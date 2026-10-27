package threadsearch

import (
	"context"
	"encoding/json"
	"sync"

	"github.com/hupao-creator/Mokusei/internal/core/store"
)

const documentCacheBytes = 64 << 20

// Cached documents are immutable. Index builders read their own mutable copy
// from the store; query/status readers never modify these slices.
type cachedDocument struct {
	hash  string
	value Document
	bytes int64
}

type cachedResult struct {
	result QueryResult
	event  queryCounts
}

type queryCounts struct {
	documents, chunks, semantic int
	bestCosine                  float64
}

type retrievalCache struct {
	mu         sync.Mutex
	generation uint64
	bytes      int64
	documents  map[string]cachedDocument
	results    map[string]cachedResult
}

func (c *retrievalCache) clear() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.generation++
	c.bytes = 0
	c.documents = nil
	c.results = nil
}

func (c *retrievalCache) document(ctx context.Context, snapshot store.Snapshot, key string) Document {
	if ctx.Err() != nil {
		return Document{}
	}
	hash, exists := snapshot.RecordHash(key)
	if !exists {
		return Document{}
	}
	c.mu.Lock()
	generation := c.generation
	entry, ok := c.documents[key]
	c.mu.Unlock()
	if ok && entry.hash == hash {
		return entry.value
	}
	var document Document
	if _, err := snapshot.Get(key, &document); err != nil {
		return Document{}
	}
	size := int64(512 + len(document.Owner) + len(document.Fingerprint) + len(document.Version))
	for _, chunk := range document.Chunks {
		size += int64(256 + len(chunk.Title) + len(chunk.Text) + len(chunk.Hash) + cap(chunk.Vector)*4)
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if generation != c.generation || ctx.Err() != nil || size > documentCacheBytes {
		return document
	}
	if c.documents == nil {
		c.documents = map[string]cachedDocument{}
	}
	if old, ok := c.documents[key]; ok {
		c.bytes -= old.bytes
		delete(c.documents, key)
	}
	for c.bytes+size > documentCacheBytes {
		for victim, old := range c.documents {
			delete(c.documents, victim)
			c.bytes -= old.bytes
			break
		}
	}
	c.documents[key] = cachedDocument{hash, document, size}
	c.bytes += size
	return document
}

func (c *retrievalCache) result(key string) (cachedResult, bool, uint64) {
	c.mu.Lock()
	defer c.mu.Unlock()
	value, ok := c.results[key]
	value.result.Hits = append([]Hit{}, value.result.Hits...)
	return value, ok, c.generation
}

func (c *retrievalCache) remember(key string, generation uint64, value cachedResult) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if generation != c.generation {
		return
	}
	if c.results == nil {
		c.results = map[string]cachedResult{}
	}
	if len(c.results) >= 8 {
		for victim := range c.results {
			delete(c.results, victim)
			break
		}
	}
	value.result.Hits = append([]Hit{}, value.result.Hits...)
	c.results[key] = value
}

// Fingerprints cover search inputs rather than the whole store revision, so
// unrelated writes do not restart expensive retrieval work.
func resultKey(snapshot store.Snapshot, config Config, request QueryRequest, sources []Source, scope map[string]bool) string {
	type stamp struct {
		Key, Owner, OwnerHash, CurrentOwnerHash, Identity, Title, Cwd, DocumentHash string
		Tags                                                                        []string
		Allowed                                                                     bool
	}
	stamps := []stamp{}
	for _, source := range sources {
		key := RefKey(source.Ref)
		if scope[key] {
			hash, _ := snapshot.RecordHash(documentPrefix + key)
			ownerHash, _ := snapshot.RecordHash(source.Owner)
			stamps = append(stamps, stamp{key, source.Owner, source.OwnerHash, ownerHash, source.Identity, source.Title, source.Cwd, hash, source.Tags, allowed(config, source)})
		}
	}
	raw, _ := json.Marshal([]any{config, request, stamps})
	return Hash(raw)
}
