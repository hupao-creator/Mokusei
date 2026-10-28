package runtime

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/services/workspaces"
)

type CreateThreadRequest struct {
	HarnessID       string
	Input           model.AgentInput
	Cwd             string
	Settings        json.RawMessage
	Worktree        *model.WorktreeOptions
	Moku            bool
	Injection       *plugin.Injection
	ResolveSettings func(context.Context, string) (json.RawMessage, error)
}
type CreatedThread struct {
	Record          model.ThreadRecord `json:"record"`
	Execution       SendResult         `json:"execution"`
	Acknowledgement json.RawMessage    `json:"acknowledgement"`
	WorktreeName    string             `json:"worktreeName,omitempty"`
	// WorktreeNameAdjusted/Notice report a sanitized, truncated, collision-suffixed
	// or generated worktree directory name instead of silently changing it.
	WorktreeNameAdjusted bool   `json:"worktreeNameAdjusted,omitempty"`
	WorktreeNameNotice   string `json:"notice,omitempty"`
}
type SendResult = plugin.SessionSendResult
type threadHandle struct {
	runtime               *Runtime
	id                    string
	generation            uint64
	harness               plugin.Harness
	native                plugin.Handle
	ctx                   context.Context
	cancel                context.CancelFunc
	changed               chan struct{}
	mu                    sync.Mutex
	currentExecution      string
	activeSends           int
	sendCancels           map[*sendAdmission]context.CancelFunc
	closed                bool
	stateMu               sync.Mutex
	disposed              bool
	forking               bool
	opened                chan struct{}
	workers               sync.WaitGroup
	closeOnce             sync.Once
	closeErr              error
	beforeNativeAdmission func(context.Context) error
	admissionMu           sync.Mutex
	admission             *sendAdmission
}
type sendAdmission struct {
	executionID string
	result      SendResult
	callback    func(SendResult) error
	done        chan struct{}
	err         error
	once        sync.Once
}

func (r *Runtime) cancelSendClaims(id string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	for claim := range r.sendClaims[id] {
		claim.cancel()
	}
}

// Operations belong to one history generation. A caller may outlive the
// runtime, but its native/filesystem work must not survive history replacement.
func (r *Runtime) operationContext(ctx context.Context) (context.Context, context.CancelFunc) {
	r.mu.Lock()
	generation := r.generationCtx
	r.mu.Unlock()
	joined, cancel := context.WithCancel(ctx)
	stop := context.AfterFunc(generation, cancel)
	if generation.Err() != nil {
		cancel()
	}
	return joined, func() { stop(); cancel() }
}

func (h *threadHandle) active() error {
	h.mu.Lock()
	closed := h.closed
	h.mu.Unlock()
	if closed {
		return errors.New("thread handle is closed")
	}
	if err := h.ctx.Err(); err != nil {
		return err
	}
	r := h.runtime
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.closed || r.resetting || r.generation != h.generation || r.handles[h.id] != h || r.deleting[h.id] {
		return errors.New("session owner has been revoked")
	}
	return nil
}

func (h *threadHandle) operationContext(ctx context.Context) (context.Context, context.CancelFunc) {
	joined, cancel := context.WithCancel(ctx)
	stop := context.AfterFunc(h.ctx, cancel)
	if h.ctx.Err() != nil {
		cancel()
	}
	return joined, func() { stop(); cancel() }
}

// Called at the serialized state boundary while stateMu keeps final disposal
// from racing a commit. Cleanup observations remain valid until Close drains.
func (h *threadHandle) ownsState() error {
	r := h.runtime
	r.mu.Lock()
	defer r.mu.Unlock()
	if h.disposed || r.generation != h.generation || r.handles[h.id] != h {
		return errors.New("session owner has been revoked")
	}
	return nil
}
func (r *Runtime) harness(ctx context.Context, t model.ThreadRecord) (plugin.Harness, error) {
	if reason := r.config.DisabledHarnesses[t.HarnessID]; reason != "" {
		return nil, fmt.Errorf("harness disabled: %s", reason)
	}
	h := r.config.Harnesses[t.HarnessID]
	if h == nil {
		return nil, fmt.Errorf("unknown harness: %s", t.HarnessID)
	}
	return h, nil
}
func (r *Runtime) openThread(ctx context.Context, t model.ThreadRecord, injection *plugin.Injection) (*threadHandle, error) {
	if t.MokuHistory {
		return nil, errors.New("Moku history is read-only and cannot reopen a native session")
	}
	if err := r.operational(); err != nil {
		return nil, err
	}
	r.mu.Lock()
	cached := r.handles[t.ID]
	generation := r.generation
	generationCtx := r.generationCtx
	deleting := r.deleting[t.ID]
	r.mu.Unlock()
	if deleting {
		return nil, errors.New("thread deletion is in progress")
	}
	if cached != nil {
		if err := cached.active(); err != nil {
			return nil, err
		}
		return cached, nil
	}
	ctx, stopOperation := r.operationContext(ctx)
	defer stopOperation()
	h, err := r.harness(ctx, t)
	if err != nil {
		return nil, err
	}
	if r.config.Workspaces != nil {
		if err := r.config.Workspaces.ValidateThread(ctx, t); err != nil {
			return nil, err
		}
	}
	lifetime, cancel := context.WithCancel(generationCtx)
	owner := &threadHandle{runtime: r, id: t.ID, generation: generation, harness: h, ctx: lifetime, cancel: cancel, changed: make(chan struct{}, 1), opened: make(chan struct{})}
	r.mu.Lock()
	stale := r.closed || r.resetting || r.generation != generation || r.deleting[t.ID] || ctx.Err() != nil
	if !stale {
		r.handles[t.ID] = owner
	}
	r.mu.Unlock()
	if stale {
		cancel()
		return nil, errors.New("thread opening lost runtime ownership")
	}
	stopOpening := context.AfterFunc(ctx, cancel)
	var metadata plugin.MetadataStore
	publicThread := r.config.Store.Snapshot().Has("thread:" + t.ID)
	if publicThread && !t.Moku {
		metadata = metadataStore{owner}
	}
	native, err := h.Open(lifetime, plugin.OpenContext{ThreadID: t.ID, ReadThread: func() model.SessionRecord {
		current, e := r.sessionThread(t.ID)
		if e != nil {
			return t.SessionRecord
		}
		return current.SessionRecord
	}, RequireExplicitSettings: publicThread && !t.Moku, PublishActivity: func(a model.HarnessActivity) {
		if owner.active() == nil {
			r.publishActivity(t.ID, t.HarnessID, a)
		}
	}, SessionState: owner, Metadata: metadata, ExecutionAdmission: owner, TelemetryLedger: ownerLedger{owner, r.Ledger(t.ID)}, ManagedWorkspaceWrite: workspaceGrant{owner}, Injection: injection})
	stopOpening()
	owner.mu.Lock()
	owner.native = native
	owner.mu.Unlock()
	close(owner.opened)
	if err == nil && native == nil {
		err = errors.New("harness opened a nil thread handle")
	}
	r.mu.Lock()
	stale = r.closed || r.resetting || r.generation != generation || r.handles[t.ID] != owner || r.deleting[t.ID] || ctx.Err() != nil || lifetime.Err() != nil
	r.mu.Unlock()
	if err != nil || stale {
		if err == nil {
			err = errors.New("thread opening lost runtime ownership")
		}
		closeErr := owner.close()
		if closeErr == nil {
			r.mu.Lock()
			if r.handles[t.ID] == owner {
				delete(r.handles, t.ID)
			}
			r.mu.Unlock()
		}
		return nil, errors.Join(err, closeErr)
	}
	return owner, nil
}
func (h *threadHandle) Read() json.RawMessage {
	h.stateMu.Lock()
	defer h.stateMu.Unlock()
	if h.ownsState() != nil {
		return json.RawMessage("null")
	}
	t, err := h.runtime.sessionThread(h.id)
	if err != nil {
		return json.RawMessage("null")
	}
	return model.CloneRaw(t.SessionState)
}

var errClosingTerminal = errors.New("discard delayed terminal snapshot from closing owner")

func (h *threadHandle) Commit(ctx context.Context, state json.RawMessage) error {
	return h.commit(ctx, state, "")
}
func (h *threadHandle) commit(ctx context.Context, state json.RawMessage, cancellationID string) error {
	state = model.CloneRaw(state)
	if !json.Valid(state) {
		return errors.New("harness session state is not JSON")
	}
	observation, err := h.harness.SessionState().Project(state)
	if err != nil {
		return err
	}
	if err := validateObservation(observation); err != nil {
		return err
	}
	h.stateMu.Lock()
	defer h.stateMu.Unlock()
	r := h.runtime
	err = r.updateSessionThread(ctx, h.id, func(t *model.ThreadRecord) error {
		if t.MokuHistory {
			return errors.New("Moku history is read-only")
		}
		if err := h.ownsState(); err != nil {
			return err
		}
		if next := observation.LatestExecution; next != nil {
			previous := t.Observation.LatestExecution
			if previous != nil && previous.ExecutionID != next.ExecutionID && !previous.Terminal() {
				return errors.New("cannot replace an active execution")
			}
			if previous != nil && previous.ExecutionID == next.ExecutionID {
				if previous.StartedAt != next.StartedAt {
					return errors.New("execution start time cannot change")
				}
				if previous.Terminal() && !same(previous, next) {
					h.mu.Lock()
					closing := h.closed
					h.mu.Unlock()
					// Close can race a host settlement with a late native one.
					// Drop the entire late snapshot; preserve the canonical
					// terminal and keep rejecting changes from live owners.
					if closing {
						return errClosingTerminal
					}
					return errors.New("terminal execution cannot change")
				}
			}
			if previous == nil || previous.ExecutionID != next.ExecutionID {
				if err := h.active(); err != nil {
					return err
				}
				h.mu.Lock()
				forking := h.forking
				reserved := h.currentExecution
				h.mu.Unlock()
				if forking {
					return errors.New("thread fork is in progress")
				}
				if next.Status != "running" || reserved != next.ExecutionID {
					return errors.New("execution was not reserved by the host")
				}
			}
		} else if t.Observation.LatestExecution != nil {
			return errors.New("cannot discard an execution")
		}
		if t.HarnessID != h.harness.Descriptor().ID {
			return errors.New("session harness identity changed")
		}
		if cancellationID != "" {
			if observation.LatestExecution == nil || observation.LatestExecution.ExecutionID != cancellationID {
				return errors.New("cancellation identity does not match native admission")
			}
			t.CancellationID = cancellationID
		}
		t.SessionState = model.CloneRaw(state)
		t.Observation = observation
		return nil
	})
	if errors.Is(err, errClosingTerminal) {
		return nil
	}
	if err != nil {
		return err
	}
	select {
	case h.changed <- struct{}{}:
	default:
	}
	return nil
}
func (h *threadHandle) Accept(ctx context.Context, project func(string) (json.RawMessage, error)) (string, error) {
	cancellation, releaseCancellation := h.runtime.cancellationState(h.id)
	defer releaseCancellation()
	cancellation.mu.Lock()
	defer cancellation.mu.Unlock()
	if cancellation.cancelling || cancellation.pending() {
		return "", errors.New("thread input admission is pending or cancelling")
	}
	releaseService, err := h.runtime.beginServiceAdmission(false)
	if err != nil {
		return "", err
	}
	defer releaseService()
	h.admissionMu.Lock()
	defer h.admissionMu.Unlock()
	if err := h.active(); err != nil {
		return "", err
	}
	h.mu.Lock()
	forking := h.forking
	before := h.beforeNativeAdmission
	h.mu.Unlock()
	if forking {
		return "", errors.New("thread fork is in progress")
	}
	if h.admission != nil {
		return "", errors.New("thread input admission is pending")
	}
	ctx, cancel := h.operationContext(ctx)
	defer cancel()
	if err := h.active(); err != nil {
		return "", errors.New("native execution owner closed")
	}
	if before != nil {
		if err := before(ctx); err != nil {
			return "", err
		}
	}
	t, err := h.runtime.sessionThread(h.id)
	if err != nil {
		return "", err
	}
	if t.MokuHistory || archived(&t) {
		return "", errors.New("archived conversations cannot admit native execution")
	}
	if e := t.Observation.LatestExecution; e != nil && !e.Terminal() {
		return "", errors.New("another execution is already active")
	}
	if h.runtime.config.Workspaces != nil {
		if _, err := h.runtime.config.Workspaces.AdmitThread(ctx, t); err != nil {
			return "", err
		}
	}
	id, err := newID()
	if err != nil {
		return "", err
	}
	value, err := project(id)
	if err != nil {
		return "", err
	}
	observation, err := h.harness.SessionState().Project(value)
	if err != nil {
		return "", err
	}
	if observation.LatestExecution == nil || observation.LatestExecution.ExecutionID != id || observation.LatestExecution.Status != "running" {
		return "", errors.New("native admission must durably expose its reserved running execution")
	}
	cancellation.id, cancellation.executionID = id, id
	h.mu.Lock()
	h.currentExecution = id
	h.mu.Unlock()
	if err = h.commit(ctx, value, id); err != nil {
		h.mu.Lock()
		if h.currentExecution == id {
			h.currentExecution = ""
		}
		h.mu.Unlock()
		return "", err
	}
	return id, nil
}
func (h *threadHandle) close() error {
	h.closeOnce.Do(func() {
		h.mu.Lock()
		h.closed = true
		h.cancel()
		h.mu.Unlock()
		<-h.opened
		if h.native != nil {
			h.closeErr = h.native.Close()
		}
		h.workers.Wait()
		h.stateMu.Lock()
		h.disposed = true
		h.stateMu.Unlock()
	})
	return h.closeErr
}

func (r *Runtime) settleClosed(owner *threadHandle) {
	thread, err := r.sessionThread(owner.id)
	if err != nil {
		return
	}
	execution := thread.Observation.LatestExecution
	if execution == nil || execution.Terminal() {
		return
	}
	state, err := owner.harness.SessionState().Settle(plugin.SettleRequest{SessionState: thread.SessionState, ExecutionID: execution.ExecutionID, Outcome: "interrupted", FinishedAt: time.Now().UnixMilli()})
	if err != nil {
		r.log("thread.close.settle", err)
		return
	}
	observation, err := owner.harness.SessionState().Project(state)
	if err != nil {
		r.log("thread.close.project", err)
		return
	}
	r.log("thread.close.persist", r.updateSessionThread(context.WithoutCancel(r.ctx), owner.id, func(t *model.ThreadRecord) error {
		if e := t.Observation.LatestExecution; e == nil || e.ExecutionID != execution.ExecutionID || e.Terminal() {
			return nil
		}
		t.SessionState = state
		t.Observation = observation
		return nil
	}))
}

type metadataStore struct{ owner *threadHandle }

func (s metadataStore) Read() plugin.MetadataSnapshot {
	s.owner.stateMu.Lock()
	defer s.owner.stateMu.Unlock()
	if s.owner.ownsState() != nil {
		return plugin.MetadataSnapshot{}
	}
	t, err := s.owner.runtime.Thread(s.owner.id)
	if err != nil {
		return plugin.MetadataSnapshot{}
	}
	revision := int64(0)
	if t.MetadataRevision != nil {
		revision = *t.MetadataRevision
	}
	return plugin.MetadataSnapshot{Revision: revision, State: model.CloneRaw(t.MetadataState)}
}
func (s metadataStore) Commit(ctx context.Context, expected int64, state json.RawMessage) (bool, error) {
	state = model.CloneRaw(state)
	if expected < 0 || !json.Valid(state) {
		return false, errors.New("invalid thread metadata commit")
	}
	title, err := s.owner.harness.Metadata().Project(state)
	if err != nil {
		return false, err
	}
	s.owner.stateMu.Lock()
	defer s.owner.stateMu.Unlock()
	saved := false
	err = s.owner.runtime.UpdateThread(ctx, s.owner.id, func(t *model.ThreadRecord) error {
		if err := s.owner.ownsState(); err != nil {
			return err
		}
		revision := int64(0)
		if t.MetadataRevision != nil {
			revision = *t.MetadataRevision
		}
		if revision != expected {
			return errMetadataConflict
		}
		revision++
		t.MetadataRevision = &revision
		t.MetadataState = model.CloneRaw(state)
		t.Title = title
		saved = true
		return nil
	})
	if errors.Is(err, errMetadataConflict) {
		return false, nil
	}
	return saved, err
}

var errMetadataConflict = errors.New("thread metadata revision conflict")

type telemetryLedger struct {
	runtime *Runtime
	id      string
}

type ownerLedger struct {
	owner  *threadHandle
	ledger plugin.TelemetryLedger
}

func (l ownerLedger) Read(ctx context.Context) (json.RawMessage, error) {
	l.owner.stateMu.Lock()
	defer l.owner.stateMu.Unlock()
	if err := l.owner.ownsState(); err != nil {
		return nil, err
	}
	return l.ledger.Read(ctx)
}

func (l ownerLedger) Record(ctx context.Context, value json.RawMessage) error {
	l.owner.stateMu.Lock()
	defer l.owner.stateMu.Unlock()
	if err := l.owner.ownsState(); err != nil {
		return err
	}
	return l.ledger.Record(ctx, model.CloneRaw(value))
}

func (t telemetryLedger) Read(ctx context.Context) (json.RawMessage, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	raw, ok := t.runtime.config.Store.Snapshot().Raw("telemetry:" + t.id)
	if !ok {
		return json.RawMessage(`{}`), nil
	}
	return raw, nil
}
func (t telemetryLedger) Record(ctx context.Context, value json.RawMessage) error {
	_, err := t.runtime.config.Store.Update(ctx, func(tx *store.Tx) error { return tx.PutRaw("telemetry:"+t.id, value) })
	return err
}

func (r *Runtime) CreateThread(ctx context.Context, request CreateThreadRequest) (CreatedThread, error) {
	if err := r.begin(); err != nil {
		return CreatedThread{}, err
	}
	defer r.operations.Done()
	ctx, cancelOperation := r.operationContext(ctx)
	defer cancelOperation()
	if err := validateInput(request.Input); err != nil {
		return CreatedThread{}, err
	}
	id, err := newID()
	if err != nil {
		return CreatedThread{}, err
	}
	cwd := request.Cwd
	var preparation *workspaces.Preparation
	durable := false
	defer func() {
		if durable {
			return
		}
		cleanup := context.WithoutCancel(ctx)
		if preparation != nil && r.config.Workspaces != nil {
			r.log("thread.create.worktree.rollback", r.config.Workspaces.Discard(cleanup, *preparation))
		}
		if request.Cwd == "" && cwd != "" && r.config.Workspaces != nil {
			r.log("thread.create.temporary.rollback", r.config.Workspaces.DiscardTemporary(cleanup, cwd))
		}
	}()
	if cwd == "" {
		if r.config.Workspaces != nil {
			cwd, err = r.config.Workspaces.CreateTemporary(ctx)
		} else {
			cwd, err = os.MkdirTemp(filepath.Join(r.config.DataDir, "workspaces"), "thread-")
			if errors.Is(err, os.ErrNotExist) {
				if err = os.MkdirAll(filepath.Join(r.config.DataDir, "workspaces"), 0700); err == nil {
					cwd, err = os.MkdirTemp(filepath.Join(r.config.DataDir, "workspaces"), "thread-")
				}
			}
			if err != nil {
				return CreatedThread{}, err
			}
		}
	} else {
		cwd, err = validateCwd(cwd)
		if err != nil {
			return CreatedThread{}, err
		}
	}
	if request.Worktree != nil && request.Worktree.Enabled != nil && *request.Worktree.Enabled {
		if request.Cwd == "" {
			return CreatedThread{}, errors.New("managed worktree requires an explicit base directory")
		}
		if r.config.Workspaces == nil {
			return CreatedThread{}, errors.New("managed workspace authority unavailable")
		}
		p, e := r.config.Workspaces.PrepareForStart(ctx, cwd, id, request.Worktree, nil)
		if e != nil {
			return CreatedThread{}, e
		}
		preparation = &p
	}
	record := model.ThreadRecord{SessionRecord: model.SessionRecord{ID: id, HarnessID: request.HarnessID, SessionState: json.RawMessage("null"), Settings: model.CloneRaw(request.Settings), Cwd: cwd, CreatedAt: time.Now().UnixMilli(), UpdatedAt: time.Now().UnixMilli()}, Tags: []string{}, TagEmojis: map[string]string{}, Moku: request.Moku, Transcript: []json.RawMessage{}}
	if preparation != nil {
		record.Worktree = &preparation.Worktree
	}
	if request.ResolveSettings != nil {
		record.Settings, err = request.ResolveSettings(ctx, cwd)
		if err != nil {
			return CreatedThread{}, err
		}
	}
	h, err := r.harness(ctx, record)
	if err != nil {
		return CreatedThread{}, err
	}
	settings, _, err := r.Settings()
	if err != nil {
		return CreatedThread{}, err
	}
	if len(record.Settings) == 0 {
		defaults, defaultsErr := h.Settings().DefaultThread(settings.Harnesses[request.HarnessID])
		if defaultsErr != nil {
			return CreatedThread{}, defaultsErr
		}
		record.Settings, err = h.Settings().ResolveThread(ctx, plugin.ResolveSettingsRequest{Merged: defaults, Cwd: cwd})
		if err != nil {
			return CreatedThread{}, err
		}
	}
	record.MetadataState, err = h.Metadata().Initialize(id, request.Input, record.Settings)
	if err != nil {
		return CreatedThread{}, err
	}
	record.Title, err = h.Metadata().Project(record.MetadataState)
	if err != nil {
		return CreatedThread{}, err
	}
	zero := int64(0)
	record.MetadataRevision = &zero
	archived := false
	record.Archived = &archived
	_, err = r.config.Store.Update(ctx, func(tx *store.Tx) error {
		if err := tx.Put("thread:"+id, record); err != nil {
			return err
		}
		if err := r.threadEvents(tx, nil, &record); err != nil {
			return err
		}
		return tx.SetOrder("threads", append(tx.Order("threads"), id))
	})
	if err != nil {
		return CreatedThread{}, err
	}
	durable = true
	r.refreshScopeAgents(ctx)
	created := func(record model.ThreadRecord, execution SendResult, ack json.RawMessage) CreatedThread {
		result := CreatedThread{Record: record, Execution: execution, Acknowledgement: ack}
		if preparation != nil {
			result.WorktreeName = preparation.WorktreeName
			result.WorktreeNameAdjusted = preparation.WorktreeNameAdjusted
			result.WorktreeNameNotice = preparation.WorktreeNameNotice
		}
		return result
	}
	ctx, releaseClaim, err := r.claimSend(ctx, id)
	if err != nil {
		return created(record, SendResult{}, nil), err
	}
	defer releaseClaim()
	lock := r.threadLock(id)
	lock.Lock()
	result, err := r.sendLocked(ctx, id, request.Input, request.Injection, nil)
	lock.Unlock()
	if err != nil {
		return created(record, SendResult{}, nil), err
	}
	record, err = r.Thread(id)
	ack, _ := json.Marshal(map[string]any{"threadId": id, "harnessId": request.HarnessID, "title": record.Title, "executionId": result.ExecutionID})
	return created(record, result, ack), err
}
func (r *Runtime) SendThread(ctx context.Context, id string, input model.AgentInput) (SendResult, error) {
	return r.sendThread(ctx, id, input, false)
}

// Only the public follow-up command represents direct user communication.
// Moku tools and background capabilities continue to use SendThread.
func (r *Runtime) sendThread(ctx context.Context, id string, input model.AgentInput, user bool) (SendResult, error) {
	if user {
		ctx = context.WithValue(ctx, userThreadInputKey{}, true)
	}
	thread, err := r.Thread(id)
	if err != nil {
		return SendResult{}, err
	}
	if thread.Moku {
		return SendResult{}, errors.New("Moku input must be routed through its coordinator")
	}
	if err := r.begin(); err != nil {
		return SendResult{}, err
	}
	defer r.operations.Done()
	ctx, cancelOperation := r.operationContext(ctx)
	defer cancelOperation()
	if err := validateInput(input); err != nil {
		return SendResult{}, err
	}
	ctx, releaseClaim, err := r.claimSend(ctx, id)
	if err != nil {
		return SendResult{}, err
	}
	defer releaseClaim()
	lock := r.threadLock(id)
	lock.Lock()
	defer lock.Unlock()
	return r.sendLocked(ctx, id, input, nil, nil)
}
func (r *Runtime) SendThreadWithContext(ctx context.Context, id string, input model.AgentInput, entries []plugin.ContextEntry) (SendResult, error) {
	thread, err := r.Thread(id)
	if err != nil {
		return SendResult{}, err
	}
	if thread.Moku {
		return SendResult{}, errors.New("Moku input must be routed through its coordinator")
	}
	if err := r.begin(); err != nil {
		return SendResult{}, err
	}
	defer r.operations.Done()
	ctx, cancelOperation := r.operationContext(ctx)
	defer cancelOperation()
	if err := validateInput(input); err != nil {
		return SendResult{}, err
	}
	ctx, releaseClaim, err := r.claimSend(ctx, id)
	if err != nil {
		return SendResult{}, err
	}
	defer releaseClaim()
	lock := r.threadLock(id)
	lock.Lock()
	defer lock.Unlock()
	return r.sendLocked(ctx, id, input, nil, entries)
}
func (r *Runtime) sendLocked(ctx context.Context, id string, input model.AgentInput, injection *plugin.Injection, entries []plugin.ContextEntry) (SendResult, error) {
	return r.sendLockedAdmitted(ctx, id, input, injection, entries, nil)
}
func (r *Runtime) sendLockedAdmitted(ctx context.Context, id string, input model.AgentInput, injection *plugin.Injection, entries []plugin.ContextEntry, onAdmitted func(SendResult) error) (SendResult, error) {
	ctx, releaseClaim, err := r.claimSend(ctx, id)
	if err != nil {
		return SendResult{}, err
	}
	defer releaseClaim()
	if err := r.operational(); err != nil {
		return SendResult{}, err
	}
	if err := ctx.Err(); err != nil {
		return SendResult{}, err
	}
	if r.IsDeleting(id) {
		return SendResult{}, errors.New("thread deletion is in progress")
	}
	t, err := r.sessionThread(id)
	if err != nil {
		return SendResult{}, err
	}
	if t.MokuHistory || t.Archived != nil && *t.Archived {
		return SendResult{}, errors.New("thread is archived")
	}
	if _, err := validateCwd(effectiveCwd(t)); err != nil {
		return SendResult{}, err
	}
	if r.config.Workspaces != nil {
		if _, err := r.config.Workspaces.AdmitThread(ctx, t); err != nil {
			return SendResult{}, err
		}
	}
	if r.config.Attachments != nil {
		input, err = r.config.Attachments.RetainInput(ctx, id, input)
		if err != nil {
			return SendResult{}, err
		}
	}
	owner, err := r.openThread(ctx, t, injection)
	if err != nil {
		return SendResult{}, err
	}
	cancellation, releaseCancellation := r.cancellationState(id)
	defer releaseCancellation()
	cancellation.mu.Lock()
	if cancellation.cancelling || ctx.Err() != nil {
		cancellation.mu.Unlock()
		return SendResult{}, model.NewError("EXECUTION_CANCELLING", "The observed execution is being stopped")
	}
	owner.admissionMu.Lock()
	unlockAdmission := func() { owner.admissionMu.Unlock(); cancellation.mu.Unlock() }
	if err := owner.active(); err != nil {
		unlockAdmission()
		return SendResult{}, err
	}
	if owner.admission != nil {
		unlockAdmission()
		return SendResult{}, errors.New("thread input admission is pending")
	}
	executionID := ""
	started := true
	t, err = r.sessionThread(id)
	if err != nil {
		unlockAdmission()
		return SendResult{}, err
	}
	if e := t.Observation.LatestExecution; e != nil && !e.Terminal() {
		if e.Status == "waiting-for-user" {
			unlockAdmission()
			return SendResult{}, errors.New("respond to the pending interaction before sending another message")
		}
		executionID = e.ExecutionID
		started = false
	} else {
		executionID, err = newID()
		if err != nil {
			unlockAdmission()
			return SendResult{}, err
		}
	}
	releaseService, err := r.beginServiceAdmission(!started)
	if err != nil {
		unlockAdmission()
		return SendResult{}, err
	}
	defer releaseService()
	if started && cancellation.executionID != "" {
		cancellation.id = executionID
		if err = r.updateSessionThread(ctx, id, func(t *model.ThreadRecord) error { t.CancellationID = executionID; return nil }); err != nil {
			unlockAdmission()
			return SendResult{}, err
		}
	}
	cancellation.executionID = executionID
	admission := &sendAdmission{executionID: executionID, result: SendResult{ExecutionID: executionID, StartedNewExecution: started}, callback: onAdmitted, done: make(chan struct{})}
	owner.mu.Lock()
	owner.currentExecution = executionID
	owner.mu.Unlock()
	owner.admission = admission
	unlockAdmission()
	defer func() {
		owner.admissionMu.Lock()
		if owner.admission == admission {
			owner.admission = nil
		}
		owner.admissionMu.Unlock()
	}()
	sendCtx, cancelSend := context.WithCancel(owner.ctx)
	stopCaller := context.AfterFunc(ctx, cancelSend)
	defer stopCaller()
	finishAdmission := func(cause error, accept bool) error {
		admission.once.Do(func() {
			admission.err = cause
			if accept {
				if admission.err = owner.active(); admission.err == nil {
					current, e := r.sessionThread(id)
					if e != nil {
						admission.err = e
					} else if latest := current.Observation.LatestExecution; latest == nil || latest.ExecutionID != executionID {
						admission.err = errors.New("input admission did not expose reserved execution")
					}
				}
				if admission.err == nil {
					admission.err = sendCtx.Err()
				}
				if admission.err == nil && admission.callback != nil {
					admission.err = admission.callback(admission.result)
				}
				if admission.err == nil && !t.Moku && r.config.Store.Snapshot().Has("thread:"+id) {
					_, admission.err = r.config.Store.Update(sendCtx, func(tx *store.Tx) error {
						if err := owner.active(); err != nil {
							return err
						}
						if !tx.Has("thread:" + id) {
							return errors.New("thread disappeared during input admission")
						}
						source := "application"
						var data any = input
						if direct, _ := ctx.Value(userThreadInputKey{}).(bool); direct {
							source = "user"
							data = model.UserThreadInput{AgentInput: input, ExecutionID: executionID, StartedNewExecution: started}
						}
						return r.appendEvent(tx, "thread.input-accepted", store.Subject{Kind: "thread", ID: id, TypeID: "agent"}, source, data, nil)
					})
				}
			}
			if accept && admission.err == nil {
				admission.err = r.markInputAdmitted(ctx)
			}
			owner.admissionMu.Lock()
			if owner.admission == admission {
				owner.admission = nil
			}
			owner.admissionMu.Unlock()
			close(admission.done)
		})
		<-admission.done
		return admission.err
	}
	request := plugin.SendRequest{ExecutionID: executionID, Input: input, ContextEntries: entries, Admitted: func() error { return finishAdmission(nil, true) }}
	owner.mu.Lock()
	if owner.closed {
		owner.mu.Unlock()
		cancelSend()
		return SendResult{}, errors.New("thread handle is closed")
	}
	owner.workers.Add(1)
	owner.activeSends++
	if owner.sendCancels == nil {
		owner.sendCancels = map[*sendAdmission]context.CancelFunc{}
	}
	owner.sendCancels[admission] = cancelSend
	owner.mu.Unlock()
	go func() {
		defer owner.workers.Done()
		defer func() {
			owner.mu.Lock()
			owner.activeSends--
			delete(owner.sendCancels, admission)
			owner.mu.Unlock()
		}()
		var err error
		if attempt, ok := ctx.Value(mokuDeliveryAttemptKey{}).(func() error); ok {
			err = attempt()
		}
		if err == nil {
			err = owner.native.Send(sendCtx, request)
		}
		// Only an untouched, unadmitted input may move to a new reservation.
		// Exact equality deliberately excludes joined failures.
		if err == plugin.ErrExecutionEnded && !started {
			select {
			case <-admission.done:
			default:
				var nextID string
				nextID, err = r.renewSendAdmission(sendCtx, owner, admission)
				if err == nil {
					executionID, started = nextID, true
					request.ExecutionID = nextID
					err = owner.native.Send(sendCtx, request)
				}
			}
		}
		if err != nil {
			cancelSend()
			_ = finishAdmission(err, false)
			if started {
				r.settleSendFailure(owner, executionID, err)
			}
			return
		}
		select {
		case <-admission.done:
		default:
			cancelSend()
			err = errors.New("harness returned without acknowledging input admission")
			_ = finishAdmission(err, false)
			if started {
				r.settleSendFailure(owner, executionID, err)
			}
		}
	}()
	select {
	case <-admission.done:
		if admission.err != nil {
			return SendResult{}, admission.err
		}
		// The acknowledgement is the proof. A fast native wake may already
		// have published a successor, so do not require it still be latest.
		return admission.result, nil
	case <-ctx.Done():
		cancelSend()
		return SendResult{}, ctx.Err()
	case <-owner.ctx.Done():
		cancelSend()
		return SendResult{}, owner.ctx.Err()
	}
}

func (r *Runtime) renewSendAdmission(ctx context.Context, owner *threadHandle, admission *sendAdmission) (string, error) {
	cancellation, releaseCancellation := r.cancellationState(owner.id)
	defer releaseCancellation()
	cancellation.mu.Lock()
	defer cancellation.mu.Unlock()
	if cancellation.cancelling {
		return "", model.NewError("EXECUTION_CANCELLING", "The observed execution is being stopped")
	}
	releaseService, err := r.beginServiceAdmission(false)
	if err != nil {
		return "", err
	}
	defer releaseService()
	owner.admissionMu.Lock()
	defer owner.admissionMu.Unlock()
	if err := ctx.Err(); err != nil {
		return "", err
	}
	if err := owner.active(); err != nil {
		return "", err
	}
	if owner.admission != admission {
		return "", errors.New("input admission is no longer pending")
	}
	t, err := r.sessionThread(owner.id)
	if err != nil {
		return "", err
	}
	if e := t.Observation.LatestExecution; e == nil || e.ExecutionID != admission.executionID || !e.Terminal() {
		return "", errors.New("ended execution has no durable terminal outcome")
	}
	id, err := newID()
	if err != nil {
		return "", err
	}
	if err = r.updateSessionThread(ctx, owner.id, func(t *model.ThreadRecord) error { t.CancellationID = id; return nil }); err != nil {
		return "", err
	}
	cancellation.id, cancellation.executionID = id, id
	admission.executionID = id
	admission.result = SendResult{ExecutionID: id, StartedNewExecution: true}
	owner.mu.Lock()
	owner.currentExecution = id
	owner.mu.Unlock()
	return id, nil
}

func (r *Runtime) settleSendFailure(owner *threadHandle, id string, cause error) {
	t, err := r.sessionThread(owner.id)
	if err != nil {
		return
	}
	execution := t.Observation.LatestExecution
	if execution == nil || execution.ExecutionID != id || execution.Terminal() {
		return
	}
	outcome := "failed"
	if errors.Is(cause, context.Canceled) {
		outcome = "interrupted"
	}
	state, err := owner.harness.SessionState().Settle(plugin.SettleRequest{SessionState: t.SessionState, ExecutionID: id, Outcome: outcome, FinishedAt: time.Now().UnixMilli()})
	if err == nil {
		err = owner.Commit(context.WithoutCancel(r.ctx), state)
	}
	r.log("thread.send.settle", err)
}
func (r *Runtime) InterruptThread(ctx context.Context, id string) error {
	r.cancelSendClaims(id)
	r.mu.Lock()
	existing := r.handles[id]
	closing := r.closed || r.resetting
	r.mu.Unlock()
	if closing && existing != nil {
		return existing.interrupt(ctx)
	}
	if err := r.begin(); err != nil {
		return err
	}
	defer r.operations.Done()
	ctx, cancelOperation := r.operationContext(ctx)
	defer cancelOperation()
	t, err := r.Thread(id)
	if err != nil {
		return err
	}
	r.mu.Lock()
	owner := r.handles[id]
	r.mu.Unlock()
	if owner == nil {
		lock := r.threadLock(id)
		lock.Lock()
		t, err = r.Thread(id)
		if err != nil {
			lock.Unlock()
			return err
		}
		if (t.Observation.LatestExecution == nil || t.Observation.LatestExecution.Terminal()) && t.Observation.BackgroundWork == nil {
			lock.Unlock()
			return nil
		}
		owner, err = r.openThread(ctx, t, nil)
		lock.Unlock()
		if err != nil {
			return err
		}
	}
	return owner.interrupt(ctx)
}

func (h *threadHandle) interrupt(ctx context.Context) error {
	h.mu.Lock()
	for _, cancel := range h.sendCancels {
		cancel()
	}
	h.mu.Unlock()
	select {
	case <-h.opened:
	default:
		// Interrupt must also stop a native opening whose send has not entered
		// the adapter yet; waiting for the command lock would miss that claim.
		h.cancel()
	}
	select {
	case <-h.opened:
		if h.native == nil {
			return nil
		}
		return h.native.Interrupt(ctx)
	case <-ctx.Done():
		return ctx.Err()
	}
}
func (r *Runtime) ReadThread(ctx context.Context, id, question string) (string, error) {
	if err := r.begin(); err != nil {
		return "", err
	}
	defer r.operations.Done()
	ctx, cancelOperation := r.operationContext(ctx)
	defer cancelOperation()
	if strings.TrimSpace(question) == "" || model.UTF16Length(question) > 1_000_000 {
		return "", errors.New("thread question is empty or too long")
	}
	lock := r.threadLock(id)
	lock.Lock()
	defer lock.Unlock()
	t, err := r.Thread(id)
	if err != nil {
		return "", err
	}
	if t.Moku || t.MokuHistory {
		return "", errors.New("Moku conversations cannot start a native history question")
	}
	owner, err := r.openThread(ctx, t, nil)
	if err != nil {
		return "", err
	}
	ctx, cancelOwner := owner.operationContext(ctx)
	defer cancelOwner()
	return owner.native.Read(ctx, question)
}
func (r *Runtime) RespondThread(ctx context.Context, id string, response model.RespondRequest) error {
	if err := r.begin(); err != nil {
		return err
	}
	defer r.operations.Done()
	ctx, cancelOperation := r.operationContext(ctx)
	defer cancelOperation()
	if err := identifier(response.InteractionID); err != nil {
		return err
	}
	if err := identifier(response.ActionID); err != nil {
		return err
	}
	lock := r.threadLock(id)
	lock.Lock()
	defer lock.Unlock()
	t, err := r.Thread(id)
	if err != nil {
		return err
	}
	execution := t.Observation.LatestExecution
	if execution == nil || execution.Status != "waiting-for-user" || response.ExecutionID != "" && response.ExecutionID != execution.ExecutionID {
		return model.NewError("INTERACTION_STALE", "This interaction has already been handled or is no longer pending")
	}
	valid := false
	for _, interaction := range execution.Interactions {
		if interaction.ID != response.InteractionID {
			continue
		}
		for _, action := range interaction.Actions {
			if action.ID == response.ActionID {
				valid = true
				if action.Intent == "submit" {
					checked := model.ValidatePublicInteractionAnswers(interaction, response.Answers)
					if !checked.Valid {
						return fmt.Errorf("invalid interaction answers: %v", checked.Errors)
					}
					response.Answers = checked.Answers
					response.ValidatedFormValues = checked.ValidatedFormValues
				}
			}
		}
	}
	if !valid {
		return model.NewError("INTERACTION_STALE", "This interaction has already been handled or is no longer pending")
	}
	owner, err := r.openThread(ctx, t, nil)
	if err != nil {
		return err
	}
	ctx, cancelOwner := owner.operationContext(ctx)
	defer cancelOwner()
	if err := r.claimInteractionAnswer(ctx, id, execution.ExecutionID, response.InteractionID); err != nil {
		return err
	}
	response.ExecutionID = execution.ExecutionID
	err = owner.native.Respond(ctx, response)
	var rejected *plugin.InteractionResponseNotSentError
	if errors.As(err, &rejected) {
		// Only an adapter's explicit pre-I/O rejection permits a new attempt.
		// Unknown native outcomes retain their claim to prevent duplicate replies.
		if releaseErr := r.releaseInteractionAnswer(context.WithoutCancel(ctx), id, execution.ExecutionID, response.InteractionID); releaseErr != nil {
			return errors.Join(err, releaseErr)
		}
	}
	return err
}
func (r *Runtime) DeleteThread(ctx context.Context, id string) error {
	if err := r.begin(); err != nil {
		return err
	}
	defer r.operations.Done()
	ctx, cancelOperation := r.operationContext(ctx)
	defer cancelOperation()
	initial, err := r.Thread(id)
	if err != nil {
		return err
	}
	if initial.Moku {
		return errors.New("use moku:clear to clear the Moku thread")
	}
	if initial.Observation.BackgroundWork != nil {
		return errors.New("thread has native background work")
	}
	r.mu.Lock()
	if r.deleting[id] {
		r.mu.Unlock()
		return errors.New("thread deletion already in progress")
	}
	r.deleting[id] = true
	r.mu.Unlock()
	defer func() { r.mu.Lock(); delete(r.deleting, id); r.mu.Unlock() }()
	r.cancelSendClaims(id)
	// Close before joining the command queue: an unacknowledged send or read
	// may be holding that queue while awaiting native I/O.
	r.mu.Lock()
	owner := r.handles[id]
	r.mu.Unlock()
	if owner != nil {
		if err := owner.close(); err != nil {
			return err
		}
	}
	lock := r.threadLock(id)
	lock.Lock()
	defer lock.Unlock()
	t, err := r.Thread(id)
	if err != nil {
		return err
	}
	if t.Moku {
		return errors.New("use moku:clear to clear the Moku thread")
	}
	if t.Observation.BackgroundWork != nil {
		return errors.New("thread has native background work")
	}
	_, err = r.config.Store.Update(ctx, func(tx *store.Tx) error {
		var current model.ThreadRecord
		ok, err := tx.Get("thread:"+id, &current)
		if err != nil {
			return err
		}
		if !ok || current.Moku || current.Observation.BackgroundWork != nil {
			return errors.New("thread changed during deletion")
		}
		for _, key := range tx.Keys("interaction-answer:" + id + ":") {
			if err := tx.Delete(key); err != nil {
				return err
			}
		}
		if err := tx.Delete("thread:" + id); err != nil {
			return err
		}
		if err := r.threadEvents(tx, &current, nil); err != nil {
			return err
		}
		ids := []string{}
		for _, value := range tx.Order("threads") {
			if value != id {
				ids = append(ids, value)
			}
		}
		return tx.SetOrder("threads", ids)
	})
	if err != nil {
		return err
	}
	r.mu.Lock()
	if r.handles[id] == owner {
		delete(r.handles, id)
	}
	r.mu.Unlock()
	r.pruneCancellationState(id)
	cleanup := context.WithoutCancel(ctx)
	if r.config.Attachments != nil {
		r.log("thread.delete.attachments", r.config.Attachments.ReleaseOwner(cleanup, id))
	}
	r.log("thread.delete.voice", r.removeThreadVoice(cleanup, id))
	if r.config.Workspaces != nil && t.Worktree != nil {
		r.log("thread.delete.workspace", r.config.Workspaces.Unregister(cleanup, id, t.Worktree))
	}
	// Reports derive their directory labels from live source threads. Refresh
	// after the delete commits so a Report referencing this thread drops the
	// stale task-… label in the same session instead of after a restart.
	r.log("thread.delete.directory_tags", r.RefreshApplicationDirectoryTags(cleanup))
	return nil
}

func (r *Runtime) IsDeleting(id string) bool { r.mu.Lock(); defer r.mu.Unlock(); return r.deleting[id] }

type workspaceGrant struct{ owner *threadHandle }

func (g workspaceGrant) Grant(ctx context.Context) (plugin.ManagedWorkspaceGrant, error) {
	if err := g.owner.active(); err != nil {
		return plugin.ManagedWorkspaceGrant{}, err
	}
	ctx, cancel := g.owner.operationContext(ctx)
	defer cancel()
	if g.owner.runtime.config.Workspaces == nil {
		return plugin.ManagedWorkspaceGrant{}, errors.New("managed workspace authority unavailable")
	}
	thread, err := g.owner.runtime.sessionThread(g.owner.id)
	if err != nil {
		return plugin.ManagedWorkspaceGrant{}, err
	}
	return g.owner.runtime.config.Workspaces.Grant(ctx, thread)
}
func (r *Runtime) StartRecovery() {
	threads, err := r.Threads()
	if err != nil {
		r.log("recovery.read", err)
		return
	}
	for _, t := range threads {
		if t.Moku || t.MokuHistory || r.config.DisabledHarnesses[t.HarnessID] != "" {
			continue
		}
		if t.Observation.LatestExecution == nil || t.Observation.LatestExecution.Terminal() {
			continue
		}
		thread := t
		if err := r.begin(); err != nil {
			return
		}
		go func() {
			defer r.operations.Done()
			lock := r.threadLock(thread.ID)
			lock.Lock()
			defer lock.Unlock()
			current, err := r.Thread(thread.ID)
			if err == nil {
				if current.Observation.LatestExecution == nil || current.Observation.LatestExecution.Terminal() {
					return
				}
				_, err = r.openThread(r.ctx, current, nil)
			}
			r.log("recovery.open", err)
			if err != nil && r.config.Diagnostic != nil && r.operational() == nil && !r.IsDeleting(thread.ID) {
				r.config.Diagnostic(fmt.Sprintf("Agent Thread %s restart recovery failed: %v", thread.ID, err))
			}
		}()
	}
}
func effectiveCwd(t model.ThreadRecord) string {
	if t.Worktree != nil {
		return t.Worktree.Cwd
	}
	return t.Cwd
}
func validateCwd(path string) (string, error) {
	if !filepath.IsAbs(path) || strings.ContainsRune(path, 0) {
		return "", errors.New("workspace path must be absolute")
	}
	canonical, err := filepath.EvalSymlinks(path)
	if err != nil {
		return "", err
	}
	info, err := os.Stat(canonical)
	if err != nil {
		return "", err
	}
	if !info.IsDir() {
		return "", errors.New("workspace path is not a directory")
	}
	return canonical, nil
}
func identifier(value string) error {
	if value == "" || len(value) > 128 || strings.ContainsAny(value, "\x00\r\n\t ") {
		return errors.New("invalid identifier")
	}
	return nil
}
func validateInput(input model.AgentInput) error {
	// The same public union validates internal canonical input after removing
	// host-owned attachment metadata. Internal hidden prompts have no visible
	// presentation tag; all attachment identities and annotations still validate.
	public := input
	if public.Presentation == "internal" {
		public.Presentation = ""
	}
	public.Parts = append([]model.AgentInputPart(nil), input.Parts...)
	for i, part := range public.Parts {
		if part.File != nil {
			public.Parts[i].File = &model.InputFile{ID: part.File.ID}
		}
		if (part.Kind == "mention" || part.Kind == "skill") && (!filepath.IsAbs(part.Path) || strings.ContainsRune(part.Path, 0)) {
			return errors.New("mention and skill paths must be absolute")
		}
	}
	raw, err := json.Marshal(public)
	if err != nil {
		return err
	}
	_, err = model.ParsePublicAgentInput(raw)
	return err
}
func validateObservation(o model.PublicObservation) error {
	return model.ValidatePublicObservation(o)
}

func newID() (string, error) {
	var data [16]byte
	if _, err := rand.Read(data[:]); err != nil {
		return "", err
	}
	data[6] = (data[6] & 0x0f) | 0x40
	data[8] = (data[8] & 0x3f) | 0x80
	hexed := hex.EncodeToString(data[:])
	return hexed[:8] + "-" + hexed[8:12] + "-" + hexed[12:16] + "-" + hexed[16:20] + "-" + hexed[20:], nil
}
