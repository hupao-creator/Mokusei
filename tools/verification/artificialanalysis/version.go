package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	aa "github.com/hupao-creator/Mokusei/internal/plugins/contexts/artificialanalysis"
)

func versionReplay() {
	identities := []aa.AcquisitionIdentity{{Names: []string{"model-a"}}, {Names: []string{"model-b"}}}
	for _, boundary := range []string{"index", "detail"} {
		for _, tc := range []struct{ name, metadata string }{
			{"missing", ""},
			{"old", versionMetadata("4.3")},
			{"future", versionMetadata("6.0")},
			{"malformed", `\"intelligenceIndex\":{\"name\":null}`},
			{"contradictory", versionMetadata("5.0") + versionMetadata("4.3")},
		} {
			root, err := os.MkdirTemp("", "mokusei-aa-version-")
			require(err == nil, "version replay root")
			client := &fixture{}
			metadata := &client.indexMetadata
			if boundary == "detail" {
				metadata = &client.detailMetadata
			}
			*metadata = &tc.metadata
			source, err := aa.NewSource(aa.Options{CacheRoot: root, HTTPClient: client})
			require(err == nil, "version replay source")
			err = source.Refresh(context.Background(), identities)
			require((err != nil) == (boundary == "index"), "version failure follows existing source boundary")
			require(source.Snapshot().Availability == "unavailable" && len(source.Snapshot().Releases) == 0, boundary+" "+tc.name+" version accepted on cold acquisition")
			if boundary == "index" {
				require(len(client.requests) == 1, "unsupported index dispatched details")
			}
			client.mu.Lock()
			*metadata = nil
			client.mu.Unlock()
			require(source.Refresh(context.Background(), identities) == nil, "recover with verified v5")
			before, _ := json.Marshal(source.Snapshot().Releases)
			require(len(source.Snapshot().Releases) == 2, "both v5 catalogs seeded")
			client.mu.Lock()
			*metadata = &tc.metadata
			client.metrics = map[string]any{"intelligenceIndex": 99, "intelligenceIndexCostPerTask": map[string]any{"cost": map[string]any{"total": 99}}}
			client.mu.Unlock()
			_ = source.Refresh(context.Background(), identities[:1])
			after, _ := json.Marshal(source.Snapshot().Releases)
			require(string(before) == string(after) && source.Snapshot().IntelligenceIndexVersion == "5.0", boundary+" "+tc.name+" version replaced or mixed verified cached facts")
			require(source.Close() == nil, "version source closure")
			require(os.RemoveAll(root) == nil, "version fixture cleanup")
		}
	}
	fmt.Println("PASS AA rejects missing, old, future, malformed and contradictory index/detail versions; retains only verified v5 facts across catalogs")
}

func metricReplay() {
	root, err := os.MkdirTemp("", "mokusei-aa-metrics-")
	require(err == nil, "metrics replay root")
	defer os.RemoveAll(root)
	client := &fixture{metrics: map[string]any{
		"intelligenceIndex":            -1,
		"intelligenceIndexCostPerTask": map[string]any{"cost": map[string]any{"total": -1}},
		"briefcaseBreakdown":           map[string]any{"overall": map[string]any{"elo": -25}},
		"automationBenchPartialScore":  2, "gdpPdfAllPass": "0.14", "frontierCode20": -0.1,
		"terminalBench40": 0, "omniscienceAccuracy": 1.01, "omniscienceHallucinationRate": -1,
		"hleDiamond": nil, "critptAgenticHard": true, "terminalBenchScience": nil,
	}}
	source, err := aa.NewSource(aa.Options{CacheRoot: root, HTTPClient: client})
	require(err == nil, "metrics source")
	require(source.Refresh(context.Background(), []aa.AcquisitionIdentity{{Names: []string{"model-a"}}}) == nil, "metrics acquisition")
	e := source.Snapshot().Releases[0].Evaluations[0]
	require(e.IntelligenceIndex == nil && e.CostPerIntelligenceIndexTaskUSD == nil, "invalid index and cost remain unknown")
	scores, _ := json.Marshal(e.BenchmarkScores)
	require(string(scores) == `{"aaBriefcaseV11":-25,"automationBenchAA":null,"gdpPDF":null,"frontierCodeV20":null,"terminalBenchV40":0,"omniscienceV11Accuracy":null,"omniscienceV11HallucinationRate":null,"hleDiamond":null,"critPtV2Hard":null,"terminalBenchScienceV01":null}`, "Elo/rate bounds, null/zero and obsolete-field exclusion")
	require(source.Close() == nil, "metrics source closure")
	loaded, err := aa.NewSource(aa.Options{CacheRoot: root, HTTPClient: client})
	require(err == nil, "metrics cache load")
	defer loaded.Close()
	fromCache, _ := json.Marshal(loaded.Snapshot().Releases[0].Evaluations[0].BenchmarkScores)
	require(string(fromCache) == string(scores), "cache preserves native units and unknowns")
	fmt.Println("PASS AA v5 metric bounds, null/zero, Elo units and no fallback to obsolete measurements")
}

func cacheVersionReplay() {
	root, err := os.MkdirTemp("", "mokusei-aa-cache-version-")
	require(err == nil, "cache version root")
	defer os.RemoveAll(root)
	identities := []aa.AcquisitionIdentity{{Names: []string{"model-a"}}, {Names: []string{"model-b"}}}
	seed, err := aa.NewSource(aa.Options{CacheRoot: root, HTTPClient: &fixture{}})
	require(err == nil && seed.Refresh(context.Background(), identities) == nil, "seed v5 cache")
	require(seed.Close() == nil, "seed source closure")
	path := filepath.Join(root, "moku-evaluation-facts.json")
	valid, err := os.ReadFile(path)
	require(err == nil, "read v5 cache")
	for _, change := range []string{"old-schema", "missing-version", "old-version", "future-version", "invalid-proportion"} {
		var cache map[string]any
		require(json.Unmarshal(valid, &cache) == nil, "decode v5 cache")
		require(cache["schemaVersion"] == float64(2) && cache["intelligenceIndexVersion"] == "5.0", "v5 cache envelope")
		switch change {
		case "old-schema":
			cache["schemaVersion"] = 1
			delete(cache, "intelligenceIndexVersion")
			for _, entry := range cache["configurations"].([]any) {
				entry.(map[string]any)["facts"].(map[string]any)["benchmarkScores"] = map[string]any{"hleText": 0.99, "terminalBenchV21": 0.98, "tau3Banking": 0.97}
			}
		case "missing-version":
			delete(cache, "intelligenceIndexVersion")
		case "old-version":
			cache["intelligenceIndexVersion"] = "4.3"
		case "future-version":
			cache["intelligenceIndexVersion"] = "6.0"
		case "invalid-proportion":
			entry := cache["configurations"].([]any)[0].(map[string]any)
			entry["facts"].(map[string]any)["benchmarkScores"].(map[string]any)["hleDiamond"] = 2
		}
		data, err := json.Marshal(cache)
		require(err == nil && os.WriteFile(path, data, 0600) == nil, "write cache mutation")
		client := &fixture{mode: "offline"}
		source, err := aa.NewSource(aa.Options{CacheRoot: root, HTTPClient: client})
		require(err == nil, "open changed cache")
		cached, err := source.WaitForBootstrap(context.Background(), identities)
		require(err == nil && cached.Availability == "unavailable" && cached.IntelligenceIndexVersion == "" && len(cached.Releases) == 0, change+" cache reused offline")
		client.mu.Lock()
		client.mode = "notmodified"
		client.requests = nil
		client.mu.Unlock()
		require(source.Refresh(context.Background(), identities[:1]) == nil && source.Snapshot().Availability == "unavailable", "304 resurrected rejected cache")
		client.mu.Lock()
		client.mode = ""
		client.requests = nil
		client.mu.Unlock()
		require(source.Refresh(context.Background(), identities[:1]) == nil, "refresh discarded cache")
		snapshot := source.Snapshot()
		require(snapshot.IntelligenceIndexVersion == "5.0" && snapshot.Availability == "available" && len(snapshot.Releases) == 1 && snapshot.Releases[0].Slug == "model-a", "legacy unrefreshed catalog mixed into v5")
		require(client.requests[len(client.requests)-1] == "/models/model-a-high|", "rejected cache supplied conditional request")
		require(source.Close() == nil, "cache version source closure")
	}
	fmt.Println("PASS AA rejects old/mismatched cache versions and invalid metrics; offline and 304 cannot restore discarded scores; fresh v5 excludes legacy catalogs")
}

func liveReplay(release string) {
	root, err := os.MkdirTemp("", "mokusei-aa-live-")
	require(err == nil, "live replay root")
	defer os.RemoveAll(root)
	source, err := aa.NewSource(aa.Options{CacheRoot: root})
	require(err == nil, "live source")
	defer source.Close()
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	require(source.Refresh(ctx, []aa.AcquisitionIdentity{{ReleaseSlug: &release}}) == nil, "live v5 acquisition")
	snapshot := source.Snapshot()
	require(snapshot.Availability == "available" && snapshot.IntelligenceIndexVersion == "5.0" && len(snapshot.Releases) == 1 && snapshot.Releases[0].Slug == release, "live v5 release identity and version")
	measured := 0
	for _, evaluation := range snapshot.Releases[0].Evaluations {
		if evaluation.IntelligenceIndex != nil && evaluation.BenchmarkScores.HLEDiamond != nil && evaluation.BenchmarkScores.TerminalBenchV40 != nil {
			measured++
		}
	}
	require(measured > 0, "live published v5 measurements")
	require(strings.Contains(aa.FormatCached(snapshot), "Intelligence Index version: v5.0."), "live formatted version")
	fmt.Printf("PASS AA live website: %s, Intelligence Index v5.0, %d configurations with published index/HLE-Diamond/Terminal-Bench 4.0 scores\n", release, measured)
}
