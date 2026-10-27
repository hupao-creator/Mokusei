// Package workpool runs bounded, cancellation-aware CPU work. Accepted tasks
// are joined before Run returns, so callers can safely own their output slices.
package workpool

import (
	"context"
	"errors"
	"fmt"
	"sync"
)

var ErrClosed = errors.New("compute pool is closed")
var ErrTooLarge = errors.New("compute input exceeds byte budget")

type Task struct {
	Bytes int64
	Run   func(context.Context) error
}
type job struct {
	ctx    context.Context
	task   Task
	result chan<- error
}
type Pool struct {
	ctx      context.Context
	cancel   context.CancelFunc
	mu       sync.RWMutex
	closed   bool
	stop     sync.Once
	jobs     chan job
	done     chan struct{}
	workers  int
	budget   int64
	budgetMu sync.Mutex
	used     int64
	changed  chan struct{}
}

func New(ctx context.Context, workers, queued int, bytes int64) *Pool {
	life, cancel := context.WithCancel(ctx)
	p := &Pool{ctx: life, cancel: cancel, jobs: make(chan job, max(0, queued)), done: make(chan struct{}), workers: max(1, workers), budget: max(1, bytes), changed: make(chan struct{})}
	var wg sync.WaitGroup
	for i := 0; i < p.workers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := range p.jobs {
				p.execute(j)
			}
		}()
	}
	go func() { wg.Wait(); close(p.done) }()
	context.AfterFunc(life, p.Stop)
	return p
}
func (p *Pool) Stop() {
	p.stop.Do(func() {
		p.cancel()
		p.mu.Lock()
		p.closed = true
		close(p.jobs)
		p.mu.Unlock()
	})
}
func (p *Pool) Close(ctx context.Context) error {
	p.Stop()
	select {
	case <-p.done:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}
func (p *Pool) reserve(ctx context.Context, n int64) error {
	if n < 0 || n > p.budget {
		return ErrTooLarge
	}
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		if p.ctx.Err() != nil {
			return ErrClosed
		}
		p.budgetMu.Lock()
		if p.used+n <= p.budget {
			p.used += n
			p.budgetMu.Unlock()
			return nil
		}
		changed := p.changed
		p.budgetMu.Unlock()
		select {
		case <-changed:
		case <-ctx.Done():
			return ctx.Err()
		case <-p.ctx.Done():
			return ErrClosed
		}
	}
}
func (p *Pool) release(n int64) {
	p.budgetMu.Lock()
	p.used -= n
	close(p.changed)
	p.changed = make(chan struct{})
	p.budgetMu.Unlock()
}
func (p *Pool) submit(ctx context.Context, task Task, result chan<- error) error {
	if err := p.reserve(ctx, task.Bytes); err != nil {
		return err
	}
	p.mu.RLock()
	defer p.mu.RUnlock()
	if p.closed {
		p.release(task.Bytes)
		return ErrClosed
	}
	select {
	case p.jobs <- job{ctx, task, result}:
		return nil
	case <-ctx.Done():
		p.release(task.Bytes)
		return ctx.Err()
	case <-p.ctx.Done():
		p.release(task.Bytes)
		return ErrClosed
	}
}
func (p *Pool) execute(j job) {
	var err error
	ctx, cancel := context.WithCancel(j.ctx)
	stop := context.AfterFunc(p.ctx, cancel)
	defer func() {
		if recover() != nil {
			err = fmt.Errorf("compute task panicked")
		}
		stop()
		cancel()
		p.release(j.task.Bytes)
		j.result <- err
	}()
	if p.ctx.Err() != nil {
		err = ErrClosed
		return
	}
	if err = ctx.Err(); err != nil {
		return
	}
	err = j.task.Run(ctx)
	if err == nil {
		err = ctx.Err()
	}
}

// Run bounds fanout for this batch as well as the pool-wide worker/byte limits.
// It cancels the batch on error and still joins every accepted task.
func (p *Pool) Run(ctx context.Context, tasks []Task, fanout int) error {
	if len(tasks) == 0 {
		return ctx.Err()
	}
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	limit := min(len(tasks), p.workers, max(1, fanout))
	results := make(chan error, limit)
	next, inFlight := 0, 0
	var failure error
	for next < len(tasks) || inFlight > 0 {
		for failure == nil && next < len(tasks) && inFlight < limit {
			if err := p.submit(ctx, tasks[next], results); err != nil {
				failure = err
				cancel()
				break
			}
			next++
			inFlight++
		}
		if inFlight == 0 {
			break
		}
		err := <-results
		inFlight--
		if err != nil && failure == nil {
			failure = err
			cancel()
		}
	}
	if failure != nil {
		return failure
	}
	return ctx.Err()
}
