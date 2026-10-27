package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	core "github.com/hupao-creator/Mokusei/internal/core/runtime"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/platform/diagnostics"
	"github.com/hupao-creator/Mokusei/internal/services/threadsearch"
)

// Exercise the production runtime -> manager -> provider -> rotating writer seam.
func verifyDiagnostics(ctx context.Context, directory string) {
	service := &service{}
	server := httptest.NewServer(http.HandlerFunc(service.serve))
	defer server.Close()
	target := server.URL
	logger, err := diagnostics.New(filepath.Join(directory, "logs"))
	must(err)
	defer logger.Close()
	factory, stop := fixtureAssetsWithTrace(directory, target, logger.SearchEvent)
	defer stop()
	provider := factory()
	db, err := store.Open(filepath.Join(directory, "state.sqlite"))
	must(err)
	defer db.Close()
	r, err := core.New(ctx, core.Config{Store: db, Harnesses: map[string]plugin.Harness{"fixture": harness{}}, DataDir: directory, DefaultCwd: directory, Embeddings: provider, SearchTrace: logger.SearchEvent})
	must(err)
	defer r.Close(ctx)
	seed(db, thread("diagnostic-private-id", "diagnostic-private-title", "离线删除 diagnostic-private-body"))
	configure(r, true, false)
	install(provider)
	start(r)
	before := service.calls.Load()
	result := query(r, "清空历史 diagnostic-private-query", refs("diagnostic-private-id")...)
	assert(result.Mode == "hybrid" && len(result.Hits) == 1, "diagnostic query has a semantic hit")
	query(r, "清空历史 diagnostic-private-query", refs("diagnostic-private-id")...)
	assert(service.calls.Load() == before+1, "cached query needs no further embedding")
	service.mode.Store(1)
	result = query(r, "diagnostic-private-failure", refs("diagnostic-private-id")...)
	assert(result.Mode == "keyword" && result.Reason == "local-unavailable", "failure still falls back to keywords")
	service.mode.Store(0)
	_, entered := service.hold()
	cancelled, cancel := context.WithCancel(ctx)
	done := make(chan error, 1)
	go func() {
		_, err := r.Invoke(cancelled, "search:query", []json.RawMessage{raw(threadsearch.QueryRequest{Query: "diagnostic-private-cancel", Threads: refs("diagnostic-private-id")})})
		done <- err
	}()
	<-entered
	// A second request waits behind the held inference and must log cancellation
	// without reaching the HTTP backend.
	queued, cancelQueued := context.WithTimeout(ctx, 50*time.Millisecond)
	_, queuedErr := r.Invoke(queued, "search:query", []json.RawMessage{raw(threadsearch.QueryRequest{Query: "diagnostic-private-queued", Threads: refs("diagnostic-private-id")})})
	cancelQueued()
	assert(queuedErr != nil, "queued query times out")
	cancel()
	select {
	case err := <-done:
		assert(err != nil, "cancelled query reports error")
	case <-time.After(2 * time.Second):
		panic("diagnostic cancellation did not join")
	}
	service.release()
	must(r.Close(ctx))
	// Verify the logging boundary cannot serialize arbitrary adapter error labels.
	logger.SearchEvent(plugin.SearchDiagnostic{Event: "search.query.completed", Reason: "diagnostic-private-unsafe-error", OperationID: "diagnostic-private-unsafe-id!", Mode: "diagnostic-private-unsafe-mode"})
	must(logger.Close())
	data, err := os.ReadFile(filepath.Join(directory, "logs", "service.jsonl"))
	must(err)
	for _, secret := range []string{"diagnostic-private", "离线删除", "清空历史", "do not leak service body", "embedding\"", "LLAMA_API_KEY", "Bearer ", directory} {
		assert(!strings.Contains(string(data), secret), "diagnostics exclude text, identities, paths, vectors and credentials: "+secret)
	}
	var events []plugin.SearchDiagnostic
	for _, line := range strings.Split(strings.TrimSpace(string(data)), "\n") {
		var event plugin.SearchDiagnostic
		must(json.Unmarshal([]byte(line), &event))
		assert(event.DurationMS >= 0 && event.QueueMS >= 0, "diagnostic durations are nonnegative")
		events = append(events, event)
	}
	contains := func(name string, predicate func(plugin.SearchDiagnostic) bool) bool {
		for _, event := range events {
			if event.Event == name && predicate(event) {
				return true
			}
		}
		return false
	}
	any := func(plugin.SearchDiagnostic) bool { return true }
	for _, name := range []string{"embedding.download.started", "embedding.download.completed", "embedding.process.start.completed", "embedding.process.stopped", "search.index.started", "search.index.completed"} {
		assert(contains(name, any), "lifecycle diagnostic: "+name)
	}
	assert(contains("search.index.completed", func(e plugin.SearchDiagnostic) bool { return e.RequestCount > 0 && e.ChunkCount > 0 }), "index counts actual inference")
	assert(contains("search.query.completed", func(e plugin.SearchDiagnostic) bool {
		return e.Cache == "hit" && e.Mode == "hybrid" && e.Outcome == "completed"
	}), "query cache diagnostic")
	assert(contains("search.query.completed", func(e plugin.SearchDiagnostic) bool {
		return e.Outcome == "fallback" && e.Reason == "local-unavailable"
	}), "keyword fallback diagnostic")
	assert(contains("search.request.completed", func(e plugin.SearchDiagnostic) bool { return e.Reason == "timeout" && e.QueueMS >= 40 }), "cancelled gate wait diagnostic")
	assert(contains("embedding.inference.completed", func(e plugin.SearchDiagnostic) bool { return e.Reason == "cancelled" }), "cancelled inference diagnostic")
	var queryID string
	for _, event := range events {
		if event.Event == "search.query.completed" && event.Cache == "miss" && event.Mode == "hybrid" {
			assert(event.Outcome == "completed" && event.HitCount == 1 && event.SemanticCount == 1 && event.BestCosine > 0.99 && event.TopScore > 0 && event.DocumentCount == 1 && event.ChunkCount > 0, "query score and candidate summary")
			queryID = event.OperationID
		}
	}
	assert(queryID != "", "query has an operation ID")
	for _, name := range []string{"search.query.started", "search.request.completed", "embedding.inference.completed"} {
		assert(contains(name, func(e plugin.SearchDiagnostic) bool { return e.OperationID == queryID }), "query/inference operation correlation: "+name)
	}
	fmt.Println("PASS structured search diagnostics: indexing, inference, cache, scoring, fallback, cancellation, operation correlation and content exclusion")
}
