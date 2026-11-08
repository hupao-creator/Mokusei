package threadsearch

import (
	"context"
	"errors"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/store"
)

type searchRecord struct {
	Title, Body string
	Busy        bool
}
type searchFixture struct {
	m        *Manager
	db       *store.Store
	loads    atomic.Int64
	failNext atomic.Bool
}

func newSearchFixture(t *testing.T, automatic bool) *searchFixture {
	t.Helper()
	db, err := store.Open(filepath.Join(t.TempDir(), "state.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	f := &searchFixture{db: db}
	interval := time.Hour
	if automatic {
		interval = 10 * time.Millisecond
	}
	f.m, err = New(context.Background(), Options{Store: db, WatchInterval: interval, RetryMin: 10 * time.Millisecond, Sources: func(snapshot store.Snapshot, body bool) ([]Source, error) {
		sources := []Source{}
		for _, key := range snapshot.Keys("source:") {
			var record searchRecord
			if _, err := snapshot.Get(key, &record); err != nil {
				return nil, err
			}
			hash, _ := snapshot.RecordHash(key)
			source := Source{Ref: model.ThreadRef{ThreadID: strings.TrimPrefix(key, "source:"), TypeID: "agent"}, Owner: key, OwnerHash: hash, Title: record.Title, Busy: record.Busy}
			if body {
				source.LoadContent = func() (string, error) {
					f.loads.Add(1)
					if f.failNext.Swap(false) {
						return "", errors.New("temporary extraction failure")
					}
					return record.Body, nil
				}
			}
			sources = append(sources, source)
		}
		return sources, nil
	}})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { f.m.Close() })
	return f
}
func (f *searchFixture) seed(t *testing.T, id string, value searchRecord) {
	t.Helper()
	_, err := f.db.Update(context.Background(), func(tx *store.Tx) error { return tx.Put("source:"+id, value) })
	if err != nil {
		t.Fatal(err)
	}
}
func (f *searchFixture) query(t *testing.T, text string, ids ...string) QueryResult {
	t.Helper()
	refs := []model.ThreadRef{}
	for _, id := range ids {
		refs = append(refs, model.ThreadRef{ThreadID: id, TypeID: "agent"})
	}
	result, err := f.m.Query(context.Background(), QueryRequest{Query: text, Threads: refs})
	if err != nil {
		t.Fatal(err)
	}
	return result
}
func (f *searchFixture) build(t *testing.T) {
	t.Helper()
	if err := f.m.build(context.Background()); err != nil {
		t.Fatal(err)
	}
}
func waitSearch(t *testing.T, condition func() bool) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for !condition() {
		if time.Now().After(deadline) {
			t.Fatal("search did not settle")
		}
		time.Sleep(5 * time.Millisecond)
	}
}
func TestKeywordScopeCacheAndSourceLifecycle(t *testing.T) {
	f := newSearchFixture(t, false)
	f.seed(t, "a", searchRecord{Title: "Maintenance", Body: "离线删除与后台清理"})
	f.seed(t, "b", searchRecord{Title: "exact-ID", Body: "different body"})
	f.build(t)
	for range 2 {
		result := f.query(t, "离线删除 后台", "a", "b")
		if result.Mode != "keyword" || len(result.Hits) != 1 || result.Hits[0].Ref.ThreadID != "a" {
			t.Fatalf("body AND query: %+v", result)
		}
	}
	if f.loads.Load() != 2 {
		t.Fatal("query reparsed source bodies")
	}
	if len(f.query(t, "清空历史", "a").Hits) != 0 || len(f.query(t, "离线删除", "b").Hits) != 0 {
		t.Fatal("nonliteral or out-of-scope hit")
	}
	// Native folded metadata matches still qualify, only within live scope.
	result, err := f.m.Query(context.Background(), QueryRequest{Query: "cafe", Threads: []model.ThreadRef{{ThreadID: "b", TypeID: "agent"}}, KeywordMatches: []model.ThreadRef{{ThreadID: "b", TypeID: "agent"}, {ThreadID: "a", TypeID: "agent"}}})
	if err != nil || len(result.Hits) != 1 || result.Hits[0].Ref.ThreadID != "b" {
		t.Fatalf("native metadata match: %+v %v", result, err)
	}
	f.seed(t, "a", searchRecord{Title: "Maintenance", Body: "replacement"})
	if len(f.query(t, "离线删除", "a").Hits) != 0 {
		t.Fatal("stale body returned after owner change")
	}
	f.build(t)
	if len(f.query(t, "replacement", "a").Hits) != 1 {
		t.Fatal("changed content missing")
	}
	_, err = f.db.Update(context.Background(), func(tx *store.Tx) error {
		if err := DeleteOwner(tx, "source:a"); err != nil {
			return err
		}
		return tx.Delete("source:a")
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(f.query(t, "replacement", "a").Hits) != 0 {
		t.Fatal("cached hit survived source deletion")
	}
}

func TestKeywordQueryRequiresEveryTerm(t *testing.T) {
	for _, field := range []string{"metadata", "body"} {
		t.Run(field, func(t *testing.T) {
			f := newSearchFixture(t, false)
			for _, source := range []struct{ id, text string }{
				{"complete", "离线删除与后台清理"},
				{"first-only", "离线删除"},
				{"second-only", "后台清理"},
			} {
				record := searchRecord{Title: source.text}
				if field == "body" {
					record = searchRecord{Title: "Maintenance", Body: source.text}
				}
				f.seed(t, source.id, record)
			}
			f.build(t)
			for _, partial := range []struct{ query, id string }{
				{"离线删除", "first-only"},
				{"后台", "second-only"},
			} {
				result := f.query(t, partial.query, partial.id)
				if len(result.Hits) != 1 || result.Hits[0].Ref.ThreadID != partial.id {
					t.Fatalf("partial fixture is not searchable: %+v", result)
				}
			}
			for _, query := range []string{"离线删除 后台", "后台 离线删除"} {
				for range 2 {
					result := f.query(t, query, "complete", "first-only", "second-only")
					if result.Mode != "keyword" || len(result.Hits) != 1 || result.Hits[0].Ref.ThreadID != "complete" {
						t.Fatalf("AND query %q returned a partial-term match: %+v", query, result)
					}
				}
			}
		})
	}
}

func TestLiteralSearchKeepsContinuousBoundedUnicodeBody(t *testing.T) {
	f := newSearchFixture(t, false)
	body := strings.Repeat("界", 1198) + "边界词" + strings.Repeat("尾", 140000) + "OUTSIDE_BOUND"
	f.seed(t, "a", searchRecord{Title: "body", Body: body})
	f.build(t)
	if len(f.query(t, "边界词", "a").Hits) != 1 || len(f.query(t, "OUTSIDE_BOUND", "a").Hits) != 0 {
		t.Fatal("continuous body or bound changed")
	}
	status, err := f.m.Status(context.Background())
	if err != nil || status.Truncated != 1 {
		t.Fatalf("truncation: %+v %v", status, err)
	}
}
func TestAutomaticIndexDefersBusySourcesAndReusesCurrentText(t *testing.T) {
	f := newSearchFixture(t, true)
	f.seed(t, "a", searchRecord{Title: "busy", Body: "completed text", Busy: true})
	time.Sleep(40 * time.Millisecond)
	if f.loads.Load() != 0 {
		t.Fatal("busy source extracted")
	}
	f.seed(t, "a", searchRecord{Title: "done", Body: "completed text"})
	waitSearch(t, func() bool { return len(f.query(t, "completed", "a").Hits) == 1 })
	loads := f.loads.Load()
	f.build(t)
	if f.loads.Load() != loads {
		t.Fatal("unchanged source extracted again")
	}
	if err := f.m.Pause(); err != nil {
		t.Fatal(err)
	}
	_, err := f.db.Update(context.Background(), ClearHistory)
	if err != nil {
		t.Fatal(err)
	}
	if len(f.query(t, "completed", "a").Hits) != 0 {
		t.Fatal("paused search returned hits")
	}
	f.m.Resume()
	waitSearch(t, func() bool { return len(f.query(t, "completed", "a").Hits) == 1 })
}
func TestCancellationAndHistoryClearFenceLateQueries(t *testing.T) {
	f := newSearchFixture(t, false)
	f.seed(t, "a", searchRecord{Title: "needle", Body: "text"})
	f.build(t)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err := f.m.Query(ctx, QueryRequest{Query: "needle", Threads: []model.ThreadRef{{ThreadID: "a", TypeID: "agent"}}})
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("cancellation: %v", err)
	}
	original := f.m.options.Sources
	entered, release := make(chan struct{}), make(chan struct{})
	f.m.options.Sources = func(snapshot store.Snapshot, body bool) ([]Source, error) {
		close(entered)
		<-release
		return original(snapshot, body)
	}
	done := make(chan QueryResult, 1)
	go func() {
		r, _ := f.m.Query(context.Background(), QueryRequest{Query: "needle", Threads: []model.ThreadRef{{ThreadID: "a", TypeID: "agent"}}})
		done <- r
	}()
	<-entered
	if err := f.m.Pause(); err != nil {
		t.Fatal(err)
	}
	_, err = f.db.Update(context.Background(), ClearHistory)
	if err != nil {
		t.Fatal(err)
	}
	close(release)
	if result := <-done; len(result.Hits) != 0 {
		t.Fatalf("late result escaped clear: %+v", result)
	}
	f.m.options.Sources = original
}
func TestLegacySearchMigrationPreservesSourceRecords(t *testing.T) {
	db, err := store.Open(filepath.Join(t.TempDir(), "state.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	_, err = db.Update(context.Background(), func(tx *store.Tx) error {
		if err := tx.Put("thread:keep", map[string]string{"body": "user content"}); err != nil {
			return err
		}
		if err := tx.Put(configKey, map[string]any{"pipeline": "old-vector-space", "revision": 7, "epoch": 2, "enabled": false, "indexPaused": true}); err != nil {
			return err
		}
		if err := tx.Put("search-usage", map[string]int{"requests": 10}); err != nil {
			return err
		}
		return tx.Put(documentPrefix+"old", map[string]any{"vector": []float32{1, 2}})
	})
	if err != nil {
		t.Fatal(err)
	}
	hash, _ := db.Snapshot().RecordHash("thread:keep")
	m, err := New(context.Background(), Options{Store: db, WatchInterval: time.Hour, Sources: func(store.Snapshot, bool) ([]Source, error) { return nil, nil }})
	if err != nil {
		t.Fatal(err)
	}
	defer m.Close()
	after, _ := db.Snapshot().RecordHash("thread:keep")
	config, err := readConfig(db.Snapshot())
	if err != nil || hash != after || config.Revision != 8 || config.Epoch != 3 || config.Pipeline != indexVersion || db.Snapshot().Has("search-usage") || len(db.Snapshot().Keys(documentPrefix)) != 0 {
		t.Fatalf("migration changed source or retained retired data: %+v %v", config, err)
	}
}

func TestAutomaticIndexRetriesExtractionWithoutNewMutation(t *testing.T) {
	f := newSearchFixture(t, true)
	f.failNext.Store(true)
	f.seed(t, "retry", searchRecord{Title: "Retry", Body: "eventual body"})
	waitSearch(t, func() bool { return len(f.query(t, "eventual", "retry").Hits) == 1 })
	if f.loads.Load() < 2 {
		t.Fatal("extraction failure was not retried")
	}
}

func TestIndexCommitRejectsDeletedSource(t *testing.T) {
	f := newSearchFixture(t, false)
	f.seed(t, "late", searchRecord{Title: "Late", Body: "deleted body"})
	original := f.m.options.Sources
	entered, release := make(chan struct{}), make(chan struct{})
	f.m.options.Sources = func(snapshot store.Snapshot, body bool) ([]Source, error) {
		sources, err := original(snapshot, body)
		if body {
			for i := range sources {
				load := sources[i].LoadContent
				sources[i].LoadContent = func() (string, error) { close(entered); <-release; return load() }
			}
		}
		return sources, err
	}
	done := make(chan error, 1)
	go func() { done <- f.m.build(context.Background()) }()
	<-entered
	_, err := f.db.Update(context.Background(), func(tx *store.Tx) error {
		if err := DeleteOwner(tx, "source:late"); err != nil {
			return err
		}
		return tx.Delete("source:late")
	})
	if err != nil {
		t.Fatal(err)
	}
	close(release)
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	if len(f.db.Snapshot().Keys(documentPrefix)) != 0 {
		t.Fatal("late extraction resurrected deleted source")
	}
}
