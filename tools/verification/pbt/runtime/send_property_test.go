package runtime_test

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	core "github.com/hupao-creator/Mokusei/internal/core/runtime"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/tools/verification/pbt/rapidcheck"
	"pgregory.net/rapid"
)

// Generated schedules drive the public Runtime + real SQLite. The scripted
// Harness controls the native-completion/send-return boundary; it does not
// implement the host's admission, retry, cancellation or settlement logic.
type propertyHarness struct {
	*harness
	mu             sync.Mutex
	schedule       string
	outcome        string
	calls          int
	entered        chan struct{}
	afterInterrupt func() error
}

func (h *propertyHarness) Open(ctx context.Context, open plugin.OpenContext) (plugin.Handle, error) {
	return &propertyHandle{handle: &handle{open: open, ctx: ctx}, peer: h}, nil
}

type propertyHandle struct {
	*handle
	peer *propertyHarness
}

func (h *propertyHandle) Interrupt(ctx context.Context) error {
	if err := h.handle.Interrupt(ctx); err != nil {
		return err
	}
	if h.peer.afterInterrupt != nil {
		return h.peer.afterInterrupt()
	}
	return nil
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

// PBT-RUNTIME-ADMISSION: internal/core/runtime/README.md
func TestSendAdmissionProperties(t *testing.T) {
	rapidcheck.Check(t, func(t *rapid.T) {
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
		before, err := r.Thread(id)
		if err != nil {
			t.Fatal(err)
		}
		result, err := r.InterruptThreadFromMokuTool(context.Background(), id)
		if err != nil {
			t.Fatal(err)
		}
		after, err := r.Thread(id)
		if err != nil {
			t.Fatal(err)
		}
		old := before.Observation.LatestExecution
		if old.Status == "running" {
			now := after.Observation.LatestExecution
			if result.Status != "cancelled" || now.Status != "interrupted" || now.ExecutionID != old.ExecutionID || after.MokuInterruptedExecutionID != old.ExecutionID {
				t.Logf("request=%q before=%+v after=%+v mokuInterruptedExecutionId=%q", result.Status, old, now, after.MokuInterruptedExecutionID)
				t.Fatal("acknowledged stop lost its execution or provenance")
			}
		} else if result.Status != "stale" || after.Revision != before.Revision {
			t.Logf("request=%q before revision=%d after revision=%d", result.Status, before.Revision, after.Revision)
			t.Fatal("stop claimed or changed an already settled execution")
		}
		repeated, err := r.InterruptThreadFromMokuTool(context.Background(), id)
		if err != nil || repeated.Status != "stale" {
			t.Fatalf("duplicate stop returned %q, error %v", repeated.Status, err)
		}
		settled, err := r.Thread(id)
		if err != nil || settled.Revision != after.Revision {
			t.Fatalf("duplicate stop changed the settled record or it became unreadable: %v", err)
		}
		// All preceding terminals came from the peer or the Chief tool. Keep
		// them queued across successor runs to detect cross-execution attribution.
		for _, rejected := range []bool{true, false} {
			checkUserStopDelivery(t, r, peer, id, rejected)
		}
	})
}

func checkUserStopDelivery(t *rapid.T, r *core.Runtime, peer *propertyHarness, threadID string, rejected bool) {
	ctx := context.Background()
	request := raw(map[string]any{"threadId": threadID, "input": model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "continue"}}}})
	if _, err := r.Invoke(ctx, "thread:follow-up", []json.RawMessage{request}); err != nil {
		t.Fatal(err)
	}
	thread, err := r.Thread(threadID)
	if err != nil {
		t.Fatal(err)
	}
	executionID := thread.Observation.LatestExecution.ExecutionID
	nativeFailure := errors.New("native stop acknowledgement failed")
	peer.afterInterrupt = func() error {
		pending, err := r.ReadyMokuDeliveries()
		if err != nil {
			return err
		}
		for _, d := range pending {
			if e := d.Thread.Observation.LatestExecution; e != nil && e.ExecutionID == executionID {
				return errors.New("interrupted terminal available before Stop acknowledgement")
			}
		}
		if rejected {
			return nativeFailure
		}
		return nil
	}
	defer func() { peer.afterInterrupt = nil }()
	target := raw(model.CancellationRequest{ThreadID: threadID, ExpectedCancellationID: thread.CancellationID})
	result, err := r.Invoke(ctx, "thread:interrupt", []json.RawMessage{target})
	if rejected {
		if !errors.Is(err, nativeFailure) {
			t.Fatalf("expected native stop error, got %v", err)
		}
	} else if err != nil || result.(model.CancellationResult).Status != model.CancellationCancelled {
		t.Fatalf("user stop failed: %v, %v", result, err)
	}
	pending, err := r.ReadyMokuDeliveries()
	if err != nil {
		t.Fatal(err)
	}
	terminals, directInputs := 0, 0
	for _, d := range pending {
		if d.Lazy {
			var notice struct{ Event plugin.LifecycleEvent }
			body, ok := strings.CutPrefix(d.Notification, "Mokusei user direct-to-thread event:\n")
			if !ok || json.NewDecoder(strings.NewReader(body)).Decode(&notice) != nil {
				t.Fatal("invalid direct input notification")
			}
			var sent model.UserThreadInput
			if json.Unmarshal(notice.Event.Data, &sent) != nil {
				t.Fatal("invalid input admission")
			}
			if sent.ExecutionID == executionID {
				directInputs++
				if notice.Event.Source != "user" || notice.Event.Subject.ID != threadID || len(sent.Parts) != 1 || sent.Parts[0].Text != "continue" {
					t.Fatal("direct input lost its user or content")
				}
			}
		}
		e := d.Thread.Observation.LatestExecution
		matches := e != nil && e.ExecutionID == executionID
		if matches {
			terminals++
			if d.Lazy || e.Status != "interrupted" {
				t.Fatal("stop lost its waking interrupted terminal")
			}
		}
		if d.UserAction == nil {
			if matches && !rejected {
				t.Fatal("user Stop missing from terminal delivery")
			}
			continue
		}
		var data struct {
			ExecutionID string `json:"executionId"`
		}
		if !matches || rejected || d.UserAction.Source != "user" || d.UserAction.Type != "thread.interrupt-acknowledged" ||
			d.UserAction.Subject.ID != threadID || json.Unmarshal(d.UserAction.Data, &data) != nil || data.ExecutionID != executionID {
			t.Fatal("incorrect user attribution on pending delivery")
		}
	}
	if terminals != 1 || directInputs != 1 {
		t.Fatalf("got %d terminals and %d direct inputs, want one each", terminals, directInputs)
	}
}
