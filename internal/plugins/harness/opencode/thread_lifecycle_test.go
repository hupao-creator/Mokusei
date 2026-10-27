package opencode

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

type threadFixtureStore struct {
	mu  sync.Mutex
	raw json.RawMessage
}

func (s *threadFixtureStore) Read() json.RawMessage {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append(json.RawMessage{}, s.raw...)
}

func (s *threadFixtureStore) Commit(ctx context.Context, raw json.RawMessage) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.raw = append(json.RawMessage{}, raw...)
	return nil
}

// Keep the actual Thread, Runtime HTTP client, bridge ownership checks and durable
// state path. Only the external native HTTP server is replaced by a local fixture.
func newThreadLifecycleFixture(t *testing.T, permissionMode string, active bool, handle func(http.ResponseWriter, *http.Request) bool) (*Thread, *Runtime, *threadFixtureStore) {
	t.Helper()
	bridge, err := NewBridge(false)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = bridge.Configure("ses_thread", BridgeConfiguration{}); err != nil {
		t.Fatal(err)
	}
	wait := make(chan struct{})
	var release sync.Once
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if handle != nil && handle(w, r) {
			return
		}
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/api/rpc/mokusei.harness/refresh":
			bridge.mu.Lock()
			revision := bridge.current["ses_thread"].revision
			bridge.mu.Unlock()
			_ = json.NewEncoder(w).Encode(Object{"output": Object{"revisions": Object{"ses_thread": revision}}})
		case "/api/session":
			_, _ = w.Write([]byte(`{"data":[]}`))
		case "/api/session/ses_thread/inbox":
			_, _ = w.Write([]byte(`[]`))
		case "/api/session/ses_thread/interrupt":
			release.Do(func() { close(wait) })
			w.WriteHeader(http.StatusNoContent)
		case "/api/experimental/session/ses_thread/wait":
			select {
			case <-wait:
			case <-r.Context().Done():
			}
			w.WriteHeader(http.StatusNoContent)
		case "/api/experimental/session/ses_thread/export":
			_, _ = w.Write([]byte(`{"info":{"id":"ses_thread"},"messages":[]}`))
		default:
			http.NotFound(w, r)
		}
	}))
	nativeLife, cancelNative := context.WithCancel(context.Background())
	runtime := &Runtime{URL: server.URL, ctx: nativeLife, cancel: cancelNative, bridge: bridge, client: server.Client(), options: Options{CWD: t.TempDir()}}
	store := &threadFixtureStore{}
	settings := Settings{PermissionMode: permissionMode}
	rawSettings, _ := json.Marshal(settings)
	thread, err := OpenThread(context.Background(), plugin.OpenContext{
		SessionState: store,
		ReadThread: func() model.SessionRecord {
			return model.SessionRecord{Cwd: runtime.options.CWD, Settings: rawSettings}
		},
	}, nil)
	if err != nil {
		cancelNative()
		_ = bridge.Close(false)
		server.Close()
		t.Fatal(err)
	}
	thread.mu.Lock()
	thread.native = runtime
	configuration, _ := json.Marshal([]any{settings, runtime.options.CWD})
	thread.configuration = string(configuration)
	thread.state.NativeSessionID = "ses_thread"
	thread.state.NativeSessionCreated = true
	thread.observed["ses_thread"] = true
	if active {
		if err = thread.state.Begin("execution_1", time.Now().UnixMilli()); err != nil {
			t.Fatal(err)
		}
		thread.state.NativeExecutions["ses_thread"] = "execution_1"
		thread.state.Messages = append(thread.state.Messages, &Message{ID: "original", NativeMessageID: "original", NativeSessionID: "ses_thread", ExecutionID: "execution_1", Role: "user", Text: "original task", Status: "complete"})
	}
	err = thread.commitLocked(context.Background())
	thread.mu.Unlock()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		// Unblock the fixture even if a regression prevents Thread.Close from
		// reaching cancellation while its reply owns the state lock.
		cancelNative()
		release.Do(func() { close(wait) })
		_ = thread.Close()
		server.Close()
	})
	return thread, runtime, store
}

func waitThreadFixture[T any](t *testing.T, channel <-chan T, description string) T {
	t.Helper()
	select {
	case value := <-channel:
		return value
	case <-time.After(3 * time.Second):
		t.Fatalf("timed out waiting for %s", description)
		var zero T
		return zero
	}
}

func TestThreadFollowupWaitsForNativeReceipt(t *testing.T) {
	for _, status := range []int{http.StatusNoContent, http.StatusConflict} {
		t.Run(http.StatusText(status), func(t *testing.T) {
			entered, release := make(chan Object, 1), make(chan struct{})
			var once sync.Once
			defer once.Do(func() { close(release) })
			thread, runtime, store := newThreadLifecycleFixture(t, "default", true, func(w http.ResponseWriter, r *http.Request) bool {
				if !strings.HasSuffix(r.URL.Path, "/prompt") {
					return false
				}
				var body Object
				if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
					http.Error(w, err.Error(), http.StatusBadRequest)
					return true
				}
				entered <- body
				select {
				case <-release:
				case <-r.Context().Done():
				}
				w.WriteHeader(status)
				return true
			})
			var admitted atomic.Int32
			done := make(chan error, 1)
			go func() {
				done <- thread.Send(context.Background(), plugin.SendRequest{ExecutionID: "execution_1", Input: model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "follow-up"}}}, Admitted: func() error {
					admitted.Add(1)
					state, err := DecodeState(store.Read())
					if err != nil {
						return err
					}
					for _, message := range state.Messages {
						if message.Text == "follow-up" {
							return nil
						}
					}
					return errors.New("admitted before durable follow-up")
				}})
			}()
			body := waitThreadFixture(t, entered, "native prompt request")
			state, err := DecodeState(store.Read())
			if err != nil {
				t.Fatal(err)
			}
			if admitted.Load() != 0 || len(state.Messages) != 1 {
				t.Fatalf("follow-up retained before native receipt: admitted=%d, messages=%d", admitted.Load(), len(state.Messages))
			}
			if status == http.StatusNoContent {
				// Native inbox evidence can arrive before its HTTP response.
				if err := thread.acceptEvent(context.Background(), Event{Type: "session.inbox.enqueued", Data: Object{"sessionID": "ses_thread", "inboxID": body["id"], "item": Object{"type": "user", "payload": Object{"text": "follow-up"}}}, Created: time.Now().UnixMilli()}, false, runtime); err != nil {
					t.Fatal(err)
				}
			}
			once.Do(func() { close(release) })
			err = waitThreadFixture(t, done, "follow-up result")
			state, decodeErr := DecodeState(store.Read())
			if decodeErr != nil {
				t.Fatal(decodeErr)
			}
			if status == http.StatusNoContent {
				if err != nil || admitted.Load() != 1 || len(state.Messages) != 2 {
					t.Fatalf("accepted follow-up: err=%v, admitted=%d, messages=%d", err, admitted.Load(), len(state.Messages))
				}
			} else if err == nil || admitted.Load() != 0 || len(state.Messages) != 1 || state.Active() == nil {
				t.Fatalf("rejected follow-up changed admission or active execution: err=%v, admitted=%d, state=%s", err, admitted.Load(), store.Read())
			}
		})
	}
}

func TestThreadInitialInputAdmitsBeforeNativeRejection(t *testing.T) {
	var admitted atomic.Int32
	thread, _, store := newThreadLifecycleFixture(t, "default", false, func(w http.ResponseWriter, r *http.Request) bool {
		if !strings.HasSuffix(r.URL.Path, "/prompt") {
			return false
		}
		if admitted.Load() != 1 {
			t.Error("initial native dispatch preceded admission")
		}
		w.WriteHeader(http.StatusConflict)
		return true
	})
	err := thread.Send(context.Background(), plugin.SendRequest{ExecutionID: "execution_1", Input: model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "initial input"}}}, Admitted: func() error { admitted.Add(1); return nil }})
	state, decodeErr := DecodeState(store.Read())
	if decodeErr != nil {
		t.Fatal(decodeErr)
	}
	if err == nil || admitted.Load() != 1 || len(state.Messages) != 1 || state.Messages[0].Text != "initial input" || state.Active() != nil {
		t.Fatalf("initial accepted input was lost after dispatch failure: err=%v, admitted=%d, state=%s", err, admitted.Load(), store.Read())
	}
}

func TestThreadStopCancelsPendingPermissionReply(t *testing.T) {
	for _, automatic := range []bool{false, true} {
		for _, closeThread := range []bool{false, true} {
			name := "manual-interrupt"
			if automatic {
				name = "automatic-interrupt"
			}
			if closeThread {
				name = strings.Replace(name, "interrupt", "close", 1)
			}
			t.Run(name, func(t *testing.T) {
				entered, cancelled := make(chan struct{}), make(chan struct{})
				var replies atomic.Int32
				mode := "default"
				if automatic {
					mode = "auto"
				}
				thread, runtime, store := newThreadLifecycleFixture(t, mode, true, func(w http.ResponseWriter, r *http.Request) bool {
					if !strings.Contains(r.URL.Path, "/permission/") {
						return false
					}
					if replies.Add(1) != 1 {
						http.Error(w, "duplicate reply", http.StatusConflict)
						return true
					}
					// HTTP/1 detects a disconnected client after the request body
					// is consumed; leave the response pending, not the body reader.
					if _, err := io.Copy(io.Discard, r.Body); err != nil {
						http.Error(w, err.Error(), http.StatusBadRequest)
						return true
					}
					close(entered)
					<-r.Context().Done()
					close(cancelled)
					return true
				})
				event := Event{Type: "permission.asked", Data: Object{"sessionID": "ses_thread", "id": "permission_1", "action": "shell", "resources": []any{"echo fixture"}}, Created: time.Now().UnixMilli()}
				response := make(chan error, 1)
				if automatic {
					if err := thread.queueEvent(runtime, event); err != nil {
						t.Fatal(err)
					}
				} else {
					if err := thread.acceptEvent(context.Background(), event, false, runtime); err != nil {
						t.Fatal(err)
					}
					state, err := DecodeState(store.Read())
					if err != nil {
						t.Fatal(err)
					}
					go func() {
						response <- thread.Respond(context.Background(), model.RespondRequest{ExecutionID: "execution_1", InteractionID: interactionID(state.Interactions[0]), ActionID: "allow"})
					}()
				}
				waitThreadFixture(t, entered, "permission reply")
				duplicate := make(chan error, 1)
				go func() {
					duplicate <- thread.Respond(context.Background(), model.RespondRequest{ExecutionID: "execution_1", InteractionID: interactionID(&Interaction{ExecutionID: "execution_1", ID: "permission_1"}), ActionID: "allow"})
				}()
				if err := waitThreadFixture(t, duplicate, "duplicate permission response"); err == nil || !strings.Contains(err.Error(), "already in progress") {
					t.Fatalf("pending native response admitted another reply: %v", err)
				}
				stopped := make(chan error, 1)
				go func() {
					if closeThread {
						stopped <- thread.Close()
					} else {
						stopped <- thread.Interrupt(context.Background())
					}
				}()
				if err := waitThreadFixture(t, stopped, "stopped thread"); err != nil {
					t.Fatal(err)
				}
				waitThreadFixture(t, cancelled, "cancelled native reply")
				if !automatic && waitThreadFixture(t, response, "cancelled response") == nil {
					t.Fatal("interrupted permission response succeeded")
				}
				state, err := DecodeState(store.Read())
				if err != nil {
					t.Fatal(err)
				}
				if state.Active() != nil || len(state.Interactions) != 1 || state.Interactions[0].Status != "cancelled" || replies.Load() != 1 {
					t.Fatalf("stopped permission was not fenced: %s", store.Read())
				}
			})
		}
	}
}

type threadFixtureLedger struct {
	recorded atomic.Int32
}

func (s *threadFixtureLedger) Read(context.Context) (json.RawMessage, error) {
	return json.RawMessage(`{}`), nil
}

func (s *threadFixtureLedger) Record(ctx context.Context, _ json.RawMessage) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	s.recorded.Add(1)
	return nil
}

func TestThreadStopCancelsUsageAttribution(t *testing.T) {
	for _, stalledPath := range []string{"message", "agent"} {
		for _, closeThread := range []bool{false, true} {
			name := stalledPath + "-interrupt"
			if closeThread {
				name = stalledPath + "-close"
			}
			t.Run(name, func(t *testing.T) {
				entered, cancelled := make(chan struct{}), make(chan struct{})
				thread, runtime, store := newThreadLifecycleFixture(t, "default", true, func(w http.ResponseWriter, r *http.Request) bool {
					message := strings.Contains(r.URL.Path, "/message/")
					agent := strings.HasPrefix(r.URL.Path, "/api/agent/")
					if !message && !agent {
						return false
					}
					if message && stalledPath == "agent" {
						_, _ = w.Write([]byte(`{"type":"assistant","agent":"fixture"}`))
						return true
					}
					close(entered)
					<-r.Context().Done()
					close(cancelled)
					return true
				})
				ledger := &threadFixtureLedger{}
				thread.mu.Lock()
				thread.open.TelemetryLedger = ledger
				thread.state.Messages = append(thread.state.Messages, &Message{ID: "assistant_1", NativeMessageID: "assistant_1", NativeSessionID: "ses_thread", ExecutionID: "execution_1", Role: "assistant", Status: "complete", Provider: "fixture", Model: "fixture", Usage: &Usage{Input: 1}})
				thread.mu.Unlock()
				if err := thread.queueEvent(runtime, Event{Type: "session.execution.succeeded", Data: Object{"sessionID": "ses_thread"}, Created: time.Now().UnixMilli()}); err != nil {
					t.Fatal(err)
				}
				waitThreadFixture(t, entered, "usage attribution")
				stopped := make(chan error, 1)
				go func() {
					if closeThread {
						stopped <- thread.Close()
					} else {
						stopped <- thread.Interrupt(context.Background())
					}
				}()
				if err := waitThreadFixture(t, stopped, "stopped usage attribution"); err != nil {
					t.Fatal(err)
				}
				waitThreadFixture(t, cancelled, "cancelled native attribution")
				state, err := DecodeState(store.Read())
				if err != nil {
					t.Fatal(err)
				}
				if ledger.recorded.Load() != 0 || len(state.UsageRecorded) != 0 {
					t.Fatalf("cancelled attribution was recorded as complete: ledger=%d state=%s", ledger.recorded.Load(), store.Read())
				}
			})
		}
	}
}
