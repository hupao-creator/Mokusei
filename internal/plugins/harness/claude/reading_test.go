package claude

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/hupao-creator/Mokusei/internal/core/model"
)

func claudeReadingState(status string, hidden string) *State {
	s := NewState()
	turn := s.NewTurn("target", model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "HIDDEN_INITIAL_PROMPT"}}}, Settings{})
	turn.addPrompt(model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "VISIBLE_FOLLOW_UP"}}}, "")
	turn.reasoning(hidden)
	turn.activity(map[string]any{"id": "tool-1", "kind": "command", "label": "HIDDEN_TOOL_LABEL", "status": "running", "toolName": "terminal", "detail": hidden})
	turn.activityEnd("tool-1", "completed", hidden)
	claudeReply(turn, "hidden-interim", "hidden-interim", "HIDDEN_INTERIM_REPLY", "complete")
	claudeReply(turn, "target-interim", "target-interim", "VISIBLE_TARGET_REPLY", "complete")
	turn.activity(map[string]any{"id": "tool-2", "kind": "tool", "label": "HIDDEN_FAILED_TOOL_LABEL", "status": "running", "toolName": "read"})
	turn.activityEnd("tool-2", "failed", "HIDDEN_FAILED_TOOL_BODY")
	claudeReply(turn, "final", "final", "VISIBLE_FINAL_REPLY", "complete")
	claudeReply(turn, "failed-assistant", "failed-assistant", "VISIBLE_FAILED_ASSISTANT", "failed")
	turn.notice("info", "HIDDEN_INFO_NOTICE")
	turn.notice("error", "VISIBLE_ERROR")
	turn.interaction(map[string]any{"id": "question", "kind": "permission", "title": "VISIBLE_PENDING_INTERACTION", "status": "pending"})
	turn.Usage = map[string]any{"inputTokens": 1, "outputTokens": 2, "reasoningTokens": 10}
	if status != "running" && status != "waiting-input" {
		turn.settle(status, 40, map[string]bool{})
	}
	return s
}

func claudeReply(turn *Turn, id, messageID, text, status string) {
	at := turn.at()
	item := map[string]any{"id": id, "kind": "assistant", "createdAt": at, "content": text, "status": status}
	if messageID != "" {
		item["messageId"] = messageID
	}
	turn.Timeline = append(turn.Timeline, item)
	turn.Text += "\n" + text
	if status == "complete" && messageID == "final" {
		turn.LastAssistantMessage = map[string]any{"id": messageID, "text": text}
	}
}

func claudeReadingWire(t *testing.T, state *State, key string) []byte {
	t.Helper()
	raw, err := state.Encode()
	if err != nil {
		t.Fatal(err)
	}
	wire, err := (StateAdapter{}).ProjectRenderer(raw, model.RendererScope{
		Kind: "turn", Key: key, Purpose: model.RendererPurposeAgentSummary,
		Target: mustJSON(t, map[string]any{"executionId": "target", "messageId": "target-interim"}),
	})
	if err != nil {
		t.Fatal(err)
	}
	return wire
}

func mustJSON(t *testing.T, value any) json.RawMessage {
	t.Helper()
	raw, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

func TestAgentReadingClaudeOmitsExecutionBodies(t *testing.T) {
	for _, status := range []string{"running", "waiting-input", "completed", "failed", "interrupted"} {
		t.Run(status, func(t *testing.T) {
			wire := claudeReadingWire(t, claudeReadingState(status, "HIDDEN_REASONING_BODY"), "target")
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
		})
	}
}

func TestAgentReadingClaudeBytesDoNotGrowWithHiddenBodies(t *testing.T) {
	for _, status := range []string{"running", "completed", "failed", "interrupted"} {
		small := claudeReadingWire(t, claudeReadingState(status, "HIDDEN_REASONING_BODY"), "target")
		large := claudeReadingWire(t, claudeReadingState(status, strings.Repeat("HIDDEN_REASONING_BODY", 10_000)), "target")
		if len(small) != len(large) {
			t.Fatalf("%s hidden bodies changed the Agent reading bytes: small=%d large=%d", status, len(small), len(large))
		}
	}
}

func TestAgentReadingClaudeForkHistoryOmitsExecutionBodies(t *testing.T) {
	s := NewState()
	s.ForkHistory = map[string]any{
		"sourceSessionId": "source",
		"items": []any{
			map[string]any{"id": "user", "kind": "user-message", "createdAt": 1, "content": "HIDDEN_INITIAL_PROMPT", "attachments": []any{}},
			map[string]any{"id": "reasoning", "kind": "reasoning", "createdAt": 2, "content": "HIDDEN_REASONING_BODY"},
			map[string]any{"id": "activity", "kind": "activity", "createdAt": 3, "activity": map[string]any{"kind": "tool", "label": "HIDDEN_TOOL_LABEL", "status": "completed", "toolName": "read", "detail": "HIDDEN_TOOL_BODY"}},
			map[string]any{"id": "final", "kind": "assistant", "createdAt": 4, "content": "VISIBLE_FINAL_REPLY", "status": "complete"},
		},
	}
	wire := claudeReadingWire(t, s, "fork-history")
	text := string(wire)
	for _, marker := range []string{"HIDDEN_INITIAL_PROMPT", "HIDDEN_REASONING_BODY", "HIDDEN_TOOL_LABEL", "HIDDEN_TOOL_BODY"} {
		if strings.Contains(text, marker) {
			t.Fatalf("fork-history projection retained %q: %s", marker, wire)
		}
	}
	if !strings.Contains(text, "VISIBLE_FINAL_REPLY") {
		t.Fatalf("fork-history projection dropped its visible reply: %s", wire)
	}
}

func TestAgentReadingClaudePendingInteractionKeepsActionSchema(t *testing.T) {
	state := claudeReadingState("waiting-input", "HIDDEN_REASONING_BODY")
	turn := state.Turns[0]
	interaction := map[string]any{"id": "elicitation", "kind": "elicitation", "title": "VISIBLE_PENDING_INTERACTION",
		"status": "pending", "elicitationMode": "form", "input": map[string]any{"value": "VISIBLE_INPUT"},
		"schema": map[string]any{"type": "object"}}
	turn.Interactions = []map[string]any{interaction}
	turn.Timeline = append(turn.Timeline, map[string]any{"id": "elicitation", "kind": "interaction", "createdAt": turn.UpdatedAt + 1, "interaction": cloneObject(interaction)})
	wire := claudeReadingWire(t, state, "target")
	text := string(wire)
	if !strings.Contains(text, `"inputDisplay"`) || !strings.Contains(text, `"schemaDisplay"`) {
		t.Fatalf("pending interaction lost its action display: %s", wire)
	}
}

func TestFullClaudeProjectionStillCarriesExecutionDetail(t *testing.T) {
	state := claudeReadingState("completed", "VISIBLE_DETAIL_BODY")
	raw, err := state.Encode()
	if err != nil {
		t.Fatal(err)
	}
	wire, err := (StateAdapter{}).ProjectRenderer(raw, model.RendererScope{Kind: "execution", Key: "target"})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(wire), "VISIBLE_DETAIL_BODY") || !strings.Contains(string(wire), "HIDDEN_INITIAL_PROMPT") {
		t.Fatalf("full detail projection dropped its execution body: %s", wire)
	}
}
