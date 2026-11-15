package pi

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/sessioncache"
)

func TestRendererExecutionAuthorsFollowScope(t *testing.T) {
	finished := int64(4)
	latest := "target"
	state := State{
		Version: 1,
		Messages: []MessageState{
			{ID: "target-user", ExecutionID: "target", Role: "user", Text: "target", CreatedAt: 1},
			{ID: "target-assistant", ExecutionID: "target", Role: "assistant", Text: "target reply", Status: "complete"},
		},
		Executions: []model.PublicExecution{
			{ExecutionID: "target", Status: "completed", StartedAt: 1, FinishedAt: &finished},
		},
		LatestExecutionID: &latest,
		ExecutionAuthors: map[string]json.RawMessage{
			"target": json.RawMessage(`{"model":"target"}`),
			"other":  json.RawMessage(`{"model":"other"}`),
		},
	}
	raw, err := json.Marshal(state)
	if err != nil {
		t.Fatal(err)
	}
	for _, scope := range []model.RendererScope{{Kind: "turn", Key: "target"}, {Kind: "execution", Key: "target"}} {
		projected, err := (stateAdapter{}).ProjectRenderer(raw, scope)
		if err != nil {
			t.Fatal(err)
		}
		var envelope struct {
			Kind  string          `json:"kind"`
			State json.RawMessage `json:"state"`
		}
		if err := json.Unmarshal(projected, &envelope); err != nil {
			t.Fatal(err)
		}
		if envelope.Kind == "deferred-execution" {
			projected = envelope.State
		}
		var value struct {
			ExecutionAuthors map[string]json.RawMessage `json:"executionAuthors"`
		}
		if err := json.Unmarshal(projected, &value); err != nil {
			t.Fatal(err)
		}
		if len(value.ExecutionAuthors) != 1 || value.ExecutionAuthors["target"] == nil {
			t.Fatalf("%s authors = %v", scope.Kind, value.ExecutionAuthors)
		}
	}
	projected, err := (stateAdapter{}).ProjectRenderer(raw, model.RendererScope{Kind: "overview"})
	if err != nil {
		t.Fatal(err)
	}
	var overview struct {
		ExecutionAuthors map[string]json.RawMessage `json:"executionAuthors"`
	}
	if err := json.Unmarshal(projected, &overview); err != nil {
		t.Fatal(err)
	}
	if overview.ExecutionAuthors["other"] != nil {
		t.Fatalf("overview retained unrelated author: %v", overview.ExecutionAuthors)
	}
}

func TestReaderExecutionAuthorsFollowScope(t *testing.T) {
	finished := int64(4)
	latest := "target"
	state := State{
		Version: 1,
		Messages: []MessageState{
			{ID: "target-user", ExecutionID: "target", Role: "user", Text: "target", CreatedAt: 1},
			{ID: "target-assistant", ExecutionID: "target", Role: "assistant", Text: "target reply", Status: "complete"},
		},
		Executions: []model.PublicExecution{
			{ExecutionID: "target", Status: "completed", StartedAt: 1, FinishedAt: &finished},
		},
		LatestExecutionID: &latest,
		ExecutionAuthors: map[string]json.RawMessage{
			"target": json.RawMessage(`{"model":"target"}`),
			"other":  json.RawMessage(`{"model":"other"}`),
		},
	}
	raw, err := json.Marshal(state)
	if err != nil {
		t.Fatal(err)
	}
	adapter := newStateAdapter()
	for _, scope := range []model.RendererScope{{Kind: "turn", Key: "target"}, {Kind: "execution", Key: "target"}} {
		result, err := adapter.ProjectReader(context.Background(), plugin.ReaderRequest{ThreadID: "thread", ContentID: sessioncache.Identity(raw), State: raw, Scope: scope, Generation: 1})
		if err != nil || result == nil {
			t.Fatalf("%s reader projection = %v, %v", scope.Kind, result, err)
		}
		var envelope struct {
			Kind  string          `json:"kind"`
			State json.RawMessage `json:"state"`
		}
		value := result.Value
		if err := json.Unmarshal(value, &envelope); err != nil {
			t.Fatal(err)
		}
		if envelope.Kind == "deferred-execution" {
			value = envelope.State
		}
		var projected struct {
			ExecutionAuthors map[string]json.RawMessage `json:"executionAuthors"`
		}
		if err := json.Unmarshal(value, &projected); err != nil {
			t.Fatal(err)
		}
		if len(projected.ExecutionAuthors) != 1 || projected.ExecutionAuthors["target"] == nil {
			t.Fatalf("%s reader authors = %v", scope.Kind, projected.ExecutionAuthors)
		}
	}
	adapter.EvictThread("thread")
}
