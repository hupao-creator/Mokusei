// Package pi implements Pi's native RPC boundary in Go. The two embedded JS
// resources run only inside the external Harness; Mokusei starts no Node service.
package pi

import (
	"context"
	"encoding/json"
	"errors"
	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"io"
	"os"
	"path/filepath"
	"strings"
)

type Adapter struct {
	host     plugin.HostContext
	settings *settingsAPI
}

func New(host plugin.HostContext) *Adapter { return &Adapter{host: host, settings: newSettings(host)} }
func (a *Adapter) Close() error            { return a.settings.close() }

func (*Adapter) Descriptor() plugin.HarnessDescriptor {
	return plugin.HarnessDescriptor{ID: "pi", DisplayName: "Pi Agent", ThreadCapabilities: plugin.ThreadCapabilities{Instructions: true, ThreadContext: true, SendContext: true, ToolModes: []string{"exclusive"}}}
}
func (*Adapter) DefaultSettings() json.RawMessage         { return json.RawMessage(`{"threadSettings":{}}`) }
func (a *Adapter) Settings() plugin.HarnessSettings       { return a.settings }
func (*Adapter) SessionState() plugin.SessionStateAdapter { return stateAdapter{} }
func (*Adapter) Metadata() plugin.ThreadMetadataAdapter   { return plugin.GeneratedThreadMetadata{} }
func (a *Adapter) Open(ctx context.Context, input plugin.OpenContext) (plugin.Handle, error) {
	handle, err := openThread(ctx, a.host, input)
	if err != nil {
		return nil, err
	}
	return plugin.WithGeneratedThreadMetadata(ctx, input, handle, func(ctx context.Context, request plugin.PromptRequest, source json.RawMessage) (plugin.PromptResult, error) {
		settings, err := a.settings.PromptSettings(a.DefaultSettings(), source)
		if err != nil {
			return plugin.PromptResult{}, err
		}
		request.Settings = settings
		return a.Complete(ctx, request)
	}), nil
}
func (a *Adapter) Detect(ctx context.Context, cwd string) (plugin.Installation, error) {
	path, err := resolveExecutable(ctx, a.host, cwd, "")
	if ctx.Err() != nil {
		return plugin.Installation{}, ctx.Err()
	}
	if err != nil {
		var nativeError *model.Error
		missing := errors.As(err, &nativeError) && nativeError.Code == "HARNESS_EXECUTABLE_NOT_FOUND"
		if missing || errors.Is(err, os.ErrNotExist) || strings.Contains(err.Error(), "not found") || strings.Contains(err.Error(), "executable file not found") {
			a.settings.recordInstallation(cwd, "")
			return plugin.Installation{Status: "missing"}, nil
		}
		return plugin.Installation{}, err
	}
	a.settings.recordInstallation(cwd, path)
	return plugin.Installation{Status: "installed", ExecutablePath: path}, nil
}
func (a *Adapter) Probe(ctx context.Context, input plugin.SettingsRequest, _ string) (plugin.Availability, error) {
	raw, err := a.settings.DefaultThread(input.Settings)
	if err != nil {
		return plugin.Availability{}, err
	}
	settings, err := normalizeThread(raw)
	if err != nil {
		return plugin.Availability{}, err
	}
	observed, err := a.settings.observe(ctx, settings, input.Cwd, false, false)
	if err != nil {
		if ctx.Err() != nil {
			return plugin.Availability{}, ctx.Err()
		}
		return plugin.Availability{Available: false, Reason: err.Error()}, nil
	}
	if observed.State.Model == nil {
		return plugin.Availability{Available: false, Reason: "Pi has no configured model. Run pi /login to configure authentication."}, nil
	}
	m := observed.State.Model
	if settings.Provider != "" && m.Provider != settings.Provider || settings.Model != "" && m.ID != settings.Model || settings.ThinkingLevel != "" && observed.State.ThinkingLevel != settings.ThinkingLevel {
		return plugin.Availability{Available: false, Reason: "Pi could not apply selected provider/model/thinking configuration"}, nil
	}
	return plugin.Availability{Available: true}, nil
}
func (a *Adapter) Fork(ctx context.Context, input plugin.ForkRequest) (plugin.ForkResult, error) {
	if err := ctx.Err(); err != nil {
		return plugin.ForkResult{}, err
	}
	if !model.IsNull(input.Request) {
		object, err := model.DecodeObject(input.Request)
		if err != nil || len(object) > 0 {
			return plugin.ForkResult{}, errors.New("Pi forks clone current branch; historical selectors unsupported")
		}
	}
	state, err := decodeState(input.Source.SessionState)
	if err != nil {
		return plugin.ForkResult{}, err
	}
	for _, e := range state.Executions {
		if !e.Terminal() {
			return plugin.ForkResult{}, errors.New("wait for Pi Execution to finish before forking")
		}
	}
	if state.NativeSessionJSONL == "" {
		return plugin.ForkResult{}, errors.New("Pi has no persisted native session to fork; complete conversation first")
	}
	state.ForkSource = &ForkSource{JSONL: state.NativeSessionJSONL}
	state.SessionFile = ""
	state.LatestExecutionID = nil
	raw, err := json.Marshal(state)
	return plugin.ForkResult{SessionState: raw, Settings: input.Source.Settings, MetadataState: input.Source.MetadataState}, err
}
func (a *Adapter) DiscoverWorkspaceDirectories(ctx context.Context) ([]string, error) {
	env, err := inheritedEnvironment(ctx, a.host)
	if err != nil {
		return nil, err
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return nil, err
	}
	directory := env["PI_CODING_AGENT_DIR"]
	if directory == "" {
		directory = filepath.Join(home, ".pi", "agent")
	}
	directory, err = filepath.Abs(directory)
	if err != nil {
		return nil, err
	}
	settings, err := readObject(filepath.Join(directory, "settings.json"))
	if err != nil {
		return nil, err
	}
	configured := env["PI_CODING_AGENT_SESSION_DIR"]
	if configured == "" {
		configured, _ = settings["sessionDir"].(string)
	}
	roots := []string{filepath.Join(directory, "sessions")}
	if configured != "" {
		if configured == "~" || strings.HasPrefix(configured, "~/") {
			configured = home + strings.TrimPrefix(configured, "~")
		}
		configured, err = filepath.Abs(configured)
		if err != nil {
			return nil, err
		}
		if configured != roots[0] {
			roots = append(roots, configured)
		}
	}
	directories := []string{}
	seen := map[string]bool{}
	for _, root := range roots {
		err = filepath.WalkDir(root, func(path string, entry os.DirEntry, walkErr error) error {
			if err := ctx.Err(); err != nil {
				return err
			}
			if walkErr != nil {
				if errors.Is(walkErr, os.ErrNotExist) || errors.Is(walkErr, os.ErrPermission) {
					return nil
				}
				return walkErr
			}
			relative, _ := filepath.Rel(root, path)
			depth := strings.Count(relative, string(filepath.Separator))
			if entry.IsDir() {
				if depth >= 1 && relative != "." {
					return filepath.SkipDir
				}
				return nil
			}
			if !strings.HasSuffix(entry.Name(), ".jsonl") {
				return nil
			}
			file, err := os.Open(path)
			if err != nil {
				return nil
			}
			defer file.Close()
			var header struct {
				Type string `json:"type"`
				Cwd  string `json:"cwd"`
			}
			decoder := json.NewDecoder(io.LimitReader(file, 1024*1024))
			err = decoder.Decode(&header)
			if err == nil && header.Type == "session" && filepath.IsAbs(header.Cwd) && !seen[header.Cwd] {
				if info, statErr := os.Stat(header.Cwd); statErr == nil && info.IsDir() {
					directories = append(directories, header.Cwd)
					seen[header.Cwd] = true
				}
			}
			return nil
		})
		if err != nil {
			return nil, err
		}
	}
	return directories, nil
}

func (a *Adapter) ModelCatalog(ctx context.Context, input plugin.SettingsRequest) (json.RawMessage, error) {
	raw, err := a.settings.DefaultThread(input.Settings)
	if err != nil {
		return nil, err
	}
	settings, err := normalizeThread(raw)
	if err != nil {
		return nil, err
	}
	observed, err := a.settings.observe(ctx, settings, input.Cwd, true, false)
	if err != nil {
		return nil, err
	}
	models := []model.Object{}
	if observed.State.Model != nil {
		for _, m := range observed.Models {
			if m.Provider == observed.State.Model.Provider {
				entry := model.Object{"selector": m.ID, "displayName": m.Name}
				entry["provenance"] = model.Object{"kind": "unknown"}
				models = append(models, entry)
			}
		}
	}
	return json.Marshal(model.Object{"models": models})
}

var _ plugin.Harness = (*Adapter)(nil)
var _ plugin.Forker = (*Adapter)(nil)
var _ plugin.PromptCompleter = (*Adapter)(nil)
var _ plugin.AvailabilityProbe = (*Adapter)(nil)
var _ plugin.WorkspaceDiscoverer = (*Adapter)(nil)
var _ plugin.ModelCatalogSource = (*Adapter)(nil)
