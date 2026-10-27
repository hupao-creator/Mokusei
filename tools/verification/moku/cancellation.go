package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"

	"github.com/hupao-creator/Mokusei/internal/core/model"
)

func runFencedMokuCancellationReplay() error {
	root, err := os.MkdirTemp("", "mokusei-moku-cancel-")
	mokuReplayMust(err)
	defer os.RemoveAll(root)
	h := &replayNativeHarness{nativeModel: "fixture-model", wake: make(chan struct{}, 128)}
	s := startReplaySystem(root, h)
	defer s.close()
	entered := make(chan struct{})
	h.mu.Lock()
	h.gateSnapshot = func(ctx context.Context) error { close(entered); <-ctx.Done(); return ctx.Err() }
	h.mu.Unlock()
	done := make(chan error, 1)
	go func() { done <- s.c.Submit(mokuReplayContext(), mokuReplayText("cancel before native configuration")) }()
	mokuReplayAwait("configuration admission", entered)
	pending := s.record()
	mokuReplayCheck(pending.PendingInput && pending.CancellationID != "" && pending.Observation.LatestExecution == nil, "Moku preparation has no cancellation generation")
	cancel := func(observed model.ThreadRecord) model.CancellationResult {
		result, err := s.r.Invoke(mokuReplayContext(), "moku:cancel", []json.RawMessage{mokuReplayRaw(model.CancellationRequest{ThreadID: observed.ID, ExpectedCancellationID: observed.CancellationID})})
		mokuReplayMust(err)
		return result.(model.CancellationResult)
	}
	mokuReplayCheck(cancel(pending).Status == "cancelled", "Moku preparation was not cancelled")
	select {
	case err := <-done:
		mokuReplayCheck(err != nil, "cancelled Moku preparation succeeded")
	case <-mokuReplayContext().Done():
		return mokuReplayContext().Err()
	}
	mokuReplayMust(s.c.Submit(mokuReplayContext(), mokuReplayText("new execution survives old stop")))
	h.awaitTools(1)
	current := s.record()
	mokuReplayCheck(current.CancellationID != pending.CancellationID, "Moku successor reused admission identity")
	mokuReplayCheck(cancel(pending).Status == "stale", "old Moku cancel affected successor")
	mokuReplayCheck(s.record().Observation.LatestExecution.Status == "running", "Moku successor stopped")
	_, err = s.r.Invoke(mokuReplayContext(), "moku:cancel", nil)
	mokuReplayCheck(err != nil, "unfenced Moku public cancel remains available")
	mokuReplayCheck(cancel(current).Status == "cancelled", "Moku current cancellation failed")
	fmt.Println("PASS public Moku cancellation: visible pre-execution generation, preparation cancellation, stable execution identity and stale successor rejection")
	return nil
}
