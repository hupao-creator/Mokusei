package main

import (
	"context"
	"encoding/json"
	"fmt"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	oc "github.com/hupao-creator/Mokusei/internal/plugins/harness/opencode"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"
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
	parent, stopSignal := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stopSignal()
	fixtureCLI := os.Getenv("MOKUSEI_OPENCODE_FIXTURE")
	if fixtureCLI == "" {
		panic("run through tools/verification/opencode so the fixture is built first")
	}
	root, err := os.MkdirTemp("", "mokusei-settings-smoke-")
	must(err)
	defer os.RemoveAll(root)
	cwd := filepath.Join(root, "workspace")
	must(os.MkdirAll(cwd, 0700))
	configDir := filepath.Join(root, "config", "opencode")
	must(os.MkdirAll(filepath.Join(configDir, "agents"), 0700))
	must(os.WriteFile(filepath.Join(configDir, "opencode.jsonc"), []byte(`{
 // Native permission order must survive object decoding.
 "permission": {"read": {"z/*":"deny","a/*":"allow"}},
 "providers":{"fixture":{"settings":{"baseURL":"{env:FIXTURE_URL}"},"headers":{"Authorization":"first","authorization":"second"}}},
 "plugins":["never-load"], "mcp":{"never-load":{}},
 }`), 0600))
	must(os.WriteFile(filepath.Join(configDir, "agents", "review.md"), []byte("---\ndescription: Review: safely\nmodel: fixture/fixture-model\nvariant: low\npermission:\n  bash:\n    'z*': deny\n    'a*': allow\n---\nReview this change."), 0600))
	env := map[string]string{"HOME": root, "PATH": os.Getenv("PATH"), "XDG_CONFIG_HOME": filepath.Join(root, "config"), "XDG_DATA_HOME": filepath.Join(root, "data"), "OPENCODE_TEST_HOME": root, "OPENCODE_CONFIG_PROJECT_DISABLE": "1", "OPENCODE_DB": filepath.Join(root, "native.db"), "FIXTURE_ROOT": root, "FIXTURE_SETTINGS": "1", "FIXTURE_URL": "http://127.0.0.1:1/v1"}
	values, cleanup, err := oc.PrepareEnvironment(oc.Options{CWD: cwd, Environment: env, IsolateConfig: true}, filepath.Join(root, "bridge"))
	must(err)
	var content map[string]any
	for _, value := range values {
		key, raw, _ := strings.Cut(value, "=")
		if key == "OPENCODE_CONFIG_CONTENT" {
			must(json.Unmarshal([]byte(raw), &content))
		}
	}
	must(cleanup())
	check(content["mcp"] == nil, "native MCP escaped isolation")
	rules := content["permissions"].([]any)
	check(rules[0].(map[string]any)["resource"] == "z/*" && rules[1].(map[string]any)["resource"] == "a/*", "native permission order changed")
	provider := content["providers"].(map[string]any)["fixture"].(map[string]any)
	headers := provider["headers"].(map[string]any)
	check(len(headers) == 1 && headers["authorization"] == "second", "header case merge precedence changed")
	agent := content["agents"].(map[string]any)["review"].(map[string]any)
	check(agent["description"] == "Review: safely" && agent["system"] == "Review this change.", "Markdown frontmatter sanitizer failed")
	agentRules := agent["permissions"].([]any)
	check(agentRules[0].(map[string]any)["resource"] == "z*" && agentRules[1].(map[string]any)["resource"] == "a*", "YAML permission order changed")
	ctx, cancel := context.WithTimeout(parent, 15*time.Second)
	defer cancel()
	host := plugin.HostContext{Environment: func(context.Context) (map[string]string, error) { return env, nil }}
	launch := func(ctx context.Context, s oc.Settings, dir string) (*oc.Runtime, error) {
		return oc.NewRuntime(ctx, oc.Options{CWD: dir, ExecutablePath: fixtureCLI, Environment: env})
	}
	api := oc.NewSettings(host, launch)
	defer api.Close()
	defaults := json.RawMessage(`{"threadSettings":{}}`)
	request := plugin.SettingsPresentationRequest{Settings: defaults, Cwd: cwd}
	first, abort := context.WithCancel(ctx)
	done := make(chan error, 1)
	go func() { _, e := api.Presentation(first, request); done <- e }()
	time.Sleep(20 * time.Millisecond)
	go func() { time.Sleep(20 * time.Millisecond); abort() }()
	presentation, err := api.Presentation(ctx, request)
	must(err)
	check(<-done != nil, "canceled catalog waiter stayed active")
	sharedLog, err := os.ReadFile(filepath.Join(root, "operations.log"))
	must(err)
	check(strings.Count(string(sharedLog), "process-start") == 1, "catalog was not shared by active waiters")
	check(!strings.Contains(string(presentation), "synthetic-secret"), "catalog leaked provider secret")
	var view map[string]any
	must(json.Unmarshal(presentation, &view))
	check(len(view["models"].([]any)) == 1, "catalog missing enabled tool model")
	snapshot, err := api.SnapshotExecution(ctx, plugin.SettingsRequest{Settings: defaults, Cwd: cwd}, true)
	must(err)
	check(strings.Contains(string(snapshot), `"variant":"low"`), "snapshot did not pin native variant")
	check(strings.Contains(string(snapshot), `"agent":"native-primary"`), "snapshot did not pin the native default without default_agent")
	resolved, err := api.ResolveThread(ctx, plugin.ResolveSettingsRequest{Merged: json.RawMessage(`{}`), Existing: json.RawMessage(`null`), Requested: json.RawMessage(`{"provider":"fixture","model":"fixture-model","thinking":{"mode":"effort","effort":"low"}}`), Cwd: cwd})
	must(err)
	settings, err := oc.NormalizeThreadSettings(resolved)
	must(err)
	check(settings.Variant == "low" && settings.Agent == "native-primary", "explicit thinking did not resolve to exact variant")
	updated, err := api.ApplyThreadUpdate(ctx, plugin.UpdateSettingsRequest{Current: resolved, Defaults: json.RawMessage(`{}`), Update: json.RawMessage(`{"thinking":{"mode":"off"}}`), Cwd: cwd})
	must(err)
	check(strings.Contains(string(updated), `"variant":"off"`), "thinking update lost native selector")
	_, err = api.ApplyThreadUpdate(ctx, plugin.UpdateSettingsRequest{Current: resolved, Defaults: json.RawMessage(`{}`), Update: json.RawMessage(`{"model":"other"}`), Cwd: cwd})
	check(err != nil, "model change without thinking admitted")
	schema, err := api.Describe(ctx, plugin.SettingsRequest{Settings: defaults, Cwd: cwd})
	must(err)
	check(strings.Contains(string(schema), `"low"`), "native thinking schema missing")
	catalog, err := api.ModelCatalog(ctx, plugin.SettingsRequest{Settings: defaults, Cwd: cwd})
	must(err)
	check(strings.Contains(string(catalog), `fixture/fixture-model`), "model provenance catalog missing route")
	runtime, err := launch(ctx, settings, cwd)
	must(err)
	must(api.ValidateRuntimeSettings(ctx, runtime, settings, true, settings.NativeModel(), "extend"))
	err = api.ValidateRuntimeSettings(ctx, runtime, settings, true, &oc.NativeModel{ProviderID: "fixture", ID: "fixture-model", Variant: "off"}, "extend")
	check(err != nil, "live variant mutation admitted")
	must(runtime.Close())
	log, err := os.ReadFile(filepath.Join(root, "operations.log"))
	must(err)
	check(strings.Count(string(log), "process-start") == 3 && strings.Count(string(log), "process-exit") == 3, fmt.Sprintf("catalog launch sharing or cleanup failed: starts=%d exits=%d\n%s", strings.Count(string(log), "process-start"), strings.Count(string(log), "process-exit"), log))
	fmt.Println("PASS: native JSONC/YAML discovery/order/isolation, shared cancellation-safe catalog, credential-free projection, exact snapshot/create/update thinking, schema/provenance, live model admission, complete process cleanup")
}
