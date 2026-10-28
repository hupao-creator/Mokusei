package main

import (
	"context"
	"encoding/json"
	"flag"
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
	mu             sync.Mutex
	requests       []string
	mode           string
	indexMetadata  *string
	detailMetadata *string
	metrics        map[string]any
}

func embedded(v any) string {
	data, _ := json.Marshal(v)
	return strings.ReplaceAll(string(data), `"`, `\"`)
}
func model(slug, release, name string) map[string]any {
	return map[string]any{
		"slug": slug, "release": map[string]any{"slug": release, "name": name},
		"name": name + " high", "isReasoning": true, "effort": map[string]string{"slug": "high"},
		"intelligenceIndex": 0, "intelligenceIndexCostPerTask": map[string]any{"cost": map[string]any{"total": 0.75}},
		"briefcaseBreakdown":          map[string]any{"overall": map[string]any{"elo": 1497.25}},
		"automationBenchPartialScore": 0.52, "gdpPdfAllPass": 0.14, "frontierCode20": 0.42,
		"terminalBench40": 0.6, "omniscienceAccuracy": 0.47, "omniscienceHallucinationRate": 0.31,
		"hleDiamond": 0.45, "critptAgenticHard": 0.35, "terminalBenchScience": 0.25,
		"hle": 0.99, "terminalBench21": 0.98, "tauBanking": 0.97, "frontierCode": 0.96, "critpt": 0.95,
		"timescaleData": map[string]any{"medianOutputSpeed": 100}, "price1mInputTokens": 0, "price1mOutputTokens": -1,
	}
}
func versionMetadata(version string) string {
	return `\"intelligenceIndex\":` + embedded(map[string]any{"slug": "artificial-analysis-intelligence-index", "name": "Artificial Analysis Intelligence Index v" + version})
}
func (f *fixture) Do(req *http.Request) (*http.Response, error) {
	f.mu.Lock()
	f.requests = append(f.requests, req.URL.Path+"|"+req.Header.Get("If-None-Match"))
	mode := f.mode
	metadata := f.detailMetadata
	if req.URL.Path == "/models/" {
		metadata = f.indexMetadata
	}
	metrics := f.metrics
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
		value := model(slug, release, name)
		for key, metric := range metrics {
			value[key] = metric
		}
		body = `\"currentModel\":` + embedded(model("comparison-high", "comparison", "Comparison")) + `\"initialModels\":` + embedded([]any{value})
	}
	if metadata == nil {
		body += versionMetadata("5.0")
	} else {
		body += *metadata
	}
	return &http.Response{StatusCode: status, Header: headers, Body: io.NopCloser(strings.NewReader(body))}, nil
}
func require(ok bool, msg string) {
	if !ok {
		panic(msg)
	}
}
func main() {
	liveRelease := flag.String("live-release", "", "also fetch this release from the public Artificial Analysis website")
	flag.Parse()
	diagnosticsReplay()
	cacheRefreshReplay()
	versionReplay()
	metricReplay()
	cacheVersionReplay()
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
	require(snapshot.IntelligenceIndexVersion == "5.0", "verified index version")
	e := snapshot.Releases[0].Evaluations[0]
	require(e.IntelligenceIndex != nil && *e.IntelligenceIndex == 0, "measured zero preserved")
	require(e.CostPerIntelligenceIndexTaskUSD != nil && *e.CostPerIntelligenceIndexTaskUSD == 0.75, "published v5 cost retained")
	scores, _ := json.Marshal(e.BenchmarkScores)
	require(string(scores) == `{"aaBriefcaseV11":1497.25,"automationBenchAA":0.52,"gdpPDF":0.14,"frontierCodeV20":0.42,"terminalBenchV40":0.6,"omniscienceV11Accuracy":0.47,"omniscienceV11HallucinationRate":0.31,"hleDiamond":0.45,"critPtV2Hard":0.35,"terminalBenchScienceV01":0.25}`, "all v5 components use the correct source fields and native units")
	require(e.OutputUSDPer1MTokens == nil, "invalid price stays null")
	formattedFacts := aa.FormatCached(snapshot)
	require(strings.Contains(formattedFacts, "Intelligence Index version: v5.0.") && strings.Contains(formattedFacts, "aaBriefcaseV11:1497.25") && strings.Contains(formattedFacts, "hleDiamond:0.45"), "detailed output carries v5 version and metrics")
	for _, obsolete := range []string{"hleText", "terminalBenchV21", "tau3Banking", "Terminus 2"} {
		require(!strings.Contains(formattedFacts, obsolete), "obsolete benchmark removed: "+obsolete)
	}
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
	require(strings.Contains(formatted, "Intelligence Index version: v5.0.") && strings.Contains(formatted, "aaBriefcaseV11, automationBenchAA, gdpPDF, frontierCodeV20, terminalBenchV40, omniscienceV11Accuracy, omniscienceV11HallucinationRate, hleDiamond, critPtV2Hard, terminalBenchScienceV01."), "compact version and column definitions")
	rows := 0
	for _, line := range strings.Split(formatted, "\n") {
		if strings.HasPrefix(line, "[") {
			var row []any
			require(json.Unmarshal([]byte(line), &row) == nil && len(row) == 21, "compact rows atomic")
			data, _ := json.Marshal(row[11:])
			require(string(data) == `[1497.25,0.52,0.14,0.42,0.6,0.47,0.31,0.45,0.35,0.25]`, "compact metric order and units")
			rows++
		}
	}
	require(rows > 0, "compact output retains measurements")
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
	if *liveRelease != "" {
		liveReplay(*liveRelease)
	}
}
