package threadsearch

import (
	"context"
	"math"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/core/store"
)

// Local EmbeddingGemma 2 checks found unrelated threads with cosine scores in
// the 0.60–0.69 range. Prefer precision for semantic-only additions; literal
// matches qualify independently, even below this model-specific floor.
const semanticScoreFloor = 0.70

type QueryRequest struct {
	Query   string            `json:"query"`
	Threads []model.ThreadRef `json:"threads"`
	// Foundation's case/diacritic/width folding remains authoritative for native
	// metadata matches. Only live, authorized catalog members can be returned.
	KeywordMatches []model.ThreadRef `json:"keywordMatches"`
}
type Hit struct {
	Ref   model.ThreadRef `json:"ref"`
	Score float64         `json:"score"`
}
type QueryResult struct {
	Hits     []Hit  `json:"hits"`
	Mode     string `json:"mode"`
	Reason   string `json:"reason,omitempty"`
	Epoch    uint64 `json:"epoch"`
	Indexing bool   `json:"indexing"`
}

func validVector(values []float32) bool {
	if len(values) != Dimensions {
		return false
	}
	var norm float64
	for _, value := range values {
		v := float64(value)
		if math.IsNaN(v) || math.IsInf(v, 0) {
			return false
		}
		norm += v * v
	}
	return norm > 1e-12
}
func cosine(a, b []float32) float64 {
	if !validVector(a) || !validVector(b) {
		return -1
	}
	var dot, aa, bb float64
	for i, v := range a {
		x, y := float64(v), float64(b[i])
		dot += x * y
		aa += x * x
		bb += y * y
	}
	return dot / math.Sqrt(aa*bb)
}
func keywords(query, text string) bool {
	text = strings.ToLower(text)
	for _, term := range strings.Fields(strings.ToLower(query)) {
		if !strings.Contains(text, term) {
			return false
		}
	}
	return true
}
func (m *Manager) Query(ctx context.Context, request QueryRequest) (result QueryResult, err error) {
	ctx, id := plugin.SearchOperation(ctx)
	requestContext := ctx // Exclude the child context cancelled by this function on return.
	started := time.Now()
	event := plugin.SearchDiagnostic{Event: "search.query.completed", OperationID: id, ScopeCount: len(request.Threads), Cache: "none"}
	m.trace(plugin.SearchDiagnostic{Event: "search.query.started", OperationID: id, ScopeCount: len(request.Threads)})
	defer func() {
		event.DurationMS = plugin.SearchDuration(started)
		event.Mode = result.Mode
		event.Reason = result.Reason
		event.Epoch = result.Epoch
		event.HitCount = len(result.Hits)
		if len(result.Hits) > 0 {
			event.TopScore = result.Hits[0].Score
		}
		event.Outcome = "completed"
		if result.Reason != "" {
			event.Outcome = "fallback"
		}
		if err != nil {
			event.Outcome = "failed"
			event.Reason = plugin.SearchFailure(err)
		}
		if requestContext.Err() != nil {
			event.Outcome = "failed"
			event.Reason = plugin.SearchFailure(requestContext.Err())
		}
		m.trace(event)
	}()
	result = QueryResult{Hits: []Hit{}, Mode: "keyword"}
	if strings.TrimSpace(request.Query) == "" || utf8.RuneCountInString(request.Query) > 1024 || len(request.Threads) > 4096 || len(request.KeywordMatches) > 4096 {
		result.Reason = "query-limit"
		return result, nil
	}
	m.mu.Lock()
	session, unavailable := m.requestCtx, m.closed || m.paused
	result.Indexing = m.working
	m.mu.Unlock()
	if unavailable {
		result.Reason = "paused"
		return result, nil
	}
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	stop := context.AfterFunc(session, cancel)
	defer stop()
	snapshot := m.options.Store.Snapshot()
	c, err := readConfig(snapshot)
	if err != nil {
		return result, err
	}
	result.Epoch = c.Epoch
	if !c.Enabled {
		result.Reason = "disabled"
		return result, nil
	}
	sources, err := m.options.Sources(snapshot, false)
	if err != nil {
		return result, err
	}
	scope := map[string]bool{}
	for _, ref := range request.Threads {
		scope[RefKey(ref)] = true
	}
	literal := map[string]bool{}
	for _, ref := range request.KeywordMatches {
		literal[RefKey(ref)] = true
	}
	fingerprint := resultKey(snapshot, c, request, sources, scope)
	cached, cacheHit, generation := m.retrieval.result(fingerprint)
	if cacheHit && m.options.Provider != nil && m.options.Provider.Available(ctx) {
		current := m.options.Store.Snapshot()
		latest, _ := readConfig(current)
		if latest.Enabled && latest.Epoch == c.Epoch && ctx.Err() == nil && resultKey(current, latest, request, sources, scope) == fingerprint {
			result.Hits = cached.result.Hits
			result.Mode = cached.result.Mode
			event.Cache = "hit"
			event.DocumentCount, event.ChunkCount = cached.event.documents, cached.event.chunks
			event.SemanticCount, event.BestCosine = cached.event.semantic, cached.event.bestCosine
			return result, nil
		}
	}
	selected := map[string]Source{}
	documents := map[string]Document{}
	scores := map[string]float64{}
	for _, source := range sources {
		if err := ctx.Err(); err != nil {
			return result, err
		}
		key := RefKey(source.Ref)
		if !scope[key] {
			continue
		}
		selected[key] = source
		metadataMatch := literal[key] || keywords(request.Query, source.metadata())
		if metadataMatch {
			scores[key] = 2
		}
		if strings.Contains(strings.ToLower(source.Title), strings.ToLower(strings.TrimSpace(request.Query))) {
			scores[key] += 1
		}
		document := m.retrieval.document(ctx, snapshot, documentPrefix+key)
		if !allowed(c, source) || document.Version != indexVersion || document.SourceHash != source.OwnerHash {
			continue
		}
		documents[key] = document
		for _, chunk := range document.Chunks {
			if keywords(request.Query, chunk.Text) {
				scores[key] = max(scores[key], 2)
			}
		}
	}
	event.DocumentCount = len(documents)
	for _, document := range documents {
		event.ChunkCount += len(document.Chunks)
	}
	// No local query evaluation is needed while no usable indexed chunks exist.
	hasVectors := false
	for _, document := range documents {
		for _, chunk := range document.Chunks {
			if validVector(chunk.Vector) {
				hasVectors = true
				break
			}
		}
	}
	var vector []float32
	if !hasVectors {
		result.Reason = "index-empty"
	} else if m.options.Provider == nil || !m.options.Provider.Available(ctx) {
		result.Reason = "model-missing"
	} else {
		cacheKey := strconv.FormatUint(c.Epoch, 10) + ":" + Hash([]byte(strings.ToLower(strings.TrimSpace(request.Query))))
		m.mu.Lock()
		vector = m.cache[cacheKey]
		event.Cache = "miss"
		if vector != nil {
			event.Cache = "hit"
		}
		m.mu.Unlock()
		if vector == nil {
			vector, err = m.request(ctx, c, "task: search result | query: "+strings.TrimSpace(request.Query), cacheKey)
		}
		if err != nil {
			if ctx.Err() != nil {
				return result, ctx.Err()
			}
			result.Reason = reason(err)
		} else {
			result.Mode = "hybrid"
		}
	}
	if vector != nil {
		type candidate struct {
			key   string
			score float64
		}
		semantic := []candidate{}
		for key, document := range documents {
			if err := ctx.Err(); err != nil {
				return result, err
			}
			best := -1.0
			for _, chunk := range document.Chunks {
				best = max(best, cosine(vector, chunk.Vector))
			}
			event.BestCosine = max(event.BestCosine, best)
			// Literal identifiers/Chinese substrings always qualify separately.
			if best >= semanticScoreFloor {
				semantic = append(semantic, candidate{key, best})
			}
		}
		event.SemanticCount = len(semantic)
		sort.Slice(semantic, func(i, j int) bool {
			if semantic[i].score == semantic[j].score {
				return semantic[i].key < semantic[j].key
			}
			return semantic[i].score > semantic[j].score
		})
		for i, item := range semantic {
			if i < 20 || scores[item.key] > 0 {
				scores[item.key] += item.score
			}
		}
	}
	// Revalidate after HTTP, including a cancellation-resistant transport. An
	// archive, deletion, source change or consent reset cannot leak stale hits.
	current := m.options.Store.Snapshot()
	latest, _ := readConfig(current)
	if !latest.Enabled || latest.Epoch != c.Epoch || ctx.Err() != nil {
		result.Reason = "stale"
		result.Mode = "keyword"
		result.Hits = nil
		return result, nil
	}
	for key, score := range scores {
		source := selected[key]
		hash, exists := current.RecordHash(source.Owner)
		if exists && hash == source.OwnerHash {
			result.Hits = append(result.Hits, Hit{source.Ref, score})
		}
	}
	sort.Slice(result.Hits, func(i, j int) bool {
		if result.Hits[i].Score == result.Hits[j].Score {
			return RefKey(result.Hits[i].Ref) < RefKey(result.Hits[j].Ref)
		}
		return result.Hits[i].Score > result.Hits[j].Score
	})
	if result.Mode == "hybrid" && result.Reason == "" && resultKey(current, latest, request, sources, scope) == fingerprint {
		m.retrieval.remember(fingerprint, generation, cachedResult{result, queryCounts{event.DocumentCount, event.ChunkCount, event.SemanticCount, event.BestCosine}})
	}
	return result, nil
}

// ValidateDocumentSource is used by the single writer for persisted index commits.
func persist(ctx context.Context, s *store.Store, c Config, source Source, document Document) error {
	_, err := s.Update(ctx, func(tx *store.Tx) error {
		live, e := readConfig(tx.Snapshot())
		if e != nil {
			return e
		}
		hash, exists := tx.RecordHash(source.Owner)
		if !exists || hash != source.OwnerHash || live.Epoch != c.Epoch || !allowed(live, source) {
			return nil
		}
		return tx.Put(documentPrefix+RefKey(source.Ref), document)
	})
	return err
}
