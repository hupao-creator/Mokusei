package main

import (
	"context"
	"errors"
	"fmt"
	"runtime"
	"strings"
	"sync"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/services/moku"
)

type mokuQueueSample struct {
	Case                string `json:"case"`
	ReleasedBeforeOwner bool   `json:"releasedBeforeOwner"`
	CancelLatencyNS     int64  `json:"cancelLatencyNs"`
	ObservationWindowNS int64  `json:"observationWindowNs"`
	QueueWaitState      string `json:"queueWaitState,omitempty"`
	MediaHoldWindowNS   int64  `json:"mediaHoldWindowNs,omitempty"`
}

// Named callers let the integration fixture identify its own waiter without a
// production hook. The stack is observed before cancellation and outside timing.
func submitQueueWaiter(ctx context.Context, c *moku.Coordinator, done chan<- error) {
	done <- c.Submit(ctx, orchestratorInput("cancelled queued request"))
}

func mokuQueueStacks() ([]string, error) {
	for size := 64 * 1024; size <= 8*1024*1024; size *= 2 {
		buffer := make([]byte, size)
		if n := runtime.Stack(buffer, true); n < len(buffer) {
			return strings.Split(string(buffer[:n]), "\n\n"), nil
		}
	}
	return nil, errors.New("queue witness exceeded its goroutine snapshot budget")
}

func awaitMokuQueueWait(caller string, result <-chan error) (string, error) {
	deadline := time.NewTimer(10 * time.Second)
	defer deadline.Stop()
	tick := time.NewTicker(time.Millisecond)
	defer tick.Stop()
	for {
		stacks, err := mokuQueueStacks()
		if err != nil {
			return "", err
		}
		for _, stack := range stacks {
			if !strings.Contains(stack, "main."+caller+"(") {
				continue
			}
			header, _, _ := strings.Cut(stack, "\n")
			var boundary string
			for _, frame := range strings.Split(stack, "\n") {
				if strings.HasPrefix(frame, "github.com/hupao-creator/Mokusei/internal/services/moku.") {
					boundary = frame
					break
				}
			}
			if strings.Contains(header, "[select") && strings.Contains(boundary, "moku.(*admissionQueue).Lock(") {
				return "select", nil
			}
			// The historical implementation waits in a mutex directly inside
			// submit/voice.command. Also recognize a precheck-only broken gate
			// for the negative-control run.
			if strings.Contains(header, "[sync.Mutex.Lock") &&
				(strings.Contains(boundary, "moku.(*admissionQueue).Lock(") || strings.Contains(boundary, "moku.(*Coordinator).submit(") || strings.Contains(boundary, "moku.(*voiceController).command(")) {
				return "sync.Mutex.Lock", nil
			}
		}
		select {
		case err := <-result:
			return "", fmt.Errorf("live waiter returned before reaching the occupied queue: %v", err)
		case <-deadline.C:
			return "", fmt.Errorf("did not observe %s blocked in the Moku queue", caller)
		case <-mokuReplayContext().Done():
			return "", mokuReplayContext().Err()
		case <-tick.C:
		}
	}
}

func measureQueuedSubmitCancellation() (mokuQueueSample, error) {
	return measureSubmitCancellation(true)
}

func measurePreCancelledSubmitCancellation() (mokuQueueSample, error) {
	return measureSubmitCancellation(false)
}

// This also runs on the previous implementation: the observation deadline
// records its blocked waiter, then releases the owner before joining workers.
func measureSubmitCancellation(queued bool) (sample mokuQueueSample, err error) {
	w := newOrchestratorWorld()
	c := startOrchestrator(w)
	defer stopOrchestrator(c)
	mokuReplayMust(c.Submit(mokuReplayContext(), orchestratorInput("initialize queue fixture")))
	ownerEntered, ownerRelease := make(chan struct{}), make(chan struct{})
	var releaseOnce sync.Once
	releaseOwner := func() { releaseOnce.Do(func() { close(ownerRelease) }) }
	defer releaseOwner()
	w.mu.Lock()
	w.beforeSend = func(ctx context.Context) error {
		close(ownerEntered)
		select {
		case <-ownerRelease:
			return nil
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	w.mu.Unlock()
	ownerDone := make(chan error, 1)
	go func() {
		ownerDone <- c.Submit(mokuReplayContext(), orchestratorInput("queue owner survives waiter cancellation"))
	}()
	mokuReplayAwait("queue owner entered native Send", ownerEntered)

	canonicalEntered, canonicalRelease, canonicalFinished := make(chan struct{}), make(chan struct{}), make(chan struct{})
	var canonicalOnce sync.Once
	releaseCanonical := func() { canonicalOnce.Do(func() { close(canonicalRelease) }) }
	defer releaseCanonical()
	w.mu.Lock()
	w.canonicalizeFn = func(_ context.Context, input model.AgentInput) (model.AgentInput, error) {
		close(canonicalEntered)
		<-canonicalRelease
		close(canonicalFinished)
		return input, nil
	}
	w.mu.Unlock()
	waiterContext, cancelWaiter := context.WithCancel(mokuReplayContext())
	defer cancelWaiter()
	waiterDone := make(chan error, 1)
	go submitQueueWaiter(waiterContext, c, waiterDone)
	mokuReplayAwait("waiter reached queue boundary", canonicalEntered)
	const observation = 250 * time.Millisecond
	sample = mokuQueueSample{Case: "submit-precancel", ObservationWindowNS: int64(observation)}
	if queued {
		sample.Case = "submit-queued-cancel"
		releaseCanonical()
		mokuReplayAwait("live waiter finished canonicalization", canonicalFinished)
		sample.QueueWaitState, err = awaitMokuQueueWait("submitQueueWaiter", waiterDone)
		if err != nil {
			return sample, err
		}
	}
	started := time.Now()
	cancelWaiter()
	if !queued {
		// The adapter may finish just as cancellation arrives. Cancellation
		// must still be observed while acquiring the subsequent gate.
		releaseCanonical()
	}
	var waiterErr error
	select {
	case waiterErr = <-waiterDone:
		sample.ReleasedBeforeOwner = true
		sample.CancelLatencyNS = time.Since(started).Nanoseconds()
	case <-time.After(observation):
	}
	releaseOwner()
	mokuReplayWaitError("queue owner admission", ownerDone)
	if !sample.ReleasedBeforeOwner {
		select {
		case waiterErr = <-waiterDone:
			sample.CancelLatencyNS = time.Since(started).Nanoseconds()
		case <-mokuReplayContext().Done():
			return sample, mokuReplayContext().Err()
		case <-time.After(time.Second):
			return sample, errors.New("cancelled queue waiter remained blocked after owner release")
		}
	}
	if !errors.Is(waiterErr, context.Canceled) {
		return sample, fmt.Errorf("queue waiter cancellation changed result: %v", waiterErr)
	}
	w.mu.Lock()
	sends := len(w.sends)
	w.mu.Unlock()
	if sends != 2 {
		return sample, fmt.Errorf("cancelled waiter reached native Send: got %d admissions, want 2", sends)
	}
	return sample, nil
}

func runQueuedAdmissionReplay() error {
	for _, measure := range []func() (mokuQueueSample, error){measurePreCancelledSubmitCancellation, measureQueuedSubmitCancellation} {
		sample, err := measure()
		if err != nil {
			return err
		}
		if !sample.ReleasedBeforeOwner {
			return fmt.Errorf("%s: cancelled Moku submission waited for an unrelated native Send", sample.Case)
		}
	}
	fmt.Println("PASS Moku queue cancellation before and during waiting releases the waiter and preserves native owner admission")
	return nil
}
