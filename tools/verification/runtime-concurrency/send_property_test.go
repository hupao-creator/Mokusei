package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"sync"
	"testing"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	core "github.com/hupao-creator/Mokusei/internal/core/runtime"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"pgregory.net/rapid"
)

// Generated schedules drive the public Runtime + real SQLite. The scripted
// Harness controls the native-completion/send-return boundary; it does not
// implement the host's admission, retry, cancellation or settlement logic.
type propertyHarness struct {
	*harness
	mu       sync.Mutex
	schedule string
	outcome  string
	calls    int
	entered  chan struct{}
}

func (h *propertyHarness) Open(ctx context.Context, open plugin.OpenContext) (plugin.Handle, error) {
	return &propertyHandle{handle: &handle{open: open, ctx: ctx}, peer: h}, nil
}

type propertyHandle struct {
	*handle
	peer *propertyHarness
}

func (h *propertyHandle) Send(ctx context.Context, request plugin.SendRequest) error {
	h.peer.mu.Lock()
	schedule, outcome, entered := h.peer.schedule, h.peer.outcome, h.peer.entered
	h.peer.schedule = "accept" // A safe retry must use a new reservation.
	h.peer.calls++
	h.peer.mu.Unlock()
	var current state
	if b := h.open.SessionState.Read(); !model.IsNull(b) {
		if err := json.Unmarshal(b, &current); err != nil {
			return err
		}
	}
	active := current.Observation.LatestExecution != nil && !current.Observation.LatestExecution.Terminal()
	if active && (schedule == "end" || schedule == "end-reject" || schedule == "end-failure" || schedule == "end-cancel") {
		at := time.Now().UnixMilli()
		current.Observation.LatestExecution.Status = outcome
		current.Observation.LatestExecution.FinishedAt = &at
		if err := h.open.SessionState.Commit(ctx, raw(current)); err != nil {
			return err
		}
	}
	switch schedule {
	case "reject", "end-reject":
		return errors.New("native rejected this input")
	case "end-failure":
		return errors.Join(errors.New("native execution failed"), plugin.ErrExecutionEnded)
	case "end-cancel":
		close(entered)
		<-ctx.Done()
		return plugin.ErrExecutionEnded
	case "end":
		if active {
			return plugin.ErrExecutionEnded
		}
	case "invalid-retry":
		// A broken peer cannot authorize a retry without a durable terminal.
		return plugin.ErrExecutionEnded
	case "admitted-failure":
		if err := h.handle.Send(ctx, request); err != nil {
			return err
		}
		return errors.New("native dispatch failed after admission")
	}
	return h.handle.Send(ctx, request)
}

func TestSendAdmissionProperties(t *testing.T) {
	rapid.Check(t, func(t *rapid.T) {
		trace := rapid.SliceOfN(rapid.SampledFrom([]string{
			"accept", "reject", "end", "end-reject", "end-failure", "end-cancel", "invalid-retry", "admitted-failure",
		}), 1, 25).Draw(t, "schedule")
		outcomes := rapid.SliceOfN(rapid.SampledFrom([]string{"completed", "failed", "interrupted"}), len(trace), len(trace)).Draw(t, "outcomes")
		root, err := os.MkdirTemp("", "mokusei-send-pbt-")
		if err != nil {
			t.Fatal(err)
		}
		defer os.RemoveAll(root)
		db, err := store.Open(filepath.Join(root, "state.sqlite"))
		if err != nil {
			t.Fatal(err)
		}
		defer db.Close()
		peer := &propertyHarness{harness: &harness{}, schedule: "accept"}
		r, err := core.New(context.Background(), core.Config{Store: db, Harnesses: map[string]plugin.Harness{"fixture": peer}, DataDir: root, DefaultCwd: root})
		if err != nil {
			t.Fatal(err)
		}
		defer r.Close(context.Background())
		created, err := create(r)
		if err != nil {
			t.Fatal(err)
		}
		id := created.Record.ID
		// Closing the scripted owner joins all send workers without changing its
		// durable state. Each next action reopens the same SQLite conversation.
		if err = r.CloseMokuThread(context.Background(), id); err != nil {
			t.Fatal(err)
		}
		accepted := 1
		for index, schedule := range trace {
			before, err := r.Thread(id)
			if err != nil {
				t.Fatal(err)
			}
			old := before.Observation.LatestExecution
			active := old != nil && !old.Terminal()
			peer.mu.Lock()
			peer.schedule, peer.outcome, peer.calls = schedule, outcomes[index], 0
			peer.entered = make(chan struct{})
			entered := peer.entered
			peer.mu.Unlock()
			ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
			if schedule == "end-cancel" {
				go func() {
					select {
					case <-entered:
						cancel()
					case <-ctx.Done():
					}
				}()
			}
			result, sendErr := r.SendThread(ctx, id, model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: fmt.Sprintf("input-%d", index)}}})
			cancel()
			if err := r.CloseMokuThread(context.Background(), id); err != nil {
				t.Fatal(err)
			}
			after, err := r.Thread(id)
			if err != nil {
				t.Fatal(err)
			}
			success := schedule == "accept" || schedule == "end" || schedule == "admitted-failure"
			if (sendErr == nil) != success {
				t.Logf("step %d %s: success=%v, result=%+v error=%v", index, schedule, success, result, sendErr)
				t.Fatal("input acknowledgement disagrees with native acceptance")
			}
			wantCalls := 1
			if schedule == "end" && active {
				wantCalls = 2
			}
			peer.mu.Lock()
			calls := peer.calls
			peer.mu.Unlock()
			if calls != wantCalls {
				t.Logf("step %d %s: %d native attempts, want %d", index, schedule, calls, wantCalls)
				t.Fatal("unsafe or missing native retry")
			}
			now := after.Observation.LatestExecution
			if success {
				accepted++
				wantNew := !active || schedule == "end"
				wantStatus := "running"
				if schedule == "admitted-failure" && wantNew {
					wantStatus = "failed"
				}
				if result.StartedNewExecution != wantNew || (result.ExecutionID != old.ExecutionID) != wantNew || now.ExecutionID != result.ExecutionID || now.Status != wantStatus {
					t.Logf("step %d %s: before=%+v result=%+v after=%+v", index, schedule, old, result, now)
					t.Fatal("incorrect admission identity or outcome")
				}
			} else if active && (schedule == "end-reject" || schedule == "end-failure" || schedule == "end-cancel") {
				if now.ExecutionID != old.ExecutionID || now.Status != outcomes[index] || now.StartedAt != old.StartedAt {
					t.Logf("step %d %s: before=%+v after=%+v", index, schedule, old, now)
					t.Fatal("send failure changed native terminal")
				}
			} else if !reflect.DeepEqual(old, now) {
				// Keep fatal messages stable: UUIDs/timestamps in the failure
				// fingerprint prevent Rapid from recognizing and shrinking it.
				t.Logf("step %d %s: before=%+v after=%+v", index, schedule, old, now)
				t.Fatal("rejected input changed original execution")
			}
			events, err := db.Snapshot().Events()
			if err != nil {
				t.Fatal(err)
			}
			count := 0
			for _, event := range events {
				if event.Subject.ID == id && event.Type == "thread.input-accepted" {
					count++
				}
			}
			if count != accepted {
				t.Logf("step %d %s: %d acknowledgements, want %d", index, schedule, count, accepted)
				t.Fatal("input acknowledgement duplicated or lost")
			}
		}
	})
}
