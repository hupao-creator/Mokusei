package opencode

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"

	"github.com/hupao-creator/Mokusei/internal/core/model"
)

func openCodeReadingState(status string, hidden string) *State {
	s, _ := DecodeState(nil)
	s.NativeSessionID = "session"
	_ = s.Begin("target", 1)
	s.ExecutionAuthors = map[string]Object{"target": {"model": "model"}}
	s.Messages = append(s.Messages,
		&Message{ID: "initial", ExecutionID: "target", Role: "user", Presentation: "ordinary", Text: "HIDDEN_INITIAL_PROMPT"},
		&Message{ID: "follow", ExecutionID: "target", Role: "user", FollowUp: true, Presentation: "ordinary", Text: "VISIBLE_FOLLOW_UP"},
		&Message{ID: "assistant-1", ExecutionID: "target", Role: "assistant", Status: "complete",
			Parts: []Part{{Type: "text", Ordinal: 0, Text: "HIDDEN_INTERIM_REPLY"}, {Type: "reasoning", Ordinal: 1, Text: hidden}}},
		&Message{ID: "target-interim", ExecutionID: "target", Role: "assistant", Status: "complete",
			Parts: []Part{{Type: "text", Ordinal: 0, Text: "VISIBLE_TARGET_REPLY"}}},
		&Message{ID: "assistant-final", ExecutionID: "target", Role: "assistant", Status: "complete",
			Parts: []Part{{Type: "text", Ordinal: 0, Text: "VISIBLE_FINAL_REPLY"}}},
		&Message{ID: "tool-1", ExecutionID: "target", Role: "tool", Status: "complete",
			ToolCallID: "tool-1", ToolName: "terminal", Arguments: map[string]any{"command": "HIDDEN_TOOL_ARGUMENT"}, Result: map[string]any{"output": hidden}},
		&Message{ID: "tool-2", ExecutionID: "target", Role: "tool", Status: "failed", IsError: true,
			ToolCallID: "tool-2", ToolName: "read", Arguments: map[string]any{"path": "HIDDEN_FAILED_TOOL_ARGUMENT"}, Result: map[string]any{"output": "HIDDEN_FAILED_TOOL_BODY"}},
		&Message{ID: "failed-assistant", ExecutionID: "target", Role: "assistant", Status: "failed", IsError: true, Parts: []Part{{Type: "text", Text: "VISIBLE_FAILED_ASSISTANT"}}},
		&Message{ID: "child-error", ExecutionID: "target", NativeSessionID: "child", Role: "assistant", Status: "failed", IsError: true, Parts: []Part{{Type: "text", Text: "VISIBLE_CHILD_ERROR"}}},
	)
	s.Interactions = append(s.Interactions, &Interaction{ID: "question", ExecutionID: "target", SessionID: "session",
		Kind: "permission", Title: "VISIBLE_PENDING_INTERACTION", Status: "pending", Action: "allow", Resources: []string{}})
	if status == "waiting-input" {
		s.RefreshInteractions("target")
	} else if status != "running" {
		s.Settle("target", status, 40, "VISIBLE_ERROR")
	}
	return s
}

func openCodeReadingWire(t *testing.T, state *State, key string) []byte {
	t.Helper()
	wire, err := (StateAdapter{}).ProjectRenderer(state.Encode(), model.RendererScope{
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

func TestAgentReadingOpenCodeOmitsExecutionBodies(t *testing.T) {
	for _, status := range []string{"running", "waiting-input", "completed", "failed", "interrupted"} {
		t.Run(status, func(t *testing.T) {
			wire := openCodeReadingWire(t, openCodeReadingState(status, "HIDDEN_REASONING_BODY"), "target")
			text := string(wire)
			hidden := []string{"HIDDEN_INITIAL_PROMPT", "HIDDEN_REASONING_BODY", "HIDDEN_TOOL_BODY", "HIDDEN_TOOL_ARGUMENT", "HIDDEN_FAILED_TOOL_BODY", "HIDDEN_FAILED_TOOL_ARGUMENT"}
			if status != "running" && status != "waiting-input" {
				hidden = append(hidden, "HIDDEN_INTERIM_REPLY")
			}
			for _, marker := range hidden {
				if strings.Contains(text, marker) {
					t.Fatalf("%s projection retained %q: %s", status, marker, wire)
				}
			}
			visible := []string{"VISIBLE_FOLLOW_UP", "VISIBLE_TARGET_REPLY", "VISIBLE_FINAL_REPLY", "VISIBLE_FAILED_ASSISTANT"}
			if status == "running" || status == "waiting-input" {
				visible = append(visible, "HIDDEN_INTERIM_REPLY")
			}
			if status == "waiting-input" {
				visible = append(visible, "VISIBLE_PENDING_INTERACTION")
			}
			if status == "failed" {
				visible = append(visible, "VISIBLE_ERROR")
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

func TestAgentReadingOpenCodeBytesDoNotGrowWithHiddenBodies(t *testing.T) {
	for _, status := range []string{"running", "completed", "failed", "interrupted"} {
		small := openCodeReadingWire(t, openCodeReadingState(status, "HIDDEN_REASONING_BODY"), "target")
		large := openCodeReadingWire(t, openCodeReadingState(status, strings.Repeat("HIDDEN_REASONING_BODY", 10_000)), "target")
		if !bytes.Equal(small, large) {
			t.Fatalf("%s hidden bodies changed the Agent reading bytes: small=%d large=%d", status, len(small), len(large))
		}
	}
}

func TestAgentReadingOpenCodeChildSessionKeepsOnlyIndependentError(t *testing.T) {
	wire := openCodeReadingWire(t, openCodeReadingState("completed", "HIDDEN_REASONING_BODY"), "target")
	text := string(wire)
	if !strings.Contains(text, "VISIBLE_CHILD_ERROR") {
		t.Fatalf("child-session error was dropped: %s", wire)
	}
}

func TestFullOpenCodeProjectionStillCarriesExecutionDetail(t *testing.T) {
	state := openCodeReadingState("completed", "VISIBLE_DETAIL_BODY")
	wire, err := (StateAdapter{}).ProjectRenderer(state.Encode(), model.RendererScope{Kind: "execution", Key: "target"})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(wire), "VISIBLE_DETAIL_BODY") || !strings.Contains(string(wire), "HIDDEN_INITIAL_PROMPT") {
		t.Fatalf("full detail projection dropped its execution body: %s", wire)
	}
}
