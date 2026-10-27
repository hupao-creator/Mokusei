package main

import (
	"context"
	"encoding/json"
	"fmt"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	aa "github.com/hupao-creator/Mokusei/internal/plugins/contexts/artificialanalysis"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

type fixture struct {
	mu       sync.Mutex
	requests []string
	mode     string
}

func embedded(v any) string {
	data, _ := json.Marshal(v)
	return strings.ReplaceAll(string(data), `"`, `\"`)
}
func model(slug, release, name string) map[string]any {
	return map[string]any{"slug": slug, "release": map[string]any{"slug": release, "name": name}, "name": name + " high", "isReasoning": true, "effort": map[string]string{"slug": "high"}, "intelligenceIndex": 0, "terminalBench21": 0.6, "terminalBench": 0.99, "hle": nil, "tauBanking": 2, "timescaleData": map[string]any{"medianOutputSpeed": 100}, "price1mInputTokens": 0, "price1mOutputTokens": -1}
}
func (f *fixture) Do(req *http.Request) (*http.Response, error) {
	f.mu.Lock()
	f.requests = append(f.requests, req.URL.Path+"|"+req.Header.Get("If-None-Match"))
	mode := f.mode
	f.mu.Unlock()
	if mode == "blocked" {
		<-req.Context().Done()
		return nil, req.Context().Err()
	}
	if mode == "offline" {
		return nil, fmt.Errorf("offline")
	}
	status := 200
	body := ""
	headers := http.Header{"Etag": []string{"generation-1"}}
	if req.URL.Path == "/models/" {
		body = `\"initialModels\":` + embedded([]any{model("comparison-high", "comparison", "Comparison")}) + `\"releases\":` + embedded([]any{map[string]string{"slug": "model-a", "name": "Model A"}, map[string]string{"slug": "model-b", "name": "Model B"}}) + `\"models\":` + embedded([]any{map[string]string{"slug": "model-a-high", "releaseSlug": "model-a"}, map[string]string{"slug": "model-b-high", "releaseSlug": "model-b"}})
	} else if mode == "gone" {
		status = 410
	} else if mode == "notmodified" {
		status = 304
	} else {
		slug := strings.TrimPrefix(req.URL.Path, "/models/")
		release := strings.TrimSuffix(slug, "-high")
		name := "Model A"
		if release == "model-b" {
			name = "Model B"
		}
		body = `\"currentModel\":` + embedded(model("comparison-high", "comparison", "Comparison")) + `\"initialModels\":` + embedded([]any{model(slug, release, name)})
	}
	return &http.Response{StatusCode: status, Header: headers, Body: io.NopCloser(strings.NewReader(body))}, nil
}
func require(ok bool, msg string) {
	if !ok {
		panic(msg)
	}
}
func main() {
	diagnosticsReplay()
	cacheRefreshReplay()
	root, err := os.MkdirTemp("", "oa-aa-go-replay-")
	if err != nil {
		panic(err)
	}
	defer os.RemoveAll(root)
	client := &fixture{}
	source, err := aa.NewSource(aa.Options{CacheRoot: root, HTTPClient: client})
	if err != nil {
		panic(err)
	}
	identities := []aa.AcquisitionIdentity{{Names: []string{"model-a"}}}
	snapshot, err := source.WaitForBootstrap(context.Background(), identities)
	if err != nil {
		panic(err)
	}
	require(snapshot.Availability == "available" && len(snapshot.Releases) == 1, "cold discovery full roster")
	e := snapshot.Releases[0].Evaluations[0]
	require(e.IntelligenceIndex != nil && *e.IntelligenceIndex == 0, "measured zero preserved")
	require(e.BenchmarkScores.TerminalBenchV21 != nil && *e.BenchmarkScores.TerminalBenchV21 == 0.6, "terminalBench21 source field")
	require(e.BenchmarkScores.HLEText == nil && e.BenchmarkScores.Tau3Banking == nil && e.OutputUSDPer1MTokens == nil, "missing and invalid metrics stay null")
	require(e.Configuration.Reasoning && e.Configuration.Effort == "high", "detail configuration")
	require(!strings.Contains(aa.FormatCached(snapshot), "Canonical evaluation release: comparison"), "wrong detail comparison omitted")
	requestCount := len(client.requests)
	client.mu.Lock()
	client.mode = "notmodified"
	client.mu.Unlock()
	if err = source.Refresh(context.Background(), identities); err != nil {
		panic(err)
	}
	require(strings.Contains(client.requests[len(client.requests)-1], "|generation-1"), "etag reused")
	require(len(client.requests) == requestCount+2, "index and detail reacquired")
	source.Close()
	loaded, err := aa.NewSource(aa.Options{CacheRoot: root, HTTPClient: client})
	if err != nil {
		panic(err)
	}
	require(loaded.Snapshot().Availability == "available", "persisted immediate load")
	client.mu.Lock()
	client.mode = "blocked"
	client.mu.Unlock()
	started := time.Now()
	snapshot, err = loaded.WaitForBootstrap(context.Background(), identities)
	if err != nil {
		panic(err)
	}
	require(time.Since(started) < 100*time.Millisecond, "warm cache nonblocking")
	loaded.Close()
	client.mu.Lock()
	client.mode = ""
	client.requests = nil
	client.mu.Unlock()
	source, err = aa.NewSource(aa.Options{CacheRoot: root, HTTPClient: client})
	if err != nil {
		panic(err)
	}
	if err = source.Refresh(context.Background(), identities); err != nil {
		panic(err)
	}
	require(!strings.Contains(client.requests[len(client.requests)-1], "generation-1"), "restart clears etag")
	if err = source.Refresh(context.Background(), []aa.AcquisitionIdentity{{Names: []string{"model-b"}}}); err != nil {
		panic(err)
	}
	snapshot = source.Snapshot()
	require(len(snapshot.Releases) == 2, "separate catalogs retain other releases")
	before := len(client.requests)
	raw, _ := json.Marshal(map[string]any{"models": []any{map[string]any{"selector": "model-a", "provenance": map[string]string{"kind": "unknown"}}}})
	content, err := aa.Collect(context.Background(), source, plugin.MokuContextInput{Catalogs: []plugin.BoundModelCatalog{{ID: "unknown", DisplayName: "Unknown", Load: func(context.Context) (json.RawMessage, error) { return raw, nil }}}})
	require(err == nil && content == "" && len(client.requests) == before, "unknown provenance suppresses acquisition")
	content, err = aa.Collect(context.Background(), source, plugin.MokuContextInput{Catalogs: []plugin.BoundModelCatalog{
		{ID: "unavailable", DisplayName: "Unavailable", Load: func(context.Context) (json.RawMessage, error) { return nil, fmt.Errorf("native catalog unavailable") }},
		{ID: "available", DisplayName: "Available", Load: func(context.Context) (json.RawMessage, error) {
			return json.RawMessage(`{"models":[{"selector":"model-a","provenance":{"kind":"native"}}]}`), nil
		}},
	}})
	require(err == nil && strings.Contains(content, "Canonical evaluation release: model-a") && !strings.Contains(content, "### Unavailable"), "one catalog failure preserves another catalog's evaluation context")
	for _, r := range []string{"model-a-999", "model-a-preview"} {
		require(aa.MatchRelease(snapshot, aa.Identity{Selector: r, Aliases: []string{"model-a"}}).Status == "unmatched", "explicit version contradicts alias")
	}
	require(aa.MatchRelease(snapshot, aa.Identity{Selector: "MODEL A[1m]"}).Status == "matched", "context suffix matches")
	copy := snapshot
	copy.Releases = append(copy.Releases, copy.Releases[0])
	require(aa.MatchRelease(copy, aa.Identity{Selector: "model-a"}).Status == "ambiguous", "duplicate scores ambiguous")
	large := snapshot
	large.Releases = append([]aa.Release{}, snapshot.Releases...)
	large.Releases[0].Evaluations = nil
	for i := 0; i < 180; i++ {
		v := e
		v.Slug = fmt.Sprintf("model-a-%d", i)
		v.EvaluatedModel = strings.Repeat("界", 160)
		large.Releases[0].Evaluations = append(large.Releases[0].Evaluations, v)
	}
	formatted := aa.FormatModels(large, []aa.NativeModel{{Label: "A", Identity: aa.Identity{Selector: "model-a"}}})
	require(len(formatted) <= aa.MaxCatalogBytes, "catalog bytes bounded")
	require(strings.Contains(formatted, "compact JSON rows"), "large catalogs compact")
	for _, line := range strings.Split(formatted, "\n") {
		if strings.HasPrefix(line, "[") {
			var row []any
			require(json.Unmarshal([]byte(line), &row) == nil && len(row) == 14, "compact rows atomic")
		}
	}
	source.Close()
	data, _ := os.ReadFile(filepath.Join(root, "moku-evaluation-facts.json"))
	var cache map[string]any
	_ = json.Unmarshal(data, &cache)
	cache["extra"] = true
	data, _ = json.Marshal(cache)
	_ = os.WriteFile(filepath.Join(root, "moku-evaluation-facts.json"), data, 0600)
	invalid, _ := aa.NewSource(aa.Options{CacheRoot: root, HTTPClient: client})
	require(invalid.Snapshot().Availability == "unavailable", "invalid schema rejected")
	invalid.Close()
	fmt.Println("AA replay passed: cold full roster/detail matching, null/zero metrics, ETags/restart, warm nonblocking/dispose, retained catalogs, provenance, ambiguity/version rules, compact rows, cache validation")
}
