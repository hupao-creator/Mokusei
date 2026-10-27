// Package discovery shares bounded, read-only native probes. It is not an
// execution authority: callers decide which successful facts may be cached.
package discovery

import (
	"context"
	"errors"
	"sync"
	"time"
)

type entry[T any] struct {
	value T
	at    time.Time
}
type flight[T any] struct {
	done    chan struct{}
	cancel  context.CancelFunc
	readers int
	refresh bool
	value   T
	err     error
}

// Cache owns probes independently of any one reader. Values must be immutable
// once published; adapters clone mutable projections at their public boundary.
// A zero Cache is ready to use. Failed probes never replace the last success.
type Cache[T any] struct {
	mu         sync.Mutex
	entries    map[string]entry[T]
	pending    map[string]*flight[T]
	active     map[*flight[T]]bool
	closed     bool
	cleanupErr error
}

type cleanupError struct{ error }

func (e cleanupError) Unwrap() error { return e.error }

// Cleanup marks native ownership failure separately from an ordinary read
// failure. An uncertain child must not be replaced by another discovery owner.
func Cleanup(err error) error {
	if err == nil {
		return nil
	}
	return cleanupError{err}
}

func (c *Cache[T]) Get(ctx context.Context, key string, refresh bool, ttl, timeout time.Duration, probe func(context.Context) (T, error)) (T, error) {
	var zero T
	if err := ctx.Err(); err != nil {
		return zero, err
	}
	c.mu.Lock()
	if c.cleanupErr != nil {
		err := c.cleanupErr
		c.mu.Unlock()
		return zero, err
	}
	if c.closed {
		c.mu.Unlock()
		return zero, errors.New("native discovery is closed")
	}
	if c.entries == nil {
		c.entries = map[string]entry[T]{}
		c.pending = map[string]*flight[T]{}
		c.active = map[*flight[T]]bool{}
	}
	f := c.pending[key]
	// Ordinary readers join an explicit refresh instead of accepting older facts.
	if !refresh && f == nil {
		if cached, ok := c.entries[key]; ok && time.Since(cached.at) < ttl {
			c.mu.Unlock()
			return cached.value, nil
		}
	}
	if f == nil || refresh && !f.refresh {
		if refresh {
			if cached, ok := c.entries[key]; ok {
				cached.at = time.Time{}
				c.entries[key] = cached
			}
		}
		shared, cancel := context.WithTimeout(context.WithoutCancel(ctx), timeout)
		f = &flight[T]{done: make(chan struct{}), cancel: cancel, refresh: refresh}
		c.pending[key] = f
		c.active[f] = true
		go func(f *flight[T]) {
			value, err := probe(shared)
			err = errors.Join(err, shared.Err())
			c.mu.Lock()
			var cleanup cleanupError
			if errors.As(err, &cleanup) {
				c.cleanupErr = errors.Join(c.cleanupErr, cleanup.error)
			}
			f.value, f.err = value, err
			// A replaced or abandoned flight may finish for its own readers, but
			// can never publish over a newer refresh (even if that refresh failed).
			if c.pending[key] == f {
				delete(c.pending, key)
				if err == nil && !c.closed {
					c.entries[key] = entry[T]{value, time.Now()}
					if len(c.entries) > 64 {
						oldest := key
						for candidate, entry := range c.entries {
							if entry.at.Before(c.entries[oldest].at) {
								oldest = candidate
							}
						}
						delete(c.entries, oldest)
					}
				}
			}
			delete(c.active, f)
			close(f.done)
			c.mu.Unlock()
			cancel()
		}(f)
	}
	f.readers++
	c.mu.Unlock()
	defer func() {
		c.mu.Lock()
		defer c.mu.Unlock()
		f.readers--
		if f.readers == 0 && c.active[f] {
			f.cancel()
			if c.pending[key] == f {
				delete(c.pending, key)
			}
		}
	}()
	select {
	case <-ctx.Done():
		return zero, ctx.Err()
	case <-f.done:
		if err := ctx.Err(); err != nil {
			return zero, err
		}
		return f.value, f.err
	}
}

// Close seals admission and drains every owned probe, including superseded ones.
func (c *Cache[T]) Close() error {
	c.mu.Lock()
	c.closed = true
	active := make([]*flight[T], 0, len(c.active))
	for f := range c.active {
		f.cancel()
		active = append(active, f)
	}
	c.mu.Unlock()
	for _, f := range active {
		<-f.done
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.cleanupErr
}
