package codex

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"

	"github.com/hupao-creator/Mokusei/internal/core/model"
)

func readingFixture(t *testing.T, status string, hidden string) (Map, Map) {
	t.Helper()
	state := StageExecution(EmptyState(1), "target", Map{"parts": []any{Map{"kind": "text", "text": "HIDDEN_INITIAL_PROMPT"}}}, 2, nil)
	state = AppendFollowUp(state, "target", Map{"parts": []any{Map{"kind": "text", "text": "VISIBLE_FOLLOW_UP"}}}, 3, "follow")
	events := []Map{
		{"type": "reasoning-delta", "delta": hidden},
		{"type": "activity-start", "activity": Map{"id": "tool-1", "kind": "command", "label": "HIDDEN_TOOL_LABEL", "status": "running", "toolCall": true}},
		{"type": "activity-end", "activityId": "tool-1", "status": "completed", "detail": hidden},
		{"type": "text-final", "itemId": "hidden-interim", "text": "HIDDEN_INTERIM_REPLY"},
		{"type": "text-final", "itemId": "target-interim", "text": "VISIBLE_TARGET_REPLY"},
		{"type": "activity-start", "activity": Map{"id": "tool-2", "kind": "tool", "label": "HIDDEN_FAILED_TOOL_LABEL", "status": "running", "toolCall": true}},
		{"type": "activity-end", "activityId": "tool-2", "status": "failed", "detail": "HIDDEN_FAILED_TOOL_BODY"},
		{"type": "text-final", "itemId": "final", "text": "VISIBLE_FINAL_REPLY"},
		{"type": "warning", "message": "HIDDEN_INFO_NOTICE"},
		{"type": "error", "message": "VISIBLE_ERROR"},
		{"type": "generation-usage", "generationId": "one", "usage": Map{"reasoningOutputTokens": 4}},
		{"type": "generation-usage", "generationId": "two", "usage": Map{"reasoningOutputTokens": 6}},
	}
	for index, event := range events {
		event["at"] = 10 + index
		state = ReduceEvent(state, "target", event)
	}
	interaction, err := ParseInteraction("item/tool/requestUserInput", Map{"interactionId": "question", "isBlocking": true, "questions": []any{Map{"id": "choice", "question": "VISIBLE_PENDING_INTERACTION", "options": []any{Map{"label": "A"}}}}})
	if err != nil {
		t.Fatal(err)
	}
	state = ReduceEvent(state, "target", Map{"type": "interaction-opened", "interaction": interaction, "at": 30})
	turn := LatestTurn(state)
	timeline := stArray(turn["timeline"])
	turn["timeline"] = append(timeline, Map{"id": "failed-assistant", "kind": "assistant", "createdAt": 31, "itemId": "failed-assistant", "content": "VISIBLE_FAILED_ASSISTANT", "status": "failed"})
	turn["updatedAt"] = 31
	state["updatedAt"] = 31
	if status != "waiting-input" {
		state = SettleExecution(state, "target", status, 40, "")
	}
	return state, Map{"executionId": "target", "itemId": "target-interim"}
}

func renderReading(t *testing.T, state Map, target Map) []byte {
	t.Helper()
	raw, err := json.Marshal(state)
	if err != nil {
		t.Fatal(err)
	}
	encoded, err := (sessionStateAdapter{}).ProjectRenderer(raw, model.RendererScope{
		Kind: "turn", Key: "turn:target", Purpose: model.RendererPurposeAgentSummary,
		Target: mustJSON(t, target),
	})
	if err != nil {
		t.Fatal(err)
	}
	return encoded
}

func mustJSON(t *testing.T, value any) json.RawMessage {
	t.Helper()
	raw, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

func TestAgentReadingCodexOmitsExecutionBodies(t *testing.T) {
	for _, status := range []string{"running", "waiting-input", "completed", "failed", "interrupted"} {
		t.Run(status, func(t *testing.T) {
			state, target := readingFixture(t, status, "HIDDEN_REASONING_BODY")
			wire := renderReading(t, state, target)
			text := string(wire)
			hidden := []string{"HIDDEN_INITIAL_PROMPT", "HIDDEN_REASONING_BODY", "HIDDEN_TOOL_LABEL", "HIDDEN_TOOL_BODY", "HIDDEN_FAILED_TOOL_LABEL", "HIDDEN_FAILED_TOOL_BODY", "HIDDEN_INFO_NOTICE"}
			if status != "running" && status != "waiting-input" {
				hidden = append(hidden, "HIDDEN_INTERIM_REPLY")
			}
			for _, marker := range hidden {
				if strings.Contains(text, marker) {
					t.Fatalf("%s projection retained %q: %s", status, marker, wire)
				}
			}
			visible := []string{"VISIBLE_FOLLOW_UP", "VISIBLE_TARGET_REPLY", "VISIBLE_FINAL_REPLY", "VISIBLE_FAILED_ASSISTANT", "VISIBLE_ERROR"}
			if status == "running" || status == "waiting-input" {
				visible = append(visible, "HIDDEN_INTERIM_REPLY")
			}
			if status == "waiting-input" {
				visible = append(visible, "VISIBLE_PENDING_INTERACTION")
			}
			for _, marker := range visible {
				if !strings.Contains(text, marker) {
					t.Fatalf("%s projection dropped %q: %s", status, marker, wire)
				}
			}
			if !strings.Contains(text, `"kind":"deferred-execution"`) {
				t.Fatalf("%s projection is not a lightweight envelope: %s", status, wire)
			}
			if !strings.Contains(text, `"readingReasoningTokens":10`) {
				t.Fatalf("%s projection lost its reasoning total: %s", status, wire)
			}
		})
	}
}

func TestAgentReadingCodexBytesDoNotGrowWithHiddenBodies(t *testing.T) {
	for _, status := range []string{"running", "completed", "failed", "interrupted"} {
		small, target := readingFixture(t, status, "HIDDEN_REASONING_BODY")
		large, _ := readingFixture(t, status, strings.Repeat("HIDDEN_REASONING_BODY", 10_000))
		smallWire, largeWire := renderReading(t, small, target), renderReading(t, large, target)
		if !bytes.Equal(smallWire, largeWire) {
			t.Fatalf("%s hidden bodies changed the Agent reading bytes: small=%d large=%d", status, len(smallWire), len(largeWire))
		}
	}
}

func TestFullCodexProjectionStillCarriesExecutionDetail(t *testing.T) {
	state, _ := readingFixture(t, "completed", "VISIBLE_DETAIL_BODY")
	raw, err := json.Marshal(state)
	if err != nil {
		t.Fatal(err)
	}
	wire, err := (sessionStateAdapter{}).ProjectRenderer(raw, model.RendererScope{Kind: "execution", Key: "turn:target"})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(wire), "HIDDEN_FAILED_TOOL_BODY") || !strings.Contains(string(wire), "HIDDEN_INITIAL_PROMPT") {
		t.Fatalf("full detail projection dropped its execution body: %s", wire)
	}
}
