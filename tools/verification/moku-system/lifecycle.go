package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
)

func findThread(state model.AppState, id string) (model.ThreadRecord, bool) {
	for _, t := range state.Threads {
		if t.ID == id {
			return t, true
		}
	}
	return model.ThreadRecord{}, false
}
func ordinary(state model.AppState) []model.ThreadRecord {
	out := []model.ThreadRecord{}
	for _, t := range state.Threads {
		if !t.Moku {
			out = append(out, t)
		}
	}
	return out
}
func reportCount(state model.AppState) int {
	n := 0
	for _, a := range state.ApplicationThreads {
		if a.Ref.TypeID == "report.document" {
			n++
		}
	}
	return n
}
func waitState(ctx context.Context, invoke systemInvoke, mock *provider, ready func(model.AppState) bool) (model.AppState, error) {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	var state model.AppState
	for {
		mock.mu.Lock()
		failures := append([]string{}, mock.failures...)
		mock.mu.Unlock()
		if len(failures) > 0 {
			return state, fmt.Errorf("mock/oracle failure: %v", failures)
		}
		// An empty optional collection is omitted from the wire snapshot. Decode
		// into a fresh value so completed agent runs cannot survive from a poll.
		var next model.AppState
		if err := invoke("state:load", []any{}, &next); err != nil {
			return state, err
		}
		state = next
		if ready(state) {
			return state, nil
		}
		select {
		case <-ctx.Done():
			return state, fmt.Errorf("state did not converge: ordinary=%d reports=%d agents=%d: %w", len(ordinary(state)), reportCount(state), len(state.AgentRuns), ctx.Err())
		case <-time.After(25 * time.Millisecond):
		}
	}
}

// A bounded public quiescence observation, not a promise that every durable
// consumer inbox has been drained. Three consecutive snapshots and no live model
// request prevent accepting a transient gap between native turns.
func settleSystem(ctx context.Context, invoke systemInvoke, mock *provider, ready func(model.AppState) bool) (model.AppState, error) {
	quiet := 0
	return waitState(ctx, invoke, mock, func(s model.AppState) bool {
		mock.mu.Lock()
		active := mock.activeRequests
		mock.mu.Unlock()
		if active != 0 || !ready(s) || len(s.AgentRuns) != 0 {
			quiet = 0
			return false
		}
		for _, t := range s.Threads {
			if e := t.Observation.LatestExecution; e != nil && !e.Terminal() {
				quiet = 0
				return false
			}
		}
		var pending []any
		if invoke("moku:deliveries", []any{}, &pending) != nil || len(pending) != 0 {
			quiet = 0
			return false
		}
		quiet++
		return quiet >= 3
	})
}

func unchangedSource(host actionHost, before model.ThreadRecord) error {
	after, e := host.Thread(before.ID)
	if e != nil {
		return e
	}
	if !bytes.Equal(before.SessionState, after.SessionState) || !bytes.Equal(before.Settings, after.Settings) || !bytes.Equal(encoded(before.Observation), encoded(after.Observation)) {
		return errors.New("operation mutated source native history/settings/observation")
	}
	return nil
}
func exerciseLifecycle(ctx context.Context, invoke systemInvoke, host actionHost, mock *provider, state model.AppState, action string, index int) (model.AppState, error) {
	children := ordinary(state)
	if action == "recreate" {
		if len(children) != 0 || len(state.ApplicationThreads) != 0 {
			return state, errors.New("recreate requires empty history")
		}
		return startChain(ctx, invoke, mock)
	}
	if strings.HasSuffix(action, "-active") {
		return activeRemoval(ctx, invoke, host, mock, state, action, index)
	}
	if action == "clear" {
		settings, revision := encoded(state.Settings), state.SettingsRevision
		if err := invoke("history:clear", []any{}, nil); err != nil {
			return state, err
		}
		next, err := settleSystem(ctx, invoke, mock, func(s model.AppState) bool { return len(ordinary(s)) == 0 && len(s.ApplicationThreads) == 0 })
		if err != nil {
			return next, err
		}
		if !bytes.Equal(settings, encoded(next.Settings)) || revision != next.SettingsRevision {
			return next, errors.New("clear changed settings")
		}
		for _, old := range children {
			if _, e := host.Thread(old.ID); e == nil || !strings.Contains(e.Error(), "unknown thread: "+old.ID) {
				return next, fmt.Errorf("clear did not remove source: %v", e)
			}
			var answer string
			if e := invoke("thread:read", []any{object{"threadId": old.ID, "question": "old generation"}}, &answer); e == nil || !strings.Contains(e.Error(), "unknown thread: "+old.ID) {
				return next, fmt.Errorf("old source read not rejected after clear: %v", e)
			}
		}
		for _, t := range next.Threads {
			if t.Note != nil {
				return next, errors.New("clear retained Moku note")
			}
		}
		fmt.Println("PASS history clear: settings retained; task/report/note/outbox removed; stale reads rejected")
		return next, nil
	}
	if len(children) == 0 {
		return state, fmt.Errorf("%s requires a source", action)
	}
	source, err := host.Thread(children[0].ID)
	if err != nil {
		return state, err
	}
	if action == "delete" {
		if err = host.DeleteThread(ctx, source.ID); err != nil {
			return state, err
		}
		next, e := settleSystem(ctx, invoke, mock, func(s model.AppState) bool { _, exists := findThread(s, source.ID); return !exists })
		if e != nil {
			return next, e
		}
		if len(ordinary(next)) != len(children)-1 || reportCount(next) != reportCount(state) {
			return next, errors.New("delete changed unrelated task/report count")
		}
		var answer string
		if e = invoke("thread:read", []any{object{"threadId": source.ID, "question": "deleted source"}}, &answer); e == nil || !strings.Contains(e.Error(), "unknown thread: "+source.ID) {
			return next, fmt.Errorf("deleted source read not rejected: %v", e)
		}
		fmt.Println("PASS Runtime delete: source gone, reports retained, stale read rejected")
		return next, nil
	}
	if source.Archived != nil && *source.Archived {
		channel, args := "thread:follow-up", []any{object{"threadId": source.ID, "input": object{"parts": []any{object{"kind": "text", "text": "must reject archived source"}}}}}
		expected := "thread is archived"
		if action == "fork" {
			channel, args = "thread:fork", []any{object{"threadId": source.ID, "request": object{}}}
			expected = "thread is not available for fork"
		}
		if e := invoke(channel, args, nil); e == nil || !strings.Contains(e.Error(), expected) {
			return state, fmt.Errorf("archived source work not rejected: %v", e)
		}
		return state, unchangedSource(host, source)
	}
	if action == "fork" {
		var fork struct{ ThreadID string }
		if e := invoke("thread:fork", []any{object{"threadId": source.ID, "request": object{}}}, &fork); e != nil {
			return state, e
		}
		derived, e := host.Thread(fork.ThreadID)
		if e != nil {
			return state, e
		}
		mock.registerChild(derived.ID, derived.Cwd)
		var oldNative, newNative object
		if e = json.Unmarshal(source.SessionState, &oldNative); e != nil {
			return state, e
		}
		if e = json.Unmarshal(derived.SessionState, &newNative); e != nil {
			return state, e
		}
		if derived.ID == source.ID || newNative["primarySessionId"] == oldNative["primarySessionId"] || text(newNative["primarySessionId"]) == "" {
			return state, errors.New("fork reused native/host identity")
		}
		var answer string
		if e = invoke("thread:read", []any{object{"threadId": derived.ID, "question": "What is the exact SYSTEM_CHAIN_CHILD result?"}}, &answer); e != nil {
			return state, e
		}
		if answer != "SYSTEM_CHILD_DONE" {
			return state, fmt.Errorf("fork history answer: %q", answer)
		}
		if e = unchangedSource(host, source); e != nil {
			return state, e
		}
		next, e := settleSystem(ctx, invoke, mock, func(s model.AppState) bool { return len(ordinary(s)) == len(children)+1 })
		if e != nil {
			return next, e
		}
		if reportCount(next) != reportCount(state) {
			return next, errors.New("fork fabricated a completed execution/report")
		}
		fmt.Println("PASS fork: independent native identity and inherited read; source unchanged")
		return next, nil
	}
	input := fmt.Sprintf("SYSTEM_CHAIN_CHILD: followup action %d; reply SYSTEM_CHILD_DONE", index)
	var gate *responseBarrier
	if action == "interrupt" {
		marker := fmt.Sprintf("SYSTEM_HOLD_%d_END", index)
		gate = mock.armBarrier(marker)
		defer gate.unblock()
		input += " " + marker
	}
	var receipt struct {
		ExecutionID         string
		StartedNewExecution bool
	}
	if err = invoke("thread:follow-up", []any{object{"threadId": source.ID, "input": object{"parts": []any{object{"kind": "text", "text": input}}}}}, &receipt); err != nil {
		return state, err
	}
	if receipt.ExecutionID == "" || !receipt.StartedNewExecution || (source.Observation.LatestExecution != nil && receipt.ExecutionID == source.Observation.LatestExecution.ExecutionID) {
		return state, errors.New("followup did not reserve fresh execution")
	}
	if action == "interrupt" {
		select {
		case <-gate.entered:
		case <-ctx.Done():
			return state, ctx.Err()
		}
		current, e := host.Thread(source.ID)
		if e != nil {
			return state, e
		}
		if current.CancellationID == "" || current.CancellationID == source.CancellationID {
			return state, errors.New("followup reused cancellation generation")
		}
		if source.CancellationID != "" {
			var stale model.CancellationResult
			if e = invoke("thread:interrupt", []any{object{"threadId": source.ID, "expectedCancellationId": source.CancellationID}}, &stale); e != nil {
				return state, e
			}
			if stale.Status != "stale" {
				return state, fmt.Errorf("stale cancellation affected successor: %s", stale.Status)
			}
		}
		var result model.CancellationResult
		if e = invoke("thread:interrupt", []any{object{"threadId": source.ID, "expectedCancellationId": current.CancellationID}}, &result); e != nil {
			return state, e
		}
		if result.Status != "cancelled" {
			return state, fmt.Errorf("active cancellation failed: %s", result.Status)
		}
		next, e := waitState(ctx, invoke, mock, func(s model.AppState) bool {
			t, ok := findThread(s, source.ID)
			return ok && t.Observation.LatestExecution != nil && t.Observation.LatestExecution.ExecutionID == receipt.ExecutionID && t.Observation.LatestExecution.Status == "interrupted"
		})
		if e != nil {
			return next, e
		}
		gate.unblock()
		select {
		case <-gate.finished:
		case <-ctx.Done():
			return next, ctx.Err()
		}
		next, e = settleSystem(ctx, invoke, mock, func(s model.AppState) bool {
			t, ok := findThread(s, source.ID)
			return ok && t.Observation.LatestExecution != nil && t.Observation.LatestExecution.ExecutionID == receipt.ExecutionID && t.Observation.LatestExecution.Status == "interrupted"
		})
		if e != nil {
			return next, e
		}
		if reportCount(next) != reportCount(state) {
			return next, errors.New("interrupted execution produced Report")
		}
		fmt.Printf("PASS interrupt: active model request fenced, late response released, no new Report (%s)\n", result.Status)
		return next, nil
	}
	next, e := settleSystem(ctx, invoke, mock, func(s model.AppState) bool {
		t, ok := findThread(s, source.ID)
		return ok && t.Observation.LatestExecution != nil && t.Observation.LatestExecution.ExecutionID == receipt.ExecutionID && t.Observation.LatestExecution.Status == "completed" && reportCount(s) >= reportCount(state)+1
	})
	if e != nil {
		return next, e
	}
	if reportCount(next) != reportCount(state)+1 {
		return next, errors.New("followup produced duplicate reports")
	}
	linked := 0
	for _, report := range next.ApplicationThreads {
		if report.Ref.TypeID != "report.document" {
			continue
		}
		var view struct {
			Related []model.ExecutionRef `json:"relatedExecutions"`
		}
		if e = json.Unmarshal(report.View, &view); e != nil {
			return next, e
		}
		for _, ref := range view.Related {
			if ref.ExecutionID == receipt.ExecutionID && ref.Thread.ThreadID == source.ID {
				linked++
			}
		}
	}
	if linked != 1 {
		return next, errors.New("followup Report has wrong execution provenance")
	}
	fmt.Println("PASS followup: successor identity, terminal fanout and exactly one new Report")
	return next, nil
}
