package codex

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestSearchTextPublicCompletedOnly(t *testing.T) {
	state := EmptyState(1)
	state, err := StageExecutionChecked(state, "internal", Map{"presentation": "internal", "parts": []any{Map{"kind": "text", "text": "PRIVATE_INTERNAL"}}}, 2, Map{})
	if err != nil {
		t.Fatal(err)
	}
	state = SettleExecution(state, "internal", "completed", 3, "")
	for i, status := range []string{"completed", "failed", "interrupted", "running"} {
		text := "PRIVATE_" + status
		if status == "completed" {
			text = "公开内容"
		}
		next, err := StageExecutionChecked(state, status, Map{"parts": []any{Map{"kind": "text", "text": text}, Map{"kind": "image-url", "url": "PRIVATE_ATTACHMENT"}}}, int64(i*10+10), Map{})
		if err != nil {
			t.Fatal(err)
		}
		state = next
		if status != "running" {
			state = SettleExecution(state, status, status, int64(i*10+11), "")
		}
	}
	raw, err := json.Marshal(state)
	if err != nil {
		t.Fatal(err)
	}
	adapter := sessionStateAdapter{}
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
