package sessioncache

import (
	"context"
	"fmt"
	"sync"
)

// DefaultBudget bounds retained index bytes, cached projections and per-thread
// overlap. Old content versions retained by an in-flight read are temporary and
// disappear when their leases release.
const DefaultBudget int64 = 128 << 20

const (
	defaultThreads       = 256
	entryOverhead  int64 = 4096
)

type Cache struct {
	mu          sync.Mutex
	budget      int64
	entryBudget int64
	maxThreads  int
	used        int64
	clock       uint64
	threads     map[string]*Entry
	closed      bool
	builds      int64
	hits        int64
	live        map[*Entry]bool
}

type Entry struct {
	cache       *Cache
	ThreadID    string
	gate        chan struct{} // context-aware index replacement lock
	contentID   string
	value       any
	generation  int64
	projections *Projections

	// The fields below are guarded by cache.mu.
	size      int64
	refs      int
	lastUse   uint64
	removed   bool
	oversized bool
}

type Handle struct {
	Entry       *Entry
	Value       any
	Projections *Projections
	cache       *Cache
	account     bool
	released    bool
}

func NewCache(budget int64) *Cache {
	return NewCacheWithLimits(budget, budget, defaultThreads)
}

func NewCacheWithLimits(budget, entryBudget int64, maxThreads int) *Cache {
	if budget <= 0 {
		budget = DefaultBudget
	}
	if entryBudget <= 0 || entryBudget > budget {
		entryBudget = budget
	}
	if maxThreads <= 0 {
		maxThreads = defaultThreads
	}
	return &Cache{budget: budget, entryBudget: entryBudget, maxThreads: maxThreads, threads: map[string]*Entry{}, live: map[*Entry]bool{}}
}

// Acquire returns the latest indexed value for a Thread, rebuilding only when
// the content identity changes. Build receives the previous indexed value and
// the Thread's shared projection cache so record-level reuse stays local to the
// adapter. The value must be immutable after return.
func (c *Cache) Acquire(ctx context.Context, threadID, contentID string, generation int64, build func(context.Context, any, *Projections) (any, int64, error)) (*Handle, error) {
	for {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		c.mu.Lock()
		if c.closed {
			c.mu.Unlock()
			return nil, ErrClosed
		}
		entry := c.threads[threadID]
		if entry == nil {
			entry = &Entry{cache: c, ThreadID: threadID, gate: make(chan struct{}, 1), projections: NewProjections()}
			entry.gate <- struct{}{}
			c.threads[threadID] = entry
		}
		c.live[entry] = true
		entry.refs++
		entry.lastUse = c.clock
		c.clock++
		c.mu.Unlock()

		if err := entry.lock(ctx); err != nil {
			c.release(entry)
			return nil, err
		}
		unlocked := false
		unlock := func() {
			if !unlocked {
				unlocked = true
				entry.unlock()
			}
		}
		defer unlock()
		c.mu.Lock()
		removed := entry.removed
		c.mu.Unlock()
		if removed {
			unlock()
			c.release(entry)
			continue
		}
		if entry.contentID == contentID && entry.value != nil {
			value := entry.value
			if generation > entry.generation {
				entry.generation = generation
			}
			unlock()
			c.mu.Lock()
			c.hits++
			c.mu.Unlock()
			return &Handle{Entry: entry, Value: value, Projections: entry.projections, cache: c, account: true}, nil
		}
		stale := generation > 0 && entry.value != nil && generation < entry.generation
		previous := entry.value
		projections := entry.projections
		c.mu.Lock()
		previousSize := entry.size
		c.mu.Unlock()
		// Build under the entry gate so one Thread has at most one index
		// replacement; waiters observe cancellation while the gate is held.
		value, size, err := buildEntry(ctx, build, previous, projections)
		if err != nil {
			unlock()
			c.release(entry)
			return nil, err
		}
		c.mu.Lock()
		removedAfterBuild := entry.removed
		closed := c.closed
		c.mu.Unlock()
		if removedAfterBuild || closed {
			unlock()
			c.mu.Lock()
			c.builds++
			c.mu.Unlock()
			return &Handle{Entry: entry, Value: value, Projections: NewProjections(), cache: c, account: false}, nil
		}
		retainedSize := size + projections.bytes() + entryOverhead
		if stale || retainedSize > c.entryBudget {
			// Stale and oversized generations stay transient. They use a private
			// projection set so their bytes never become retained cache state.
			unlock()
			c.mu.Lock()
			c.builds++
			c.mu.Unlock()
			return &Handle{Entry: entry, Value: value, Projections: NewProjections(), cache: c, account: false}, nil
		}
		entry.value, entry.contentID = value, contentID
		entry.generation = max(entry.generation, generation)
		c.mu.Lock()
		entry.size = retainedSize
		entry.oversized = retainedSize > c.entryBudget
		c.used += entry.size - previousSize
		c.builds++
		c.evictLocked(entry)
		c.mu.Unlock()
		unlock()
		return &Handle{Entry: entry, Value: value, Projections: projections, cache: c, account: true}, nil
	}
}

func (e *Entry) lock(ctx context.Context) error {
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-e.gate:
		return nil
	}
}

func (e *Entry) unlock() { e.gate <- struct{}{} }

func buildEntry(ctx context.Context, build func(context.Context, any, *Projections) (any, int64, error), previous any, projections *Projections) (value any, size int64, err error) {
	defer func() {
		if recovered := recover(); recovered != nil {
			value = nil
			size = 0
			err = fmt.Errorf("reader index build panicked: %v", recovered)
		}
	}()
	return build(ctx, previous, projections)
}

func (h *Handle) AddSize(delta int64) {
	if h == nil || h.released || !h.account || delta == 0 {
		return
	}
	h.cache.mu.Lock()
	defer h.cache.mu.Unlock()
	if h.Entry.removed {
		return
	}
	if h.Entry.size+delta > h.cache.entryBudget {
		// Stop retaining this generation as soon as its live projections cross
		// the per-entry limit. The current handle keeps its immutable value.
		h.cache.used -= h.Entry.size
		h.Entry.size = 0
		h.Entry.removed = true
		h.Entry.oversized = true
		if h.cache.threads[h.Entry.ThreadID] == h.Entry {
			delete(h.cache.threads, h.Entry.ThreadID)
		}
		return
	}
	h.Entry.size += delta
	h.cache.used += delta
	h.Entry.oversized = h.Entry.size > h.cache.entryBudget
	h.cache.evictLocked(h.Entry)
}

func (h *Handle) Release() {
	if h == nil || h.released {
		return
	}
	h.released = true
	h.cache.release(h.Entry)
}

func (c *Cache) release(entry *Entry) {
	c.mu.Lock()
	if entry.refs > 0 {
		entry.refs--
	}
	if entry.refs == 0 {
		delete(c.live, entry)
		if entry.removed || entry.oversized || entry.value == nil {
			c.used -= entry.size
			entry.size = 0
			entry.removed = true
			// A retired handle can outlive a replacement for this Thread.
			if c.threads[entry.ThreadID] == entry {
				delete(c.threads, entry.ThreadID)
			}
		}
	}
	entry.lastUse = c.clock
	c.clock++
	c.evictLocked(nil)
	c.mu.Unlock()
}

func (c *Cache) evictLocked(keep *Entry) {
	for {
		var victim *Entry
		for _, candidate := range c.threads {
			if candidate == keep || candidate.refs != 0 || candidate.removed {
				continue
			}
			if candidate.oversized {
				victim = candidate
				break
			}
			if victim == nil || candidate.lastUse < victim.lastUse {
				victim = candidate
			}
		}
		if victim == nil {
			return
		}
		if !victim.oversized && c.used <= c.budget && len(c.threads) <= c.maxThreads {
			return
		}
		victim.removed = true
		c.used -= victim.size
		victim.size = 0
		delete(c.threads, victim.ThreadID)
	}
}

// ReleaseThread drops every cached generation for one Thread. It never waits
// for an in-flight build; that handle owns its value until release.
func (c *Cache) ReleaseThread(threadID string) {
	c.mu.Lock()
	entry := c.threads[threadID]
	if entry != nil {
		delete(c.threads, threadID)
		entry.removed = true
		if entry.refs == 0 {
			c.used -= entry.size
			entry.size = 0
		}
	}
	c.mu.Unlock()
}

func (c *Cache) Close() {
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return
	}
	c.closed = true
	for _, entry := range c.threads {
		entry.removed = true
		if entry.refs == 0 {
			c.used -= entry.size
			entry.size = 0
		}
	}
	c.threads = map[string]*Entry{}
	c.mu.Unlock()
}

func (c *Cache) Stats() Stats {
	c.mu.Lock()
	threads := len(c.threads)
	bytes := c.used
	builds, hits := c.builds, c.hits
	entries := make([]*Entry, 0, len(c.threads))
	for _, entry := range c.threads {
		entries = append(entries, entry)
	}
	var liveEntries int
	var liveBytes int64
	for entry := range c.live {
		liveEntries++
		liveBytes += entry.size
	}
	c.mu.Unlock()
	var projectionBuilds, projectionHits int64
	for _, entry := range entries {
		build, hit, _ := entry.projections.stats()
		projectionBuilds += build
		projectionHits += hit
	}
	return Stats{
		IndexBuilds: builds, IndexHits: hits,
		ProjectionBuilds: projectionBuilds, ProjectionHits: projectionHits,
		Bytes: bytes, Threads: threads,
		RetainedBytes: bytes, RetainedThreads: threads,
		LiveEntries: liveEntries, LiveBytes: liveBytes,
	}
}
