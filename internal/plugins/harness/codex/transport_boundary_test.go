package codex

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

type transportBuffer struct{ bytes.Buffer }

func (*transportBuffer) Close() error { return nil }

type completedAppServerInput struct {
	pipe interface {
		io.WriteCloser
		SetWriteDeadline(time.Time) error
	}
	cancel        context.CancelFunc
	interrupted   chan struct{}
	cancelOnce    sync.Once
	interruptOnce sync.Once
}

func (input *completedAppServerInput) Write(data []byte) (int, error) {
	n, err := input.pipe.Write(data)
	input.cancelOnce.Do(func() {
		input.cancel()
		select {
		case <-input.interrupted:
		case <-time.After(2 * time.Second):
			err = errors.New("write cancellation did not reach the completed native pipe")
		}
	})
	return n, err
}
func (input *completedAppServerInput) SetWriteDeadline(deadline time.Time) error {
	err := input.pipe.SetWriteDeadline(deadline)
	if !deadline.IsZero() {
		input.interruptOnce.Do(func() { close(input.interrupted) })
	}
	return err
}
func (input *completedAppServerInput) Close() error {
	err := input.pipe.Close()
	input.interruptOnce.Do(func() { close(input.interrupted) })
	return err
}

func transportWriteFixture() (*AppServer, *transportBuffer) {
	writer := &transportBuffer{}
	return &AppServer{
		stdin:     writer,
		writeSlot: make(chan struct{}, 1),
		pending:   map[string]chan rpcReply{},
		done:      make(chan struct{}),
	}, writer
}

func TestAppServerCancelledStartupDisposesPreparedLaunch(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	disposed := 0
	server, err := StartAppServer(ctx, LaunchOptions{Dispose: func() error { disposed++; return nil }})
	if !errors.Is(err, context.Canceled) || server != nil || disposed != 1 {
		t.Fatalf("cancelled startup: server=%v err=%v dispose calls=%d", server, err, disposed)
	}
}

func TestAppServerCancelledCallDoesNotWrite(t *testing.T) {
	server, writer := transportWriteFixture()
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := server.Call(ctx, "turn/start", Map{"input": "must not dispatch"}); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled call returned %v", err)
	}
	if writer.Len() != 0 || len(server.pending) != 0 || server.next != 0 || server.closed {
		t.Fatal("cancelled call wrote, allocated a request, or retired the transport")
	}
}

func TestAppServerQueuedWriteCancellationKeepsTransport(t *testing.T) {
	server, writer := transportWriteFixture()
	server.writeSlot <- struct{}{}
	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Millisecond)
	defer cancel()
	if _, err := server.Call(ctx, "turn/start", Map{"input": "queued"}); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("queued call returned %v", err)
	}
	<-server.writeSlot
	if writer.Len() != 0 || len(server.pending) != 0 || server.closed {
		t.Fatal("queued cancellation wrote bytes, retained a request, or retired the transport")
	}
	if err := server.Notify("ping", nil); err != nil {
		t.Fatalf("transport unusable after queued cancellation: %v", err)
	}
	if writer.String() != "{\"method\":\"ping\"}\n" {
		t.Fatalf("unexpected subsequent write: %q", writer.String())
	}
}

const backpressureInputMarker = "MOKUSEI_BLOCKED_PIPE_INPUT:"
const backpressurePrefixRead = "fixture/blocked-pipe-prefix-read"
const backpressurePrefixBytes = 256

func startBackpressureServer(t *testing.T, readPrefix bool) (*AppServer, <-chan struct{}) {
	t.Helper()
	root := t.TempDir()
	binary, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	launcher := filepath.Join(root, "native-peer")
	// StartAppServer owns the executable's arguments. The launcher enters just
	// the local test peer, preserving the process group through exec.
	script := "#!/bin/sh\nexec \"$MOKUSEI_CODEX_TEST_BINARY\" -test.run='^TestCodexBackpressurePeer$'\n"
	if err := os.WriteFile(launcher, []byte(script), 0700); err != nil {
		t.Fatal(err)
	}
	disposed := make(chan struct{})
	startCtx, cancelStart := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancelStart()
	environment := []string{
		"PATH=/usr/bin:/bin",
		"MOKUSEI_CODEX_TEST_BINARY=" + binary,
		"MOKUSEI_CODEX_BACKPRESSURE_PEER=1",
	}
	if readPrefix {
		environment = append(environment, "MOKUSEI_CODEX_BACKPRESSURE_READ_PREFIX=1")
	}
	server, err := StartAppServer(startCtx, LaunchOptions{
		Executable:  launcher,
		Cwd:         root,
		Environment: environment,
		Dispose:     func() error { close(disposed); return nil },
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := server.Close(); err != nil {
			t.Errorf("close native peer: %v", err)
		}
	})
	return server, disposed
}

func TestAppServerBlockedPipeWriteHonorsCancellation(t *testing.T) {
	server, disposed := startBackpressureServer(t, true)
	observed := make(chan Map, 1)
	server.SetHandler(func(method string, params Map, _ any) {
		if method == backpressurePrefixRead {
			observed <- params
		}
	}, nil)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	result := make(chan error, 1)
	go func() {
		input := backpressureInputMarker + strings.Repeat("x", 8*1024*1024-len(backpressureInputMarker))
		_, err := server.Call(ctx, "turn/start", Map{"input": input})
		result <- err
	}()
	// Encoding and scheduling cannot start this cancellation: only the real
	// peer's receipt proves that the large frame has entered the pipe.
	select {
	case params := <-observed:
		if str(params["method"]) != "turn/start" || num(params["bytes"]) != backpressurePrefixBytes || str(params["inputMarker"]) != backpressureInputMarker {
			t.Fatalf("peer did not confirm the target frame prefix: %v", params)
		}
	case err := <-result:
		t.Fatalf("native call ended before its frame prefix was read: %v", err)
	case <-time.After(5 * time.Second):
		t.Fatal("native peer did not observe the target frame prefix")
	}
	cancel()
	select {
	case err := <-result:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("blocked write returned %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("native pipe write ignored request cancellation")
	}
	server.mu.Lock()
	closed, pending := server.closed, len(server.pending)
	server.mu.Unlock()
	if !closed || pending != 0 {
		t.Fatal("uncertain partial write left the native transport reusable")
	}
	if err := server.Close(); err != nil {
		t.Fatal(err)
	}
	select {
	case <-server.exited:
	default:
		t.Fatal("Close returned before the native process exited")
	}
	select {
	case <-disposed:
	default:
		t.Fatal("Close returned before owned-process cleanup")
	}
}

func TestAppServerCancellationKeepsCompletedFrame(t *testing.T) {
	server, _ := startBackpressureServer(t, false)
	stdin, ok := server.stdin.(interface {
		io.WriteCloser
		SetWriteDeadline(time.Time) error
	})
	if !ok {
		t.Fatalf("native stdin has unexpected type %T", server.stdin)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	server.stdin = &completedAppServerInput{pipe: stdin, cancel: cancel, interrupted: make(chan struct{})}
	// The local peer's pipe has room for this full frame. Hold Write's return
	// until cancellation reaches that completed pipe to force the race window.
	if err := server.writeContext(ctx, Map{"method": "completed-frame"}); err != nil {
		t.Fatalf("completed frame was treated as partial: %v", err)
	}
	server.mu.Lock()
	closed := server.closed
	server.mu.Unlock()
	if closed {
		t.Fatal("cancellation retired a transport after its frame completed")
	}
	if err := server.Notify("next-frame", nil); err != nil {
		t.Fatalf("completed frame left its pipe deadline active: %v", err)
	}
}

func TestCodexBackpressurePeer(t *testing.T) {
	if os.Getenv("MOKUSEI_CODEX_BACKPRESSURE_PEER") != "1" {
		return
	}
	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGTERM)
	defer cancel()
	// Keep one reader across both handshake frames and the target prefix, so
	// buffered read-ahead cannot consume bytes behind the prefix barrier.
	reader := bufio.NewReader(os.Stdin)
	line, err := reader.ReadBytes('\n')
	var initialize Map
	if err != nil || json.Unmarshal(line, &initialize) != nil || initialize["method"] != "initialize" || initialize["id"] == nil {
		os.Exit(2)
	}
	if err := json.NewEncoder(os.Stdout).Encode(Map{"id": initialize["id"], "result": Map{}}); err != nil {
		os.Exit(3)
	}
	line, err = reader.ReadBytes('\n')
	var initialized Map
	if err != nil || json.Unmarshal(line, &initialized) != nil || initialized["method"] != "initialized" || initialized["id"] != nil {
		os.Exit(4)
	}
	if os.Getenv("MOKUSEI_CODEX_BACKPRESSURE_READ_PREFIX") == "1" {
		prefix := make([]byte, backpressurePrefixBytes)
		if _, err := io.ReadFull(reader, prefix); err != nil {
			os.Exit(5)
		}
		// This bounded prefix must end inside the input string. Completing only
		// its JSON delimiters validates the envelope without reading the large tail.
		var frame Map
		if json.Unmarshal(append(prefix, []byte(`"}}`)...), &frame) != nil || frame["method"] != "turn/start" || frame["id"] == nil {
			os.Exit(6)
		}
		input := str(obj(frame["params"])["input"])
		if !strings.HasPrefix(input, backpressureInputMarker) || len(input) <= len(backpressureInputMarker) || strings.TrimPrefix(input, backpressureInputMarker) != strings.Repeat("x", len(input)-len(backpressureInputMarker)) {
			os.Exit(7)
		}
		if err := json.NewEncoder(os.Stdout).Encode(Map{"method": backpressurePrefixRead, "params": Map{"method": "turn/start", "bytes": backpressurePrefixBytes, "inputMarker": backpressureInputMarker}}); err != nil {
			os.Exit(8)
		}
	}
	// A live native peer that stops reading must not defeat caller cancellation.
	// SIGTERM ends the fixture without a timer or any external subprocess.
	<-ctx.Done()
	os.Exit(0)
}
