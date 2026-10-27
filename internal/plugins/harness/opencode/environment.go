package opencode

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/hupao-creator/Mokusei/internal/platform/sqlite"
)

func inheritedEnvironment(overlay map[string]string) map[string]string {
	result := make(map[string]string)
	if overlay != nil {
		for key, value := range overlay {
			result[key] = value
		}
		return result
	}
	for _, entry := range os.Environ() {
		if key, value, ok := strings.Cut(entry, "="); ok {
			result[key] = value
		}
	}
	return result
}

func environmentHome(environment map[string]string) (string, error) {
	if home := environment["HOME"]; home != "" {
		return home, nil
	}
	return os.UserHomeDir()
}

func nativeDataDirectory(environment map[string]string) string {
	home := environment["HOME"]
	if home == "" {
		home, _ = os.UserHomeDir()
	}
	data := environment["XDG_DATA_HOME"]
	if data == "" {
		data = filepath.Join(home, ".local", "share")
	}
	return filepath.Join(data, "opencode")
}

func nativeDatabasePath(environment map[string]string) string {
	path := environment["OPENCODE_DB"]
	if path == ":memory:" {
		return path
	}
	if path == "" {
		path = "opencode.db"
	}
	if !filepath.IsAbs(path) {
		path = filepath.Join(nativeDataDirectory(environment), path)
	}
	path, _ = filepath.Abs(path)
	return path
}

func privateDirectory(path string) error {
	if err := os.MkdirAll(path, 0700); err != nil {
		return err
	}
	return os.Chmod(path, 0700)
}

// PrepareEnvironment preserves native storage and authentication while isolating
// temporary files and, when requested, executable configuration.
func PrepareEnvironment(options Options, bridgeDirectory string) ([]string, func() error, error) {
	root, err := os.MkdirTemp("", "mokusei-opencode-")
	if err != nil {
		return nil, nil, err
	}
	dispose := func() error {
		return cleanupTemporaryEnvironment(func() error { return os.RemoveAll(root) })
	}
	success := false
	defer func() {
		if !success {
			_ = dispose()
		}
	}()
	if err = os.Chmod(root, 0700); err != nil {
		return nil, nil, err
	}
	inherited := inheritedEnvironment(options.Environment)
	if options.IsolateConfig {
		if err = assertNativeConfigIsolation(inherited); err != nil {
			return nil, nil, err
		}
	}
	for _, name := range []string{"cache", "state", "config", "home", "tmp"} {
		if err = privateDirectory(filepath.Join(root, name)); err != nil {
			return nil, nil, err
		}
	}
	configurationCWD := options.ConfigurationCWD
	if configurationCWD == "" {
		configurationCWD = options.CWD
	}
	config := map[string]any{}
	if options.IsolateConfig {
		config, err = readNativeDataConfig(inherited, configurationCWD)
		if err != nil {
			return nil, nil, err
		}
	}
	content := map[string]any{}
	if inherited["OPENCODE_CONFIG_CONTENT"] != "" {
		content, err = parseConfigObject(inherited["OPENCODE_CONFIG_CONTENT"], "OPENCODE_CONFIG_CONTENT")
		if err != nil {
			return nil, nil, err
		}
	}
	if options.IsolateConfig {
		var substituted any
		substituted, err = substituteConfig(safeNativeConfig(content), inherited, configurationCWD)
		if err != nil {
			return nil, nil, err
		}
		config = mergeNativeDataConfig(mergeNativeDataConfig(config, substituted.(map[string]any), inherited), options.Config, inherited)
	} else {
		config = mergeOpenCodeConfig(mergeOpenCodeConfig(config, content), options.Config)
	}
	plugins := []any{}
	if !options.IsolateConfig {
		if existing, ok := config["plugins"].([]any); ok {
			plugins = existing
		} else if existing, ok := config["plugin"].([]any); ok {
			plugins = existing
		}
	}
	filtered := make([]any, 0, len(plugins)+1)
	for _, plugin := range plugins {
		if path, ok := plugin.(string); !ok || path != bridgeDirectory {
			filtered = append(filtered, plugin)
		}
	}
	config["plugins"] = append(filtered, bridgeDirectory)
	config["update"], config["autoupdate"], config["warming"] = "disable", false, false
	delete(config, "plugin")
	encoded, err := json.Marshal(config)
	if err != nil {
		return nil, nil, errors.New("Cannot encode OpenCode configuration")
	}
	environment := inherited
	for _, name := range []string{"TMPDIR", "TMP", "TEMP"} {
		environment[name] = filepath.Join(root, "tmp")
	}
	environment["OPENCODE_CONFIG_CONTENT"] = string(encoded)
	environment["OPENCODE_DISABLE_AUTOUPDATE"], environment["OPENCODE_CLIENT"] = "1", "mokusei"
	for _, key := range []string{"OPENCODE_PASSWORD", "OPENCODE_SERVER_PASSWORD", "OPENCODE_PTY_HANDOFF"} {
		delete(environment, key)
	}
	if options.IsolateConfig {
		environment["XDG_CONFIG_HOME"] = filepath.Join(root, "config")
		environment["OPENCODE_CONFIG_DIR"] = filepath.Join(root, "config", "opencode")
		environment["OPENCODE_TEST_HOME"] = filepath.Join(root, "home")
		environment["OPENCODE_CONFIG_PROJECT_DISABLE"] = "1"
		delete(environment, "OPENCODE_CONFIG")
	}
	result := make([]string, 0, len(environment))
	for key, value := range environment {
		result = append(result, key+"="+value)
	}
	sort.Strings(result)
	success = true
	return result, dispose, nil
}

// File-based isolation cannot suppress remote configuration registered in the
// native DB. Refuse it for exclusive execution before OpenCode can load MCP or
// plugins from that source. Ordinary native execution keeps this configuration.
func assertNativeConfigIsolation(env map[string]string) error {
	path := nativeDatabasePath(env)
	if path == ":memory:" {
		return nil
	}
	if _, err := os.Stat(path); errors.Is(err, os.ErrNotExist) {
		return nil
	} else if err != nil {
		return err
	}
	db, err := sqlite.Open(path, true)
	if err != nil {
		return errors.New("Cannot inspect OpenCode native configuration isolation")
	}
	defer db.Close()
	tables, err := db.Query("SELECT name FROM sqlite_master WHERE type='table' AND name='kv'")
	if err != nil {
		return err
	}
	if len(tables) == 0 {
		return nil
	}
	rows, err := db.Query("SELECT value FROM kv WHERE key = ?", "wellknown:sources")
	if err != nil {
		return err
	}
	for _, row := range rows {
		var sources []string
		if err = json.Unmarshal([]byte(str(row["value"])), &sources); err != nil {
			return errors.New("Cannot inspect OpenCode remote configuration")
		}
		if len(sources) > 0 {
			return errors.New("OpenCode exclusive tools are unavailable while native remote configuration is enabled")
		}
	}
	return nil
}
