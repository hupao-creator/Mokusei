package main

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	oc "github.com/hupao-creator/Mokusei/internal/plugins/harness/opencode"
)

// Exercise the settings and Thread adapters against the installed engine. A
// protocol-shaped fake alone cannot establish native default-agent ordering or
// prove that changing models preserves the native conversation.
func verifyNativeSettings(parent context.Context, nativeCLI, cwd string, env map[string]string, config oc.Object, requests func() []map[string]any) {
	ctx, cancel := context.WithTimeout(parent, 60*time.Second)
	defer cancel()
	providers := config["providers"].(map[string]any)
	providers["fixture-next"] = oc.Object{
		"package":  "@opencode/ai/providers/openai-compatible",
		"settings": providers["fixture"].(map[string]any)["settings"],
		"models": oc.Object{"next-model": oc.Object{
			"name": "Next fixture", "modelID": "next-wire-model",
			"capabilities": oc.Object{"tools": true, "input": []string{"text"}, "output": []string{"text"}},
			"limit":        oc.Object{"context": 32000, "output": 1024},
			"variants":     []oc.Object{{"id": "replay-low", "body": oc.Object{"reasoning_effort": "low"}}},
		}},
	}
	launch := func(ctx context.Context, settings oc.Settings, directory string) (*oc.Runtime, error) {
		return oc.NewRuntime(ctx, oc.Options{CWD: directory, ExecutablePath: nativeCLI, Environment: env, Config: config, IsolateConfig: true})
	}
	api := oc.NewSettings(plugin.HostContext{Environment: func(context.Context) (map[string]string, error) { return env, nil }}, launch)
	defer api.Close()
	defaults := json.RawMessage(`{"threadSettings":{}}`)
	snapshot, err := api.SnapshotExecution(ctx, plugin.SettingsRequest{Settings: defaults, Cwd: cwd}, true)
	must(err)
	var pinned oc.HarnessSettings
	must(json.Unmarshal(snapshot, &pinned))
	if pinned.ThreadSettings.Agent == "" || pinned.ThreadSettings.Provider != "fixture" || pinned.ThreadSettings.Model != "fixture-model" || pinned.ThreadSettings.Variant == "" || pinned.ThreadSettings.PermissionMode != "auto" {
		panic(fmt.Sprintf("native defaults were not fully pinned: %s", snapshot))
	}
	saved, err := api.SnapshotExecution(ctx, plugin.SettingsRequest{Settings: snapshot, Cwd: cwd}, false)
	must(err)
	if string(saved) != string(snapshot) {
		panic("saving the native execution snapshot changed its selection")
	}
	presentation, err := api.Presentation(ctx, plugin.SettingsPresentationRequest{Settings: snapshot, Cwd: cwd})
	must(err)
	var view struct {
		Models []oc.CatalogModel `json:"models"`
	}
	must(json.Unmarshal(presentation, &view))
	found := false
	for _, entry := range view.Models {
		if entry.Provider == "fixture-next" && entry.ID == "next-model" {
			found = entry.ModelID == "next-wire-model" && entry.Thinking != nil && entry.Thinking.Kind == "effort"
		}
	}
	if !found || strings.Contains(string(presentation), "synthetic-only") {
		panic("native model catalog lost model identity/thinking capability or exposed credentials")
	}
	resolved, err := api.ResolveThread(ctx, plugin.ResolveSettingsRequest{
		Merged: json.RawMessage(`{}`), Existing: json.RawMessage(`null`), Cwd: cwd,
		Requested: json.RawMessage(`{"provider":"fixture","model":"fixture-model","thinking":{"mode":"effort","effort":"low"}}`),
	})
	must(err)
	var settingsMu sync.Mutex
	current := resolved
	state := &settingsState{}
	handle, err := oc.OpenThread(ctx, plugin.OpenContext{
		ThreadID: "native-model-switch", SessionState: state, RequireExplicitSettings: true,
		ReadThread: func() model.SessionRecord {
			settingsMu.Lock()
			defer settingsMu.Unlock()
			return model.SessionRecord{Cwd: cwd, Settings: append(json.RawMessage{}, current...)}
		},
	}, func(ctx context.Context, settings oc.Settings, directory string, _ bool) (*oc.Runtime, error) {
		return launch(ctx, settings, directory)
	})
	must(err)
	defer handle.Close()
	wait := func(execution string) *oc.State {
		for {
			value, err := oc.DecodeState(state.Read())
			must(err)
			for _, entry := range value.Executions {
				if entry.ExecutionID == execution && entry.Terminal() {
					if entry.Status != "completed" {
						panic(fmt.Sprintf("native settings execution failed: %+v", entry))
					}
					return value
				}
			}
			select {
			case <-ctx.Done():
				panic(ctx.Err())
			case <-time.After(20 * time.Millisecond):
			}
		}
	}
	must(handle.Send(ctx, plugin.SendRequest{ExecutionID: "before-switch", Input: model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "Remember NATIVE_SWITCH_HISTORY and reply fixture JSON."}}}}))
	before := wait("before-switch")
	update := json.RawMessage(`{"provider":"fixture-next","model":"next-model","thinking":{"mode":"effort","effort":"low"}}`)
	next, err := api.ApplyThreadUpdate(ctx, plugin.UpdateSettingsRequest{Current: resolved, Defaults: json.RawMessage(`{}`), Update: update, Cwd: cwd, HasContent: true})
	must(err)
	normalized, err := oc.NormalizeThreadSettings(next)
	must(err)
	if normalized.Provider != "fixture-next" || normalized.Model != "next-model" || normalized.Variant != "replay-low" {
		panic(fmt.Sprintf("model change did not resolve its exact native variant: %s", next))
	}
	settingsMu.Lock()
	current = next
	settingsMu.Unlock()
	must(handle.Send(ctx, plugin.SendRequest{ExecutionID: "after-switch", Input: model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "Recall the prior marker and reply fixture JSON."}}}}))
	after := wait("after-switch")
	if before.NativeSessionID == "" || after.NativeSessionID != before.NativeSessionID || len(after.Executions) != 2 {
		panic("model change replaced the native conversation or lost executions")
	}
	all := requests()
	if len(all) < 3 {
		panic("native settings replay did not send both model requests")
	}
	last := all[len(all)-1]
	encoded, err := json.Marshal(last["messages"])
	must(err)
	if last["model"] != "next-wire-model" || last["reasoning_effort"] != "low" || !strings.Contains(string(encoded), "NATIVE_SWITCH_HISTORY") {
		panic("native model change lost wire model, thinking encoding or conversation history")
	}
	if after.ExecutionAuthors["after-switch"]["model"] != "fixture-next/next-model" || after.ExecutionAuthors["before-switch"]["model"] != "fixture/fixture-model" {
		panic("native model change rewrote execution model attribution")
	}
	must(handle.Close())
	must(api.Close())
	fmt.Println("PASS native settings: default-agent snapshot/save, credential-free catalog and thinking capability, exact cross-provider model update, preserved session/history, wire model/variant, terminal events and execution attribution")
}

type settingsState struct {
	mu  sync.Mutex
	raw json.RawMessage
}

func (s *settingsState) Read() json.RawMessage {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append(json.RawMessage{}, s.raw...)
}
func (s *settingsState) Commit(ctx context.Context, raw json.RawMessage) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.raw = append(json.RawMessage{}, raw...)
	return nil
}
