package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	core "github.com/hupao-creator/Mokusei/internal/core/runtime"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/platform/diagnostics"
)

// Keep the production Runtime -> search -> rotating writer privacy boundary.
func verifyDiagnostics(ctx context.Context, directory string) {
	logger, err := diagnostics.New(filepath.Join(directory, "logs"))
	must(err)
	defer logger.Close()
	db, err := store.Open(filepath.Join(directory, "state.sqlite"))
	must(err)
	defer db.Close()
	r, err := core.New(ctx, core.Config{Store: db, Harnesses: map[string]plugin.Harness{"fixture": harness{}}, DataDir: directory, DefaultCwd: directory, SearchTrace: logger.SearchEvent})
	must(err)
	defer r.Close(ctx)
	seed(db, thread("diagnostic-private-id", "diagnostic-private-title", "离线删除 diagnostic-private-body"))
	start(r)
	for range 2 {
		result := query(r, "离线删除", refs("diagnostic-private-id")...)
		assert(result.Mode == "keyword" && len(result.Hits) == 1, "diagnostic body query")
	}
	must(r.Close(ctx))
	logger.SearchEvent(plugin.SearchDiagnostic{Event: "search.query.completed", Reason: "diagnostic-private-unsafe-error", OperationID: "diagnostic-private-unsafe-id!", Mode: "diagnostic-private-unsafe-mode"})
	must(logger.Close())
	data, err := os.ReadFile(filepath.Join(directory, "logs", "service.jsonl"))
	must(err)
	for _, secret := range []string{"diagnostic-private", "离线删除", directory} {
		assert(!strings.Contains(string(data), secret), "diagnostics exclude text, identities, paths and unsafe labels")
	}
	started := map[string]bool{}
	indexed, cacheHit := false, false
	for _, line := range strings.Split(strings.TrimSpace(string(data)), "\n") {
		var event plugin.SearchDiagnostic
		must(json.Unmarshal([]byte(line), &event))
		assert(event.DurationMS >= 0, "nonnegative duration")
		if event.Event == "search.query.started" {
			started[event.OperationID] = true
		}
		if event.Event == "search.index.completed" && event.DocumentCount == 1 {
			indexed = true
		}
		if event.Event == "search.query.completed" && event.Cache == "hit" {
			assert(started[event.OperationID] && event.Mode == "keyword" && event.HitCount == 1 && event.DocumentCount == 1, "cached keyword query correlation and counts")
			cacheHit = true
		}
	}
	assert(indexed && cacheHit, "index and query diagnostics observed")
	fmt.Println("PASS structured keyword diagnostics: indexing, cache, counts, operation correlation and content exclusion")
}
