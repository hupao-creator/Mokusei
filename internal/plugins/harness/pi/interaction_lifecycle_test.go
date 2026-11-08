package pi

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

func TestMain(m *testing.M) {
	if os.Getenv("MOKUSEI_PI_INTERACTION_PEER") == "1" {
		if err := serveInteractionPeer(); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		os.Exit(0)
	}
	os.Exit(m.Run())
}

// The child speaks the native protocol through the production process pipes.
// It deliberately settles immediately after reading the complete answer.
func serveInteractionPeer() error {
	if len(os.Args) > 1 && os.Args[1] == "--version" {
		fmt.Println("1.0.0")
		return nil
	}
	encoder := json.NewEncoder(os.Stdout)
	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 4096), 2*maxRPCLineBytes)
	pending := ""
	sequence := 0
	for scanner.Scan() {
		var frame map[string]any
		if err := json.Unmarshal(scanner.Bytes(), &frame); err != nil {
			return err
		}
		respond := func(data any) error {
			return encoder.Encode(map[string]any{"type": "response", "id": frame["id"], "success": true, "data": data})
		}
		switch frame["type"] {
		case "get_state":
			if err := respond(map[string]any{"sessionFile": os.Getenv("MOKUSEI_PI_INTERACTION_SESSION"), "thinkingLevel": "off", "model": map[string]any{"provider": "provider", "id": "model"}}); err != nil {
				return err
			}
		case "get_available_thinking_levels":
			if err := respond(map[string]any{"levels": []string{"off"}}); err != nil {
				return err
			}
		case "prompt":
			if err := respond(map[string]any{}); err != nil {
				return err
			}
			sequence++
			pending = fmt.Sprintf("question-%d", sequence)
			if err := encoder.Encode(map[string]any{"type": "agent_start"}); err != nil {
				return err
			}
			if err := encoder.Encode(map[string]any{"type": "extension_ui_request", "id": pending, "method": "editor", "title": "Answer", "timeout": 60000}); err != nil {
				return err
			}
			if os.Getenv("MOKUSEI_PI_INTERACTION_SCENARIO") == "backpressure" {
				if _, err := io.ReadFull(os.Stdin, make([]byte, 1)); err != nil {
					return err
				}
				if err := encoder.Encode(map[string]any{"type": "extension_ui_request", "method": "notify", "message": "answer-prefix-received"}); err != nil {
					return err
				}
				for {
					time.Sleep(time.Hour)
				}
			}
		case "extension_ui_response":
			if pending == "" || frame["id"] != pending {
				return fmt.Errorf("unexpected native answer: %v", frame["id"])
			}
			pending = ""
			if err := encoder.Encode(map[string]any{"type": "agent_settled"}); err != nil {
				return err
			}
		default:
			return fmt.Errorf("unexpected native command: %v", frame["type"])
		}
	}
	return scanner.Err()
}

type interactionStateStore struct {
	mu      sync.Mutex
	raw     json.RawMessage
	changed chan struct{}
}

func (s *interactionStateStore) Read() json.RawMessage {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append(json.RawMessage(nil), s.raw...)
}
func (s *interactionStateStore) Commit(_ context.Context, raw json.RawMessage) error {
	s.mu.Lock()
	s.raw = append(json.RawMessage(nil), raw...)
	s.mu.Unlock()
	select {
	case s.changed <- struct{}{}:
	default:
	}
	return nil
}
func (s *interactionStateStore) waitExecution(t *testing.T, ctx context.Context, id, status string) model.PublicExecution {
	t.Helper()
	for {
		state, err := decodeState(s.Read())
		if err != nil {
			t.Fatal(err)
		}
		for _, execution := range state.Executions {
			if execution.ExecutionID != id {
				continue
			}
			if execution.Status == status {
				return execution
			}
			if execution.FinishedAt != nil {
				t.Fatalf("wanted %s, got %+v", status, execution)
			}
		}
		select {
		case <-s.changed:
		case <-ctx.Done():
			t.Fatalf("waiting for %s: %v; state=%s", status, ctx.Err(), s.Read())
		}
	}
}

func openInteractionPeer(t *testing.T, scenario string) (context.Context, *threadHandle, *interactionStateStore, model.PublicInteraction) {
	t.Helper()
	ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
	t.Cleanup(cancel)
	root := t.TempDir()
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	store := &interactionStateStore{changed: make(chan struct{}, 1)}
	record := model.SessionRecord{ID: "thread", HarnessID: "pi", Cwd: root, Settings: json.RawMessage(`{"provider":"provider","model":"model","thinkingLevel":"off"}`)}
	host := plugin.HostContext{
		HarnessDataRoot: filepath.Join(root, "data"),
		ResolveExecutable: func(context.Context, string, string, string) (string, error) {
			return executable, nil
		},
		Environment: func(context.Context) (map[string]string, error) {
			return map[string]string{"MOKUSEI_PI_INTERACTION_PEER": "1", "MOKUSEI_PI_INTERACTION_SCENARIO": scenario,
				"MOKUSEI_PI_INTERACTION_SESSION": filepath.Join(root, "native.jsonl"), "GORACE": "halt_on_error=1 atexit_sleep_ms=0"}, nil
		},
	}
	h, err := openThread(ctx, host, plugin.OpenContext{ThreadID: record.ID, ReadThread: func() model.SessionRecord { return record }, SessionState: store})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := h.Close(); err != nil {
			t.Error(err)
		}
	})
	if err := h.Send(ctx, plugin.SendRequest{ExecutionID: "execution", Input: model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "ask"}}}}); err != nil {
		t.Fatal(err)
	}
	execution := store.waitExecution(t, ctx, "execution", "waiting-for-user")
	if err := h.rpc.FlushEvents(ctx); err != nil {
		t.Fatal(err)
	}
	return ctx, h, store, execution.Interactions[0]
}

type pausedInteractionInput struct {
	*os.File
	written     chan struct{}
	resume      chan struct{}
	pauseOnce   sync.Once
	releaseOnce sync.Once
}

func (input *pausedInteractionInput) Write(data []byte) (int, error) {
	n, err := input.File.Write(data)
	input.pauseOnce.Do(func() {
		close(input.written)
		<-input.resume
	})
	return n, err
}
func (input *pausedInteractionInput) release() {
	input.releaseOnce.Do(func() { close(input.resume) })
}
func (input *pausedInteractionInput) Close() error {
	err := input.File.Close()
	input.release()
	return err
}

func TestInteractionAnswerOrdersNativeSettlementAndExpiry(t *testing.T) {
	ctx, h, store, interaction := openInteractionPeer(t, "")
	session := h.rpc
	h.mu.Lock()
	timer := h.interactions[interaction.ID].Timer
	h.mu.Unlock()
	input := &pausedInteractionInput{File: session.rpc.stdin.(*os.File), written: make(chan struct{}), resume: make(chan struct{})}
	session.rpc.stdin = input
	t.Cleanup(input.release)
	dispatchStarted, dispatchDone := make(chan struct{}), make(chan struct{})
	session.mu.Lock()
	for id, listener := range session.listeners {
		session.listeners[id] = func(event Event) {
			if event.Type == "settled" {
				close(dispatchStarted)
			}
			listener(event)
			if event.Type == "settled" {
				close(dispatchDone)
			}
		}
	}
	session.mu.Unlock()
	before := store.Read()
	answered := make(chan error, 1)
	go func() {
		answered <- h.Respond(ctx, model.RespondRequest{ExecutionID: "execution", InteractionID: interaction.ID, ActionID: "submit", Answers: map[string]json.RawMessage{"answer": json.RawMessage(`"answer"`)}})
	}()
	for _, ready := range []<-chan struct{}{input.written, dispatchStarted} {
		select {
		case <-ready:
		case <-ctx.Done():
			t.Fatal("native answer/settlement did not cross the process pipes")
		}
	}
	// Make the native request's real timer fire while its answer is in flight.
	// Stop in Respond must tolerate a callback that has already been queued.
	timer.Reset(0)
	select {
	case <-dispatchDone:
		t.Fatal("settlement overtook the complete answer's local commit")
	case err := <-answered:
		t.Fatalf("expiry retired an in-flight answer: %v", err)
	case <-time.After(25 * time.Millisecond):
	}
	if timer.Stop() {
		t.Fatal("interaction expiry did not fire during the paused write")
	}
	if !bytes.Equal(before, store.Read()) {
		t.Fatalf("native completion changed the pending interaction before write return: %s", store.Read())
	}
	input.release()
	select {
	case err := <-answered:
		if err != nil {
			t.Fatal(err)
		}
	case <-ctx.Done():
		t.Fatal("answer did not return after releasing the complete write")
	}
	store.waitExecution(t, ctx, "execution", "completed")
	if err := h.Send(ctx, plugin.SendRequest{ExecutionID: "successor", Input: model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "ask"}}}}); err != nil {
		t.Fatal(err)
	}
	store.waitExecution(t, ctx, "successor", "waiting-for-user")
	before = store.Read()
	h.expireInteraction("execution", interaction.ID)
	if !bytes.Equal(before, store.Read()) {
		t.Fatal("an expired old interaction changed its successor")
	}
}

func TestInteractionAnswerBackpressureCanBeRetired(t *testing.T) {
	for _, action := range []string{"interrupt", "close"} {
		t.Run(action, func(t *testing.T) {
			ctx, h, store, interaction := openInteractionPeer(t, "backpressure")
			prefixReceived := make(chan struct{})
			unsubscribe := h.rpc.rpc.subscribe(func(frame map[string]any) {
				if frame["message"] == "answer-prefix-received" {
					close(prefixReceived)
				}
			})
			defer unsubscribe()
			answer, _ := json.Marshal(strings.Repeat("x", maxRPCLineBytes))
			answered := make(chan error, 1)
			go func() {
				answered <- h.Respond(ctx, model.RespondRequest{ExecutionID: "execution", InteractionID: interaction.ID, ActionID: "submit", Answers: map[string]json.RawMessage{"answer": answer}})
			}()
			select {
			case <-prefixReceived:
			case <-ctx.Done():
				t.Fatal("native process did not accept the partial answer")
			}
			retired := make(chan error, 1)
			go func() {
				if action == "close" {
					retired <- h.Close()
				} else {
					retired <- h.Interrupt(ctx)
				}
			}()
			select {
			case err := <-answered:
				if err == nil {
					t.Fatal("partial answer succeeded")
				}
			case <-ctx.Done():
				t.Fatal("retiring the connection did not unblock its answer write")
			}
			select {
			case err := <-retired:
				if err != nil {
					t.Fatal(err)
				}
			case <-ctx.Done():
				t.Fatal("retiring the connection waited on its blocked event dispatcher")
			}
			store.waitExecution(t, ctx, "execution", "interrupted")
		})
	}
}
