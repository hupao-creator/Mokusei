package main

import (
	"fmt"
	"reflect"
	"testing"

	"github.com/hupao-creator/Mokusei/internal/plugins/harness/codex"
	"pgregory.net/rapid"
)

func TestCodexTerminalProperties(t *testing.T) {
	rapid.Check(t, func(t *rapid.T) {
		state := codex.EmptyState(1)
		terminals := map[string]object{}
		ids := []string{}
		at := int64(2)
		message := rapid.StringOfN(rapid.SampledFrom([]rune{'a', '中', '🙂', '\n'}), 0, 32, 128)
		t.Repeat(map[string]func(*rapid.T){
			"start": func(t *rapid.T) {
				last := codex.LatestTurn(state)
				if last != nil && (last["status"] == "running" || last["status"] == "waiting-input") {
					t.Skip("current execution is active")
				}
				if len(ids) >= 100 {
					t.Skip("bounded retained history")
				}
				id := fmt.Sprintf("execution-%d", len(ids))
				var err error
				state, err = codex.StageExecutionChecked(state, id, object{"parts": []any{object{"kind": "text", "text": message.Draw(t, "input")}}}, at, nil)
				if err != nil {
					t.Fatal(err)
				}
				ids = append(ids, id)
				at++
			},
			"event": func(t *rapid.T) {
				if len(ids) == 0 {
					t.Skip("no execution")
				}
				id := rapid.SampledFrom(ids).Draw(t, "execution")
				kind := rapid.SampledFrom([]string{"text-delta", "text-final", "status", "done", "error"}).Draw(t, "event")
				event := object{"type": kind, "at": at, "itemId": "answer", "delta": message.Draw(t, "delta"), "text": message.Draw(t, "text"), "label": "working", "message": "native error", "outcome": rapid.SampledFrom([]string{"completed", "failed", "interrupted"}).Draw(t, "outcome")}
				state = codex.ReduceEvent(state, id, event)
				at++
			},
			"follow-up": func(t *rapid.T) {
				if len(ids) == 0 {
					t.Skip("no execution")
				}
				id := rapid.SampledFrom(ids).Draw(t, "execution")
				state = codex.AppendFollowUp(state, id, object{"parts": []any{object{"kind": "text", "text": message.Draw(t, "follow-up")}}}, at, fmt.Sprintf("input-%d", at))
				at++
			},
			"rejection": func(t *rapid.T) {
				if len(ids) == 0 {
					t.Skip("no execution")
				}
				id := rapid.SampledFrom(ids).Draw(t, "execution")
				noticeCount := func() int {
					for _, value := range list(state["turns"]) {
						turn := record(value)
						if turn["executionId"] == id {
							return len(list(turn["notices"]))
						}
					}
					return 0
				}
				before := noticeCount()
				state = codex.RejectFollowUp(state, id, message.Draw(t, "rejection"), at, fmt.Sprintf("notice-%d", at))
				at++
				if noticeCount() != before+1 {
					t.Fatal("rejected follow-up lost its audit notice")
				}
			},
			"settle": func(t *rapid.T) {
				if len(ids) == 0 {
					t.Skip("no execution")
				}
				id := rapid.SampledFrom(ids).Draw(t, "execution")
				state = codex.SettleExecution(state, id, rapid.SampledFrom([]string{"completed", "failed", "interrupted"}).Draw(t, "outcome"), at, "")
				at++
			},
			"": func(t *rapid.T) {
				if _, err := codex.DecodeState(state); err != nil {
					t.Fatalf("generated event order produced invalid durable state: %v", err)
				}
				for _, id := range ids {
					execution := codex.ResolveExecution(state, id)
					if canonical := terminals[id]; canonical != nil {
						if !reflect.DeepEqual(canonical, execution) {
							t.Logf("terminal %s: before=%v after=%v", id, canonical, execution)
							t.Fatal("terminal execution changed")
						}
					} else if execution["status"] == "completed" || execution["status"] == "failed" || execution["status"] == "interrupted" {
						terminals[id] = execution
					}
				}
			},
		})
	})
}
