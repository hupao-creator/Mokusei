package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Fixed matrix guarantees all 15 role/fault pairs in addition to generated
// combinations. Each row runs the same complete task/read/Report/Tag/restart oracle.
func TestSystemFaultMatrix(t *testing.T) {
	native := os.Getenv("MOKUSEI_SYSTEM_CODEX")
	if native == "" {
		t.Skip("set MOKUSEI_SYSTEM_CODEX for native matrix")
	}
	for _, mode := range []string{"429", "500", "truncate"} {
		for scopes := 1; scopes <= 3; scopes++ {
			t.Run(fmt.Sprintf("%s/scopes-%d", mode, scopes), func(t *testing.T) {
				plan := []string{}
				for _, role := range []string{"moku", "child", "report", "tag", "read"} {
					plan = append(plan, role+"="+mode)
				}
				artifacts, err := os.MkdirTemp("", "moku-system-matrix-")
				if err != nil {
					t.Fatal(err)
				}
				if err = runScenario(native, filepath.Join(artifacts, "evidence"), strings.Join(plan, ","), scopes); err != nil {
					t.Fatalf("retained %s: %v", artifacts, err)
				}
				if err = os.RemoveAll(artifacts); err != nil {
					t.Fatal(err)
				}
			})
		}
	}

}
