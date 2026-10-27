package opencode

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

type queuedEvent struct {
	Event   Event
	Runtime *Runtime
}
type stopOperation struct {
	done chan struct{}
	err  error
}
type threadNativeOperation struct {
	cancel context.CancelFunc
	done   chan struct{}
}

type Thread struct {
	open                         plugin.OpenContext
	life                         context.Context
	cancel                       context.CancelFunc
	launch                       func(context.Context, Settings, string, bool) (*Runtime, error)
	mu                           sync.Mutex
	state                        *State
	native                       *Runtime
	configuration                string
	observed                     map[string]bool
	busy                         map[string]bool
	closed, stopping, recovering bool
	buffered                     []Event
	accepting                    int
	dirty                        bool
	timer                        *time.Timer
	eventQueue                   chan queuedEvent
	workerDone                   chan struct{}
	unsubscribe                  func()
	connectMu                    sync.Mutex
	sendMu                       sync.Mutex
	stopOp                       *stopOperation
	nativeOps                    map[string]*threadNativeOperation
	reconcileMu                  sync.Mutex
	reconcileCancel              context.CancelFunc
	connectingCancel             context.CancelFunc
	reconcileAgain               bool
	reconciling                  bool
	async                        sync.WaitGroup
	closeOnce                    sync.Once
	closeErr                     error
}

func OpenThread(ctx context.Context, open plugin.OpenContext, launch func(context.Context, Settings, string, bool) (*Runtime, error)) (*Thread, error) {
	if open.SessionState == nil || open.ReadThread == nil {
		return nil, errors.New("OpenCode requires durable session authority")
	}
	state, err := DecodeState(open.SessionState.Read())
	if err != nil {
		return nil, err
	}
	if open.Injection != nil && open.Injection.Tools != nil && open.Injection.Tools.Mode != "extend" && open.Injection.Tools.Mode != "exclusive" {
		return nil, errors.New("unsupported OpenCode tool mode")
	}
	life, cancel := context.WithCancel(ctx)
	t := &Thread{open: open, life: life, cancel: cancel, launch: launch, state: state, observed: map[string]bool{}, busy: map[string]bool{}, eventQueue: make(chan queuedEvent, 4096), workerDone: make(chan struct{})}
	if state.NativeSessionID != "" {
		t.observed[state.NativeSessionID] = true
	}
	for id := range state.NativeExecutions {
		t.observed[id] = true
	}
	for _, b := range state.BackgroundSessions {
		t.observed[b.SessionID] = true
	}
	go t.events()
	needsRecovery := state.Active() != nil
	for _, b := range state.BackgroundSessions {
		needsRecovery = needsRecovery || b.Status == "running"
	}
	for _, b := range state.BackgroundShells {
		needsRecovery = needsRecovery || b.Status == "running"
	}
	if needsRecovery {
		if _, err = t.connect(ctx); err == nil {
			t.reconcileMu.Lock()
			t.reconciling = true
			t.reconcileMu.Unlock()
			err = t.reconcile(ctx, true)
			t.reconcileMu.Lock()
			again := t.reconcileAgain
			t.reconcileAgain = false
			t.reconciling = false
			t.reconcileMu.Unlock()
			if again && err == nil {
				t.scheduleReconcile()
			}
		}
		if err != nil {
			_ = t.Close()
			return nil, err
		}
	}
	go func() { <-life.Done(); _ = t.Close() }()
	return t, nil
}
func (t *Thread) settings() (Settings, string, error) {
	record := t.open.ReadThread()
	var s Settings
	if err := json.Unmarshal(record.Settings, &s); err != nil {
		return s, "", err
	}
	cwd := record.Cwd
	if record.Worktree != nil {
		cwd = record.Worktree.Cwd
	}
	return s, cwd, nil
}
func (t *Thread) toolMode() string {
	if t.open.Injection != nil && t.open.Injection.Tools != nil {
		return t.open.Injection.Tools.Mode
	}
	return "extend"
}
func (t *Thread) commitLocked(ctx context.Context) error {
	t.dirty = false
	if t.timer != nil {
		t.timer.Stop()
		t.timer = nil
	}
	err := t.open.SessionState.Commit(ctx, t.state.Encode())
	if err != nil {
		if current, readErr := DecodeState(t.open.SessionState.Read()); readErr == nil {
			t.state = current
		}
	}
	return err
}
func (t *Thread) scheduleCommitLocked() {
	t.dirty = true
	if t.timer != nil {
		return
	}
	t.timer = time.AfterFunc(50*time.Millisecond, func() {
		t.mu.Lock()
		t.timer = nil
		var err error
		if t.dirty && !t.closed {
			err = t.commitLocked(t.life)
		}
		t.mu.Unlock()
		if err != nil {
			go t.fail(err)
		}
	})
}
func (t *Thread) bridge(entries []plugin.ContextEntry) BridgeConfiguration {
	return BridgeConfiguration{Injection: t.open.Injection, ContextEntries: entries, BeforeModel: t.beforeModel}
}
func (t *Thread) connect(ctx context.Context, allowReplace ...bool) (*Runtime, error) {
	t.connectMu.Lock()
	defer t.connectMu.Unlock()
	settings, cwd, err := t.settings()
	if err != nil {
		return nil, err
	}
	encoded, _ := json.Marshal([]any{settings, cwd})
	configuration := string(encoded)
	t.mu.Lock()
	if t.closed || t.stopping {
		t.mu.Unlock()
		return nil, errors.New("OpenCode thread is closing")
	}
	if t.native != nil && t.configuration == configuration {
		r := t.native
		t.mu.Unlock()
		return r, nil
	}
	if t.native != nil && t.state.Active() != nil && !(len(allowReplace) > 0 && allowReplace[0]) {
		t.mu.Unlock()
		return nil, errors.New("cannot change OpenCode settings during active execution")
	}
	old := t.native
	unsubscribe := t.unsubscribe
	t.native = nil
	t.unsubscribe = nil
	id := t.state.NativeSessionID
	created := t.state.NativeSessionCreated || t.state.NativeTranscript != nil
	var fork *ForkSource
	if t.state.ForkSource != nil {
		copy := clone(*t.state.ForkSource)
		fork = &copy
	}
	entries := append([]plugin.ContextEntry{}, t.state.NativeContextEntries...)
	t.mu.Unlock()
	if unsubscribe != nil {
		unsubscribe()
	}
	if old != nil {
		if err := old.Close(); err != nil {
			return nil, err
		}
	}
	starting, cancelStarting := context.WithCancel(t.life)
	stopCaller := context.AfterFunc(ctx, cancelStarting)
	defer stopCaller()
	t.mu.Lock()
	t.connectingCancel = cancelStarting
	if t.stopping || t.closed {
		cancelStarting()
	}
	t.mu.Unlock()
	defer func() { t.mu.Lock(); t.connectingCancel = nil; t.mu.Unlock() }()
	runtime, err := t.launch(starting, settings, cwd, t.toolMode() == "exclusive")
	if err != nil {
		cancelStarting()
		return nil, err
	}
	succeeded := false
	defer func() {
		if !succeeded {
			cancelStarting()
			_ = runtime.Close()
		}
	}()
	if id == "" {
		id = NewSessionID()
	}
	t.mu.Lock()
	t.state.NativeSessionID = id
	t.observed[id] = true
	if active := t.state.Active(); active != nil {
		t.state.NativeExecutions[id] = active.ExecutionID
	}
	err = t.commitLocked(ctx)
	t.mu.Unlock()
	if err != nil {
		return nil, err
	}
	if err = runtime.ConfigureSession(ctx, id, t.bridge(entries)); err != nil {
		return nil, err
	}
	var info Object
	err = runtime.Request(ctx, "GET", sessionPath(id, ""), nil, &info)
	if err != nil {
		var req *RequestError
		if !errors.As(err, &req) || req.Status != http.StatusNotFound {
			return nil, err
		}
		info = nil
	}
	if info == nil {
		if created {
			return nil, errors.New("saved OpenCode native session is missing; refusing empty replacement")
		}
		if fork != nil {
			err = runtime.Request(ctx, "POST", "/api/experimental/session/import", importTranscript(fork.Transcript, id, cwd, settings), &info)
		} else {
			payload := Object{"id": id, "location": Object{"directory": cwd}}
			if settings.Agent != "" {
				payload["agent"] = settings.Agent
			}
			if selected := settings.NativeModel(); selected != nil {
				payload["model"] = selected
			}
			err = runtime.Request(ctx, "POST", "/api/session", payload, &info)
		}
		if err != nil {
			return nil, err
		}
	}
	if info["id"] != id || object(info["location"])["directory"] != cwd {
		return nil, errors.New("OpenCode returned a different session identity or workspace")
	}
	t.mu.Lock()
	t.state.NativeSessionCreated = true
	err = t.commitLocked(ctx)
	t.mu.Unlock()
	if err != nil {
		return nil, err
	}
	if settings.Agent != "" && info["agent"] != settings.Agent {
		if err = runtime.Request(ctx, "POST", sessionPath(id, "/agent"), Object{"agent": settings.Agent}, nil); err != nil {
			return nil, err
		}
	}
	if selected := settings.NativeModel(); selected != nil {
		a, _ := json.Marshal(selected)
		b, _ := json.Marshal(info["model"])
		if string(a) != string(b) {
			if err = runtime.Request(ctx, "POST", sessionPath(id, "/model"), Object{"model": selected}, nil); err != nil {
				return nil, err
			}
		}
	}
	t.mu.Lock()
	t.native = runtime
	t.configuration = configuration
	t.mu.Unlock()
	unsubscribe = runtime.Subscribe(func(event Event) error { return t.queueEvent(runtime, event) }, func(gap error) {
		if errors.Is(gap, ErrProcessExited) {
			go t.failOwned(runtime, gap)
			return
		}
		t.mu.Lock()
		if !t.closed && !t.stopping {
			t.recovering = true
		}
		t.mu.Unlock()
	})
	t.mu.Lock()
	t.unsubscribe = unsubscribe
	t.mu.Unlock()
	if err = runtime.EventsReady(ctx); err != nil {
		return nil, err
	}
	if fork != nil {
		snapshot, err := runtime.Snapshot(ctx, id)
		if err != nil {
			return nil, err
		}
		t.mu.Lock()
		t.state.NativeTranscript = frozenTranscript(snapshot)
		mapping := map[string]string{}
		for i, v := range array(fork.Transcript["messages"]) {
			mapping[str(object(v)["id"])] = importedMessageID(id, i)
		}
		for _, m := range t.state.Messages {
			if m.Inherited {
				if newID := mapping[m.NativeMessageID]; newID != "" {
					m.NativeMessageID = newID
					m.NativeSessionID = id
				}
			}
		}
		t.state.ForkSource = nil
		err = t.commitLocked(ctx)
		t.mu.Unlock()
		if err != nil {
			return nil, err
		}
	}
	succeeded = true
	return runtime, nil
}
func (t *Thread) queueEvent(runtime *Runtime, event Event) error {
	select {
	case t.eventQueue <- queuedEvent{event, runtime}:
		return nil
	case <-t.life.Done():
		return t.life.Err()
	default:
		return errors.New("OpenCode consumer overflow; durable reconciliation required")
	}
}
func (t *Thread) events() {
	defer close(t.workerDone)
	for {
		select {
		case <-t.life.Done():
			return
		case queued := <-t.eventQueue:
			event := queued.Event
			t.mu.Lock()
			owned := t.native == queued.Runtime
			t.mu.Unlock()
			if !owned {
				continue
			}
			if event.Type == "server.connected" {
				t.mu.Lock()
				recovering := t.recovering
				t.mu.Unlock()
				if recovering {
					t.scheduleReconcile()
				}
				continue
			}
			t.mu.Lock()
			if t.recovering {
				t.buffered = append(t.buffered, event)
				t.mu.Unlock()
				continue
			}
			t.mu.Unlock()
			if err := t.acceptEvent(t.life, event, false, queued.Runtime); err != nil {
				go t.failOwned(queued.Runtime, err)
			}
		}
	}
}
func eventSession(event Event) string {
	data := event.Data
	if s := str(data["sessionID"]); s != "" {
		return s
	}
	if s := str(object(data["form"])["sessionID"]); s != "" {
		return s
	}
	if s := str(object(data["shell"])["sessionID"]); s != "" {
		return s
	}
	return str(object(object(data["info"])["metadata"])["sessionID"])
}
func (t *Thread) admitAutomaticLocked(ctx context.Context, session string) (string, error) {
	if t.open.ExecutionAdmission == nil {
		return "", errors.New("OpenCode automatic continuation has no execution admission authority")
	}
	id, err := t.open.ExecutionAdmission.Accept(ctx, func(id string) (json.RawMessage, error) {
		copy := clone(*t.state)
		if err := copy.Begin(id, time.Now().UnixMilli()); err != nil {
			return nil, err
		}
		copy.AutomaticExecutions[id] = []string{session}
		copy.NativeExecutions[session] = id
		return copy.Encode(), nil
	})
	if err != nil {
		if current, readErr := DecodeState(t.open.SessionState.Read()); readErr == nil {
			t.state = current
		}
		return "", err
	}
	state, err := DecodeState(t.open.SessionState.Read())
	if err != nil {
		return "", err
	}
	t.state = state
	return id, nil
}
func (t *Thread) beforeModel(ctx context.Context, request ModelRequest) error {
	if err := t.life.Err(); err != nil {
		return err
	}
	settings, _, err := t.settings()
	if err != nil {
		return err
	}
	t.mu.Lock()
	runtime := t.native
	closing := t.closed || t.stopping
	t.mu.Unlock()
	if closing {
		return errors.New("OpenCode thread closing")
	}
	if request.Kind == "primary" && request.SessionID == request.RootSessionID && runtime != nil {
		if err = ValidateRuntimeSettings(ctx, runtime, settings, t.open.RequireExplicitSettings, &request.Model, t.toolMode()); err != nil {
			return err
		}
		if settings.Agent != "" {
			var info Object
			if err = runtime.Request(ctx, "GET", sessionPath(request.SessionID, ""), nil, &info); err != nil {
				return err
			}
			if info["agent"] != settings.Agent {
				return errors.New("OpenCode changed selected agent")
			}
		}
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.closed || t.stopping || request.RootSessionID != t.state.NativeSessionID {
		return errors.New("unowned OpenCode model request")
	}
	t.observed[request.SessionID] = true
	active := t.state.Active()
	id := ""
	if active != nil {
		id = active.ExecutionID
	} else {
		id, err = t.admitAutomaticLocked(ctx, request.SessionID)
		if err != nil {
			return err
		}
	}
	owners := t.state.AutomaticExecutions[id]
	if len(owners) > 0 && !slices.Contains(owners, request.SessionID) {
		t.state.AutomaticExecutions[id] = append(owners, request.SessionID)
	}
	t.state.NativeExecutions[request.SessionID] = id
	t.busy[request.SessionID] = true
	t.state.background(request.SessionID, "running")
	if (request.SessionID == request.RootSessionID && request.Kind == "primary") ||
		(slices.Contains(owners, request.SessionID) && !slices.Contains(owners, request.RootSessionID)) {
		author := clone(t.state.ExecutionAuthors[id])
		if author == nil {
			author = Object{}
		}
		author["model"] = request.Model.ProviderID + "/" + request.Model.ID
		if request.Model.Variant != "" {
			author["effort"] = request.Model.Variant
		}
		t.state.ExecutionAuthors[id] = author
	}
	if request.Kind == "primary" && request.SessionID == request.RootSessionID {
		t.state.NativeReadPrefix = clone(request.ReadPrefix)
	}
	return t.commitLocked(ctx)
}
func (t *Thread) acceptEvent(ctx context.Context, event Event, replay bool, expected ...*Runtime) error {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.closed || t.stopping || len(expected) > 0 && t.native != expected[0] {
		return nil
	}
	session := eventSession(event)
	if session == "" {
		for _, shell := range t.state.BackgroundShells {
			if shell.ShellID == str(event.Data["id"]) {
				session = shell.SessionID
			}
		}
	}
	if session == "" {
		return nil
	}
	if !t.observed[session] {
		parent := str(event.Data["parentID"])
		if event.Type != "session.created" || !t.observed[parent] {
			return nil
		}
		t.observed[session] = true
		t.state.NativeExecutions[session] = t.state.NativeExecutions[parent]
		t.state.background(session, "idle")
	}
	if event.Durable != nil {
		if prev, ok := t.state.Cursors[event.Durable.AggregateID]; ok && prev >= event.Durable.Seq {
			return nil
		}
	}
	owner := t.state.NativeExecutions[session]
	active := t.state.Active()
	if owner == "" && active != nil {
		owner = active.ExecutionID
	}
	interaction := event.Type == "permission.asked" || event.Type == "form.created"
	if interaction {
		for _, v := range t.state.Interactions {
			if v.SessionID == session && v.ID == str(event.Data["id"]) && v.Status != "pending" {
				return nil
			}
		}
		if active == nil && !replay {
			var err error
			owner, err = t.admitAutomaticLocked(ctx, session)
			if err != nil {
				return err
			}
			active = t.state.Active()
		}
		if active != nil {
			owner = active.ExecutionID
			t.state.NativeExecutions[session] = owner
			owners := t.state.AutomaticExecutions[owner]
			if len(owners) > 0 && !slices.Contains(owners, session) {
				t.state.AutomaticExecutions[owner] = append(owners, session)
			}
		}
	}
	if event.Type == "session.execution.started" {
		t.busy[session] = true
	}
	foreground := t.state.foregroundForEvent(event, owner)
	if err := t.state.Reduce(event, owner); err != nil {
		return err
	}
	if event.Durable != nil {
		t.state.Cursors[session] = event.Durable.Seq
	}
	if event.Type == "permission.asked" && !replay && active != nil && t.native != nil {
		settings, _, err := t.settings()
		if err != nil {
			return err
		}
		if settings.PermissionMode == "" || settings.PermissionMode == "auto" {
			for _, pending := range t.state.Interactions {
				if pending.Kind == "permission" && pending.SessionID == session && pending.ID == str(event.Data["id"]) && pending.Status == "pending" && t.nativeOps[interactionID(pending)] == nil {
					err = t.respondInteractionLocked(ctx, pending, model.RespondRequest{ActionID: "allow"})
					if t.closed || t.stopping {
						return nil
					}
					if err != nil {
						var req *RequestError
						if !errors.As(err, &req) || req.Status != http.StatusNotFound {
							return err
						}
						for _, current := range t.state.Interactions {
							if interactionID(current) == interactionID(pending) && current.Status == "pending" {
								current.Status = "cancelled"
								t.state.RefreshInteractions(current.ExecutionID)
								break
							}
						}
					}
				}
			}
		}
	}
	terminal := event.Type == "session.execution.succeeded" || event.Type == "session.execution.failed" || event.Type == "session.execution.interrupted"
	if terminal {
		delete(t.busy, session)
		owners := t.state.AutomaticExecutions[owner]
		settles := session == t.state.NativeSessionID
		if len(owners) > 0 {
			settles = slices.Contains(owners, session)
			for _, id := range owners {
				settles = settles && !t.busy[id]
			}
		}
		if settles && owner != "" {
			outcome := map[string]string{"session.execution.succeeded": "completed", "session.execution.failed": "failed", "session.execution.interrupted": "interrupted"}[event.Type]
			t.state.Settle(owner, outcome, event.Created, nativeFailure(event.Data["error"]))
		}
	}
	if terminal || event.Type == "session.step.ended" || event.Type == "session.step.failed" || event.Type == "session.compaction.ended" || event.Type == "session.compaction.failed" {
		if err := t.recordUsageLocked(ctx); err != nil {
			return err
		}
	}
	if activity := t.state.acceptForeground(foreground); activity != nil && t.open.PublishActivity != nil {
		t.open.PublishActivity(*activity)
	}

	if terminal || interaction || strings.Contains(event.Type, "replied") || strings.Contains(event.Type, "cancelled") {
		if err := t.commitLocked(ctx); err != nil {
			return err
		}
		if terminal && !replay {
			go t.scheduleReconcile()
		}
	} else {
		t.scheduleCommitLocked()
	}
	return nil
}
func (t *Thread) recordUsageLocked(ctx context.Context) error {
	if t.closed || t.stopping {
		return context.Canceled
	}
	if t.open.TelemetryLedger == nil {
		return nil
	}
	record := func(session, id, provider, modelID string, at int64, u *Usage) error {
		sampleID := "opencode:" + session + ":" + id
		if slices.Contains(t.state.UsageRecorded, sampleID) {
			return nil
		}
		key := "usage:" + sampleID
		if t.nativeOps[key] != nil {
			return nil
		}
		runtime := t.native
		usage := clone(*u)
		operationCtx, operation := t.beginNativeOperationLocked(ctx, key)
		t.mu.Unlock()
		payload := Object{"type": "execution-usage", "sampleId": sampleID, "observedAt": at, "model": strings.Trim(provider+"/"+modelID, "/"), "attributionKeys": usageAttribution(operationCtx, runtime, session, id, provider, modelID), "usageKind": "generation", "uncachedInputTokens": usage.Input, "outputTokens": usage.Output, "cachedReadTokens": usage.CacheRead, "cacheWriteTokens": usage.CacheWrite, "reasoningTokens": usage.Reasoning}
		if usage.Cost != nil {
			payload["costUsd"] = *usage.Cost
		}
		raw, _ := json.Marshal(payload)
		err := t.open.TelemetryLedger.Record(operationCtx, raw)
		t.mu.Lock()
		t.endNativeOperationLocked(key, operation)
		if t.closed || t.stopping || t.native != runtime {
			return context.Canceled
		}
		if err != nil {
			return err
		}
		t.state.UsageRecorded = append(t.state.UsageRecorded, sampleID)
		return nil
	}
	for _, m := range t.state.Messages {
		if !m.Inherited && m.Usage != nil && m.Status != "streaming" && m.NativeSessionID != "" {
			if err := record(m.NativeSessionID, m.NativeMessageID, m.Provider, m.Model, m.CreatedAt, m.Usage); err != nil {
				return err
			}
		}
	}
	for _, u := range t.state.AuxiliaryUsage {
		if err := record(u.NativeSessionID, u.ID, u.Provider, u.Model, u.CreatedAt, &u.Usage); err != nil {
			return err
		}
	}
	return nil
}
func (t *Thread) scheduleReconcile() {
	t.mu.Lock()
	if t.closed || t.stopping {
		t.mu.Unlock()
		return
	}
	t.async.Add(1)
	t.mu.Unlock()
	t.reconcileMu.Lock()
	if t.reconciling {
		t.reconcileAgain = true
		t.reconcileMu.Unlock()
		t.async.Done()
		return
	}
	t.reconciling = true
	t.reconcileMu.Unlock()
	go func() {
		defer t.async.Done()
		for {
			t.mu.Lock()
			expected := t.native
			t.mu.Unlock()
			if err := t.reconcile(t.life, false); err != nil && t.life.Err() == nil {
				go t.failOwned(expected, err)
			}
			t.reconcileMu.Lock()
			again := t.reconcileAgain
			t.reconcileAgain = false
			if !again {
				t.reconciling = false
			}
			t.reconcileMu.Unlock()
			if !again {
				return
			}
		}
	}()
}
func (t *Thread) reconcile(ctx context.Context, startup bool) error {
	t.connectMu.Lock()
	defer t.connectMu.Unlock()
	t.mu.Lock()
	runtime := t.native
	id := t.state.NativeSessionID
	if runtime == nil || t.closed || t.stopping {
		t.mu.Unlock()
		return nil
	}
	t.recovering = true
	operation, cancelOperation := context.WithCancel(ctx)
	t.reconcileCancel = cancelOperation
	t.mu.Unlock()
	defer func() { cancelOperation(); t.mu.Lock(); t.reconcileCancel = nil; t.mu.Unlock() }()
	ctx = operation
	finish := func() error {
		for {
			t.mu.Lock()
			buffered := t.buffered
			t.buffered = nil
			if len(buffered) == 0 {
				t.recovering = false
				t.mu.Unlock()
				return nil
			}
			t.mu.Unlock()
			for _, event := range buffered {
				if !strings.HasSuffix(event.Type, ".delta") && event.Type != "session.tool.progress" {
					if err := t.acceptEvent(ctx, event, false); err != nil {
						return err
					}
				}
			}
		}
	}

	success := false
	defer func() {
		if !success {
			t.mu.Lock()
			t.recovering = false
			t.mu.Unlock()
		}
	}()
	descendants, err := runtime.Descendants(ctx, id)
	if err != nil {
		return err
	}
	t.mu.Lock()
	for _, session := range descendants {
		t.observed[session] = true
		if t.state.NativeExecutions[session] == "" {
			t.state.NativeExecutions[session] = t.state.NativeExecutions[id]
		}
	}
	for session := range t.observed {
		if !slices.Contains(descendants, session) {
			descendants = append(descendants, session)
		}
	}
	t.mu.Unlock()
	available := []string{}
	for _, session := range descendants {
		t.mu.Lock()
		after, ok := t.state.Cursors[session]
		if !ok {
			after = -1
		}
		t.mu.Unlock()
		if err = runtime.ReplayLog(ctx, session, after, func(event Event) error { return t.acceptEvent(ctx, event, true, runtime) }); err != nil {
			var requestError *RequestError
			if session != id && errors.As(err, &requestError) && requestError.Status == 404 {
				t.mu.Lock()
				t.state.background(session, "idle")
				delete(t.busy, session)
				for _, v := range t.state.Interactions {
					if v.SessionID == session && v.Status == "pending" {
						v.Status = "cancelled"
					}
				}
				t.mu.Unlock()
				continue
			}
			return err
		}
		available = append(available, session)
	}
	descendants = available
	snapshot, err := runtime.Snapshot(ctx, id)
	if err != nil {
		return err
	}
	var active map[string]Object
	if err = runtime.Request(ctx, "GET", "/api/session/active", nil, &active); err != nil {
		return err
	}
	var shells []Object
	if err = runtime.Request(ctx, "GET", "/api/shell", nil, &shells); err != nil {
		return err
	}
	t.mu.Lock()
	for i := range t.state.BackgroundShells {
		t.state.BackgroundShells[i].Status = "idle"
	}
	for _, shell := range shells {
		session := str(object(shell["metadata"])["sessionID"])
		if t.observed[session] {
			_ = t.state.Reduce(Event{Type: "shell.created", Data: Object{"info": shell}, Created: time.Now().UnixMilli()}, t.state.NativeExecutions[session])
		}
	}

	for _, session := range descendants {
		t.observed[session] = true
		if t.state.NativeExecutions[session] == "" {
			t.state.NativeExecutions[session] = t.state.NativeExecutions[id]
		}
		status := "idle"
		if active[session] != nil {
			status = "running"
			t.busy[session] = true
		} else {
			delete(t.busy, session)
		}
		t.state.background(session, status)
	}
	t.state.MergeMessages(array(snapshot["messages"]), id, t.state.NativeExecutions[id], false)
	t.state.NativeTranscript = frozenTranscript(snapshot)
	current := t.state.Active()
	candidate := ""
	started := int64(0)
	owners := []string{id}
	if current != nil {
		candidate = current.ExecutionID
		started = current.StartedAt
		if automatic := t.state.AutomaticExecutions[candidate]; len(automatic) > 0 {
			owners = append([]string{}, automatic...)
		}
	}
	t.mu.Unlock()
	pendingNative := map[string]bool{}
	for _, session := range descendants {
		if session != id {
			child, err := runtime.Snapshot(ctx, session)
			if err != nil {
				return err
			}
			t.mu.Lock()
			t.state.MergeMessages(array(child["messages"]), session, t.state.NativeExecutions[session], false)
			t.mu.Unlock()
		}
		var permissions, forms []Object
		if err = runtime.Request(ctx, "GET", sessionPath(session, "/permission"), nil, &permissions); err != nil {
			return err
		}
		if err = runtime.Request(ctx, "GET", sessionPath(session, "/form"), nil, &forms); err != nil {
			return err
		}
		for _, permission := range permissions {
			pendingNative[session+":"+str(permission["id"])] = true
			if err = t.acceptEvent(ctx, Event{Type: "permission.asked", Data: permission, Created: time.Now().UnixMilli()}, false); err != nil {
				return err
			}
		}
		for _, form := range forms {
			pendingNative[session+":"+str(form["id"])] = true
			if err = t.acceptEvent(ctx, Event{Type: "form.created", Data: Object{"form": form}, Created: time.Now().UnixMilli()}, false); err != nil {
				return err
			}
		}
	}
	t.mu.Lock()
	for _, v := range t.state.Interactions {
		if v.Status == "pending" && !pendingNative[v.SessionID+":"+v.ID] {
			v.Status = "cancelled"
		}
	}
	t.mu.Unlock()
	if err = finish(); err != nil {
		return err
	}
	success = true
	if candidate != "" {
		var nowActive map[string]Object
		if err = runtime.Request(ctx, "GET", "/api/session/active", nil, &nowActive); err != nil {
			return err
		}
		allIdle := true
		outcome := "completed"
		boundary := true
		finished := time.Now().UnixMilli()
		for _, session := range owners {
			if nowActive[session] != nil {
				allIdle = false
				continue
			}
			var info Object
			if err = runtime.Request(ctx, "GET", sessionPath(session, ""), nil, &info); err != nil {
				return err
			}
			idle := int64(number(object(info["time"])["idle"]))
			boundary = boundary && idle >= started
			if info["outcome"] == "failed" {
				outcome = "failed"
			} else if info["outcome"] == "interrupted" && outcome != "failed" {
				outcome = "interrupted"
			}
			finished = max(finished, idle)
		}
		t.mu.Lock()
		if allIdle && (boundary || startup) && t.accepting == 0 && t.state.Active() != nil && t.state.Active().ExecutionID == candidate {
			if !boundary {
				outcome = "interrupted"
			}
			t.state.Settle(candidate, outcome, finished, "")
		}
		t.mu.Unlock()
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	for _, e := range t.state.Executions {
		t.state.RefreshInteractions(e.ExecutionID)
	}
	if err = t.recordUsageLocked(ctx); err != nil {
		return err
	}
	return t.commitLocked(ctx)
}
func (t *Thread) Send(ctx context.Context, request plugin.SendRequest) error {
	t.mu.Lock()
	if t.closed {
		t.mu.Unlock()
		return errors.New("OpenCode thread closed")
	}
	t.async.Add(1)
	t.mu.Unlock()
	defer t.async.Done()
	combined, cancel := context.WithCancel(ctx)
	defer cancel()
	stopLife := context.AfterFunc(t.life, cancel)
	defer stopLife()
	ctx = combined
	t.sendMu.Lock()
	defer t.sendMu.Unlock()
	if err := ctx.Err(); err != nil {
		return err
	}
	prepared, err := PrepareInput(ctx, request.Input)
	if err != nil {
		return err
	}
	t.mu.Lock()
	if t.closed || t.stopping {
		t.mu.Unlock()
		return errors.New("OpenCode thread is unavailable")
	}
	active := t.state.Active()
	if active != nil && active.ExecutionID != request.ExecutionID {
		t.mu.Unlock()
		return errors.New("OpenCode already has another execution")
	}
	if active == nil {
		if err = t.state.Begin(request.ExecutionID, time.Now().UnixMilli()); err != nil {
			t.mu.Unlock()
			return err
		}
	}
	promptID := newMessageID()
	message := &Message{ID: promptID, NativeMessageID: promptID, NativeSessionID: t.state.NativeSessionID, ExecutionID: request.ExecutionID, Role: "user", Text: prepared.VisibleText, Status: "complete", CreatedAt: time.Now().UnixMilli(), Annotations: append(json.RawMessage{}, request.Input.Annotations...)}
	if active == nil {
		t.state.Messages = append(t.state.Messages, message)
		if t.state.NativeSessionID != "" {
			t.state.NativeExecutions[t.state.NativeSessionID] = request.ExecutionID
		}
		err = t.commitLocked(ctx)
	}
	t.accepting++
	t.mu.Unlock()
	defer func() { t.mu.Lock(); t.accepting--; t.mu.Unlock() }()
	if err != nil {
		return err
	}
	if active == nil && request.Admitted != nil {
		if err := request.Admitted(); err != nil {
			_ = t.stop(context.Background(), "failed", err.Error())
			return err
		}
	}
	stopCancel := context.AfterFunc(ctx, func() { go t.stopOwned(context.Background(), "interrupted", "", nil, request.ExecutionID) })
	defer stopCancel()
	dispatched, received := false, false
	runtime, err := t.connect(ctx, active == nil)
	if err == nil {
		t.mu.Lock()
		id := t.state.NativeSessionID
		t.mu.Unlock()
		err = runtime.ConfigureSession(ctx, id, t.bridge(request.ContextEntries))
		if err == nil {
			t.mu.Lock()
			t.state.NativeContextEntries = append([]plugin.ContextEntry{}, request.ContextEntries...)
			err = t.commitLocked(ctx)
			t.mu.Unlock()
		}
		settings, _, settingsErr := t.settings()
		if err == nil {
			err = settingsErr
		}
		if err == nil {
			err = ValidateRuntimeSettings(ctx, runtime, settings, t.open.RequireExplicitSettings, nil, t.toolMode())
		}
		if err == nil && len(prepared.Modalities) > 0 {
			var info Object
			err = runtime.Request(ctx, "GET", sessionPath(id, ""), nil, &info)
			if err == nil {
				var models []Object
				err = runtime.Request(ctx, "GET", "/api/model", nil, &models)
				if err == nil {
					selected := object(info["model"])
					var modelInfo Object
					for _, m := range models {
						if m["providerID"] == selected["providerID"] && m["id"] == selected["id"] {
							modelInfo = m
						}
					}
					if len(selected) == 0 {
						err = runtime.Request(ctx, "GET", "/api/model/default", nil, &modelInfo)
					}
					for _, modality := range prepared.Modalities {
						supported := false
						for _, value := range array(object(modelInfo["capabilities"])["input"]) {
							if strings.HasPrefix(str(value), modality) {
								supported = true
							}
						}
						if !supported {
							err = fmt.Errorf("selected OpenCode model does not support %s attachments", modality)
						}
					}
				}
			}
		}
		if err == nil {
			presentation := request.Input.Presentation
			if presentation == "" {
				presentation = "ordinary"
			}
			dispatched = true
			err = runtime.Request(ctx, "POST", sessionPath(id, "/prompt"), Object{"id": promptID, "text": prepared.Text, "files": prepared.Files, "metadata": Object{"mokuseiExecutionId": request.ExecutionID, "mokuseiPresentation": presentation}, "delivery": "steer"}, nil)
			received = err == nil
		}
		if err == nil && active != nil {
			// A steer is retained only after native acceptance. Its inbox event can
			// arrive before this receipt, so enrich that message rather than duplicate it.
			t.mu.Lock()
			message.NativeSessionID = id
			if known := t.state.message("user", promptID, id); known != nil {
				*known = *message
			} else {
				t.state.Messages = append(t.state.Messages, message)
			}
			err = t.commitLocked(ctx)
			t.mu.Unlock()
			if err == nil && request.Admitted != nil {
				err = request.Admitted()
			}
		}
		if err == nil {
			t.async.Add(1)
			go func() {
				defer t.async.Done()
				_ = runtime.Request(t.life, "POST", "/api/experimental/session/"+url.PathEscape(id)+"/wait", nil, nil)
				t.mu.Lock()
				owned := !t.closed && !t.stopping && t.native == runtime && t.state.Active() != nil && t.state.Active().ExecutionID == request.ExecutionID
				t.mu.Unlock()
				if owned {
					t.scheduleReconcile()
				}
			}()
		}
	}
	if err != nil {
		var rejected *RequestError
		if active != nil && !received && ctx.Err() == nil && (!dispatched || errors.As(err, &rejected) && rejected.Status >= 400 && rejected.Status < 500) {
			return err
		}
		outcome := "failed"
		if ctx.Err() != nil {
			outcome = "interrupted"
		}
		_ = t.stop(context.Background(), outcome, err.Error())
		return err
	}
	return nil
}
func (t *Thread) stop(ctx context.Context, outcome, reason string) error {
	return t.stopOwned(ctx, outcome, reason, nil, "")
}
func (t *Thread) stopOwned(ctx context.Context, outcome, reason string, expected *Runtime, executionID string) error {
	t.mu.Lock()
	if expected != nil && t.native != expected {
		t.mu.Unlock()
		return nil
	}
	if executionID != "" && (t.state.Active() == nil || t.state.Active().ExecutionID != executionID) {
		t.mu.Unlock()
		return nil
	}
	if op := t.stopOp; op != nil {
		t.mu.Unlock()
		select {
		case <-op.done:
			return op.err
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	op := &stopOperation{done: make(chan struct{})}
	t.stopOp = op
	t.stopping = true
	cancelReconcile, cancelConnect := t.reconcileCancel, t.connectingCancel
	operations := make([]*threadNativeOperation, 0, len(t.nativeOps))
	for _, operation := range t.nativeOps {
		operations = append(operations, operation)
		operation.cancel()
	}
	t.mu.Unlock()
	if cancelReconcile != nil {
		cancelReconcile()
	}
	if cancelConnect != nil {
		cancelConnect()
	}
	for _, operation := range operations {
		<-operation.done
	}
	err := t.stopResources(ctx, outcome, reason)
	t.mu.Lock()
	op.err = err
	t.stopping = false
	if t.stopOp == op {
		t.stopOp = nil
	}
	close(op.done)
	t.mu.Unlock()
	return err
}
func (t *Thread) stopResources(ctx context.Context, outcome, reason string) error {
	t.mu.Lock()
	runtime := t.native
	id := t.state.NativeSessionID
	unsubscribe := t.unsubscribe
	t.mu.Unlock()
	t.connectMu.Lock()
	t.connectMu.Unlock()
	t.mu.Lock()
	if runtime == nil {
		runtime = t.native
		id = t.state.NativeSessionID
		unsubscribe = t.unsubscribe
	}
	t.mu.Unlock()
	cleanupCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 10*time.Second)
	defer cancel()
	var closeErr error
	if runtime != nil {
		sessions, err := runtime.Descendants(cleanupCtx, id)
		if err != nil {
			t.mu.Lock()
			for session := range t.observed {
				sessions = append(sessions, session)
			}
			t.mu.Unlock()
		}
		for _, session := range sessions {
			var inbox []Object
			if runtime.Request(cleanupCtx, "GET", sessionPath(session, "/inbox"), nil, &inbox) == nil {
				for _, item := range inbox {
					_ = runtime.Request(cleanupCtx, "DELETE", sessionPath(session, "/inbox/"+url.PathEscape(str(item["id"]))), nil, nil)
				}
			}
			_ = runtime.Request(cleanupCtx, "POST", sessionPath(session, "/interrupt?resume=false"), nil, nil)
			_ = runtime.Request(cleanupCtx, "POST", "/api/experimental/session/"+url.PathEscape(session)+"/wait", nil, nil)
		}
		if snapshot, err := runtime.Snapshot(cleanupCtx, id); err == nil {
			t.mu.Lock()
			t.state.NativeTranscript = frozenTranscript(snapshot)
			t.state.MergeMessages(array(snapshot["messages"]), id, t.state.NativeExecutions[id], false)
			t.mu.Unlock()
		}
		if unsubscribe != nil {
			unsubscribe()
		}
		closeErr = runtime.Close()
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	t.native = nil
	t.unsubscribe = nil
	t.configuration = ""
	t.recovering = false
	t.buffered = nil
	t.busy = map[string]bool{}
	for i := range t.state.BackgroundSessions {
		t.state.BackgroundSessions[i].Status = "idle"
	}
	for i := range t.state.BackgroundShells {
		t.state.BackgroundShells[i].Status = "idle"
	}
	if active := t.state.Active(); active != nil {
		t.state.Settle(active.ExecutionID, outcome, time.Now().UnixMilli(), reason)
	}
	for _, v := range t.state.Interactions {
		if v.Status == "pending" {
			v.Status = "cancelled"
		}
	}
	persistCtx, persistCancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer persistCancel()
	return errors.Join(closeErr, t.commitLocked(persistCtx))
}
func (t *Thread) failOwned(runtime *Runtime, err error) {
	if err != nil {
		_ = t.stopOwned(context.Background(), "failed", err.Error(), runtime, "")
	}
}
func (t *Thread) fail(err error) {
	if err != nil {
		_ = t.stop(context.Background(), "failed", err.Error())
	}
}
func (t *Thread) Interrupt(ctx context.Context) error { return t.stop(ctx, "interrupted", "") }
func (t *Thread) Respond(ctx context.Context, request model.RespondRequest) error {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.closed || t.stopping || t.native == nil {
		return errors.New("OpenCode connection is unavailable")
	}
	var pending *Interaction
	for _, v := range t.state.Interactions {
		if v.Status == "pending" && interactionID(v) == request.InteractionID {
			pending = v
			break
		}
	}
	if pending == nil || request.ExecutionID != "" && pending.ExecutionID != request.ExecutionID {
		return errors.New("unknown or expired OpenCode interaction")
	}
	if err := t.respondInteractionLocked(ctx, pending, request); err != nil {
		return err
	}
	return t.commitLocked(ctx)
}

// All native work started while holding state authority must register before
// releasing that lock. Stop closes admission, cancels these calls and joins them.
func (t *Thread) beginNativeOperationLocked(ctx context.Context, key string) (context.Context, *threadNativeOperation) {
	if t.nativeOps == nil {
		t.nativeOps = make(map[string]*threadNativeOperation)
	}
	ctx, cancel := context.WithCancel(ctx)
	operation := &threadNativeOperation{cancel: cancel, done: make(chan struct{})}
	t.nativeOps[key] = operation
	t.async.Add(1)
	return ctx, operation
}
func (t *Thread) endNativeOperationLocked(key string, operation *threadNativeOperation) {
	operation.cancel()
	delete(t.nativeOps, key)
	close(operation.done)
	t.async.Done()
}

// Native replies may wait for execution work. Release the state lock while they
// run so stop can cancel and drain them before closing the native runtime.
func (t *Thread) respondInteractionLocked(ctx context.Context, pending *Interaction, request model.RespondRequest) error {
	valid := false
	for _, action := range publicInteraction(pending).Actions {
		if action.ID == request.ActionID {
			valid = true
		}
	}
	if !valid {
		return errors.New("unsupported interaction action")
	}
	key := interactionID(pending)
	if t.nativeOps[key] != nil {
		return errors.New("OpenCode interaction response is already in progress")
	}
	ctx, operation := t.beginNativeOperationLocked(ctx, key)
	runtime := t.native
	snapshot := clone(*pending)
	t.mu.Unlock()
	err := func() error {
		path := sessionPath(snapshot.SessionID, "")
		if snapshot.Kind == "permission" {
			if len(request.Answers) > 0 {
				return errors.New("permission has no answer fields")
			}
			if request.ActionID == "allow-session" {
				var info Object
				if err := runtime.Request(ctx, "GET", path, nil, &info); err != nil {
					return err
				}
				rules := array(info["permissions"])
				for _, resource := range snapshot.Save {
					rules = append(rules, Object{"action": snapshot.Action, "resource": resource, "effect": "allow"})
				}
				if err := runtime.Request(ctx, "PATCH", path, Object{"permissions": rules}, nil); err != nil {
					return err
				}
			}
			decision := "once"
			if request.ActionID == "deny" {
				decision = "reject"
			}
			body := Object{"decision": decision}
			if request.Message != "" {
				body["message"] = request.Message
			}
			return runtime.Request(ctx, "POST", path+"/permission/"+url.PathEscape(snapshot.ID)+"/reply", body, nil)
		}
		if request.ActionID == "cancel" {
			q := ""
			if request.Message != "" {
				q = "?message=" + url.QueryEscape(request.Message)
			}
			return runtime.Request(ctx, "DELETE", path+"/form/"+url.PathEscape(snapshot.ID)+q, nil, nil)
		}
		answers, err := formAnswers(&snapshot, request)
		if err != nil {
			return err
		}
		return runtime.Request(ctx, "POST", path+"/form/"+url.PathEscape(snapshot.ID)+"/reply", Object{"answer": answers}, nil)
	}()
	t.mu.Lock()
	t.endNativeOperationLocked(key, operation)
	if t.closed || t.stopping || t.native != runtime {
		return context.Canceled
	}
	if err != nil {
		return err
	}
	for _, current := range t.state.Interactions {
		if interactionID(current) == key && current.Status == "pending" {
			current.Status = "answered"
			if request.ActionID == "cancel" {
				current.Status = "cancelled"
			}
			t.state.RefreshInteractions(current.ExecutionID)
			break
		}
	}
	return nil
}

func (t *Thread) Read(ctx context.Context, question string) (string, error) {
	t.mu.Lock()
	if t.closed {
		t.mu.Unlock()
		return "", errors.New("OpenCode thread closed")
	}
	t.async.Add(1)
	t.mu.Unlock()
	defer t.async.Done()
	combined, cancel := context.WithCancel(ctx)
	defer cancel()
	stopLife := context.AfterFunc(t.life, cancel)
	defer stopLife()
	ctx = combined
	if strings.TrimSpace(question) == "" {
		return "", errors.New("OpenCode read question is empty")
	}
	if t.open.Injection != nil {
		return "", errors.New("injected Host threads cannot be read as ordinary source conversations")
	}
	t.sendMu.Lock()
	barrierHeld := true
	defer func() {
		if barrierHeld {
			t.sendMu.Unlock()
		}
	}()
	t.mu.Lock()
	if t.closed {
		t.mu.Unlock()
		return "", errors.New("OpenCode thread closed")
	}
	id := t.state.NativeSessionID
	created := t.state.NativeSessionCreated
	pendingFork := t.state.ForkSource != nil
	prefix := clone(t.state.NativeReadPrefix)
	entries := append([]plugin.ContextEntry{}, t.state.NativeContextEntries...)
	t.mu.Unlock()
	if !created && pendingFork {
		// Ordinary forks retain their existing lazy import semantics. Materialize
		// that source once, then read it through a native fork like any thread.
		if _, err := t.connect(ctx); err != nil {
			return "", err
		}
		t.mu.Lock()
		id = t.state.NativeSessionID
		created = t.state.NativeSessionCreated
		t.mu.Unlock()
	}
	if id == "" || !created {
		return "", errors.New("OpenCode has no completed native history to read")
	}
	settings, cwd, err := t.settings()
	if err != nil {
		return "", err
	}
	t.sendMu.Unlock()
	barrierHeld = false
	return ReadFork(ctx, t.launch, settings, cwd, id, prefix, entries, question)
}
func (t *Thread) CompletedReply(executionID string) (string, bool) {
	t.mu.Lock()
	defer t.mu.Unlock()
	completed := false
	for _, e := range t.state.Executions {
		if e.ExecutionID == executionID && e.Status == "completed" {
			completed = true
		}
	}
	if !completed {
		return "", false
	}
	for i := len(t.state.Messages) - 1; i >= 0; i-- {
		m := t.state.Messages[i]
		if m.ExecutionID == executionID && m.Role == "assistant" && m.Status == "complete" && (m.NativeSessionID == "" || m.NativeSessionID == t.state.NativeSessionID) && strings.TrimSpace(m.Text) != "" {
			return m.Text, true
		}
	}
	return "", false
}
func (t *Thread) Close() error {
	t.closeOnce.Do(func() {
		t.mu.Lock()
		t.closed = true
		t.mu.Unlock()
		t.closeErr = t.stop(context.Background(), "interrupted", "")
		t.cancel()
		t.mu.Lock()
		if t.timer != nil {
			t.timer.Stop()
		}
		t.mu.Unlock()
		<-t.workerDone
		t.async.Wait()
	})
	return t.closeErr
}
