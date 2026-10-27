package moku

import (
	"context"
	"sync"
)

// admissionQueue keeps native preparation and acknowledgement serial while
// letting cancelled waiters release their input claims before the owner exits.
// Its zero value is ready for use, including coordinators assembled by fixtures.
type admissionQueue struct {
	once sync.Once
	gate chan struct{}
}

func (q *admissionQueue) Lock(ctx context.Context) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	q.once.Do(func() { q.gate = make(chan struct{}, 1) })
	select {
	case q.gate <- struct{}{}:
		if err := ctx.Err(); err != nil {
			<-q.gate
			return err
		}
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (q *admissionQueue) Unlock() { <-q.gate }
