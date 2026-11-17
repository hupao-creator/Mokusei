package pi

import "testing"

func TestThinkingBlocksMatchDeltaStreamAndHistorySnapshot(t *testing.T) {
	decoder := &eventDecoder{}
	if _, err := decoder.decode(map[string]any{"type": "message_start", "message": map[string]any{"role": "assistant", "content": []any{}}}); err != nil {
		t.Fatal(err)
	}
	for index, text := range []string{"**Confirming process termination**", "**Analyzing image tag details**"} {
		for _, delta := range []string{text[:3], text[3:]} {
			event, err := decoder.decode(map[string]any{"type": "message_update", "assistantMessageEvent": map[string]any{"type": "thinking_delta", "contentIndex": float64(index), "delta": delta}})
			if err != nil || event == nil {
				t.Fatalf("stream decode: %v", err)
			}
			if index == 0 && delta == text[3:] && event.Thinking != text {
				t.Fatalf("one block's chunks gained separators: %q", event.Thinking)
			}
			if index == 1 && delta == text[3:] && event.Thinking != "**Confirming process termination**\n**Analyzing image tag details**" {
				t.Fatalf("thinking blocks were joined: %q", event.Thinking)
			}
		}
	}
	message := map[string]any{"role": "assistant", "content": []any{
		map[string]any{"type": "thinking", "thinking": "**Confirming process termination**"},
		map[string]any{"type": "thinking", "thinking": "**Analyzing image tag details**"},
	}}
	for _, phase := range []string{"message_update", "message_end"} {
		event, err := decoder.decode(map[string]any{"type": phase, "message": message})
		if err != nil || event == nil || event.Thinking != "**Confirming process termination**\n**Analyzing image tag details**" {
			t.Fatalf("%s snapshot lost boundaries: %#v, %v", phase, event, err)
		}
	}
}
