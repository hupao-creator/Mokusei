package opencode

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"

	"github.com/hupao-creator/Mokusei/internal/core/model"
)

const testTransportContentLimit = 32<<20 - 256<<10

func TestRendererBoundsLargeToolField(t *testing.T) {
	finished := int64(1)
	latest := "exec"
	state := State{
		Version: 1, NativeSessionID: "session", LatestExecutionID: &latest,
		Executions: []*model.PublicExecution{{ExecutionID: "exec", Status: "completed", StartedAt: 0, FinishedAt: &finished}},
		Messages: []*Message{
			{ID: "user", ExecutionID: "exec", Role: "user", Text: "hello"},
			{ID: "assistant", ExecutionID: "exec", Role: "assistant", Text: ""},
			{ID: "tool", ExecutionID: "exec", Role: "tool", ToolCallID: "call", ToolName: "read", Status: "complete",
				Text: strings.Repeat("x", 34<<20), Result: "small"},
		},
	}
	projected, err := (StateAdapter{}).ProjectRenderer(state.Encode(), model.RendererScope{Kind: "execution", Key: "exec"})
	if err != nil {
		t.Fatal(err)
	}
	if len(projected) > rendererWireBudget || len(projected) > testTransportContentLimit {
		t.Fatalf("projection escaped both budgets: %d bytes", len(projected))
	}
	var value map[string]any
	if err := json.Unmarshal(projected, &value); err != nil {
		t.Fatal(err)
	}
	if value["contentTruncated"] != true {
		t.Fatal("large projection did not advertise truncation")
	}
	tool := value["messages"].([]any)[2].(map[string]any)
	if text := tool["text"].(string); len(text) > rendererStages[0].tool {
		t.Fatalf("tool text retained %d bytes", len(text))
	}
	if _, exists := tool["result"]; exists {
		t.Fatal("redundant tool result survived degradation")
	}
}

func TestRendererBoundsDeferredNonempty(t *testing.T) {
	finished := int64(1)
	latest := "exec"
	messages := make([]*Message, 200)
	for index := range messages {
		parts := make([]Part, 64)
		for part := range parts {
			parts[part] = Part{Type: "reasoning", Ordinal: part, Text: "x"}
		}
		messages[index] = &Message{ID: fmt.Sprintf("m-%d", index), ExecutionID: "exec", Role: "assistant", Status: "complete", Parts: parts}
	}
	state := State{
		Version: 1, NativeSessionID: "session", LatestExecutionID: &latest,
		Executions: []*model.PublicExecution{{ExecutionID: "exec", Status: "completed", StartedAt: 0, FinishedAt: &finished}},
		Messages:   messages,
	}
	projected, err := (StateAdapter{}).ProjectRenderer(state.Encode(), model.RendererScope{Kind: "turn", Key: "exec"})
	if err != nil {
		t.Fatal(err)
	}
	var envelope map[string]any
	if err := json.Unmarshal(projected, &envelope); err != nil {
		t.Fatal(err)
	}
	if envelope["kind"] != "deferred-execution" {
		t.Fatalf("unexpected deferred envelope: %v", envelope["kind"])
	}
	if nonempty := envelope["nonempty"].([]any); len(nonempty) != len(messages)*64 {
		t.Fatalf("fixture presence count = %d", len(nonempty))
	}
	// The reviewer's reproduction had ~768k small presence entries. A smaller
	// number of long fields exercises the same unbounded envelope path without
	// making the test spend most of its time constructing redundant maps.
	hostile := make([]any, 40_000)
	for index := range hostile {
		hostile[index] = map[string]any{"id": fmt.Sprintf("m-%d", index%len(messages)), "field": strings.Repeat("f", 1024)}
	}
	envelope["nonempty"] = hostile
	bounded, err := rendererMarshalProjection(envelope)
	if err != nil {
		t.Fatal(err)
	}
	if len(bounded) > rendererWireBudget || len(bounded) > testTransportContentLimit {
		t.Fatalf("deferred projection escaped both budgets: %d bytes", len(bounded))
	}
	if err := json.Unmarshal(bounded, &envelope); err != nil {
		t.Fatal(err)
	}
	stateValue := envelope["state"].(map[string]any)
	if stateValue["contentTruncated"] != true {
		t.Fatal("deferred projection did not advertise truncation")
	}
	ids := map[string]bool{}
	for _, raw := range stateValue["messages"].([]any) {
		ids[raw.(map[string]any)["id"].(string)] = true
	}
	nonempty := envelope["nonempty"].([]any)
	if len(nonempty) > 50_000 {
		t.Fatalf("nonempty retained %d entries", len(nonempty))
	}
	for _, raw := range nonempty {
		entry := raw.(map[string]any)
		if !ids[entry["id"].(string)] {
			t.Fatalf("nonempty references omitted message %q", entry["id"])
		}
	}
}

func TestRendererPartsTypesAndSkeleton(t *testing.T) {
	limits := rendererStages[1]
	toolMessage := Object{"id": "tool", "executionId": "exec", "role": "tool", "text": "output", "parts": []any{
		Object{"type": "tool", "toolCallId": "call", "ordinal": 7, "text": "unexpected"},
	}}
	rendererBoundMessage(toolMessage, limits)
	toolPart := toolMessage["parts"].([]Object)[0]
	if _, exists := toolPart["ordinal"]; exists {
		t.Fatal("tool part retained a non-contract ordinal")
	}
	if _, exists := toolPart["text"]; exists {
		t.Fatal("tool part retained a non-contract text field")
	}
	for _, parts := range []any{
		[]any{Object{"type": "reasoning", "ordinal": 0, "text": strings.Repeat("x", limits.text+1)}},
		[]Object{{"type": "reasoning", "ordinal": 0, "text": strings.Repeat("x", limits.text+1)}},
	} {
		message := Object{"id": "m", "executionId": "exec", "role": "assistant", "text": "", "parts": parts}
		rendererBoundMessage(message, limits)
		bound := message["parts"].([]Object)
		if len(bound) != 1 {
			t.Fatalf("parts normalization lost the part: %#v", message["parts"])
		}
		if text := rendererText(bound[0]["text"]); len(text) > limits.text {
			t.Fatalf("parts text retained %d bytes", len(text))
		}
	}

	state := Object{"messages": make([]Object, 600)}
	messages := state["messages"].([]Object)
	for index := range messages {
		parts := make([]Object, 40)
		for part := range parts {
			parts[part] = Object{"type": "reasoning", "ordinal": part, "text": strings.Repeat("x", 10_000)}
		}
		messages[index] = Object{"id": fmt.Sprintf("m-%d", index), "executionId": "exec", "role": "assistant", "text": strings.Repeat("x", 10_000), "parts": parts}
	}
	rendererApplyLimits(state, state, rendererStages[2])
	messages = state["messages"].([]Object)
	if len(messages) != 500 {
		t.Fatalf("skeleton retained %d messages", len(messages))
	}
	if parts := messages[0]["parts"].([]Object); len(parts) > rendererStages[2].parts {
		t.Fatalf("skeleton retained %d parts", len(parts))
	}
	if text := messages[0]["text"].(string); len(text) > rendererStages[2].text {
		t.Fatalf("skeleton retained %d text bytes", len(text))
	}
	rendererApplyLimits(state, state, rendererStages[3])
	if messages = state["messages"].([]Object); len(messages) != rendererStages[3].messages {
		t.Fatalf("hard limit retained %d messages", len(messages))
	}
}

func TestRendererBoundsExecutionsAndInteractions(t *testing.T) {
	latest := "exec-000"
	executions := make([]Object, 501)
	for index := range executions {
		executions[index] = Object{
			"executionId": fmt.Sprintf("exec-%03d", index), "status": "completed",
			"startedAt": 0, "finishedAt": 1, "summary": strings.Repeat("s", 10_000),
		}
	}
	state := Object{"executions": executions, "latestExecutionId": &latest}
	rendererBoundExecutions(state, rendererStages[1])
	bound := state["executions"].([]Object)
	if len(bound) > rendererStages[1].executions {
		t.Fatalf("retained %d executions", len(bound))
	}
	if current, ok := state["latestExecutionId"].(string); !ok || current != latest {
		t.Fatalf("latestExecutionId normalized to %#v", state["latestExecutionId"])
	}
	found := false
	for _, execution := range bound {
		found = found || execution["executionId"] == latest
	}
	if !found {
		t.Fatal("latest execution was trimmed")
	}

	interactions := make([]Object, 501)
	for index := range interactions {
		interactions[index] = Object{
			"id": fmt.Sprintf("int-%d", index), "executionId": "exec", "sessionId": "session",
			"kind": "permission", "title": strings.Repeat("t", 10_000), "status": "pending",
			"action": "allow", "resources": []any{"resource"}, "save": []any{},
		}
	}
	top := Object{"interactions": interactions}
	rendererBoundTopInteractions(top, rendererStages[1])
	boundInteractions := top["interactions"].([]Object)
	if len(boundInteractions) > rendererStages[1].interactions {
		t.Fatalf("retained %d native interactions", len(boundInteractions))
	}
	if title := boundInteractions[0]["title"].(string); len(title) > rendererStages[1].short {
		t.Fatalf("interaction title retained %d bytes", len(title))
	}

	waitingInteractions := make([]Object, 100)
	for index := range waitingInteractions {
		waitingInteractions[index] = Object{
			"id": fmt.Sprintf("public-%d", index), "kind": "permission",
			"title":     strings.Repeat("t", 10_000),
			"actions":   []any{Object{"id": "allow", "intent": "allow", "label": strings.Repeat("l", 10_000)}},
			"questions": []any{},
		}
	}
	waiting := Object{"executionId": "exec", "status": "waiting-for-user", "startedAt": 0, "interactions": waitingInteractions}
	execution, ok := rendererBoundExecution(waiting, rendererStages[1])
	if !ok {
		t.Fatal("waiting execution was dropped")
	}
	if list := execution["interactions"].([]Object); len(list) > rendererStages[1].interactions {
		t.Fatalf("retained %d public interactions", len(list))
	}

	latestPointer := latest
	wholeState := Object{
		"version": 1, "messages": []Object{}, "executions": executions,
		"latestExecutionId": &latestPointer,
		"interactions": []Object{{
			"id": "huge", "executionId": "exec", "sessionId": "session", "kind": "permission",
			"title": strings.Repeat("t", 34<<20), "status": "pending", "action": "allow",
			"resources": []any{strings.Repeat("r", 34<<20)}, "save": []any{},
		}},
	}
	projected, err := rendererMarshalProjection(wholeState)
	if err != nil {
		t.Fatal(err)
	}
	if len(projected) > rendererWireBudget || len(projected) > testTransportContentLimit {
		t.Fatalf("whole execution envelope escaped both budgets: %d bytes", len(projected))
	}
	var value map[string]any
	if err = json.Unmarshal(projected, &value); err != nil {
		t.Fatal(err)
	}
	if value["contentTruncated"] != true || value["latestExecutionId"] != latest {
		t.Fatalf("whole envelope lost truncation/latest state: %#v", value["latestExecutionId"])
	}
}

func TestRendererBudgetBoundaryAndMinimalFallback(t *testing.T) {
	underState := Object{
		"version": 1, "messages": []Object{{"id": "m", "executionId": "exec", "role": "user",
			"text": strings.Repeat("u", rendererWireBudget-128<<10)}},
		"executions": []Object{}, "latestExecutionId": nil, "interactions": []Object{},
	}
	under, err := rendererMarshalProjection(underState)
	if err != nil {
		t.Fatal(err)
	}
	var underValue map[string]any
	if err := json.Unmarshal(under, &underValue); err != nil {
		t.Fatal(err)
	}
	if len(under) > rendererWireBudget || underValue["contentTruncated"] != nil {
		t.Fatalf("projection below the budget changed: %d bytes", len(under))
	}

	overState := Object{
		"version": 1, "messages": []Object{{"id": "m", "executionId": "exec", "role": "user",
			"text": strings.Repeat("u", rendererWireBudget+64<<10)}},
		"executions": []Object{}, "latestExecutionId": nil, "interactions": []Object{},
	}
	over, err := rendererMarshalProjection(overState)
	if err != nil {
		t.Fatal(err)
	}
	var overValue map[string]any
	if err := json.Unmarshal(over, &overValue); err != nil {
		t.Fatal(err)
	}
	if len(over) > rendererWireBudget || overValue["contentTruncated"] != true {
		t.Fatalf("projection above the budget was not degraded: %d bytes", len(over))
	}

	latest := "exec"
	hostile := Object{
		"version": 1, "messages": []Object{}, "executions": []Object{
			{"executionId": latest, "status": "failed", "startedAt": 0, "finishedAt": 0, "error": "failed"},
		}, "latestExecutionId": latest, "interactions": []Object{},
		"junk": map[string]any{strings.Repeat("k", rendererWireBudget+1): true},
	}
	envelope := Object{"kind": "deferred-execution", "state": hostile, "nonempty": []Object{}}
	minimal, err := rendererMarshalProjection(envelope)
	if err != nil {
		t.Fatal(err)
	}
	var value map[string]any
	if err := json.Unmarshal(minimal, &value); err != nil {
		t.Fatal(err)
	}
	if len(minimal) > testTransportContentLimit || value["kind"] == "deferred-execution" ||
		value["contentTruncated"] != true || value["junk"] != nil {
		t.Fatalf("final fallback was not minimal/legal: %d bytes %#v", len(minimal), value)
	}
}
