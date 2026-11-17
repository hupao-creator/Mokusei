package system_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"pgregory.net/rapid"
)

// Unlike reducer-only properties, every generated case starts production
// composition, a real native CLI and HTTP model service, and runs all consumers.
// It is opt-in because the native CLI and macOS sandbox are external dependencies.
// PBT-SYSTEM-COMBINATION: internal/core/runtime/README.md
func TestSystemFaultCombinationProperties(t *testing.T) {
	native := os.Getenv("MOKUSEI_SYSTEM_CODEX")
	if native == "" {
		t.Fatal("set MOKUSEI_SYSTEM_CODEX to an absolute native Codex path; missing capability is not a pass")
	}
	rapid.Check(t, func(t *rapid.T) {
		scopes := rapid.IntRange(1, 3).Draw(t, "scopes")
		plan := []string{}
		for _, role := range []string{"moku", "child", "report", "tag", "read"} {
			mode := rapid.SampledFrom([]string{"", "429", "500", "truncate"}).Draw(t, role)
			if mode != "" {
				plan = append(plan, role+"="+mode)
			}
		}
		artifacts, err := os.MkdirTemp(os.Getenv("MOKUSEI_PBT_EVIDENCE"), "moku-system-property-")
		if err != nil {
			t.Fatal(err)
		}
		specification := strings.Join(plan, ",")
		actions := rapid.SliceOfN(rapid.SampledFrom([]string{"read", "archive", "unarchive", "settings", "followup", "fork", "interrupt"}), 0, 6).Draw(t, "actions")
		// Destructive operations end a generated trace so every earlier command
		// has a valid source even when Rapid shrinks scopes or action prefixes.
		if rapid.Bool().Draw(t, "deleteAtEnd") {
			actions = append(actions, "delete")
		}
		if rapid.Bool().Draw(t, "clearAtEnd") {
			actions = append(actions, "clear")
		}
		t.Logf("scopes=%d fault combination: %s actions=%v", scopes, specification, actions)
		if err := runScenarioActions(native, filepath.Join(artifacts, "evidence"), specification, scopes, actions); err != nil {
			t.Logf("faults=%s retained evidence %s: %v", specification, artifacts, err)
			t.Fatal("system scenario failed")
		}
		if err := os.RemoveAll(artifacts); err != nil {
			t.Fatal(err)
		}
	})
}
