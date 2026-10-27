package claude

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/hupao-creator/Mokusei/internal/core/model"
)

// TestStateEncoderAuthorThinkingGolden pins the persisted shape consumed by
// the Swift ClaudeState decoder. The fixture is also read by
// app/macos/Tests/Integration/Threads/ClaudeErrorSurfacingTests.swift
// so a Go encoder change that breaks the native reader fails both suites.
func TestStateEncoderAuthorThinkingGolden(t *testing.T) {
	raw, err := goldenAuthorThinkingState().Encode()
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join("testdata", "state-author-thinking.golden.json")
	if os.Getenv("MOKUSEI_UPDATE_CLAUDE_GOLDEN") == "1" {
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, append(raw, '\n'), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	expected, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(raw) != strings.TrimSpace(string(expected)) {
		t.Fatalf("Claude state golden is stale; rerun with MOKUSEI_UPDATE_CLAUDE_GOLDEN=1\nwant: %s\ngot:  %s", expected, raw)
	}
	var state struct {
		Turns []struct {
			Author map[string]any `json:"author"`
		} `json:"turns"`
	}
	if err := json.Unmarshal(raw, &state); err != nil {
		t.Fatal(err)
	}
	if len(state.Turns) != 1 {
		t.Fatalf("turns = %d", len(state.Turns))
	}
	thinking, ok := state.Turns[0].Author["thinking"].(map[string]any)
	if !ok || thinking["mode"] != "effort" || thinking["effort"] != "high" {
		t.Fatalf("author thinking = %#v", state.Turns[0].Author["thinking"])
	}
}

// TestResultAPIErrorIsCarriedVerbatim replays a real Claude result frame for an
// upstream 402. The transport must hand the exact API message (including the
// request ID) to the handle instead of falling back to a process-exit string.
func TestResultAPIErrorIsCarriedVerbatim(t *testing.T) {
	const message = "API Error: 402 Insufficient Balance (request_id: e5f42042-b460-47cf-ae82-1a8db1109bcd)"
	transport := &Transport{controls: map[string]chan controlResult{}, interactions: map[string]map[string]any{}, events: make(chan NativeEvent, 4)}
	transport.active = &nativeExecution{id: "execution-402", boundaries: []*nativeBoundary{{id: "user-402", admitted: true}}}
	transport.handleFrame(map[string]any{
		"type": "result", "is_error": true, "subtype": "success", "result": message,
		"api_error_status": float64(402), "user_message_uuid": "user-402",
	})
	for len(transport.events) > 0 {
		if event := <-transport.events; event.Outcome != "" {
			if event.Outcome != "failed" || event.Error != message {
				t.Fatalf("event = %#v", event)
			}
			return
		}
	}
	t.Fatal("expected a terminal native event")
}

func TestObservationProjectsFailedTurnError(t *testing.T) {
	const message = "API Error: 402 Insufficient Balance (request_id: e5f42042-b460-47cf-ae82-1a8db1109bcd)"
	state := NewState()
	turn := state.NewTurn("execution-402", model.AgentInput{Parts: []model.AgentInputPart{}}, Settings{Model: "claude-sonnet-4-5"})
	turn.fail(message)
	turn.settle("failed", 3_000, nil)
	execution := state.observation().LatestExecution
	if execution == nil || execution.Error == nil || *execution.Error != message {
		t.Fatalf("observation error = %#v", execution)
	}
}

func goldenAuthorThinkingState() *State {
	finished := int64(2_000)
	return &State{
		Version:          1,
		PrimarySessionID: "claude-native-session",
		Turns: []*Turn{{
			Author: map[string]any{
				"model":    "claude-sonnet-4-5",
				"thinking": &model.ThinkingChoice{Mode: "effort", Effort: "high"},
			},
			ExecutionID:       "execution-golden",
			CreatedAt:         1_000,
			UpdatedAt:         2_000,
			FinishedAt:        &finished,
			Prompts:           []string{"Explain the failure"},
			PromptAttachments: [][]map[string]any{{}},
			Text:              "The upstream request failed.",
			Reasoning:         "",
			Status:            "completed",
			Plan:              []map[string]any{},
			Activities:        []map[string]any{},
			Interactions:      []map[string]any{},
			Notices:           []map[string]any{},
			Timeline: []map[string]any{
				{"id": "user-message:1001:0", "kind": "user-message", "createdAt": 1_001, "promptIndex": 0},
				{"id": "assistant:1002:1", "kind": "assistant", "createdAt": 1_002, "content": "The upstream request failed.", "status": "complete"},
			},
		}},
		NativeNotifications: []map[string]any{},
	}
}
