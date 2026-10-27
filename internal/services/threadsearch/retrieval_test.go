package threadsearch

import (
	"context"
	"errors"
	"math"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/store"
)

type performanceProvider struct {
	available atomic.Bool
	calls     atomic.Int64
	run       func(context.Context, string) ([]float32, error)
}

func (*performanceProvider) Model() string                    { return "synthetic" }
func (p *performanceProvider) Available(context.Context) bool { return p.available.Load() }
func (p *performanceProvider) Embed(ctx context.Context, text string, _ int) ([]float32, error) {
	p.calls.Add(1)
	if p.run != nil {
		return p.run(ctx, text)
	}
	return performanceVector(), nil
}
func performanceVector() []float32 {
	v := make([]float32, Dimensions)
	for i := range v {
		v[i] = float32(math.Sin(float64(i+1))) / 20
	}
	return v
}

type performanceRecord struct{ Title, Body string }
type performanceFixture struct {
	m  *Manager
	db *store.Store
	p  *performanceProvider
}

func newPerformanceFixture(t testing.TB, interval time.Duration) *performanceFixture {
	t.Helper()
	db, e := store.Open(filepath.Join(t.TempDir(), "state.sqlite"))
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { db.Close() })
	c := defaultConfig()
	c.IndexPaused = true
	_, e = db.Update(context.Background(), func(tx *store.Tx) error { return tx.Put(configKey, c) })
	if e != nil {
		t.Fatal(e)
	}
	p := &performanceProvider{}
	p.available.Store(true)
	m, e := New(context.Background(), Options{Store: db, Provider: p, WatchInterval: time.Hour, Interval: interval, Sources: func(s store.Snapshot, body bool) ([]Source, error) {
		out := []Source{}
		for _, key := range s.Keys("perf-source:") {
			var r performanceRecord
			if _, e := s.Get(key, &r); e != nil {
				return nil, e
			}
			hash, _ := s.RecordHash(key)
			source := Source{Ref: model.ThreadRef{TypeID: "agent", ThreadID: strings.TrimPrefix(key, "perf-source:")}, Owner: key, OwnerHash: hash, Identity: key, Title: r.Title}
			if body {
				source.LoadContent = func() (string, error) { return r.Body, nil }
			}
			out = append(out, source)
		}
		return out, nil
	}})
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { m.Close() })
	return &performanceFixture{m, db, p}
}
func (f *performanceFixture) seed(t testing.TB, id, title, body string, indexed bool) {
	t.Helper()
	_, e := f.db.Update(context.Background(), func(tx *store.Tx) error {
		key := "perf-source:" + id
		if e := tx.Put(key, performanceRecord{title, body}); e != nil {
			return e
		}
		if !indexed {
			return nil
		}
		hash, _ := tx.RecordHash(key)
		s := Source{Ref: model.ThreadRef{TypeID: "agent", ThreadID: id}, Owner: key, OwnerHash: hash, Identity: key, Title: title, Content: body}
		d := prepare(s, Document{})
		for i := range d.Chunks {
			d.Chunks[i].Vector = performanceVector()
		}
		return tx.Put(documentPrefix+RefKey(s.Ref), d)
	})
	if e != nil {
		t.Fatal(e)
	}
}
func (f *performanceFixture) query(t testing.TB, q string, ids ...string) QueryResult {
	t.Helper()
	r := QueryRequest{Query: q}
	for _, id := range ids {
		r.Threads = append(r.Threads, model.ThreadRef{TypeID: "agent", ThreadID: id})
	}
	out, e := f.m.Query(context.Background(), r)
	if e != nil {
		t.Fatal(e)
	}
	return out
}
func waitPerformance(t *testing.T, f func() bool) {
	t.Helper()
	until := time.Now().Add(5 * time.Second)
	for !f() {
		if time.Now().After(until) {
			t.Fatal("timed out")
		}
		time.Sleep(time.Millisecond)
	}
}

func TestRetrievalCacheTracksScopeSourcesIndexAndLifecycle(t *testing.T) {
	f := newPerformanceFixture(t, time.Nanosecond)
	f.seed(t, "a", "first", "public body", true)
	f.seed(t, "b", "second", "different body", true)
	out := f.query(t, "paraphrase", "a")
	if len(out.Hits) != 1 {
		t.Fatal(out)
	}
	// Returned slices belong to the caller, including on a cache hit.
	out.Hits[0].Score = -100
	out = f.query(t, "paraphrase", "a")
	out.Hits[0].Score = -200
	if out = f.query(t, "paraphrase", "a"); out.Hits[0].Score < 0 || f.p.calls.Load() != 1 {
		t.Fatal("cached hits alias caller data", out)
	}
	_, e := f.db.Update(context.Background(), func(tx *store.Tx) error { return tx.Put("unrelated", 1) })
	if e != nil {
		t.Fatal(e)
	}
	f.query(t, "paraphrase", "a")
	if f.p.calls.Load() != 1 {
		t.Fatal("unrelated write discarded vector")
	}
	if out = f.query(t, "paraphrase", "b"); len(out.Hits) != 1 || out.Hits[0].Ref.ThreadID != "b" {
		t.Fatal("scope reused wrong result", out)
	}
	// Same source, changed persisted vectors: a result must not outlive its index.
	_, e = f.db.Update(context.Background(), func(tx *store.Tx) error {
		key := documentPrefix + RefKey(model.ThreadRef{TypeID: "agent", ThreadID: "a"})
		var d Document
		_, e := tx.Get(key, &d)
		if e != nil {
			return e
		}
		for i := range d.Chunks {
			for j := range d.Chunks[i].Vector {
				d.Chunks[i].Vector[j] *= -1
			}
		}
		return tx.Put(key, d)
	})
	if e != nil {
		t.Fatal(e)
	}
	if out = f.query(t, "paraphrase", "a"); len(out.Hits) != 0 {
		t.Fatal("stale index result", out)
	}
	f.seed(t, "a", "paraphrase", "changed body", false)
	if out = f.query(t, "paraphrase", "a"); len(out.Hits) != 1 || out.Hits[0].Score < 3 {
		t.Fatal("metadata not refreshed", out)
	}
	f.seed(t, "a", "first", "public body", true)
	f.query(t, "paraphrase", "a")
	f.p.available.Store(false)
	if out = f.query(t, "paraphrase", "a"); out.Mode != "keyword" || out.Reason != "model-missing" {
		t.Fatal("cached success hid model failure", out)
	}
	f.p.available.Store(true)
	if out = f.query(t, "paraphrase", "a"); out.Mode != "hybrid" {
		t.Fatal("model recovery", out)
	}
	if e = f.m.Pause(); e != nil {
		t.Fatal(e)
	}
	if out = f.query(t, "paraphrase", "a"); len(out.Hits) != 0 {
		t.Fatal("paused cache leaked")
	}
	f.m.Resume()
	_, e = f.db.Update(context.Background(), func(tx *store.Tx) error {
		if e := DeleteOwner(tx, "perf-source:a"); e != nil {
			return e
		}
		return tx.Delete("perf-source:a")
	})
	if e != nil {
		t.Fatal(e)
	}
	if out = f.query(t, "paraphrase", "a"); len(out.Hits) != 0 {
		t.Fatal("deleted cache leaked")
	}
	_, e = f.db.Update(context.Background(), ClearHistory)
	if e != nil {
		t.Fatal(e)
	}
	if out = f.query(t, "paraphrase", "b"); len(out.Hits) != 0 {
		t.Fatal("cleared cache leaked")
	}
}

func TestIndexYieldsToQueryAndRestsAfterInference(t *testing.T) {
	f := newPerformanceFixture(t, 30*time.Millisecond)
	f.seed(t, "a", "indexing", strings.Repeat("index body ", 300), false)
	f.seed(t, "b", "existing", "query body", true)
	entered, release := make(chan struct{}), make(chan struct{})
	var once sync.Once
	var mu sync.Mutex
	var starts []string
	var indexFinish, nextIndex time.Time
	f.p.run = func(ctx context.Context, text string) ([]float32, error) {
		mu.Lock()
		starts = append(starts, text)
		n := len(starts)
		if n > 1 && strings.HasPrefix(text, "title:") && nextIndex.IsZero() {
			nextIndex = time.Now()
		}
		mu.Unlock()
		if n == 1 {
			once.Do(func() { close(entered) })
			select {
			case <-release:
			case <-ctx.Done():
				return nil, ctx.Err()
			}
			mu.Lock()
			indexFinish = time.Now()
			mu.Unlock()
		}
		return performanceVector(), nil
	}
	_, e := f.m.Index(context.Background(), IndexRequest{Action: "start", Consent: true})
	if e != nil {
		t.Fatal(e)
	}
	select {
	case <-entered:
	case <-time.After(5 * time.Second):
		t.Fatal("index not started")
	}
	done := make(chan error, 1)
	go func() {
		_, e := f.m.Query(context.Background(), QueryRequest{Query: "interactive", Threads: []model.ThreadRef{{TypeID: "agent", ThreadID: "b"}}})
		done <- e
	}()
	waitPerformance(t, func() bool { f.m.gate.mu.Lock(); defer f.m.gate.mu.Unlock(); return f.m.gate.queries > 0 })
	// Ensure inference itself took longer than the configured start spacing.
	time.Sleep(45 * time.Millisecond)
	close(release)
	select {
	case e := <-done:
		if e != nil {
			t.Fatal(e)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("query blocked")
	}
	waitPerformance(t, func() bool { s, e := f.m.Status(context.Background()); return e == nil && !s.Working && s.Indexed == 2 })
	mu.Lock()
	defer mu.Unlock()
	if len(starts) < 3 || !strings.HasPrefix(starts[1], "task: search result") {
		t.Fatal("background inference passed waiting query", starts)
	}
	if nextIndex.Sub(indexFinish) < 25*time.Millisecond {
		t.Fatal("no post-inference rest", nextIndex.Sub(indexFinish))
	}
}

func TestIndexCheckpointsReduceWritesAndResumeAfterFailure(t *testing.T) {
	f := newPerformanceFixture(t, time.Nanosecond)
	f.seed(t, "a", "checkpoint", strings.Repeat("checkpoint content ", 1000), false)
	calls := 0
	f.p.run = func(context.Context, string) ([]float32, error) {
		calls++
		if calls == 12 {
			return nil, errors.New("synthetic failure")
		}
		return performanceVector(), nil
	}
	before := f.db.Snapshot().Revision()
	_, e := f.m.Index(context.Background(), IndexRequest{Action: "start", Consent: true})
	if e != nil {
		t.Fatal(e)
	}
	waitPerformance(t, func() bool { s, e := f.m.Status(context.Background()); return e == nil && !s.Working && s.Reason != "" })
	after := f.db.Snapshot().Revision()
	if after-before != 3 {
		t.Fatal("expected one control write, one checkpoint, one error flush", after-before)
	}
	key := documentPrefix + RefKey(model.ThreadRef{TypeID: "agent", ThreadID: "a"})
	var d Document
	_, e = f.db.Snapshot().Get(key, &d)
	if e != nil {
		t.Fatal(e)
	}
	completed := 0
	for _, c := range d.Chunks {
		if validVector(c.Vector) {
			completed++
		}
	}
	if completed != 11 {
		t.Fatal("lost error checkpoint", completed)
	}
	f.p.run = nil
	s, e := f.m.Status(context.Background())
	if e != nil {
		t.Fatal(e)
	}
	beforeCalls := f.p.calls.Load()
	_, e = f.m.Index(context.Background(), IndexRequest{Action: "start", Consent: true, ExpectedRevision: s.Config.Revision})
	if e != nil {
		t.Fatal(e)
	}
	waitPerformance(t, func() bool { s, e := f.m.Status(context.Background()); return e == nil && !s.Working && s.Indexed == 1 })
	if got := int(f.p.calls.Load() - beforeCalls); got != len(d.Chunks)-completed {
		t.Fatal("resume recomputed completed vectors", got, len(d.Chunks)-completed)
	}
}

func TestInferencePriorityAndCancelledWaiter(t *testing.T) {
	var gate inferenceGate
	if e := gate.acquire(context.Background(), false); e != nil {
		t.Fatal(e)
	}
	acquired := make(chan string, 2)
	go func() {
		if e := gate.acquire(context.Background(), false); e == nil {
			acquired <- "index"
			gate.release()
		}
	}()
	queryCtx, cancel := context.WithCancel(context.Background())
	defer cancel()
	queryDone := make(chan error, 1)
	go func() { queryDone <- gate.acquire(queryCtx, true) }()
	waitPerformance(t, func() bool { gate.mu.Lock(); defer gate.mu.Unlock(); return gate.queries == 1 })
	cancel()
	select {
	case e := <-queryDone:
		if !errors.Is(e, context.Canceled) {
			t.Fatal(e)
		}
	case <-time.After(time.Second):
		t.Fatal("cancelled query held slot")
	}
	queryHeld, releaseQuery := make(chan struct{}), make(chan struct{})
	go func() {
		if e := gate.acquire(context.Background(), true); e == nil {
			acquired <- "query"
			close(queryHeld)
			<-releaseQuery
			gate.release()
		}
	}()
	waitPerformance(t, func() bool { gate.mu.Lock(); defer gate.mu.Unlock(); return gate.queries == 1 })
	gate.release()
	select {
	case first := <-acquired:
		if first != "query" {
			t.Fatal("index passed interactive query")
		}
	case <-time.After(time.Second):
		t.Fatal("no inference progressed")
	}
	<-queryHeld
	close(releaseQuery)
	select {
	case next := <-acquired:
		if next != "index" {
			t.Fatal(next)
		}
	case <-time.After(time.Second):
		t.Fatal("cancelled waiter starved index")
	}
}

func TestCachedResultRechecksConcurrentDeletion(t *testing.T) {
	f := newPerformanceFixture(t, time.Nanosecond)
	f.seed(t, "a", "indexed", "body", true)
	f.query(t, "paraphrase", "a")
	// Capture an immutable source snapshot, then delete during a potential hit.
	sources := f.m.options.Sources
	entered, release := make(chan struct{}), make(chan struct{})
	f.m.options.Sources = func(s store.Snapshot, body bool) ([]Source, error) {
		out, e := sources(s, body)
		close(entered)
		<-release
		return out, e
	}
	done := make(chan QueryResult, 1)
	go func() {
		r, _ := f.m.Query(context.Background(), QueryRequest{Query: "paraphrase", Threads: []model.ThreadRef{{TypeID: "agent", ThreadID: "a"}}})
		done <- r
	}()
	<-entered
	_, e := f.db.Update(context.Background(), func(tx *store.Tx) error {
		if e := DeleteOwner(tx, "perf-source:a"); e != nil {
			return e
		}
		return tx.Delete("perf-source:a")
	})
	if e != nil {
		t.Fatal(e)
	}
	close(release)
	select {
	case r := <-done:
		if len(r.Hits) != 0 {
			t.Fatal("cached hit resurrected deleted owner", r)
		}
	case <-time.After(time.Second):
		t.Fatal("query stuck")
	}
}
