// Package architecture checks all source files, including Go files that are not
// reachable from a shipped binary and platform-specific build branches.
package architecture

import (
	"errors"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

const module = "github.com/hupao-creator/Mokusei/"

var allowed = map[string]string{
	"hosts/applicationhost": "core/model core/plugin core/store services/threadsearch", "platform/applicationprocess": "platform/environment core/model core/plugin platform/processgroup",
	"plugins/contexts/artificialanalysis": "core/plugin platform/profile", "hosts/contexthost": "core/plugin", "plugins/applications/background": "core/model core/plugin", "plugins/applications/report": "plugins/applications/background plugins/applications/value core/model core/plugin services/taglabel", "plugins/applications/tag": "plugins/applications/background plugins/applications/value core/model core/plugin", "plugins/applications/value": "core/model", "plugins/applications/git": "plugins/applications/value core/model core/plugin",
	"tooling/architecture": "", "services/attachments": "core/model", "services/moku": "services/directorytag core/model core/plugin platform/profile", "core/composition": "*", "platform/daemon": "core/model platform/profile platform/transport", "tooling/devtool": "platform/profile platform/processgroup", "services/directorytag": "services/workspaces", "platform/diagnostics": "core/plugin", "platform/environment": "core/model platform/processgroup", "platform/discovery": "", "plugins/harness/claude": "core/model core/plugin platform/discovery", "plugins/harness/codex": "core/model core/plugin platform/processgroup platform/sqlite platform/discovery", "plugins/harness/opencode": "plugins/harness/opencode/accounttelemetry core/model core/plugin platform/processgroup platform/sqlite platform/discovery", "plugins/harness/opencode/accounttelemetry": "", "plugins/harness/pi": "core/model core/plugin platform/discovery", "services/localembedding": "core/plugin platform/processgroup", "tooling/maintenance": "", "core/model": "", "core/plugin": "core/model", "platform/processgroup": "", "platform/profile": "core/model", "core/runtime": "services/attachments services/directorytag core/model core/plugin core/store services/taglabel services/threadsearch services/threadvoice platform/transport services/workspaces platform/workpool", "services/taglabel": "", "services/threadsearch": "core/model core/plugin core/store", "platform/sqlite": "", "core/store": "platform/sqlite", "services/threadvoice": "core/model core/plugin", "platform/transport": "core/model platform/profile", "services/workspaces": "core/model core/plugin", "platform/workpool": "",
}
var shims = map[string]bool{
	"internal/plugins/harness/pi/resources/host-extension.mjs": true,
	"internal/plugins/harness/pi/resources/read-guard.mjs":     true,
	"internal/plugins/harness/opencode/assets/index.mjs":       true,
	"internal/plugins/harness/opencode/assets/credentials.mjs": true,
}

var commandDependencies = map[string]string{
	"cmd/mokusei-runtime": "core/composition platform/daemon platform/diagnostics platform/environment plugins/harness/claude core/model core/plugin platform/profile platform/transport",
	"cmd/mokusei-dev":     "tooling/devtool", "cmd/mokusei-maintain": "tooling/maintenance",
	"cmd/mokusei-check": "tooling/architecture",
}

func Check(root string) error {
	var failures []error
	edges := map[string]map[string]bool{}
	foundShim := map[string]bool{}
	err := filepath.WalkDir(root, func(path string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		relative, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		relative = filepath.ToSlash(relative)
		if entry.IsDir() {
			// These gitignored directories hold local runtime data and separate
			// worktrees, not this checkout's source. Keep .claude/skills in scope.
			switch relative {
			case ".claude/dev-main", ".claude/worktrees":
				return filepath.SkipDir
			}
			switch entry.Name() {
			case ".git", ".build", ".swiftpm", "node_modules", "dist", "out", "output", ".scratch", ".turbo":
				return filepath.SkipDir
			}
			return nil
		}
		if relative == "package.json" || relative == "pnpm-lock.yaml" || relative == "pnpm-workspace.yaml" || entry.Name() == "package.json" || entry.Name() == "tsconfig.json" {
			failures = append(failures, fmt.Errorf("Node build manifest remains: %s", relative))
		}
		ext := filepath.Ext(relative)
		if ext == ".js" || ext == ".mjs" || ext == ".cjs" || ext == ".ts" || ext == ".tsx" {
			if shims[relative] {
				foundShim[relative] = true
			} else {
				failures = append(failures, fmt.Errorf("unapproved active JS/TS source: %s", relative))
			}
		}
		if ext != ".go" {
			return nil
		}
		file, err := parser.ParseFile(token.NewFileSet(), path, nil, parser.ImportsOnly|parser.ParseComments)
		if err != nil {
			return err
		}
		from := filepath.ToSlash(filepath.Dir(relative))
		if edges[from] == nil {
			edges[from] = map[string]bool{}
		}
		for _, item := range file.Imports {
			target, err := strconv.Unquote(item.Path.Value)
			if err != nil {
				return err
			}
			if !strings.HasPrefix(target, module) {
				continue
			}
			target = strings.TrimPrefix(target, module)
			edges[from][target] = true
			if strings.HasPrefix(from, "internal/") {
				source := strings.TrimPrefix(from, "internal/")
				dest := strings.TrimPrefix(target, "internal/")
				rule, exists := allowed[source]
				if !exists {
					failures = append(failures, fmt.Errorf("undeclared architecture package: %s", source))
					continue
				}
				if source != dest && rule != "*" && !contains(strings.Fields(rule), dest) {
					failures = append(failures, fmt.Errorf("forbidden package dependency: %s -> %s", from, target))
				}
			} else if strings.HasPrefix(from, "cmd/") {
				if !contains(strings.Fields(commandDependencies[from]), strings.TrimPrefix(target, "internal/")) {
					failures = append(failures, fmt.Errorf("forbidden command composition dependency: %s -> %s", from, target))
				}
			}
		}
		return nil
	})
	if err != nil {
		return err
	}
	for shim := range shims {
		if !foundShim[shim] {
			failures = append(failures, fmt.Errorf("required external Harness shim missing: %s", shim))
		}
	}
	visiting, visited := map[string]bool{}, map[string]bool{}
	var visit func(string) error
	visit = func(node string) error {
		if visiting[node] {
			return fmt.Errorf("import cycle across all build branches: %s", node)
		}
		if visited[node] {
			return nil
		}
		visiting[node] = true
		for next := range edges[node] {
			if err := visit(next); err != nil {
				return err
			}
		}
		delete(visiting, node)
		visited[node] = true
		return nil
	}
	for node := range edges {
		if err := visit(node); err != nil {
			failures = append(failures, err)
			break
		}
	}
	// Inspect actual constructor calls, not names in comments or string literals.
	file, err := parser.ParseFile(token.NewFileSet(), filepath.Join(root, "internal/core/composition/bootstrap.go"), nil, 0)
	if err != nil {
		return err
	}
	constructors := map[string]bool{}
	ast.Inspect(file, func(node ast.Node) bool {
		call, ok := node.(*ast.CallExpr)
		if !ok {
			return true
		}
		selector, ok := call.Fun.(*ast.SelectorExpr)
		if !ok {
			return true
		}
		owner, ok := selector.X.(*ast.Ident)
		if ok && (selector.Sel.Name == "New" || selector.Sel.Name == "NewWithOptions") {
			constructors[owner.Name] = true
		}
		return true
	})
	for _, id := range []string{"report", "tag", "artificialanalysis", "git", "codex", "claude", "pi", "opencode"} {
		if !constructors[id] {
			failures = append(failures, fmt.Errorf("static module missing from composition: %s", id))
		}
	}
	native, err := os.ReadFile(filepath.Join(root, "app/macos/Sources/Plugins/Applications/NativeApplicationModules.swift"))
	if err != nil {
		return err
	}
	for _, id := range []string{"Report", "Tag"} {
		if !strings.Contains(string(native), "Native"+id+"Application.make()") {
			failures = append(failures, fmt.Errorf("native application registration missing: %s", id))
		}
	}
	sort.Slice(failures, func(i, j int) bool { return failures[i].Error() < failures[j].Error() })
	return errors.Join(failures...)
}
func contains(values []string, value string) bool {
	for _, candidate := range values {
		if value == candidate {
			return true
		}
	}
	return false
}
