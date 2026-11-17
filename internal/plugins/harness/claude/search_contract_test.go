package claude

import (
	"encoding/json"
	"github.com/hupao-creator/Mokusei/internal/core/model"
	"strings"
	"testing"
)

func TestSearchPassagesPublicCompletedOnly(t *testing.T) {
	state := NewState()
	for _, status := range []string{"completed", "failed", "interrupted", "running"} {
		text := "PRIVATE_" + status
		if status == "completed" {
			text = "公开内容"
		}
		turn := state.NewTurn(status, model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: text}}}, Settings{})
		turn.text(text+" assistant reply", "", false)
		turn.reasoning("PRIVATE_REASONING")
		turn.Status = status
		if status != "running" {
			finished := turn.UpdatedAt + 1
			turn.FinishedAt = &finished
		}
	}
	raw, err := state.Encode()
	if err != nil {
		t.Fatal(err)
	}
	passages, err := (StateAdapter{}).SearchPassages(raw)
	if err != nil {
		t.Fatal(err)
	}
	var text string
	for _, passage := range passages {
		text += passage.Text + "\n"
	}
	if !strings.Contains(text, "公开内容") || strings.Contains(text, "PRIVATE") {
		t.Fatalf("search content: %q", text)
	}
	if _, err := (StateAdapter{}).SearchPassages(json.RawMessage(`{`)); err == nil {
		t.Fatal("malformed state accepted")
	}
}
