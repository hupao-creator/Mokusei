package threadsearch

import (
	"context"
	"sort"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/core/store"
)

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
	if cacheHit {
		current := m.options.Store.Snapshot()
		latest, _ := readConfig(current)
		if latest.Epoch == c.Epoch && ctx.Err() == nil && resultKey(current, latest, request, sources, scope) == fingerprint {
			result.Hits = cached.result.Hits
			result.Mode = cached.result.Mode
			event.Cache = "hit"
			event.DocumentCount = cached.event.documents
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
		document := m.retrieval.document(ctx, snapshot, documentKey(source))
		if document.Version != indexVersion || document.SourceHash != source.OwnerHash {
			continue
		}
		documents[key] = document
		if keywords(request.Query, document.LiteralText) {
			scores[key] = max(scores[key], 2)
		}
	}
	event.DocumentCount = len(documents)
	// Revalidate owner and epoch after reading projections so deletion and
	// history clearing cannot return stale source content.
	current := m.options.Store.Snapshot()
	latest, _ := readConfig(current)
	if latest.Epoch != c.Epoch || ctx.Err() != nil {
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
	if result.Reason == "" && resultKey(current, latest, request, sources, scope) == fingerprint {
		m.retrieval.remember(fingerprint, generation, cachedResult{result, queryCounts{event.DocumentCount}})
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
		if !exists || hash != source.OwnerHash || live.Epoch != c.Epoch {
			return nil
		}
		key := documentKey(source)
		if err := tx.Put(key, document); err != nil {
			return err
		}
		hash, _ = tx.RecordHash(key)
		return tx.Put(stampKey(source), documentStamp{SourceHash: source.OwnerHash, DocumentHash: hash, Version: indexVersion, Truncated: document.Truncated})
	})
	return err
}
