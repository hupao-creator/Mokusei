package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"time"
	"unicode/utf8"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	core "github.com/hupao-creator/Mokusei/internal/core/runtime"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/platform/sqlite"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/claude"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/codex"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/opencode"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/pi"
	"github.com/hupao-creator/Mokusei/internal/services/embedding"
	"github.com/hupao-creator/Mokusei/internal/services/threadsearch"
)

type evaluationDocument struct {
	ID         string   `json:"id"`
	Title      string   `json:"title"`
	Cwd        string   `json:"cwd"`
	Tags       []string `json:"tags"`
	Text       string   `json:"text"`
	SourceHash string   `json:"sourceHash"`
}

type evaluationQuery struct {
	ID       string   `json:"id"`
	Query    string   `json:"query"`
	Relevant []string `json:"relevant"`
	Split    string   `json:"split"`
}
type evaluationResult struct {
	Case         evaluationQuery    `json:"case"`
	Hits         []threadsearch.Hit `json:"hits"`
	Milliseconds float64            `json:"milliseconds"`
	Mode         string             `json:"mode"`
}

func readEvaluationJSON(path string, value any) error {
	raw, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	return json.Unmarshal(raw, value)
}
func runCorpusEvaluation(ctx context.Context, corpusPath, queryPath, output, variant, helper, models string) error {
	var documents []evaluationDocument
	var queries []evaluationQuery
	if err := readEvaluationJSON(corpusPath, &documents); err != nil {
		return err
	}
	if err := readEvaluationJSON(queryPath, &queries); err != nil {
		return err
	}
	if len(documents) == 0 || len(queries) == 0 || output == "" {
		return errors.New("nonempty corpus, labelled queries and output are required")
	}
	tuning := threadsearch.Tuning{PassageBytes: 1536, MinimumSimilarity: .72, SemanticLimit: 40}
	switch variant {
	case "final":
		tuning = threadsearch.DefaultTuning()
	case "keyword", "baseline":
	case "conservative":
		tuning.MinimumSimilarity = .76
		tuning.SemanticLimit = 12
	case "strict":
		tuning.MinimumSimilarity = .80
		tuning.SemanticLimit = 8
	case "coherent":
		tuning.PassageBytes = 768
		tuning.MinimumSimilarity = .76
		tuning.SemanticLimit = 12
		tuning.MetadataWeight = .2
	case "short":
		tuning.PassageBytes = 768
		tuning.MinimumSimilarity = .76
		tuning.SemanticLimit = 12
	default:
		return errors.New("unknown evaluation variant")
	}
	known := map[string]bool{}
	for _, document := range documents {
		known[document.ID] = true
	}
	for _, query := range queries {
		if query.ID == "" || query.Query == "" || (query.Split != "tune" && query.Split != "holdout") {
			return errors.New("invalid labelled query")
		}
		for _, id := range query.Relevant {
			if !known[id] {
				return errors.New("label references a thread outside the fixed corpus")
			}
		}
	}
	if err := os.MkdirAll(output, 0700); err != nil {
		return err
	}
	directory := filepath.Join(output, "runtime")
	if err := os.MkdirAll(directory, 0700); err != nil {
		return err
	}
	db, err := store.Open(filepath.Join(directory, "state.sqlite"))
	if err != nil {
		return err
	}
	defer db.Close()
	records := []model.ThreadRecord{}
	scope := []model.ThreadRef{}
	for _, document := range documents {
		record := thread(document.ID, document.Title, document.Text)
		record.Cwd, record.Tags = document.Cwd, document.Tags
		record.TagEmojis = map[string]string{}
		for _, tag := range record.Tags {
			record.TagEmojis[tag] = "🔖"
		}
		records = append(records, record)
		scope = append(scope, model.ThreadRef{ThreadID: document.ID, TypeID: "agent"})
	}
	seed(db, records...)
	var provider embedding.Provider
	if variant != "keyword" {
		if helper == "" || models == "" {
			return errors.New("hybrid evaluation requires a native helper and model directory")
		}
		helper, err = filepath.Abs(helper)
		if err != nil {
			return err
		}
		models, err = filepath.Abs(models)
		if err != nil {
			return err
		}
		provider = embedding.NewNative(ctx, embedding.NativeOptions{Executable: helper, ModelDirectory: models})
	}
	r, err := core.New(ctx, core.Config{Store: db, Harnesses: map[string]plugin.Harness{"fixture": harness{}}, DataDir: directory, DefaultCwd: directory, Embedding: provider, SearchTuning: tuning})
	if err != nil {
		return err
	}
	defer r.Close(ctx)
	started := time.Now()
	lastPending := -1
	if err = waitNative("corpus indexing", 15*time.Minute, func() bool {
		state := status(r)
		if provider == nil {
			return state.PendingDocuments == 0 && !state.Working
		}
		if state.Semantic != nil && state.Semantic.PendingDocuments != lastPending {
			lastPending = state.Semantic.PendingDocuments
			fmt.Printf("%s indexing: %d/%d threads, model %s\n", variant, state.Semantic.Indexed, len(documents), state.Semantic.Phase)
		}
		return state.Semantic != nil && state.Semantic.Ready && state.Semantic.Indexed == len(documents)
	}); err != nil {
		return err
	}
	indexMS := float64(time.Since(started).Microseconds()) / 1000
	results := []evaluationResult{}
	for _, sample := range queries {
		started := time.Now()
		var result threadsearch.QueryResult
		if err = waitNative("evaluation query "+sample.ID, 30*time.Second, func() bool {
			result = query(r, sample.Query, scope...)
			return provider == nil || result.Mode == "hybrid"
		}); err != nil {
			return err
		}
		results = append(results, evaluationResult{sample, result.Hits, float64(time.Since(started).Microseconds()) / 1000, result.Mode})
	}
	metrics := map[string]any{}
	for _, split := range []string{"tune", "holdout"} {
		positives, negatives, hit1, hit3, cleanNegatives := 0, 0, 0, 0, 0
		var reciprocal, precision, returned float64
		latencies := []float64{}
		for _, result := range results {
			if result.Case.Split != split {
				continue
			}
			latencies = append(latencies, result.Milliseconds)
			returned += float64(len(result.Hits))
			if len(result.Case.Relevant) == 0 {
				negatives++
				if len(result.Hits) == 0 {
					cleanNegatives++
				}
				continue
			}
			positives++
			wanted := map[string]bool{}
			for _, id := range result.Case.Relevant {
				wanted[id] = true
			}
			rank := 0
			relevant5 := 0
			for i, hit := range result.Hits {
				if wanted[hit.Ref.ThreadID] {
					if rank == 0 {
						rank = i + 1
					}
					if i < 5 {
						relevant5++
					}
				}
			}
			if rank == 1 {
				hit1++
			}
			if rank > 0 && rank <= 3 {
				hit3++
			}
			if rank > 0 {
				reciprocal += 1 / float64(rank)
			}
			if len(result.Hits) > 0 {
				precision += float64(relevant5) / float64(min(5, len(result.Hits)))
			}
		}
		sort.Float64s(latencies)
		if len(latencies) > 0 {
			metrics[split] = map[string]any{"positiveQueries": positives, "negativeQueries": negatives, "hit1": hit1, "hit3": hit3, "cleanNegatives": cleanNegatives, "mrr": reciprocal / float64(max(1, positives)), "meanPrecisionAt5": precision / float64(max(1, positives)), "meanReturned": returned / float64(len(latencies)), "p50Milliseconds": latencies[len(latencies)/2], "p95Milliseconds": latencies[min(len(latencies)-1, int(float64(len(latencies))*.95))]}
		}
	}
	report := map[string]any{"variant": variant, "tuning": tuning, "corpusThreads": len(documents), "indexMilliseconds": indexMS, "metrics": metrics, "results": results}
	data, err := json.MarshalIndent(report, "", "  ")
	if err != nil {
		return err
	}
	if err = os.WriteFile(filepath.Join(output, variant+".json"), append(data, '\n'), 0600); err != nil {
		return err
	}
	summary, _ := json.Marshal(metrics)
	fmt.Printf("%s metrics: %s\n", variant, summary)
	return nil
}

// This optional local tool reads one consistent SQLite snapshot. It invokes the
// production public-text adapters and never opens a native Harness session or
// modifies the user's profile. Real corpora must remain outside tracked files.
func extractEvaluationCorpus(path, output string) error {
	if output == "" {
		return errors.New("evaluation-output is required")
	}
	if err := os.MkdirAll(output, 0700); err != nil {
		return err
	}
	db, err := sqlite.Open(path, true)
	if err != nil {
		return err
	}
	defer db.Close()
	if err = db.Exec("BEGIN"); err != nil {
		return err
	}
	defer db.Exec("ROLLBACK")
	rows, err := db.Query("SELECT body FROM records WHERE key LIKE 'thread:%' ORDER BY key")
	if err != nil {
		return err
	}
	harnesses := map[string]plugin.Harness{"codex": codex.New(plugin.HostContext{}), "claude": claude.New(plugin.HostContext{}), "opencode": opencode.New(plugin.HostContext{}), "pi": pi.New(plugin.HostContext{})}
	excluded := map[string]int{}
	documents := []evaluationDocument{}
	for _, row := range rows {
		raw, ok := row["body"].([]byte)
		if !ok {
			return errors.New("invalid profile record encoding")
		}
		var record model.ThreadRecord
		if err = json.Unmarshal(raw, &record); err != nil {
			return err
		}
		if record.Moku || record.MokuHistory {
			excluded["private-conversation"]++
			continue
		}
		if record.Archived != nil && *record.Archived {
			excluded["archived"]++
			continue
		}
		if record.Observation.LatestExecution == nil || record.Observation.LatestExecution.Status != "completed" {
			excluded["not-completed"]++
			continue
		}
		harness := harnesses[record.HarnessID]
		if harness == nil {
			excluded["unsupported-harness"]++
			continue
		}
		adapter, ok := harness.SessionState().(plugin.SearchTextAdapter)
		if !ok {
			excluded["unsupported-adapter"]++
			continue
		}
		body, err := adapter.SearchText(record.SessionState)
		if err != nil {
			return err
		}
		if body == "" {
			excluded["no-public-text"]++
			continue
		}
		documents = append(documents, evaluationDocument{record.ID, record.Title, record.Cwd, record.Tags, body, threadsearch.Hash(raw)})
		fmt.Printf("%s\t%d public characters\t%s\n", record.ID, utf8.RuneCountInString(body), record.Title)
	}
	data, err := json.MarshalIndent(documents, "", "  ")
	if err != nil {
		return err
	}
	if err = os.WriteFile(filepath.Join(output, "corpus.json"), append(data, '\n'), 0600); err != nil {
		return err
	}
	metadata, _ := json.MarshalIndent(map[string]any{"documents": len(documents), "excluded": excluded, "source": "read-only profile snapshot via production public-text adapters"}, "", "  ")
	if err = os.WriteFile(filepath.Join(output, "corpus-metadata.json"), append(metadata, '\n'), 0600); err != nil {
		return err
	}
	fmt.Printf("Extracted %d public completed threads; exclusions: %v\n", len(documents), excluded)
	return nil
}
