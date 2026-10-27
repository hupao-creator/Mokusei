package opencode

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestReadVersionJoinsWrapperDescendants(t *testing.T) {
	for _, cancelled := range []bool{false, true} {
		name := "leader-exited"
		if cancelled {
			name = "cancelled"
		}
		t.Run(name, func(t *testing.T) {
			directory := t.TempDir()
			path := filepath.Join(directory, "opencode")
			script := `#!/bin/sh
if [ "$1" = child ]; then
  trap 'printf stopped > "$PROBE_ROOT/stopped"; exit 0' TERM
  printf ready > "$PROBE_ROOT/ready"
  while :; do /bin/sleep 0.02; done
fi
"$0" child &
while [ ! -f "$PROBE_ROOT/ready" ]; do /bin/sleep 0.01; done
if [ "$PROBE_CANCEL" = 1 ]; then
  wait
else
  printf '2.0.25\n'
fi
`
			if err := os.WriteFile(path, []byte(script), 0700); err != nil {
				t.Fatal(err)
			}
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			env := map[string]string{"PROBE_ROOT": directory}
			if cancelled {
				env["PROBE_CANCEL"] = "1"
			}
			type result struct {
				version string
				err     error
			}
			done := make(chan result, 1)
			go func() {
				version, err := ReadVersion(ctx, path, directory, env)
				done <- result{version, err}
			}()
			if cancelled {
				deadline := time.Now().Add(3 * time.Second)
				for {
					if _, err := os.Stat(filepath.Join(directory, "ready")); err == nil {
						break
					}
					if time.Now().After(deadline) {
						cancel()
						t.Fatal("version wrapper child did not start")
					}
					time.Sleep(10 * time.Millisecond)
				}
				cancel()
			}
			select {
			case got := <-done:
				if cancelled {
					if !errors.Is(got.err, context.Canceled) {
						t.Fatalf("cancelled probe = %q, %v", got.version, got.err)
					}
				} else if got.err != nil || got.version != "2.0.25" {
					t.Fatalf("version = %q, %v", got.version, got.err)
				}
			case <-time.After(8 * time.Second):
				t.Fatal("version probe did not drain its wrapper process group")
			}
			if contents, err := os.ReadFile(filepath.Join(directory, "stopped")); err != nil || string(contents) != "stopped" {
				t.Fatalf("probe returned before descendant cleanup: %q, %v", contents, err)
			}
		})
	}
}

func TestReadVersionRejectsFailedOrUnsupportedProbe(t *testing.T) {
	for _, scenario := range []struct {
		name, output, exit, want string
	}{
		{"exit", "2.0.25", "7", "exited with code 7"},
		{"old", "2.0.24", "0", "stable 2.x"},
		{"prerelease", "2.0.25-beta.1", "0", "stable 2.x"},
		{"major", "3.0.0", "0", "stable 2.x"},
	} {
		t.Run(scenario.name, func(t *testing.T) {
			directory := t.TempDir()
			path := filepath.Join(directory, "opencode")
			if err := os.WriteFile(path, []byte("#!/bin/sh\nprintf '%s\\n' '"+scenario.output+"'\nexit "+scenario.exit+"\n"), 0700); err != nil {
				t.Fatal(err)
			}
			if version, err := ReadVersion(context.Background(), path, directory, map[string]string{}); err == nil || !strings.Contains(err.Error(), scenario.want) {
				t.Fatalf("probe = %q, %v; want %q", version, err, scenario.want)
			}
		})
	}
}
