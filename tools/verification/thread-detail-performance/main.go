// Command thread-detail-performance checks the production reader projection boundary.
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"reflect"
	"strings"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/claude"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/codex"
)

func main() {
	for _, status := range []string{"running", "completed", "failed", "interrupted"} {
		c := codex.StageExecution(codex.EmptyState(1), "one", codex.Map{"parts": []any{codex.Map{"kind": "text", "text": "prompt"}}}, 2, nil)
		steps := []any{}
		for i := 0; i < 100; i++ {
			steps = append(steps, codex.Map{"step": strings.Repeat("p", 1024), "status": "pending"})
		}
		c = codex.ReduceEvent(c, "one", codex.Map{"type": "plan", "steps": steps, "explanation": "hidden explanation", "at": 3})
		c = codex.ReduceEvent(c, "one", codex.Map{"type": "reasoning-delta", "delta": "reasoning", "at": 4})
		c = codex.ReduceEvent(c, "one", codex.Map{"type": "text-final", "itemId": "answer", "text": "answer", "at": 5})
		if status != "running" {
			c = codex.SettleExecution(c, "one", status, 6, "failure")
		}
		verify("codex/"+status, codex.NewSessionStateAdapter(), encode(c), "turn:one", false)
		if status != "running" {
			history := codex.EmptyState(7)
			history["forkHistory"] = c["turns"]
			verify("codex/history/"+status, codex.NewSessionStateAdapter(), encode(history), "turn:one", true)
		}

		s := claude.NewState()
		t := s.NewTurn("one", model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "prompt"}}}, claude.Settings{})
		for _, step := range steps {
			t.Plan = append(t.Plan, step.(map[string]any))
		}
		t.PlanExplanation = "hidden explanation"
		t.Timeline = append(t.Timeline, map[string]any{"id": "plan", "kind": "plan", "createdAt": t.CreatedAt})
		t.Text = "answer"
		t.Reasoning = "reasoning"
		t.Timeline = append(t.Timeline, map[string]any{"id": "reasoning", "kind": "reasoning", "content": "reasoning", "createdAt": t.CreatedAt}, map[string]any{"id": "answer", "kind": "assistant", "content": "answer", "status": "complete", "createdAt": t.CreatedAt})
		t.Status = status
		if status != "running" {
			t.FinishedAt = &t.UpdatedAt
		}
		verify("claude/"+status, claude.StateAdapter{}, encode(s), "one", false)
	}
	verifyClaudeHistory()
	fmt.Println("PASS reader plans omitted; other fields, source, overview, context and full execution preserved")
}
func encode(value any) json.RawMessage { raw, err := json.Marshal(value); must(err); return raw }
func decode(raw json.RawMessage) map[string]any {
	var value map[string]any
	must(json.Unmarshal(raw, &value))
	return value
}
func must(err error) {
	if err != nil {
		panic(err)
	}
}

func verify(name string, adapter plugin.SessionStateAdapter, raw json.RawMessage, key string, history bool) {
	before := bytes.Clone(raw)
	full, err := adapter.ProjectRenderer(raw, model.RendererScope{Kind: "execution", Key: key})
	must(err)
	overview, err := adapter.ProjectRenderer(raw, model.RendererScope{Kind: "overview"})
	must(err)
	context, err := adapter.ReadContext(raw)
	must(err)
	reading, err := adapter.ProjectRenderer(raw, model.RendererScope{Kind: "turn", Key: key})
	must(err)
	value := decode(reading)
	if value["kind"] == "deferred-execution" {
		if len(value["nonempty"].([]any)) == 0 {
			panic(name + ": reasoning presence lost")
		}
		value = value["state"].(map[string]any)
	}
	field := "turns"
	if history {
		field = "forkHistory"
	}
	turn := value[field].([]any)[0].(map[string]any)
	if len(turn["plan"].([]any)) != 0 || turn["planExplanation"] != nil {
		panic(name + ": plan payload retained")
	}
	for _, item := range turn["timeline"].([]any) {
		if item.(map[string]any)["kind"] == "plan" {
			panic(name + ": plan timeline retained")
		}
	}

	fullTurn := decode(full)[field].([]any)[0].(map[string]any)
	if len(fullTurn["plan"].([]any)) != 100 || fullTurn["planExplanation"] != "hidden explanation" {
		panic(name + ": full execution lost plan")
	}
	if !history && (!bytes.Contains(overview, []byte(strings.Repeat("p", 100))) || !bytes.Contains(context, []byte("hidden explanation"))) {
		panic(name + ": overview/context lost plan")
	}
	ids := []any{}
	for _, item := range fullTurn["timeline"].([]any) {
		if item.(map[string]any)["kind"] != "plan" {
			ids = append(ids, item.(map[string]any)["id"])
		}
	}
	actualIDs := []any{}
	for _, item := range turn["timeline"].([]any) {
		actualIDs = append(actualIDs, item.(map[string]any)["id"])
	}
	if !reflect.DeepEqual(ids, actualIDs) {
		panic(name + ": reading timeline identities changed")
	}
	for _, field := range []string{"messages", "prompts", "promptAttachments", "answer", "text", "status", "usage"} {
		if !reflect.DeepEqual(fullTurn[field], turn[field]) {
			panic(name + ": reading field lost: " + field)
		}
	}
	// Removing only these known fields from the full view gives the same reader
	// content for running turns. Settled turns already have deferred redaction.
	if strings.HasSuffix(name, "/running") {
		expected := decode(full)
		expectedTurn := expected[field].([]any)[0].(map[string]any)
		expectedTurn["plan"] = []any{}
		delete(expectedTurn, "planExplanation")
		items := []any{}
		for _, item := range expectedTurn["timeline"].([]any) {
			if item.(map[string]any)["kind"] != "plan" {
				items = append(items, item)
			}
		}
		expectedTurn["timeline"] = items
		if !reflect.DeepEqual(expected, value) {
			panic(name + ": unrelated reader field changed")
		}
	}
	again, err := adapter.ProjectRenderer(raw, model.RendererScope{Kind: "execution", Key: key})
	must(err)
	overviewAgain, err := adapter.ProjectRenderer(raw, model.RendererScope{Kind: "overview"})
	must(err)
	contextAgain, err := adapter.ReadContext(raw)
	must(err)
	if !bytes.Equal(raw, before) || !reflect.DeepEqual(decode(full), decode(again)) || !bytes.Equal(overview, overviewAgain) || !bytes.Equal(context, contextAgain) {
		panic(name + ": another consumer changed")
	}
	fmt.Printf("%s full=%d reader=%d bytes\n", name, len(full), len(reading))
}

func verifyClaudeHistory() {
	s := claude.NewState()
	s.ForkHistory = map[string]any{"sourceSessionId": "source", "items": []any{
		map[string]any{"id": "prompt", "kind": "user-message", "content": "prompt", "createdAt": 1},
		map[string]any{"id": "plan", "kind": "plan", "plan": []any{map[string]any{"step": "hidden", "status": "pending"}}, "createdAt": 2},
	}}
	raw := encode(s)
	adapter := claude.StateAdapter{}
	full, err := adapter.ProjectRenderer(raw, model.RendererScope{Kind: "execution", Key: "fork-history"})
	must(err)
	reading, err := adapter.ProjectRenderer(raw, model.RendererScope{Kind: "turn", Key: "fork-history"})
	must(err)
	state := decode(reading)["state"].(map[string]any)
	items := state["forkHistory"].(map[string]any)["items"].([]any)
	if len(items) != 1 || items[0].(map[string]any)["content"] != "prompt" {
		panic("Claude inherited reader lost prompt or retained plan")
	}
	if len(decode(full)["forkHistory"].(map[string]any)["items"].([]any)) != 2 {
		panic("Claude inherited full execution lost plan")
	}
	fmt.Printf("claude/history full=%d reader=%d bytes\n", len(full), len(reading))
}
