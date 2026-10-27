package threadsearch

import (
	"context"
	"sync"
)

// A waiting interactive query gets the next slot. Already running inference is
// allowed to finish; cancellation never leaves a waiter reserving that slot.
type inferenceGate struct {
	mu      sync.Mutex
	busy    bool
	queries int
	changed chan struct{}
}

func (g *inferenceGate) signal() {
	if g.changed != nil {
		close(g.changed)
	}
	g.changed = make(chan struct{})
}

func (g *inferenceGate) acquire(ctx context.Context, query bool) error {
	g.mu.Lock()
	if g.changed == nil {
		g.changed = make(chan struct{})
	}
	if query {
		g.queries++
	}
	for {
		if err := ctx.Err(); err != nil {
			if query {
				g.queries--
				g.signal()
			}
			g.mu.Unlock()
			return err
		}
		if !g.busy && (query || g.queries == 0) {
			g.busy = true
			if query {
				g.queries--
			}
			g.mu.Unlock()
			return nil
		}
		changed := g.changed
		g.mu.Unlock()
		select {
		case <-ctx.Done():
		case <-changed:
		}
		g.mu.Lock()
	}
}

func (g *inferenceGate) release() {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.busy = false
	g.signal()
}
