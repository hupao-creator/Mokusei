package transport

import (
	"context"
	"sync"
)

// Each worker reserves one maximum-size raw resource slot before calling Host.
// At most 2 * contentWriteLimit raw bytes can enter decode concurrently. This
// is separate from Host allocations, decoded baselines and client event queues.
const contentWorkers = 2

type contentJob struct {
	clientID     string
	subscription *contentSubscription
}

func (c *contentServer) dirtyLocked(clientID string, subscription *contentSubscription) {
	subscription.dirty = true
	if subscription.working || subscription.queued {
		return
	}
	subscription.queued = true
	c.ready = append(c.ready, contentJob{clientID, subscription})
}
func (c *contentServer) removeQueuedLocked(subscription *contentSubscription) {
	ready := c.ready[:0]
	for _, job := range c.ready {
		if job.subscription != subscription {
			ready = append(ready, job)
		}
	}
	clear(c.ready[len(ready):])
	c.ready = ready
	subscription.queued = false
}
func (c *contentServer) signal() {
	select {
	case c.wake <- struct{}{}:
	default:
	}
}
func (c *contentServer) run() {
	jobs := make(chan contentJob)
	var workers sync.WaitGroup
	for i := 0; i < contentWorkers; i++ {
		workers.Add(1)
		go func() {
			defer workers.Done()
			for job := range jobs {
				if job.subscription.ctx.Err() == nil {
					c.publishOne(job.clientID, job.subscription)
				}
				c.mu.Lock()
				sub := job.subscription
				sub.working = false
				if !c.closed && c.clients[job.clientID][sub.id] == sub && sub.dirty {
					c.dirtyLocked(job.clientID, sub)
				}
				c.mu.Unlock()
				c.signal()
			}
		}()
	}
	defer func() { close(jobs); workers.Wait(); close(c.done) }()
	for {
		if c.ctx.Err() != nil {
			return
		}
		c.mu.Lock()
		var job contentJob
		for len(c.ready) > 0 {
			job = c.ready[0]
			c.ready[0] = contentJob{}
			c.ready = c.ready[1:]
			sub := job.subscription
			sub.queued = false
			if c.clients[job.clientID][sub.id] == sub && sub.ctx.Err() == nil {
				sub.working = true
				sub.dirty = false
				break
			}
			job = contentJob{}
		}
		c.mu.Unlock()
		if job.subscription == nil {
			select {
			case <-c.ctx.Done():
				return
			case <-c.wake:
			}
			continue
		}
		select {
		case jobs <- job:
		case <-c.ctx.Done():
			return
		}
	}
}
func (c *contentServer) wait(ctx context.Context) error {
	select {
	case <-c.done:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}
