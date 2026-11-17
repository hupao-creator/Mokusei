package codex

import (
	"encoding/json"
	"testing"
)

func TestReduceNativeTextRemovesNULBeforePersistence(t *testing.T) {
	for _, test := range []struct {
		name      string
		events    string
		answer    string
		reasoning string
	}{
		{
			name:   "assistant deltas",
			events: `[{"type":"text-delta","itemId":"message","delta":"\u0000Hel\u0000"},{"type":"text-delta","itemId":"message","delta":"lo\u0000🙂"}]`,
			answer: "Hello🙂",
		},
		{
			name:   "assistant final",
			events: `[{"type":"text-final","itemId":"message","text":"\u0000Hello\u0000🙂"}]`,
			answer: "Hello🙂",
		},
		{
			name:   "streamed then final",
			events: `[{"type":"text-delta","itemId":"message","delta":"\u0000partial"},{"type":"text-final","itemId":"message","text":"Final\u0000 answer"}]`,
			answer: "Final answer",
		},
		{
			name:      "reasoning deltas",
			events:    `[{"type":"reasoning-delta","delta":"\u0000Think"},{"type":"reasoning-delta","delta":"\u0000ing🙂"},{"type":"reasoning-delta","delta":"\u0000"}]`,
			reasoning: "Thinking🙂",
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			state, err := StageExecutionChecked(EmptyState(1), "execution", Map{"parts": []any{Map{"kind": "text", "text": "prompt"}}}, 2, nil)
			if err != nil {
				t.Fatal(err)
			}
			var events []Map
			if err := json.Unmarshal([]byte(test.events), &events); err != nil {
				t.Fatal(err)
			}
			for i, event := range events {
				event["at"] = i + 3
				state = ReduceEvent(state, "execution", event)
				state, err = DecodeState(state)
				if err != nil {
					t.Fatalf("event %d cannot be persisted: %v", i, err)
				}
			}
			turn := LatestTurn(state)
			if turn["answer"] != test.answer || turn["reasoning"] != test.reasoning {
				t.Fatalf("unexpected text projections: answer=%q reasoning=%q", turn["answer"], turn["reasoning"])
			}
			if test.answer != "" && obj(turn["lastAssistantMessage"])["text"] != test.answer {
				t.Fatalf("assistant snapshot differs from answer: %#v", turn["lastAssistantMessage"])
			}
			if test.reasoning != "" && obj(turn["foreground"])["text"] != test.reasoning {
				t.Fatalf("live reasoning differs from persisted reasoning: %#v", turn["foreground"])
			}
			state = ReduceEvent(state, "execution", Map{"type": "done", "outcome": "completed", "at": len(events) + 3})
			if _, err := DecodeState(state); err != nil {
				t.Fatalf("terminal state cannot be persisted: %v", err)
			}
			if LatestTurn(state)["status"] != "completed" {
				t.Fatal("native text prevented execution settlement")
			}
		})
	}
}

func TestReasoningAggregateSeparatesWorkBoundariesAndExecutions(t *testing.T) {
	state := StageExecution(EmptyState(1), "execution", Map{"parts": []any{Map{"kind": "text", "text": "prompt"}}}, 2, nil)
	for _, event := range []Map{
		{"type": "reasoning-delta", "delta": "First", "newSegment": true, "at": 3},
		{"type": "reasoning-delta", "delta": " paragraph", "at": 4},
		{"type": "activity-start", "activity": Map{"id": "tool", "kind": "command", "label": "command"}, "at": 5},
		{"type": "reasoning-delta", "delta": "Second paragraph", "newSegment": true, "at": 6},
	} {
		state = ReduceEvent(state, "execution", event)
	}
	turn := LatestTurn(state)
	if turn["reasoning"] != "First paragraph\n\nSecond paragraph" || obj(turn["foreground"])["text"] != "Second paragraph" {
		t.Fatalf("work boundary lost or foreground borrowed earlier work: %#v", turn)
	}
	state = ReduceEvent(state, "execution", Map{"type": "done", "outcome": "completed", "at": 7})
	state = StageExecution(state, "successor", Map{"parts": []any{Map{"kind": "text", "text": "next"}}}, 8, nil)
	state = ReduceEvent(state, "successor", Map{"type": "reasoning-delta", "delta": "New execution", "newSegment": true, "at": 9})
	if LatestTurn(state)["reasoning"] != "New execution" {
		t.Fatalf("reasoning crossed an execution boundary: %#v", LatestTurn(state))
	}
	if _, err := DecodeState(state); err != nil {
		t.Fatal(err)
	}
}
