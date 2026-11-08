package opencode

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/platform/processgroup"
)

type Harness struct {
	host         plugin.HostContext
	settings     *SettingsAPI
	backgroundMu sync.Mutex
	lifetime     context.Context
	stop         context.CancelFunc
	workers      sync.WaitGroup
	pending      map[string]bool
	telemetry    map[string]telemetryCacheEntry
	closed       bool
	closeOnce    sync.Once
	closeErr     error
}

func New(host plugin.HostContext) *Harness {
	lifetime, stop := context.WithCancel(context.Background())
	h := &Harness{host: host, lifetime: lifetime, stop: stop, pending: map[string]bool{}, telemetry: map[string]telemetryCacheEntry{}}
	// Production discovery launches the captured source directly. A callback here
	// would resolve the environment and executable again after fingerprinting.
	h.settings = NewSettings(host, nil)
	return h
}
func (h *Harness) Descriptor() plugin.HarnessDescriptor {
	return plugin.HarnessDescriptor{ID: "opencode", DisplayName: "OpenCode", ThreadCapabilities: plugin.ThreadCapabilities{Instructions: true, ThreadContext: true, SendContext: true, ToolModes: []string{"extend", "exclusive"}}}
}
func (h *Harness) DefaultSettings() json.RawMessage         { return json.RawMessage(`{"threadSettings":{}}`) }
func (h *Harness) Settings() plugin.HarnessSettings         { return h.settings }
func (h *Harness) SessionState() plugin.SessionStateAdapter { return StateAdapter{} }
func (h *Harness) Metadata() plugin.ThreadMetadataAdapter   { return plugin.GeneratedThreadMetadata{} }
func (h *Harness) Detect(ctx context.Context, cwd string) (plugin.Installation, error) {
	env, err := hostEnvironment(ctx, h.host)
	if err != nil {
		return plugin.Installation{}, err
	}
	var path string
	if h.host.ResolveExecutable != nil {
		path, err = h.host.ResolveExecutable(ctx, "opencode", cwd, "")
	} else {
		path, err = ResolveExecutable("", env)
	}
	if err != nil {
		if ctx.Err() != nil {
			return plugin.Installation{}, ctx.Err()
		}
		return plugin.Installation{Status: "missing"}, nil
	}
	return plugin.Installation{Status: "installed", ExecutablePath: path}, nil
}
func (h *Harness) Install(ctx context.Context) error {
	env, err := hostEnvironment(ctx, h.host)
	if err != nil {
		return err
	}
	path := ""
	for _, name := range []string{"npm"} {
		if h.host.ResolveExecutable != nil {
			path, err = h.host.ResolveExecutable(ctx, name, "", "")
		} else {
			path, err = exec.LookPath(name)
		}
		if err == nil {
			break
		}
	}
	if path == "" {
		return errors.New("installing external OpenCode requires npm; install @opencode/cli@2.0.25 manually")
	}
	var values []string
	for k, v := range env {
		values = append(values, k+"="+v)
	}
	// npm lifecycle scripts belong to this installation, including after npm exits.
	result, err := processgroup.Run(ctx, path, []string{"install", "--global", "@opencode/cli@2.0.25"}, "", values, 8*1024*1024)
	if err == nil && result.ExitCode != 0 {
		err = fmt.Errorf("exit status %d", result.ExitCode)
	}
	if err != nil {
		return fmt.Errorf("OpenCode installer failed: %w: %s", err, clip(strings.TrimSpace(result.Stderr+"\n"+result.Stdout), 8192))
	}
	return nil
}
func (h *Harness) launch(ctx context.Context, s Settings, cwd string, isolated bool) (*Runtime, error) {
	options, err := captureLaunch(ctx, h.host, s, cwd)
	if err != nil {
		return nil, err
	}
	options.IsolateConfig = isolated
	return NewRuntime(ctx, options)
}

// Capture once so fingerprinting and process startup use the same resolver and
// environment. NewRuntime receives an absolute executable, never a PATH lookup.
func captureLaunch(ctx context.Context, host plugin.HostContext, s Settings, cwd string) (Options, error) {
	env, err := hostEnvironment(ctx, host)
	if err != nil {
		return Options{}, err
	}
	executable := s.ExecutablePath
	if host.ResolveExecutable != nil {
		path, resolveErr := host.ResolveExecutable(ctx, "opencode", cwd, executable)
		if resolveErr == nil {
			executable = path
		} else if executable != "" {
			return Options{}, resolveErr
		}
	}
	executable, err = ResolveExecutable(executable, env)
	if err != nil {
		return Options{}, err
	}
	executable, err = filepath.Abs(executable)
	if err != nil {
		return Options{}, err
	}
	return Options{CWD: cwd, ConfigurationCWD: s.ConfigurationCWD, ExecutablePath: executable, Environment: env}, nil
}

func (h *Harness) Open(ctx context.Context, open plugin.OpenContext) (plugin.Handle, error) {
	handle, err := OpenThread(ctx, open, h.launch)
	if err != nil {
		return nil, err
	}
	return plugin.WithGeneratedThreadMetadata(ctx, open, handle, func(ctx context.Context, request plugin.PromptRequest, source json.RawMessage) (plugin.PromptResult, error) {
		settings, err := h.settings.PromptSettings(h.DefaultSettings(), source)
		if err != nil {
			return plugin.PromptResult{}, err
		}
		request.Settings = settings
		return h.Complete(ctx, request)
	}), nil
}
func (h *Harness) Complete(ctx context.Context, request plugin.PromptRequest) (plugin.PromptResult, error) {
	return Complete(ctx, h.host, h.launch, request)
}
func (h *Harness) Fork(ctx context.Context, request plugin.ForkRequest) (plugin.ForkResult, error) {
	return Fork(ctx, request)
}
func (h *Harness) Probe(ctx context.Context, request plugin.SettingsRequest, mode string) (plugin.Availability, error) {
	return h.settings.Probe(ctx, request, mode)
}
func (h *Harness) ModelCatalog(ctx context.Context, request plugin.SettingsRequest) (json.RawMessage, error) {
	return h.settings.ModelCatalog(ctx, request)
}
func (h *Harness) DiscoverWorkspaceDirectories(ctx context.Context) ([]string, error) {
	env, err := hostEnvironment(ctx, h.host)
	if err != nil {
		return nil, err
	}
	return DiscoverWorkspaceDirectories(ctx, env)
}
func (h *Harness) WorkspaceDirectoryPolicy(ctx context.Context) (plugin.DirectoryPolicy, error) {
	env, err := hostEnvironment(ctx, h.host)
	if err != nil {
		return plugin.DirectoryPolicy{}, err
	}
	return WorkspaceDirectoryPolicy(ctx, env)
}

var _ plugin.Harness = (*Harness)(nil)
var _ plugin.Handle = (*Thread)(nil)
var _ plugin.Forker = (*Harness)(nil)
var _ plugin.PromptCompleter = (*Harness)(nil)

func (h *Harness) background(key string, run func(context.Context)) {
	h.backgroundMu.Lock()
	defer h.backgroundMu.Unlock()
	if h.closed || h.pending[key] {
		return
	}
	h.pending[key] = true
	h.workers.Add(1)
	go func() {
		defer h.workers.Done()
		ctx, cancel := context.WithTimeout(h.lifetime, 55*time.Second)
		defer cancel()
		run(ctx)
		h.backgroundMu.Lock()
		delete(h.pending, key)
		h.backgroundMu.Unlock()
	}()
}
func (h *Harness) Close() error {
	h.closeOnce.Do(func() {
		h.backgroundMu.Lock()
		h.closed = true
		h.stop()
		h.backgroundMu.Unlock()
		h.workers.Wait()
		h.closeErr = h.settings.Close()
	})
	return h.closeErr
}

var _ plugin.Closer = (*Harness)(nil)
