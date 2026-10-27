package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

func runRelayQueueCancellationReplay() (err error) {
	root, err := os.MkdirTemp("", "mokusei-relay-queue-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(root)
	system := startVoiceReplay(root, "mock", &voiceReplayFactory{})
	defer func() { err = errors.Join(err, system.close()) }()
	media, err := system.prepare(voiceReplayRequestID)
	if err != nil {
		return err
	}
	ownerEntered, ownerRelease, ownerCancelled := make(chan struct{}), make(chan struct{}), make(chan struct{})
	var releaseOnce sync.Once
	releaseOwner := func() { releaseOnce.Do(func() { close(ownerRelease) }) }
	defer releaseOwner()
	system.h.mu.Lock()
	system.h.gateAdmission = func(ctx context.Context) error {
		close(ownerEntered)
		select {
		case <-ownerRelease:
			return nil
		case <-ctx.Done():
			close(ownerCancelled)
			return ctx.Err()
		}
	}
	system.h.mu.Unlock()
	media.delegate(plugin.VoiceDelegation{ID: "relay-owner", Text: "admitting relay work survives", Generation: 0})
	mokuReplayAwait("relay owner inside native admission", ownerEntered)
	const waiters = 8
	for index := range waiters {
		media.delegate(plugin.VoiceDelegation{ID: fmt.Sprintf("relay-waiter-%d", index), Text: fmt.Sprintf("abandoned relay request %d", index), Generation: int64(index + 1)})
	}
	if err := awaitRelayQueueWorkers(waiters, 5*time.Second); err != nil {
		return err
	}
	if _, err := system.command("moku:voice", map[string]any{"action": "stop", "sessionId": media.ID()}); err != nil {
		return err
	}
	// The first request remains deliberately held. All unadmitted workers must
	// disappear before it can advance; a stop-only flag checked later fails here.
	if err := awaitRelayQueueWorkers(0, 250*time.Millisecond); err != nil {
		return err
	}
	select {
	case <-ownerCancelled:
		return errors.New("ending media cancelled the service-owned relay admission")
	default:
	}
	releaseOwner()
	system.h.awaitTools(1)
	record := system.record()
	if !voiceReplayHasMessage(record, "admitting relay work survives") {
		return errors.New("relay owner did not commit after media stopped")
	}
	for index := range waiters {
		if voiceReplayHasMessage(record, fmt.Sprintf("abandoned relay request %d", index)) {
			return errors.New("retired relay waiter was admitted")
		}
	}
	fmt.Println("PASS media shutdown releases already-waiting relay workers while service-owned admission survives")
	return nil
}

func awaitRelayQueueWorkers(want int, timeout time.Duration) error {
	deadline := time.NewTimer(timeout)
	defer deadline.Stop()
	tick := time.NewTicker(time.Millisecond)
	defer tick.Stop()
	for {
		stacks, err := mokuQueueStacks()
		if err != nil {
			return err
		}
		count, workers := 0, 0
		for _, stack := range stacks {
			if !strings.Contains(stack, "moku.(*voiceController).delegate(") {
				continue
			}
			workers++
			header, _, _ := strings.Cut(stack, "\n")
			if strings.Contains(stack, "moku.takeVoiceQueue(") &&
				(want == 0 || strings.Contains(header, "[select")) {
				count++
			}
		}
		if count == want && workers == want+1 {
			return nil
		}
		select {
		case <-mokuReplayContext().Done():
			return mokuReplayContext().Err()
		case <-deadline.C:
			return fmt.Errorf("relay admission has %d waiters and %d workers, want %d waiters and one owner", count, workers, want)
		case <-tick.C:
		}
	}
}
