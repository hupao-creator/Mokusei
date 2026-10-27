package pi

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/exec"
	"strings"
	"sync"
	"testing"
	"time"
)

type recordingRPCInput struct {
	writes chan []byte
}

func (input recordingRPCInput) Write(data []byte) (int, error) {
	input.writes <- append([]byte(nil), data...)
	return len(data), nil
}
func (recordingRPCInput) Close() error { return nil }

type stalledRPCInput struct {
	*os.File
	started chan struct{}
}

func (input stalledRPCInput) Write(data []byte) (int, error) {
	close(input.started)
	return input.File.Write(data)
}

type completedRPCInput struct {
	*os.File
	cancel        context.CancelFunc
	interrupted   chan struct{}
	cancelOnce    sync.Once
	interruptOnce sync.Once
}

func (input *completedRPCInput) Write(data []byte) (int, error) {
	n, err := input.File.Write(data)
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
func (input *completedRPCInput) SetWriteDeadline(deadline time.Time) error {
	err := input.File.SetWriteDeadline(deadline)
	if !deadline.IsZero() {
		input.interruptOnce.Do(func() { close(input.interrupted) })
	}
	return err
}
func (input *completedRPCInput) Close() error {
	err := input.File.Close()
	input.interruptOnce.Do(func() { close(input.interrupted) })
	return err
}

func TestCancelledQueuedRPCRequestIsNeverDispatched(t *testing.T) {
	input := recordingRPCInput{writes: make(chan []byte, 2)}
	rpc := &rpcTransport{stdin: input, writeGate: make(chan struct{}, 1), pending: map[string]chan rpcResult{}, closed: make(chan struct{})}
	rpc.writeGate <- struct{}{}
	var unlockOnce sync.Once
	unlock := func() { unlockOnce.Do(func() { <-rpc.writeGate }) }
	defer unlock()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() {
		_, err := rpc.request(ctx, map[string]any{"type": "prompt", "message": "cancelled steering"})
		done <- err
	}()
	deadline := time.After(5 * time.Second)
	for {
		rpc.mu.Lock()
		registered := len(rpc.pending) == 1
		rpc.mu.Unlock()
		if registered {
			break
		}
		select {
		case <-deadline:
			t.Fatal("request was not registered")
		case <-time.After(time.Millisecond):
		}
	}
	cancel()
	select {
	case err := <-done:
		if err == nil {
			t.Fatal("cancelled request succeeded")
		}
	case <-deadline:
		t.Fatal("queued request did not observe cancellation")
	}
	unlock()
	// A later command must still use this connection. Reading both writes
	// exposes a cancelled command that leaked out after its caller returned.
	nextCtx, nextCancel := context.WithTimeout(context.Background(), time.Second)
	defer nextCancel()
	if err := rpc.write(nextCtx, map[string]any{"type": "get_state"}); err != nil {
		t.Fatal(err)
	}
	select {
	case data := <-input.writes:
		var frame map[string]any
		if err := json.Unmarshal(data, &frame); err != nil || frame["type"] != "get_state" {
			t.Fatalf("cancelled steering reached the native input: %s", data)
		}
	case <-deadline:
		t.Fatal("subsequent command was not written")
	}
	select {
	case data := <-input.writes:
		t.Fatalf("unexpected native input: %s", data)
	case <-time.After(25 * time.Millisecond):
	}
	rpc.mu.Lock()
	defer rpc.mu.Unlock()
	if rpc.failure != nil || len(rpc.pending) != 0 {
		t.Fatalf("queued cancellation changed connection state: %v, %d pending", rpc.failure, len(rpc.pending))
	}
}

func TestCancellingRPCResponseWaitKeepsCompletedWrite(t *testing.T) {
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	defer writer.Close()
	if err := reader.SetReadDeadline(time.Now().Add(5 * time.Second)); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	input := &completedRPCInput{File: writer, cancel: cancel, interrupted: make(chan struct{})}
	processDone := make(chan struct{})
	close(processDone)
	rpc := &rpcTransport{
		stdin: input, writeGate: make(chan struct{}, 1), pending: map[string]chan rpcResult{}, closed: make(chan struct{}),
		stdout: io.NopCloser(strings.NewReader("")), stderr: io.NopCloser(strings.NewReader("")), cmd: &exec.Cmd{}, done: processDone,
	}
	defer rpc.Close()
	done := make(chan error, 1)
	go func() {
		_, err := rpc.request(ctx, map[string]any{"type": "get_state"})
		done <- err
	}()
	decoder := json.NewDecoder(reader)
	var frame map[string]any
	if err := decoder.Decode(&frame); err != nil {
		t.Fatal(err)
	}
	// The fixture cancels after the OS accepted the whole frame, before Write
	// returns. This is already a response wait, not an uncertain partial frame.
	select {
	case err := <-done:
		if err == nil {
			t.Fatal("cancelled response wait succeeded")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("response wait did not observe cancellation")
	}
	rpc.mu.Lock()
	failure := rpc.failure
	rpc.mu.Unlock()
	if failure != nil {
		t.Fatalf("cancelling a response wait closed the connection: %v", failure)
	}
	nextCtx, nextCancel := context.WithTimeout(context.Background(), time.Second)
	defer nextCancel()
	if err := rpc.write(nextCtx, map[string]any{"type": "get_models"}); err != nil {
		t.Fatalf("completed frame left its pipe deadline active: %v", err)
	}
	if err := decoder.Decode(&frame); err != nil || frame["type"] != "get_models" {
		t.Fatalf("subsequent native frame = %v, error = %v", frame, err)
	}
}

func TestCancellingStartedRPCWriteClosesConnection(t *testing.T) {
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	defer writer.Close()
	if err := reader.SetReadDeadline(time.Now().Add(5 * time.Second)); err != nil {
		t.Fatal(err)
	}
	started := make(chan struct{})
	processDone := make(chan struct{})
	close(processDone)
	rpc := &rpcTransport{
		stdin: stalledRPCInput{File: writer, started: started}, writeGate: make(chan struct{}, 1),
		stdout: io.NopCloser(strings.NewReader("")), stderr: io.NopCloser(strings.NewReader("")),
		cmd: &exec.Cmd{}, done: processDone, closed: make(chan struct{}), pending: map[string]chan rpcResult{},
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() {
		_, err := rpc.request(ctx, map[string]any{"type": "prompt", "message": strings.Repeat("x", 8*1024*1024)})
		done <- err
	}()
	select {
	case <-started:
	case <-time.After(5 * time.Second):
		t.Fatal("request did not reach the blocked pipe")
	}
	if _, err := reader.Read(make([]byte, 1)); err != nil {
		t.Fatalf("native pipe did not accept the partial frame: %v", err)
	}
	cancel()
	select {
	case err := <-done:
		if err == nil {
			t.Fatal("cancelled write succeeded")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("request did not observe write cancellation")
	}
	select {
	case <-rpc.closed:
	case <-time.After(5 * time.Second):
		t.Fatal("cancelled partial write did not close the connection")
	}
}
