package opencode

import (
	"context"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/platform/sqlite"
)

func nativeDirectories(ctx context.Context, env map[string]string) ([]string, []string, error) {
	if err := ctx.Err(); err != nil {
		return nil, nil, err
	}
	database := nativeDatabasePath(env)
	if database == ":memory:" {
		return []string{}, []string{}, nil
	}
	db, err := sqlite.Open(database, true)
	if err != nil {
		return []string{}, []string{}, nil
	}
	defer db.Close()
	directories, managed := map[string]bool{}, map[string]bool{}
	for _, query := range []string{"SELECT DISTINCT directory FROM project_directory", "SELECT worktree AS directory FROM project"} {
		if err = ctx.Err(); err != nil {
			return nil, nil, err
		}
		rows, queryErr := db.Query(query)
		if queryErr != nil {
			continue
		}
		for _, row := range rows {
			if path := str(row["directory"]); filepath.IsAbs(path) {
				directories[path] = true
			}
		}
	}
	rows, _ := db.Query("SELECT DISTINCT directory FROM worktree WHERE strategy IS NOT NULL")
	for _, row := range rows {
		if path := str(row["directory"]); filepath.IsAbs(path) {
			managed[path] = true
		}
	}
	list := func(values map[string]bool) []string {
		out := []string{}
		for path := range values {
			out = append(out, path)
		}
		sort.Strings(out)
		return out
	}
	return list(directories), list(managed), ctx.Err()
}
func DiscoverWorkspaceDirectories(ctx context.Context, env map[string]string) ([]string, error) {
	directories, _, err := nativeDirectories(ctx, inheritedEnvironment(env))
	return directories, err
}
func WorkspaceDirectoryPolicy(ctx context.Context, env map[string]string) (plugin.DirectoryPolicy, error) {
	env = inheritedEnvironment(env)
	home := env["HOME"]
	if home == "" {
		home, _ = os.UserHomeDir()
	}
	data := env["XDG_DATA_HOME"]
	if data == "" {
		data = filepath.Join(home, ".local", "share")
	}
	root := filepath.Join(data, "opencode")
	roots := map[string]bool{filepath.Join(root, "worktree"): true, filepath.Join(root, "repos"): true}
	directories, managed, err := nativeDirectories(ctx, env)
	if err != nil {
		return plugin.DirectoryPolicy{}, err
	}
	for _, path := range managed {
		roots[path] = true
	}
	config := env["OPENCODE_CONFIG_DIR"]
	if config == "" {
		base := env["XDG_CONFIG_HOME"]
		if base == "" {
			base = filepath.Join(home, ".config")
		}
		config = filepath.Join(base, "opencode")
	}
	configured := directories
	if len(configured) == 0 {
		configured = []string{home}
	}
	files := map[string][]string{}
	for _, name := range []string{"opencode.json", "opencode.jsonc"} {
		files[filepath.Join(config, name)] = configured
	}
	if path := env["OPENCODE_CONFIG"]; path != "" {
		absolute, _ := filepath.Abs(path)
		files[absolute] = configured
	}
	for _, dir := range directories {
		for _, name := range []string{"opencode.json", "opencode.jsonc", ".opencode/opencode.json", ".opencode/opencode.jsonc"} {
			files[filepath.Join(dir, name)] = []string{dir}
		}
	}
	add := func(text, cwd string) {
		value, err := parseConfigObject(text, "workspace configuration")
		if err != nil {
			return
		}
		path := str(configRecord(value["worktree"])["directory"])
		if path == "" {
			return
		}
		if path == "~" {
			path = home
		} else if strings.HasPrefix(path, "~/") {
			path = filepath.Join(home, path[2:])
		}
		if !filepath.IsAbs(path) {
			path = filepath.Join(cwd, path)
		}
		roots[filepath.Clean(path)] = true
	}
	for path, targets := range files {
		if err = ctx.Err(); err != nil {
			return plugin.DirectoryPolicy{}, err
		}
		text, readErr := os.ReadFile(path)
		if readErr == nil {
			for _, dir := range targets {
				add(string(text), dir)
			}
		}
	}
	if content := env["OPENCODE_CONFIG_CONTENT"]; content != "" {
		for _, dir := range configured {
			add(content, dir)
		}
	}
	excluded := []string{}
	for path := range roots {
		excluded = append(excluded, path)
	}
	sort.Strings(excluded)
	return plugin.DirectoryPolicy{ExcludedRoots: excluded, Excludes: func(path string) bool {
		parts := strings.Split(filepath.Clean(path), string(filepath.Separator))
		for i := 0; i+3 < len(parts); i++ {
			if parts[i] == ".local" && parts[i+1] == "share" && parts[i+2] == "opencode" && (parts[i+3] == "worktree" || parts[i+3] == "repos") {
				return true
			}
		}
		return false
	}}, ctx.Err()
}
