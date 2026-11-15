package agentreading

import (
	"strings"
	"testing"
)

// TestAgentReadingWireBudget records the actual wire/state bytes and projection
// allocations. It also proves the hidden execution bodies do not reach the
// count-only contract; it does not claim a CPU or frame-rate result.
func TestAgentReadingWireBudget(t *testing.T) {
	for _, harness := range []string{"codex", "claude", "pi", "opencode"} {
		state, row, target, _ := completedFixture(harness)
		wire := project(harness, state, target)
		if len(wire) != len(row) {
			t.Fatalf("%s projection changed between calls", harness)
		}
		fixture := fixture(harness)
		for _, visible := range fixture.Visible {
			if !strings.Contains(string(wire), visible) {
				t.Fatalf("%s wire dropped visible marker %q", harness, visible)
			}
		}
		for _, hidden := range fixture.Hidden {
			if strings.Contains(string(wire), hidden) {
				t.Fatalf("%s wire retained hidden body %q", harness, hidden)
			}
		}
		allocs := testing.AllocsPerRun(10, func() {
			if projected := project(harness, state, target); len(projected) == 0 {
				t.Fatal("empty projection")
			}
		})
		t.Logf("%s utf8WireBytes=%d stateBytes=%d projectionAllocs=%.0f", harness, len(wire), len(state), allocs)
	}
}
