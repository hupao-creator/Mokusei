package main

import (
	"bytes"
	"context"
	"encoding/json"
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

// Pi omits detected compatibility defaults from RPC model metadata. Exercise
// its actual Chat encoder so an omitted flag cannot hide a working model, and
// explicit overrides cannot advertise an effort that never reaches the wire.
func verifyNativeChatThinking(ctx context.Context, root, wrapper string, environment map[string]string) error {
	yes, no := true, false
	cases := []struct {
		name, provider, path string
		forwarding           *bool
		effort               bool
	}{
		{name: "native-deepseek", provider: "deepseek", path: "/v1", effort: true},
		{name: "explicit-disabled", provider: "deepseek", path: "/v1", forwarding: &no},
		{name: "native-disabled", provider: "xai", path: "/v1"},
		{name: "url-disabled", provider: "local-chat", path: "/api.x.ai/v1"},
		{name: "explicit-enabled", provider: "xai", path: "/v1", forwarding: &yes, effort: true},
	}
	for _, tc := range cases {
		if err := func() error {
			var requests atomic.Int32
			var expectedType, expectedEffort atomic.Value
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				var body map[string]any
				if r.Method != "POST" || r.URL.Path != tc.path+"/chat/completions" || json.NewDecoder(http.MaxBytesReader(w, r.Body, 8<<20)).Decode(&body) != nil {
					http.Error(w, "unexpected Chat request", 400)
					return
				}
				thinking, _ := body["thinking"].(map[string]any)
				effort, hasEffort := body["reasoning_effort"]
				wantEffort := expectedEffort.Load().(string)
				if body["model"] != tc.name || thinking["type"] != expectedType.Load() || (wantEffort == "" && hasEffort) || (wantEffort != "" && effort != wantEffort) {
					http.Error(w, "wrong model, thinking switch or effort", 400)
					return
				}
				requests.Add(1)
				w.Header().Set("Content-Type", "text/event-stream")
				for _, choice := range []map[string]any{
					{"index": 0, "delta": map[string]any{"role": "assistant", "content": "CHAT_THINKING_OK"}, "finish_reason": nil},
					{"index": 0, "delta": map[string]any{}, "finish_reason": "stop"},
				} {
					raw, _ := json.Marshal(map[string]any{"id": "chat-proof", "object": "chat.completion.chunk", "created": 1, "model": tc.name, "choices": []any{choice}})
					fmt.Fprintf(w, "data: %s\n\n", raw)
				}
				fmt.Fprint(w, "data: [DONE]\n\n")
			}))
			defer server.Close()
			env := map[string]string{}
			for k, v := range environment {
				env[k] = v
			}
			env["PI_CODING_AGENT_DIR"] = filepath.Join(root, tc.name)
			if err := os.MkdirAll(env["PI_CODING_AGENT_DIR"], 0700); err != nil {
				return err
			}
			compat := map[string]any{"thinkingFormat": "deepseek"}
			if tc.forwarding != nil {
				compat["supportsReasoningEffort"] = *tc.forwarding
			}
			models := map[string]any{"providers": map[string]any{tc.provider: map[string]any{
				"baseUrl": server.URL + tc.path, "api": "openai-completions", "apiKey": "local-fixture-only",
				"models": []any{map[string]any{"id": tc.name, "reasoning": true, "input": []string{"text"}, "contextWindow": 32768, "maxTokens": 128,
					"compat": compat, "thinkingLevelMap": map[string]any{"minimal": nil, "low": "low", "medium": nil, "high": "high", "max": "max"}}},
			}}}
			raw, _ := json.Marshal(models)
			if err := os.WriteFile(filepath.Join(env["PI_CODING_AGENT_DIR"], "models.json"), raw, 0600); err != nil {
				return err
			}
			adapter := pi.New(plugin.HostContext{HarnessDataRoot: filepath.Join(root, tc.name+"-data"), Environment: func(context.Context) (map[string]string, error) { return env, nil }, ResolveExecutable: func(context.Context, string, string, string) (string, error) { return wrapper, nil }})
			cwd := filepath.Join(root, "work")
			schema, err := adapter.Settings().Describe(ctx, plugin.SettingsRequest{Settings: adapter.DefaultSettings(), Cwd: cwd})
			if err != nil {
				return err
			}
			if !bytes.Contains(schema, []byte(`"`+tc.name+`"`)) {
				return fmt.Errorf("native model missing from ordinary Thread schema")
			}
			choices := []model.ThinkingChoice{{Mode: "off"}}
			if tc.effort {
				for _, effort := range []string{"low", "high", "max"} {
					choices = append(choices, model.ThinkingChoice{Mode: "effort", Effort: effort})
				}
			} else {
				choices = append(choices, model.ThinkingChoice{Mode: "on"})
			}
			resolve := func(choice model.ThinkingChoice) (json.RawMessage, error) {
				requested, _ := json.Marshal(pi.ThreadSettings{Provider: tc.provider, Model: tc.name, Thinking: &choice})
				return adapter.Settings().ResolveThread(ctx, plugin.ResolveSettingsRequest{Merged: requested, Requested: requested, Cwd: cwd})
			}
			for _, choice := range choices {
				settings, err := resolve(choice)
				if err != nil {
					return err
				}
				expectedType.Store("enabled")
				if choice.Mode == "off" {
					expectedType.Store("disabled")
				}
				expectedEffort.Store(choice.Effort)
				result, err := adapter.Complete(ctx, plugin.PromptRequest{Settings: settings, Messages: []plugin.PromptMessage{{Role: "user", Content: "Reply CHAT_THINKING_OK"}}, OutputFormat: plugin.PromptOutputFormat{Type: "text"}})
				if err != nil {
					return err
				}
				if result.Output.Text != "CHAT_THINKING_OK" {
					return fmt.Errorf("Chat completion changed reply")
				}
			}
			unsupported := "medium"
			if !tc.effort {
				unsupported = "high"
			}
			if _, err := resolve(model.ThinkingChoice{Mode: "effort", Effort: unsupported}); err == nil {
				return fmt.Errorf("unsupported effort accepted")
			}
			if int(requests.Load()) != len(choices) {
				return fmt.Errorf("Chat request count changed")
			}
			fmt.Println("PASS installed Pi Chat thinking:", tc.name, "schema, exact switch/effort on wire, unsupported effort rejected")
			return nil
		}(); err != nil {
			return fmt.Errorf("native Chat %s: %w", tc.name, err)
		}
	}
	return nil
}
