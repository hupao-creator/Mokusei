package runtime

import (
	"context"
	"encoding/json"
	"fmt"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/platform/transport"
)

type catalogFixtureHarness struct{ adapter catalogFixtureAdapter }

func (h catalogFixtureHarness) Descriptor() plugin.HarnessDescriptor {
	return plugin.HarnessDescriptor{ID: "fixture", DisplayName: "Fixture"}
}
func (h catalogFixtureHarness) DefaultSettings() json.RawMessage { return json.RawMessage(`{}`) }
func (h catalogFixtureHarness) Detect(context.Context, string) (plugin.Installation, error) {
	return plugin.Installation{Status: "installed"}, nil
}
func (h catalogFixtureHarness) Settings() plugin.HarnessSettings { return nil }
func (h catalogFixtureHarness) SessionState() plugin.SessionStateAdapter {
	return h.adapter
}
func (h catalogFixtureHarness) Metadata() plugin.ThreadMetadataAdapter {
	return plugin.GeneratedThreadMetadata{}
}
func (h catalogFixtureHarness) Open(context.Context, plugin.OpenContext) (plugin.Handle, error) {
	return nil, nil
}

type catalogFixtureAdapter struct {
	checkKnown        func(*int64) error
	calls             *atomic.Int64
	badDirectory      bool
	badDirectoryLimit bool
}

type catalogFixtureState struct {
	Executions []model.ExecutionDigest `json:"executions"`
	Body       string                  `json:"body"`
}

func (catalogFixtureAdapter) Project(json.RawMessage) (model.PublicObservation, error) {
	return model.PublicObservation{}, nil
}
func (c catalogFixtureAdapter) ProjectRenderer(raw json.RawMessage, scope model.RendererScope) (json.RawMessage, error) {
	var state catalogFixtureState
	if err := json.Unmarshal(raw, &state); err != nil {
		return nil, err
	}
	switch scope.Kind {
	case "thread":
		return json.Marshal(model.Object{"body": state.Body})
	case "directory":
		page := model.PaginateExecutionDigests(state.Executions, scope.Offset, scope.Limit)
		if c.badDirectory {
			page.Offset++
		}
		if c.badDirectoryLimit {
			page.Limit++
		}
		return json.Marshal(page)
	case "preview":
		for _, execution := range state.Executions {
			if execution.ExecutionID == scope.Key {
				return json.Marshal(execution)
			}
		}
		return json.RawMessage(`{}`), nil
	default:
		return json.RawMessage(`{}`), nil
	}
}
func (catalogFixtureAdapter) ReadContext(raw json.RawMessage) (json.RawMessage, error) {
	return raw, nil
}
func (catalogFixtureAdapter) ResolveExecution(json.RawMessage, string) (*model.PublicExecution, error) {
	return nil, nil
}
func (catalogFixtureAdapter) Settle(request plugin.SettleRequest) (json.RawMessage, error) {
	return request.SessionState, nil
}
func (c catalogFixtureAdapter) ProjectReader(_ context.Context, request plugin.ReaderRequest) (*plugin.ReaderSnapshot, error) {
	return c.projectReader(request)
}

func (c catalogFixtureAdapter) projectReader(request plugin.ReaderRequest) (*plugin.ReaderSnapshot, error) {
	if c.calls != nil {
		c.calls.Add(1)
	}
	if request.ContentID == "" {
		return nil, fmt.Errorf("adapter request omitted ContentID")
	}
	if c.checkKnown != nil {
		if err := c.checkKnown(request.Known); err != nil {
			return nil, err
		}
	}
	value, err := c.ProjectRenderer(request.State, request.Scope)
	if err != nil {
		return nil, err
	}
	// A reader cache deliberately reports a 63-bit content hash. Runtime must
	// not use it as the final envelope revision or return it as the adapter Known.
	const contentRevision = int64(^uint64(0) >> 1)
	if request.Known != nil && *request.Known == contentRevision {
		return nil, nil
	}
	return &plugin.ReaderSnapshot{Revision: contentRevision, Value: value}, nil
}
func (catalogFixtureAdapter) EvictThread(string) {}

func TestOverviewCatalogStripsTitlesAndExecutionScopesReadThemByReference(t *testing.T) {
	dir := t.TempDir()
	db, err := store.Open(filepath.Join(dir, "state.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	finished := int64(20)
	state := catalogFixtureState{Body: "bounded card", Executions: []model.ExecutionDigest{
		{ExecutionID: "e1", Status: "completed", StartedAt: 10, FinishedAt: &finished, Excerpt: "first excerpt"},
		{ExecutionID: "e2", Status: "completed", StartedAt: 15, FinishedAt: &finished, Excerpt: "second excerpt"},
		{ExecutionID: "e3", Status: "running", StartedAt: 18, Excerpt: "current excerpt"},
	}}
	rawState, err := json.Marshal(state)
	if err != nil {
		t.Fatal(err)
	}
	thread := model.ThreadRecord{
		SessionRecord: model.SessionRecord{ID: "thread", HarnessID: "fixture", Revision: 1,
			SessionState: rawState, Settings: json.RawMessage(`{}`), Cwd: dir, CreatedAt: 1, UpdatedAt: 1},
		Title: "Fixture thread", Tags: []string{}, TagEmojis: map[string]string{},
		ExecutionTitles: map[string]string{"e1": "First execution", "e2": "Second execution"},
	}
	if _, err := db.Update(t.Context(), func(tx *store.Tx) error {
		if err := tx.Put("thread:thread", thread); err != nil {
			return err
		}
		return tx.Put("threads", []string{"thread"})
	}); err != nil {
		t.Fatal(err)
	}
	r, err := New(t.Context(), Config{Store: db, DataDir: dir, DefaultCwd: dir,
		Harnesses: map[string]plugin.Harness{"fixture": catalogFixtureHarness{adapter: catalogFixtureAdapter{
			checkKnown: func(known *int64) error {
				if known != nil {
					return fmt.Errorf("enveloped scope passed final revision as adapter Known: %d", *known)
				}
				return nil
			},
		}}}})
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		if err := r.Close(context.Background()); err != nil {
			t.Error(err)
		}
	}()

	app, err := r.Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	if len(app.Threads) != 1 {
		t.Fatalf("catalog threads = %d", len(app.Threads))
	}
	catalogRecord, err := json.Marshal(app.Threads[0])
	if err != nil {
		t.Fatal(err)
	}
	if app.Threads[0].ExecutionTitles != nil || strings.Contains(string(catalogRecord), "executionTitles") {
		t.Fatalf("catalog retained execution titles: %s", catalogRecord)
	}
	if len(catalogRecord) > model.MaxThreadOverviewBytes {
		t.Fatalf("catalog record is %d bytes", len(catalogRecord))
	}
	fullCatalog, err := json.Marshal(app)
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("catalog thread record bytes=%d full catalog bytes=%d", len(catalogRecord), len(fullCatalog))

	content, err := r.ReadThreadContent(t.Context(), "thread", transport.ContentScope{Kind: "thread"}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if content.Revision != 1 {
		t.Fatalf("initial content revision = %d, want Thread revision 1", content.Revision)
	}
	var envelope threadContentEnvelope
	if err := json.Unmarshal(content.Value, &envelope); err != nil {
		t.Fatal(err)
	}
	if envelope.Version != 1 || envelope.ExecutionTitles["e1"] != "First execution" || !strings.Contains(string(envelope.State), "bounded card") {
		t.Fatalf("full content envelope lost its exact titles: %s", content.Value)
	}

	pageContent, err := r.ReadThreadContent(t.Context(), "thread",
		transport.ContentScope{Kind: "directory", Offset: 1, Limit: 1}, nil)
	if err != nil {
		t.Fatal(err)
	}
	var page model.ExecutionDirectoryPage
	if err := json.Unmarshal(pageContent.Value, &page); err != nil {
		t.Fatal(err)
	}
	if page.Total != 3 || page.Offset != 1 || page.NextOffset == nil || *page.NextOffset != 2 ||
		len(page.Executions) != 1 || page.Executions[0].ExecutionID != "e2" || page.Executions[0].Title != "Second execution" {
		t.Fatalf("directory page lost order or title: %+v", page)
	}
	previewContent, err := r.ReadThreadContent(t.Context(), "thread",
		transport.ContentScope{Kind: "preview", Key: "e2"}, nil)
	if err != nil {
		t.Fatal(err)
	}
	var contentPreview model.ExecutionDigest
	if err := json.Unmarshal(previewContent.Value, &contentPreview); err != nil {
		t.Fatal(err)
	}
	if contentPreview.ThreadID != "thread" || contentPreview.Title != "Second execution" ||
		contentPreview.ExecutionID != "e2" || contentPreview.Excerpt != "second excerpt" {
		t.Fatalf("content preview lost its reference: %+v", contentPreview)
	}

	request, _ := json.Marshal(map[string]any{"references": []map[string]any{
		{"threadId": "thread", "executionId": "e1"},
	}})
	result, err := r.Invoke(t.Context(), "thread:execution-previews", []json.RawMessage{request})
	if err != nil {
		t.Fatal(err)
	}
	encoded, err := json.Marshal(result)
	if err != nil {
		t.Fatal(err)
	}
	var response struct {
		Previews []model.ExecutionDigest `json:"previews"`
	}
	if err := json.Unmarshal(encoded, &response); err != nil {
		t.Fatal(err)
	}
	if len(response.Previews) != 1 {
		t.Fatalf("preview response = %s", encoded)
	}
	preview := response.Previews[0]
	if preview.ThreadID != "thread" || preview.ExecutionID != "e1" || preview.Title != "First execution" ||
		preview.Excerpt != "first excerpt" || preview.FinishedAt == nil || preview.Status != "completed" {
		t.Fatalf("preview lost the cited execution: %+v", preview)
	}
	if strings.Contains(string(encoded), "bounded card") {
		t.Fatal("preview returned the complete execution body")
	}
	t.Logf("execution preview response bytes=%d", len(encoded))

	duplicate, _ := json.Marshal(map[string]any{"references": []map[string]any{
		{"threadId": "thread", "executionId": "e1"},
		{"threadId": "thread", "executionId": "e1"},
		{"threadId": "missing", "executionId": "e1"},
	}})
	duplicateResult, err := r.Invoke(t.Context(), "thread:execution-previews", []json.RawMessage{duplicate})
	if err != nil {
		t.Fatal(err)
	}
	duplicateBytes, _ := json.Marshal(duplicateResult)
	if err := json.Unmarshal(duplicateBytes, &response); err != nil {
		t.Fatal(err)
	}
	if len(response.Previews) != 1 || response.Previews[0].ExecutionID != "e1" {
		t.Fatalf("duplicate/invalid preview references = %s", duplicateBytes)
	}
	many := make([]map[string]any, 257)
	for index := range many {
		many[index] = map[string]any{"threadId": "thread", "executionId": "e1"}
	}
	oversized, _ := json.Marshal(map[string]any{"references": many})
	if _, err := r.Invoke(t.Context(), "thread:execution-previews", []json.RawMessage{oversized}); err == nil {
		t.Fatal("accepted more than 256 execution references")
	}
	exact := make([]map[string]any, 256)
	for index := range exact {
		exact[index] = map[string]any{"threadId": "thread", "executionId": fmt.Sprintf("missing-%d", index)}
	}
	exactRequest, _ := json.Marshal(map[string]any{"references": exact})
	exactResult, err := r.Invoke(t.Context(), "thread:execution-previews", []json.RawMessage{exactRequest})
	if err != nil {
		t.Fatalf("256 references were rejected: %v", err)
	}
	exactBytes, _ := json.Marshal(exactResult)
	var exactResponse struct {
		Previews []model.ExecutionDigest `json:"previews"`
	}
	if err := json.Unmarshal(exactBytes, &exactResponse); err != nil || len(exactResponse.Previews) != 0 {
		t.Fatalf("256-reference response = %s, err=%v", exactBytes, err)
	}
	empty, _ := json.Marshal(map[string]any{"references": []any{}})
	emptyResult, err := r.Invoke(t.Context(), "thread:execution-previews", []json.RawMessage{empty})
	if err != nil {
		t.Fatal(err)
	}
	emptyBytes, _ := json.Marshal(emptyResult)
	if err := json.Unmarshal(emptyBytes, &exactResponse); err != nil || len(exactResponse.Previews) != 0 {
		t.Fatalf("empty preview response = %s, err=%v", emptyBytes, err)
	}
	for _, invalid := range []map[string]any{
		{},
		{"threadId": "", "executionId": "e1"},
		{"threadId": "thread"},
		{"threadId": "thread", "executionId": "e1", "extra": true},
	} {
		raw, _ := json.Marshal(map[string]any{"references": []any{invalid}})
		if _, err := r.Invoke(t.Context(), "thread:execution-previews", []json.RawMessage{raw}); err == nil {
			t.Fatalf("accepted invalid preview reference %+v", invalid)
		}
	}
	moku := thread
	moku.ID, moku.Moku = "moku-thread", true
	moku.ExecutionTitles = nil
	if _, err := db.Update(t.Context(), func(tx *store.Tx) error {
		return tx.Put("thread:moku-thread", moku)
	}); err != nil {
		t.Fatal(err)
	}
	mokuRequest, _ := json.Marshal(map[string]any{"references": []map[string]any{
		{"threadId": "thread", "executionId": "e1"},
		{"threadId": "moku-thread", "executionId": "e1"},
	}})
	mokuResult, err := r.Invoke(t.Context(), "thread:execution-previews", []json.RawMessage{mokuRequest})
	if err != nil {
		t.Fatal(err)
	}
	var mokuResponse struct {
		Previews []model.ExecutionDigest `json:"previews"`
	}
	mokuBytes, _ := json.Marshal(mokuResult)
	if err := json.Unmarshal(mokuBytes, &mokuResponse); err != nil {
		t.Fatal(err)
	}
	if len(mokuResponse.Previews) != 1 || mokuResponse.Previews[0].ThreadID != "thread" {
		t.Fatalf("Moku reference was not skipped: %s", mokuBytes)
	}

	mutations := make(chan json.RawMessage, 4)
	unsubscribe := r.SubscribeMutations(func(raw json.RawMessage) {
		select {
		case mutations <- raw:
		default:
		}
	})
	defer unsubscribe()
	if err := r.UpdateThread(t.Context(), "thread", func(thread *model.ThreadRecord) error {
		thread.Title = "Renamed fixture thread"
		thread.ExecutionTitles = map[string]string{"e1": "Renamed execution"}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	r.Publish()
	select {
	case mutation := <-mutations:
		if strings.Contains(string(mutation), "executionTitles") {
			t.Fatalf("mutation retained execution titles: %s", mutation)
		}
		if len(mutation) > model.MaxThreadOverviewBytes {
			t.Fatalf("mutation is %d bytes", len(mutation))
		}
		t.Logf("mutation envelope bytes=%d", len(mutation))
	case <-time.After(2 * time.Second):
		t.Fatal("thread mutation was not published")
	}
	updated, err := r.Thread("thread")
	if err != nil {
		t.Fatal(err)
	}
	content, err = r.ReadThreadContent(t.Context(), "thread", transport.ContentScope{Kind: "thread"}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if content.Revision != updated.Revision {
		t.Fatalf("content revision = %d, Thread revision = %d", content.Revision, updated.Revision)
	}
	if err := json.Unmarshal(content.Value, &envelope); err != nil {
		t.Fatal(err)
	}
	if envelope.ExecutionTitles["e1"] != "Renamed execution" {
		t.Fatalf("adapter path lost the runtime title overlay: %s", content.Value)
	}
}

func TestCatalogStripsPreloadedExecutionTitles(t *testing.T) {
	dir := t.TempDir()
	db, err := store.Open(filepath.Join(dir, "state.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	state := catalogFixtureState{Body: "bounded card", Executions: []model.ExecutionDigest{{ExecutionID: "e1", Status: "completed", StartedAt: 1, Excerpt: "excerpt"}}}
	rawState, err := json.Marshal(state)
	if err != nil {
		t.Fatal(err)
	}
	thread := model.ThreadRecord{SessionRecord: model.SessionRecord{ID: "thread", HarnessID: "fixture", Revision: 1, SessionState: rawState, Settings: json.RawMessage(`{}`), Cwd: dir, CreatedAt: 1, UpdatedAt: 1}, Title: "Fixture", Tags: []string{}, TagEmojis: map[string]string{}, ExecutionTitles: map[string]string{"e1": "Title"}}
	if _, err := db.Update(t.Context(), func(tx *store.Tx) error {
		if err := tx.Put("thread:thread", thread); err != nil {
			return err
		}
		return tx.Put("threads", []string{"thread"})
	}); err != nil {
		t.Fatal(err)
	}
	r, err := New(t.Context(), Config{Store: db, DataDir: dir, DefaultCwd: dir, Harnesses: map[string]plugin.Harness{"fixture": catalogFixtureHarness{adapter: catalogFixtureAdapter{}}}})
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close(context.Background())
	snapshot := db.Snapshot()
	hash, _ := snapshot.RecordHash("thread:thread")
	raw, _ := snapshot.Raw("thread:thread")
	var rawRecord model.ThreadRecord
	if err := json.Unmarshal(raw, &rawRecord); err != nil {
		t.Fatal(err)
	}
	rawRecord.ExecutionTitles = map[string]string{"e1": "Preloaded title"}
	r.overviewCache["thread"] = cachedOverview{hash: hash, record: rawRecord}
	for i := 0; i < 2; i++ {
		app, err := r.Snapshot()
		if err != nil {
			t.Fatal(err)
		}
		if len(app.Threads) != 1 || app.Threads[0].ExecutionTitles != nil {
			t.Fatalf("snapshot %d retained preloaded titles: %+v", i, app.Threads)
		}
	}
	direct, err := r.projectChangedThread(snapshot, "thread")
	if err != nil {
		t.Fatal(err)
	}
	if direct.ExecutionTitles != nil {
		t.Fatalf("cache-hit catalog record retained titles: %+v", direct.ExecutionTitles)
	}
	mutations := make(chan json.RawMessage, 1)
	unsubscribe := r.SubscribeMutations(func(raw json.RawMessage) {
		select {
		case mutations <- raw:
		default:
		}
	})
	defer unsubscribe()
	if err := r.UpdateThread(t.Context(), "thread", func(thread *model.ThreadRecord) error {
		thread.Title = "Renamed"
		thread.ExecutionTitles = map[string]string{"e1": "Renamed title"}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	r.Publish()
	select {
	case mutation := <-mutations:
		if strings.Contains(string(mutation), "executionTitles") {
			t.Fatalf("mutation retained preloaded titles: %s", mutation)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("mutation was not published")
	}
}

func TestEnvelopeKnownRevisionSkipsAdapter(t *testing.T) {
	dir := t.TempDir()
	db, err := store.Open(filepath.Join(dir, "state.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	var calls atomic.Int64
	state := catalogFixtureState{Body: strings.Repeat("x", 4<<20), Executions: []model.ExecutionDigest{}}
	rawState, err := json.Marshal(state)
	if err != nil {
		t.Fatal(err)
	}
	thread := model.ThreadRecord{SessionRecord: model.SessionRecord{ID: "thread", HarnessID: "fixture", Revision: 7, SessionState: rawState, Settings: json.RawMessage(`{}`), Cwd: dir, CreatedAt: 1, UpdatedAt: 1}, Title: "Fixture", Tags: []string{}, TagEmojis: map[string]string{}}
	if _, err := db.Update(t.Context(), func(tx *store.Tx) error { return tx.Put("thread:thread", thread) }); err != nil {
		t.Fatal(err)
	}
	r, err := New(t.Context(), Config{Store: db, DataDir: dir, DefaultCwd: dir, Harnesses: map[string]plugin.Harness{"fixture": catalogFixtureHarness{adapter: catalogFixtureAdapter{calls: &calls}}}})
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close(context.Background())
	calls.Store(0)
	known := thread.Revision
	result, err := r.ReadThreadContent(t.Context(), "thread", transport.ContentScope{Kind: "thread"}, &known)
	if err != nil {
		t.Fatal(err)
	}
	if result != nil || calls.Load() != 0 {
		t.Fatalf("known envelope revision called adapter: result=%v calls=%d", result, calls.Load())
	}
}

func TestExecutionPageRejectsScopeMismatch(t *testing.T) {
	page := model.ExecutionDirectoryPage{Version: 1, Offset: 0, Limit: 1, Total: 2, Executions: []model.ExecutionDigest{}}
	raw, err := json.Marshal(page)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := projectExecutionPage(raw, transport.ContentScope{Kind: "directory", Offset: 1, Limit: 1}, nil); err == nil {
		t.Fatal("mismatched execution page scope was accepted")
	}
	page.Offset = 1
	raw, _ = json.Marshal(page)
	if _, err := projectExecutionPage(raw, transport.ContentScope{Kind: "directory", Offset: 1, Limit: 1}, nil); err != nil {
		t.Fatalf("matching execution page scope failed: %v", err)
	}
}

func TestThreadTitleOnlyChangeBypassesKnownEnvelopeShortcut(t *testing.T) {
	dir := t.TempDir()
	db, err := store.Open(filepath.Join(dir, "state.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	state := catalogFixtureState{Body: "stable", Executions: []model.ExecutionDigest{}}
	rawState, err := json.Marshal(state)
	if err != nil {
		t.Fatal(err)
	}
	thread := model.ThreadRecord{SessionRecord: model.SessionRecord{ID: "thread", HarnessID: "fixture", Revision: 1, SessionState: rawState, Settings: json.RawMessage(`{}`), Cwd: dir, CreatedAt: 1, UpdatedAt: 1}, Title: "Before", Tags: []string{}, TagEmojis: map[string]string{}}
	if _, err := db.Update(t.Context(), func(tx *store.Tx) error { return tx.Put("thread:thread", thread) }); err != nil {
		t.Fatal(err)
	}
	r, err := New(t.Context(), Config{Store: db, DataDir: dir, DefaultCwd: dir, Harnesses: map[string]plugin.Harness{"fixture": catalogFixtureHarness{adapter: catalogFixtureAdapter{}}}})
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close(context.Background())
	before, err := r.ReadThreadContent(t.Context(), "thread", transport.ContentScope{Kind: "thread"}, nil)
	if err != nil || before == nil {
		t.Fatalf("initial thread content = %v, %v", before, err)
	}
	if err := r.UpdateThread(t.Context(), "thread", func(thread *model.ThreadRecord) error {
		thread.Title = "After"
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	r.Publish()
	after, err := r.ReadThreadContent(t.Context(), "thread", transport.ContentScope{Kind: "thread"}, &before.Revision)
	if err != nil {
		t.Fatal(err)
	}
	if after == nil {
		t.Fatal("title-only change was lost behind known envelope revision")
	}
	updated, err := r.Thread("thread")
	if err != nil {
		t.Fatal(err)
	}
	if updated.Title != "After" {
		t.Fatalf("title-only update lost the Thread title: %q", updated.Title)
	}
	if after.Revision != updated.Revision || after.Revision == before.Revision {
		t.Fatalf("title-only revision = %d, before=%d, Thread=%d", after.Revision, before.Revision, updated.Revision)
	}
	var envelope threadContentEnvelope
	if err := json.Unmarshal(after.Value, &envelope); err != nil {
		t.Fatal(err)
	}
	if len(envelope.ExecutionTitles) != 0 {
		t.Fatalf("title-only update synthesized execution titles: %+v", envelope.ExecutionTitles)
	}
}

func TestRuntimeRejectsDirectoryScopeMismatch(t *testing.T) {
	dir := t.TempDir()
	db, err := store.Open(filepath.Join(dir, "state.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	state := catalogFixtureState{Executions: []model.ExecutionDigest{
		{ExecutionID: "e1", Status: "completed", StartedAt: 1, Excerpt: "one"},
		{ExecutionID: "e2", Status: "completed", StartedAt: 2, Excerpt: "two"},
	}}
	rawState, err := json.Marshal(state)
	if err != nil {
		t.Fatal(err)
	}
	thread := model.ThreadRecord{SessionRecord: model.SessionRecord{ID: "thread", HarnessID: "fixture", Revision: 1, SessionState: rawState, Settings: json.RawMessage(`{}`), Cwd: dir, CreatedAt: 1, UpdatedAt: 1}, Title: "Thread", Tags: []string{}, TagEmojis: map[string]string{}}
	if _, err := db.Update(t.Context(), func(tx *store.Tx) error { return tx.Put("thread:thread", thread) }); err != nil {
		t.Fatal(err)
	}
	r, err := New(t.Context(), Config{Store: db, DataDir: dir, DefaultCwd: dir, Harnesses: map[string]plugin.Harness{"fixture": catalogFixtureHarness{adapter: catalogFixtureAdapter{badDirectory: true}}}})
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close(context.Background())
	if _, err := r.ReadThreadContent(t.Context(), "thread", transport.ContentScope{Kind: "directory", Offset: 1, Limit: 1}, nil); err == nil || !strings.Contains(err.Error(), "scope mismatch") {
		t.Fatalf("runtime directory mismatch error = %v", err)
	}
}

func TestRuntimeRejectsDirectoryLimitMismatch(t *testing.T) {
	dir := t.TempDir()
	db, err := store.Open(filepath.Join(dir, "state.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	state := catalogFixtureState{Executions: []model.ExecutionDigest{
		{ExecutionID: "e1", Status: "completed", StartedAt: 1, Excerpt: "one"},
		{ExecutionID: "e2", Status: "completed", StartedAt: 2, Excerpt: "two"},
	}}
	rawState, err := json.Marshal(state)
	if err != nil {
		t.Fatal(err)
	}
	thread := model.ThreadRecord{SessionRecord: model.SessionRecord{ID: "thread", HarnessID: "fixture", Revision: 1, SessionState: rawState, Settings: json.RawMessage(`{}`), Cwd: dir, CreatedAt: 1, UpdatedAt: 1}, Title: "Thread", Tags: []string{}, TagEmojis: map[string]string{}}
	if _, err := db.Update(t.Context(), func(tx *store.Tx) error { return tx.Put("thread:thread", thread) }); err != nil {
		t.Fatal(err)
	}
	r, err := New(t.Context(), Config{Store: db, DataDir: dir, DefaultCwd: dir, Harnesses: map[string]plugin.Harness{"fixture": catalogFixtureHarness{adapter: catalogFixtureAdapter{badDirectoryLimit: true}}}})
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close(context.Background())
	if _, err := r.ReadThreadContent(t.Context(), "thread", transport.ContentScope{Kind: "directory", Offset: 0, Limit: 1}, nil); err == nil || !strings.Contains(err.Error(), "scope mismatch") {
		t.Fatalf("runtime directory limit mismatch error = %v", err)
	}
}

func TestExecutionPreviewsSameThreadKeepsReferenceOrder(t *testing.T) {
	dir := t.TempDir()
	db, err := store.Open(filepath.Join(dir, "state.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	executions := make([]model.ExecutionDigest, 24)
	references := make([]map[string]any, 0, len(executions))
	for i := range executions {
		id := fmt.Sprintf("e%02d", i)
		executions[i] = model.ExecutionDigest{ExecutionID: id, Status: "completed", StartedAt: int64(i + 1), Excerpt: id}
		references = append(references, map[string]any{"threadId": "thread", "executionId": id})
	}
	state := catalogFixtureState{Executions: executions}
	rawState, err := json.Marshal(state)
	if err != nil {
		t.Fatal(err)
	}
	thread := model.ThreadRecord{SessionRecord: model.SessionRecord{ID: "thread", HarnessID: "fixture", Revision: 1, SessionState: rawState, Settings: json.RawMessage(`{}`), Cwd: dir, CreatedAt: 1, UpdatedAt: 1}, Title: "Thread", Tags: []string{}, TagEmojis: map[string]string{}}
	if _, err := db.Update(t.Context(), func(tx *store.Tx) error { return tx.Put("thread:thread", thread) }); err != nil {
		t.Fatal(err)
	}
	r, err := New(t.Context(), Config{Store: db, DataDir: dir, DefaultCwd: dir, Harnesses: map[string]plugin.Harness{"fixture": catalogFixtureHarness{adapter: catalogFixtureAdapter{}}}})
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close(context.Background())
	raw, _ := json.Marshal(map[string]any{"references": references})
	result, err := r.Invoke(t.Context(), "thread:execution-previews", []json.RawMessage{raw})
	if err != nil {
		t.Fatal(err)
	}
	encoded, _ := json.Marshal(result)
	var response struct {
		Previews []model.ExecutionDigest `json:"previews"`
	}
	if err := json.Unmarshal(encoded, &response); err != nil {
		t.Fatal(err)
	}
	if len(response.Previews) != len(executions) {
		t.Fatalf("preview count = %d", len(response.Previews))
	}
	for index, preview := range response.Previews {
		if preview.ExecutionID != executions[index].ExecutionID {
			t.Fatalf("preview order[%d] = %s want %s", index, preview.ExecutionID, executions[index].ExecutionID)
		}
	}
}
