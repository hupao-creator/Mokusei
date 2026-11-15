package sessioncache

import (
	"context"
	"encoding/json"
	"fmt"
	"sync"
)

const (
	scopeOverhead     int64 = 128
	DefaultScopeBytes int64 = 64 << 20
)

// Scopes is a bounded, single-flight store for partially materialized narrow
// renderer states. Each value is retained only while it fits the per-session
// count and byte limits; larger values remain transient and are returned to the
// caller without entering the cache.
type Scopes struct {
	mu       sync.Mutex
	entries  map[Key]json.RawMessage
	order    []Key
	inflight map[Key]*scopeFlight
	maximum  int
	maxBytes int64
	bytes    int64
	builds   int64
	hits     int64
}

type scopeFlight struct{ ready chan struct{} }

func NewScopes(maximum int, maxBytes int64) *Scopes {
	if maximum <= 0 {
		maximum = 64
	}
	if maxBytes <= 0 {
		maxBytes = DefaultScopeBytes
	}
	return &Scopes{entries: map[Key]json.RawMessage{}, inflight: map[Key]*scopeFlight{}, maximum: maximum, maxBytes: maxBytes}
}

// Do returns a retained scope value or builds it once. The returned delta is
// the retained-byte change, including map overhead and LRU evictions.
func (s *Scopes) Do(ctx context.Context, key Key, build func(context.Context) (json.RawMessage, error)) (json.RawMessage, int64, error) {
	for {
		if err := ctx.Err(); err != nil {
			return nil, 0, err
		}
		s.mu.Lock()
		if value, ok := s.entries[key]; ok {
			s.touchLocked(key)
			s.hits++
			s.mu.Unlock()
			return value, 0, nil
		}
		if active := s.inflight[key]; active != nil {
			ready := active.ready
			s.mu.Unlock()
			select {
			case <-ctx.Done():
				return nil, 0, ctx.Err()
			case <-ready:
			}
			continue
		}
		active := &scopeFlight{ready: make(chan struct{})}
		s.inflight[key] = active
		s.mu.Unlock()

		value, err := buildScope(ctx, build)

		s.mu.Lock()
		delete(s.inflight, key)
		close(active.ready)
		if err != nil {
			s.mu.Unlock()
			return nil, 0, err
		}
		before := s.bytes
		if int64(len(value))+scopeOverhead <= s.maxBytes {
			if previous, exists := s.entries[key]; exists {
				s.bytes -= int64(len(previous)) + scopeOverhead
			}
			s.entries[key] = value
			s.bytes += int64(len(value)) + scopeOverhead
			s.touchLocked(key)
			s.builds++
			s.pruneLocked()
		}
		delta := s.bytes - before
		s.mu.Unlock()
		return value, delta, nil
	}
}

func buildScope(ctx context.Context, build func(context.Context) (json.RawMessage, error)) (value json.RawMessage, err error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	defer func() {
		if recovered := recover(); recovered != nil {
			value = nil
			err = fmt.Errorf("reader scope build panicked: %v", recovered)
		}
	}()
	value, err = build(ctx)
	if err == nil {
		err = ctx.Err()
	}
	return value, err
}

func (s *Scopes) touchLocked(key Key) {
	for i, current := range s.order {
		if current == key {
			s.order = append(s.order[:i], s.order[i+1:]...)
			break
		}
	}
	s.order = append(s.order, key)
}

func (s *Scopes) pruneLocked() {
	for len(s.entries) > s.maximum || s.bytes > s.maxBytes {
		if len(s.order) == 0 {
			return
		}
		oldest := s.order[0]
		s.order = s.order[1:]
		value, exists := s.entries[oldest]
		if !exists {
			continue
		}
		delete(s.entries, oldest)
		s.bytes -= int64(len(value)) + scopeOverhead
	}
}

func (s *Scopes) bytesLocked() int64 { return s.bytes }
