package discovery

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

var sourceEnvironment = regexp.MustCompile(`\{env:([^}]+)\}`)

var sourceReference = regexp.MustCompile(`\{file:([^}]+)\}|["']([^"'\r\n]+\.(?:jsonc?|toml|ya?ml|md|m?js|ts))["']`)

// SourceIdentity fingerprints the resolved launch and native configuration tree,
// including ancestor namespaces, symlinks and literal referenced files. Reading
// is bounded and errors fail closed; no configuration contents leave this hash.
// This is dependency identity, not proof that a provider finished discovery.
func SourceIdentity(ctx context.Context, env map[string]string, executable, cwd, namespace string, roots ...string) (string, error) {
	base, err := filepath.Abs(cwd)
	if err != nil {
		return "", err
	}
	canonical, err := filepath.EvalSymlinks(base)
	if err != nil {
		return "", err
	}
	queue := append([]string{}, roots...)
	for _, start := range []string{base, canonical} {
		for directory := start; ; directory = filepath.Dir(directory) {
			queue = append(queue, filepath.Join(directory, namespace))
			if namespace == ".opencode" {
				queue = append(queue, filepath.Join(directory, "opencode.json"), filepath.Join(directory, "opencode.jsonc"))
			}
			if filepath.Dir(directory) == directory {
				break
			}
		}
	}
	executablePaths := map[string]bool{filepath.Clean(executable): true}
	if resolved, err := filepath.EvalSymlinks(executable); err == nil {
		executablePaths[resolved] = true
	}
	facts := map[string]any{}
	seen := map[string]bool{}
	bytesRead := int64(0)
	for len(queue) > 0 {
		if err := ctx.Err(); err != nil {
			return "", err
		}
		path := filepath.Clean(queue[0])
		queue = queue[1:]
		if path == "." || seen[path] {
			continue
		}
		seen[path] = true
		if len(seen) > 4096 {
			return "", fmt.Errorf("native configuration dependency limit exceeded")
		}
		info, err := os.Lstat(path)
		if os.IsNotExist(err) {
			facts[path] = "absent"
			continue
		}
		if err != nil {
			return "", fmt.Errorf("cannot inspect native configuration dependency %s: %w", path, err)
		}
		if info.Mode()&os.ModeSymlink != 0 {
			target, err := filepath.EvalSymlinks(path)
			if err != nil {
				return "", fmt.Errorf("cannot resolve native configuration link %s: %w", path, err)
			}
			facts[path] = target
			queue = append(queue, target)
			continue
		}
		if info.IsDir() {
			directory, err := os.Open(path)
			if err != nil {
				return "", err
			}
			entries, readErr := directory.ReadDir(4097)
			closeErr := directory.Close()
			if readErr != nil && readErr != io.EOF {
				return "", readErr
			}
			if closeErr != nil {
				return "", closeErr
			}
			if len(entries) > 4096 {
				return "", fmt.Errorf("native configuration directory entry limit exceeded")
			}
			children := []string{}
			for _, entry := range entries {
				// Runtime-owned history/caches are not configuration inputs.
				if entry.IsDir() {
					switch entry.Name() {
					case ".git", "node_modules", "sessions", "archived_sessions", "logs", "cache", "tmp":
						continue
					}
				}
				if !entry.IsDir() && !sourceTextFile(entry.Name()) {
					continue
				}
				if strings.HasPrefix(entry.Name(), "models_cache") || entry.Name() == "history.jsonl" {
					continue
				}
				children = append(children, entry.Name())
				queue = append(queue, filepath.Join(path, entry.Name()))
			}
			sort.Strings(children)
			facts[path] = children
			continue
		}
		if !info.Mode().IsRegular() {
			return "", fmt.Errorf("native configuration dependency is not a regular file: %s", path)
		}
		if executablePaths[path] || !sourceTextFile(path) {
			facts[path] = fileGeneration(info)
			continue
		}
		if info.Size() > 4*1024*1024 || bytesRead+info.Size() > 16*1024*1024 {
			return "", fmt.Errorf("native configuration dependency byte limit exceeded")
		}
		file, err := os.Open(path)
		if err != nil {
			return "", err
		}
		content, readErr := io.ReadAll(io.LimitReader(file, 4*1024*1024+1))
		closeErr := file.Close()
		if readErr != nil {
			return "", readErr
		}
		if closeErr != nil {
			return "", closeErr
		}
		bytesRead += int64(len(content))
		if len(content) > 4*1024*1024 || bytesRead > 16*1024*1024 {
			return "", fmt.Errorf("native configuration dependency byte limit exceeded")
		}
		facts[path] = fmt.Sprintf("%x", sha256.Sum256(content))
		text := sourceEnvironment.ReplaceAllStringFunc(string(content), func(value string) string {
			return env[value[len("{env:"):len(value)-1]]
		})
		references := sourceReference.FindAllStringSubmatch(text, 4097)
		if len(references) > 4096 {
			return "", fmt.Errorf("native configuration reference limit exceeded")
		}
		for _, match := range references {
			reference := match[1]
			if reference == "" {
				reference = match[2]
			}
			if strings.Contains(reference, "://") {
				continue
			}
			reference = os.Expand(reference, func(key string) string { return env[key] })
			if strings.HasPrefix(reference, "~/") {
				reference = filepath.Join(env["HOME"], reference[2:])
			}
			candidates := []string{reference}
			if !filepath.IsAbs(reference) {
				// Native relative-reference rules vary; observe both source-file
				// and workspace resolution rather than silently missing either.
				candidates = []string{filepath.Join(filepath.Dir(path), reference), filepath.Join(base, reference)}
			}
			for _, candidate := range candidates {
				queue = append(queue, candidate)
				matches, err := filepath.Glob(candidate)
				if err != nil {
					return "", err
				}
				if len(matches) > 4096 {
					return "", fmt.Errorf("native configuration glob limit exceeded")
				}
				queue = append(queue, matches...)
			}
		}
	}
	hash := sha256.New()
	encoder := json.NewEncoder(hash)
	_ = encoder.Encode([]any{base, canonical, Identity(env, executable), facts})
	return hex.EncodeToString(hash.Sum(nil)), ctx.Err()
}

func sourceTextFile(path string) bool {
	switch strings.ToLower(filepath.Ext(path)) {
	case ".json", ".jsonc", ".toml", ".yaml", ".yml", ".md", ".js", ".mjs", ".ts":
		return true
	}
	return false
}
