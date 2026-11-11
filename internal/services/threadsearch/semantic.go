package threadsearch

import (
	"context"
	"encoding/json"
	"errors"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/services/embedding"
)

type SemanticStatus struct {
	embedding.Status
	Indexing         bool `json:"indexing"`
	PendingDocuments int  `json:"pendingDocuments"`
	Indexed          int  `json:"indexed"`
}
type queryEmbedding struct {
	vector   []float32
	cancel   context.CancelFunc
	failedAt time.Time
}
type semanticIndex struct {
	manager  *Manager
	provider embedding.Provider
	store    *vectorStore
	mu       sync.Mutex
	ctx      context.Context
	cancel   context.CancelFunc
	done     chan struct{}
	queries  sync.WaitGroup
	cache    map[string]*queryEmbedding
	revision uint64
	working  bool
	pending  int
	reason   string
	retry    chan struct{}
}

func newSemanticIndex(m *Manager) *semanticIndex {
	s := &semanticIndex{manager: m, provider: m.options.Embedding, retry: make(chan struct{}, 1)}
	s.start(m.requestCtx)
	return s
}
func (s *semanticIndex) database() *vectorStore {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.store
}
func (s *semanticIndex) closeStore() error {
	if db := s.database(); db != nil {
		return db.close()
	}
	return nil
}
func (s *semanticIndex) clearStore() error {
	if db := s.database(); db != nil {
		return db.prune(map[string]bool{})
	}
	return nil
}
func (s *semanticIndex) start(parent context.Context) {
	s.mu.Lock()
	s.ctx, s.cancel = context.WithCancel(parent)
	s.done, s.cache = make(chan struct{}), map[string]*queryEmbedding{}
	s.revision++
	ctx, done := s.ctx, s.done
	s.mu.Unlock()
	go func() { defer close(done); s.watch(ctx) }()
}
func (s *semanticIndex) stop() {
	s.mu.Lock()
	s.cancel()
	done := s.done
	s.mu.Unlock()
	<-done
	s.queries.Wait()
	s.mu.Lock()
	s.cache = nil
	s.revision++
	s.mu.Unlock()
}
func (s *semanticIndex) status() *SemanticStatus {
	state := s.provider.Status()
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.reason != "" {
		state.Reason = s.reason
	}
	return &SemanticStatus{Status: state, Indexing: s.working, PendingDocuments: s.pending}
}
func (m *Manager) semanticStatus(snapshot store.Snapshot, config Config, sources []Source) (*SemanticStatus, error) {
	if m.semantic == nil {
		return nil, nil
	}
	state := m.semantic.status()
	state.PendingDocuments = 0
	descriptor := m.options.Embedding.Descriptor()
	pipeline := m.semantic.pipeline()
	for _, source := range sources {
		if source.Busy {
			continue
		}
		stamp, err := readStamp(snapshot, source)
		if err != nil {
			return nil, err
		}
		var vector vectorStamp
		if _, err = snapshot.Get(vectorStampPrefix+documentSuffix(source), &vector); err != nil {
			return nil, err
		}
		if currentStamp(snapshot, source, stamp) && vector.Space == descriptor.Space && vector.Pipeline == pipeline && vector.Epoch == config.Epoch && vector.DocumentHash == stamp.DocumentHash {
			state.Indexed++
		} else {
			state.PendingDocuments++
		}
	}
	if state.Ready && state.Reason == "" && state.PendingDocuments > 0 {
		state.Indexing = true
	}
	return state, nil
}
func (s *semanticIndex) token() string {
	s.mu.Lock()
	revision := s.revision
	s.mu.Unlock()
	raw, _ := json.Marshal([]any{s.provider.Descriptor(), s.provider.Status().Ready, revision})
	return Hash(raw)
}
func (s *semanticIndex) pipeline() string {
	return vectorPipeline + ":" + strconv.Itoa(min(s.manager.options.Tuning.PassageBytes, s.provider.Descriptor().DocumentBytes))
}
func (s *semanticIndex) query(text string) ([]float32, bool) {
	if !s.provider.Status().Ready {
		return nil, false
	}
	descriptor := s.provider.Descriptor()
	key := descriptor.Space + "\x00" + strings.TrimSpace(text)
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.ctx.Err() != nil {
		return nil, false
	}
	if entry := s.cache[key]; entry != nil {
		if entry.failedAt.IsZero() || time.Since(entry.failedAt) < 5*time.Second {
			return entry.vector, entry.vector != nil
		}
		delete(s.cache, key)
	}
	if len(s.cache) >= 8 {
		for old, entry := range s.cache {
			entry.cancel()
			delete(s.cache, old)
			break
		}
	}
	ctx, cancel := context.WithCancel(s.ctx)
	entry := &queryEmbedding{cancel: cancel}
	s.cache[key] = entry
	s.queries.Add(1)
	go func() {
		defer s.queries.Done()
		defer cancel()
		vectors, err := s.provider.Embed(ctx, embedding.Query, []string{text})
		s.mu.Lock()
		defer s.mu.Unlock()
		if ctx.Err() != nil || s.cache[key] != entry {
			return
		}
		if err != nil {
			entry.failedAt = time.Now()
		} else {
			entry.vector = vectors[0]
		}
		s.revision++
	}()
	return nil, false
}
func (s *semanticIndex) watch(ctx context.Context) {
	changes, unsubscribe := s.manager.options.Store.Subscribe()
	defer unsubscribe()
	ticker := time.NewTicker(s.manager.options.WatchInterval)
	defer ticker.Stop()
	var previous store.Snapshot
	space := ""
	dirty := true
	retryAt := time.Time{}
	backoff := s.manager.options.RetryMin
	for {
		select {
		case <-ctx.Done():
			return
		case <-s.retry:
			dirty = true
			previous = store.Snapshot{}
			retryAt = time.Time{}
		case _, ok := <-changes:
			if !ok {
				return
			}
			dirty = true
		case <-ticker.C:
			if !s.provider.Status().Ready {
				continue
			}
			descriptor := s.provider.Descriptor()
			if descriptor.Space != space {
				previous = store.Snapshot{}
				space = descriptor.Space
				dirty = true
			}
			if !dirty || time.Now().Before(retryAt) {
				continue
			}
			snapshot := s.manager.options.Store.Snapshot()
			s.mu.Lock()
			s.working = true
			s.mu.Unlock()
			err := s.build(ctx, snapshot, previous, descriptor)
			s.mu.Lock()
			s.working = false
			if err != nil && ctx.Err() == nil {
				s.reason = "semantic-index-failed"
				retryAt = time.Now().Add(backoff)
				backoff = min(s.manager.options.RetryMax, backoff*2)
			} else if err == nil {
				s.reason = ""
				previous = snapshot
				dirty = false
				retryAt = time.Time{}
				backoff = s.manager.options.RetryMin
			}
			s.mu.Unlock()
		}
	}
}
func (s *semanticIndex) build(ctx context.Context, snapshot, previous store.Snapshot, descriptor embedding.Descriptor) error {
	config, err := readConfig(snapshot)
	if err != nil {
		return err
	}
	previousConfig, _ := readConfig(previous)
	if config.Epoch != previousConfig.Epoch {
		previous = store.Snapshot{}
	}
	keys := snapshot.ChangedKeys(previous, stampPrefix)
	// Telemetry and our own publication stamps are not an indexing queue.
	// Avoid scanning/compacting the vector database after unrelated commits.
	if len(keys) == 0 && previous.Revision() != 0 {
		return nil
	}
	db := s.database()
	if db == nil {
		opened, err := openVectorStore(s.manager.options.VectorPath)
		if err != nil {
			return err
		}
		s.mu.Lock()
		s.store = opened
		s.revision++
		s.mu.Unlock()
		db = opened
	}
	s.mu.Lock()
	s.pending = len(keys)
	s.mu.Unlock()
	for i, stamp := range keys {
		if err := ctx.Err(); err != nil {
			return err
		}
		s.mu.Lock()
		s.pending = len(keys) - i
		s.mu.Unlock()
		suffix := strings.TrimPrefix(stamp, stampPrefix)
		key := documentPrefix + suffix
		hash, exists := snapshot.RecordHash(key)
		if !exists {
			continue
		}
		var indexed vectorStamp
		if _, err := snapshot.Get(vectorStampPrefix+suffix, &indexed); err != nil {
			return err
		}
		if indexed.DocumentHash == hash && indexed.Space == descriptor.Space && indexed.Pipeline == s.pipeline() && indexed.Epoch == config.Epoch && db.has(indexed.Generation) {
			continue
		}
		var document Document
		if _, err := snapshot.Get(key, &document); err != nil {
			return err
		}
		ownerHash, exists := snapshot.RecordHash(document.Owner)
		if !exists || ownerHash != document.SourceHash || document.Version != indexVersion {
			continue
		}
		if document.BodyOffset < 0 || document.BodyOffset > len(document.LiteralText) || !utf8.ValidString(document.LiteralText) {
			return errors.New("invalid persisted search document")
		}
		hashes := []string{}
		metadataPassages := 0
		for _, passage := range embeddingPassages(document, min(s.manager.options.Tuning.PassageBytes, descriptor.DocumentBytes)) {
			if err := ctx.Err(); err != nil {
				return err
			}
			text := strings.TrimSpace(passage.Text)
			if text == "" {
				continue
			}
			if passage.Metadata {
				metadataPassages++
			}
			chunk := Hash([]byte(text))
			hashes = append(hashes, chunk)
			cached, err := db.get(descriptor.Space, chunk, descriptor.Dimensions)
			if err != nil {
				return err
			}
			if cached {
				continue
			}
			// One passage per admission bounds the interval before a waiting
			// interactive query can use the serial inference process.
			vectors, err := s.provider.Embed(ctx, embedding.Document, []string{text})
			if err != nil {
				return err
			}
			if err := ctx.Err(); err != nil {
				return err
			}
			if err = db.put(descriptor.Space, chunk, vectors[0]); err != nil {
				return err
			}
		}
		raw, _ := json.Marshal([]any{key, hash, config.Epoch, descriptor.Space, s.pipeline()})
		generation := Hash(raw)
		if err = db.publish(generation, descriptor.Space, hashes); err != nil {
			return err
		}
		_, err = s.manager.options.Store.Update(ctx, func(tx *store.Tx) error {
			live, err := readConfig(tx.Snapshot())
			if err != nil {
				return err
			}
			currentHash, exists := tx.RecordHash(key)
			ownerHash, ownerExists := tx.RecordHash(document.Owner)
			if !exists || !ownerExists || currentHash != hash || ownerHash != document.SourceHash || live.Epoch != config.Epoch {
				return nil
			}
			return tx.Put(vectorStampPrefix+suffix, vectorStamp{generation, descriptor.Space, s.pipeline(), hash, config.Epoch, len(hashes), metadataPassages})
		})
		if err != nil {
			return err
		}
	}
	s.mu.Lock()
	s.pending = 0
	s.mu.Unlock()
	return s.prune()
}
func (s *semanticIndex) prune() error {
	snapshot := s.manager.options.Store.Snapshot()
	config, err := readConfig(snapshot)
	if err != nil {
		return err
	}
	live := map[string]bool{}
	for _, key := range snapshot.Keys(vectorStampPrefix) {
		var stamp vectorStamp
		if _, err := snapshot.Get(key, &stamp); err != nil {
			return err
		}
		hash, exists := snapshot.RecordHash(documentPrefix + strings.TrimPrefix(key, vectorStampPrefix))
		if exists && hash == stamp.DocumentHash && stamp.Epoch == config.Epoch && stamp.Space == s.provider.Descriptor().Space && stamp.Pipeline == s.pipeline() {
			live[stamp.Generation] = true
		}
	}
	if db := s.database(); db != nil {
		return db.prune(live)
	}
	return nil
}
func (s *semanticIndex) scores(ctx context.Context, snapshot store.Snapshot, config Config, sources map[string]Source, documents map[string]Document, query []float32) (map[string]float64, error) {
	descriptor := s.provider.Descriptor()
	allowed := map[string]vectorCandidate{}
	for key := range documents {
		source := sources[key]
		var stamp vectorStamp
		if _, err := snapshot.Get(vectorStampPrefix+documentSuffix(source), &stamp); err != nil {
			return nil, err
		}
		hash, _ := snapshot.RecordHash(documentKey(source))
		if stamp.Space == descriptor.Space && stamp.Pipeline == s.pipeline() && stamp.DocumentHash == hash && stamp.Epoch == config.Epoch {
			allowed[stamp.Generation] = vectorCandidate{key, stamp.MetadataPassages}
		}
	}
	if db := s.database(); db != nil {
		return db.scores(ctx, descriptor.Space, query, allowed, s.manager.options.Tuning.MetadataWeight)
	}
	return nil, errors.New("vector index unavailable")
}

// Reciprocal rank fusion combines independent rankings without treating a
// cosine similarity as a calibrated probability. Exact titles retain priority.
func fuse(scores map[string]float64, semantic map[string]float64, tuning Tuning) {
	literalKeys := make([]string, 0, len(scores))
	for key := range scores {
		literalKeys = append(literalKeys, key)
	}
	sort.Slice(literalKeys, func(i, j int) bool {
		a, b := literalKeys[i], literalKeys[j]
		if scores[a] == scores[b] {
			return a < b
		}
		return scores[a] > scores[b]
	})
	semanticKeys := []string{}
	for key, score := range semantic {
		if score >= tuning.MinimumSimilarity {
			semanticKeys = append(semanticKeys, key)
		}
	}
	sort.Slice(semanticKeys, func(i, j int) bool {
		a, b := semanticKeys[i], semanticKeys[j]
		if semantic[a] == semantic[b] {
			return a < b
		}
		return semantic[a] > semantic[b]
	})
	semanticKeys = semanticKeys[:min(tuning.SemanticLimit, len(semanticKeys))]
	for rank, key := range literalKeys {
		title := scores[key] >= 3
		scores[key] = 1 / float64(61+rank)
		if title {
			scores[key] += 1
		}
	}
	for rank, key := range semanticKeys {
		scores[key] += 1 / float64(61+rank)
	}
}
