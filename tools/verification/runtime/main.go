package main

import (
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	core "github.com/hupao-creator/Mokusei/internal/core/runtime"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/hosts/applicationhost"
	"github.com/hupao-creator/Mokusei/internal/platform/transport"
	"github.com/hupao-creator/Mokusei/internal/plugins/applications/report"
	"github.com/hupao-creator/Mokusei/internal/plugins/applications/tag"
	"github.com/hupao-creator/Mokusei/internal/services/attachments"
	"github.com/hupao-creator/Mokusei/internal/services/workspaces"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

func must(err error) {
	if err != nil {
		panic(err)
	}
}
func raw(value any) json.RawMessage { data, err := json.Marshal(value); must(err); return data }

type harness struct{}

func (harness) Descriptor() plugin.HarnessDescriptor {
	return plugin.HarnessDescriptor{ID: "fixture", DisplayName: "Fixture", ThreadCapabilities: plugin.ThreadCapabilities{Instructions: true, ThreadContext: true, SendContext: true, ToolModes: []string{"exclusive"}}}
}
func (harness) DefaultSettings() json.RawMessage { return raw(map[string]any{}) }
func (harness) Detect(context.Context, string) (plugin.Installation, error) {
	return plugin.Installation{Status: "installed"}, nil
}
func (harness) Settings() plugin.HarnessSettings         { return settings{} }
func (harness) SessionState() plugin.SessionStateAdapter { return stateAdapter{} }
func (harness) Metadata() plugin.ThreadMetadataAdapter   { return metadata{} }
func (harness) Open(ctx context.Context, open plugin.OpenContext) (plugin.Handle, error) {
	return &handle{open: open}, nil
}
func (harness) Fork(ctx context.Context, request plugin.ForkRequest) (plugin.ForkResult, error) {
	return plugin.ForkResult{SessionState: request.Source.SessionState, Settings: request.Source.Settings, MetadataState: request.Source.MetadataState}, nil
}

type settings struct{ plugin.HarnessSettings }

func (settings) DefaultThread(raw json.RawMessage) (json.RawMessage, error) {
	return model.CloneRaw(raw), nil
}

func (settings) SnapshotExecution(ctx context.Context, request plugin.SettingsRequest, initial bool) (json.RawMessage, error) {
	return raw(map[string]any{}), nil
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

var detailBodyReads atomic.Int64

func (stateAdapter) ProjectDetail(value json.RawMessage, request model.DetailRequest) (model.DetailProjection, error) {
	var s state
	if err := json.Unmarshal(value, &s); err != nil {
		return model.DetailProjection{}, err
	}
	result := model.DetailProjection{ExecutionID: request.ExecutionID, Items: []model.DetailItem{}}
	for _, id := range request.Items {
		var index int
		if _, err := fmt.Sscanf(id, "detail:%d", &index); err != nil || index < 0 || index >= len(s.Messages) {
			continue
		}
		result.Items = append(result.Items, model.DetailItem{ID: id, Kind: "activity", Label: "fixture", Status: "completed",
			Bodies: []model.DetailBody{{Slot: "body", Format: model.DetailBodyText, Length: len(s.Messages[index])}}})
	}
	return result, nil
}
func (stateAdapter) ReadDetailBody(value json.RawMessage, request model.DetailBodyRequest) (model.DetailBody, error) {
	detailBodyReads.Add(1)
	var s state
	if err := json.Unmarshal(value, &s); err != nil {
		return model.DetailBody{}, err
	}
	var index int
	if _, err := fmt.Sscanf(request.ItemID, "detail:%d", &index); err != nil || index < 0 || index >= len(s.Messages) {
		return model.DetailBody{}, model.NewError("DETAIL_NOT_FOUND", "fixture detail is unavailable")
	}
	return model.DetailBody{Slot: request.Slot, Format: model.DetailBodyText, Length: len(s.Messages[index]), Text: s.Messages[index]}, nil
}
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
	open   plugin.OpenContext
	mu     sync.Mutex
	closed bool
}

func (h *handle) Send(ctx context.Context, request plugin.SendRequest) error {
	h.mu.Lock()
	defer h.mu.Unlock()
	var s state
	data := h.open.SessionState.Read()
	if !model.IsNull(data) {
		must(json.Unmarshal(data, &s))
	}
	s.Messages = append(s.Messages, request.Input.Parts[0].Text)
	startedAt := time.Now().UnixMilli()
	if execution := s.Observation.LatestExecution; execution != nil && execution.ExecutionID == request.ExecutionID {
		startedAt = execution.StartedAt
	}
	s.Observation.LatestExecution = &model.PublicExecution{ExecutionID: request.ExecutionID, Status: "running", StartedAt: startedAt}
	if err := h.open.SessionState.Commit(ctx, raw(s)); err != nil {
		return err
	}
	if err := request.Admitted(); err != nil {
		return err
	}
	return nil
}
func (h *handle) Interrupt(ctx context.Context) error {
	h.mu.Lock()
	defer h.mu.Unlock()
	data := h.open.SessionState.Read()
	if model.IsNull(data) {
		return nil
	}
	var s state
	must(json.Unmarshal(data, &s))
	if s.Observation.LatestExecution != nil {
		s.Observation.LatestExecution.Status = "interrupted"
		finished := max(time.Now().UnixMilli(), s.Observation.LatestExecution.StartedAt)
		s.Observation.LatestExecution.FinishedAt = &finished
	}
	return h.open.SessionState.Commit(ctx, raw(s))
}
func (h *handle) Respond(context.Context, model.RespondRequest) error { return nil }
func (h *handle) Read(ctx context.Context, question string) (string, error) {
	readCalls.Add(1)
	if question == "wait for cancellation" {
		readStarted <- struct{}{}
		<-ctx.Done()
		return "", ctx.Err()
	}
	if question == "native error" {
		return "", readFailure
	}
	return "answer: " + question, nil
}
func (h *handle) Close() error { h.mu.Lock(); h.closed = true; h.mu.Unlock(); return nil }
func waitFor(condition func() bool) {
	until := time.Now().Add(2 * time.Second)
	for time.Now().Before(until) {
		if condition() {
			return
		}
		time.Sleep(time.Millisecond)
	}
	panic("condition deadline")
}
func main() {
	swiftVoice := flag.Bool("swift-voice", false, "verify actual Swift integer encoding through global Moku voice and retained thread history")
	flag.Parse()
	ctx := context.Background()
	dir, err := os.MkdirTemp("", "mokusei-runtime-verification-")
	must(err)
	defer os.RemoveAll(dir)
	verifyBackgroundScopeBindings(ctx)
	verifyReportScopes(ctx)
	verifyBackgroundSettings(ctx)
	verifyBackgroundEnablement(ctx)
	verifyTagStatusbar(ctx)
	verifyComputePool(ctx)
	verifyProjectionWorkers(ctx, dir)
	verifyProjectionReuse(ctx, dir)
	verifyPublisherFanout(ctx, dir)
	verifyCommittedRecords(ctx, dir)
	verifyLifecycleSubscriptions(ctx, dir)
	database := filepath.Join(dir, "state.sqlite")
	db, err := store.Open(database)
	must(err)
	manager := workspaces.New(workspaces.Paths{MokuCwd: filepath.Join(dir, "moku"), TemporaryRoot: filepath.Join(dir, "workspaces"), RegistryPath: filepath.Join(dir, "worktrees.json")})
	r, err := core.New(ctx, core.Config{Store: db, Harnesses: map[string]plugin.Harness{"fixture": harness{}}, DataDir: dir, DefaultCwd: dir, Attachments: attachments.New(filepath.Join(dir, "attachments")), Workspaces: manager, Log: func(kind string, err error) { fmt.Println("log", kind, err) }})
	must(err)
	app, err := applicationhost.New(ctx, applicationhost.Config{Store: db, Applications: []plugin.Application{report.New(), tag.New()}, RuntimeCapabilities: r.RuntimeCapabilities, BackgroundCapabilities: r.BackgroundCapabilities, SnapshotCapabilities: r.SnapshotCapabilities, ProjectSession: r.ProjectSession, InitializeSession: r.InitializeApplicationSession, ArchiveExecutions: r.ArchiveExecutions})
	must(err)
	r.SetApplications(app)
	verifyDownloadMutation(ctx, r, dir)
	var mutations atomic.Int64
	var last atomic.Int64
	initial, err := r.Snapshot()
	must(err)
	last.Store(initial.Revision)
	unsubscribe := r.SubscribeMutations(func(value json.RawMessage) {
		var mutation model.StateMutation
		must(json.Unmarshal(value, &mutation))
		if mutation.Type != "state-patched" || mutation.BaseRevision != last.Load() {
			panic("mutation chain")
		}
		last.Store(mutation.Revision)
		mutations.Add(1)
		_, err := r.Snapshot()
		must(err)
	})
	defer unsubscribe()
	input := model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "first"}}}
	created, err := r.CreateThread(ctx, core.CreateThreadRequest{HarnessID: "fixture", Input: input})
	must(err)
	if created.Execution.ExecutionID == "" {
		panic("execution missing")
	}
	id := created.Record.ID
	verifyRuntimeVoice(ctx, dir, *swiftVoice)
	snapshotTags, err := plugin.Require[plugin.SemanticTagsSnapshotCapability](r.SnapshotCapabilities(db.Snapshot(), nil), plugin.SemanticTagsSnapshotCapabilityKey)
	must(err)
	projectedTags, err := snapshotTags.ReadThreadTags(model.ThreadRef{ThreadID: id, TypeID: "agent"})
	must(err)
	if len(projectedTags.DirectoryTags) != 0 || len(projectedTags.Tags) != 0 {
		panic("allocated temporary workspace leaked a directory tag")
	}
	follow, err := r.SendThread(ctx, id, model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "follow up"}}})
	must(err)
	if follow.StartedNewExecution || follow.ExecutionID != created.Execution.ExecutionID {
		panic("steering identity")
	}
	must(r.InterruptThread(ctx, id))
	must(verifyHTTPHealth(ctx, r, dir, id))
	forkID, err := r.ForkThread(ctx, id, raw(map[string]any{}))
	must(err)
	must(r.SetArchived(ctx, forkID, true))
	must(r.DeleteThread(ctx, forkID))
	content, err := r.ReadThreadContent(ctx, id, transport.ContentScope{Kind: "thread"}, nil)
	must(err)
	if content == nil {
		panic("content snapshot missing")
	}
	unchanged, err := r.ReadThreadContent(ctx, id, transport.ContentScope{Kind: "thread"}, &content.Revision)
	must(err)
	if unchanged != nil {
		panic("known revision changed")
	}
	verifyRuntimeDetail(ctx, r, id, created.Execution.ExecutionID)
	settings, revision, err := r.Settings()
	must(err)
	prompt := "verify"
	settings.Moku.RoutingGuidance = &prompt
	saved, err := r.UpdateSettings(ctx, revision, settings)
	must(err)
	if saved.Status != "saved" {
		panic("settings not saved")
	}
	conflict, err := r.UpdateSettings(ctx, revision, settings)
	must(err)
	if conflict.Status != "conflict" {
		panic("settings conflict missed")
	}
	caps := r.BackgroundCapabilities(plugin.BackgroundAgentRef{PluginID: "report", AgentID: "report.agent", Binding: plugin.ScopeBinding{Kind: plugin.GlobalScope}}, "report.settings")
	lifecycle, err := plugin.Require[plugin.LifecycleCapability](caps, plugin.LifecycleCapabilityKey)
	must(err)
	consumer, err := lifecycle.Register(plugin.LifecycleConsumerDefinition{ID: "verification", Filter: plugin.LifecycleScope{{SubjectTypeIDs: []string{"agent"}}}})
	must(err)
	events, err := consumer.Pending(plugin.PendingEventsQuery{})
	must(err)
	if len(events) < 4 {
		panic("lifecycle facts missing")
	}
	work, err := consumer.Begin(ctx, []string{events[0].ID})
	must(err)
	must(consumer.Settle(ctx, work.ID, "processed"))
	page, err := consumer.Read(plugin.LifecycleHistoryQuery{PageRequest: plugin.PageRequest{Limit: 100}})
	must(err)
	if len(page.Items) < 4 {
		panic("history missing")
	}
	config, err := plugin.Require[plugin.BackgroundConfigurationCapability](caps, plugin.BackgroundConfigurationCapabilityKey)
	must(err)
	resolved, err := config.Resolve(ctx, "primary")
	must(err)
	sessions, err := plugin.Require[plugin.BackgroundSessionsCapability](caps, plugin.BackgroundSessionsCapabilityKey)
	must(err)
	_, err = sessions.Configure(ctx, plugin.ConfigureSessionRequest{SessionKey: "primary", Configuration: resolved})
	must(err)
	private, err := sessions.Open(ctx, plugin.OpenSessionRequest{SessionKey: "primary"})
	must(err)
	admitted := false
	_, err = private.Send(ctx, input, nil, func(plugin.SessionSendResult) error { admitted = true; return nil })
	must(err)
	if !admitted {
		panic("private admission missed")
	}
	state, err := r.Snapshot()
	must(err)
	if len(state.Threads) != 1 || len(state.AgentRuns) != 1 {
		panic(fmt.Sprintf("private session leaked or run missing %d %d", len(state.Threads), len(state.AgentRuns)))
	}
	must(private.Interrupt(ctx, nil))
	must(private.Close())
	verifyTaskReadCapability(ctx, r, id, private.Ref().SessionID)
	tagCaps := r.RuntimeCapabilities("tag")
	tags, err := plugin.Require[plugin.SemanticTagsWriteCapability](tagCaps, plugin.SemanticTagsWriteCapabilityKey)
	must(err)
	must(tags.EnsureInventory(ctx))
	_, err = tags.Execute(ctx, plugin.SemanticTagOperation{Kind: "create", Name: "Research", Emoji: stringPointer("🔬")}, plugin.BackgroundWriteOptions{RequestID: "verify-create"})
	must(err)
	_, err = tags.Execute(ctx, plugin.SemanticTagOperation{Kind: "assign", Thread: &model.ThreadRef{ThreadID: id, TypeID: "agent"}, Tags: []string{"Research"}}, plugin.BackgroundWriteOptions{RequestID: "verify-assign"})
	must(err)
	newName := "Investigation"
	_, err = tags.Execute(ctx, plugin.SemanticTagOperation{Kind: "update", Name: "Research", NewName: newName}, plugin.BackgroundWriteOptions{RequestID: "verify-rename"})
	must(err)
	thread, err := r.Thread(id)
	must(err)
	assertTagEmoji(r, id, newName, "🔬")
	if len(thread.Tags) != 1 || thread.Tags[0] != newName {
		panic("tag propagation missing")
	}
	verifyScopedTagPools(ctx, r, id)
	waitFor(func() bool { return mutations.Load() > 0 })
	must(r.Close(ctx))
	must(db.Close())
	db, err = store.Open(database)
	must(err)
	r, err = core.New(ctx, core.Config{Store: db, Harnesses: map[string]plugin.Harness{"fixture": harness{}}, DataDir: dir, DefaultCwd: dir})
	must(err)
	assertTagEmoji(r, id, "Investigation", "🔬")
	thread, err = r.Thread(id)
	must(err)
	if thread.Tags[0] != newName || thread.Observation.LatestExecution.Status != "interrupted" {
		panic("durability lost")
	}
	must(r.ClearHistory(ctx))
	threads, err := r.Threads()
	must(err)
	if len(threads) != 1 || !threads[0].Moku {
		panic("clear history failed")
	}
	must(r.Close(ctx))
	must(db.Close())
	fmt.Printf("PASS runtime SQLite lifecycle, steering, cancellation, fork/delete, settings CAS, content revisions, reentrant mutation subscribers, private sessions, tags, restart, history reset; %d mutations\n", mutations.Load())
}

func verifyRuntimeDetail(ctx context.Context, r *core.Runtime, threadID, executionID string) {
	thread, err := r.Thread(threadID)
	must(err)
	original := thread.SessionState
	small := "small runtime detail"
	huge := "RUNTIME_DETAIL_MARKER" + strings.Repeat("a", 24<<20)
	must(r.UpdateThread(ctx, threadID, func(t *model.ThreadRecord) error {
		t.SessionState = raw(state{Messages: []string{small, huge}})
		return nil
	}))
	defer func() {
		must(r.UpdateThread(context.Background(), threadID, func(t *model.ThreadRecord) error {
			t.SessionState = original
			return nil
		}))
	}()

	directoryRaw, err := r.ReadThreadContent(ctx, threadID, transport.ContentScope{Kind: "detail", Key: executionID, Items: []string{"detail:0"}}, nil)
	must(err)
	if bytes.Contains(directoryRaw.Value, []byte("RUNTIME_DETAIL_MARKER")) {
		panic("runtime detail directory serialized an unselected sibling body")
	}
	var directory model.DetailDirectory
	must(json.Unmarshal(directoryRaw.Value, &directory))
	if directory.Kind != "detail" || directory.ContentID == "" || len(directory.Items) != 1 || directory.Items[0].ID != "detail:0" || len(directory.Items[0].Bodies) != 1 {
		panic("runtime detail directory lost the selected item or content identity")
	}
	if directory.Items[0].Bodies[0].Length != len(small) || directory.Items[0].Bodies[0].Slot != "body" {
		panic("runtime detail directory lost body metadata")
	}
	if bytes.Contains(directoryRaw.Value, []byte("version")) {
		panic("runtime detail directory exposed a body hash")
	}

	detailBodyReads.Store(0)
	started := time.Now()
	firstRaw, err := r.ReadThreadContent(ctx, threadID, transport.ContentScope{Kind: "body", Key: executionID, Items: []string{"detail:1"}, Slot: "body"}, nil)
	must(err)
	var first model.DetailChunk
	must(json.Unmarshal(firstRaw.Value, &first))
	if first.Length != len(huge) || first.Text == "" || first.Next == "" || first.Version == "" || first.Offset != 0 {
		panic("runtime detail body did not start a versioned chunked read")
	}
	var assembled strings.Builder
	assembled.WriteString(first.Text)
	cursor := first.Next
	pages := 1
	for cursor != "" {
		chunkRaw, err := r.ReadThreadContent(ctx, threadID, transport.ContentScope{Kind: "body", Key: executionID, Items: []string{"detail:1"}, Slot: "body", Cursor: cursor}, nil)
		must(err)
		var chunk model.DetailChunk
		must(json.Unmarshal(chunkRaw.Value, &chunk))
		if chunk.Offset != assembled.Len() || chunk.Length != len(huge) || chunk.Version != first.Version {
			panic("runtime detail chunk identity changed")
		}
		if len(chunk.Text) > 64*1024 {
			panic("runtime detail chunk exceeded its byte budget")
		}
		assembled.WriteString(chunk.Text)
		cursor = chunk.Next
		pages++
	}
	if assembled.String() != huge {
		panic("runtime detail chunks did not reassemble the retained body")
	}
	if reads := detailBodyReads.Load(); reads != 1 {
		panic(fmt.Sprintf("runtime detail body was reprojected per page: %d reads", reads))
	}
	if pages <= 1 {
		panic("24 MiB detail body was not paged")
	}
	fmt.Printf("detail budget body=%d pages=%d reads=%d elapsed=%s\n", len(huge), pages, detailBodyReads.Load(), time.Since(started))

	must(r.UpdateThread(ctx, threadID, func(t *model.ThreadRecord) error {
		t.Title += " metadata-only"
		return nil
	}))
	metadataRaw, err := r.ReadThreadContent(ctx, threadID, transport.ContentScope{Kind: "body", Key: executionID, Items: []string{"detail:1"}, Slot: "body"}, nil)
	must(err)
	var metadataFirst model.DetailChunk
	must(json.Unmarshal(metadataRaw.Value, &metadataFirst))
	if metadataFirst.Version != first.Version || detailBodyReads.Load() != 1 {
		panic("metadata-only update evicted the detail body cache or changed its version")
	}

	must(r.UpdateThread(ctx, threadID, func(t *model.ThreadRecord) error {
		t.SessionState = raw(state{Messages: []string{small, huge + "changed"}})
		return nil
	}))
	_, err = r.ReadThreadContent(ctx, threadID, transport.ContentScope{Kind: "body", Key: executionID, Items: []string{"detail:1"}, Slot: "body", Cursor: first.Next}, nil)
	if err == nil || !strings.Contains(err.Error(), "detail body changed") {
		panic("runtime detail cursor crossed content versions")
	}

	items := make([]string, 1025)
	messages := make([]string, 1025)
	for index := range items {
		items[index] = fmt.Sprintf("detail:%d", index)
		messages[index] = "x"
	}
	must(r.UpdateThread(ctx, threadID, func(t *model.ThreadRecord) error {
		t.SessionState = raw(state{Messages: messages})
		return nil
	}))
	truncatedRaw, err := r.ReadThreadContent(ctx, threadID, transport.ContentScope{Kind: "detail", Key: executionID, Items: items}, nil)
	must(err)
	var truncated model.DetailDirectory
	must(json.Unmarshal(truncatedRaw.Value, &truncated))
	if !truncated.Truncated || len(truncated.Items) != 1024 {
		panic("runtime detail directory truncated without a visible flag")
	}
}
