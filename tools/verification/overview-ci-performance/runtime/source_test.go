package main

import (
	"context"
	"errors"
	"slices"
	"testing"
	"time"
)

func sourceTestRaw(t *testing.T) int64 {
	t.Helper()
	now, err := rawUptimeNanoseconds()
	if err != nil {
		t.Fatal(err)
	}
	return now
}

func sourceTestOrigin(t *testing.T) clockObservation {
	t.Helper()
	origin, err := observeClock()
	if err != nil {
		t.Fatal(err)
	}
	origin.UptimeNanoseconds -= int64(time.Second)
	origin.UnixNanoseconds -= int64(time.Second)
	return origin
}

func sourceTestSnapshot(t *testing.T, queue *sourceQueue) map[string]any {
	t.Helper()
	snapshot, err := queue.snapshot()
	if err != nil {
		t.Fatal(err)
	}
	return snapshot
}

func awaitSource[T any](t *testing.T, values <-chan T) T {
	t.Helper()
	select {
	case value := <-values:
		return value
	case <-time.After(5 * time.Second):
		t.Fatal("source test did not complete")
		var zero T
		return zero
	}
}

func taskEvent(task sourceTask) sourceEvent {
	return sourceEvent{Index: task.Index, EnqueuedUnixNano: task.Enqueued.UnixNano,
		EnqueuedElapsedNanoseconds: task.Enqueued.ElapsedNano, DequeuedUnixNano: task.Dequeued.UnixNano,
		DequeuedElapsedNanoseconds: task.Dequeued.ElapsedNano,
		EnqueuedUptimeNanoseconds:  task.Enqueued.UptimeNanoseconds, DequeuedUptimeNanoseconds: task.Dequeued.UptimeNanoseconds}
}

func TestSourceProducerContinuesWhileWorkerIsBlocked(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	q := newSourceQueue(sourceTestOrigin(t), 8)
	entered, release := make(chan struct{}), make(chan struct{})
	workerDone, producerDone := make(chan error, 1), make(chan error, 1)
	var received []int
	go func() {
		workerDone <- consumeSource(ctx, q, func(task sourceTask) error {
			received = append(received, task.Index)
			if task.Index == -1 {
				close(entered)
				select {
				case <-release:
				case <-ctx.Done():
					return ctx.Err()
				}
			}
			return nil
		})
	}()
	// Begin with a real worker task held inside production work. Future source
	// slots must still enter the queue without releasing that worker.
	if _, err := q.enqueue(-1); err != nil {
		t.Fatal(err)
	}
	awaitSource(t, entered)
	go func() {
		producerDone <- produceSource(ctx, sourceTestRaw(t), 4, time.Millisecond, q, func(index int, _ sourceTask, err error) {})
	}()
	if err := awaitSource(t, producerDone); err != nil {
		t.Fatal(err)
	}
	state := sourceTestSnapshot(t, q)
	if state["pending"] != 4 || state["inFlight"] != 1 || state["closed"] != true || state["overflowCount"] != 0 {
		t.Fatalf("producer was coupled to blocked worker: %#v", state)
	}
	close(release)
	if err := awaitSource(t, workerDone); err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(received, []int{-1, 0, 1, 2, 3}) {
		t.Fatalf("FIFO work changed: %v", received)
	}
}

func TestSourceFIFOExactOnceAndBoundedOverflow(t *testing.T) {
	q := newSourceQueue(sourceTestOrigin(t), 2)
	var attempted []int
	err := produceSource(context.Background(), sourceTestRaw(t)-int64(time.Second), 5, time.Millisecond, q,
		func(index int, _ sourceTask, _ error) { attempted = append(attempted, index) })
	if !errors.Is(err, errSourceQueueFull) || !slices.Equal(attempted, []int{0, 1, 2}) {
		t.Fatalf("overflow was not an explicit stopped producer: attempts=%v err=%v", attempted, err)
	}
	state := sourceTestSnapshot(t, q)
	if state["capacity"] != 2 || state["highWater"] != 2 || state["pending"] != 2 || state["overflowCount"] != 1 || state["closed"] != true {
		t.Fatalf("unexpected bounded queue receipt: %#v", state)
	}
	if overflows := state["overflows"].([]sourceOverflow); len(overflows) != 1 || overflows[0].Index != 2 || overflows[0].At.UnixNano == 0 {
		t.Fatalf("lost rejected index: %#v", overflows)
	}
	var received []int
	if err := consumeSource(context.Background(), q, func(task sourceTask) error {
		received = append(received, task.Index)
		if task.Dequeued.ElapsedNano < task.Enqueued.ElapsedNano {
			t.Fatal("dequeue preceded actual insertion")
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(received, []int{0, 1}) || sourceTestSnapshot(t, q)["pending"] != 0 || sourceTestSnapshot(t, q)["inFlight"] != 0 {
		t.Fatalf("admitted prefix was dropped, duplicated or reordered: %v / %#v", received, sourceTestSnapshot(t, q))
	}
}

func TestSourceCancellationUnblocksWaiters(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	q := newSourceQueue(sourceTestOrigin(t), 2)
	producerDone, workerDone := make(chan error, 1), make(chan error, 1)
	go func() {
		producerDone <- produceSource(ctx, sourceTestRaw(t)+int64(time.Hour), 1, time.Millisecond, q,
			func(_ int, _ sourceTask, _ error) { t.Error("cancelled future source tried to enqueue") })
	}()
	go func() {
		workerDone <- consumeSource(ctx, q, func(sourceTask) error { t.Error("empty source produced a worker mutation"); return nil })
	}()
	cancel()
	if err := awaitSource(t, producerDone); !errors.Is(err, context.Canceled) {
		t.Fatalf("producer: %v", err)
	}
	if err := awaitSource(t, workerDone); !errors.Is(err, context.Canceled) {
		t.Fatalf("consumer: %v", err)
	}
	if state := sourceTestSnapshot(t, q); state["closed"] != true || state["pending"] != 0 || state["inFlight"] != 0 {
		t.Fatalf("cancelled source retained unrecorded work: %#v", state)
	}
}

func TestSourceCancelledBeforeWarmupRecordsProducerFinished(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	b := &benchmark{ctx: ctx, origin: sourceTestOrigin(t), warmupReady: make(chan struct{}), errors: []string{}}
	b.inputQueue = newSourceQueue(b.origin, sourceQueueCapacity)
	b.workers.Add(1)
	done := make(chan struct{})
	go func() { b.produce(sourceTestRaw(t) + int64(time.Second)); close(done) }()
	awaitSource(t, done)
	b.workers.Wait()
	if !b.producerDone || b.enqueueDone || b.sourceDone || len(b.errors) != 1 || sourceTestSnapshot(t, b.inputQueue)["closed"] != true {
		t.Fatalf("pre-warmup cancellation lost lifecycle receipt: producer=%v enqueued=%v complete=%v errors=%v",
			b.producerDone, b.enqueueDone, b.sourceDone, b.errors)
	}
}

func TestSourceCancelledAfterDequeueKeepsTerminalReceipt(t *testing.T) {
	origin := sourceTestOrigin(t)
	q := newSourceQueue(origin, 2)
	if _, err := q.enqueue(0); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	task, ok, err := q.take(ctx)
	if err != nil || !ok {
		t.Fatal("source task was not dequeued", err)
	}
	cancel()
	var receipt sourceEvent
	_, err = executeSourceEvent(ctx, origin, taskEvent(task),
		func() error { t.Fatal("cancelled dequeued task started preparation"); return nil },
		func() error { t.Fatal("cancelled dequeued task started Store.Update"); return nil },
		func(value sourceEvent) { receipt = value })
	q.complete(task.Index)
	if !errors.Is(err, context.Canceled) || receipt.DequeuedUnixNano == 0 || receipt.CompletedUnixNano == 0 || receipt.Error == "" ||
		receipt.SentUnixNano != 0 || receipt.AcceptedUnixNano != 0 || receipt.StoreUpdateStartedUnixNano != 0 {
		t.Fatalf("cancelled task was lost or falsely sent/accepted: %#v / %v", receipt, err)
	}
	state := queueAt([]sourceEvent{receipt}, sourceTestRaw(t), origin.UptimeNanoseconds)
	if state["enqueued"] != 1 || state["dequeued"] != 1 || state["pending"] != 0 || state["inFlight"] != 0 || state["failed"] != 1 || state["outstanding"] != 1 {
		t.Fatalf("cancelled dequeued task broke conservation: %#v", state)
	}
}

func TestSourceSuccessfulCommitSurvivesConcurrentCancellation(t *testing.T) {
	origin := sourceTestOrigin(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	q := newSourceQueue(origin, 1)
	if _, err := q.enqueue(0); err != nil {
		t.Fatal(err)
	}
	task, ok, err := q.take(ctx)
	if err != nil || !ok {
		t.Fatal("missing source task", err)
	}
	event, err := executeSourceEvent(ctx, origin, taskEvent(task), func() error { return nil }, func() error {
		// Store.Update reports a definite successful commit even when its context
		// was cancelled after commit began. The harness must retain that success.
		cancel()
		return nil
	}, func(sourceEvent) {})
	q.complete(task.Index)
	if err != nil || !event.CommitSucceeded || event.AcceptedUptimeNanoseconds == 0 || event.CompletedUptimeNanoseconds < event.AcceptedUptimeNanoseconds || event.Error != "" ||
		event.StoreUpdateStartedElapsedNanoseconds < event.SentElapsedNanoseconds {
		t.Fatalf("successful committed work was relabelled cancelled: %#v / %v", event, err)
	}
	if got := queueAt([]sourceEvent{event}, sourceTestRaw(t), origin.UptimeNanoseconds); got["accepted"] != 1 || got["outstanding"] != 0 || got["failed"] != 0 {
		t.Fatalf("successful commit did not balance queue receipts: %#v", got)
	}
}
