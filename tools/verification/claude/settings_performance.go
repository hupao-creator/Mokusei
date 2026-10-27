package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/claude"
)

// This times the production adapter, including native pipes and process cleanup.
// The fixed initialize delay represents native I/O; it is not a CLI benchmark.
func verifySettingsPerformance() {
	root, err := os.MkdirTemp("", "claude-settings-performance-")
	must(err)
	defer os.RemoveAll(root)
	executable, err := os.Executable()
	must(err)
	h := claude.New(plugin.HostContext{
		Environment: func(context.Context) (map[string]string, error) {
			return map[string]string{"HOME": root, "CLAUDE_CONFIG_DIR": root, "CLAUDE_FIXTURE": "1", "CLAUDE_SETTINGS_PERFORMANCE": root}, nil
		},
		ResolveExecutable: func(context.Context, string, string, string) (string, error) { return executable, nil },
	})
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	for _, phase := range []string{"cold", "warm"} {
		started := time.Now()
		var workers sync.WaitGroup
		failures := make(chan error, 8)
		for range 8 {
			workers.Add(1)
			go func() {
				defer workers.Done()
				_, err := h.Settings().Presentation(ctx, plugin.SettingsPresentationRequest{Settings: h.DefaultSettings(), Cwd: root})
				failures <- err
			}()
		}
		workers.Wait()
		close(failures)
		for err := range failures {
			must(err)
		}
		files, err := filepath.Glob(filepath.Join(root, "start-*"))
		must(err)
		fmt.Printf("Claude settings %s: readers=8 nativeStartsTotal=%d elapsedMs=%.2f\n", phase, len(files), float64(time.Since(started))/float64(time.Millisecond))
	}
}

func verifySettingsIdentity(ctx context.Context, executable string) {
	root, err := os.MkdirTemp("", "claude-settings-identity-")
	must(err)
	defer os.RemoveAll(root)
	first, second := filepath.Join(root, "first"), filepath.Join(root, "second")
	for _, path := range []string{first, second} {
		must(os.MkdirAll(path, 0700))
	}
	must(os.WriteFile(filepath.Join(first, "settings.json"), []byte("profile-a"), 0600))
	must(os.WriteFile(filepath.Join(second, "settings.json"), []byte("profile-b"), 0600))
	selected := first
	h := claude.New(plugin.HostContext{
		Environment: func(context.Context) (map[string]string, error) {
			return map[string]string{"HOME": root, "CLAUDE_CONFIG_DIR": selected, "CLAUDE_FIXTURE": "1", "CLAUDE_SETTINGS_IDENTITY": "1"}, nil
		},
		ResolveExecutable: func(context.Context, string, string, string) (string, error) { return executable, nil },
	})
	if closer, ok := any(h).(interface{ Close() error }); ok {
		defer closer.Close()
	}
	read := func(want string) {
		raw, err := h.Settings().Presentation(ctx, plugin.SettingsPresentationRequest{Settings: h.DefaultSettings(), Cwd: root})
		must(err)
		var value struct{ Models []struct{ Value string } }
		must(json.Unmarshal(raw, &value))
		if len(value.Models) != 1 || value.Models[0].Value != want {
			panic("native catalog crossed profile/configuration generations")
		}
	}
	read("profile-a")
	selected = second
	read("profile-b")
	selected = first
	read("profile-a")
	must(os.WriteFile(filepath.Join(first, "settings.json"), []byte("profile-a-updated"), 0600))
	read("profile-a-updated")
	fmt.Println("PASS Claude settings catalog isolates native profile paths and invalidates changed native configuration")
}
