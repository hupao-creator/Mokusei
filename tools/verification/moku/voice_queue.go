package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"sync"
	"time"
)

func runQueuedVoiceCancellationReplay() error {
	for _, measure := range []func() (mokuQueueSample, error){measurePreCancelledVoiceCancellation, measureQueuedVoiceCancellation} {
		sample, err := measure()
		if err != nil {
			return err
		}
		if !sample.ReleasedBeforeOwner {
			return fmt.Errorf("%s: stopped voice preparation retained the command queue while waiting for typed admission", sample.Case)
		}
	}
	fmt.Println("PASS voice preparation and stop-before-ID release while typed admission still owns the Moku queue")
	return nil
}

func measureQueuedVoiceCancellation() (sample mokuQueueSample, err error) {
	return measureVoiceCancellation(true)
}

func measurePreCancelledVoiceCancellation() (sample mokuQueueSample, err error) {
	return measureVoiceCancellation(false)
}

func prepareQueueWaiter(system *voiceReplaySystem, done chan<- error) {
	_, err := system.command("moku:voice", map[string]any{
		"action": "prepare", "requestId": voiceReplayRejectedInputID, "takeover": voiceReplayRequestID,
	})
	done <- err
}

// The media teardown signals that prepare owns the voice command gate. The
// pre-cancel case holds it until stop; the queued case releases it and observes
// the still-live preparation waiting before issuing stop.
func measureVoiceCancellation(queued bool) (sample mokuQueueSample, err error) {
	const observationWindow = 250 * time.Millisecond
	sample = mokuQueueSample{Case: "voice-prepare-precancel", ObservationWindowNS: int64(observationWindow)}
	if queued {
		sample.Case = "voice-prepare-queued-cancel"
	}
	root, err := os.MkdirTemp("", "mokusei-moku-voice-queue-")
	if err != nil {
		return sample, err
	}
	defer os.RemoveAll(root)
	mediaRelease := make(chan struct{})
	ownerRelease := make(chan struct{})
	var mediaOnce, ownerOnce sync.Once
	releaseMedia := func() { mediaOnce.Do(func() { close(mediaRelease) }) }
	releaseOwner := func() { ownerOnce.Do(func() { close(ownerRelease) }) }
	factory := &voiceReplayFactory{stopRelease: mediaRelease}
	system := startVoiceReplay(root, "codex", factory)
	defer func() { err = errors.Join(err, system.close()) }()
	defer releaseOwner()
	defer releaseMedia()
	media, err := system.prepare(voiceReplayRequestID)
	if err != nil {
		return sample, err
	}
	ownerEntered := make(chan struct{})
	system.h.mu.Lock()
	system.h.gateAdmission = func(ctx context.Context) error {
		close(ownerEntered)
		select {
		case <-ownerRelease:
			return nil
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	system.h.mu.Unlock()
	ownerDone := make(chan error, 1)
	go func() {
		ownerDone <- system.c.Submit(mokuReplayContext(), mokuReplayText("typed owner survives queued voice cancellation"))
	}()
	mokuReplayAwait("typed admission owns Moku queue", ownerEntered)
	preparing := make(chan error, 1)
	go prepareQueueWaiter(system, preparing)
	mokuReplayAwait("takeover preparation owns voice commands", media.stopStarted)
	stopRequest := []json.RawMessage{mokuReplayRaw(map[string]any{
		"action": "stop", "sessionId": voiceReplayRejectedInputID, "ownershipId": voiceReplayRejectedInputID,
	})}
	var started time.Time
	if queued {
		releaseMedia()
		sample.QueueWaitState, err = awaitMokuQueueWait("prepareQueueWaiter", preparing)
		if err != nil {
			return sample, err
		}
	} else {
		// This stop cancels before the Moku queue is reached. Its deadline only
		// releases the caller; the preparation stays cancelled.
		const mediaHold = 100 * time.Millisecond
		sample.MediaHoldWindowNS = int64(mediaHold)
		stopCtx, cancelStop := context.WithTimeout(mokuReplayContext(), mediaHold)
		started = time.Now()
		_, stopErr := system.c.Invoke(stopCtx, "moku:voice", stopRequest)
		cancelStop()
		if !errors.Is(stopErr, context.DeadlineExceeded) {
			return sample, fmt.Errorf("stop did not wait for controlled media teardown: %v", stopErr)
		}
	}
	if started.IsZero() {
		started = time.Now()
	}
	releaseMedia()
	stopping := make(chan error, 1)
	go func() {
		_, stopErr := system.c.Invoke(mokuReplayContext(), "moku:voice", stopRequest)
		stopping <- stopErr
	}()
	prepareResult, stopResult := (<-chan error)(preparing), (<-chan error)(stopping)
	var prepareErr, finalStopErr error
	timer := time.NewTimer(observationWindow)
	for prepareResult != nil || stopResult != nil {
		select {
		case prepareErr = <-prepareResult:
			prepareResult = nil
		case finalStopErr = <-stopResult:
			stopResult = nil
		case <-timer.C:
			goto observed
		case <-mokuReplayContext().Done():
			timer.Stop()
			return sample, mokuReplayContext().Err()
		}
	}
observed:
	timer.Stop()
	sample.ReleasedBeforeOwner = prepareResult == nil && stopResult == nil
	// The baseline has an uncancellable mutex. Release it in either version so
	// measurement mode reports the difference instead of hanging on old code.
	releaseOwner()
	if prepareResult != nil {
		select {
		case prepareErr = <-prepareResult:
		case <-mokuReplayContext().Done():
			return sample, mokuReplayContext().Err()
		}
	}
	if stopResult != nil {
		select {
		case finalStopErr = <-stopResult:
		case <-mokuReplayContext().Done():
			return sample, mokuReplayContext().Err()
		}
	}
	sample.CancelLatencyNS = time.Since(started).Nanoseconds()
	if !errors.Is(prepareErr, context.Canceled) {
		return sample, fmt.Errorf("stopped preparation did not return cancellation: %v", prepareErr)
	}
	if finalStopErr != nil {
		return sample, fmt.Errorf("stop after preparation cancellation: %w", finalStopErr)
	}
	mokuReplayWaitError("typed admission after queued voice cancellation", ownerDone)
	factory.mu.Lock()
	nativeCalls := factory.nativeCalls
	factory.mu.Unlock()
	if nativeCalls != 1 {
		return sample, fmt.Errorf("cancelled queued preparation reached native voice: %d preparations", nativeCalls)
	}
	return sample, nil
}
