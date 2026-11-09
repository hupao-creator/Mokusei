package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
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
	if assert {
		verifySettingsSourceChanges(ctx)
	}
}

func verifySettingsSourceChanges(ctx context.Context) {
	reports := []map[string]any{}
	for _, routing := range []bool{false, true} {
		for _, scenario := range []string{"cold", "model", "dependency", "dependency-cached", "churn", "error", "cancel", "close"} {
			dependency := strings.HasPrefix(scenario, "dependency")
			if dependency && !routing {
				continue
			}
			func() {
				root, err := os.MkdirTemp(fixtureRoot, "source-"+scenario+"-")
				check(err == nil, "create source discovery fixture")
				defer os.RemoveAll(root)
				mode := scenario
				if mode == "cancel" || mode == "close" {
					mode = "blocked"
				}
				options := fixtureOptions("settings-source-" + mode)
				options.Cwd = filepath.Join(root, "work")
				options.Env["HOME"] = filepath.Join(root, "home")
				options.Env["PI_CODING_AGENT_DIR"] = filepath.Join(root, "agent")
				options.Env["MOKUSEI_PI_VERIFICATION_SOURCE"] = root
				for _, directory := range []string{options.Cwd, options.Env["HOME"], options.Env["PI_CODING_AGENT_DIR"]} {
					check(os.MkdirAll(directory, 0700) == nil, "create isolated discovery inputs")
				}
				check(os.WriteFile(filepath.Join(options.Env["PI_CODING_AGENT_DIR"], "models.json"), []byte(`{"id":"original-model"}`), 0600) == nil, "write initial native model input")
				if dependency {
					check(os.WriteFile(filepath.Join(options.Env["PI_CODING_AGENT_DIR"], "models.json"), []byte(`{"include":"catalog.json"}`), 0600) == nil, "point root config at a native dependency")
					check(os.WriteFile(filepath.Join(options.Env["PI_CODING_AGENT_DIR"], "catalog.json"), []byte(`{"id":"original-model"}`), 0600) == nil, "write included native model input")
				}
				adapter := pi.New(plugin.HostContext{
					Environment:       func(context.Context) (map[string]string, error) { return options.Env, nil },
					ResolveExecutable: func(context.Context, string, string, string) (string, error) { return options.ExecutablePath, nil },
				})
				defer adapter.Close()
				describe := func(callCtx context.Context) (json.RawMessage, error) {
					return adapter.Settings().Describe(callCtx, plugin.SettingsRequest{Settings: adapter.DefaultSettings(), Cwd: options.Cwd, RoutingCatalog: routing})
				}
				starts := func() int {
					files, err := filepath.Glob(filepath.Join(root, "start-*.json"))
					check(err == nil, "count bounded discovery attempts")
					return len(files)
				}
				if scenario == "cancel" || scenario == "close" {
					callCtx, cancel := context.WithCancel(ctx)
					defer cancel()
					done := make(chan error, 1)
					go func() { _, err := describe(callCtx); done <- err }()
					until := time.Now().Add(5 * time.Second)
					for {
						if _, err := os.Stat(filepath.Join(root, "draining")); err == nil {
							break
						}
						select {
						case err := <-done:
							panic(fmt.Sprintf("source discovery ended before disposal barrier: %v", err))
						case <-ctx.Done():
							panic(ctx.Err())
						case <-time.After(time.Millisecond):
							check(time.Now().Before(until), "source discovery reached disposal barrier")
						}
					}
					if scenario == "cancel" {
						cancel()
					}
					check(adapter.Close() == nil, "dispose cancelled discovery owner")
					err := <-done
					check(err != nil && (scenario != "cancel" || errors.Is(err, context.Canceled)), "cancelled discovery must remain failed")
					check(starts() == 1, "cancel/Close started a replacement discovery")
				} else {
					if scenario == "dependency-cached" {
						initial, err := adapter.Settings().Describe(ctx, plugin.SettingsRequest{Settings: adapter.DefaultSettings(), Cwd: options.Cwd})
						check(err == nil && bytes.Contains(initial, []byte(`"original-model"`)) && starts() == 1, "prime the ordinary root-metadata observation")
						check(os.WriteFile(filepath.Join(options.Env["PI_CODING_AGENT_DIR"], "catalog.json"), []byte(`{"id":"fresh-model-1"}`), 0600) == nil, "change only the transitive native model source")
					}
					raw, err := describe(ctx)
					switch scenario {
					case "error":
						check(err != nil && starts() == 1, "ordinary RPC failure was retried after native auth initialization")
					case "churn":
						check(err != nil && strings.Contains(err.Error(), "configuration changed") && starts() == 2, "changing sources must fail after exactly one retry")
						check(os.WriteFile(filepath.Join(root, "stable"), nil, 0600) == nil, "stop source mutations")
						raw, err = describe(ctx)
						check(err == nil && bytes.Contains(raw, []byte(`"fresh-model-2"`)) && !bytes.Contains(raw, []byte(`"fresh-model-1"`)) && starts() == 3, "failed old catalog escaped its source identity")
					default:
						check(err == nil && starts() == 2, "cold discovery did not recover with one fresh attempt: "+fmt.Sprint(err))
						want := "original-model"
						if scenario == "model" || dependency {
							want = "fresh-model-1"
							check(!bytes.Contains(raw, []byte(`"original-model"`)), "superseded native model was published")
						}
						check(bytes.Contains(raw, []byte(`"`+want+`"`)), "fresh source model is missing")
						for index, existed := range []bool{false, true} {
							data, err := os.ReadFile(filepath.Join(root, fmt.Sprintf("start-%d.json", index+1)))
							var start struct{ AuthExisted bool }
							check(err == nil && json.Unmarshal(data, &start) == nil && (dependency || start.AuthExisted == existed), "retry did not acquire the initialized native source")
						}
					}
					if scenario != "error" {
						before := starts()
						warm, err := describe(ctx)
						check(err == nil && bytes.Equal(raw, warm) && starts() == before, "fresh catalog did not remain cached under its stable identity")
					}
				}
				reports = append(reports, map[string]any{"scenario": scenario, "routing": routing, "nativeStarts": starts()})
			}()
		}
	}
	raw, _ := json.Marshal(reports)
	check(writeArtifact("settings-source-retry.json", raw) == nil, "retain source recovery evidence")
	fmt.Println("PASS Pi cold auth initialization and model-source changes: one fresh observation after disposal, stable-only cache, two-attempt bound, RPC/cancellation/Close exclusions, ordinary and routing catalogs")
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
