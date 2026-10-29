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
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/pi"
)

func verifySettingsSharing(ctx context.Context, assert bool) {
	options := fixtureOptions("settings-sharing")
	adapter := pi.New(plugin.HostContext{
		Environment:       func(context.Context) (map[string]string, error) { return options.Env, nil },
		ResolveExecutable: func(context.Context, string, string, string) (string, error) { return options.ExecutablePath, nil },
	})
	defer adapter.Close()
	for _, phase := range []string{"cold", "warm"} {
		started := time.Now()
		var workers sync.WaitGroup
		failures := make(chan error, 8)
		for i := range 8 {
			workers.Add(1)
			go func() {
				defer workers.Done()
				var err error
				if i%2 == 0 {
					var availability plugin.Availability
					availability, err = adapter.Probe(ctx, plugin.SettingsRequest{Settings: adapter.DefaultSettings(), Cwd: options.Cwd}, "settings")
					if err == nil && !availability.Available {
						err = fmt.Errorf("Pi unavailable: %s", availability.Reason)
					}
				} else {
					var raw json.RawMessage
					raw, err = adapter.Settings().Presentation(ctx, plugin.SettingsPresentationRequest{Settings: adapter.DefaultSettings(), Cwd: options.Cwd})
					if err == nil {
						var value struct {
							CLI struct{ Status string } `json:"cli"`
						}
						err = json.Unmarshal(raw, &value)
						if err == nil && value.CLI.Status != "ready" {
							err = fmt.Errorf("Pi catalog is not ready: %s", raw)
						}
					}
				}
				failures <- err
			}()
		}
		workers.Wait()
		close(failures)
		for err := range failures {
			check(err == nil, "settings sharing: "+fmt.Sprint(err))
		}
		files, err := filepath.Glob(filepath.Join(fixtureRoot, "settings-start-*"))
		check(err == nil, "count settings processes")
		fmt.Printf("Pi settings %s: readers=8 nativeStartsTotal=%d elapsedMs=%.2f\n", phase, len(files), float64(time.Since(started))/float64(time.Millisecond))
		if assert {
			check(len(files) == 1, "state/catalog readers did not share one native process")
		}
	}
}

func verifyNativeSettingsDiscovery(ctx context.Context, root, executable string, env map[string]string) error {
	adapter := pi.New(plugin.HostContext{
		Environment:       func(context.Context) (map[string]string, error) { return env, nil },
		ResolveExecutable: func(context.Context, string, string, string) (string, error) { return executable, nil },
	})
	defer adapter.Close()
	settings := json.RawMessage(`{"threadSettings":{"provider":"mock","model":"mock-model","thinkingLevel":"off"},"useDefaultThreadSettings":false}`)
	measurements := make([]int64, 0, 12)
	for attempt := 1; attempt <= 12; attempt++ {
		started := time.Now()
		raw, err := adapter.Settings().Presentation(ctx, plugin.SettingsPresentationRequest{
			Settings: settings, Cwd: filepath.Join(root, "work"), Refresh: true,
		})
		if err != nil {
			return fmt.Errorf("real Pi discovery attempt %d: %w", attempt, err)
		}
		var value struct {
			CLI    struct{ Status string } `json:"cli"`
			Models []struct {
				ID, Provider   string
				ThinkingLevels []string `json:"thinkingLevels"`
			} `json:"models"`
		}
		if err := json.Unmarshal(raw, &value); err != nil {
			return err
		}
		found := false
		for _, model := range value.Models {
			if model.ID == "mock-model" && model.Provider == "mock" && len(model.ThinkingLevels) > 0 {
				found = true
			}
		}
		if value.CLI.Status != "ready" || !found {
			return fmt.Errorf("real Pi discovery attempt %d did not expose the configured model/thinking choices: %s", attempt, raw)
		}
		// Presentation returns only after the observation process drains. A normal
		// child exit alone does not prove that its asynchronous auth lock was removed.
		if _, err := os.Stat(filepath.Join(env["PI_CODING_AGENT_DIR"], "auth.json.lock")); !os.IsNotExist(err) {
			return fmt.Errorf("real Pi discovery attempt %d left an auth lock (stat: %v)", attempt, err)
		}
		measurements = append(measurements, time.Since(started).Milliseconds())
	}
	data, err := json.Marshal(map[string]any{"attempts": len(measurements), "durationMs": measurements, "authLocksRemaining": 0})
	if err != nil {
		return err
	}
	if err := writeArtifact("native-settings-discovery.json", data); err != nil {
		return err
	}
	fmt.Printf("PASS real Pi repeated settings discovery: attempts=%d durationMs=%v no auth lock residue\n", len(measurements), measurements)
	return nil
}
