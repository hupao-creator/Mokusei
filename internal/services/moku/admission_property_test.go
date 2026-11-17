package moku

import (
	"context"
	"errors"
	"sync/atomic"
	"testing"
	"time"

	"github.com/hupao-creator/Mokusei/tools/verification/pbt/rapidcheck"
	"pgregory.net/rapid"
)

// PBT-MOKU-QUEUE: README.md. A held owner is a barrier, so cancellation is
// observed without relying on sleeps or assuming a FIFO goroutine scheduler.
func TestAdmissionQueueProperties(t *testing.T) {
	rapidcheck.Check(t, func(t *rapid.T) {
		var q admissionQueue
		var inside atomic.Int32
		cohorts := rapid.IntRange(1, 8).Draw(t, "cohorts")
		for range cohorts {
			cancelled := rapid.SliceOfN(rapid.Bool(), 1, 12).Draw(t, "cancelled-waiters")
			ctx, stop := context.WithTimeout(context.Background(), 3*time.Second)
			if err := q.Lock(ctx); err != nil {
				stop()
				t.Fatal(err)
			}
			type result struct {
				id      int
				err     error
				overlap bool
			}
			results := make(chan result, len(cancelled))
			cancels := make([]context.CancelFunc, len(cancelled))
			for id := range cancelled {
				waiter, cancel := context.WithCancel(ctx)
				cancels[id] = cancel
				go func() {
					err := q.Lock(waiter)
					overlap := false
					if err == nil {
						overlap = inside.Add(1) != 1
						inside.Add(-1)
						q.Unlock()
					}
					results <- result{id, err, overlap}
				}()
			}
			count := 0
			for id, cancel := range cancels {
				if cancelled[id] {
					count++
					cancel()
				}
			}
			seen := map[int]bool{}
			for range count {
				select {
				case result := <-results:
					if seen[result.id] || !cancelled[result.id] || !errors.Is(result.err, context.Canceled) {
						q.Unlock()
						stop()
						t.Fatal("cancelled waiter entered or lost cancellation")
					}
					seen[result.id] = true
				case <-ctx.Done():
					q.Unlock()
					stop()
					t.Fatal("cancelled waiter retained claim behind held owner")
				}
			}
			q.Unlock()
			for range len(cancelled) - count {
				select {
				case result := <-results:
					if seen[result.id] || cancelled[result.id] || result.err != nil || result.overlap {
						stop()
						t.Fatal("queue lost exclusive surviving admission")
					}
					seen[result.id] = true
				case <-ctx.Done():
					stop()
					t.Fatal("released queue failed to drain")
				}
			}
			for _, cancel := range cancels {
				cancel()
			}
			stop()
		}
	})
}
