package sessioncache

import (
	"context"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"sync"

	"github.com/hupao-creator/Mokusei/internal/core/model"
)

// Key is the canonical serialized renderer scope. Encoding the complete scope
// keeps future reading purposes and targets from sharing a projection slot.
const projectionOverhead int64 = 128

type Key string

func ScopeKey(scope model.RendererScope) Key {
	encoded, _ := json.Marshal(scope)
	return Key(encoded)
}

type Projection struct {
	Fingerprint [sha256.Size]byte
	Revision    int64
	// Value is immutable read-only JSON shared by cache hits.
	Value json.RawMessage
}

type flight struct {
	fingerprint [sha256.Size]byte
	ready       chan struct{}
}

// Projections retains a few dependency versions per scope. A matching
// fingerprint reuses the value even when unrelated session bytes changed. Old
// in-flight readers keep their version instead of replacing a newer result.
type Projections struct {
	mu       sync.Mutex
	entries  map[Key][]Projection
	inflight map[Key]*flight
	maximum  int
	versions int
	builds   int64
	hits     int64
}

func NewProjections() *Projections {
	return &Projections{entries: map[Key][]Projection{}, inflight: map[Key]*flight{}, maximum: 64, versions: 4}
}

func Fingerprint(value []byte) [sha256.Size]byte { return sha256.Sum256(value) }

func FingerprintString(value string) [sha256.Size]byte { return sha256.Sum256([]byte(value)) }

// Identity names exact state bytes without retaining them.
func Identity(value []byte) string {
	sum := sha256.Sum256(value)
	return hex.EncodeToString(sum[:])
}

// Revision returns a stable non-negative identity for one complete projection.
// Equal bytes keep the same source revision even across unrelated state updates.
func Revision(value []byte) int64 {
	sum := sha256.Sum256(value)
	revision := int64(binary.BigEndian.Uint64(sum[:8]) & 0x7fffffffffffffff)
	if revision == 0 {
		revision = 1
	}
	return revision
}

// Do returns the cached projection for key and fingerprint, otherwise builds it
// once. Concurrent readers of the same scope share one build; the returned delta
// is the byte change to account for in the owner cache.
func (p *Projections) Do(ctx context.Context, key Key, fingerprint [sha256.Size]byte, build func() (json.RawMessage, error)) (Projection, int64, error) {
	for {
		if err := ctx.Err(); err != nil {
			return Projection{}, 0, err
		}
		p.mu.Lock()
		if current, ok := p.matchLocked(key, fingerprint); ok {
			p.hits++
			p.mu.Unlock()
			return current, 0, nil
		}
		if active := p.inflight[key]; active != nil {
			ready := active.ready
			p.mu.Unlock()
			select {
			case <-ctx.Done():
				return Projection{}, 0, ctx.Err()
			case <-ready:
			}
			continue
		}
		active := &flight{fingerprint: fingerprint, ready: make(chan struct{})}
		p.inflight[key] = active
		p.mu.Unlock()

		value, err := buildProjection(ctx, build)

		p.mu.Lock()
		delete(p.inflight, key)
		close(active.ready)
		if err != nil {
			p.mu.Unlock()
			return Projection{}, 0, err
		}
		projection := Projection{Fingerprint: fingerprint, Revision: Revision(value), Value: value}
		previous := p.entries[key]
		before := p.bytesLocked()
		kept := make([]Projection, 0, min(len(previous)+1, p.versions))
		kept = append(kept, projection)
		for _, candidate := range previous {
			if candidate.Fingerprint == fingerprint {
				continue
			}
			if len(kept) >= p.versions {
				continue
			}
			kept = append(kept, candidate)
		}
		p.entries[key] = kept
		p.builds++
		p.pruneLocked()
		delta := p.bytesLocked() - before
		p.mu.Unlock()
		return projection, delta, nil
	}
}

func buildProjection(ctx context.Context, build func() (json.RawMessage, error)) (value json.RawMessage, err error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	defer func() {
		if recovered := recover(); recovered != nil {
			value = nil
			err = fmt.Errorf("reader projection panicked: %v", recovered)
		}
	}()
	value, err = build()
	if err == nil {
		err = ctx.Err()
	}
	return value, err
}

func (p *Projections) matchLocked(key Key, fingerprint [sha256.Size]byte) (Projection, bool) {
	for _, candidate := range p.entries[key] {
		if candidate.Fingerprint == fingerprint {
			return candidate, true
		}
	}
	return Projection{}, false
}

func (p *Projections) pruneLocked() {
	if len(p.entries) <= p.maximum {
		return
	}
	for key := range p.entries {
		delete(p.entries, key)
		if len(p.entries) <= p.maximum {
			return
		}
	}
}

// Stats is diagnostic evidence for reader-cache verification. It never changes
// projection behavior and is not persisted.
type Stats struct {
	IndexBuilds      int64
	IndexHits        int64
	ProjectionBuilds int64
	ProjectionHits   int64
	// Bytes and Threads are retained logical estimates. They include fixed
	// per-entry/scope overhead but not exact map/goroutine accounting. Use
	// process HeapInuse for physical evidence.
	Bytes           int64
	Threads         int
	RetainedBytes   int64
	RetainedThreads int
	LiveEntries     int
	LiveBytes       int64
}

func (p *Projections) stats() (builds, hits int64, bytes int64) {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.builds, p.hits, p.bytesLocked()
}

func (p *Projections) bytes() int64 {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.bytesLocked()
}

func (p *Projections) bytesLocked() int64 {
	var bytes int64
	for _, versions := range p.entries {
		for _, value := range versions {
			bytes += int64(len(value.Value)) + projectionOverhead
		}
	}
	return bytes
}
