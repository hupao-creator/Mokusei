package main

import (
	"context"
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
	runtimepkg "github.com/hupao-creator/Mokusei/internal/core/runtime"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/services/attachments"
	"github.com/hupao-creator/Mokusei/internal/services/moku"
	"github.com/hupao-creator/Mokusei/internal/services/workspaces"
)

func mokuReplayMust(e error) {
	if e != nil {
		panic(e)
	}
}
func mokuReplayCheck(ok bool, s string) {
	if !ok {
		panic(s)
	}
}
func mokuReplayRaw(v any) json.RawMessage { r, e := json.Marshal(v); mokuReplayMust(e); return r }
func mokuReplayText(s string) moku.SubmitRequest {
	return moku.SubmitRequest{Input: model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: s}}}}
}
func mokuReplayString(s string) *string { return &s }
func mokuReplayWaitError(label string, ch <-chan error) {
	select {
	case e := <-ch:
		mokuReplayMust(e)
	case <-time.After(8 * time.Second):
		panic("timeout " + label)
	}
}
func mokuReplayRemainsBlocked(label string, ch <-chan error) {
	select {
	case e := <-ch:
		panic(fmt.Sprintf("%s completed while admission fenced: %v", label, e))
	case <-time.After(60 * time.Millisecond):
	}
}

type replayNativeHarness struct {
	workspaces       *workspaces.Manager
	mu               sync.Mutex
	r                *runtimepkg.Runtime
	db               *store.Store
	nativeModel      string
	opened           []json.RawMessage
	resolvedCwds     []string
	handles          []*replayNativeHandle
	toolCount        int
	nativeSends      int
	snapshots        int
	probeFn          func(context.Context) error
	describeFn       func(context.Context) error
	probeCalls       int
	describeCalls    int
	gateSnapshot     func(context.Context) error
	gateAdmission    func(context.Context) error
	wake             chan struct{}
	errors           []string
	inputs           []replayNativeInput
	beforeThreadSend func(context.Context) error
	doubleAdmission  bool
}

type replayNativeInput struct {
	threadID    string
	input       model.AgentInput
	executionID string
	context     []plugin.ContextEntry
}

func (h *replayNativeHarness) Descriptor() plugin.HarnessDescriptor {
	return plugin.HarnessDescriptor{ID: "mock", DisplayName: "Runtime mock", ThreadCapabilities: plugin.ThreadCapabilities{Instructions: true, ThreadContext: true, SendContext: true, ToolModes: []string{"exclusive"}}}
}
func (h *replayNativeHarness) DefaultSettings() json.RawMessage {
	return json.RawMessage(`{"useDefaultThreadSettings":false,"threadSettings":{"model":"first-model"}}`)
}
func (h *replayNativeHarness) Detect(context.Context, string) (plugin.Installation, error) {
	return plugin.Installation{Status: "available"}, nil
}
func (h *replayNativeHarness) Probe(ctx context.Context, _ plugin.SettingsRequest, _ string) (plugin.Availability, error) {
	h.mu.Lock()
	h.probeCalls++
	fn := h.probeFn
	h.mu.Unlock()
	if fn != nil {
		if e := fn(ctx); e != nil {
			return plugin.Availability{}, e
		}
	}
	return plugin.Availability{Available: true}, nil
}
func (h *replayNativeHarness) Settings() plugin.HarnessSettings         { return replayNativeSettings{h: h} }
func (h *replayNativeHarness) SessionState() plugin.SessionStateAdapter { return replayNativeState{} }
func (h *replayNativeHarness) Metadata() plugin.ThreadMetadataAdapter   { return replayNativeMetadata{} }
func (h *replayNativeHarness) Open(ctx context.Context, open plugin.OpenContext) (plugin.Handle, error) {
	configuration, e := h.r.ReadMokuConfiguration()
	if e != nil {
		return nil, e
	}
	if configuration.Unapplied || !h.db.Snapshot().Has("moku-applied-settings") {
		return nil, errors.New("native open occurred before applied configuration was durable")
	}
	handle := &replayNativeHandle{h: h, open: open}
	h.mu.Lock()
	h.opened = append(h.opened, model.CloneRaw(open.ReadThread().Settings))
	h.handles = append(h.handles, handle)
	h.mu.Unlock()
	return handle, nil
}
func (h *replayNativeHarness) MokuContext(context.Context, string, plugin.SettingsRequest, plugin.TelemetryLedger) (string, error) {
	return "runtime smoke context", nil
}
func (h *replayNativeHarness) pulse() {
	select {
	case h.wake <- struct{}{}:
	default:
	}
}
func (h *replayNativeHarness) awaitTools(n int) {
	timer := time.NewTimer(8 * time.Second)
	defer timer.Stop()
	for {
		h.mu.Lock()
		count := h.toolCount
		es := append([]string{}, h.errors...)
		h.mu.Unlock()
		if len(es) > 0 {
			panic(strings.Join(es, "; "))
		}
		if count >= n {
			return
		}
		select {
		case <-h.wake:
		case <-timer.C:
			panic("timed out waiting for native tools")
		}
	}
}

type replayNativeSettings struct{ h *replayNativeHarness }

func (s replayNativeSettings) Normalize(r json.RawMessage) (json.RawMessage, error) {
	_, e := model.DecodeObject(r)
	return model.CloneRaw(r), e
}
func (s replayNativeSettings) SnapshotExecution(ctx context.Context, r plugin.SettingsRequest, initial bool) (json.RawMessage, error) {
	s.h.mu.Lock()
	s.h.snapshots++
	gate := s.h.gateSnapshot
	s.h.gateSnapshot = nil
	modelID := s.h.nativeModel
	s.h.mu.Unlock()
	if gate != nil {
		if e := gate(ctx); e != nil {
			return nil, e
		}
	}
	return mokuReplayRaw(map[string]any{"useDefaultThreadSettings": false, "threadSettings": map[string]any{"model": modelID}}), nil
}
func (s replayNativeSettings) Describe(ctx context.Context, _ plugin.SettingsRequest) (json.RawMessage, error) {
	s.h.mu.Lock()
	s.h.describeCalls++
	fn := s.h.describeFn
	s.h.mu.Unlock()
	if fn != nil {
		if e := fn(ctx); e != nil {
			return nil, e
		}
	}
	return json.RawMessage(`{"type":"object","properties":{"model":{"type":"string"}},"required":["model"],"additionalProperties":false}`), nil
}
func (s replayNativeSettings) DefaultThread(r json.RawMessage) (json.RawMessage, error) {
	var envelope struct {
		ThreadSettings json.RawMessage `json:"threadSettings"`
	}
	if err := json.Unmarshal(r, &envelope); err != nil {
		return nil, err
	}
	if len(envelope.ThreadSettings) == 0 {
		return nil, errors.New("expected harness settings envelope")
	}
	return model.CloneRaw(envelope.ThreadSettings), nil
}
func (s replayNativeSettings) ResolveThread(_ context.Context, r plugin.ResolveSettingsRequest) (json.RawMessage, error) {
	var defaults struct {
		Model string `json:"model"`
	}
	if err := model.Unmarshal(r.Merged, &defaults); err != nil {
		return nil, fmt.Errorf("expected projected thread defaults: %w", err)
	}
	if len(r.Requested) > 0 {
		s.h.mu.Lock()
		s.h.resolvedCwds = append(s.h.resolvedCwds, r.Cwd)
		s.h.mu.Unlock()
		return model.CloneRaw(r.Requested), nil
	}
	return model.CloneRaw(r.Merged), nil
}
func (s replayNativeSettings) HasThreadContent(r json.RawMessage) bool { return !model.IsNull(r) }
func (s replayNativeSettings) ApplyThreadUpdate(_ context.Context, r plugin.UpdateSettingsRequest) (json.RawMessage, error) {
	return model.CloneRaw(r.Update), nil
}
func (s replayNativeSettings) PromptSettings(a, b json.RawMessage) (json.RawMessage, error) {
	return model.CloneRaw(a), nil
}
func (s replayNativeSettings) Presentation(context.Context, plugin.SettingsPresentationRequest) (json.RawMessage, error) {
	return json.RawMessage(`{}`), nil
}

type replayNativeState struct{}

func (replayNativeState) Project(r json.RawMessage) (model.PublicObservation, error) {
	if model.IsNull(r) {
		return model.PublicObservation{}, nil
	}
	var o model.PublicObservation
	e := model.Unmarshal(r, &o)
	return o, e
}
func (replayNativeState) ProjectRenderer(r json.RawMessage, _ model.RendererScope) (json.RawMessage, error) {
	if model.IsNull(r) {
		return json.RawMessage(`{}`), nil
	}
	return model.CloneRaw(r), nil
}
func (replayNativeState) ReadContext(r json.RawMessage) (json.RawMessage, error) {
	return json.RawMessage(`{}`), nil
}
func (replayNativeState) ResolveExecution(r json.RawMessage, id string) (*model.PublicExecution, error) {
	o, e := (replayNativeState{}).Project(r)
	if o.LatestExecution != nil && o.LatestExecution.ExecutionID != id {
		return nil, e
	}
	return o.LatestExecution, e
}
func (replayNativeState) Settle(r plugin.SettleRequest) (json.RawMessage, error) {
	o, e := (replayNativeState{}).Project(r.SessionState)
	if e != nil {
		return nil, e
	}
	if o.LatestExecution != nil && o.LatestExecution.ExecutionID == r.ExecutionID {
		o.LatestExecution.Status = r.Outcome
		o.LatestExecution.FinishedAt = &r.FinishedAt
	}
	return mokuReplayRaw(o), nil
}

type replayNativeMetadata struct{}

func (replayNativeMetadata) Initialize(_ string, input model.AgentInput, _ json.RawMessage) (json.RawMessage, error) {
	return mokuReplayRaw(map[string]string{"title": input.Parts[0].Text}), nil
}
func (replayNativeMetadata) Project(r json.RawMessage) (string, error) {
	var v map[string]string
	e := json.Unmarshal(r, &v)
	return v["title"], e
}
func (replayNativeMetadata) Fork(r json.RawMessage, title string) (json.RawMessage, error) {
	return mokuReplayRaw(map[string]string{"title": title}), nil
}

type replayNativeHandle struct {
	h    *replayNativeHarness
	open plugin.OpenContext
}

func (n *replayNativeHandle) Send(ctx context.Context, req plugin.SendRequest) error {
	current := n.open.ReadThread()
	thread, err := n.h.r.Thread(n.open.ThreadID)
	if err != nil {
		return err
	}
	n.h.mu.Lock()
	before := n.h.beforeThreadSend
	doubleAdmission := n.h.doubleAdmission
	n.h.mu.Unlock()
	if !thread.Moku && before != nil {
		if err := before(ctx); err != nil {
			return err
		}
	}
	o := current.Observation
	if o.LatestExecution == nil || o.LatestExecution.ExecutionID != req.ExecutionID {
		o.LatestExecution = &model.PublicExecution{ExecutionID: req.ExecutionID, Status: "running", StartedAt: time.Now().UnixMilli()}
	}
	if e := n.open.SessionState.Commit(ctx, mokuReplayRaw(o)); e != nil {
		return e
	}
	if req.Admitted == nil {
		return errors.New("missing explicit admission callback")
	}
	if e := req.Admitted(); e != nil {
		return e
	}
	if doubleAdmission {
		if e := req.Admitted(); e != nil {
			return e
		}
	}
	n.h.mu.Lock()
	n.h.inputs = append(n.h.inputs, replayNativeInput{threadID: n.open.ThreadID, input: orchestratorCopyJSON(req.Input), executionID: req.ExecutionID, context: append([]plugin.ContextEntry(nil), req.ContextEntries...)})
	n.h.mu.Unlock()
	n.h.pulse()
	// This reads committed SQLite snapshot authority, not an in-memory mock row.
	var committed model.ThreadRecord
	ok, e := n.h.db.Snapshot().Get("thread:"+n.open.ThreadID, &committed)
	if e != nil || !ok {
		return errors.New("durable thread missing")
	}
	if !committed.Moku {
		// Ordinary delegated work has native persistence but no Moku-only tools.
		return nil
	}
	if req.Input.Presentation != "internal" {
		found := false
		for _, item := range committed.Transcript {
			var v map[string]any
			mokuReplayMust(json.Unmarshal(item, &v))
			if v["type"] == "message" && v["role"] == "user" && v["content"] == req.Input.Parts[0].Text {
				found = true
			}
		}
		if !found {
			return errors.New("native dispatch lacks durable user transcript")
		}
	}
	for _, tool := range n.open.Injection.Tools.Bindings {
		if tool.Name == "talk" {
			if _, e := tool.Execute(ctx, plugin.ToolCall{CallID: "native-token", Arguments: mokuReplayRaw(map[string]string{"text": "durable input received"})}); e != nil {
				return e
			}
			n.h.mu.Lock()
			n.h.toolCount++
			n.h.nativeSends++
			n.h.mu.Unlock()
			n.h.pulse()
			return nil
		}
	}
	return errors.New("talk binding missing")
}
func (n *replayNativeHandle) Interrupt(ctx context.Context) error {
	current := n.open.ReadThread()
	if current.Observation.LatestExecution == nil {
		return nil
	}
	o := current.Observation
	now := time.Now().UnixMilli()
	o.LatestExecution.Status = "interrupted"
	o.LatestExecution.FinishedAt = &now
	return n.open.SessionState.Commit(ctx, mokuReplayRaw(o))
}
func (n *replayNativeHandle) Respond(context.Context, model.RespondRequest) error { return nil }
func (n *replayNativeHandle) Read(context.Context, string) (string, error)        { return "history", nil }
func (n *replayNativeHandle) Close() error {
	o := n.open.ReadThread().Observation
	if o.BackgroundWork == nil {
		return nil
	}
	o.BackgroundWork = nil
	return n.open.SessionState.Commit(context.Background(), mokuReplayRaw(o))
}

type replaySystem struct {
	db   *store.Store
	r    *runtimepkg.Runtime
	c    *moku.Coordinator
	h    *replayNativeHarness
	root string
}

func startReplaySystem(root string, h *replayNativeHarness, reasons ...string) *replaySystem {
	db, e := store.Open(filepath.Join(root, "state.sqlite"))
	mokuReplayMust(e)
	h.db = db
	r, e := runtimepkg.New(mokuReplayContext(), runtimepkg.Config{Store: db, Workspaces: h.workspaces, Harnesses: map[string]plugin.Harness{"mock": h}, Attachments: attachments.New(filepath.Join(root, "attachments")), DataDir: root, DefaultCwd: root, Log: func(kind string, e error) {
		if e != nil {
			h.mu.Lock()
			h.errors = append(h.errors, kind+": "+e.Error())
			h.mu.Unlock()
			h.pulse()
		}
	}})
	mokuReplayMust(e)
	h.r = r
	cfg := newReplayConfiguration(root, r, h)
	c, e := moku.New(cfg)
	mokuReplayMust(e)
	r.SetMoku(c)
	reason := "manual"
	if len(reasons) > 0 {
		reason = reasons[0]
	}
	mokuReplayMust(c.Start(mokuReplayContext(), plugin.RuntimeStartContext{Reason: reason}))
	return &replaySystem{db, r, c, h, root}
}
func (s *replaySystem) record() model.ThreadRecord {
	rs, e := s.r.Threads()
	mokuReplayMust(e)
	for _, r := range rs {
		if r.Moku {
			return r
		}
	}
	panic("no Moku")
}
func (s *replaySystem) close() {
	ctx, cancel := context.WithTimeout(mokuReplayContext(), 5*time.Second)
	defer cancel()
	mokuReplayMust(s.r.Close(ctx))
	mokuReplayMust(s.db.Close())
}
func replaySettingsModel(r json.RawMessage) string {
	var v map[string]any
	mokuReplayMust(json.Unmarshal(r, &v))
	vstr, _ := v["model"].(string)
	return vstr
}

func newReplayConfiguration(root string, r *runtimepkg.Runtime, h *replayNativeHarness) moku.Configuration {
	workspace := filepath.Join(root, "moku")
	mokuReplayMust(os.MkdirAll(workspace, 0700))
	return moku.Configuration{Workspace: workspace, DataDir: root, Harnesses: map[string]plugin.Harness{"mock": h}, WithSettingsAdmission: r.WithConfigurationAdmission, PrepareSettings: r.PrepareSettings, Settings: r.Settings, Threads: r.Threads, Thread: r.Thread, UpdateThread: r.UpdateThread, UpdateNote: r.UpdateMokuNote,
		ReadSessionConfiguration: func() (moku.SessionConfiguration, error) {
			c, e := r.ReadMokuConfiguration()
			return moku.SessionConfiguration{Unapplied: c.Unapplied, HarnessID: c.HarnessID, Settings: c.Settings, Cwd: c.Cwd, AppliedSettings: c.AppliedSettings, SettingsRevision: c.SettingsRevision}, e
		},
		EnsureSession: func(ctx context.Context, c moku.SessionConfiguration) (model.ThreadRecord, error) {
			return r.EnsureConfiguredMokuThread(ctx, runtimepkg.MokuConfiguration{Unapplied: c.Unapplied, HarnessID: c.HarnessID, Settings: c.Settings, Cwd: c.Cwd, AppliedSettings: c.AppliedSettings, SettingsRevision: c.SettingsRevision})
		},
		ReplaceSession: func(ctx context.Context, old string, c moku.SessionConfiguration) (model.ThreadRecord, error) {
			return r.ReplaceConfiguredMokuThread(ctx, old, runtimepkg.MokuConfiguration{Unapplied: c.Unapplied, HarnessID: c.HarnessID, Settings: c.Settings, Cwd: c.Cwd, AppliedSettings: c.AppliedSettings, SettingsRevision: c.SettingsRevision, PreserveNote: c.PreserveNote, PreserveHistory: c.PreserveHistory})
		},
		ConfigureSession: func(ctx context.Context, id string, revision int64, c moku.SessionConfiguration) error {
			return r.ConfigureMokuThread(ctx, id, revision, c.HarnessID, c.Settings, c.AppliedSettings, c.SettingsRevision, c.Cwd)
		},
		OpenSession: r.OpenMokuThread, CloseSession: r.CloseMokuThread, SetNativeAdmission: r.SetMokuNativeAdmission, SubscribeCommitted: r.OnThreadCommitted, InterruptThread: r.InterruptThread, InterruptThreadTarget: r.InterruptThreadTarget, ClaimThreadInput: r.ClaimThreadInput, SendThread: r.SendThread,
		SubscribeUserThreadInputs: r.SubscribeUserThreadInputs,
		CreateThread: func(ctx context.Context, request moku.CreateThreadRequest) (moku.CreatedThread, error) {
			created, err := r.CreateThread(ctx, runtimepkg.CreateThreadRequest{HarnessID: request.HarnessID, Input: request.Input, Cwd: request.Cwd, Settings: request.Settings, Worktree: request.Worktree, ResolveSettings: request.ResolveSettings})
			return moku.CreatedThread{Record: created.Record, Execution: created.Execution, Acknowledgement: created.Acknowledgement, WorktreeName: created.WorktreeName, WorktreeNameAdjusted: created.WorktreeNameAdjusted, WorktreeNameNotice: created.WorktreeNameNotice}, err
		},
		SendSession: func(ctx context.Context, id string, in model.AgentInput, injection *plugin.Injection, entries []plugin.ContextEntry, admitted func(plugin.SessionSendResult) error) (plugin.SessionSendResult, error) {
			return r.SendMokuThread(ctx, id, in, injection, entries, func(result plugin.SessionSendResult) error {
				h.mu.Lock()
				gate := h.gateAdmission
				h.gateAdmission = nil
				h.mu.Unlock()
				if gate != nil {
					if e := gate(ctx); e != nil {
						return e
					}
				}
				if admitted != nil {
					return admitted(result)
				}
				return nil
			})
		},
		ReportFailure: func(kind string, e error) {
			if e != nil {
				h.mu.Lock()
				h.errors = append(h.errors, kind+": "+e.Error())
				h.mu.Unlock()
				h.pulse()
			}
		},
	}
}
