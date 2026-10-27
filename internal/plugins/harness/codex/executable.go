package codex

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/hupao-creator/Mokusei/internal/platform/discovery"
	"github.com/hupao-creator/Mokusei/internal/platform/sqlite"
	"github.com/pelletier/go-toml/v2"
)

type ExecutableTarget struct {
	Executable string
	Version    string
	Identity   string
}
type codexVersion struct {
	numbers [3]string
	pre     []string
}

func ResolveExecutable(ctx context.Context, cwd, configured string, env []string) (string, error) {
	target, err := ResolveExecutableTarget(ctx, cwd, configured, env)
	return target.Executable, err
}
func ResolveExecutableTarget(ctx context.Context, cwd, configured string, env []string) (ExecutableTarget, error) {
	if err := ctx.Err(); err != nil {
		return ExecutableTarget{}, err
	}
	requested := []string{"codex"}
	if strings.TrimSpace(configured) != "" && strings.TrimSpace(configured) != "codex" {
		requested = append(requested, strings.TrimSpace(configured))
	}
	discovered, err := DiscoverExecutables(ctx, env)
	if err != nil {
		return ExecutableTarget{}, err
	}
	requested = append(requested, discovered...)
	candidates := []ExecutableTarget{}
	seen := map[string]bool{}
	for _, candidate := range requested {
		path, err := ceResolvePath(candidate, cwd, env)
		if err != nil {
			continue
		}
		canonical, err := filepath.EvalSymlinks(path)
		if err != nil {
			canonical = path
		}
		if seen[canonical] {
			continue
		}
		seen[canonical] = true
		candidates = append(candidates, ExecutableTarget{Executable: path, Identity: canonical})
	}
	if len(candidates) == 0 {
		return ExecutableTarget{}, fmt.Errorf("Codex executable not found")
	}
	type probe struct {
		target  ExecutableTarget
		version *codexVersion
		err     error
	}
	probes := make([]probe, len(candidates))
	var wg sync.WaitGroup
	for index, candidate := range candidates {
		wg.Add(1)
		go func(index int, candidate ExecutableTarget) {
			defer wg.Done()
			version, err := ReadCodexVersion(ctx, candidate.Executable, env)
			candidate.Version = version
			candidate.Identity += "\x00" + version
			probes[index] = probe{candidate, ceParseVersion(version), err}
		}(index, candidate)
	}
	wg.Wait()
	if err := ctx.Err(); err != nil {
		return ExecutableTarget{}, err
	}
	var selected *probe
	failures := []string{}
	for index := range probes {
		probe := &probes[index]
		if probe.err != nil {
			failures = append(failures, probe.target.Executable+": "+probe.err.Error())
			continue
		}
		if selected == nil || (probe.version != nil && (selected.version == nil || ceCompareVersion(probe.version, selected.version) > 0)) {
			selected = probe
		}
	}
	if selected == nil {
		return ExecutableTarget{}, fmt.Errorf("No usable Codex installation: %s", strings.Join(failures, "; "))
	}
	return selected.target, nil
}

// Version facts are immutable for a binary generation. The process itself
// remains owned by the requesting context and is drained before this returns.
var codexVersions = struct {
	sync.Mutex
	entries map[string]struct {
		value string
		at    time.Time
	}
}{entries: map[string]struct {
	value string
	at    time.Time
}{}}

func ReadCodexVersion(ctx context.Context, executable string, env []string) (string, error) {
	if err := ctx.Err(); err != nil {
		return "", err
	}
	key := discovery.Identity(ceEnvironment(env), executable)
	codexVersions.Lock()
	cached, exists := codexVersions.entries[key]
	codexVersions.Unlock()
	if exists && time.Since(cached.at) < 5*time.Minute {
		return cached.value, nil
	}
	output, err := ceProcessOutput(ctx, executable, []string{"--version"}, env, "", 5*time.Second, 64*1024)
	if err != nil {
		return "", err
	}
	if output == "" {
		return "", fmt.Errorf("Codex version probe returned no version")
	}
	if key == discovery.Identity(ceEnvironment(env), executable) {
		codexVersions.Lock()
		if len(codexVersions.entries) >= 64 {
			clear(codexVersions.entries)
		}
		codexVersions.entries[key] = struct {
			value string
			at    time.Time
		}{output, time.Now()}
		codexVersions.Unlock()
	}
	return output, nil
}

func DiscoverExecutables(ctx context.Context, env []string) ([]string, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	values := ceEnvironment(env)
	home := values["HOME"]
	if home == "" {
		home, _ = os.UserHomeDir()
	}
	paths := []string{}
	if path := values["CODEX_CLI_PATH"]; path != "" {
		paths = append(paths, path)
	}
	switch runtime.GOOS {
	case "windows":
		local := values["LOCALAPPDATA"]
		if local == "" {
			local = filepath.Join(home, "AppData", "Local")
		}
		install := values["CODEX_INSTALL_DIR"]
		if install == "" {
			install = filepath.Join(local, "Programs", "OpenAI", "Codex", "bin")
		}
		paths = append(paths, filepath.Join(install, "codex.exe"), filepath.Join(local, "OpenAI", "Codex", "bin", "codex.exe"))
		system := values["SystemRoot"]
		if system == "" {
			system = values["SYSTEMROOT"]
		}
		powershell := "powershell.exe"
		if system != "" {
			powershell = filepath.Join(system, "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
		}
		locations := ceOptionalDiscovery(ctx, powershell, []string{"-NoLogo", "-NoProfile", "-NonInteractive", "-Command", "[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new(); Get-AppxPackage -Name OpenAI.Codex -ErrorAction SilentlyContinue | ForEach-Object { $_.InstallLocation }"}, env)
		for _, root := range locations {
			paths = append(paths, filepath.Join(root, "app", "resources", "codex.exe"), filepath.Join(root, "app", "resources", "codex-cli", "bin", "codex.exe"))
		}
	default:
		install := values["CODEX_INSTALL_DIR"]
		if install == "" {
			install = filepath.Join(home, ".local", "bin")
		}
		paths = append(paths, filepath.Join(install, "codex"))
		if runtime.GOOS == "darwin" {
			applications := []string{}
			for _, root := range []string{"/Applications", filepath.Join(home, "Applications")} {
				for _, name := range []string{"Codex.app", "ChatGPT.app"} {
					applications = append(applications, filepath.Join(root, name))
				}
			}
			applications = append(applications, ceOptionalDiscovery(ctx, "/usr/bin/mdfind", []string{"kMDItemCFBundleIdentifier == 'com.openai.codex' || kMDItemCFBundleIdentifier == 'com.openai.chat'"}, env)...)
			for _, application := range applications {
				resources := filepath.Join(application, "Contents", "Resources")
				paths = append(paths, filepath.Join(resources, "codex-cli", "CodexCLI.app", "Contents", "MacOS", "codex"), filepath.Join(resources, "codex-cli", "bin", "codex"), filepath.Join(resources, "codex"))
			}
		} else if runtime.GOOS == "linux" {
			for _, root := range []string{"/usr/lib/chatgpt", "/opt/chatgpt", "/opt/ChatGPT", "/opt/codex", "/opt/Codex"} {
				paths = append(paths, filepath.Join(root, "resources", "codex"), filepath.Join(root, "resources", "codex-cli", "bin", "codex"))
			}
		}
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	unique := []string{}
	for _, path := range paths {
		if !csContains(unique, path) {
			unique = append(unique, path)
		}
	}
	return unique, nil
}
func ceResolvePath(command, cwd string, env []string) (string, error) {
	candidates := []string{}
	if strings.ContainsAny(command, `/\`) {
		if !filepath.IsAbs(command) {
			command = filepath.Join(cwd, command)
		}
		candidates = append(candidates, command)
	} else {
		path := ceEnvironment(env)["PATH"]
		for _, root := range filepath.SplitList(path) {
			if root == "" {
				root = cwd
			}
			candidates = append(candidates, filepath.Join(root, command))
			if runtime.GOOS == "windows" && !strings.HasSuffix(strings.ToLower(command), ".exe") {
				candidates = append(candidates, filepath.Join(root, command+".exe"))
			}
		}
	}
	for _, path := range candidates {
		info, err := os.Stat(path)
		if err == nil && !info.IsDir() && (runtime.GOOS == "windows" || info.Mode()&0111 != 0) {
			return filepath.Abs(path)
		}
	}
	return "", os.ErrNotExist
}
func ceEnvironment(env []string) map[string]string {
	if env == nil {
		env = os.Environ()
	}
	result := map[string]string{}
	for _, entry := range env {
		key, value, ok := strings.Cut(entry, "=")
		if ok {
			result[key] = value
		}
	}
	return result
}
func ceEnvironmentList(env map[string]string) []string {
	keys := make([]string, 0, len(env))
	for key := range env {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	out := make([]string, 0, len(keys))
	for _, key := range keys {
		out = append(out, key+"="+env[key])
	}
	return out
}
func ceOptionalDiscovery(ctx context.Context, command string, args, env []string) []string {
	output, err := ceProcessOutput(ctx, command, args, env, "", 5*time.Second, 1024*1024)
	if err != nil {
		return nil
	}
	paths := []string{}
	for _, path := range strings.Split(output, "\n") {
		if path = strings.TrimSpace(path); path != "" {
			paths = append(paths, path)
		}
	}
	return paths
}

type ceLimitedBuffer struct {
	bytes.Buffer
	limit    int
	overflow bool
	onLimit  func()
}

func (b *ceLimitedBuffer) Write(p []byte) (int, error) {
	size := len(p)
	remaining := b.limit - b.Len()
	if remaining < len(p) {
		if !b.overflow && b.onLimit != nil {
			b.onLimit()
		}
		b.overflow = true
		p = p[:max(0, remaining)]
	}
	_, _ = b.Buffer.Write(p)
	return size, nil
}
func ceProcessOutput(ctx context.Context, command string, args, env []string, cwd string, timeout time.Duration, limit int) (string, error) {
	limited, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	cmd := exec.CommandContext(limited, command, args...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error {
		if cmd.Process != nil {
			return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		}
		return nil
	}
	cmd.Env = env
	cmd.Dir = cwd
	cmd.WaitDelay = 500 * time.Millisecond
	out := &ceLimitedBuffer{limit: limit, onLimit: cancel}
	diagnostic := &ceLimitedBuffer{limit: 32 * 1024}
	cmd.Stdout = out
	cmd.Stderr = diagnostic
	err := cmd.Run()
	if out.overflow {
		return "", fmt.Errorf("Codex process output exceeded %d bytes", limit)
	}
	if limited.Err() != nil {
		return "", limited.Err()
	}
	if err != nil {
		return "", fmt.Errorf("%s: %w", filepath.Base(command), err)
	}
	return strings.TrimSpace(out.String()), nil
}

var ceVersionPattern = regexp.MustCompile(`^codex-cli\s+(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$`)
var ceNumericPattern = regexp.MustCompile(`^\d+$`)

func ceParseVersion(output string) *codexVersion {
	match := ceVersionPattern.FindStringSubmatch(output)
	if len(match) == 0 {
		return nil
	}
	version := &codexVersion{numbers: [3]string{match[1], match[2], match[3]}}
	if match[4] != "" {
		version.pre = strings.Split(match[4], ".")
		for _, part := range version.pre {
			if part == "" || (ceNumericPattern.MatchString(part) && len(part) > 1 && part[0] == '0') {
				return nil
			}
		}
	}
	return version
}
func ceCompareNumeric(a, b string) int {
	if len(a) != len(b) {
		if len(a) < len(b) {
			return -1
		}
		return 1
	}
	return strings.Compare(a, b)
}
func ceCompareVersion(a, b *codexVersion) int {
	for i := range 3 {
		if comparison := ceCompareNumeric(a.numbers[i], b.numbers[i]); comparison != 0 {
			return comparison
		}
	}
	if len(a.pre) == 0 || len(b.pre) == 0 {
		if len(a.pre) > 0 {
			return -1
		}
		if len(b.pre) > 0 {
			return 1
		}
		return 0
	}
	for i := 0; i < max(len(a.pre), len(b.pre)); i++ {
		if i >= len(a.pre) {
			return -1
		}
		if i >= len(b.pre) {
			return 1
		}
		left, right := a.pre[i], b.pre[i]
		if left == right {
			continue
		}
		leftNumeric, rightNumeric := ceNumericPattern.MatchString(left), ceNumericPattern.MatchString(right)
		if leftNumeric && rightNumeric {
			return ceCompareNumeric(left, right)
		}
		if leftNumeric != rightNumeric {
			if leftNumeric {
				return -1
			}
			return 1
		}
		return strings.Compare(left, right)
	}
	return 0
}

// Workspace discovery reads historical paths; it never opens a native session.
// SQLite is opened read-only and closed before continuing discovery. JSONL
// remains the independent historical fallback.
func DiscoverWorkspaceDirectories(ctx context.Context, env []string) ([]string, error) {
	values := ceEnvironment(env)
	root := ceCodexHome(values)
	sqliteRoot := values["CODEX_SQLITE_HOME"]
	if sqliteRoot == "" {
		sqliteRoot = root
	}
	if data, err := os.ReadFile(filepath.Join(root, "config.toml")); err == nil {
		configuration := Map{}
		if toml.Unmarshal(data, &configuration) == nil {
			if configured, ok := configuration["sqlite_home"].(string); ok {
				sqliteRoot = configured
			}
		}
	}
	sqliteRoot, _ = filepath.Abs(sqliteRoot)
	entries, _ := os.ReadDir(sqliteRoot)
	pattern := regexp.MustCompile(`^state_(\d+)\.sqlite$`)
	files := []string{}
	for _, entry := range entries {
		if !entry.IsDir() && pattern.MatchString(entry.Name()) {
			files = append(files, entry.Name())
		}
	}
	sort.Slice(files, func(i, j int) bool {
		a := pattern.FindStringSubmatch(files[i])[1]
		b := pattern.FindStringSubmatch(files[j])[1]
		return ceCompareNumeric(a, b) > 0
	})
	directories := []string{}
	add := func(path string) {
		if path != "" && !csContains(directories, path) {
			directories = append(directories, path)
		}
	}
	for _, name := range files {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		database, err := sqlite.Open(filepath.Join(sqliteRoot, name), true)
		if err != nil {
			continue
		}
		rows, err := database.Query("SELECT DISTINCT cwd FROM threads")
		closeErr := database.Close()
		if err != nil || closeErr != nil {
			continue
		}
		for _, row := range rows {
			if err := ctx.Err(); err != nil {
				return nil, err
			}
			add(csString(row["cwd"]))
		}
		break
	}
	for _, directory := range []string{"sessions", "archived_sessions"} {
		base := filepath.Join(root, directory)
		err := filepath.WalkDir(base, func(path string, entry os.DirEntry, err error) error {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			if err != nil {
				return nil
			}
			relative, _ := filepath.Rel(base, path)
			depth := strings.Count(relative, string(filepath.Separator))
			if entry.IsDir() {
				if depth > 3 {
					return filepath.SkipDir
				}
				return nil
			}
			if !strings.HasSuffix(path, ".jsonl") {
				return nil
			}
			file, err := os.Open(path)
			if err != nil {
				return nil
			}
			defer file.Close()
			scanner := bufio.NewScanner(io.LimitReader(file, 2*1024*1024))
			scanner.Buffer(make([]byte, 64*1024), 1024*1024)
			for scanner.Scan() {
				row := Map{}
				if json.Unmarshal(scanner.Bytes(), &row) == nil && row["type"] == "session_meta" {
					payload, _ := csRecord(row["payload"])
					add(csString(payload["cwd"]))
					break
				}
			}
			return nil
		})
		if err != nil && !errors.Is(err, os.ErrNotExist) {
			return nil, err
		}
	}
	return directories, ctx.Err()
}
func WorkspaceExcludedRoots(env []string) []string {
	return []string{filepath.Join(ceCodexHome(ceEnvironment(env)), "worktrees")}
}
func ExcludesWorkspaceDirectory(path string) bool {
	parts := strings.FieldsFunc(filepath.Clean(path), func(r rune) bool { return r == '/' || r == '\\' })
	for i := 0; i+1 < len(parts); i++ {
		if parts[i] == ".codex" && parts[i+1] == "worktrees" {
			return true
		}
	}
	return false
}
func ceCodexHome(environment map[string]string) string {
	root := strings.TrimSpace(environment["CODEX_HOME"])
	if root == "" {
		home := environment["HOME"]
		if home == "" {
			home, _ = os.UserHomeDir()
		}
		root = filepath.Join(home, ".codex")
	}
	absolute, err := filepath.Abs(root)
	if err != nil {
		return root
	}
	return absolute
}
