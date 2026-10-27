package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
)

func TestReadRequiresAssistantHistoryEvidence(t *testing.T) {
	for _, role := range []string{"user", "developer", "assistant"} {
		input := []any{object{"role": role, "content": []any{object{"type": "output_text", "text": "SYSTEM_CHILD_DONE"}}}}
		if got := hasCompletedChildEvidence(input); got != (role == "assistant") {
			t.Fatalf("evidence from %s accepted=%v", role, got)
		}
	}
	if hasCompletedChildEvidence([]any{object{"type": "function_call_output", "output": "SYSTEM_CHILD_DONE"}}) || hasCompletedChildEvidence(nil) {
		t.Fatal("missing assistant history accepted as evidence")
	}
}

func TestWaitStateDropsOmittedAgentRuns(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	polls := 0
	invoke := func(channel string, _ []any, target any) error {
		if channel != "state:load" {
			t.Fatalf("unexpected command %s", channel)
		}
		polls++
		wire := `{"agentRuns":[{}]}`
		if polls > 1 {
			wire = `{}` // AppState omits an empty agentRuns collection.
		}
		return json.Unmarshal([]byte(wire), target)
	}
	state, err := waitState(ctx, invoke, &provider{}, func(s model.AppState) bool { return len(s.AgentRuns) == 0 })
	if err != nil || polls != 2 || len(state.AgentRuns) != 0 {
		t.Fatalf("terminal snapshot retained stale runs: polls=%d runs=%d error=%v", polls, len(state.AgentRuns), err)
	}
}

func TestSystemLifecycleMatrix(t *testing.T) {
	native := os.Getenv("MOKUSEI_SYSTEM_CODEX")
	if native == "" {
		t.Skip("set MOKUSEI_SYSTEM_CODEX for native lifecycle matrix")
	}
	for scopes := 1; scopes <= 3; scopes++ {
		t.Run(fmt.Sprintf("scopes-%d", scopes), func(t *testing.T) {
			artifacts, err := os.MkdirTemp("", "moku-system-lifecycle-")
			if err != nil {
				t.Fatal(err)
			}
			actions := []string{"archive", "followup", "fork", "interrupt", "unarchive", "followup", "read", "fork", "interrupt", "followup", "delete", "settings", "clear"}
			faults := "moku=429,child=truncate,report=500,tag=429,read=truncate"
			if err = runScenarioActions(native, filepath.Join(artifacts, "evidence"), faults, scopes, actions); err != nil {
				t.Fatalf("retained %s: %v", artifacts, err)
			}
			if err = os.RemoveAll(artifacts); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestSystemActiveRemoval(t *testing.T) {
	native := os.Getenv("MOKUSEI_SYSTEM_CODEX")
	if native == "" {
		t.Skip("set MOKUSEI_SYSTEM_CODEX for native active removal")
	}
	for _, scopes := range []int{1, 3} {
		t.Run(fmt.Sprintf("scopes-%d", scopes), func(t *testing.T) {
			artifacts, err := os.MkdirTemp("", "moku-system-active-")
			if err != nil {
				t.Fatal(err)
			}
			if err = runScenarioActions(native, filepath.Join(artifacts, "evidence"), "", scopes, []string{"fork", "delete-active", "clear-active", "recreate", "followup"}); err != nil {
				t.Fatalf("retained %s: %v", artifacts, err)
			}
			if err = os.RemoveAll(artifacts); err != nil {
				t.Fatal(err)
			}
		})
	}
}
