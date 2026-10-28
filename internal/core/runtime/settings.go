package runtime

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/services/workspaces"
)

type SettingsResult struct {
	Status           string         `json:"status"`
	SettingsRevision int64          `json:"settingsRevision"`
	Settings         model.Settings `json:"settings"`
}

func (r *Runtime) UpdateSettings(ctx context.Context, expected int64, settings model.Settings) (result SettingsResult, err error) {
	queuedAt := time.Now()
	stage := "queue"
	finishSave := r.settingsSpan(ctx, "save", model.Object{"expectedRevision": expected})
	defer func() {
		if err != nil {
			r.settingsTrace(ctx, "save.failed", model.Object{"stage": stage, "outcome": "failed"})
		}
		finishSave(err)
	}()
	if err := r.begin(); err != nil {
		return SettingsResult{}, err
	}
	defer r.operations.Done()
	unlock, err := r.configurationLock(ctx)
	if err != nil {
		return SettingsResult{}, err
	}
	defer unlock()
	previous, revision, err := r.Settings()
	if err != nil {
		return SettingsResult{}, err
	}
	r.settingsTrace(ctx, "save.admitted", model.Object{"queueMs": float64(time.Since(queuedAt)) / float64(time.Millisecond), "revision": revision})
	if expected != revision {
		r.settingsTrace(ctx, "save.conflict", model.Object{"revision": revision, "expectedRevision": expected})
		return SettingsResult{Status: "conflict", Settings: previous, SettingsRevision: revision}, nil
	}
	stage = "normalize"
	settings, err = normalizeSettingsShell(settings)
	if err != nil {
		return SettingsResult{}, err
	}
	settings, err = retainExecutionProfiles(settings, previous)
	if err != nil {
		return SettingsResult{}, err
	}
	stage = "plugins"
	finishPlugins := r.settingsSpan(ctx, "validate.plugins", model.Object{})
	pluginsFinished := false
	defer func() {
		if !pluginsFinished {
			finishPlugins(err)
		}
	}()
	knownPlugins := map[string]bool{}
	for _, p := range r.config.Plugins {
		knownPlugins[p.Key] = true
	}
	for key := range settings.PluginEnabled {
		if !knownPlugins[key] {
			return SettingsResult{}, fmt.Errorf("unknown plugin preference: %s", key)
		}
	}
	if settings.Moku.HostHarnessPreference == "" {
		return SettingsResult{}, errors.New("Moku host harness preference is required")
	}
	if p := settings.Moku.HostHarnessPreference; p != "auto" && r.config.Harnesses[p] == nil {
		return SettingsResult{}, fmt.Errorf("unknown Moku harness: %s", p)
	}
	for _, id := range settings.Moku.TargetHarnessIDs {
		if r.config.Harnesses[id] == nil {
			return SettingsResult{}, fmt.Errorf("unknown target harness: %s", id)
		}
	}
	for id, value := range settings.Harnesses {
		h := r.config.Harnesses[id]
		if h == nil {
			return SettingsResult{}, fmt.Errorf("unknown harness setting: %s", id)
		}
		normalized, err := h.Settings().Normalize(value)
		if err != nil {
			return SettingsResult{}, err
		}
		settings.Harnesses[id] = normalized
	}
	for id, h := range r.config.Harnesses {
		if _, ok := settings.Harnesses[id]; !ok {
			return SettingsResult{}, fmt.Errorf("missing settings for harness: %s", id)
		}
		if value, ok := settings.Moku.ExecutionHarnesses[id]; ok {
			normalized, err := h.Settings().Normalize(value)
			if err != nil {
				return SettingsResult{}, err
			}
			settings.Moku.ExecutionHarnesses[id] = normalized
		}
	}
	for id := range settings.Moku.ExecutionHarnesses {
		if r.config.Harnesses[id] == nil {
			return SettingsResult{}, fmt.Errorf("unknown execution harness: %s", id)
		}
	}
	if validator, ok := r.config.Applications.(interface {
		ValidateSettings(context.Context, model.Settings) (model.Settings, error)
	}); ok {
		validated, err := validator.ValidateSettings(ctx, settings)
		if err != nil {
			return SettingsResult{}, err
		}
		settings = validated
	}
	r.settingsTrace(ctx, "save.changed", model.Object{"fields": changedSettingsFields(previous, settings)})
	finishPlugins(nil)
	pluginsFinished = true
	stage = "profiles"
	finishProfiles := r.settingsSpan(ctx, "validate.profiles", model.Object{})
	settings, err = r.validateChangedProfiles(ctx, settings, previous)
	finishProfiles(err)
	if err != nil {
		return SettingsResult{}, err
	}
	stage = "persist"
	finishPersist := r.settingsSpan(ctx, "persist", model.Object{"expectedRevision": expected})
	result = SettingsResult{}
	_, err = r.config.Store.Update(ctx, func(tx *store.Tx) error {
		var current model.Settings
		var revision int64
		if _, err := tx.Get("settings", &current); err != nil {
			return err
		}
		if _, err := tx.Get("settings-revision", &revision); err != nil {
			return err
		}
		result = SettingsResult{Status: "conflict", SettingsRevision: revision, Settings: current}
		if revision != expected {
			return nil
		}
		if same(current, settings) {
			result.Status = "saved"
			return nil
		}
		revision++
		if err := tx.Put("settings", settings); err != nil {
			return err
		}
		if err := tx.Put("settings-revision", revision); err != nil {
			return err
		}
		result = SettingsResult{Status: "saved", SettingsRevision: revision, Settings: settings}
		if bindings, ok := r.config.Applications.(interface{ BackgroundSettingsBindings() map[string]string }); ok {
			configured := bindings.BackgroundSettingsBindings()
			agentIDs := make([]string, 0, len(configured))
			for id := range configured {
				agentIDs = append(agentIDs, id)
			}
			sort.Strings(agentIDs)
			for _, agentID := range agentIDs {
				settingsID := configured[agentID]
				capability := backgroundCapability{settingsID: settingsID}
				beforeHarnesses, beforePreference, beforeErr := capability.effectiveSettings(current)
				afterHarnesses, afterPreference, afterErr := capability.effectiveSettings(settings)
				if err := errors.Join(beforeErr, afterErr); err != nil {
					return err
				}
				if beforePreference != afterPreference || !same(beforeHarnesses, afterHarnesses) {
					if err := r.appendEvent(tx, "settings.changed", store.Subject{Kind: "settings", ID: agentID, TypeID: agentID}, "user", map[string]any{}, nil); err != nil {
						return err
					}
				}
			}
		}
		return r.appendEvent(tx, "settings.changed", store.Subject{Kind: "settings", ID: "mokusei", TypeID: "settings"}, "user", map[string]any{"settingsRevision": revision}, nil)
	})
	finishPersist(err)
	if err == nil {
		if result.Status == "saved" {
			r.Publish()
			r.settingsTrace(ctx, "published", model.Object{"revision": result.SettingsRevision})
			r.settingsTrace(ctx, "save.saved", model.Object{"revision": result.SettingsRevision, "changed": result.SettingsRevision != revision})
		} else {
			r.settingsTrace(ctx, "save.conflict", model.Object{"revision": result.SettingsRevision, "expectedRevision": expected})
		}
	}
	return result, err
}

type ThreadSettingsResult struct {
	Status           string          `json:"status"`
	SettingsRevision int64           `json:"settingsRevision"`
	Settings         json.RawMessage `json:"settings"`
}

func (r *Runtime) UpdateThreadSettings(ctx context.Context, id, harnessID string, expected int64, change json.RawMessage) (ThreadSettingsResult, error) {
	result := ThreadSettingsResult{}
	if expected < 0 || expected > model.MaximumSafeInteger {
		return result, errors.New("invalid settings revision")
	}
	if err := r.begin(); err != nil {
		return result, err
	}
	defer r.operations.Done()
	lock := r.threadLock(id)
	lock.Lock()
	defer lock.Unlock()
	source, err := r.Thread(id)
	if err != nil {
		return result, err
	}
	result = ThreadSettingsResult{Status: "conflict", SettingsRevision: source.SettingsRevision, Settings: model.CloneRaw(source.Settings)}
	if source.HarnessID != harnessID {
		return result, errors.New("thread harness does not match")
	}
	if source.Moku || source.MokuHistory {
		return result, errors.New("Moku execution settings cannot be edited through a thread")
	}
	if source.SettingsRevision != expected {
		return result, nil
	}
	if source.PendingInput || source.Observation.LatestExecution != nil && !source.Observation.LatestExecution.Terminal() {
		return result, errors.New("cannot update settings during an active execution or input admission")
	}
	h, err := r.harness(ctx, source)
	if err != nil {
		return result, err
	}
	settings, _, err := r.Settings()
	if err != nil {
		return result, err
	}
	resolved, err := h.Settings().ApplyThreadUpdate(ctx, plugin.UpdateSettingsRequest{Current: source.Settings, Defaults: settings.Harnesses[harnessID], Update: change, HasContent: h.Settings().HasThreadContent(source.SessionState), Cwd: effectiveCwd(source)})
	if err != nil {
		return result, err
	}
	err = r.UpdateThread(ctx, id, func(t *model.ThreadRecord) error {
		if t.MokuHistory {
			return errors.New("Moku history is read-only")
		}
		if t.SettingsRevision != expected || !same(t.Settings, source.Settings) || t.HarnessID != source.HarnessID {
			result = ThreadSettingsResult{Status: "conflict", SettingsRevision: t.SettingsRevision, Settings: model.CloneRaw(t.Settings)}
			return errThreadSettingsConflict
		}
		if t.PendingInput || t.Observation.LatestExecution != nil && !t.Observation.LatestExecution.Terminal() {
			return errors.New("thread execution or input admission started while resolving settings")
		}
		if t.SettingsRevision == model.MaximumSafeInteger && !same(t.Settings, resolved) {
			return errors.New("thread settings revision exhausted")
		}
		result = ThreadSettingsResult{Status: "saved", SettingsRevision: t.SettingsRevision, Settings: model.CloneRaw(resolved)}
		if !same(t.Settings, resolved) {
			result.SettingsRevision++
		}
		t.Settings = resolved
		return nil
	})
	if errors.Is(err, errThreadSettingsConflict) {
		return result, nil
	}
	return result, err
}

var errThreadSettingsConflict = errors.New("thread settings revision conflict")

func (r *Runtime) SettingsPresentation(ctx context.Context, raw json.RawMessage) (result any, err error) {
	var request struct {
		Scope               string `json:"scope"`
		HarnessID           string `json:"harnessId,omitempty"`
		ThreadID            string `json:"threadId,omitempty"`
		Refresh             bool   `json:"refresh,omitempty"`
		ExecutionOwner      string `json:"executionOwner,omitempty"`
		ApplicationSettings string `json:"applicationSettings,omitempty"`
	}
	if err := model.Unmarshal(raw, &request); err != nil {
		return nil, err
	}
	owner := request.ApplicationSettings
	if owner == "" {
		owner = request.ExecutionOwner
	}
	if owner == "" {
		owner = "global"
	}
	finish := r.settingsSpan(ctx, "presentation", model.Object{"scope": request.Scope, "harnessId": request.HarnessID, "refresh": request.Refresh, "owner": owner})
	defer func() { finish(err) }()
	snapshotError := ""
	if request.Scope == "global" && (request.ExecutionOwner == "moku" || request.ApplicationSettings != "") {
		finishSnapshot := r.settingsSpan(ctx, "presentation.snapshot", model.Object{"harnessId": request.HarnessID, "owner": owner})
		_, snapshotErr := r.EnsureExecutionSettings(ctx, request.HarnessID, request.ApplicationSettings)
		finishSnapshot(snapshotErr)
		if err := snapshotErr; err != nil {
			if ctx.Err() != nil {
				return nil, ctx.Err()
			}
			snapshotError = err.Error()
		}
	}
	settings, _, err := r.Settings()
	if err != nil {
		return nil, err
	}
	cwd := r.config.DefaultCwd
	var threadSettings json.RawMessage
	var threadSource *model.ThreadRecord
	var observed *workspaces.Observation
	var h plugin.Harness
	switch request.Scope {
	case "thread":
		if request.HarnessID != "" || request.ExecutionOwner != "" || request.ApplicationSettings != "" {
			return nil, errors.New("invalid thread presentation fields")
		}
		t, err := r.Thread(request.ThreadID)
		if err != nil {
			return nil, err
		}
		request.HarnessID = t.HarnessID
		threadSource = &t
		if r.config.Workspaces != nil {
			observed, err = r.config.Workspaces.Observe(ctx, t, nil)
			if err != nil {
				return nil, err
			}
			defer r.config.Workspaces.ReleaseObservation(observed)
		}
		cwd = effectiveCwd(t)
		threadSettings = t.Settings
		h, err = r.harness(ctx, t)
		if err != nil {
			return nil, err
		}
	case "global":
		if request.ThreadID != "" {
			return nil, errors.New("global presentation has no threadId")
		}
		h = r.config.Harnesses[request.HarnessID]
		if h == nil {
			return nil, fmt.Errorf("unknown harness: %s", request.HarnessID)
		}
	default:
		return nil, errors.New("invalid harness settings scope")
	}
	selectSource := func(saved model.Settings) (json.RawMessage, string, error) {
		selected := saved.Harnesses[request.HarnessID]
		workspace := cwd
		var workspaceErr error
		if request.ExecutionOwner == "moku" {
			selected = saved.Moku.ExecutionHarnesses[request.HarnessID]
			workspace, workspaceErr = r.configurationCwd("")
			if workspaceErr != nil {
				return nil, "", workspaceErr
			}
		}
		if request.ApplicationSettings != "" {
			found := false
			for _, entry := range saved.PluginSettings {
				if entry.ID != request.ApplicationSettings {
					continue
				}
				var value backgroundSettings
				if err := model.Unmarshal(entry.Value, &value); err != nil {
					return nil, "", err
				}
				if value.Mode == "inherit" {
					selected = saved.Moku.ExecutionHarnesses[request.HarnessID]
					workspace, workspaceErr = r.configurationCwd("")
				} else if value.Mode == "override" {
					selected = value.Harnesses[request.HarnessID]
					workspace, workspaceErr = r.configurationCwd(request.ApplicationSettings)
				} else {
					return nil, "", errors.New("not an execution settings binding")
				}
				if workspaceErr != nil {
					return nil, "", workspaceErr
				}
				found = true
			}
			if !found {
				return nil, "", errors.New("unknown application execution settings")
			}
		}
		if len(selected) == 0 {
			selected = h.DefaultSettings()
		}
		return selected, workspace, nil
	}
	harnessSettings, cwd, err := selectSource(settings)
	if err != nil {
		return nil, err
	}
	finishNative := r.settingsSpan(ctx, "presentation.native", model.Object{"harnessId": request.HarnessID, "owner": owner})
	value, err := h.Settings().Presentation(ctx, plugin.SettingsPresentationRequest{Settings: harnessSettings, Cwd: cwd, ThreadSettings: threadSettings, Refresh: request.Refresh})
	finishNative(err)
	if err != nil {
		return nil, err
	}
	if threadSource != nil {
		current, e := r.Thread(threadSource.ID)
		if e != nil {
			return nil, e
		}
		if threadSource.SettingsRevision != current.SettingsRevision || !sameVoiceSource(*threadSource, current) {
			return nil, errors.New("thread settings source changed during presentation")
		}
		if r.config.Workspaces != nil {
			if _, e := r.config.Workspaces.Observe(ctx, current, observed); e != nil {
				return nil, e
			}
		}
	} else {
		latest, _, e := r.Settings()
		if e != nil {
			return nil, e
		}
		profile, workspace, e := selectSource(latest)
		if e != nil {
			return nil, e
		}
		if !same(profile, harnessSettings) || workspace != cwd {
			return nil, errors.New("settings source changed during presentation")
		}
	}
	output := map[string]any{"scope": request.Scope, "harnessId": request.HarnessID, "value": value}
	if snapshotError != "" {
		output["executionSnapshotError"] = snapshotError
	}
	if request.Scope == "thread" {
		output["threadId"] = request.ThreadID
		output["settingsRevision"] = threadSource.SettingsRevision
	}
	return output, nil
}

// Automatic discovery is independent per Harness and reuses the environment.
// Explicit recovery retains DetectInstallations, which refreshes the shell once.
func (r *Runtime) DetectInstallation(ctx context.Context, id string) (result plugin.Installation, err error) {
	h := r.config.Harnesses[id]
	if h == nil {
		return result, fmt.Errorf("unknown harness: %s", id)
	}
	finish := r.settingsSpan(ctx, "installation", model.Object{"harnessId": id})
	defer func() { finish(err) }()
	return h.Detect(ctx, r.config.DefaultCwd)
}

func (r *Runtime) DetectInstallations(ctx context.Context) (map[string]any, error) {
	if r.config.RefreshEnvironment != nil {
		if err := r.config.RefreshEnvironment(ctx); err != nil {
			return nil, err
		}
	}
	result := map[string]any{}
	var mu sync.Mutex
	var workers sync.WaitGroup
	for id := range r.config.Harnesses {
		workers.Add(1)
		go func(id string) {
			defer workers.Done()
			value, err := r.DetectInstallation(ctx, id)
			mu.Lock()
			defer mu.Unlock()
			if err != nil {
				result[id] = map[string]string{"status": "error", "message": err.Error()}
			} else {
				result[id] = value
			}
		}(id)
	}
	workers.Wait()
	return result, ctx.Err()
}
func (r *Runtime) KnownDirectories(ctx context.Context) ([]model.KnownDirectory, error) {
	paths := []string{r.config.DefaultCwd}
	threads, err := r.Threads()
	if err != nil {
		return nil, err
	}
	for _, t := range threads {
		paths = append(paths, t.Cwd)
	}
	policies := []plugin.DirectoryPolicy{}
	for _, h := range r.config.Harnesses {
		if d, ok := h.(plugin.WorkspaceDiscoverer); ok {
			found, e := d.DiscoverWorkspaceDirectories(ctx)
			if e != nil {
				r.log("workspace.discover", e)
			} else {
				paths = append(paths, found...)
			}
		}
		if p, ok := h.(plugin.WorkspacePolicy); ok {
			policy, e := p.WorkspaceDirectoryPolicy(ctx)
			if e != nil {
				return nil, e
			}
			policies = append(policies, policy)
		}
	}
	seen := map[string]bool{}
	result := []model.KnownDirectory{}
	for _, path := range paths {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		if !filepath.IsAbs(path) || strings.ContainsRune(path, 0) {
			continue
		}
		path = filepath.Clean(path)
		canonical, e := filepath.EvalSymlinks(path)
		if e != nil {
			canonical = path
		}
		if within(r.config.DataDir, canonical) || seen[canonical] {
			continue
		}
		excluded := false
		for _, part := range strings.Split(canonical, string(filepath.Separator)) {
			if strings.HasPrefix(part, ".") && strings.HasSuffix(part, "-mokusei-worktrees") {
				excluded = true
			}
		}
		for _, p := range policies {
			if p.Excludes != nil && p.Excludes(canonical) {
				excluded = true
			}
			for _, root := range p.ExcludedRoots {
				if within(root, canonical) {
					excluded = true
				}
			}
		}
		if excluded {
			continue
		}
		seen[canonical] = true
		result = append(result, model.KnownDirectory{Name: filepath.Base(path), Path: path})
	}
	sort.Slice(result, func(i, j int) bool {
		if result[i].Name == result[j].Name {
			return result[i].Path < result[j].Path
		}
		return result[i].Name < result[j].Name
	})
	return result, nil
}
func within(root, path string) bool {
	rel, err := filepath.Rel(root, path)
	return err == nil && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator)) && !filepath.IsAbs(rel)
}
