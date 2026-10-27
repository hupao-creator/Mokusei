package codex

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"
)

// Cache only public model metadata, never copied auth or effective configuration.
// The short lifetime also bounds changes to the service-authored model catalog.
var launchCatalogs = struct {
	sync.Mutex
	entries map[[32]byte]launchCatalog
}{entries: make(map[[32]byte]launchCatalog)}

type launchCatalog struct {
	at   time.Time
	data []byte
}

func launchCatalogKey(executable string, env []string, cwd string) ([32]byte, error) {
	info, err := os.Stat(executable)
	if err != nil {
		return [32]byte{}, err
	}
	hash := sha256.New()
	environment := append([]string(nil), env...)
	sort.Strings(environment)
	identity, _ := json.Marshal([]any{executable, info.Size(), info.ModTime().UnixNano(), environment})
	hash.Write(identity)
	home := ceCodexHome(ceEnvironment(env))
	paths := []string{filepath.Join(home, "config.toml"), filepath.Join(home, "auth.json")}
	for path := cwd; path != ""; {
		paths = append(paths, filepath.Join(path, ".codex", "config.toml"))
		parent := filepath.Dir(path)
		if parent == path {
			break
		}
		path = parent
	}
	for _, path := range paths {
		data, err := os.ReadFile(path)
		if os.IsNotExist(err) {
			continue
		}
		if err != nil {
			return [32]byte{}, err
		}
		// Include the path only for present configuration. Disposable workspaces
		// with no local configuration may share the same native catalog.
		data, _ = json.Marshal([]any{path, data})
		hash.Write(data)
	}
	var key [32]byte
	copy(key[:], hash.Sum(nil))
	return key, nil
}

func loadLaunchCatalog(ctx context.Context, executable string, env []string, cwd string) (Map, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	key, err := launchCatalogKey(executable, env, cwd)
	if err != nil {
		return nil, err
	}
	launchCatalogs.Lock()
	cached, ok := launchCatalogs.entries[key]
	launchCatalogs.Unlock()
	var data []byte
	if ok && time.Since(cached.at) < 30*time.Second {
		data = cached.data
	} else {
		args := []string{"debug", "models"}
		output, err := ceProcessOutput(ctx, executable, args, env, cwd, 10*time.Second, 8*1024*1024)
		if err != nil {
			return nil, err
		}
		data = []byte(output)
	}
	catalog := Map{}
	if err := json.Unmarshal(data, &catalog); err != nil {
		return nil, fmt.Errorf("Invalid Codex model catalog: %w", err)
	}
	if len(csArray(catalog["models"])) == 0 {
		return nil, fmt.Errorf("Codex model catalog is empty")
	}
	for _, model := range csArray(catalog["models"]) {
		if _, valid := csRecord(model); !valid {
			return nil, fmt.Errorf("Invalid Codex model")
		}
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if !ok || time.Since(cached.at) >= 30*time.Second {
		launchCatalogs.Lock()
		if len(launchCatalogs.entries) >= 16 {
			for old := range launchCatalogs.entries {
				delete(launchCatalogs.entries, old)
				break
			}
		}
		launchCatalogs.entries[key] = launchCatalog{time.Now(), append([]byte(nil), data...)}
		launchCatalogs.Unlock()
	}
	return catalog, nil
}

// A discussion keeps the source history store and effective configuration. It
// needs only the restricted catalog, so do not launch a throwaway config reader
// or copy auth/config into an unused isolated home.
func prepareDiscussionCatalog(ctx context.Context, executable string, env []string, dataRoot, cwd string) (PreparedLaunch, error) {
	catalog, err := loadLaunchCatalog(ctx, executable, env, cwd)
	if err != nil {
		return PreparedLaunch{}, err
	}
	restrictLaunchCatalog(catalog)
	root := filepath.Join(dataRoot, "discussion-catalogs")
	if err = cpPrivateDirectory(root); err != nil {
		return PreparedLaunch{}, err
	}
	directory, err := os.MkdirTemp(root, "session-")
	if err != nil {
		return PreparedLaunch{}, err
	}
	dispose := func() error { return os.RemoveAll(directory) }
	path := filepath.Join(directory, "models.json")
	data, err := json.Marshal(catalog)
	if err == nil {
		err = cpPrivateWrite(path, data)
	}
	if err != nil {
		_ = dispose()
		return PreparedLaunch{}, err
	}
	quoted, _ := json.Marshal(path)
	return PreparedLaunch{Environment: env, ConfigOverrides: []string{"model_catalog_json=" + string(quoted)}, Dispose: dispose}, nil
}

func restrictLaunchCatalog(catalog Map) {
	for _, raw := range csArray(catalog["models"]) {
		model := obj(raw)
		model["tool_mode"] = "direct"
		model["experimental_supported_tools"] = []any{}
		model["shell_type"] = "disabled"
		model["apply_patch_tool_type"] = nil
		model["supports_search_tool"] = false
	}
}
