package main

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/claude"
)

// verifyEffortSnapshot replays the explicit effort-only execution snapshot used
// by Moku. Claude's inherited CLAUDE_CODE_EFFORT_LEVEL must be masked for that
// session, otherwise a saved effort is silently replaced by the user's global
// setting and the applied-value check reports a mismatch.
func verifyEffortSnapshot(ctx context.Context, executable, cwd string) {
	newHarness := func(environment map[string]string) *claude.Harness {
		return claude.New(plugin.HostContext{ResolveExecutable: func(context.Context, string, string, string) (string, error) {
			return executable, nil
		}, Environment: func(context.Context) (map[string]string, error) {
			values := map[string]string{"CLAUDE_FIXTURE": "1", "CLAUDE_CONFIG_DIR": cwd}
			for key, value := range environment {
				values[key] = value
			}
			return values, nil
		}})
	}
	raw := json.RawMessage(`{"useDefaultThreadSettings":false,"threadSettings":{"model":"claude-fixture","effort":"high","permissionMode":"bypassPermissions"}}`)
	harness := newHarness(map[string]string{"CLAUDE_FIXTURE_INHERITED_EFFORT": "low"})
	snapshot, err := harness.Settings().SnapshotExecution(ctx, plugin.SettingsRequest{Settings: raw, Cwd: cwd}, false)
	if err != nil {
		panic(fmt.Sprintf("explicit effort-only snapshot did not mask inherited effort: %v", err))
	}
	var value struct {
		ThreadSettings struct{ Model, Effort string } `json:"threadSettings"`
	}
	must(json.Unmarshal(snapshot, &value))
	if value.ThreadSettings.Model != "claude-fixture" || value.ThreadSettings.Effort != "high" {
		panic("explicit effort-only snapshot did not capture high effort")
	}

	// A genuine mismatch must still surface, not be silently accepted.
	ignoring := newHarness(map[string]string{"CLAUDE_FIXTURE_INHERITED_EFFORT": "low", "CLAUDE_FIXTURE_IGNORE_MASK": "1"})
	_, err = ignoring.Settings().SnapshotExecution(ctx, plugin.SettingsRequest{Settings: raw, Cwd: cwd}, false)
	if err == nil || err.Error() != "Claude did not apply selected effort" {
		panic(fmt.Sprintf("masked-inherited effort mismatch did not surface accurately: %v", err))
	}
	fmt.Println("PASS Claude explicit effort-only execution snapshot masks inherited effort and still rejects a real mismatch; no model calls")
}
