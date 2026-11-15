package runtime

import (
	"context"
	"encoding/json"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/platform/transport"
)

type detailFixtureAdapter struct {
	catalogFixtureAdapter
	mu          sync.Mutex
	projections int
	bodies      int
	bodyText    string
}

func (a *detailFixtureAdapter) ProjectDetail(json.RawMessage, model.DetailRequest) (model.DetailProjection, error) {
	a.mu.Lock()
	a.projections++
	a.mu.Unlock()
	return model.DetailProjection{Items: []model.DetailItem{{ID: "row", Kind: "activity",
		Bodies: []model.DetailBody{{Slot: "detail", Format: model.DetailBodyText, Length: 8}}}}}, nil
}

func (a *detailFixtureAdapter) ReadDetailBody(json.RawMessage, model.DetailBodyRequest) (model.DetailBody, error) {
	a.mu.Lock()
	a.bodies++
	a.mu.Unlock()
	text := a.bodyText
	if text == "" {
		text = "fixture body"
	}
	return model.DetailBody{Slot: "detail", Format: model.DetailBodyText, Text: text}, nil
}

func (a *detailFixtureAdapter) counts() (projections, bodies int) {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.projections, a.bodies
}

type detailFixtureHarness struct{ adapter *detailFixtureAdapter }

func (h detailFixtureHarness) Descriptor() plugin.HarnessDescriptor {
	return plugin.HarnessDescriptor{ID: "fixture", DisplayName: "Fixture"}
}
func (h detailFixtureHarness) DefaultSettings() json.RawMessage { return json.RawMessage(`{}`) }
func (h detailFixtureHarness) Detect(context.Context, string) (plugin.Installation, error) {
	return plugin.Installation{Status: "installed"}, nil
}
func (h detailFixtureHarness) Settings() plugin.HarnessSettings { return nil }
func (h detailFixtureHarness) SessionState() plugin.SessionStateAdapter {
	return h.adapter
}
func (h detailFixtureHarness) Metadata() plugin.ThreadMetadataAdapter {
	return plugin.GeneratedThreadMetadata{}
}
func (h detailFixtureHarness) Open(context.Context, plugin.OpenContext) (plugin.Handle, error) {
	return nil, nil
}

func TestDetailReadsReuseKnownRevisionAndContentIdentity(t *testing.T) {
	dir := t.TempDir()
	db, err := store.Open(filepath.Join(dir, "state.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	thread := model.ThreadRecord{SessionRecord: model.SessionRecord{ID: "thread", HarnessID: "fixture", Revision: 1,
		SessionState: json.RawMessage(`{"body":"fixture body"}`), Settings: json.RawMessage(`{}`),
		Cwd: dir, CreatedAt: 1, UpdatedAt: 1}, Title: "Original"}
	if _, err = db.Update(t.Context(), func(tx *store.Tx) error {
		if err := tx.Put("thread:thread", thread); err != nil {
			return err
		}
		return tx.Put("threads", []string{"thread"})
	}); err != nil {
		t.Fatal(err)
	}
	adapter := &detailFixtureAdapter{}
	r, err := New(t.Context(), Config{Store: db, DataDir: dir, DefaultCwd: dir,
		Harnesses: map[string]plugin.Harness{"fixture": detailFixtureHarness{adapter: adapter}}})
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close(context.Background())
	detailScope := transport.ContentScope{Kind: "detail", Key: "execution", Items: []string{"row"}}
	bodyScope := transport.ContentScope{Kind: "body", Key: "execution", Items: []string{"row"}, Slot: "detail"}
	first, err := r.ReadThreadContent(context.Background(), "thread", detailScope, nil)
	if err != nil || first == nil || first.Revision != 1 {
		t.Fatalf("first detail read = %+v, %v", first, err)
	}
	known := int64(1)
	if snapshot, err := r.ReadThreadContent(context.Background(), "thread", detailScope, &known); err != nil || snapshot != nil {
		t.Fatalf("known detail read = %+v, %v", snapshot, err)
	}
	if snapshot, err := r.ReadThreadContent(context.Background(), "thread", bodyScope, &known); err != nil || snapshot != nil {
		t.Fatalf("known body read = %+v, %v", snapshot, err)
	}
	if projections, bodies := adapter.counts(); projections != 1 || bodies != 0 {
		t.Fatalf("known revision still projected: projections=%d bodies=%d", projections, bodies)
	}
	if _, err := r.ReadThreadContent(context.Background(), "thread", bodyScope, nil); err != nil {
		t.Fatal(err)
	}
	if projections, bodies := adapter.counts(); projections != 1 || bodies != 1 {
		t.Fatalf("body read counts = projections=%d bodies=%d", projections, bodies)
	}
	if err := r.UpdateThread(context.Background(), "thread", func(t *model.ThreadRecord) error {
		t.Title = "Renamed"
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if snapshot, err := r.ReadThreadContent(context.Background(), "thread", detailScope, &known); err != nil || snapshot == nil || snapshot.Revision != 2 {
		t.Fatalf("metadata update detail read = %+v, %v", snapshot, err)
	}
	updated := int64(2)
	if snapshot, err := r.ReadThreadContent(context.Background(), "thread", detailScope, &updated); err != nil || snapshot != nil {
		t.Fatalf("current metadata revision still projected detail: %+v, %v", snapshot, err)
	}
	if _, err := r.ReadThreadContent(context.Background(), "thread", bodyScope, nil); err != nil {
		t.Fatal(err)
	}
	if projections, bodies := adapter.counts(); projections != 2 || bodies != 1 {
		t.Fatalf("metadata-only update evicted detail bodies: projections=%d bodies=%d", projections, bodies)
	}
	var firstDirectory, secondDirectory model.DetailDirectory
	if err := json.Unmarshal(first.Value, &firstDirectory); err != nil {
		t.Fatal(err)
	}
	if directory, err := r.ReadThreadContent(context.Background(), "thread", detailScope, nil); err != nil {
		t.Fatal(err)
	} else if err := json.Unmarshal(directory.Value, &secondDirectory); err != nil {
		t.Fatal(err)
	}
	if firstDirectory.ContentID == "" || firstDirectory.ContentID != secondDirectory.ContentID {
		t.Fatalf("metadata-only update changed the content identity: %q != %q", firstDirectory.ContentID, secondDirectory.ContentID)
	}
}

func TestDetailBodiesRetainLargePagesAcrossMetadataUpdates(t *testing.T) {
	dir := t.TempDir()
	db, err := store.Open(filepath.Join(dir, "state.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	thread := model.ThreadRecord{SessionRecord: model.SessionRecord{ID: "thread", HarnessID: "fixture", Revision: 1,
		SessionState: json.RawMessage(`{"body":"large"}`), Settings: json.RawMessage(`{}`),
		Cwd: dir, CreatedAt: 1, UpdatedAt: 1}, Title: "Large"}
	if _, err = db.Update(t.Context(), func(tx *store.Tx) error {
		if err := tx.Put("thread:thread", thread); err != nil {
			return err
		}
		return tx.Put("threads", []string{"thread"})
	}); err != nil {
		t.Fatal(err)
	}
	const bodyBytes = 24 << 20
	adapter := &detailFixtureAdapter{bodyText: strings.Repeat("x", bodyBytes)}
	r, err := New(t.Context(), Config{Store: db, DataDir: dir, DefaultCwd: dir,
		Harnesses: map[string]plugin.Harness{"fixture": detailFixtureHarness{adapter: adapter}}})
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close(context.Background())
	read := func(item string) {
		t.Helper()
		scope := transport.ContentScope{Kind: "body", Key: "execution", Items: []string{item}, Slot: "detail"}
		if _, err := r.ReadThreadContent(context.Background(), "thread", scope, nil); err != nil {
			t.Fatal(err)
		}
	}
	for _, item := range []string{"a", "b", "c", "d"} {
		read(item)
	}
	r.detailMu.Lock()
	retained := r.detailBytes
	r.detailMu.Unlock()
	if retained != 4*bodyBytes {
		t.Fatalf("retained detail bytes = %d", retained)
	}
	// Metadata-only updates keep the same SessionState content identity, so the
	// four large bodies stay resident instead of being parsed and hashed again.
	if err := r.UpdateThread(context.Background(), "thread", func(t *model.ThreadRecord) error {
		t.Title = "Renamed"
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	for _, item := range []string{"a", "b", "c", "d"} {
		read(item)
	}
	if _, bodies := adapter.counts(); bodies != 4 {
		t.Fatalf("metadata update re-read detail bodies: %d", bodies)
	}
	read("e")
	r.detailMu.Lock()
	_, oldest := r.detailCache[detailCacheKey("thread", sessionContentID(thread.SessionState), "execution", "a", "detail")]
	retained = r.detailBytes
	r.detailMu.Unlock()
	if oldest || retained > detailCacheMaxBytes {
		t.Fatalf("fifth large body did not evict the oldest entry: retained=%d", retained)
	}
}
