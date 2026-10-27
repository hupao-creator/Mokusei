package plugin

import (
	"context"
	"errors"
	"sync"
	"sync/atomic"
)

// ErrPromptSettled means input must be retried in a fresh completion.
var ErrPromptSettled = errors.New("isolated completion has settled")

// PromptSteering is a single-completion mailbox. Native adapters publish only
// after initial admission and end it at the native terminal boundary. End must
// not wait for a native request: wire readers may be delivering that request's
// acknowledgement. Callers serialize Send and wait for it before disposing the
// native session.
type PromptSteering struct {
	ready chan struct{}
	done  chan struct{}
	once  sync.Once
	end   sync.Once
	ended atomic.Bool
	send  sync.Mutex
	steer func(context.Context, string) error
}

func NewPromptSteering() *PromptSteering {
	return &PromptSteering{ready: make(chan struct{}), done: make(chan struct{})}
}

func (s *PromptSteering) Bind(steer func(context.Context, string) error) {
	if s == nil {
		return
	}
	s.once.Do(func() { s.steer = steer; close(s.ready) })
}
func (s *PromptSteering) End() {
	if s == nil {
		return
	}
	s.end.Do(func() { s.ended.Store(true); close(s.done) })
}
func (s *PromptSteering) Send(ctx context.Context, text string) error {
	s.send.Lock()
	defer s.send.Unlock()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-s.done:
		return ErrPromptSettled
	case <-s.ready:
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	if s.ended.Load() {
		return ErrPromptSettled
	}
	if err := s.steer(ctx, text); err != nil {
		return err
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	// Conservatively replay input if settlement crossed its admission boundary.
	if s.ended.Load() {
		return ErrPromptSettled
	}
	return nil
}

// Drain fences native disposal against an in-flight steer request.
func (s *PromptSteering) Drain() {
	if s == nil {
		return
	}
	s.End()
	s.send.Lock()
	s.send.Unlock()
}
