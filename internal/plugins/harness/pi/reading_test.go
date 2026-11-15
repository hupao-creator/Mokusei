package pi

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"

	"github.com/hupao-creator/Mokusei/internal/core/model"
)

func piReadingState(status string, hidden string) State {
	execution := model.PublicExecution{ExecutionID: "target", Status: status, StartedAt: 1}
	if status == "waiting-for-user" {
		execution.Interactions = []model.PublicInteraction{{ID: "question", Kind: "question", Title: "VISIBLE_PENDING_INTERACTION",
			Actions:   []model.PublicInteractionAction{{ID: "submit", Intent: "submit", Label: "Submit"}},
			Questions: []model.PublicInteractionQuestion{{ID: "question", Prompt: "VISIBLE_PENDING_INTERACTION", Options: []model.PublicInteractionOption{}}}}}
	}
	if status != "running" && status != "waiting-for-user" {
		finished := int64(40)
		execution.FinishedAt = &finished
	}
	if status == "failed" {
		errorText := "VISIBLE_ERROR"
		execution.Error = &errorText
	}
	latest := "target"
	return State{
		Version: 1, LatestExecutionID: &latest,
		Executions: []model.PublicExecution{execution},
		Messages: []MessageState{
			{ID: "initial", ExecutionID: "target", Role: "user", Presentation: "ordinary", Text: "HIDDEN_INITIAL_PROMPT"},
			{ID: "follow", ExecutionID: "target", Role: "user", Presentation: "ordinary", FollowUp: true, CreatedAt: 3, Text: "VISIBLE_FOLLOW_UP"},
			{ID: "assistant-1", ExecutionID: "target", Role: "assistant", Status: "complete", Text: "HIDDEN_INTERIM_REPLY", Thinking: hidden, Usage: &Usage{Input: 1, Output: 1}},
			{ID: "target-interim", ExecutionID: "target", Role: "assistant", Status: "complete", Text: "VISIBLE_TARGET_REPLY"},
			{ID: "failed-assistant", ExecutionID: "target", Role: "assistant", Status: "failed", Text: "VISIBLE_FAILED_ASSISTANT"},
			{ID: "final", ExecutionID: "target", Role: "assistant", Status: "complete", Text: "VISIBLE_FINAL_REPLY", Model: "model", Provider: "provider", Usage: &Usage{Input: 2, Output: 3, Reasoning: func() *int64 { value := int64(10); return &value }()}},
			{ID: "tool-1", ExecutionID: "target", Role: "tool", Text: "HIDDEN_TOOL_BODY" + hidden, ToolCallID: "tool-1", ToolName: "terminal"},
			{ID: "tool-2", ExecutionID: "target", Role: "tool", Text: "HIDDEN_FAILED_TOOL_BODY" + hidden, ToolCallID: "tool-2", ToolName: "read", IsError: true},
		},
	}
}

func piReadingWire(t *testing.T, state State, key string) []byte {
	t.Helper()
	raw, err := json.Marshal(state)
	if err != nil {
		t.Fatal(err)
	}
	wire, err := (stateAdapter{}).ProjectRenderer(raw, model.RendererScope{
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

func TestAgentReadingPiOmitsExecutionBodies(t *testing.T) {
	for _, status := range []string{"running", "waiting-for-user", "completed", "failed", "interrupted"} {
		t.Run(status, func(t *testing.T) {
			wire := piReadingWire(t, piReadingState(status, "HIDDEN_REASONING_BODY"), "target")
			text := string(wire)
			hidden := []string{"HIDDEN_INITIAL_PROMPT", "HIDDEN_REASONING_BODY", "HIDDEN_TOOL_BODY", "HIDDEN_FAILED_TOOL_BODY"}
			if status != "running" && status != "waiting-for-user" {
				hidden = append(hidden, "HIDDEN_INTERIM_REPLY")
			}
			for _, marker := range hidden {
				if strings.Contains(text, marker) {
					t.Fatalf("%s projection retained %q: %s", status, marker, wire)
				}
			}
			visible := []string{"VISIBLE_FOLLOW_UP", "VISIBLE_TARGET_REPLY", "VISIBLE_FINAL_REPLY", "VISIBLE_FAILED_ASSISTANT"}
			if status == "running" || status == "waiting-for-user" {
				visible = append(visible, "HIDDEN_INTERIM_REPLY")
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

func TestAgentReadingPiBytesDoNotGrowWithHiddenBodies(t *testing.T) {
	for _, status := range []string{"running", "completed", "failed", "interrupted"} {
		small := piReadingWire(t, piReadingState(status, "HIDDEN_REASONING_BODY"), "target")
		large := piReadingWire(t, piReadingState(status, strings.Repeat("HIDDEN_REASONING_BODY", 10_000)), "target")
		if !bytes.Equal(small, large) {
			t.Fatalf("%s hidden bodies changed the Agent reading bytes: small=%d large=%d", status, len(small), len(large))
		}
	}
}

func TestAgentReadingPiKeepsUnknownExecutionUsageUnknown(t *testing.T) {
	state := piReadingState("completed", "HIDDEN_REASONING_BODY")
	for index := range state.Messages {
		state.Messages[index].Usage = nil
	}
	wire := piReadingWire(t, state, "target")
	if strings.Contains(string(wire), `"executionUsage"`) {
		t.Fatalf("unreported usage became a known total: %s", wire)
	}
}

func TestFullPiProjectionStillCarriesExecutionDetail(t *testing.T) {
	state := piReadingState("completed", "VISIBLE_DETAIL_BODY")
	wire := piReadingWireWithScope(t, state, model.RendererScope{Kind: "execution", Key: "target"})
	if !strings.Contains(string(wire), "VISIBLE_DETAIL_BODY") || !strings.Contains(string(wire), "HIDDEN_INITIAL_PROMPT") {
		t.Fatalf("full detail projection dropped its execution body: %s", wire)
	}
}

func piReadingWireWithScope(t *testing.T, state State, scope model.RendererScope) []byte {
	t.Helper()
	raw, err := json.Marshal(state)
	if err != nil {
		t.Fatal(err)
	}
	wire, err := (stateAdapter{}).ProjectRenderer(raw, scope)
	if err != nil {
		t.Fatal(err)
	}
	return wire
}
