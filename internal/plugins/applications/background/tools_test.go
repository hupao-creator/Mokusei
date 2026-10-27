package background

import (
	"context"
	"encoding/json"
	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"testing"
)

func TestToolRejectsInvalidOrRetiredCallsBeforeEffects(t *testing.T) {
	life, cancel := context.WithCancel(t.Context())
	defer cancel()
	calls := 0
	tool := Tool(life, "write", "", model.Object{"text": model.Object{"type": "string"}}, []string{"text"}, func(context.Context, model.Object, string) (any, error) { calls++; return true, nil })
	for _, raw := range []string{`{`, `[]`, `{}`, `{"text":"ok","extra":true}`} {
		if _, err := tool.Execute(t.Context(), plugin.ToolCall{Arguments: json.RawMessage(raw)}); err == nil {
			t.Fatalf("accepted %s", raw)
		}
	}
	if calls != 0 {
		t.Fatal("invalid arguments caused effects")
	}
	if _, err := tool.Execute(t.Context(), plugin.ToolCall{Arguments: json.RawMessage(`{"text":"ok"}`)}); err != nil {
		t.Fatal(err)
	}
	cancel()
	if _, err := tool.Execute(t.Context(), plugin.ToolCall{Arguments: json.RawMessage(`{"text":"ok"}`)}); err == nil {
		t.Fatal("retired call accepted")
	}
	if calls != 1 {
		t.Fatalf("calls=%d", calls)
	}
}
