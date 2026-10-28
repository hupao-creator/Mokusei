// Command moku replays fixed coordinator and runtime scenarios without Node,
// installed native Harness CLIs, credentials, or a user's Mokusei profile.
package main

import (
	"context"
	"fmt"
	"os"
	"time"
)

var mokuReplayLifetime context.Context

func mokuReplayContext() context.Context { return mokuReplayLifetime }

func main() {
	if err := runMokuReplays(); err != nil {
		fmt.Fprintln(os.Stderr, "FAIL Moku replay:", err)
		os.Exit(1)
	}
}

func runMokuReplays() error {
	options, err := parseMokuPerformanceOptions()
	if err != nil {
		return err
	}
	timeout := 2 * time.Minute
	if options.enabled {
		timeout = 5 * time.Minute
	}
	if options.swiftNoteExposure {
		timeout = 10 * time.Minute
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	mokuReplayLifetime = ctx
	if options.enabled {
		return runMokuReplaySection("performance fixtures", func() error { return runMokuPerformance(options) })
	}
	if options.swiftNoteExposure {
		return runSwiftNoteExposureReplay()
	}
	if err := exportNativeTalkRecords(); err != nil {
		return err
	}
	if err := exportNativeNoteRecords(); err != nil {
		return err
	}
	for _, replay := range []struct {
		name string
		run  func() error
	}{
		{"creation contract", runCreationContractReplay},
		{"talk schema", runTalkSchemaReplay},
		{"note contract", runNoteSchemaReplay},
		{"note orchestrator and audit", func() error { runNoteOrchestratorReplay(); return nil }},
		{"note persistence and migration", func() error { runNoteRuntimeReplay(); return nil }},
		{"idle Harness switching and note handoff", runHarnessSwitchReplay},
		{"Git worktree creation", runWorktreeCreationReplay},
		{"runtime admission and SQLite", runRuntimeReplay},
		{"settings at successor admission", runAdmissionSettingsChangeReplay},
		{"relay voice across settings changes", runRelaySettingsChangeReplay},
		{"native voice settings recovery", runNativeVoiceSettingsReplay},
		{"execution-fenced public cancellation", runFencedMokuCancellationReplay},
		{"sidecard direct thread notifications", runUserThreadInputReplay},
		{"initial shell and restart", runShellReplay},
		{"startup discovery and settings saves", runStartupSettingsReplay},
		{"coordinator lifecycle and tools", runOrchestratorReplay},
		{"cancellable coordinator queue", runQueuedAdmissionReplay},
		{"lazy context Thread reads", runContextReadContractReplay},
		{"compiled tool schema ownership", runCompiledToolContractReplay},
		{"terminal queue and outbox ownership", runTerminalQueueReplay},
		{"queued voice preparation cancellation", runQueuedVoiceCancellationReplay},
		{"retired relay queue cancellation", runRelayQueueCancellationReplay},
		{"voice lifecycle", runVoiceReplay},
	} {
		if err := runMokuReplaySection(replay.name, replay.run); err != nil {
			return err
		}
	}
	fmt.Println("PASS all Moku fixed replays")
	return nil
}

func runMokuReplaySection(name string, run func() error) (err error) {
	defer func() {
		if failure := recover(); failure != nil {
			err = fmt.Errorf("%s: %v", name, failure)
		}
	}()
	if err := run(); err != nil {
		return fmt.Errorf("%s: %w", name, err)
	}
	return nil
}

func mokuReplayAwait(label string, signal <-chan struct{}) {
	select {
	case <-signal:
	case <-mokuReplayContext().Done():
		panic(fmt.Errorf("%s: %w", label, mokuReplayContext().Err()))
	case <-time.After(10 * time.Second):
		panic("timed out waiting for " + label)
	}
}
