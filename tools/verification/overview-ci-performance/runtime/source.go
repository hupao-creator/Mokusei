package main

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"time"
)

const sourceProtocolVersion = 2
const sourceQueueCapacity = 256

type sourceInstant struct {
	UnixNano    int64 `json:"unixNano"`
	ElapsedNano int64 `json:"elapsedNanoseconds"`
}

func sourceNow(origin time.Time) sourceInstant {
	now := time.Now()
	return sourceInstant{UnixNano: now.UnixNano(), ElapsedNano: now.Sub(origin).Nanoseconds()}
}

type sourceTask struct {
	Index    int
	Enqueued sourceInstant
	Dequeued sourceInstant
}

type sourceOverflow struct {
	Index int           `json:"index"`
	At    sourceInstant `json:"at"`
}

var errSourceQueueFull = errors.New("bounded source input queue overflow")

// Only queue bookkeeping holds this lock. Production reduction, Store.Update,
// publication and report encoding never prevent the producer from taking it.
type sourceQueue struct {
	mu             sync.Mutex
	origin         time.Time
	items          []sourceTask
	head, count    int
	highWater      int
	closed         bool
	inFlight       *sourceTask
	maxPendingWait int64
	overflows      []sourceOverflow
	ready          chan struct{}
}

func newSourceQueue(origin time.Time, capacity int) *sourceQueue {
	return &sourceQueue{origin: origin, items: make([]sourceTask, capacity), ready: make(chan struct{}, 1), overflows: []sourceOverflow{}}
}

func (q *sourceQueue) notify() {
	select {
	case q.ready <- struct{}{}:
	default:
	}
}

func (q *sourceQueue) enqueue(index int) (sourceTask, error) {
	q.mu.Lock()
	if q.closed {
		q.mu.Unlock()
		return sourceTask{}, errors.New("source input queue is closed")
	}
	if q.count == len(q.items) {
		q.overflows = append(q.overflows, sourceOverflow{Index: index, At: sourceNow(q.origin)})
		q.mu.Unlock()
		return sourceTask{}, errSourceQueueFull
	}
	position := (q.head + q.count) % len(q.items)
	q.items[position] = sourceTask{Index: index}
	q.count++
	// This is the actual insertion point, after the preallocated slot is written,
	// while the consumer is excluded. It is never the planned wakeup timestamp.
	q.items[position].Enqueued = sourceNow(q.origin)
	task := q.items[position]
	q.highWater = max(q.highWater, q.count)
	q.mu.Unlock()
	q.notify()
	return task, nil
}

func (q *sourceQueue) take(ctx context.Context) (sourceTask, bool, error) {
	for {
		if err := ctx.Err(); err != nil {
			return sourceTask{}, false, err
		}
		q.mu.Lock()
		if q.count > 0 {
			task := q.items[q.head]
			q.items[q.head] = sourceTask{}
			q.head = (q.head + 1) % len(q.items)
			q.count--
			task.Dequeued = sourceNow(q.origin)
			q.maxPendingWait = max(q.maxPendingWait, task.Dequeued.ElapsedNano-task.Enqueued.ElapsedNano)
			q.inFlight = &task
			q.mu.Unlock()
			return task, true, nil
		}
		closed := q.closed
		q.mu.Unlock()
		if closed {
			return sourceTask{}, false, nil
		}
		select {
		case <-q.ready:
		case <-ctx.Done():
			return sourceTask{}, false, ctx.Err()
		}
	}
}

func (q *sourceQueue) complete(index int) {
	q.mu.Lock()
	defer q.mu.Unlock()
	if q.inFlight == nil || q.inFlight.Index != index {
		panic("source queue worker completed an unexpected index")
	}
	q.inFlight = nil
}

func (q *sourceQueue) close() {
	q.mu.Lock()
	q.closed = true
	q.mu.Unlock()
	q.notify()
}

func (q *sourceQueue) snapshot() map[string]any {
	q.mu.Lock()
	defer q.mu.Unlock()
	now := sourceNow(q.origin)
	indices := make([]int, q.count)
	for index := range indices {
		indices[index] = q.items[(q.head+index)%len(q.items)].Index
	}
	oldest, inFlightAge, inFlight, inFlightIndex := int64(0), int64(0), 0, -1
	if q.count > 0 {
		oldest = now.ElapsedNano - q.items[q.head].Enqueued.ElapsedNano
	}
	if q.inFlight != nil {
		inFlight, inFlightIndex = 1, q.inFlight.Index
		inFlightAge = now.ElapsedNano - q.inFlight.Dequeued.ElapsedNano
	}
	return map[string]any{"meaning": "bounded benchmark input FIFO, not a production Store/transport/UI queue", "capacity": len(q.items),
		"observedAt": now, "pending": q.count, "pendingIndices": indices, "inFlight": inFlight, "inFlightIndex": inFlightIndex,
		"inFlightAgeMilliseconds": float64(inFlightAge) / 1e6, "oldestPendingAgeMilliseconds": float64(oldest) / 1e6,
		"highWater": q.highWater, "maxOldestPendingAgeMilliseconds": float64(max(q.maxPendingWait, oldest)) / 1e6,
		"closed": q.closed, "overflowCount": len(q.overflows), "overflows": append([]sourceOverflow{}, q.overflows...)}
}

// A full queue invalidates the experiment; it cannot block or silently reshape
// the independent source. Already admitted tasks remain available to the worker.
func produceSource(ctx context.Context, start time.Time, count int, interval time.Duration,
	queue *sourceQueue, observe func(int, sourceTask, error)) error {
	defer queue.close()
	for index := 0; index < count; index++ {
		if !waitUntil(ctx, start.Add(time.Duration(index)*interval)) {
			return ctx.Err()
		}
		if err := ctx.Err(); err != nil {
			return err
		}
		task, err := queue.enqueue(index)
		observe(index, task, err)
		if err != nil {
			return fmt.Errorf("source event %d: %w", index, err)
		}
	}
	return nil
}

// Receipts follow the operations that actually happened. A cancellation after
// dequeue is a failed completed task with no sent timestamp. Once commit returns
// success, a later context cancellation cannot erase the accepted mutation.
func executeSourceEvent(ctx context.Context, origin time.Time, event sourceEvent, prepare, commit func() error,
	observe func(sourceEvent)) (sourceEvent, error) {
	observe(event)
	err := ctx.Err()
	if err == nil {
		mark := sourceNow(origin)
		event.SentUnixNano, event.SentElapsedNanoseconds = mark.UnixNano, mark.ElapsedNano
		observe(event)
		err = prepare()
	}
	if err == nil {
		mark := sourceNow(origin)
		event.StoreUpdateStartedUnixNano, event.StoreUpdateStartedElapsedNanoseconds = mark.UnixNano, mark.ElapsedNano
		observe(event)
		err = commit()
	}
	if err == nil {
		mark := sourceNow(origin)
		event.AcceptedUnixNano, event.AcceptedElapsedNanoseconds = mark.UnixNano, mark.ElapsedNano
	} else {
		event.Error = err.Error()
	}
	mark := sourceNow(origin)
	event.CompletedUnixNano, event.CompletedElapsedNanoseconds = mark.UnixNano, mark.ElapsedNano
	observe(event)
	return event, err
}

func consumeSource(ctx context.Context, queue *sourceQueue, apply func(sourceTask) error) error {
	for {
		task, ok, err := queue.take(ctx)
		if err != nil || !ok {
			return err
		}
		err = apply(task)
		queue.complete(task.Index)
		if err != nil {
			return err
		}
	}
}
