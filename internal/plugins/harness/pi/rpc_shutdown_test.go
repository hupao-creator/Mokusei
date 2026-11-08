package pi

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

// The wrapper starts this test binary as Pi, so all shutdown assertions cross
// production pipes and exec.Cmd.Wait without requiring an installed native CLI.
func TestPiShutdownProcess(t *testing.T) {
	if os.Getenv("MOKUSEI_PI_SHUTDOWN_HELPER") != "1" {
		return
	}
	for _, arg := range os.Args {
		if arg == "--version" {
			fmt.Println("1.0.0")
			os.Exit(0)
		}
	}
	directory := os.Getenv("MOKUSEI_PI_SHUTDOWN_DIRECTORY")
	mode := os.Getenv("MOKUSEI_PI_SHUTDOWN_MODE")
	terminated := make(chan os.Signal, 1)
	if mode == "term" {
		signal.Notify(terminated, syscall.SIGTERM)
	} else if mode == "kill" {
		signal.Ignore(syscall.SIGTERM)
	}
	writeFile := func(name, value string) {
		if err := os.WriteFile(filepath.Join(directory, name), []byte(value), 0600); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(2)
		}
	}
	writeFile("pid", fmt.Sprint(os.Getpid()))
	encoder := json.NewEncoder(os.Stdout)
	scanner := bufio.NewScanner(os.Stdin)
	for scanner.Scan() {
		var command map[string]any
		if err := json.Unmarshal(scanner.Bytes(), &command); err != nil {
			os.Exit(2)
		}
		data := map[string]any{}
		switch command["type"] {
		case "get_state":
			data = map[string]any{"sessionFile": filepath.Join(directory, "session.jsonl"), "sessionId": "shutdown-fixture", "thinkingLevel": "off", "model": map[string]any{"id": "fixture", "provider": "fixture"}}
		case "get_available_thinking_levels":
			data["levels"] = []string{"off"}
		case "emit":
			_ = encoder.Encode(map[string]any{"type": "agent_start"})
		case "fail":
			fmt.Println("not-json")
			continue
		}
		if err := encoder.Encode(map[string]any{"type": "response", "id": command["id"], "success": true, "data": data}); err != nil {
			os.Exit(2)
		}
	}
	writeFile("eof", "observed")
	switch mode {
	case "eof-barrier":
		for {
			if _, err := os.Stat(filepath.Join(directory, "release")); err == nil {
				break
			}
			time.Sleep(time.Millisecond)
		}
	case "term":
		<-terminated
		writeFile("term", "observed")
	case "kill":
		for {
			time.Sleep(time.Hour)
		}
	}
	writeFile("session.jsonl", "{\"type\":\"session\",\"id\":\"shutdown-fixture\"}\n{\"type\":\"shutdown-final\"}\n")
	_ = encoder.Encode(map[string]any{"type": "agent_settled"})
	fmt.Fprintln(os.Stderr, "shutdown diagnostics drained")
	os.Exit(0)
}

func shutdownProcessOptions(t *testing.T, mode string) ProcessOptions {
	t.Helper()
	directory := t.TempDir()
	binary, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	executable := filepath.Join(directory, "pi")
	quoted := "'" + strings.ReplaceAll(binary, "'", "'\"'\"'") + "'"
	if err := os.WriteFile(executable, []byte("#!/bin/sh\nexec "+quoted+" -test.run='^TestPiShutdownProcess$' -- \"$@\"\n"), 0700); err != nil {
		t.Fatal(err)
	}
	env := map[string]string{}
	for _, pair := range os.Environ() {
		key, value, _ := strings.Cut(pair, "=")
		env[key] = value
	}
	env["MOKUSEI_PI_SHUTDOWN_HELPER"] = "1"
	env["MOKUSEI_PI_SHUTDOWN_DIRECTORY"] = directory
	env["MOKUSEI_PI_SHUTDOWN_MODE"] = mode
	// The race runtime's optional exit sleep is unrelated to native cleanup and
	// would otherwise consume the entire first shutdown escalation interval.
	env["GORACE"] = "atexit_sleep_ms=0"
	return ProcessOptions{ExecutablePath: executable, Cwd: directory, Env: env}
}

func awaitShutdownSignal(t *testing.T, done <-chan struct{}, phase string) {
	t.Helper()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatalf("timed out waiting for %s", phase)
	}
}

func awaitShutdownResult(t *testing.T, done <-chan error) error {
	t.Helper()
	select {
	case err := <-done:
		return err
	case <-time.After(8 * time.Second):
		t.Fatal("Close did not return")
		return nil
	}
}

func TestRPCCloseWaitsForProtocolReader(t *testing.T) {
	rpc, err := startRPC(t.Context(), shutdownProcessOptions(t, "eof"))
	if err != nil {
		t.Fatal(err)
	}
	entered, release := make(chan struct{}), make(chan struct{})
	var releaseOnce sync.Once
	finish := func() { releaseOnce.Do(func() { close(release) }) }
	defer rpc.Close()
	defer finish()
	rpc.subscribe(func(map[string]any) { close(entered); <-release })
	if err := rpc.write(t.Context(), map[string]any{"type": "emit"}); err != nil {
		t.Fatal(err)
	}
	awaitShutdownSignal(t, entered, "protocol callback")
	closed := make(chan error, 1)
	go func() { closed <- rpc.Close() }()
	awaitShutdownSignal(t, rpc.done, "child exit")
	select {
	case err := <-closed:
		t.Fatalf("Close returned before the protocol reader finished: %v", err)
	case <-time.After(30 * time.Millisecond):
	}
	finish()
	if err := awaitShutdownResult(t, closed); err != nil {
		t.Fatal(err)
	}
	assertRPCDrained(t, rpc)
}

func TestRPCCloseReportsUndrainedProtocolReader(t *testing.T) {
	rpc, err := startRPC(context.Background(), shutdownProcessOptions(t, "eof"))
	if err != nil {
		t.Fatal(err)
	}
	entered, release := make(chan struct{}), make(chan struct{})
	defer rpc.Close()
	defer close(release)
	rpc.subscribe(func(map[string]any) { close(entered); <-release })
	if err := rpc.write(t.Context(), map[string]any{"type": "emit"}); err != nil {
		t.Fatal(err)
	}
	awaitShutdownSignal(t, entered, "protocol callback")
	closed := make(chan error, 4)
	for range cap(closed) {
		go func() { closed <- rpc.Close() }()
	}
	first := awaitShutdownResult(t, closed)
	if !errors.Is(first, errRPCCleanupIncomplete) {
		t.Fatalf("Close did not report incomplete reader cleanup: %v", first)
	}
	for range cap(closed) - 1 {
		if got := awaitShutdownResult(t, closed); got != first {
			t.Fatalf("concurrent Close returned a different result: %v != %v", got, first)
		}
	}
	if got := rpc.Close(); got != first {
		t.Fatalf("repeated Close lost the cleanup failure: %v", got)
	}
}

func TestRPCCloseWaitsForDiagnosticReader(t *testing.T) {
	rpc, err := startRPC(t.Context(), shutdownProcessOptions(t, "eof"))
	if err != nil {
		t.Fatal(err)
	}
	// The child emits its last stdout frame after EOF, so the stopped protocol
	// reader can finish independently while the real stderr sink is blocked.
	rpc.diagnostics.mu.Lock()
	var releaseOnce sync.Once
	release := func() { releaseOnce.Do(rpc.diagnostics.mu.Unlock) }
	defer rpc.Close()
	defer release()
	closed := make(chan error, 1)
	go func() { closed <- rpc.Close() }()
	awaitShutdownSignal(t, rpc.done, "child exit")
	awaitShutdownSignal(t, rpc.readDone, "stdout reader exit")
	select {
	case <-rpc.stderrDone:
		t.Fatal("diagnostic reader did not reach its blocked sink")
	default:
	}
	select {
	case err := <-closed:
		t.Fatalf("Close returned before the diagnostic reader finished: %v", err)
	case <-time.After(30 * time.Millisecond):
	}
	release()
	if err := awaitShutdownResult(t, closed); err != nil {
		t.Fatal(err)
	}
	assertRPCDrained(t, rpc)
}

func assertRPCDrained(t *testing.T, rpc *rpcTransport) {
	t.Helper()
	for name, done := range map[string]<-chan struct{}{"process": rpc.done, "stdout": rpc.readDone, "stderr": rpc.stderrDone, "close": rpc.closed} {
		select {
		case <-done:
		default:
			t.Fatalf("Close succeeded before %s completed", name)
		}
	}
	if rpc.cmd.ProcessState == nil {
		t.Fatal("Close succeeded without reaping the child")
	}
	if err := syscall.Kill(rpc.cmd.Process.Pid, 0); !errors.Is(err, syscall.ESRCH) {
		t.Fatalf("native child still exists after Close: %v", err)
	}
}

func TestRPCCloseDrainsProcessAndReaders(t *testing.T) {
	for _, mode := range []string{"eof", "term", "kill", "cancel"} {
		t.Run(mode, func(t *testing.T) {
			ctx, cancel := context.WithCancel(t.Context())
			defer cancel()
			options := shutdownProcessOptions(t, mode)
			rpc, err := startRPC(ctx, options)
			if err != nil {
				t.Fatal(err)
			}
			defer rpc.Close()
			if mode == "cancel" {
				cancel()
				awaitShutdownSignal(t, rpc.closed, "cancelled owner cleanup")
			}
			closed := make(chan error, 4)
			for range cap(closed) {
				go func() { closed <- rpc.Close() }()
			}
			for range cap(closed) {
				if err := awaitShutdownResult(t, closed); err != nil {
					t.Fatal(err)
				}
			}
			assertRPCDrained(t, rpc)
			if err := rpc.Close(); err != nil {
				t.Fatalf("repeated Close: %v", err)
			}
			if mode == "term" {
				if _, err := os.Stat(filepath.Join(options.Cwd, "term")); err != nil {
					t.Fatalf("fixture did not finish through SIGTERM: %v", err)
				}
			}
			if mode == "kill" {
				status := rpc.cmd.ProcessState.Sys().(syscall.WaitStatus)
				if !status.Signaled() || status.Signal() != syscall.SIGKILL {
					t.Fatalf("stubborn child was not killed: %v", status)
				}
			}
		})
	}
}

func TestSessionCloseFromCallback(t *testing.T) {
	for _, event := range []string{"emit", "fail"} {
		t.Run(event, func(t *testing.T) {
			session, err := StartSession(t.Context(), shutdownProcessOptions(t, "eof"))
			if err != nil {
				t.Fatal(err)
			}
			defer session.Close()
			closed := make(chan error, 1)
			if event == "emit" {
				session.Subscribe(func(Event) { closed <- session.Close() })
			} else {
				session.OnFailure(func(error) { closed <- session.Close() })
			}
			if err := session.rpc.write(t.Context(), map[string]any{"type": event}); err != nil {
				t.Fatal(err)
			}
			if err := awaitShutdownResult(t, closed); err != nil {
				t.Fatal(err)
			}
			awaitShutdownSignal(t, session.dispatched, "callback dispatcher exit")
			assertRPCDrained(t, session.rpc)
		})
	}
}

type shutdownStateStore struct {
	mu  sync.Mutex
	raw json.RawMessage
}

func (s *shutdownStateStore) Read() json.RawMessage {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append(json.RawMessage(nil), s.raw...)
}

func (s *shutdownStateStore) Commit(_ context.Context, raw json.RawMessage) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.raw = append(json.RawMessage(nil), raw...)
	return nil
}

func (s *shutdownStateStore) state(t *testing.T) State {
	t.Helper()
	state, err := decodeState(s.Read())
	if err != nil {
		t.Fatal(err)
	}
	return state
}

func openShutdownThread(t *testing.T, options ProcessOptions) (plugin.Handle, *shutdownStateStore) {
	t.Helper()
	adapter := New(plugin.HostContext{HarnessDataRoot: t.TempDir(), Environment: func(context.Context) (map[string]string, error) { return options.Env, nil }})
	t.Cleanup(func() { _ = adapter.Close() })
	settings, _ := json.Marshal(ThreadSettings{ExecutablePath: options.ExecutablePath, Provider: "fixture", Model: "fixture", ThinkingLevel: "off"})
	store := &shutdownStateStore{}
	handle, err := adapter.Open(t.Context(), plugin.OpenContext{ThreadID: "thread", SessionState: store, ReadThread: func() model.SessionRecord {
		return model.SessionRecord{ID: "thread", HarnessID: "pi", Cwd: options.Cwd, Settings: settings}
	}})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = handle.Close() })
	if err := handle.Send(t.Context(), plugin.SendRequest{ExecutionID: "execution", Input: model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "stay active until shutdown"}}}}); err != nil {
		t.Fatal(err)
	}
	return handle, store
}

func awaitShutdownFile(t *testing.T, path string) {
	t.Helper()
	deadline := time.NewTimer(5 * time.Second)
	defer deadline.Stop()
	tick := time.NewTicker(time.Millisecond)
	defer tick.Stop()
	for {
		if _, err := os.Stat(path); err == nil {
			return
		}
		select {
		case <-tick.C:
		case <-deadline.C:
			t.Fatalf("fixture did not publish %s", filepath.Base(path))
		}
	}
}

func TestThreadCloseCapturesFinalNativeSnapshot(t *testing.T) {
	options := shutdownProcessOptions(t, "eof-barrier")
	handle, store := openShutdownThread(t, options)
	thread := handle.(*threadHandle)
	thread.mu.Lock()
	rpc := thread.rpc.rpc
	thread.mu.Unlock()
	closed := make(chan error, 3)
	for range cap(closed) {
		go func() { closed <- handle.Close() }()
	}
	awaitShutdownFile(t, filepath.Join(options.Cwd, "eof"))
	select {
	case err := <-closed:
		t.Fatalf("Thread Close returned before the native final write: %v", err)
	default:
	}
	before := store.state(t)
	if before.Executions[0].Terminal() || before.NativeSessionJSONL != "" {
		t.Fatalf("Thread published terminal state before native cleanup: %+v", before)
	}
	if err := os.WriteFile(filepath.Join(options.Cwd, "release"), nil, 0600); err != nil {
		t.Fatal(err)
	}
	for range cap(closed) {
		if err := awaitShutdownResult(t, closed); err != nil {
			t.Fatal(err)
		}
	}
	state := store.state(t)
	if state.Executions[0].Status != "interrupted" || !strings.Contains(state.NativeSessionJSONL, "shutdown-final") {
		t.Fatalf("Thread lost the final native snapshot or settlement: %+v", state)
	}
	assertRPCDrained(t, rpc)
	if err := handle.Close(); err != nil {
		t.Fatalf("repeated Thread Close: %v", err)
	}
}

func TestThreadCleanupFailurePreservesSnapshotAndBlocksReplacement(t *testing.T) {
	options := shutdownProcessOptions(t, "eof")
	handle, store := openShutdownThread(t, options)
	thread := handle.(*threadHandle)
	thread.mu.Lock()
	rpc := thread.rpc.rpc
	thread.mu.Unlock()
	entered, release := make(chan struct{}), make(chan struct{})
	defer close(release)
	rpc.subscribe(func(map[string]any) { close(entered); <-release })
	if err := rpc.write(t.Context(), map[string]any{"type": "emit"}); err != nil {
		t.Fatal(err)
	}
	awaitShutdownSignal(t, entered, "protocol callback")
	before := store.state(t).NativeSessionJSONL
	stopped := make(chan error, 1)
	go func() { stopped <- handle.Interrupt(t.Context()) }()
	if err := awaitShutdownResult(t, stopped); !errors.Is(err, errRPCCleanupIncomplete) {
		t.Fatalf("Thread swallowed incomplete cleanup: %v", err)
	}
	final, err := os.ReadFile(filepath.Join(options.Cwd, "session.jsonl"))
	if err != nil || !strings.Contains(string(final), "shutdown-final") {
		t.Fatalf("fixture did not produce a candidate final snapshot: %q, %v", final, err)
	}
	if got := store.state(t).NativeSessionJSONL; got != before {
		t.Fatalf("failed Close published an uncertified snapshot: %q", got)
	}
	retained := string(store.Read())
	err = handle.Send(t.Context(), plugin.SendRequest{ExecutionID: "replacement", Input: model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "must not dispatch"}}}})
	if !errors.Is(err, errRPCCleanupIncomplete) || string(store.Read()) != retained {
		t.Fatalf("replacement input bypassed cleanup failure: %v", err)
	}
	if _, err := thread.ensureConnection(t.Context(), false); !errors.Is(err, errRPCCleanupIncomplete) {
		t.Fatalf("replacement connection bypassed cleanup failure: %v", err)
	}
	if err := handle.Close(); !errors.Is(err, errRPCCleanupIncomplete) {
		t.Fatalf("Thread Close lost earlier incomplete cleanup: %v", err)
	}
}
