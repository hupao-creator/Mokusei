// Package firstresponse exercises real Harness renderer boundaries for the
// native first-response replay. It exports projections, never a UI reducer.
package firstresponse

import (
	"encoding/json"
	"fmt"
	"os"
	"reflect"
	"strings"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/claude"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/codex"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/opencode"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/pi"
)

const Prompt = "USER_PROMPT_MUST_NOT_APPEAR_IN_BODY"
const Answer = "AGENT_CONTENT_TAKES_OVER"

type Fixture struct {
	Harness     string                  `json:"harness"`
	Name        string                  `json:"name"`
	State       json.RawMessage         `json:"state"`
	Observation model.PublicObservation `json:"observation"`
	Initial     bool                    `json:"initial"`
	Agent       bool                    `json:"agent"`
}

func encode(value any) json.RawMessage {
	b, err := json.Marshal(value)
	if err != nil {
		panic(err)
	}
	return b
}
func adapter(id string) plugin.SessionStateAdapter {
	switch id {
	case "codex":
		return codex.NewSessionStateAdapter()
	case "claude":
		return claude.StateAdapter{}
	case "pi":
		return pi.New(plugin.HostContext{}).SessionState()
	default:
		return opencode.StateAdapter{}
	}
}
func base(id string) map[string]any {
	at := time.Now().UnixMilli()
	input := model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: Prompt}}}
	var raw json.RawMessage
	switch id {
	case "codex":
		raw = encode(codex.StageExecution(codex.EmptyState(at-1), "first", codex.Map{"parts": []any{codex.Map{"kind": "text", "text": Prompt}}}, at, nil))
	case "claude":
		s := claude.NewState()
		s.NewTurn("first", input, claude.Settings{})
		raw = encode(s)
	case "pi":
		raw = encode(pi.State{Version: 1, Messages: []pi.MessageState{{ID: "prompt", ExecutionID: "first", Role: "user", Text: Prompt}}, Executions: []model.PublicExecution{{ExecutionID: "first", Status: "running", StartedAt: at}}, LatestExecutionID: ptr("first")})
	case "opencode":
		s, _ := opencode.DecodeState(nil)
		_ = s.Begin("first", at)
		s.Messages = append(s.Messages, &opencode.Message{ID: "prompt", ExecutionID: "first", Role: "user", Text: Prompt})
		raw = s.Encode()
	}
	var result map[string]any
	if err := json.Unmarshal(raw, &result); err != nil {
		panic(err)
	}
	return result
}
func ptr[T any](v T) *T { return &v }
func first(state map[string]any, id string) map[string]any {
	key := "executions"
	if id == "codex" || id == "claude" {
		key = "turns"
	}
	return state[key].([]any)[0].(map[string]any)
}

func Verify(id string) ([]Fixture, error) {
	a := adapter(id)
	fixtures := []Fixture{}
	for _, name := range []string{"empty", "running", "incomplete", "reasoning", "answer", "failed", "interrupted", "completed", "second", "fork", "tool-plan", "long-prompt"} {
		state := base(id)
		turn := first(state, id)
		initial, agent := true, false
		switch name {
		case "incomplete", "reasoning", "answer":
			complete := name == "answer"
			agent = name != "incomplete"
			status := "streaming"
			if complete {
				status = "complete"
			}
			if id == "codex" || id == "claude" {
				kind := "assistant"
				if name == "reasoning" {
					kind = "reasoning"
				}
				item := map[string]any{"id": "agent", "kind": kind, "createdAt": turn["createdAt"], "content": Answer}
				if kind == "assistant" {
					item["status"] = status
					if id == "codex" {
						item["itemId"] = "native"
					} else {
						item["messageId"] = "native"
					}
				}
				turn["timeline"] = append(turn["timeline"].([]any), item)
			} else {
				m := map[string]any{"id": "agent", "executionId": "first", "role": "assistant", "status": status, "text": ""}
				if complete {
					m["text"] = Answer
				} else if name == "reasoning" {
					m["thinking"] = Answer
				} else {
					m["text"] = Answer
				}
				if id == "opencode" {
					m["parts"] = []any{}
				}
				state["messages"] = append(state["messages"].([]any), m)
			}
		case "failed", "interrupted", "completed", "second":
			outcome := name
			if name == "second" {
				outcome = "completed"
			}
			turn["status"] = outcome
			if at, ok := turn["updatedAt"].(float64); ok {
				turn["finishedAt"] = at
			} else {
				turn["finishedAt"] = turn["startedAt"].(float64) + 1
			}
			if name == "second" {
				initial = false
				key := "executions"
				if id == "codex" || id == "claude" {
					key = "turns"
				}
				var next map[string]any
				_ = json.Unmarshal(encode(turn), &next)
				next["executionId"] = "second"
				state[key] = append(state[key].([]any), next)
				if key == "executions" {
					state["latestExecutionId"] = "second"
				}
			}
		case "fork":
			initial = false
			switch id {
			case "codex":
				state["nativeHistorySeed"] = "history"
			case "claude":
				state["pendingFork"] = map[string]any{"sourceSessionId": "source"}
			case "pi":
				state["forkSource"] = map[string]any{"jsonl": "history"}
			case "opencode":
				state["forkSource"] = map[string]any{"sessionId": "source", "transcript": map[string]any{}}
			}
		case "tool-plan":
			if id == "codex" || id == "claude" {
				turn["plan"] = []any{map[string]any{"step": "REAL_PLAN", "status": "pending"}}
			}
		case "long-prompt":
			if id == "codex" {
				turn["messages"].([]any)[0].(map[string]any)["content"] = strings.Repeat(Prompt+"😀", 1000)
			} else if id == "claude" {
				turn["prompts"] = []any{strings.Repeat(Prompt+"😀", 1000)}
			} else {
				state["messages"].([]any)[0].(map[string]any)["text"] = strings.Repeat(Prompt+"😀", 1000)
			}
		}
		raw := encode(state)
		if name == "empty" {
			raw = json.RawMessage("null")
		}
		obs, err := a.Project(raw)
		if err != nil {
			return nil, fmt.Errorf("%s/%s observation: %w", id, name, err)
		}
		before := append([]byte{}, raw...)
		projected, err := a.ProjectRenderer(raw, model.RendererScope{Kind: "overview"})
		if err != nil {
			return nil, fmt.Errorf("%s/%s renderer: %w", id, name, err)
		}
		var value map[string]any
		_ = json.Unmarshal(projected, &value)
		if value["initialResponseScope"] != initial {
			return nil, fmt.Errorf("%s/%s scope = %v", id, name, value["initialResponseScope"])
		}
		if !reflect.DeepEqual(before, []byte(raw)) {
			return nil, fmt.Errorf("%s/%s mutated canonical bytes", id, name)
		}
		full, err := a.ProjectRenderer(raw, model.RendererScope{Kind: "thread"})
		if err != nil {
			return nil, err
		}
		var fullValue map[string]any
		_ = json.Unmarshal(full, &fullValue)
		if _, ok := fullValue["initialResponseScope"]; ok {
			return nil, fmt.Errorf("%s flag escaped overview", id)
		}
		fixtures = append(fixtures, Fixture{id, name, projected, obs, initial, agent})
	}
	fmt.Printf("PASS %s initial-response overview scope and canonical isolation (%d fixtures)\n", id, len(fixtures))
	return fixtures, nil
}
func Export(path string) error {
	all := []Fixture{}
	for _, id := range []string{"codex", "claude", "pi", "opencode"} {
		f, err := Verify(id)
		if err != nil {
			return err
		}
		all = append(all, f...)
	}
	return os.WriteFile(path, encode(all), 0600)
}
