// Integration replay of the production metadata policy and its public stores.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

type memoryStore struct {
	mu       sync.Mutex
	snapshot plugin.MetadataSnapshot
	updates  chan struct{}
}

func (s *memoryStore) Read() plugin.MetadataSnapshot {
	s.mu.Lock()
	defer s.mu.Unlock()
	return plugin.MetadataSnapshot{Revision: s.snapshot.Revision, State: append(json.RawMessage(nil), s.snapshot.State...)}
}
func (s *memoryStore) Commit(ctx context.Context, revision int64, state json.RawMessage) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := ctx.Err(); err != nil {
		return false, err
	}
	if revision != s.snapshot.Revision {
		return false, nil
	}
	s.snapshot = plugin.MetadataSnapshot{Revision: revision + 1, State: append(json.RawMessage(nil), state...)}
	select {
	case s.updates <- struct{}{}:
	default:
	}
	return true, nil
}
func (s *memoryStore) fields() map[string]json.RawMessage {
	var f map[string]json.RawMessage
	must(json.Unmarshal(s.Read().State, &f))
	return f
}
func (s *memoryStore) title() string {
	var v string
	must(json.Unmarshal(s.fields()["title"], &v))
	return v
}
func (s *memoryStore) wait(title string) {
	deadline := time.NewTimer(5 * time.Second)
	defer deadline.Stop()
	for s.title() != title {
		select {
		case <-s.updates:
		case <-deadline.C:
			panic("title never became " + title + ": " + string(s.Read().State))
		}
	}
}

type nativeHandle struct{ reject bool }

func (h *nativeHandle) Send(context.Context, plugin.SendRequest) error {
	if h.reject {
		return errors.New("rejected")
	}
	return nil
}
func (*nativeHandle) Interrupt(context.Context) error                     { return nil }
func (*nativeHandle) Close() error                                        { return nil }
func (*nativeHandle) Respond(context.Context, model.RespondRequest) error { return nil }
func (*nativeHandle) Read(context.Context, string) (string, error)        { return "", nil }

type completer func(context.Context, plugin.PromptRequest, json.RawMessage) (plugin.PromptResult, error)

func open(s *memoryStore, c completer) plugin.Handle {
	return plugin.WithGeneratedThreadMetadata(context.Background(), plugin.OpenContext{ThreadID: "fixture", Metadata: s, ReadThread: func() model.SessionRecord {
		return model.SessionRecord{ID: "fixture", HarnessID: "fixture", Settings: json.RawMessage(`{}`)}
	}}, &nativeHandle{}, c)
}
func store() *memoryStore {
	raw, err := (plugin.GeneratedThreadMetadata{}).Initialize("fixture", input("initial task"), nil)
	must(err)
	return &memoryStore{snapshot: plugin.MetadataSnapshot{State: raw}, updates: make(chan struct{}, 1)}
}
func input(text string) model.AgentInput {
	return model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: text}}}
}
func send(h plugin.Handle, text string) {
	must(h.Send(context.Background(), plugin.SendRequest{ExecutionID: "exec", Input: input(text)}))
}
func answer(title string) plugin.PromptResult {
	raw, _ := json.Marshal(map[string]string{"title": title, "emoji": "🔧"})
	return plugin.PromptResult{Output: plugin.PromptOutput{Type: "json", Value: raw}}
}
func must(err error) {
	if err != nil {
		panic(err)
	}
}
func check(ok bool, message string) {
	if !ok {
		panic(message)
	}
}
func receive[T any](c <-chan T) T {
	select {
	case v := <-c:
		return v
	case <-time.After(5 * time.Second):
		panic("replay timed out")
	}
}
func main() {
	initialIntent()
	admission()
	updates()
	cancelActive()
	newInputDuringBackoff()
	boundary()
	retry()
	cancelBackoff()
	exhausted()
	invalid()
	rejection()
	fmt.Println("PASS metadata: admission receipts, dispatch failures, later messages, native steer, boundary replay, bounded retries/reopen, cancellation, invalid output and rejected sends")
}
func updates() {
	s := store()
	var calls atomic.Int32
	prompts := make(chan plugin.PromptRequest, 4)
	steered := make(chan string, 4)
	release := make(chan struct{}, 4)
	h := open(s, func(ctx context.Context, r plugin.PromptRequest, _ json.RawMessage) (plugin.PromptResult, error) {
		n := calls.Add(1)
		r.Steering.Bind(func(_ context.Context, text string) error { steered <- text; return nil })
		prompts <- r
		select {
		case <-ctx.Done():
			return plugin.PromptResult{}, ctx.Err()
		case <-release:
		}
		return answer(fmt.Sprintf("Updated task %d", n)), nil
	})
	defer h.Close()
	send(h, "initial task")
	receive(prompts)
	send(h, "build a garden")
	text := receive(steered)
	check(strings.Contains(text, "build a garden") && strings.Contains(text, "initial task"), "steer lost latest or initial intent")
	check(calls.Load() == 1, "new input restarted an active completion")
	release <- struct{}{}
	s.wait("Updated task 1")
	send(h, "add watering")
	r := receive(prompts)
	check(strings.Contains(r.Messages[1].Content, "initial task") && strings.Contains(r.Messages[1].Content, "add watering"), "subsequent prompt lost context")
	check(s.title() == "Updated task 1", "title changed before successful replacement")
	release <- struct{}{}
	s.wait("Updated task 2")
	check(string(s.fields()["pending"]) == "null", "success left pending work")
	var emoji string
	must(json.Unmarshal(s.fields()["emoji"], &emoji))
	check(emoji == "🔧", "emoji not committed")
}
func boundary() {
	s := store()
	var calls atomic.Int32
	ready := make(chan struct{}, 1)
	release := make(chan struct{})
	h := open(s, func(ctx context.Context, r plugin.PromptRequest, _ json.RawMessage) (plugin.PromptResult, error) {
		if calls.Add(1) == 1 {
			r.Steering.End()
			ready <- struct{}{}
			select {
			case <-ctx.Done():
				return plugin.PromptResult{}, ctx.Err()
			case <-release:
			}
			return answer("Stale title"), nil
		}
		check(strings.Contains(r.Messages[1].Content, "new boundary intent"), "boundary lost pending input")
		return answer("Current title"), nil
	})
	defer h.Close()
	send(h, "initial task")
	receive(ready)
	send(h, "new boundary intent")
	close(release)
	s.wait("Current title")
	check(calls.Load() == 2, "boundary did not start exactly one fresh completion")
}
func retry() {
	s := store()
	var calls atomic.Int32
	times := make(chan time.Time, 2)
	h := open(s, func(context.Context, plugin.PromptRequest, json.RawMessage) (plugin.PromptResult, error) {
		times <- time.Now()
		if calls.Add(1) == 1 {
			return plugin.PromptResult{}, context.DeadlineExceeded
		}
		return answer("Recovered task"), nil
	})
	defer h.Close()
	send(h, "initial task")
	first := receive(times)
	second := receive(times)
	check(second.Sub(first) >= 1900*time.Millisecond, "retry skipped backoff")
	s.wait("Recovered task")
}
func cancelBackoff() {
	s := store()
	called := make(chan struct{}, 1)
	h := open(s, func(context.Context, plugin.PromptRequest, json.RawMessage) (plugin.PromptResult, error) {
		called <- struct{}{}
		return plugin.PromptResult{}, context.DeadlineExceeded
	})
	send(h, "initial task")
	receive(called)
	time.Sleep(30 * time.Millisecond)
	start := time.Now()
	must(h.Interrupt(context.Background()))
	check(time.Since(start) < time.Second, "interrupt did not cancel backoff")
	must(h.Close())
	check(string(s.fields()["pending"]) != "null", "interrupt dropped pending work")
}
func exhausted() {
	s := store()
	var calls atomic.Int32
	times := make(chan time.Time, 10)
	h := open(s, func(context.Context, plugin.PromptRequest, json.RawMessage) (plugin.PromptResult, error) {
		calls.Add(1)
		times <- time.Now()
		return plugin.PromptResult{}, errors.New("service temporarily unavailable")
	})
	send(h, "initial task")
	var previous time.Time
	for i, delay := range []time.Duration{0, 2 * time.Second, 5 * time.Second, 15 * time.Second} {
		select {
		case now := <-times:
			if i > 0 {
				check(now.Sub(previous) >= delay-100*time.Millisecond, "retry delay too short")
			}
			previous = now
		case <-time.After(delay + 5*time.Second):
			panic("missing retry")
		}
	}
	time.Sleep(100 * time.Millisecond)
	check(calls.Load() == 4, "retry budget incorrect")
	check(s.title() == "initial task", "failure replaced visible title")
	check(string(s.fields()["pending"]) != "null", "exhaustion erased pending work")
	must(h.Close())
	reopened := open(s, func(context.Context, plugin.PromptRequest, json.RawMessage) (plugin.PromptResult, error) {
		return answer("Reopened task"), nil
	})
	defer reopened.Close()
	s.wait("Reopened task")
}
func invalid() {
	s := store()
	var calls atomic.Int32
	called := make(chan struct{}, 1)
	h := open(s, func(context.Context, plugin.PromptRequest, json.RawMessage) (plugin.PromptResult, error) {
		calls.Add(1)
		called <- struct{}{}
		return answer("initial task"), nil
	})
	defer h.Close()
	send(h, "initial task")
	receive(called)
	time.Sleep(50 * time.Millisecond)
	check(calls.Load() == 1 && s.title() == "initial task" && string(s.fields()["pending"]) != "null", "invalid output should retain old title and pending")
}
func rejection() {
	s := store()
	h := plugin.WithGeneratedThreadMetadata(context.Background(), plugin.OpenContext{ThreadID: "fixture", Metadata: s, ReadThread: func() model.SessionRecord { return model.SessionRecord{} }}, &nativeHandle{reject: true}, func(context.Context, plugin.PromptRequest, json.RawMessage) (plugin.PromptResult, error) {
		panic("rejected input triggered completion")
	})
	defer h.Close()
	check(h.Send(context.Background(), plugin.SendRequest{Input: input("rejected")}) != nil, "send error swallowed")
	check(s.Read().Revision == 0, "rejected input changed metadata")
}

func cancelActive() {
	s := store()
	ready := make(chan struct{}, 1)
	steered := make(chan struct{}, 1)
	h := open(s, func(ctx context.Context, r plugin.PromptRequest, _ json.RawMessage) (plugin.PromptResult, error) {
		r.Steering.Bind(func(ctx context.Context, _ string) error { steered <- struct{}{}; <-ctx.Done(); return ctx.Err() })
		ready <- struct{}{}
		<-ctx.Done()
		return plugin.PromptResult{}, ctx.Err()
	})
	send(h, "initial task")
	receive(ready)
	send(h, "steer before interrupt")
	receive(steered)
	start := time.Now()
	must(h.Interrupt(context.Background()))
	check(time.Since(start) < time.Second, "interrupt failed to drain active steer")
	must(h.Close())
	check(s.title() == "initial task" && string(s.fields()["pending"]) != "null", "interrupt replaced title or dropped latest pending intent")
}
func newInputDuringBackoff() {
	s := store()
	failed := make(chan struct{}, 1)
	var calls atomic.Int32
	h := open(s, func(_ context.Context, r plugin.PromptRequest, _ json.RawMessage) (plugin.PromptResult, error) {
		if calls.Add(1) == 1 {
			failed <- struct{}{}
			return plugin.PromptResult{}, context.DeadlineExceeded
		}
		check(strings.Contains(r.Messages[1].Content, "changed task"), "new input during backoff was lost")
		return answer("Changed task summary"), nil
	})
	defer h.Close()
	send(h, "initial task")
	receive(failed)
	send(h, "changed task")
	s.wait("Changed task summary")
	check(calls.Load() == 2, "new input during backoff caused redundant attempts")
}
