package opencode

import (
	"context"
	"encoding/json"
	"errors"
	"os/exec"
	"sync"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/plugin"
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
	h.settings = NewSettings(host, func(ctx context.Context, s Settings, cwd string) (*Runtime, error) {
		return h.launch(ctx, s, cwd, false)
	})
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
	cmd := exec.CommandContext(ctx, path, "install", "--global", "@opencode/cli@2.0.25")
	for k, v := range env {
		cmd.Env = append(cmd.Env, k+"="+v)
	}
	return cmd.Run()
}
func (h *Harness) launch(ctx context.Context, s Settings, cwd string, isolated bool) (*Runtime, error) {
	env, err := hostEnvironment(ctx, h.host)
	if err != nil {
		return nil, err
	}
	if h.host.ResolveExecutable != nil {
		path, resolveErr := h.host.ResolveExecutable(ctx, "opencode", cwd, s.ExecutablePath)
		if resolveErr == nil {
			s.ExecutablePath = path
		} else if s.ExecutablePath != "" {
			return nil, resolveErr
		}
	}
	return NewRuntime(ctx, Options{CWD: cwd, ConfigurationCWD: s.ConfigurationCWD, ExecutablePath: s.ExecutablePath, Environment: env, IsolateConfig: isolated})
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
