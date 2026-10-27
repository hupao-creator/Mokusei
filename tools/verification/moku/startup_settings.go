package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"time"
)

func runStartupSettingsReplay() error {
	root, err := os.MkdirTemp("", "mokusei-startup-settings-")
	mokuReplayMust(err)
	defer os.RemoveAll(root)
	entered, release := make(chan struct{}), make(chan struct{})
	h := &replayNativeHarness{nativeModel: "startup-model", wake: make(chan struct{}, 128), gateSnapshot: func(ctx context.Context) error {
		close(entered)
		select {
		case <-release:
			return nil
		case <-ctx.Done():
			return ctx.Err()
		}
	}}
	s := startReplaySystem(root, h, "startup")
	defer s.close()
	mokuReplayAwait("startup native snapshot", entered)
	settings, revision, err := s.r.Settings()
	mokuReplayMust(err)
	settings.Moku.RoutingGuidance = mokuReplayString("routing guidance changed during startup discovery")
	saved := make(chan error, 1)
	go func() {
		result, err := s.r.UpdateSettings(mokuReplayContext(), revision, settings)
		if err == nil && result.Status != "saved" {
			err = errors.New("routing guidance save conflicted with startup discovery")
		}
		saved <- err
	}()
	select {
	case err := <-saved:
		mokuReplayMust(err)
	case <-time.After(time.Second):
		close(release)
		return errors.New("startup discovery blocked a routing guidance save")
	}
	updates, unsubscribe := s.db.Subscribe()
	defer unsubscribe()
	close(release)
	timer := time.NewTimer(5 * time.Second)
	defer timer.Stop()
	for {
		applied, err := s.r.ReadMokuConfiguration()
		mokuReplayMust(err)
		if !applied.Unapplied {
			mokuReplayCheck(applied.AppliedSettings.Moku.RoutingGuidance != nil &&
				*applied.AppliedSettings.Moku.RoutingGuidance == *settings.Moku.RoutingGuidance,
				"startup applied a configuration that lost the routing guidance edit")
			break
		}
		select {
		case <-updates:
		case <-timer.C:
			h.mu.Lock()
			failures := append([]string{}, h.errors...)
			h.mu.Unlock()
			current, revision, err := s.r.Settings()
			mokuReplayMust(err)
			return fmt.Errorf("startup did not apply its captured settings: revision=%d settings=%s failures=%v", revision, mokuReplayRaw(current), failures)
		}
	}
	h.mu.Lock()
	nativeSends := h.nativeSends
	h.mu.Unlock()
	mokuReplayCheck(nativeSends == 0, "startup settings preparation submitted a native task")
	fmt.Println("PASS startup native discovery allows routing guidance persistence, preserves the edit in applied configuration, and admits no task")
	return nil
}
