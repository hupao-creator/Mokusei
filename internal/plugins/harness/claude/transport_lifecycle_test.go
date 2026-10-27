package claude

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"sync"
	"testing"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
)

type stalledClaudeInput struct {
	io.WriteCloser
	started chan struct{}
	once    sync.Once
}

func (w *stalledClaudeInput) Write(data []byte) (int, error) {
	w.once.Do(func() { close(w.started) })
	return w.WriteCloser.Write(data)
}

type completedClaudeInput struct {
	*os.File
	cancel        context.CancelFunc
	interrupted   chan struct{}
	cancelOnce    sync.Once
	interruptOnce sync.Once
}

func (w *completedClaudeInput) Write(data []byte) (int, error) {
	n, err := w.File.Write(data)
	w.cancelOnce.Do(func() {
		w.cancel()
		select {
		case <-w.interrupted:
		case <-time.After(2 * time.Second):
			err = errors.New("write cancellation did not reach the completed native pipe")
		}
	})
	return n, err
}
func (w *completedClaudeInput) SetWriteDeadline(deadline time.Time) error {
	err := w.File.SetWriteDeadline(deadline)
	if !deadline.IsZero() {
		w.interruptOnce.Do(func() { close(w.interrupted) })
	}
	return err
}
func (w *completedClaudeInput) Close() error {
	err := w.File.Close()
	w.interruptOnce.Do(func() { close(w.interrupted) })
	return err
}

func claudePipeFixture(t *testing.T) (*Transport, *io.PipeReader, <-chan struct{}) {
	t.Helper()
	reader, writer := io.Pipe()
	input := &stalledClaudeInput{WriteCloser: writer, started: make(chan struct{})}
	transport := NewTransport(TransportOptions{})
	transport.stdin = input
	t.Cleanup(func() {
		_ = reader.Close()
		_ = transport.Close()
	})
	return transport, reader, input.started
}

func awaitClaudeWrite(t *testing.T, started <-chan struct{}) {
	t.Helper()
	select {
	case <-started:
	case <-time.After(2 * time.Second):
		t.Fatal("Claude fixture did not reach its pipe write")
	}
}

func awaitClaudeWriteResult(t *testing.T, result <-chan error) error {
	t.Helper()
	select {
	case err := <-result:
		return err
	case <-time.After(2 * time.Second):
		t.Fatal("Claude write did not finish")
		return nil
	}
}

func TestControlDeadlineInterruptsStalledPipe(t *testing.T) {
	transport, _, started := claudePipeFixture(t)
	result := make(chan error, 1)
	go func() {
		_, err := transport.controlTimeout(context.Background(), map[string]any{"subtype": "get_settings"}, 100*time.Millisecond)
		result <- err
	}()
	awaitClaudeWrite(t, started)
	if err := awaitClaudeWriteResult(t, result); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("control error = %v, want deadline exceeded", err)
	}
	transport.mu.Lock()
	stdin := transport.stdin
	pending := len(transport.controls)
	transport.mu.Unlock()
	if stdin != nil || pending != 0 {
		t.Fatalf("cancelled control retained stdin=%v or %d pending requests", stdin, pending)
	}
}

func TestSendCancellationInterruptsStalledPipe(t *testing.T) {
	transport, _, started := claudePipeFixture(t)
	// Initialization is already complete; the fixture stalls the production
	// user frame rather than invoking any native executable.
	transport.initialized = true
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	result := make(chan error, 1)
	go func() {
		_, err := transport.Send(ctx, "stalled-send", model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "hello"}}}, "now")
		result <- err
	}()
	awaitClaudeWrite(t, started)
	cancel()
	if err := awaitClaudeWriteResult(t, result); !errors.Is(err, context.Canceled) {
		t.Fatalf("send error = %v, want cancellation", err)
	}
	transport.mu.Lock()
	boundaries := len(transport.active.boundaries)
	transport.mu.Unlock()
	if boundaries != 0 {
		t.Fatalf("cancelled send retained %d native boundaries", boundaries)
	}
}

func TestQueuedWriteCancellationPreservesActivePipe(t *testing.T) {
	transport, reader, started := claudePipeFixture(t)
	first := make(chan error, 1)
	go func() {
		first <- transport.writeContext(context.Background(), map[string]any{"frame": "first"})
	}()
	awaitClaudeWrite(t, started)
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	queued := make(chan error, 1)
	go func() { queued <- transport.writeContext(ctx, map[string]any{"frame": "cancelled"}) }()
	if err := awaitClaudeWriteResult(t, queued); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("queued write error = %v, want deadline exceeded", err)
	}

	frames := make(chan string, 2)
	go func() {
		scanner := bufio.NewScanner(reader)
		for scanner.Scan() {
			var frame struct {
				Frame string `json:"frame"`
			}
			if err := json.Unmarshal(scanner.Bytes(), &frame); err != nil {
				frames <- "invalid JSON"
				return
			}
			frames <- frame.Frame
		}
	}()
	if err := awaitClaudeWriteResult(t, first); err != nil {
		t.Fatalf("active frame was interrupted: %v", err)
	}
	third := make(chan error, 1)
	go func() { third <- transport.writeContext(context.Background(), map[string]any{"frame": "third"}) }()
	if err := awaitClaudeWriteResult(t, third); err != nil {
		t.Fatalf("pipe was not reusable after queued cancellation: %v", err)
	}
	for _, want := range []string{"first", "third"} {
		select {
		case got := <-frames:
			if got != want {
				t.Fatalf("native frame = %q, want %q", got, want)
			}
		case <-time.After(2 * time.Second):
			t.Fatalf("missing native frame %q", want)
		}
	}
}

func TestCloseInterruptsStalledNativeReply(t *testing.T) {
	transport, _, started := claudePipeFixture(t)
	result := make(chan error, 1)
	go func() { result <- transport.controlReply("native-request", map[string]any{"behavior": "deny"}) }()
	awaitClaudeWrite(t, started)
	if err := transport.Close(); err != nil {
		t.Fatal(err)
	}
	if err := awaitClaudeWriteResult(t, result); err == nil {
		t.Fatal("stalled native reply unexpectedly succeeded after close")
	}
}

func TestCancellationKeepsCompletedNativeFrame(t *testing.T) {
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
	input := &completedClaudeInput{File: writer, cancel: cancel, interrupted: make(chan struct{})}
	transport := NewTransport(TransportOptions{})
	transport.stdin = input
	defer transport.Close()
	// Cancellation lands after the OS accepted the frame, before Write returns.
	if err := transport.writeContext(ctx, map[string]any{"frame": "complete"}); err != nil {
		t.Fatalf("completed frame was treated as partial: %v", err)
	}
	if err := transport.writeContext(context.Background(), map[string]any{"frame": "next"}); err != nil {
		t.Fatalf("completed frame left its pipe deadline active: %v", err)
	}
	decoder := json.NewDecoder(reader)
	for _, want := range []string{"complete", "next"} {
		var frame map[string]any
		if err := decoder.Decode(&frame); err != nil || frame["frame"] != want {
			t.Fatalf("native frame = %v, error = %v; want %q", frame, err, want)
		}
	}
}
