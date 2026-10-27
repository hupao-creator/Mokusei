package pi

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestSearchTextPublicCompletedOnly(t *testing.T) {
	executions := []any{}
	messages := []any{}
	for _, status := range []string{"completed", "failed", "interrupted", "running"} {
		e := map[string]any{"executionId": status, "status": status, "startedAt": 1}
		if status != "running" {
			e["finishedAt"] = 2
		}
		executions = append(executions, e)
		text := "PRIVATE_" + status
		if status == "completed" {
			text = "公开内容"
		}
		for _, role := range []string{"user", "assistant", "tool"} {
			body := text
			if role == "tool" {
				body = "PRIVATE_TOOL"
			}
			message := map[string]any{"id": status + role, "executionId": status, "role": role, "text": body}
			if role == "assistant" {
				message["thinking"] = "PRIVATE_REASONING"
			}
			messages = append(messages, message)
		}
	}
	messages = append(messages, map[string]any{"id": "unknown", "executionId": "unknown", "role": "assistant", "text": "PRIVATE_UNKNOWN"})
	raw, err := json.Marshal(map[string]any{"version": 1, "messages": messages, "executions": executions, "latestExecutionId": "running"})
	if err != nil {
		t.Fatal(err)
	}
	adapter := stateAdapter{}
	text, err := adapter.SearchText(raw)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(text, "公开内容") || strings.Contains(text, "PRIVATE") {
		t.Fatalf("search content: %q", text)
	}
	if _, err := adapter.SearchText(json.RawMessage(`{`)); err == nil {
		t.Fatal("malformed state accepted")
	}
}
