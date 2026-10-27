package main

import (
	"context"
	"encoding/json"
	"fmt"
	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	core "github.com/hupao-creator/Mokusei/internal/core/runtime"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"os"
	"path/filepath"
	"strings"
	"sync"
)

func must(err error) {
	if err != nil {
		panic(err)
	}
}
func check(ok bool, message string) {
	if !ok {
		panic(message)
	}
}
func main() {
	dir, err := os.MkdirTemp("", "mokusei-settings-shell-fixture-")
	must(err)
	defer os.RemoveAll(dir)
	db, err := store.Open(filepath.Join(dir, "state.sqlite"))
	must(err)
	defer db.Close()
	var mu sync.Mutex
	events := []model.Object{}
	r, err := core.New(context.Background(), core.Config{Store: db, DataDir: dir, DefaultCwd: dir, Harnesses: map[string]plugin.Harness{}, SettingsTrace: func(event string, fields model.Object) {
		mu.Lock()
		defer mu.Unlock()
		copy := model.Object{"event": event}
		for key, value := range fields {
			copy[key] = value
		}
		events = append(events, copy)
	}})
	must(err)
	defer r.Close(context.Background())
	settings, revision, err := r.Settings()
	must(err)
	sensitive := "private-settings-canary-ONLY-IN-SETTINGS"
	text := "  中文输入 🚀 "
	settings.Moku.RoutingGuidance = &text
	save := func(settings model.Settings, rev int64) (core.SettingsResult, error) {
		raw, _ := json.Marshal(model.Object{"settings": settings, "expectedSettingsRevision": rev})
		value, err := r.Invoke(context.Background(), "app:update-settings", []json.RawMessage{raw})
		if err != nil {
			return core.SettingsResult{}, err
		}
		return value.(core.SettingsResult), nil
	}
	saved, err := save(settings, revision)
	must(err)
	check(saved.Settings.Moku.RoutingGuidance != nil && *saved.Settings.Moku.RoutingGuidance == "中文输入 🚀", "trim normalization")
	settings = saved.Settings
	settings.Moku.RoutingGuidance = &sensitive
	saved, err = save(settings, saved.SettingsRevision)
	must(err)
	conflict, err := save(settings, revision)
	must(err)
	check(conflict.Status == "conflict" && conflict.SettingsRevision == saved.SettingsRevision, "conflict authority")
	text = " \n\t\ufeff "
	settings = saved.Settings
	settings.Moku.RoutingGuidance = &text
	saved, err = save(settings, saved.SettingsRevision)
	must(err)
	check(saved.Settings.Moku.RoutingGuidance == nil, "empty text did not clear to null")
	text = strings.Repeat("🚀", 6001)
	settings.Moku.RoutingGuidance = &text
	_, err = save(settings, saved.SettingsRevision)
	check(err != nil, "UTF16 limit ignored")
	current, currentRevision, err := r.Settings()
	must(err)
	check(currentRevision == saved.SettingsRevision && current.Moku.RoutingGuidance == nil, "invalid save mutated authority")
	raw, _ := json.Marshal(model.Object{"settings": current, "expectedSettingsRevision": currentRevision, "private-settings-canary-extra": sensitive})
	_, err = r.Invoke(context.Background(), "app:update-settings", []json.RawMessage{raw})
	check(err != nil, "unknown root accepted")
	var retired model.Object
	must(json.Unmarshal(raw, &retired))
	delete(retired, "private-settings-canary-extra")
	retired["settings"].(map[string]any)["moku"].(map[string]any)["systemPrompt"] = sensitive
	raw, _ = json.Marshal(retired)
	_, err = r.Invoke(context.Background(), "app:update-settings", []json.RawMessage{raw})
	check(err != nil, "retired system prompt replacement accepted")
	delete(retired["settings"].(map[string]any)["moku"].(map[string]any), "systemPrompt")
	retired["settings"].(map[string]any)["moku"].(map[string]any)["additionalSystemPrompt"] = sensitive
	raw, _ = json.Marshal(retired)
	_, err = r.Invoke(context.Background(), "app:update-settings", []json.RawMessage{raw})
	check(err != nil, "retired additional system prompt accepted")
	unchanged, unchangedRevision, err := r.Settings()
	must(err)
	check(unchangedRevision == currentRevision && unchanged.Moku.RoutingGuidance == nil, "retired setting mutated authority")
	publicSettings, err := json.Marshal(unchanged)
	must(err)
	check(!strings.Contains(string(publicSettings), "additionalSystemPrompt"), "retired setting exposed publicly")
	raw, _ = json.Marshal(model.Object{"settings": current})
	_, err = r.Invoke(context.Background(), "app:update-settings", []json.RawMessage{raw})
	check(err != nil, "missing revision accepted")
	flow := "123e4567-e89b-42d3-a456-426614174000"
	raw, _ = json.Marshal([]any{model.Object{"event": "conflict", "outcome": "keep", "flowId": flow, "operationId": "settings_fixture_command_123", "revision": currentRevision}})
	_, err = r.Invoke(context.Background(), "settings:diagnostics", []json.RawMessage{raw})
	must(err)
	// Client-only preferences contribute field names, never their values or CAS state.
	raw, _ = json.Marshal([]any{model.Object{"event": "preferences", "outcome": "saved", "flowId": flow, "fields": []string{"glassWorld"}}})
	_, err = r.Invoke(context.Background(), "settings:diagnostics", []json.RawMessage{raw})
	must(err)
	raw, _ = json.Marshal([]any{model.Object{"event": "preferences", "outcome": "saved", "flowId": flow, "fields": []string{"glassWorld"}, "glassWorld": false}})
	_, err = r.Invoke(context.Background(), "settings:diagnostics", []json.RawMessage{raw})
	check(err != nil, "preference value accepted in diagnostics")
	bad := []any{model.Object{"event": "edit", "outcome": "pending", "flowId": flow, "text": sensitive}}
	raw, _ = json.Marshal(bad)
	_, err = r.Invoke(context.Background(), "settings:diagnostics", []json.RawMessage{raw})
	check(err != nil, "arbitrary diagnostic content accepted")
	large := []any{}
	for i := 0; i < 33; i++ {
		large = append(large, model.Object{"event": "edit", "outcome": "pending", "flowId": flow})
	}
	raw, _ = json.Marshal(large)
	_, err = r.Invoke(context.Background(), "settings:diagnostics", []json.RawMessage{raw})
	check(err != nil, "diagnostic bound ignored")
	mu.Lock()
	defer mu.Unlock()
	seen := map[string]bool{}
	client := false
	glassWorld := false
	for _, event := range events {
		if event["event"] == "client.preferences" {
			fields, _ := event["fields"].([]string)
			glassWorld = len(fields) == 1 && fields[0] == "glassWorld"
		}
		seen[event["event"].(string)] = true
		if event["event"] == "client.conflict" && event["flowId"] == flow && event["traceId"] == "settings_fixture_command_123" {
			client = true
		}
	}
	for _, name := range []string{"command.started", "command.completed", "command.rejected", "save.started", "save.admitted", "save.changed", "validate.plugins.completed", "validate.profiles.completed", "persist.completed", "published", "save.saved", "save.conflict"} {
		check(seen[name], "missing "+name)
	}
	check(client, "native client trace missing")
	check(glassWorld, "glass world preference diagnostic missing")
	data, _ := json.Marshal(events)
	check(!strings.Contains(string(data), "private-settings-canary"), "settings value leaked to diagnostics")
	fmt.Println("PASS settings shell normalize/null/UTF16, conflict/no partial save, strict required/unknown fields, bounded client diagnostics, stage traces and canary redaction")
}
