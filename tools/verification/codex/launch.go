package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"

	"github.com/hupao-creator/Mokusei/internal/plugins/harness/codex"
	"github.com/pelletier/go-toml/v2"
)

func launchCount(path, kind string) int {
	data, _ := os.ReadFile(path)
	count := 0
	for _, line := range strings.Split(string(data), "\n") {
		var row object
		if json.Unmarshal([]byte(line), &row) == nil && row["kind"] == kind {
			count++
		}
	}
	return count
}

func verifyLaunchCatalogCache(ctx context.Context, root, binary string, environment map[string]string) error {
	env := make(map[string]string)
	for key, value := range environment {
		env[key] = value
	}
	if err := verifyIsolatedProxyConfiguration(ctx, root, binary, env); err != nil {
		return err
	}
	capture := filepath.Join(root, "launch-cache.jsonl")
	env["MOKUSEI_CODEX_REPLAY_LAUNCH_CAPTURE"] = capture
	prepare := func(cwd string) error {
		launch, err := codex.PrepareIsolatedLaunch(ctx, binary, environmentList(env), filepath.Join(root, "cache-homes"), "", cwd)
		if err != nil {
			return err
		}
		return launch.Dispose()
	}
	for i := 0; i < 3; i++ {
		if err := prepare(filepath.Join(root, "work")); err != nil {
			return err
		}
	}
	if launchCount(capture, "catalog") != 1 {
		return fmt.Errorf("identical launch preparations repeated native catalog probing")
	}
	// Configuration and native auth changes invalidate within the cache lifetime.
	config := filepath.Join(root, "work", ".codex")
	if err := os.MkdirAll(config, 0700); err != nil {
		return err
	}
	configPath := filepath.Join(config, "config.toml")
	defer os.RemoveAll(config)
	if err := os.WriteFile(configPath, []byte("model = 'changed'\n"), 0600); err != nil {
		return err
	}
	if err := prepare(filepath.Join(root, "work")); err != nil {
		return err
	}
	if launchCount(capture, "catalog") != 2 {
		return fmt.Errorf("project configuration change reused stale catalog")
	}
	auth := filepath.Join(env["CODEX_HOME"], "auth.json")
	if err := os.WriteFile(auth, []byte(`{"OPENAI_API_KEY":"local-fixture-only"}`), 0600); err != nil {
		return err
	}
	defer os.Remove(auth)
	if err := prepare(filepath.Join(root, "work")); err != nil {
		return err
	}
	if launchCount(capture, "catalog") != 3 {
		return fmt.Errorf("native account change reused stale catalog")
	}
	cancelled, cancel := context.WithCancel(ctx)
	cancel()
	if _, err := codex.PrepareIsolatedLaunch(cancelled, binary, environmentList(env), root, "", filepath.Join(root, "work")); err == nil {
		return fmt.Errorf("cancelled cache hit admitted a launch")
	}
	fmt.Println("PASS launch catalog reuse / configuration and auth invalidation / cancelled cache hit")
	return nil
}

func verifyIsolatedProxyConfiguration(ctx context.Context, root, binary string, environment map[string]string) error {
	env := make(map[string]string)
	for key, value := range environment {
		env[key] = value
	}
	for _, scenario := range []struct {
		name     string
		features object
		want     object
	}{
		{"enabled", object{"respect_system_proxy": true, "system_proxy_fallback": false, "shell_tool": true}, object{"respect_system_proxy": true, "system_proxy_fallback": false}},
		{"disabled", object{"respect_system_proxy": false, "system_proxy_fallback": true, "plugins": true}, object{"respect_system_proxy": false, "system_proxy_fallback": true}},
		{"absent", object{"shell_tool": true}, nil},
		{"invalid", object{"respect_system_proxy": "true", "system_proxy_fallback": nil}, nil},
	} {
		env["MOKUSEI_CODEX_REPLAY_FEATURES"] = string(encoded(scenario.features))
		launch, err := codex.PrepareIsolatedLaunch(ctx, binary, environmentList(env), filepath.Join(root, "proxy-homes"), "proxy-owner", filepath.Join(root, "work"))
		if err != nil {
			return err
		}
		data, readErr := os.ReadFile(filepath.Join(launch.Home, "config.toml"))
		closeErr := launch.Dispose()
		if readErr != nil || closeErr != nil {
			return fmt.Errorf("proxy configuration %s read/cleanup: %v / %v", scenario.name, readErr, closeErr)
		}
		var configuration object
		if err := toml.Unmarshal(data, &configuration); err != nil {
			return err
		}
		got, _ := configuration["features"].(map[string]any)
		if !reflect.DeepEqual(got, scenario.want) {
			return fmt.Errorf("isolated proxy configuration %s: got %v, want %v", scenario.name, got, scenario.want)
		}
	}
	fmt.Println("PASS isolated native proxy features / explicit false / absent settings / unrelated feature exclusion")
	return nil
}
