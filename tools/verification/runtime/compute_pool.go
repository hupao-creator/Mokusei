package main

import (
	"context"
	"errors"
	"fmt"
	"sync/atomic"
	"time"

	"github.com/hupao-creator/Mokusei/internal/platform/workpool"
)

func verifyComputePool(ctx context.Context) {
	p := workpool.New(ctx, 4, 8, 8)
	defer p.Close(context.Background())
	gate := make(chan struct{})
	defer func() {
		select {
		case <-gate:
		default:
			close(gate)
		}
	}()
	entered := make(chan struct{}, 8)
	var active, peak atomic.Int64
	task := func(ctx context.Context) error {
		n := active.Add(1)
		for old := peak.Load(); n > old && !peak.CompareAndSwap(old, n); old = peak.Load() {
		}
		defer active.Add(-1)
		entered <- struct{}{}
		<-gate
		return nil
	}
	batch, cancel := context.WithCancel(ctx)
	defer cancel()
	done := make(chan error, 1)
	go func() {
		tasks := make([]workpool.Task, 6)
		for i := range tasks {
			tasks[i] = workpool.Task{Bytes: 4, Run: task}
		}
		done <- p.Run(batch, tasks, 4)
	}()
	waitPoolSignal(ctx, entered)
	waitPoolSignal(ctx, entered)
	select {
	case <-entered:
		panic("byte budget admitted a third 4-byte task into 8-byte capacity")
	case <-time.After(30 * time.Millisecond):
	}
	cancel()
	select {
	case <-done:
		panic("Run returned before joining accepted cancellation-resistant work")
	case <-time.After(30 * time.Millisecond):
	}
	close(gate)
	if err := <-done; !errors.Is(err, context.Canceled) {
		panic("pool did not report batch cancellation")
	}
	if peak.Load() != 2 || active.Load() != 0 {
		panic("pool byte admission or join bound violated")
	}
	err := p.Run(ctx, []workpool.Task{{Bytes: 9, Run: task}}, 1)
	if !errors.Is(err, workpool.ErrTooLarge) {
		panic("oversized compute input was admitted")
	}
	if err = p.Run(ctx, []workpool.Task{{Bytes: 8, Run: func(context.Context) error { panic("fixture") }}}, 1); err == nil {
		panic("compute panic escaped containment")
	}
	must(p.Run(ctx, []workpool.Task{{Bytes: 8, Run: func(context.Context) error { return nil }}}, 1))
	held := make(chan struct{})
	defer func() {
		select {
		case <-held:
		default:
			close(held)
		}
	}()
	go func() {
		done <- p.Run(ctx, []workpool.Task{{Bytes: 8, Run: func(context.Context) error { entered <- struct{}{}; <-held; return nil }}}, 1)
	}()
	waitPoolSignal(ctx, entered)
	timeout, stop := context.WithTimeout(ctx, 30*time.Millisecond)
	err = p.Close(timeout)
	stop()
	if !errors.Is(err, context.DeadlineExceeded) {
		panic("pool close did not wait for running task")
	}
	close(held)
	<-done
	must(p.Close(ctx))
	if err = p.Run(ctx, []workpool.Task{{Run: func(context.Context) error { return nil }}}, 1); !errors.Is(err, workpool.ErrClosed) {
		panic("closed pool admitted new work")
	}
	fmt.Println("PASS compute byte admission, cancellation joins, panic recovery, deadline-aware repeated close and closed admission")
}
func waitPoolSignal(ctx context.Context, ch <-chan struct{}) {
	select {
	case <-ch:
	case <-ctx.Done():
		panic(ctx.Err())
	case <-time.After(3 * time.Second):
		panic("compute fixture did not enter")
	}
}
