// Synthetic integration replay: managed local process + actual llama HTTP
// adapter + durable index and runtime lifecycle. No real history or model weights.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	core "github.com/hupao-creator/Mokusei/internal/core/runtime"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/services/localembedding"
	"github.com/hupao-creator/Mokusei/internal/services/threadsearch"
)

func must(err error) {
	if err != nil {
		panic(err)
	}
}
func assert(ok bool, message string) {
	if !ok {
		panic(message)
	}
}
func raw(value any) json.RawMessage { b, e := json.Marshal(value); must(e); return b }
func wait(label string, predicate func() bool) {
	deadline := time.Now().Add(12 * time.Second)
	for !predicate() {
		if time.Now().After(deadline) {
			panic("timeout: " + label)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

type harness struct{ plugin.Harness }

func (harness) Descriptor() plugin.HarnessDescriptor     { return plugin.HarnessDescriptor{ID: "fixture"} }
func (harness) DefaultSettings() json.RawMessage         { return raw(map[string]any{}) }
func (harness) SessionState() plugin.SessionStateAdapter { return adapter{} }
func (harness) Settings() plugin.HarnessSettings         { return settings{} }
func (harness) Open(context.Context, plugin.OpenContext) (plugin.Handle, error) {
	return nil, errors.New("fixture must never launch native sessions")
}

type settings struct{ plugin.HarnessSettings }

func (settings) Normalize(v json.RawMessage) (json.RawMessage, error) { return v, nil }

type adapter struct{ plugin.SessionStateAdapter }

func (adapter) ProjectRenderer(v json.RawMessage, _ model.RendererScope) (json.RawMessage, error) {
	return v, nil
}
func (adapter) SearchText(v json.RawMessage) (string, error) {
	var data struct {
		Text string `json:"text"`
	}
	e := json.Unmarshal(v, &data)
	return data.Text, e
}
func (adapter) ReadContext(v json.RawMessage) (json.RawMessage, error) { return v, nil }
func (adapter) Project(v json.RawMessage) (model.PublicObservation, error) {
	return model.PublicObservation{}, nil
}

type service struct {
	calls   atomic.Int64
	mode    atomic.Int64
	mu      sync.Mutex
	block   chan struct{}
	entered chan struct{}
	texts   []string
}

func (s *service) serve(w http.ResponseWriter, r *http.Request) {
	s.calls.Add(1)
	assert(r.Method == http.MethodPost, "embedding POST")
	assert(strings.HasPrefix(r.Header.Get("Authorization"), "Bearer ") && len(r.Header.Get("Authorization")) == 71, "ephemeral local authentication")
	data, e := io.ReadAll(r.Body)
	must(e)
	var request struct {
		Model    string `json:"model"`
		Input    string `json:"input"`
		Encoding string `json:"encoding_format"`
	}
	must(json.Unmarshal(data, &request))
	assert(request.Model == localembedding.Model && request.Encoding == "float", "actual llama.cpp request schema")
	text := request.Input
	assert(strings.HasPrefix(text, "title: ") || strings.HasPrefix(text, "task: search result | query: "), "Embedding 2 task formatting")
	assert(len(text) < 8192, "bounded text payload below worst-case token byte bound")
	assert(!strings.Contains(text, "NEVER_UPLOAD"), "excluded private/Moku/archive data")
	s.mu.Lock()
	s.texts = append(s.texts, text)
	block, entered := s.block, s.entered
	if entered != nil {
		s.entered = nil
		close(entered)
	}
	s.mu.Unlock()
	if block != nil {
		select {
		case <-block:
		case <-r.Context().Done():
			return
		}
	}
	switch s.mode.Load() {
	case 1:
		w.WriteHeader(429)
		_, _ = w.Write([]byte(`{"error":"do not leak service body"}`))
		return
	case 2:
		_, _ = w.Write([]byte(`{"data":[{"index":0,"embedding":[1,2]}]}`))
		return
	case 4:
		connection, _, err := w.(http.Hijacker).Hijack()
		must(err)
		_ = connection.Close()
		return
	case 5:
		w.WriteHeader(403)
		return
	case 3:
		w.Header().Set("Location", "http://127.0.0.1:1/never-follow")
		w.WriteHeader(302)
		return
	}
	vector := make([]float32, 768)
	if strings.Contains(text, "relevance-fixture-score:") {
		start := strings.Index(text, "relevance-fixture-score:")
		var score float64
		_, err := fmt.Sscanf(text[start:], "relevance-fixture-score:%f", &score)
		must(err)
		vector[0], vector[1] = float32(score), float32(math.Sqrt(1-score*score))
	} else if strings.Contains(text, "相关性校准") || strings.Contains(text, "离线删除") || strings.Contains(text, "清空历史") || strings.Contains(text, "delete history") {
		vector[0] = 1
	} else {
		vector[1] = 1
	}
	must(json.NewEncoder(w).Encode(map[string]any{"data": []any{map[string]any{"index": 0, "embedding": vector}}}))
}
func (s *service) hold() (chan struct{}, chan struct{}) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.block = make(chan struct{})
	s.entered = make(chan struct{})
	return s.block, s.entered
}
func (s *service) release() {
	s.mu.Lock()
	if s.block != nil {
		close(s.block)
	}
	s.block = nil
	s.entered = nil
	s.mu.Unlock()
}
func source(snapshot store.Snapshot, body bool) ([]threadsearch.Source, error) {
	result := []threadsearch.Source{}
	for _, key := range snapshot.Keys("thread:") {
		var t model.ThreadRecord
		_, err := snapshot.Get(key, &t)
		if err != nil {
			return nil, err
		}
		if t.Moku || t.Archived != nil && *t.Archived {
			continue
		}
		hash, _ := snapshot.RecordHash(key)
		item := threadsearch.Source{Ref: model.ThreadRef{ThreadID: t.ID, TypeID: "agent"}, Owner: key, OwnerHash: hash, Identity: key + "\x00" + fmt.Sprint(t.CreatedAt), Title: t.Title, Cwd: t.Cwd, Tags: t.Tags}
		item.Busy = t.Observation.BackgroundWork != nil || (t.Observation.LatestExecution != nil && !t.Observation.LatestExecution.Terminal())
		if body {
			item.LoadContent = func() (string, error) { return adapter{}.SearchText(t.SessionState) }
		}
		result = append(result, item)
	}
	return result, nil
}
func thread(id, title, text string) model.ThreadRecord {
	return model.ThreadRecord{SessionRecord: model.SessionRecord{ID: id, HarnessID: "fixture", Revision: 0, CreatedAt: 1, UpdatedAt: 1, Cwd: "/synthetic/项目", Settings: raw(map[string]any{}), SessionState: raw(map[string]any{"text": text, "private": "NEVER_UPLOAD"})}, Title: title, Tags: []string{"Maintenance"}, TagEmojis: map[string]string{"Maintenance": "🔧"}}
}
func seed(s *store.Store, threads ...model.ThreadRecord) {
	_, e := s.Update(context.Background(), func(tx *store.Tx) error {
		ids := tx.Order("threads")
		for _, t := range threads {
			if !tx.Has("thread:" + t.ID) {
				ids = append(ids, t.ID)
			}
			if e := tx.Put("thread:"+t.ID, t); e != nil {
				return e
			}
		}
		return tx.SetOrder("threads", ids)
	})
	must(e)
}
func invoke(r *core.Runtime, channel string, input ...any) any {
	args := []json.RawMessage{}
	for _, v := range input {
		args = append(args, raw(v))
	}
	out, e := r.Invoke(context.Background(), channel, args)
	must(e)
	return out
}
func status(r *core.Runtime) threadsearch.Status {
	return invoke(r, "search:status").(threadsearch.Status)
}
func settle(r *core.Runtime) { wait("index complete", func() bool { return !status(r).Working }) }
func start(r *core.Runtime) {
	s := status(r)
	invoke(r, "search:index", threadsearch.IndexRequest{Action: "start", Consent: true, ExpectedRevision: s.Config.Revision})
	settle(r)
}
func configure(r *core.Runtime, body, auto bool) {
	s := status(r)
	invoke(r, "search:configure", threadsearch.ConfigureRequest{ExpectedRevision: s.Config.Revision, IncludeContent: body, AutoUpdate: auto})
}
func query(r *core.Runtime, text string, refs ...model.ThreadRef) threadsearch.QueryResult {
	return invoke(r, "search:query", threadsearch.QueryRequest{Query: text, Threads: refs}).(threadsearch.QueryResult)
}
func refs(ids ...string) []model.ThreadRef {
	out := []model.ThreadRef{}
	for _, id := range ids {
		out = append(out, model.ThreadRef{ThreadID: id, TypeID: "agent"})
	}
	return out
}

func main() {
	if len(os.Args) > 1 && os.Args[1] == "embedding-fixture-child" {
		runEmbeddingPeer()
		return
	}
	if len(os.Args) == 3 && os.Args[1] == "--verify-engine" {
		verifyRealEngine(os.Args[2])
		return
	}
	ctx := context.Background()
	directory, e := os.MkdirTemp("", "mokusei-local-search-fixture-")
	must(e)
	defer os.RemoveAll(directory)
	s := &service{}
	server := httptest.NewServer(http.HandlerFunc(s.serve))
	defer server.Close()
	verifyDiagnostics(ctx, filepath.Join(directory, "diagnostics"))
	factory, stopAssets := fixtureAssets(directory, server.URL)
	defer stopAssets()
	provider := factory()
	path := filepath.Join(directory, "state.sqlite")
	database, e := store.Open(path)
	must(e)
	openRuntime := func() *core.Runtime {
		provider = factory()
		r, e := core.New(ctx, core.Config{Store: database, Harnesses: map[string]plugin.Harness{"fixture": harness{}}, DataDir: directory, DefaultCwd: directory, Embeddings: provider})
		must(e)
		return r
	}
	runtime := openRuntime()
	seed(database, thread("semantic", "Maintenance", "离线删除与后台清理"), thread("literal", "exact-ID-42", "different subject"))
	archived := thread("archive", "NEVER_UPLOAD", "NEVER_UPLOAD")
	yes := true
	archived.Archived = &yes
	moku := thread("moku", "Moku", "NEVER_UPLOAD")
	moku.Moku = true
	moku.Transcript = []json.RawMessage{}
	seed(database, archived, moku)
	configure(runtime, true, false)
	assert(s.calls.Load() == 0 && !status(runtime).Config.Enabled, "saving does not start indexing")
	_, err := runtime.Invoke(ctx, "search:index", []json.RawMessage{raw(threadsearch.IndexRequest{Action: "start", ExpectedRevision: status(runtime).Config.Revision})})
	assert(err != nil && s.calls.Load() == 0, "consent required")
	start(runtime)
	assert(s.calls.Load() == 0 && !status(runtime).Config.Enabled, "missing local model fails closed")
	_, err = runtime.Invoke(ctx, "search:model", []json.RawMessage{raw(map[string]any{"action": "download"})})
	assert(err != nil && !status(runtime).Setup.Downloading, "asset download requires a separate explicit action")
	invoke(runtime, "search:model", map[string]any{"action": "download", "confirmDownload": true})
	wait("runtime-managed model setup", func() bool { return !status(runtime).Setup.Downloading })
	assert(status(runtime).ModelAvailable, "download completes without indexing history")
	start(runtime)
	assert(status(runtime).Indexed == 2, "body index and visibility")
	savedCalls := s.calls.Load()
	configure(runtime, true, true)
	assert(!status(runtime).Config.Enabled && len(database.Snapshot().Keys("search-document:")) == 2, "automatic-update changes revoke confirmation but retain reusable chunks")
	start(runtime)
	assert(s.calls.Load() == savedCalls, "changing auto-update does not rebuild unchanged chunks")
	before := s.calls.Load()
	start(runtime)
	assert(s.calls.Load() == before, "unchanged index reuses chunks")
	result := query(runtime, "清空历史", refs("semantic", "literal", "archive")...)
	assert(result.Mode == "hybrid" && len(result.Hits) == 1 && result.Hits[0].Ref.ThreadID == "semantic", "synthetic Chinese semantic recall")
	assert(len(query(runtime, "清空历史", refs("literal")...).Hits) == 0, "tag/candidate scope respected")
	before = s.calls.Load()
	query(runtime, "清空历史", refs("semantic")...)
	assert(s.calls.Load() == before, "query vector cache")
	result = query(runtime, "exact-ID-42", refs("semantic", "literal")...)
	assert(len(result.Hits) > 0 && result.Hits[0].Ref.ThreadID == "literal", "literal identifiers outrank semantic additions")
	must(runtime.SetArchived(ctx, "semantic", true))
	assert(len(query(runtime, "清空历史", refs("semantic")...).Hits) == 0, "archive filtering and deletion")
	assert(len(database.Snapshot().Keys("search-document:")) == 1, "archive removes vector/text atomically")
	must(runtime.SetArchived(ctx, "semantic", false))
	start(runtime)
	seed(database, thread("semantic", "Maintenance", "离线删除与后台清理：增量更新"))
	start(runtime)
	assert(status(runtime).Indexed == 2, "incremental changed body")
	seed(database, thread("semantic", "Maintenance", "离线删除与后台清理：等待删除"))
	_, entered := s.hold()
	invoke(runtime, "search:index", threadsearch.IndexRequest{Action: "start", Consent: true, ExpectedRevision: status(runtime).Config.Revision})
	<-entered
	must(runtime.DeleteThread(ctx, "semantic"))
	assert(len(database.Snapshot().Keys("search-document:")) == 1, "deletion committed before delayed HTTP")
	s.release()
	settle(runtime)
	assert(len(database.Snapshot().Keys("search-document:")) == 1, "late index response cannot resurrect deleted thread")
	must(runtime.Close(ctx))
	must(database.Close())
	database, e = store.Open(path)
	must(e)
	runtime = openRuntime()
	assert(status(runtime).Indexed == 1, "durable index survives reopen")
	result = query(runtime, "exact-ID-42", refs("literal")...)
	assert(len(result.Hits) == 1, "persisted hybrid query after reopen")
	seed(database, thread("literal", "exact-ID-42", "different subject changed"))
	_, entered = s.hold()
	invoke(runtime, "search:index", threadsearch.IndexRequest{Action: "start", Consent: true, ExpectedRevision: status(runtime).Config.Revision})
	<-entered
	must(runtime.ClearHistory(ctx))
	s.release()
	assert(status(runtime).Config.Enabled && len(database.Snapshot().Keys("search-document:")) == 0, "clear fences in-flight indexing and leaves automatic search enabled for future threads")
	must(runtime.Close(ctx))
	must(database.Close())
	fmt.Println("PASS runtime consent, managed local HTTP schema, text chunks, scoped hybrid query, caching, incremental updates, archive, deletion races, persistence and fenced history reset")

	provider = factory()
	defer provider.Close()
	db, e := store.Open(filepath.Join(directory, "engine.sqlite"))
	must(e)
	seed(db, thread("long", "长标题", strings.Repeat("中文跨片段检索 ", 600)))
	manager := newManager(ctx, db, provider)
	config, e := manager.Configure(ctx, threadsearch.ConfigureRequest{IncludeContent: true})
	must(e)
	_, e = manager.Index(ctx, threadsearch.IndexRequest{Action: "start", Consent: true, ExpectedRevision: config.Config.Revision})
	must(e)
	wait("multi-chunk index", func() bool { x, e := manager.Status(ctx); must(e); return !x.Working })
	ready, e := manager.Status(ctx)
	must(e)
	assert(ready.Indexed == 1 && s.calls.Load() > 1, "Unicode overlapping persistent chunks")
	must(provider.Remove())
	scaffold, e := manager.Query(ctx, threadsearch.QueryRequest{Query: "title", Threads: refs("long")})
	must(e)
	assert(scaffold.Mode == "keyword" && scaffold.Reason == "model-missing" && len(scaffold.Hits) == 0, "missing model falls back without treating embedding formatting as literal text")
	install(provider)
	before = s.calls.Load()
	var group sync.WaitGroup
	for i := 0; i < 4; i++ {
		group.Add(1)
		go func() {
			defer group.Done()
			v, e := manager.Query(ctx, threadsearch.QueryRequest{Query: "并发查询", Threads: refs("long")})
			must(e)
			assert(v.Mode == "hybrid", "coalesced query result")
		}()
	}
	group.Wait()
	assert(s.calls.Load() == before+1, "concurrent queries share one local evaluation")
	manager.Close()
	must(db.Close())
	fmt.Println("PASS UTF-8 chunks, persistent vectors, concurrent query coalescing and no cloud budget")
	for mode, want := range map[int64]string{1: "local-unavailable", 2: "response", 3: "local-unavailable", 4: "local-unavailable", 5: "local-unavailable"} {
		db, e = store.Open(filepath.Join(directory, fmt.Sprintf("error-%d.sqlite", mode)))
		must(e)
		seed(db, thread("error", "literal", "different subject"))
		manager = newManager(ctx, db, provider)
		config, e = manager.Configure(ctx, threadsearch.ConfigureRequest{})
		must(e)
		_, e = manager.Index(ctx, threadsearch.IndexRequest{Action: "start", Consent: true, ExpectedRevision: config.Config.Revision})
		must(e)
		wait("error fixture index", func() bool { x, _ := manager.Status(ctx); return !x.Working })
		s.mode.Store(mode)
		v, e := manager.Query(ctx, threadsearch.QueryRequest{Query: "literal", Threads: refs("error")})
		must(e)
		assert(v.Mode == "keyword" && v.Reason == want && len(v.Hits) == 1, fmt.Sprintf("local error preserves keywords: mode=%d reason=%s", mode, v.Reason))
		s.mode.Store(0)
		manager.Close()
		must(db.Close())
	}
	_, e = provider.Embed(ctx, "task: search result | query: idle fixture", 768)
	must(e)
	assert(provider.SetupStatus().Loaded, "local process is loaded after inference")
	wait("idle model resources released", func() bool { return !provider.SetupStatus().Loaded })
	verifySetupFailures(directory)
	verifyConcurrentAssetActions(directory)
	verifyTextAdapters()
	verifyLazyPreparation(ctx, directory, provider, s)
	verifyRelevance(ctx, directory, factory())
	verifyAsync(ctx, directory, provider, s)
	verifyPauseDuringReconcile(ctx, directory, provider, s)
	verifyCancelledReplacement(ctx, directory, factory(), s)
	verifyApplications(ctx, directory, provider, s)
	verifyPipelineReset(ctx, directory, factory(), s)
	verifyAutomaticSearch(ctx, directory, server.URL, s)
	verifyExclusiveModelRemoval(ctx, directory, factory())
	removing := factory()
	install(removing)
	_, entered = s.hold()
	cancelled, cancel := context.WithCancel(ctx)
	done := make(chan error, 1)
	go func() {
		_, e := removing.Embed(cancelled, "task: search result | query: removal fixture", 768)
		done <- e
	}()
	<-entered
	cancel()
	must(removing.Remove())
	s.release()
	assert(<-done != nil && !removing.Available(ctx) && !removing.SetupStatus().Loaded, "cancelled inference and model removal join before deleting files")
	must(removing.Close())
	fmt.Println("PASS local engine errors, invalid vectors, redirect refusal, cancelled/disconnected inference and keyword fallback; no model weights or user data were downloaded")
}

func newManager(ctx context.Context, db *store.Store, p *localembedding.Provider) *threadsearch.Manager {
	m, err := threadsearch.New(ctx, threadsearch.Options{Store: db, Provider: p, Sources: source, Interval: time.Nanosecond})
	must(err)
	return m
}
