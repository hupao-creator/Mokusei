package codex

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

type PreparedLaunch struct {
	Environment     []string
	ConfigOverrides []string
	Dispose         func() error
	Home            string
}

// PrepareIsolatedLaunch preserves a thread's native rollout across acquisitions,
// but retires copied credentials and configuration on every Close. A one-shot
// prompt has no owner and its entire home is removed when the process closes.
func PrepareIsolatedLaunch(ctx context.Context, executable string, env []string, dataRoot, ownerThreadID, cwd string) (PreparedLaunch, error) {
	if err := ctx.Err(); err != nil {
		return PreparedLaunch{}, err
	}
	catalog, err := loadLaunchCatalog(ctx, executable, env, cwd)
	if err != nil {
		return PreparedLaunch{}, err
	}
	restrictLaunchCatalog(catalog)
	root := filepath.Join(dataRoot, "application-tools-only")
	if err = cpPrivateDirectory(root); err != nil {
		return PreparedLaunch{}, err
	}
	var directory string
	if ownerThreadID != "" {
		hash := sha256.Sum256([]byte(ownerThreadID))
		directory = filepath.Join(root, "thread-"+hex.EncodeToString(hash[:]))
	} else {
		directory, err = os.MkdirTemp(root, "session-")
		if err != nil {
			return PreparedLaunch{}, err
		}
	}
	dispose := func() error {
		if ownerThreadID == "" {
			return os.RemoveAll(directory)
		}
		var result error
		for _, name := range []string{"auth.json", "config.toml"} {
			if err := os.Remove(filepath.Join(directory, name)); err != nil && !os.IsNotExist(err) {
				result = err
			}
		}
		return result
	}
	complete := false
	defer func() {
		if !complete {
			_ = dispose()
		}
	}()
	if err = cpPrivateDirectory(directory); err != nil {
		return PreparedLaunch{}, err
	}
	catalogPath := filepath.Join(directory, "models.json")
	data, err := json.Marshal(catalog)
	if err != nil {
		return PreparedLaunch{}, err
	}
	if err = cpPrivateWrite(catalogPath, data); err != nil {
		return PreparedLaunch{}, err
	}
	if cwd != "" {
		source, e := StartAppServer(ctx, LaunchOptions{Executable: executable, Cwd: cwd, Environment: env})
		if e != nil {
			return PreparedLaunch{}, e
		}
		configuration, e := ReadThreadConfiguration(ctx, source, cwd)
		closeErr := source.Close()
		if e != nil {
			return PreparedLaunch{}, e
		}
		if closeErr != nil {
			return PreparedLaunch{}, closeErr
		}
		if len(configuration) > 0 {
			text, e := cpTOMLDocument(configuration)
			if e != nil {
				return PreparedLaunch{}, e
			}
			if e = cpPrivateWrite(filepath.Join(directory, "config.toml"), []byte(text)); e != nil {
				return PreparedLaunch{}, e
			}
		} else {
			if e = os.Remove(filepath.Join(directory, "config.toml")); e != nil && !os.IsNotExist(e) {
				return PreparedLaunch{}, e
			}
		}
	}
	auth, authErr := os.ReadFile(filepath.Join(ceCodexHome(ceEnvironment(env)), "auth.json"))
	if authErr != nil && !os.IsNotExist(authErr) {
		return PreparedLaunch{}, authErr
	}
	if authErr == nil {
		if err = cpPrivateWrite(filepath.Join(directory, "auth.json"), auth); err != nil {
			return PreparedLaunch{}, err
		}
	} else if err = os.Remove(filepath.Join(directory, "auth.json")); err != nil && !os.IsNotExist(err) {
		return PreparedLaunch{}, err
	}

	values := ceEnvironment(env)
	values["CODEX_HOME"] = directory
	values["CODEX_SQLITE_HOME"] = directory
	if err = ctx.Err(); err != nil {
		return PreparedLaunch{}, err
	}
	quoted, _ := json.Marshal(catalogPath)
	complete = true
	return PreparedLaunch{Environment: ceEnvironmentList(values), ConfigOverrides: []string{"model_catalog_json=" + string(quoted)}, Dispose: dispose, Home: directory}, nil
}

// ExclusiveToolsConfig closes native skill, MCP, plugin and built-in tool
// surfaces at the thread request boundary, including inherited workspace config.
func ExclusiveToolsConfig(ctx context.Context, transport CatalogTransport, cwd string) (Map, error) {
	response, err := transport.Call(ctx, "config/read", Map{"cwd": cwd, "includeLayers": false})
	if err != nil {
		return nil, err
	}
	skillsResponse, err := transport.Call(ctx, "skills/list", Map{"cwds": []string{cwd}, "forceReload": true})
	if err != nil {
		return nil, err
	}
	effective, _ := csRecord(response["config"])
	servers, _ := csRecord(effective["mcp_servers"])
	disabledServers := Map{}
	for name := range servers {
		disabledServers[name] = Map{"enabled": false}
	}
	plugins, _ := csRecord(effective["plugins"])
	disabledPlugins := Map{}
	for name, raw := range plugins {
		config, _ := csRecord(raw)
		servers, _ := csRecord(config["mcp_servers"])
		disabled := Map{}
		for server := range servers {
			disabled[server] = Map{"enabled": false}
		}
		if len(disabled) > 0 {
			disabledPlugins[name] = Map{"mcp_servers": disabled}
		}
	}
	skills := []Map{}
	for _, raw := range csArray(skillsResponse["data"]) {
		entry, _ := csRecord(raw)
		for _, rawSkill := range csArray(entry["skills"]) {
			skill, _ := csRecord(rawSkill)
			if path := csString(skill["path"]); path != "" {
				skills = append(skills, Map{"path": path, "enabled": false})
			}
		}
	}
	features := Map{}
	for _, name := range []string{"apps", "current_time_reminder", "sleep_tool", "send_message_to_user_async", "goals", "hooks", "image_generation", "memories", "multi_agent", "plugins", "remote_plugin", "shell_tool", "skill_mcp_dependency_install", "unified_exec", "view_image"} {
		features[name] = false
	}
	config := Map{"agents": Map{"enabled": false}, "apps": Map{"_default": Map{"enabled": false}}, "features": features, "mcp_servers": disabledServers, "memories": Map{"generate_memories": false, "use_memories": false}, "plugins": disabledPlugins, "skills": Map{"config": skills}, "tools": Map{"experimental_request_user_input": Map{"enabled": false}, "update_plan": Map{"enabled": false}, "image_generation": false, "view_image": false, "web_search": false}, "web_search": "disabled"}
	if workspace, ok := csRecord(effective["sandbox_workspace_write"]); ok && len(workspace) > 0 {
		config["sandbox_workspace_write"] = workspace
	}
	return config, nil
}
func cpPrivateDirectory(directory string) error {
	if err := os.MkdirAll(directory, 0700); err != nil {
		return err
	}
	info, err := os.Lstat(directory)
	if err != nil {
		return err
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("Codex private home is not a directory")
	}
	return os.Chmod(directory, 0700)
}
func cpPrivateWrite(path string, data []byte) error {
	temporary, err := os.CreateTemp(filepath.Dir(path), ".mokusei-private-")
	if err != nil {
		return err
	}
	name := temporary.Name()
	defer os.Remove(name)
	if err = temporary.Chmod(0600); err == nil {
		_, err = temporary.Write(data)
	}
	if closeErr := temporary.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return err
	}
	return os.Rename(name, path)
}
func cpTOMLDocument(config Map) (string, error) {
	keys := make([]string, 0, len(config))
	for key := range config {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	lines := []string{}
	for _, key := range keys {
		if config[key] == nil {
			continue
		}
		value, err := cpTOMLValue(config[key])
		if err != nil {
			return "", err
		}
		encoded, _ := json.Marshal(key)
		lines = append(lines, string(encoded)+" = "+value)
	}
	return strings.Join(lines, "\n") + "\n", nil
}
func cpTOMLValue(value any) (string, error) {
	switch value.(type) {
	case string, bool, float64, float32, int, int64, int32, uint, uint64, json.Number:
		encoded, err := json.Marshal(value)
		return string(encoded), err
	}
	if values, ok := csSlice(value); ok {
		parts := []string{}
		for _, child := range values {
			encoded, err := cpTOMLValue(child)
			if err != nil {
				return "", err
			}
			parts = append(parts, encoded)
		}
		return "[" + strings.Join(parts, ", ") + "]", nil
	}
	if record, ok := csRecord(value); ok {
		keys := []string{}
		for key := range record {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		parts := []string{}
		for _, key := range keys {
			if record[key] == nil {
				continue
			}
			encoded, err := cpTOMLValue(record[key])
			if err != nil {
				return "", err
			}
			name, _ := json.Marshal(key)
			parts = append(parts, string(name)+" = "+encoded)
		}
		return "{ " + strings.Join(parts, ", ") + " }", nil
	}
	return "", fmt.Errorf("Codex configuration value cannot be represented in TOML")
}
