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
	raw := json.RawMessage(`{"version":1,"nativeSessionId":"ses","messages":[{"id":"assistant:tool:t","executionId":"exec","role":"tool","toolCallId":"t","arguments":{"z":"<>&\u2028","quote":"a\"b\\c","2":2},"result":{"2":"two","10":"ten","z":"<>&\u2028","quote":"a\"b\\c","a":0}}],"executions":[{"executionId":"exec","startedAt":1,"status":"running"}],"latestExecutionId":"exec","interactions":[]}`)
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
