package opencode

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"

	"github.com/hupao-creator/Mokusei/internal/core/model"
)

func dedupState(t *testing.T) *State {
	t.Helper()
	state, err := DecodeState(nil)
	if err != nil {
		t.Fatal(err)
	}
	state.NativeSessionID = "ses"
	if err = state.Begin("exec", 1); err != nil {
		t.Fatal(err)
	}
	return state
}
func dedupEvent(t *testing.T, state *State, kind string, data Object) {
	t.Helper()
	if err := state.Reduce(Event{Type: kind, Data: data, Created: 2}, "exec"); err != nil {
		t.Fatal(err)
	}
}
func dedupTool(t *testing.T, state *State, id, name string, arguments, content, failure any) {
	t.Helper()
	dedupEvent(t, state, "session.tool.called", Object{"assistantMessageID": "assistant", "sessionID": "ses", "id": id, "name": name, "input": arguments})
	kind := "session.tool.success"
	if failure != nil {
		kind = "session.tool.failed"
	}
	data := Object{"assistantMessageID": "assistant", "sessionID": "ses", "id": id, "content": content}
	if failure != nil {
		data["error"] = failure
	}
	dedupEvent(t, state, kind, data)
}
func dedupProject(t *testing.T, state *State) map[string]any {
	t.Helper()
	raw, err := (StateAdapter{}).ProjectRenderer(state.Encode(), model.RendererScope{Kind: "execution", Key: "exec"})
	if err != nil {
		t.Fatal(err)
	}
	var value map[string]any
	if err = json.Unmarshal(raw, &value); err != nil {
		t.Fatal(err)
	}
	return value
}
func dedupMessages(t *testing.T, value map[string]any) []map[string]any {
	t.Helper()
	items, _ := value["messages"].([]any)
	result := make([]map[string]any, 0, len(items))
	for _, item := range items {
		message, ok := item.(map[string]any)
		if !ok {
			t.Fatalf("message shape: %T", item)
		}
		result = append(result, message)
	}
	return result
}
func dedupMessage(messages []map[string]any, role string) map[string]any {
	for _, message := range messages {
		if message["role"] == role {
			return message
		}
	}
	return nil
}
func dedupCount(value any, body string) int {
	count := 0
	switch typed := value.(type) {
	case string:
		if typed == body {
			count++
		}
	case []any:
		for _, item := range typed {
			count += dedupCount(item, body)
		}
	case map[string]any:
		for _, item := range typed {
			count += dedupCount(item, body)
		}
	}
	return count
}

func TestProjectionKeepsOneVisibleToolBody(t *testing.T) {
	state := dedupState(t)
	dedupEvent(t, state, "session.text.ended", Object{"assistantMessageID": "assistant", "sessionID": "ses", "ordinal": 0, "text": "answer"})
	dedupTool(t, state, "text", "read", Object{"path": "a"}, []any{Object{"type": "text", "text": "plain output"}}, nil)
	dedupTool(t, state, "structured", "read", Object{"path": "b"}, Object{"2": "two", "10": "ten", "z": "<>&\u2028", "a": 0}, nil)
	dedupTool(t, state, "mixed", "read", Object{"path": "c"}, []any{
		Object{"type": "text", "text": "hello"},
		Object{"type": "file", "name": "f", "uri": "file:///f"},
	}, nil)
	dedupTool(t, state, "failure", "read", Object{"path": "d"}, []any{Object{"type": "text", "text": "bad output"}}, Object{"message": "native failure"})
	dedupTool(t, state, "empty", "read", Object{"path": "e"}, []any{Object{"type": "text", "text": ""}}, nil)

	value := dedupProject(t, state)
	messages := dedupMessages(t, value)
	assistant := dedupMessage(messages, "assistant")
	if assistant == nil {
		t.Fatal("missing assistant message")
	}
	for _, key := range []string{"text", "thinking"} {
		if _, exists := assistant[key]; exists {
			t.Fatalf("assistant carries duplicate %s", key)
		}
	}
	parts, _ := assistant["parts"].([]any)
	if len(parts) != 6 || parts[0].(map[string]any)["text"] != "answer" {
		t.Fatalf("assistant parts: %#v", parts)
	}

	want := map[string]string{
		"text":       "plain output",
		"structured": "{\n  \"2\": \"two\",\n  \"10\": \"ten\",\n  \"a\": 0,\n  \"z\": \"<>&\u2028\"\n}",
		"mixed":      "hello\nf: file:///f",
		"failure":    "bad output\nnative failure",
	}
	for _, message := range messages {
		if message["role"] != "tool" {
			continue
		}
		id, _ := message["toolCallId"].(string)
		for _, key := range []string{"text", "thinking", "arguments", "result", "metadata"} {
			if _, exists := message[key]; exists {
				t.Fatalf("tool %s carries duplicate %s", id, key)
			}
		}
		if _, exists := message["argumentsDisplay"]; !exists {
			t.Fatalf("tool %s lost arguments display", id)
		}
		if expected, exists := want[id]; exists {
			if message["resultDisplay"] != expected {
				t.Fatalf("tool %s resultDisplay = %#v, want %#v", id, message["resultDisplay"], expected)
			}
		}
		if id == "empty" && message["resultDisplay"] != "[\n  {\n    \"text\": \"\",\n    \"type\": \"text\"\n  }\n]" {
			t.Fatalf("empty-text resultDisplay = %#v", message["resultDisplay"])
		}
	}
}

func TestProjectionPreservesStructuredDisplayOrder(t *testing.T) {
	raw := json.RawMessage(`{"version":2,"nativeSessionId":"ses","messages":[{"id":"assistant:tool:t","executionId":"exec","role":"tool","toolCallId":"t","arguments":{"z":"<>&\u2028","quote":"a\"b\\c","2":2},"result":{"2":"two","10":"ten","z":"<>&\u2028","quote":"a\"b\\c","a":0}}],"executions":[{"executionId":"exec","startedAt":1,"status":"running"}],"latestExecutionId":"exec","interactions":[]}`)
	projected, err := (StateAdapter{}).ProjectRenderer(raw, model.RendererScope{Kind: "execution", Key: "exec"})
	if err != nil {
		t.Fatal(err)
	}
	var value map[string]any
	if err = json.Unmarshal(projected, &value); err != nil {
		t.Fatal(err)
	}
	tool := dedupMessages(t, value)[0]
	wantResult := "{\n  \"2\": \"two\",\n  \"10\": \"ten\",\n  \"z\": \"<>&\u2028\",\n  \"quote\": \"a\\\"b\\\\c\",\n  \"a\": 0\n}"
	if tool["resultDisplay"] != wantResult {
		t.Fatalf("resultDisplay = %#v", tool["resultDisplay"])
	}
	wantArguments := "{\n  \"2\": 2,\n  \"z\": \"<>&\u2028\",\n  \"quote\": \"a\\\"b\\\\c\"\n}"
	if tool["argumentsDisplay"] != wantArguments {
		t.Fatalf("argumentsDisplay = %#v", tool["argumentsDisplay"])
	}
}

func TestProjectionKeepsPartOrderAndDistinctToolCalls(t *testing.T) {
	state := dedupState(t)
	dedupEvent(t, state, "session.reasoning.ended", Object{"assistantMessageID": "assistant", "sessionID": "ses", "ordinal": 0, "text": "think"})
	dedupEvent(t, state, "session.text.ended", Object{"assistantMessageID": "assistant", "sessionID": "ses", "ordinal": 0, "text": "first"})
	dedupTool(t, state, "one", "read", Object{"path": "same"}, []any{Object{"type": "text", "text": "same output"}}, nil)
	dedupTool(t, state, "two", "read", Object{"path": "same"}, []any{Object{"type": "text", "text": "same output"}}, nil)
	dedupEvent(t, state, "session.text.ended", Object{"assistantMessageID": "assistant", "sessionID": "ses", "ordinal": 1, "text": "last"})

	value := dedupProject(t, state)
	messages := dedupMessages(t, value)
	assistant := dedupMessage(messages, "assistant")
	parts, _ := assistant["parts"].([]any)
	var kinds []string
	for _, item := range parts {
		part := item.(map[string]any)
		kind := fmt.Sprint(part["type"])
		if kind == "tool" {
			kind += ":" + fmt.Sprint(part["toolCallId"])
		}
		kinds = append(kinds, kind)
	}
	want := []string{"reasoning", "text", "tool:one", "tool:two", "text"}
	if fmt.Sprint(kinds) != fmt.Sprint(want) {
		t.Fatalf("parts = %#v, want %#v", kinds, want)
	}
	tools := 0
	for _, message := range messages {
		if message["role"] == "tool" {
			tools++
		}
	}
	if tools != 2 {
		t.Fatalf("tool messages = %d, want 2", tools)
	}
}

func TestReasoningPartsRetainBoundariesAcrossStreamAndRestore(t *testing.T) {
	state := dedupState(t)
	for ordinal, text := range []string{"**Confirming process termination**", "**Analyzing image tag details**"} {
		for _, delta := range []string{text[:3], text[3:]} {
			dedupEvent(t, state, "session.reasoning.delta", Object{"assistantMessageID": "assistant", "sessionID": "ses", "ordinal": ordinal, "delta": delta})
		}
		for range 2 {
			dedupEvent(t, state, "session.reasoning.ended", Object{"assistantMessageID": "assistant", "sessionID": "ses", "ordinal": ordinal, "text": text})
		}
	}
	const want = "**Confirming process termination**\n\n**Analyzing image tag details**"
	for _, restored := range []bool{false, true} {
		if restored {
			var err error
			state, err = DecodeState(state.Encode())
			if err != nil {
				t.Fatal(err)
			}
		}
		assistant := state.message("assistant", "assistant", "ses")
		if assistant == nil || messageThinking(assistant) != want {
			t.Fatalf("restored=%v thinking=%#v", restored, assistant)
		}
		projected := dedupMessage(dedupMessages(t, dedupProject(t, state)), "assistant")
		parts, _ := projected["parts"].([]any)
		if len(parts) != 2 || parts[0].(map[string]any)["text"] != "**Confirming process termination**" || parts[1].(map[string]any)["text"] != "**Analyzing image tag details**" {
			t.Fatalf("restored=%v parts=%#v", restored, parts)
		}
	}
}

func TestProjectionTransfersOneCopyOfEachLargeToolBody(t *testing.T) {
	state := dedupState(t)
	dedupEvent(t, state, "session.text.ended", Object{"assistantMessageID": "assistant", "sessionID": "ses", "ordinal": 0, "text": "answer"})
	bodies := make([]string, 12)
	for index := range bodies {
		bodies[index] = fmt.Sprintf("%02d", index) + strings.Repeat("x", 1<<20)
		dedupTool(t, state, fmt.Sprintf("tool-%d", index), "read", Object{"path": fmt.Sprintf("/%d", index)}, []any{Object{"type": "text", "text": bodies[index]}}, nil)
	}
	raw, err := (StateAdapter{}).ProjectRenderer(state.Encode(), model.RendererScope{Kind: "execution", Key: "exec"})
	if err != nil {
		t.Fatal(err)
	}
	var value any
	if err = json.Unmarshal(raw, &value); err != nil {
		t.Fatal(err)
	}
	for index, body := range bodies {
		if count := dedupCount(value, body); count != 1 {
			t.Fatalf("body %d copies = %d, want 1", index, count)
		}
	}
	single := len(bodies[0])
	t.Logf("single tool body bytes=%d full projection envelope bytes=%d", single, len(raw))
	if len(raw) >= 16<<20 {
		t.Fatalf("projection envelope = %d bytes, want one copy per body", len(raw))
	}
}

func deferredProjection(t *testing.T, state *State) (string, map[string]any) {
	t.Helper()
	raw, err := (StateAdapter{}).ProjectRenderer(state.Encode(), model.RendererScope{Kind: "turn", Key: "exec"})
	if err != nil {
		t.Fatal(err)
	}
	var envelope map[string]any
	if err = json.Unmarshal(raw, &envelope); err != nil {
		t.Fatal(err)
	}
	if envelope["kind"] != "deferred-execution" {
		t.Fatalf("expected deferred envelope, got %#v", envelope["kind"])
	}
	return string(raw), envelope
}

func projectedMessage(t *testing.T, envelope map[string]any, id string) map[string]any {
	t.Helper()
	state, _ := envelope["state"].(map[string]any)
	messages, _ := state["messages"].([]any)
	for _, item := range messages {
		message, _ := item.(map[string]any)
		if message["id"] == id {
			return message
		}
	}
	t.Fatalf("message %q not projected", id)
	return nil
}

func deferredPresence(envelope map[string]any) map[string]map[string]bool {
	result := map[string]map[string]bool{}
	entries, _ := envelope["nonempty"].([]any)
	for _, item := range entries {
		entry, _ := item.(map[string]any)
		id, _ := entry["id"].(string)
		field, _ := entry["field"].(string)
		if result[id] == nil {
			result[id] = map[string]bool{}
		}
		result[id][field] = true
	}
	return result
}

func TestDeferredProjectionHidesChildUserAndToolBodies(t *testing.T) {
	finished := int64(1)
	latest := "exec"
	state := &State{
		Version: StateVersion, NativeSessionID: "root", LatestExecutionID: &latest,
		Executions: []*model.PublicExecution{{ExecutionID: "exec", Status: "completed", StartedAt: 0, FinishedAt: &finished}},
		Messages: []*Message{
			{ID: "parent", ExecutionID: "exec", Role: "user", Text: "parent prompt"},
			{ID: "child-user", ExecutionID: "exec", Role: "user", Text: "CHILD_SECRET_PROMPT", NativeSessionID: "child"},
			{ID: "assistant", ExecutionID: "exec", Role: "assistant", Status: "complete", NativeSessionID: "root",
				Parts: []Part{{Type: "text", Ordinal: 0, Text: "assistant answer"}, {Type: "reasoning", Ordinal: 1, Text: "HIDDEN_REASONING"}}},
			{ID: "child-assistant", ExecutionID: "exec", Role: "assistant", Status: "complete", NativeSessionID: "child",
				Parts: []Part{{Type: "text", Ordinal: 0, Text: "child answer"}}},
			{ID: "tool", ExecutionID: "exec", Role: "tool", ToolCallID: "call", ToolName: "read", Status: "complete",
				Arguments: Object{"path": "ARG_SECRET"}, Result: "TOOL_SECRET_OUTPUT", NativeSessionID: "root"},
		},
	}
	raw, envelope := deferredProjection(t, state)
	presence := deferredPresence(envelope)

	parent := projectedMessage(t, envelope, "parent")
	if parent["text"] != "parent prompt" || presence["parent"]["text"] {
		t.Fatalf("parent prompt projected incorrectly: %#v presence=%v", parent, presence["parent"])
	}
	child := projectedMessage(t, envelope, "child-user")
	if child["text"] != "" || !presence["child-user"]["text"] {
		t.Fatalf("child prompt was not hidden with presence: %#v presence=%v", child, presence["child-user"])
	}
	assistant := projectedMessage(t, envelope, "assistant")
	parts, _ := assistant["parts"].([]any)
	if len(parts) != 2 || parts[0].(map[string]any)["text"] != "assistant answer" || parts[1].(map[string]any)["text"] != "" {
		t.Fatalf("assistant parts were not retained/hidden correctly: %#v", parts)
	}
	if !presence["assistant"]["parts:reasoning:1"] || presence["assistant"]["parts:text:0"] {
		t.Fatalf("assistant presence: %v", presence["assistant"])
	}
	childAssistant := projectedMessage(t, envelope, "child-assistant")
	if childAssistant["parts"].([]any)[0].(map[string]any)["text"] != "child answer" {
		t.Fatalf("child assistant reply was hidden: %#v", childAssistant)
	}
	tool := projectedMessage(t, envelope, "tool")
	for _, field := range []string{"argumentsDisplay", "resultDisplay", "text", "arguments", "result"} {
		if _, exists := tool[field]; exists {
			t.Fatalf("deferred tool retained %q", field)
		}
	}
	if !presence["tool"]["argumentsDisplay"] || !presence["tool"]["resultDisplay"] {
		t.Fatalf("tool presence: %v", presence["tool"])
	}
	for _, secret := range []string{"CHILD_SECRET_PROMPT", "HIDDEN_REASONING", "TOOL_SECRET_OUTPUT", "ARG_SECRET"} {
		if strings.Contains(raw, secret) {
			t.Fatalf("deferred payload leaked %q", secret)
		}
	}
}

func TestCompactCardKeepsTextPreviewBesideReasoning(t *testing.T) {
	source := newRendererSource(nil)
	for _, fixture := range []struct {
		name        string
		parts       []Part
		text        string
		wantParts   int
		wantPart    string
		wantPreview string
	}{
		{"text then reasoning", []Part{{Type: "text", Ordinal: 0, Text: "answer"}, {Type: "reasoning", Ordinal: 1, Text: "reason"}}, "answer", 1, "reasoning", "answer"},
		{"reasoning then text", []Part{{Type: "reasoning", Ordinal: 0, Text: "reason"}, {Type: "text", Ordinal: 1, Text: "answer"}}, "answer", 0, "", "answer"},
		{"reasoning only", []Part{{Type: "reasoning", Ordinal: 0, Text: "reason"}}, "", 1, "reasoning", ""},
	} {
		message := &Message{ID: "assistant", ExecutionID: "exec", Role: "assistant", Status: "complete", Parts: fixture.parts}
		value := rendererCompactMessage(message, true, true, false, nil, "completed", source)
		if value["text"] != fixture.wantPreview {
			t.Fatalf("%s: text = %#v, want %#v", fixture.name, value["text"], fixture.wantPreview)
		}
		parts, _ := value["parts"].([]Object)
		if len(parts) != fixture.wantParts || len(parts) > 0 && parts[0]["type"] != fixture.wantPart {
			t.Fatalf("%s: parts = %#v", fixture.name, value["parts"])
		}
	}
}

func TestRendererSourceKeepsOnlyProjectedMessageFields(t *testing.T) {
	raw := json.RawMessage(`{"messages":[{"id":"m","executionId":"exec","role":"tool","toolName":"read","arguments":{"path":"a"},"result":"out","todos":[],"unused":"drop","metadata":{"secret":"x"}}],"executions":[],"interactions":[],"auxiliaryUsage":[]}`)
	source := newRendererSource(raw)
	record, exists := source.records["messages"]["m"]
	if !exists {
		t.Fatal("message record was not indexed")
	}
	if record.raw != nil {
		t.Fatal("message record retained the whole encoded message")
	}
	for _, key := range []string{"id", "toolName", "arguments", "result", "todos"} {
		if _, exists := record.fields[key]; !exists {
			t.Fatalf("message record dropped %q", key)
		}
	}
	for _, key := range []string{"executionId", "role", "unused", "metadata"} {
		if _, exists := record.fields[key]; exists {
			t.Fatalf("message record retained unrelated field %q", key)
		}
	}
	if string(source.field("messages", "m", "result")) != `"out"` {
		t.Fatalf("result field = %q", source.field("messages", "m", "result"))
	}
	for _, collection := range []string{"messages", "executions", "interactions"} {
		if _, exists := source.fields[collection]; exists {
			t.Fatalf("source retained duplicate %q collection", collection)
		}
	}
	if _, exists := source.fields["auxiliaryUsage"]; !exists {
		t.Fatal("source dropped the auxiliaryUsage optionality sentinel")
	}
}

func TestStateVersionRejectsRetiredDuplicatedSchema(t *testing.T) {
	old := json.RawMessage(`{"version":1,"messages":[{"id":"a","executionId":"exec","role":"assistant","thinking":"only reasoning"}],"executions":[],"latestExecutionId":null,"interactions":[]}`)
	if _, err := DecodeState(old); err == nil || !strings.Contains(err.Error(), "version 1") || !strings.Contains(err.Error(), "rebuild or clear") {
		t.Fatalf("version 1 error = %v", err)
	}
	state, err := DecodeState(nil)
	if err != nil || state.Version != StateVersion {
		t.Fatalf("new state version = %d, err = %v", state.Version, err)
	}
	var encoded map[string]any
	if err = json.Unmarshal(state.Encode(), &encoded); err != nil || encoded["version"] != float64(StateVersion) {
		t.Fatalf("encoded version = %#v, err = %v", encoded["version"], err)
	}
	if _, err = DecodeState(json.RawMessage(`{"version":3,"messages":[],"executions":[],"latestExecutionId":null,"interactions":[]}`)); err == nil {
		t.Fatal("future state version was accepted")
	}
}

func TestToolResultClearsPreviousFailure(t *testing.T) {
	message := &Message{Role: "tool", Status: "failed", IsError: true, ToolError: Object{"message": "old"}, Result: "old"}
	toolResult(message, "new output", nil)
	if message.IsError || message.ToolError != nil || message.Status != "complete" || message.Result != "new output" {
		t.Fatalf("successful retry retained failure: %#v", message)
	}
	toolResult(message, "failed output", Object{"message": "native failure"})
	if !message.IsError || message.ToolError == nil || message.Status != "failed" {
		t.Fatalf("failure was not recorded: %#v", message)
	}
}

func TestDeferredNonemptyFilterKeepsValidPresence(t *testing.T) {
	state := Object{"messages": []Object{
		{"id": "assistant", "executionId": "exec", "role": "assistant", "parts": []Object{{"type": "reasoning", "ordinal": 0, "text": ""}}},
		{"id": "child", "executionId": "exec", "role": "user", "text": ""},
		{"id": "parent", "executionId": "exec", "role": "user", "text": "visible"},
		{"id": "tool", "executionId": "exec", "role": "tool", "argumentsDisplay": "", "resultDisplay": ""},
	}}
	original := []Object{
		{"id": "assistant", "field": "parts:reasoning:0"},
		{"id": "assistant", "field": "parts:reasoning:9"},
		{"id": "assistant", "field": "text"},
		{"id": "assistant", "field": "thinking"},
		{"id": "child", "field": "text"},
		{"id": "parent", "field": "text"},
		{"id": "tool", "field": "argumentsDisplay"},
		{"id": "tool", "field": "resultDisplay"},
		{"id": "tool", "field": "text"},
		{"id": "missing", "field": "text"},
	}
	value := Object{"kind": "deferred-execution", "nonempty": original}
	rendererFilterNonempty(value, state, original, 4096)
	entries, _ := value["nonempty"].([]Object)
	var got []string
	for _, entry := range entries {
		got = append(got, fmt.Sprintf("%s/%s", entry["id"], entry["field"]))
	}
	want := []string{"assistant/parts:reasoning:0", "child/text", "tool/argumentsDisplay", "tool/resultDisplay"}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("presence = %v, want %v", got, want)
	}
}
