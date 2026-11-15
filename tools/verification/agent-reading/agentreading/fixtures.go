// Package agentreading exports production Harness projections for the native
// count-only Agent reading replay. It never duplicates the UI reducer.
package agentreading

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/claude"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/codex"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/opencode"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/pi"
)

const (
	VisibleReply       = "VISIBLE_FINAL_REPLY"
	VisibleFailed      = "VISIBLE_FAILED_ASSISTANT"
	VisibleTarget      = "VISIBLE_TARGET_REPLY"
	VisibleFollowUp    = "VISIBLE_FOLLOW_UP"
	VisibleError       = "VISIBLE_ERROR"
	VisiblePending     = "VISIBLE_PENDING_INTERACTION"
	VisibleChildError  = "VISIBLE_CHILD_ERROR"
	HiddenInitial      = "HIDDEN_INITIAL_PROMPT"
	HiddenReasoning    = "HIDDEN_REASONING_BODY"
	HiddenToolBody     = "HIDDEN_TOOL_BODY"
	HiddenToolArgument = "HIDDEN_TOOL_ARGUMENT"
	HiddenToolLabel    = "HIDDEN_TOOL_LABEL"
	HiddenFailedBody   = "HIDDEN_FAILED_TOOL_BODY"
	HiddenInterim      = "HIDDEN_INTERIM_REPLY"
	HiddenInfo         = "HIDDEN_INFO_NOTICE"
)

type Fixture struct {
	BoundedRow json.RawMessage `json:"boundedRow,omitempty"`
	Harness    string          `json:"harness"`
	Status     string          `json:"status"`
	State      json.RawMessage `json:"state"`
	Row        json.RawMessage `json:"row"`
	Target     json.RawMessage `json:"target"`
	Execution  json.RawMessage `json:"execution"`
	Anchor     string          `json:"anchor"`
	Visible    []string        `json:"visible"`
	Hidden     []string        `json:"hidden"`
	WireBytes  int             `json:"wireBytes"`
	StateBytes int             `json:"stateBytes"`
}

func Export(path string) error {
	fixtures := []Fixture{}
	for _, harness := range []string{"codex", "claude", "pi", "opencode"} {
		value := fixture(harness)
		if harness == "opencode" {
			// Canonical v2 is not a native renderer envelope. Export the same
			// thread projection that Runtime serves to the manifest consumer.
			manifest, err := (opencode.StateAdapter{}).ProjectRenderer(value.State, model.RendererScope{Kind: "thread"})
			if err != nil {
				return err
			}
			value.State = manifest
			value.StateBytes = len(manifest)
			value.BoundedRow, err = boundedOpenCodeSummary()
			if err != nil {
				return err
			}
		}
		fixtures = append(fixtures, value)
	}
	encoded, err := json.MarshalIndent(fixtures, "", "  ")
	if err != nil {
		return err
	}
	encoded = append(encoded, '\n')
	if path == "-" {
		_, err = os.Stdout.Write(encoded)
		return err
	}
	return os.WriteFile(path, encoded, 0o644)
}

func fixture(harness string) Fixture {
	state, row, target, execution := completedFixture(harness)
	visible := []string{VisibleTarget, VisibleReply, VisibleFailed}
	if harness == "codex" || harness == "claude" {
		visible = append(visible, VisibleError)
	}
	hidden := []string{HiddenInitial, HiddenReasoning, HiddenToolBody, HiddenToolArgument, HiddenToolLabel, HiddenFailedBody, HiddenInterim, HiddenInfo}
	return Fixture{Harness: harness, Status: "completed", State: state, Row: row, Target: target,
		Execution: execution, Anchor: anchor(harness, state), Visible: visible, Hidden: hidden, WireBytes: len(row), StateBytes: len(state)}
}

func anchor(harness string, state json.RawMessage) string {
	var value map[string]any
	_ = json.Unmarshal(state, &value)
	switch harness {
	case "codex":
		for _, turn := range array(value["turns"]) {
			for _, item := range array(object(turn)["timeline"]) {
				if str(object(item)["itemId"]) == "target-interim" {
					return str(object(item)["id"])
				}
			}
		}
	case "claude":
		return "target-interim"
	case "opencode":
		return "target-interim:text:0"
	default:
		return "target-interim"
	}
	return ""
}

func array(value any) []any           { values, _ := value.([]any); return values }
func object(value any) map[string]any { values, _ := value.(map[string]any); return values }
func str(value any) string            { text, _ := value.(string); return text }

func completedFixture(harness string) (json.RawMessage, json.RawMessage, json.RawMessage, json.RawMessage) {
	switch harness {
	case "codex":
		return codexFixture("completed")
	case "claude":
		return claudeFixture("completed")
	case "pi":
		return piFixture("completed")
	default:
		return openCodeFixture("completed")
	}
}

func encode(value any) json.RawMessage {
	raw, err := json.Marshal(value)
	if err != nil {
		panic(err)
	}
	return raw
}

func targetJSON(executionID, messageID string) json.RawMessage {
	return encode(map[string]any{"executionId": executionID, "messageId": messageID})
}

func codexTargetJSON(executionID, itemID string) json.RawMessage {
	return encode(map[string]any{"executionId": executionID, "itemId": itemID})
}

func executionJSON(execution model.PublicExecution) json.RawMessage { return encode(execution) }

func codexFixture(status string) (json.RawMessage, json.RawMessage, json.RawMessage, json.RawMessage) {
	state := codex.StageExecution(codex.EmptyState(1), "target", codex.Map{"parts": []any{codex.Map{"kind": "text", "text": HiddenInitial}}}, 2, nil)
	state = codex.AppendFollowUp(state, "target", codex.Map{"parts": []any{codex.Map{"kind": "text", "text": VisibleFollowUp}}}, 3, "follow")
	events := []codex.Map{
		{"type": "reasoning-delta", "delta": HiddenReasoning},
		{"type": "activity-start", "activity": codex.Map{"id": "tool-1", "kind": "command", "label": HiddenToolLabel, "status": "running", "toolCall": true}},
		{"type": "activity-end", "activityId": "tool-1", "status": "completed", "detail": HiddenToolBody},
		{"type": "text-final", "itemId": "hidden-interim", "text": HiddenInterim},
		{"type": "text-final", "itemId": "target-interim", "text": VisibleTarget},
		{"type": "activity-start", "activity": codex.Map{"id": "tool-2", "kind": "tool", "label": "HIDDEN_FAILED_TOOL_LABEL", "status": "running", "toolCall": true}},
		{"type": "activity-end", "activityId": "tool-2", "status": "failed", "detail": HiddenFailedBody},
		{"type": "text-final", "itemId": "final", "text": VisibleReply},
		{"type": "warning", "message": HiddenInfo},
		{"type": "error", "message": VisibleError},
		{"type": "generation-usage", "generationId": "one", "usage": codex.Map{"reasoningOutputTokens": 4}},
		{"type": "generation-usage", "generationId": "two", "usage": codex.Map{"reasoningOutputTokens": 6}},
	}
	for index, event := range events {
		event["at"] = 10 + index
		state = codex.ReduceEvent(state, "target", event)
	}
	interaction, err := codex.ParseInteraction("item/tool/requestUserInput", codex.Map{"interactionId": "question", "isBlocking": true, "questions": []any{codex.Map{"id": "choice", "question": VisiblePending, "options": []any{codex.Map{"label": "A"}}}}})
	if err != nil {
		panic(err)
	}
	state = codex.ReduceEvent(state, "target", codex.Map{"type": "interaction-opened", "interaction": interaction, "at": 30})
	turn := codex.LatestTurn(state)
	timeline, _ := turn["timeline"].([]any)
	turn["timeline"] = append(timeline, codex.Map{"id": "failed-assistant", "kind": "assistant", "createdAt": 31, "itemId": "failed-assistant", "content": VisibleFailed, "status": "failed"})
	turn["updatedAt"] = 31
	state["updatedAt"] = 31
	finished := int64(40)
	if status != "running" && status != "waiting-input" {
		state = codex.SettleExecution(state, "target", status, finished, "")
	}
	execution := model.PublicExecution{ExecutionID: "target", Status: status, StartedAt: 2}
	if status != "running" && status != "waiting-input" {
		execution.Status, execution.FinishedAt = status, &finished
	}
	raw := encode(state)
	wire := project("codex", raw, codexTargetJSON("target", "target-interim"))
	return raw, wire, codexTargetJSON("target", "target-interim"), executionJSON(execution)
}

func claudeFixture(status string) (json.RawMessage, json.RawMessage, json.RawMessage, json.RawMessage) {
	finished := int64(40)
	activity := map[string]any{"id": "tool-1", "kind": "command", "label": HiddenToolLabel, "status": "completed", "toolName": "terminal", "detail": HiddenToolBody}
	failed := map[string]any{"id": "tool-2", "kind": "tool", "label": "HIDDEN_FAILED_TOOL_LABEL", "status": "failed", "toolName": "read", "detail": HiddenFailedBody}
	interaction := map[string]any{"id": "question", "kind": "permission", "title": VisiblePending, "status": "pending"}
	turn := map[string]any{
		"executionId": "target", "createdAt": 2, "updatedAt": 40, "finishedAt": finished,
		"prompts": []any{HiddenInitial, VisibleFollowUp}, "promptAttachments": []any{[]any{}, []any{}},
		"text": VisibleReply, "reasoning": "", "status": status,
		"plan": []any{}, "activities": []any{activity, failed}, "interactions": []any{interaction},
		"notices": []any{map[string]any{"id": "notice", "level": "error", "message": VisibleError}},
		"usage":   map[string]any{"inputTokens": 1, "outputTokens": 2, "reasoningTokens": 10},
		"timeline": []any{
			map[string]any{"id": "u0", "kind": "user-message", "createdAt": 2, "promptIndex": 0},
			map[string]any{"id": "u1", "kind": "user-message", "createdAt": 3, "promptIndex": 1},
			map[string]any{"id": "r1", "kind": "reasoning", "createdAt": 4, "content": HiddenReasoning},
			map[string]any{"id": "a1", "kind": "activity", "createdAt": 5, "activity": activity},
			map[string]any{"id": "hidden-interim", "kind": "assistant", "createdAt": 6, "content": HiddenInterim, "status": "complete", "messageId": "hidden"},
			map[string]any{"id": "target-interim", "kind": "assistant", "createdAt": 7, "content": VisibleTarget, "status": "complete", "messageId": "target"},
			map[string]any{"id": "final", "kind": "assistant", "createdAt": 8, "content": VisibleReply, "status": "complete", "messageId": "final"},
			map[string]any{"id": "failed-assistant", "kind": "assistant", "createdAt": 8, "content": VisibleFailed, "status": "failed", "messageId": "failed-assistant"},
			map[string]any{"id": "notice", "kind": "notice", "createdAt": 9, "notice": map[string]any{"id": "notice", "level": "error", "message": VisibleError}},
			map[string]any{"id": "question", "kind": "interaction", "createdAt": 10, "interaction": interaction},
		},
	}
	if status == "failed" {
		turn["error"] = VisibleError
		turn["timeline"] = append(turn["timeline"].([]any), map[string]any{"id": "error", "kind": "error", "createdAt": 11, "message": VisibleError})
	}
	if status != "running" && status != "waiting-input" {
		turn["interactions"] = []any{}
		turn["timeline"] = turn["timeline"].([]any)[:len(turn["timeline"].([]any))-2]
	}
	raw := encode(map[string]any{"version": 1, "turns": []any{turn}, "nativeNotifications": []any{}})
	wire := project("claude", raw, targetJSON("target", "target"))
	execution := model.PublicExecution{ExecutionID: "target", Status: status, StartedAt: 2}
	if status != "running" && status != "waiting-user" {
		execution.FinishedAt = &finished
	}
	return raw, wire, targetJSON("target", "target"), executionJSON(execution)
}

func piFixture(status string) (json.RawMessage, json.RawMessage, json.RawMessage, json.RawMessage) {
	finished := int64(40)
	state := pi.State{
		Version: 1,
		Messages: []pi.MessageState{
			{ID: "initial", ExecutionID: "target", Role: "user", Presentation: "ordinary", Text: HiddenInitial},
			{ID: "follow", ExecutionID: "target", Role: "user", Presentation: "ordinary", FollowUp: true, CreatedAt: 3, Text: VisibleFollowUp},
			{ID: "assistant-1", ExecutionID: "target", Role: "assistant", Status: "complete", Thinking: HiddenReasoning, Usage: &pi.Usage{Input: 1, Output: 1}},
			{ID: "target-interim", ExecutionID: "target", Role: "assistant", Status: "complete", Text: VisibleTarget},
			{ID: "final", ExecutionID: "target", Role: "assistant", Status: "complete", Text: VisibleReply, Model: "model", Provider: "provider", Usage: &pi.Usage{Input: 2, Output: 3, Reasoning: pointer(int64(10))}},
			{ID: "failed-assistant", ExecutionID: "target", Role: "assistant", Status: "failed", Text: VisibleFailed},
			{ID: "tool-1", ExecutionID: "target", Role: "tool", ToolCallID: "tool-1", ToolName: "terminal"},
			{ID: "tool-2", ExecutionID: "target", Role: "tool", ToolCallID: "tool-2", ToolName: "read", IsError: true},
		},
		Executions:        []model.PublicExecution{{ExecutionID: "target", Status: status, StartedAt: 2}},
		LatestExecutionID: pointer("target"),
	}
	if status == "waiting-for-user" {
		state.Executions[0].Interactions = []model.PublicInteraction{{ID: "question", Kind: "question", Title: VisiblePending,
			Actions:   []model.PublicInteractionAction{{ID: "submit", Intent: "submit", Label: "Submit"}},
			Questions: []model.PublicInteractionQuestion{{ID: "question", Prompt: VisiblePending, Options: []model.PublicInteractionOption{}}}}}
	}
	if status == "failed" {
		state.Executions[0].Error = pointer(VisibleError)
	}
	if status != "running" && status != "waiting-for-user" {
		state.Executions[0].FinishedAt = &finished
	}
	raw := encode(state)
	wire := project("pi", raw, targetJSON("target", "target-interim"))
	execution := model.PublicExecution{ExecutionID: "target", Status: status, StartedAt: 2, FinishedAt: state.Executions[0].FinishedAt, Error: state.Executions[0].Error, Interactions: state.Executions[0].Interactions}
	return raw, wire, targetJSON("target", "target-interim"), executionJSON(execution)
}

func openCodeFixture(status string) (json.RawMessage, json.RawMessage, json.RawMessage, json.RawMessage) {
	finished := int64(40)
	state, _ := opencode.DecodeState(nil)
	state.NativeSessionID = "session"
	_ = state.Begin("target", 2)
	state.ExecutionAuthors = map[string]opencode.Object{"target": {"model": "model"}}
	state.Messages = append(state.Messages,
		&opencode.Message{ID: "initial", ExecutionID: "target", Role: "user", Presentation: "ordinary", Text: HiddenInitial},
		&opencode.Message{ID: "follow", ExecutionID: "target", Role: "user", FollowUp: true, Presentation: "ordinary", Text: VisibleFollowUp},
		&opencode.Message{ID: "assistant-1", ExecutionID: "target", Role: "assistant", Status: "complete",
			Parts: []opencode.Part{{Type: "text", Ordinal: 0, Text: HiddenInterim}, {Type: "reasoning", Ordinal: 1, Text: HiddenReasoning}}},
		&opencode.Message{ID: "target-interim", ExecutionID: "target", Role: "assistant", Status: "complete",
			Parts: []opencode.Part{{Type: "text", Ordinal: 0, Text: VisibleTarget}}},
		&opencode.Message{ID: "final", ExecutionID: "target", Role: "assistant", Status: "complete",
			Parts: []opencode.Part{{Type: "text", Ordinal: 0, Text: VisibleReply}}},
		&opencode.Message{ID: "tool-1", ExecutionID: "target", Role: "tool", Status: "complete",
			ToolCallID: "tool-1", ToolName: "terminal", Arguments: map[string]any{"command": HiddenToolArgument}, Result: map[string]any{"output": HiddenToolBody}},
		&opencode.Message{ID: "tool-2", ExecutionID: "target", Role: "tool", Status: "failed", IsError: true,
			ToolCallID: "tool-2", ToolName: "read", Arguments: map[string]any{"path": HiddenToolArgument}, Result: map[string]any{"output": HiddenFailedBody}},
		&opencode.Message{ID: "failed-assistant", ExecutionID: "target", Role: "assistant", Status: "failed", IsError: true, Parts: []opencode.Part{{Type: "text", Text: VisibleFailed}}},
		&opencode.Message{ID: "child-error", ExecutionID: "target", NativeSessionID: "child", Role: "assistant", Status: "failed", IsError: true, Parts: []opencode.Part{{Type: "text", Text: VisibleChildError}}},
	)
	state.Interactions = append(state.Interactions, &opencode.Interaction{ID: "question", ExecutionID: "target", SessionID: "session",
		Kind: "permission", Title: VisiblePending, Status: "pending", Action: "allow", Resources: []string{"resource"}})
	if status == "waiting-input" {
		state.RefreshInteractions("target")
	} else if status != "running" {
		state.Settle("target", status, finished, VisibleError)
	}
	raw := state.Encode()
	wire := project("opencode", raw, targetJSON("target", "target-interim"))
	execution := model.PublicExecution{ExecutionID: "target", Status: status, StartedAt: 2}
	if status != "running" && status != "waiting-input" {
		execution.FinishedAt = &finished
		if status == "failed" {
			execution.Error = pointer(VisibleError)
		}
	}
	return raw, wire, targetJSON("target", "target-interim"), executionJSON(execution)
}

func project(harness string, raw, target json.RawMessage) json.RawMessage {
	var adapter interface {
		ProjectRenderer(json.RawMessage, model.RendererScope) (json.RawMessage, error)
	}
	switch harness {
	case "codex":
		adapter = codex.NewSessionStateAdapter()
	case "claude":
		adapter = claude.StateAdapter{}
	case "pi":
		adapter = pi.New(pluginHost()).SessionState()
	default:
		adapter = opencode.StateAdapter{}
	}
	key := "target"
	if harness == "codex" {
		key = "turn:target"
	}
	wire, err := adapter.ProjectRenderer(raw, model.RendererScope{Kind: "turn", Key: key, Purpose: model.RendererPurposeAgentSummary, Target: target})
	if err != nil {
		panic(fmt.Sprintf("%s projection failed: %v", harness, err))
	}
	return wire
}

func pointer[T any](value T) *T { return &value }

// pluginHost keeps the exported adapter construction independent of runtime
// services; the projection path does not call host callbacks.
func pluginHost() plugin.HostContext { return plugin.HostContext{} }

// The native decoder consumes the actual bounded adapter output, not a hand-built Swift fixture.
func boundedOpenCodeSummary() (json.RawMessage, error) {
	state, err := opencode.DecodeState(nil)
	if err != nil {
		return nil, err
	}
	state.NativeSessionID = "session"
	if err := state.Begin("large", 1); err != nil {
		return nil, err
	}
	state.Messages = append(state.Messages, &opencode.Message{ID: "large-reply", ExecutionID: "large", Role: "assistant", Status: "complete", Parts: []opencode.Part{{Type: "text", Text: strings.Repeat("x", 33<<20)}}})
	state.Settle("large", "completed", 2, "")
	return (opencode.StateAdapter{}).ProjectRenderer(state.Encode(), model.RendererScope{Kind: "turn", Key: "large", Purpose: model.RendererPurposeAgentSummary})
}
