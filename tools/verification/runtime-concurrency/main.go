package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	core "github.com/hupao-creator/Mokusei/internal/core/runtime"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"time"
)

func must(err error) {
	if err != nil {
		panic(err)
	}
}
func raw(v any) json.RawMessage { b, e := json.Marshal(v); must(e); return b }
func receive[T any](ch <-chan T) T {
	select {
	case v := <-ch:
		return v
	case <-time.After(3 * time.Second):
		panic("timeout")
	}
}
func assert(v bool, m string) {
	if !v {
		panic(m)
	}
}

type harness struct {
	opened      chan *handle
	mode        string
	forkStarted chan struct{}
	settingsAPI plugin.HarnessSettings
}

func (*harness) Descriptor() plugin.HarnessDescriptor {
	return plugin.HarnessDescriptor{ID: "fixture", ThreadCapabilities: plugin.ThreadCapabilities{Instructions: true, ThreadContext: true, SendContext: true, ToolModes: []string{"exclusive"}}}
}
func (*harness) DefaultSettings() json.RawMessage { return raw(map[string]any{}) }
func (*harness) Detect(context.Context, string) (plugin.Installation, error) {
	return plugin.Installation{Status: "installed"}, nil
}
func (h *harness) Settings() plugin.HarnessSettings {
	if h.settingsAPI != nil {
		return h.settingsAPI
	}
	return settings{}
}
func (*harness) Metadata() plugin.ThreadMetadataAdapter   { return metadata{} }
func (*harness) SessionState() plugin.SessionStateAdapter { return stateAdapter{} }
func (h *harness) Open(ctx context.Context, o plugin.OpenContext) (plugin.Handle, error) {
	n := &handle{open: o, ctx: ctx, mode: h.mode, closeEntered: make(chan struct{}), closeRelease: make(chan struct{})}
	h.opened <- n
	if h.mode == "opening" {
		<-ctx.Done()
		return nil, ctx.Err()
	}
	return n, nil
}
func (h *harness) Fork(ctx context.Context, r plugin.ForkRequest) (plugin.ForkResult, error) {
	if h.forkStarted != nil {
		close(h.forkStarted)
		<-ctx.Done()
		return plugin.ForkResult{}, ctx.Err()
	}
	return plugin.ForkResult{SessionState: r.Source.SessionState, MetadataState: r.Source.MetadataState, Settings: r.Source.Settings}, nil
}

type settings struct{ plugin.HarnessSettings }

func (settings) DefaultThread(raw json.RawMessage) (json.RawMessage, error) {
	return model.CloneRaw(raw), nil
}

func (settings) SnapshotExecution(ctx context.Context, request plugin.SettingsRequest, initial bool) (json.RawMessage, error) {
	return raw(map[string]any{}), nil
}

func (settings) Presentation(ctx context.Context, request plugin.SettingsPresentationRequest) (json.RawMessage, error) {
	return raw(map[string]any{}), ctx.Err()
}

func (settings) Normalize(value json.RawMessage) (json.RawMessage, error) { return value, nil }
func (settings) ResolveThread(context.Context, plugin.ResolveSettingsRequest) (json.RawMessage, error) {
	return raw(map[string]any{}), nil
}
func (settings) HasThreadContent(value json.RawMessage) bool { return !model.IsNull(value) }
func (settings) ApplyThreadUpdate(ctx context.Context, request plugin.UpdateSettingsRequest) (json.RawMessage, error) {
	return request.Update, nil
}

type metadata struct{}

func (metadata) Initialize(string, model.AgentInput, json.RawMessage) (json.RawMessage, error) {
	return raw(map[string]string{"title": "Fixture task"}), nil
}
func (metadata) Project(value json.RawMessage) (string, error) {
	var item map[string]string
	err := json.Unmarshal(value, &item)
	return item["title"], err
}
func (metadata) Fork(value json.RawMessage, title string) (json.RawMessage, error) { return value, nil }

type state struct {
	Observation model.PublicObservation `json:"observation"`
	Messages    []string                `json:"messages"`
}
type stateAdapter struct{}

func (stateAdapter) Project(value json.RawMessage) (model.PublicObservation, error) {
	var s state
	if model.IsNull(value) {
		return s.Observation, nil
	}
	err := json.Unmarshal(value, &s)
	return s.Observation, err
}
func (stateAdapter) ProjectRenderer(value json.RawMessage, scope model.RendererScope) (json.RawMessage, error) {
	if model.IsNull(value) {
		return raw(map[string]any{}), nil
	}
	return value, nil
}
func (stateAdapter) ReadContext(value json.RawMessage) (json.RawMessage, error) { return value, nil }
func (stateAdapter) ResolveExecution(value json.RawMessage, id string) (*model.PublicExecution, error) {
	o, err := (stateAdapter{}).Project(value)
	if err != nil {
		return nil, err
	}
	if o.LatestExecution != nil && o.LatestExecution.ExecutionID == id {
		return o.LatestExecution, nil
	}
	return nil, nil
}
func (stateAdapter) Settle(request plugin.SettleRequest) (json.RawMessage, error) {
	var s state
	must(json.Unmarshal(request.SessionState, &s))
	s.Observation.LatestExecution.Status = request.Outcome
	s.Observation.LatestExecution.FinishedAt = &request.FinishedAt
	return raw(s), nil
}

type handle struct {
	open               plugin.OpenContext
	ctx                context.Context
	mode               string
	mu                 sync.Mutex
	closed             bool
	responses          atomic.Int64
	responseNotSent    atomic.Bool
	responseUncertain  atomic.Bool
	requireTypedNumber atomic.Bool
	sentCtx            context.Context
	closeEntered       chan struct{}
	closeRelease       chan struct{}
}

func (h *handle) Send(ctx context.Context, q plugin.SendRequest) error {
	h.mu.Lock()
	h.sentCtx = ctx
	mode := h.mode
	h.mu.Unlock()
	if mode == "pending" {
		<-ctx.Done()
		return ctx.Err()
	}
	var s state
	b := h.open.SessionState.Read()
	if !model.IsNull(b) {
		must(json.Unmarshal(b, &s))
	}
	s.Messages = append(s.Messages, q.Input.Parts[0].Text)
	if e := s.Observation.LatestExecution; e == nil || e.ExecutionID != q.ExecutionID {
		s.Observation.LatestExecution = &model.PublicExecution{ExecutionID: q.ExecutionID, Status: "running", StartedAt: time.Now().UnixMilli()}
	}
	if e := h.open.SessionState.Commit(ctx, raw(s)); e != nil {
		return e
	}
	if e := q.Admitted(); e != nil {
		return e
	}
	if mode == "successor" {
		at := time.Now().UnixMilli()
		s.Observation.LatestExecution.Status = "completed"
		s.Observation.LatestExecution.FinishedAt = &at
		if e := h.open.SessionState.Commit(ctx, raw(s)); e != nil {
			return e
		}
		_, e := h.open.ExecutionAdmission.Accept(ctx, func(id string) (json.RawMessage, error) {
			s.Observation.LatestExecution = &model.PublicExecution{ExecutionID: id, Status: "running", StartedAt: time.Now().UnixMilli()}
			return raw(s), nil
		})
		return e
	}
	return nil
}
func (h *handle) Interrupt(ctx context.Context) error {
	b := h.open.SessionState.Read()
	if model.IsNull(b) {
		return nil
	}
	var s state
	must(json.Unmarshal(b, &s))
	if s.Observation.LatestExecution != nil && !s.Observation.LatestExecution.Terminal() {
		at := time.Now().UnixMilli()
		s.Observation.LatestExecution.Status = "interrupted"
		s.Observation.LatestExecution.Interactions = nil
		s.Observation.LatestExecution.FinishedAt = &at
		return h.open.SessionState.Commit(ctx, raw(s))
	}
	return nil
}
func (h *handle) Respond(_ context.Context, request model.RespondRequest) error {
	if h.responseNotSent.Swap(false) {
		return &plugin.InteractionResponseNotSentError{Cause: errors.New("fixture local rejection")}
	}
	h.responses.Add(1)
	if h.requireTypedNumber.Load() {
		assert(request.ValidatedFormValues["count"] == float64(16), "validated numeric type was not handed to native adapter")
	}
	if h.responseUncertain.Swap(false) {
		return errors.New("fixture native acknowledgement lost")
	}
	return nil
}
func (h *handle) Read(ctx context.Context, _ string) (string, error) {
	if h.mode == "read" {
		<-ctx.Done()
		return "", ctx.Err()
	}
	return "ok", nil
}
func (h *handle) Close() error {
	h.mu.Lock()
	h.closed = true
	h.mu.Unlock()
	if h.mode == "history-fail" {
		return errors.New("fixture native stop refused")
	}
	if h.mode == "history-drain" {
		close(h.closeEntered)
		<-h.closeRelease
		var s state
		must(json.Unmarshal(h.open.SessionState.Read(), &s))
		s.Observation.BackgroundWork = nil
		return h.open.SessionState.Commit(context.Background(), raw(s))
	}
	if h.mode == "canonical-close" {
		return h.open.SessionState.Commit(context.Background(), lateTerminal(h.open.SessionState.Read()))
	}
	return nil
}
func setup(mode string, additional ...plugin.Harness) (*core.Runtime, *harness, func()) {
	d, e := os.MkdirTemp("", "oa-review-")
	must(e)
	db, e := store.Open(filepath.Join(d, "state.sqlite"))
	must(e)
	h := &harness{opened: make(chan *handle, 8), mode: mode}
	harnesses := map[string]plugin.Harness{"fixture": h}
	for _, extra := range additional {
		harnesses[extra.Descriptor().ID] = extra
	}
	r, e := core.New(context.Background(), core.Config{Store: db, Harnesses: harnesses, DataDir: d, DefaultCwd: d})
	must(e)
	return r, h, func() {
		err := r.Close(context.Background())
		if mode != "history-fail" {
			must(err)
		}
		must(db.Close())
		must(os.RemoveAll(d))
	}
}
func create(r *core.Runtime) (core.CreatedThread, error) {
	return r.CreateThread(context.Background(), core.CreateThreadRequest{HarnessID: "fixture", Input: model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "hello"}}}})
}

type participant struct{ started chan context.Context }

func (p *participant) Invoke(context.Context, string, []json.RawMessage) (any, error) {
	return nil, nil
}
func (p *participant) Start(ctx context.Context, _ plugin.RuntimeStartContext) error {
	p.started <- ctx
	return nil
}
func (p *participant) Stop(context.Context) error { return nil }

type blockedAttachments struct {
	core.AttachmentStore
	retaining chan string
}

func (b *blockedAttachments) RetainOwners(context.Context, []string) error { return nil }
func (b *blockedAttachments) RetainInput(ctx context.Context, id string, in model.AgentInput) (model.AgentInput, error) {
	b.retaining <- id
	<-ctx.Done()
	return in, ctx.Err()
}
func main() {
	verifyConfigurationCancellation()
	verifySettingsDiscoveryIsolation()
	verifySettingsSnapshotConvergence()
	verifyMultiClientContracts()
	verifyCanonicalClosingOwner()
	verifyHistoryDrain()
	{
		r, h, cleanup := setup("pending")
		done := make(chan error, 1)
		go func() { _, e := create(r); done <- e }()
		n := receive(h.opened)
		del := make(chan error, 1)
		go func() { del <- r.DeleteThread(context.Background(), n.open.ThreadID) }()
		must(receive(del))
		assert(receive(done) != nil, "delete didn't cancel send")
		_, e := r.Thread(n.open.ThreadID)
		assert(e != nil, "delete did not remove record")
		cleanup()
		fmt.Println("delete during pending admission: passed")
	}
	{
		r, h, cleanup := setup("opening")
		done := make(chan error, 1)
		go func() { _, e := create(r); done <- e }()
		n := receive(h.opened)
		cleared := make(chan error, 1)
		go func() { cleared <- r.ClearHistory(context.Background()) }()
		must(receive(cleared))
		assert(receive(done) != nil, "history didn't cancel opening")
		assert(n.ctx.Err() != nil, "opening context survived history")
		threads, e := r.Threads()
		must(e)
		assert(len(threads) == 1 && threads[0].Moku, "history missing atomic Moku shell")
		cleanup()
		fmt.Println("history during native opening + Moku shell: passed")
	}
	{
		r, h, cleanup := setup("normal")
		c, e := create(r)
		must(e)
		n := receive(h.opened)
		must(r.InterruptThread(context.Background(), c.Record.ID))
		must(r.CloseMokuThread(context.Background(), c.Record.ID))
		e = n.open.SessionState.Commit(context.Background(), n.open.SessionState.Read())
		assert(e != nil, "retired owner persisted session")
		_, e = n.open.Metadata.Commit(context.Background(), 0, raw(map[string]string{"title": "stale"}))
		assert(e != nil, "retired owner persisted metadata")
		cleanup()
		fmt.Println("retired session + metadata owner fencing: passed")
	}
	{
		r, h, cleanup := setup("successor")
		for i := 0; i < 12; i++ {
			done := make(chan error, 1)
			go func() {
				c, e := create(r)
				if e == nil && c.Execution.ExecutionID == "" {
					e = errors.New("missing execution")
				}
				done <- e
			}()
			receive(h.opened)
			must(receive(done))
		}
		cleanup()
		fmt.Println("successor native wake after admission: passed")
	}
	{
		r, h, cleanup := setup("normal")
		c, e := create(r)
		must(e)
		n := receive(h.opened)
		must(r.InterruptThread(context.Background(), c.Record.ID))
		h.forkStarted = make(chan struct{})
		fork := make(chan error, 1)
		go func() { _, e := r.ForkThread(context.Background(), c.Record.ID, raw(map[string]any{})); fork <- e }()
		receive(h.forkStarted)
		_, e = n.open.ExecutionAdmission.Accept(context.Background(), func(id string) (json.RawMessage, error) {
			return raw(state{Observation: model.PublicObservation{LatestExecution: &model.PublicExecution{ExecutionID: id, Status: "running", StartedAt: time.Now().UnixMilli()}}}), nil
		})
		assert(e != nil, "native admission ignored fork reservation")
		del := make(chan error, 1)
		go func() { del <- r.DeleteThread(context.Background(), c.Record.ID) }()
		must(receive(del))
		assert(receive(fork) != nil, "delete did not revoke in-flight fork")
		cleanup()
		fmt.Println("fork exclusion + deletion cancellation: passed")
	}
	{
		r, h, cleanup := setup("pending")
		done := make(chan error, 1)
		go func() { _, e := create(r); done <- e }()
		n := receive(h.opened)
		must(r.InterruptThread(context.Background(), n.open.ThreadID))
		assert(receive(done) != nil, "interrupt didn't cancel pending input")
		cleanup()
		fmt.Println("interrupt pending native send: passed")
	}
	{
		r, h, cleanup := setup("normal")
		c, e := create(r)
		must(e)
		n := receive(h.opened)
		n.mu.Lock()
		sent := n.sentCtx
		n.mu.Unlock()
		assert(sent.Err() == nil, "successful admission canceled native execution context")
		must(r.InterruptThread(context.Background(), c.Record.ID))
		cleanup()
		fmt.Println("successful Send retains execution context: passed")
	}
	{
		r, _, cleanup := setup("normal")
		p := &participant{started: make(chan context.Context, 1)}
		r.SetMoku(p)
		ctx, cancel := context.WithCancel(context.Background())
		must(r.ClearHistory(ctx))
		started := receive(p.started)
		cancel()
		assert(started.Err() == nil, "history participant bound to request")
		cleanup()
		assert(started.Err() != nil, "participant survived shutdown generation")
		fmt.Println("history participants use generation lifetime: passed")
	}
	{
		d, e := os.MkdirTemp("", "oa-review-attachments-")
		must(e)
		db, e := store.Open(filepath.Join(d, "state.sqlite"))
		must(e)
		h := &harness{opened: make(chan *handle, 8), mode: "normal"}
		a := &blockedAttachments{retaining: make(chan string, 1)}
		r, e := core.New(context.Background(), core.Config{Store: db, Harnesses: map[string]plugin.Harness{"fixture": h}, DataDir: d, DefaultCwd: d, Attachments: a})
		must(e)
		done := make(chan error, 1)
		go func() { _, e := create(r); done <- e }()
		id := receive(a.retaining)
		must(r.InterruptThread(context.Background(), id))
		assert(receive(done) != nil, "interrupt before native open did not cancel send claim")
		assert(len(h.opened) == 0, "interrupt started an unnecessary native owner")
		must(r.Close(context.Background()))
		must(db.Close())
		must(os.RemoveAll(d))
		fmt.Println("interrupt during attachment preparation: passed")
	}

}
