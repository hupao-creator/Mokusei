package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync/atomic"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/pi"
)

func verifyResponsesThinking() {
	yes := true
	low, high, none := "low", "high", "none"
	m := pi.Model{Provider: "xai", ID: "responses-fixture", API: "openai-responses", Reasoning: &yes, ThinkingLevelMap: map[string]*string{"off": nil, "minimal": nil, "low": &low, "medium": nil, "high": &high, "xhigh": nil, "max": nil}}
	capability := pi.ThinkingCapability(m, nil)
	check(capability.Kind == "effort" && len(capability.Efforts) == 2 && !capability.CanDisable, "Responses explicit effort mappings and no inferred off")
	level, err := pi.ThinkingLevel(model.ThinkingChoice{Mode: "effort", Effort: "high"}, m, nil)
	check(err == nil && level == "high", "Responses exact high choice")
	_, err = pi.ThinkingLevel(model.ThinkingChoice{Mode: "off"}, m, nil)
	check(err != nil, "Responses rejects disabled off")
	_, err = pi.ThinkingLevel(model.ThinkingChoice{Mode: "effort", Effort: "max"}, m, nil)
	check(err != nil, "Responses rejects unmapped max")
	m.ThinkingLevelMap["off"] = &none
	check(pi.ThinkingCapability(m, nil).CanDisable, "Responses explicit none allows off")
	m.ThinkingLevelMap = nil
	check(pi.ThinkingCapability(m, nil).Kind == "unknown", "Responses missing mappings fail closed")
	m.ThinkingLevelMap = map[string]*string{"high": &high}
	m.HasRequestOverrides = true
	check(pi.ThinkingCapability(m, nil).Kind == "unknown", "Responses request overrides remain unavailable")
	fmt.Println("PASS Pi Responses thinking: exact mapped effort, explicit off, unsupported effort, missing metadata and request override rejection")
}

// Run the installed Pi Responses encoder under the caller's existing
// loopback-only sandbox. Inspect the actual HTTP request, rather than assuming
// native get_state proves that the model received the selected effort.
func verifyNativeResponses(ctx context.Context, root, wrapper string, environment map[string]string) error {
	var requests atomic.Int32
	var correct atomic.Bool
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "POST" || r.URL.Path != "/v1/responses" {
			http.Error(w, "unexpected request", 400)
			return
		}
		var body map[string]any
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 8<<20)).Decode(&body); err != nil {
			http.Error(w, "invalid JSON", 400)
			return
		}
		requests.Add(1)
		reasoning, _ := body["reasoning"].(map[string]any)
		if body["model"] != "responses-proof" || reasoning["effort"] != "high" {
			http.Error(w, "wrong model or reasoning effort", 400)
			return
		}
		correct.Store(true)
		w.Header().Set("Content-Type", "text/event-stream")
		item := map[string]any{"id": "msg_responses", "type": "message", "role": "assistant", "status": "completed", "content": []any{map[string]any{"type": "output_text", "text": "RESPONSES_OK", "annotations": []any{}}}}
		response := map[string]any{"id": "resp_proof", "object": "response", "status": "completed", "model": "responses-proof", "output": []any{item}, "usage": map[string]any{"input_tokens": 12, "output_tokens": 3, "total_tokens": 15, "input_tokens_details": map[string]any{"cached_tokens": 0}, "output_tokens_details": map[string]any{"reasoning_tokens": 0}}}
		events := []map[string]any{
			{"type": "response.created", "response": map[string]any{"id": "resp_proof", "status": "in_progress", "output": []any{}}},
			{"type": "response.output_item.added", "output_index": 0, "item": map[string]any{"id": "msg_responses", "type": "message", "role": "assistant", "status": "in_progress", "content": []any{}}},
			{"type": "response.content_part.added", "item_id": "msg_responses", "output_index": 0, "content_index": 0, "part": map[string]any{"type": "output_text", "text": "", "annotations": []any{}}},
			{"type": "response.output_text.delta", "item_id": "msg_responses", "output_index": 0, "content_index": 0, "delta": "RESPONSES_OK"},
			{"type": "response.output_item.done", "output_index": 0, "item": item},
			{"type": "response.completed", "response": response},
		}
		for sequence, event := range events {
			event["sequence_number"] = sequence
			raw, _ := json.Marshal(event)
			fmt.Fprintf(w, "event: %s\ndata: %s\n\n", event["type"], raw)
			w.(http.Flusher).Flush()
		}
	}))
	defer server.Close()
	env := map[string]string{}
	for k, v := range environment {
		env[k] = v
	}
	env["PI_CODING_AGENT_DIR"] = filepath.Join(root, "responses-agent")
	if err := os.MkdirAll(env["PI_CODING_AGENT_DIR"], 0700); err != nil {
		return err
	}
	models := map[string]any{"providers": map[string]any{"responses-local": map[string]any{"baseUrl": server.URL + "/v1", "api": "openai-responses", "apiKey": "local-fixture-only", "models": []any{map[string]any{"id": "responses-proof", "name": "Responses proof", "reasoning": true, "input": []string{"text"}, "contextWindow": 32768, "maxTokens": 128, "thinkingLevelMap": map[string]any{"off": nil, "minimal": nil, "low": "low", "medium": "medium", "high": "high", "xhigh": nil, "max": nil}}}}}}
	raw, _ := json.Marshal(models)
	if err := os.WriteFile(filepath.Join(env["PI_CODING_AGENT_DIR"], "models.json"), raw, 0600); err != nil {
		return err
	}
	adapter := pi.New(plugin.HostContext{HarnessDataRoot: filepath.Join(root, "responses-data"), Environment: func(context.Context) (map[string]string, error) { return env, nil }, ResolveExecutable: func(context.Context, string, string, string) (string, error) { return wrapper, nil }})
	requested := json.RawMessage(`{"provider":"responses-local","model":"responses-proof","thinking":{"mode":"effort","effort":"high"}}`)
	settings, err := adapter.Settings().ResolveThread(ctx, plugin.ResolveSettingsRequest{Merged: requested, Requested: requested, Cwd: filepath.Join(root, "work")})
	if err != nil {
		return fmt.Errorf("native Responses thinking resolution: %w", err)
	}
	result, err := adapter.Complete(ctx, plugin.PromptRequest{Settings: settings, Messages: []plugin.PromptMessage{{Role: "user", Content: "Reply RESPONSES_OK"}}, OutputFormat: plugin.PromptOutputFormat{Type: "text"}})
	if err != nil {
		return fmt.Errorf("native Responses completion: %w", err)
	}
	if result.Output.Text != "RESPONSES_OK" || requests.Load() != 1 || !correct.Load() {
		return errors.New("native Responses did not preserve exact model/effort/reply")
	}
	fmt.Println("PASS installed Pi Responses: exact reasoning.effort=high on loopback wire and final completion; no account credentials")
	return nil
}
