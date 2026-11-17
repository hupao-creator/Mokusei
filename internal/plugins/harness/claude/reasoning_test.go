package claude

import (
	"testing"

	"github.com/hupao-creator/Mokusei/internal/core/model"
)

func TestNativeReasoningBoundariesMatchStreamAndCompletedMessages(t *testing.T) {
	const want = "**Confirming process termination**\n\n**Analyzing image tag details**\n\nNext paragraph"
	for _, streamed := range []bool{false, true} {
		state := NewState()
		turn := state.NewTurn("execution", model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "prompt"}}}, Settings{})
		parser := newParser()
		apply := func(frame map[string]any) { parser.apply(state, turn, frame, nil) }
		for messageIndex, blocks := range [][]string{{"**Confirming process termination**", "**Analyzing image tag details**"}, {"Next paragraph"}} {
			id := []string{"message-1", "message-2"}[messageIndex]
			content := []any{}
			if streamed {
				apply(map[string]any{"type": "stream_event", "event": map[string]any{"type": "message_start", "message": map[string]any{"id": id}}})
			}
			for index, text := range blocks {
				content = append(content, map[string]any{"type": "thinking", "thinking": text})
				if streamed {
					apply(map[string]any{"type": "stream_event", "event": map[string]any{"type": "content_block_start", "index": index, "content_block": map[string]any{"type": "thinking"}}})
					for _, delta := range []string{"", "\x00", text[:3], text[3:]} {
						apply(map[string]any{"type": "stream_event", "event": map[string]any{"type": "content_block_delta", "index": index, "delta": map[string]any{"type": "thinking_delta", "thinking": delta}}})
					}
				}
			}
			completed := map[string]any{"type": "assistant", "message": map[string]any{"id": id, "content": content, "stop_reason": "end_turn"}}
			apply(completed)
			apply(completed)
		}
		if got := turn.reasoningText(); got != want {
			t.Fatalf("streamed=%v reasoning=%q, want %q", streamed, got, want)
		}
		if turn.Foreground["text"] != want {
			t.Fatalf("streamed=%v foreground=%#v", streamed, turn.Foreground)
		}
		raw, err := state.Encode()
		if err != nil {
			t.Fatal(err)
		}
		restored, err := ParseState(raw)
		if err != nil || restored.Turns[0].reasoningText() != want {
			t.Fatalf("restored reasoning differs: %v", err)
		}
		for _, scope := range []model.RendererScope{{Kind: "overview"}, {Kind: "execution", Key: "execution"}} {
			projected, err := (StateAdapter{}).ProjectRenderer(raw, scope)
			if err != nil {
				t.Fatal(err)
			}
			decoded, err := ParseState(projected)
			if err != nil || decoded.Turns[0].reasoningText() != want {
				t.Fatalf("%s reasoning differs: %v", scope.Kind, err)
			}
		}
	}
}
