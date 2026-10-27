package main

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/claude"
)

// Native model controls remain usable with CLI-owned external authentication.
// Account attribution must not turn declared controls into an unusable schema.
func verifyNativeCatalog(ctx context.Context, executable, cwd string) {
	newHarness := func(disabled bool) *claude.Harness {
		return claude.New(plugin.HostContext{
			ResolveExecutable: func(context.Context, string, string, string) (string, error) { return executable, nil },
			Environment: func(context.Context) (map[string]string, error) {
				env := map[string]string{"CLAUDE_FIXTURE": "1", "CLAUDE_CONFIG_DIR": cwd,
					"ANTHROPIC_BASE_URL": "https://native-fixture.invalid", "ANTHROPIC_API_KEY": "synthetic-native-key"}
				if disabled {
					env["CLAUDE_FIXTURE_EFFORT_DISABLED"] = "1"
				}
				return env, nil
			},
		})
	}
	h := newHarness(false)
	defaults, err := h.Settings().DefaultThread(h.DefaultSettings())
	must(err)
	requested := json.RawMessage(`{"model":"claude-fixture","thinking":{"mode":"effort","effort":"high"},"permissionMode":"auto"}`)
	resolved, err := h.Settings().ResolveThread(ctx, plugin.ResolveSettingsRequest{Merged: defaults, Requested: requested, Cwd: cwd})
	if err != nil {
		panic(fmt.Sprintf("native external account lost declared model controls: %v", err))
	}
	var selected struct{ Model, Effort string }
	must(json.Unmarshal(resolved, &selected))
	if selected.Model != "claude-fixture" || selected.Effort != "high" {
		panic("native external account changed the exact model or effort")
	}
	profile := json.RawMessage(`{"useDefaultThreadSettings":false,"threadSettings":{"model":"claude-fixture","effort":"high","permissionMode":"auto"}}`)
	_, err = h.Settings().SnapshotExecution(ctx, plugin.SettingsRequest{Settings: profile, Cwd: cwd}, false)
	must(err)
	_, err = h.Settings().ResolveThread(ctx, plugin.ResolveSettingsRequest{Merged: defaults, Requested: json.RawMessage(`{"model":"claude-fixture","thinking":{"mode":"effort","effort":"max"}}`), Cwd: cwd})
	if err == nil {
		panic("native external account accepted an unadvertised effort")
	}
	_, err = newHarness(true).Settings().ResolveThread(ctx, plugin.ResolveSettingsRequest{Merged: defaults, Requested: requested, Cwd: cwd})
	if err == nil {
		panic("native external account ignored explicit supportsEffort=false")
	}
	telemetry, err := h.MokuContext(ctx, "telemetry", plugin.SettingsRequest{Settings: profile, Cwd: cwd}, nil)
	must(err)
	var account map[string]any
	must(json.Unmarshal([]byte(telemetry), &account))
	if account["availability"] != "unknown" || account["namespace"] != "external-provider" {
		panic("external native configuration borrowed a Claude subscription quota")
	}
	fmt.Println("PASS Claude native external account: exact declared model/effort resolution and execution capture; unsupported controls rejected; subscription quota remains unknown")
}
