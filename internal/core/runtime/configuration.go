package runtime

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/core/store"
)

type configurationContextKey struct{}
type MokuConfiguration struct {
	HarnessID        string
	Settings         json.RawMessage
	Cwd              string
	AppliedSettings  model.Settings
	SettingsRevision int64
	Unapplied        bool
	// PreserveNote copies the persistent note when a replacement Thread takes
	// over the same Moku history.
	PreserveNote    bool
	PreserveHistory bool
}
type ConfigurationChange struct {
	Settings            model.Settings
	SettingsRevision    int64
	Applied             *model.Settings
	Pending             bool
	ResolveHost         bool
	ResolveHostSettings bool
}
type executionProfiles struct {
	HarnessPreference string                     `json:"harnessPreference"`
	Harnesses         map[string]json.RawMessage `json:"harnesses"`
}
type backgroundSettings struct {
	Mode              string                     `json:"mode"`
	HarnessPreference string                     `json:"harnessPreference,omitempty"`
	Harnesses         map[string]json.RawMessage `json:"harnesses,omitempty"`
	Independent       *executionProfiles         `json:"independent,omitempty"`
}

// WithConfigurationAdmission serializes the entire native admission against
// settings saves. Its context makes nested snapshot preparation non-recursive.
func (r *Runtime) WithConfigurationAdmission(ctx context.Context, operation func(context.Context) error) error {
	if err := r.begin(); err != nil {
		return err
	}
	defer r.operations.Done()
	unlock, err := r.configurationLock(ctx)
	if err != nil {
		return err
	}
	defer unlock()
	return operation(context.WithValue(ctx, configurationContextKey{}, r))
}
func (r *Runtime) configurationLock(ctx context.Context) (func(), error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if ctx.Value(configurationContextKey{}) == r {
		return func() {}, nil
	}
	// Native discovery can hold this gate for seconds. Abandoned presentation
	// requests must stop waiting immediately so they do not retain HTTP slots.
	select {
	case r.configurationGate <- struct{}{}:
		if err := ctx.Err(); err != nil {
			<-r.configurationGate
			return nil, err
		}
		return func() { <-r.configurationGate }, nil
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}
func (r *Runtime) ReadMokuConfiguration() (MokuConfiguration, error) {
	threads, err := r.Threads()
	if err != nil {
		return MokuConfiguration{}, err
	}
	var thread *model.ThreadRecord
	for _, t := range threads {
		if t.Moku {
			value := t
			thread = &value
			break
		}
	}
	if thread == nil {
		return MokuConfiguration{}, errors.New("Moku session is not initialized")
	}
	settings, revision, err := r.Settings()
	if err != nil {
		return MokuConfiguration{}, err
	}
	var saved struct {
		Settings         model.Settings `json:"settings"`
		SettingsRevision int64          `json:"settingsRevision"`
	}
	unapplied := false
	if ok, e := r.config.Store.Snapshot().Get("moku-applied-settings", &saved); e != nil {
		return MokuConfiguration{}, e
	} else if ok {
		settings = saved.Settings
		revision = saved.SettingsRevision
	} else {
		unapplied = true
	}
	return MokuConfiguration{HarnessID: thread.HarnessID, Settings: thread.Settings, Cwd: thread.Cwd, AppliedSettings: settings, SettingsRevision: revision, Unapplied: unapplied}, nil
}
func (r *Runtime) MokuConfigurationChange(host string) (ConfigurationChange, error) {
	settings, revision, err := r.Settings()
	if err != nil {
		return ConfigurationChange{}, err
	}
	result := ConfigurationChange{Settings: settings, SettingsRevision: revision, Pending: true, ResolveHost: true, ResolveHostSettings: true}
	var saved struct {
		Settings model.Settings `json:"settings"`
	}
	ok, err := r.config.Store.Snapshot().Get("moku-applied-settings", &saved)
	if err != nil {
		return result, err
	}
	if !ok {
		return result, nil
	}
	result.Applied = &saved.Settings
	result.Pending = !sameMokuConfiguration(saved.Settings, settings)
	result.ResolveHost = saved.Settings.Moku.HostHarnessPreference != settings.Moku.HostHarnessPreference || settings.Moku.HostHarnessPreference == "auto" || !same(saved.Settings.Moku.ExecutionHarnesses[host], settings.Moku.ExecutionHarnesses[host])
	result.ResolveHostSettings = !same(saved.Settings.Moku.ExecutionHarnesses[host], settings.Moku.ExecutionHarnesses[host])
	return result, nil
}
func (r *Runtime) PrepareSettings(ctx context.Context, currentHost string) (model.Settings, int64, error) {
	return r.prepareExecutionSettings(ctx, "", "", false)
}
func (r *Runtime) EnsureExecutionSettings(ctx context.Context, harnessID, applicationSettings string) (model.Settings, error) {
	settings, _, err := r.prepareExecutionSettings(ctx, applicationSettings, harnessID, true)
	return settings, err
}
func (r *Runtime) prepareExecutionSettings(ctx context.Context, owner, requested string, initializeOnly bool) (model.Settings, int64, error) {
	settings, revision, err := r.Settings()
	if err != nil {
		return settings, revision, err
	}
	// Presentation and startup recovery do not admit native work. Their catalog
	// discovery must not hold the write gate while an unrelated prompt is saved.
	// A real execution admission already owns this gate through its context.
	captured, err := r.captureExecutionProfiles(ctx, settings, owner, requested, initializeOnly)
	if err != nil {
		return settings, revision, err
	}
	unlock, err := r.configurationLock(ctx)
	if err != nil {
		return settings, revision, err
	}
	defer unlock()
	current, revision, err := r.Settings()
	if err != nil {
		return settings, revision, err
	}
	captured, err = mergeCapturedSettings(settings, captured, current, owner, initializeOnly)
	if err != nil {
		return current, revision, err
	}
	if err := r.persistCapturedSettings(ctx, revision, captured); err != nil {
		return current, revision, err
	}
	return r.Settings()
}

// Discovery only owns changed execution fields. In particular, an initialized
// read has nothing to commit, and concurrent initializers reuse the first saved
// profile rather than treating its publication as an obsolete native source.
func mergeCapturedSettings(base, captured, current model.Settings, owner string, initializeOnly bool) (model.Settings, error) {
	conflict := model.NewError("REVISION_CONFLICT", "execution settings changed during native snapshot")
	var before, after backgroundSettings
	var schemaVersion int
	if owner != "" {
		for i, entry := range base.PluginSettings {
			if entry.ID == owner {
				if err := json.Unmarshal(entry.Value, &before); err != nil {
					return current, err
				}
				if err := json.Unmarshal(captured.PluginSettings[i].Value, &after); err != nil {
					return current, err
				}
				schemaVersion = entry.SchemaVersion
				break
			}
		}
	}
	if owner == "" || before.Mode == "inherit" {
		if base.Moku.HostHarnessPreference == captured.Moku.HostHarnessPreference &&
			sameExecutionProfiles(base.Moku.ExecutionHarnesses, captured.Moku.ExecutionHarnesses) {
			return current, nil
		}
		if owner != "" {
			found := false
			for _, entry := range current.PluginSettings {
				if entry.ID == owner {
					var latest backgroundSettings
					if err := json.Unmarshal(entry.Value, &latest); err != nil {
						return current, err
					}
					found = entry.SchemaVersion == schemaVersion && latest.Mode == before.Mode
					break
				}
			}
			if !found {
				return current, conflict
			}
		}
		profiles, preference, err := mergeCapturedProfiles(
			base.Moku.ExecutionHarnesses, captured.Moku.ExecutionHarnesses, current.Moku.ExecutionHarnesses,
			base.Moku.HostHarnessPreference, captured.Moku.HostHarnessPreference, current.Moku.HostHarnessPreference,
			base.Harnesses, current.Harnesses, initializeOnly)
		if err != nil {
			return current, err
		}
		current.Moku.ExecutionHarnesses, current.Moku.HostHarnessPreference = profiles, preference
		return current, nil
	}
	if before.HarnessPreference == after.HarnessPreference && sameExecutionProfiles(before.Harnesses, after.Harnesses) {
		return current, nil
	}
	for i, entry := range current.PluginSettings {
		if entry.ID != owner {
			continue
		}
		var latest backgroundSettings
		if err := json.Unmarshal(entry.Value, &latest); err != nil {
			return current, err
		}
		if entry.SchemaVersion != schemaVersion || before.Mode != latest.Mode {
			return current, conflict
		}
		profiles, preference, err := mergeCapturedProfiles(before.Harnesses, after.Harnesses, latest.Harnesses,
			before.HarnessPreference, after.HarnessPreference, latest.HarnessPreference,
			mergeProfiles(base.Harnesses, base.Moku.ExecutionHarnesses),
			mergeProfiles(current.Harnesses, current.Moku.ExecutionHarnesses), initializeOnly)
		if err != nil {
			return current, err
		}
		// A read with no captured change must preserve the plugin's JSON.
		// Reordering its keys would consume a CAS revision and race the editor.
		if latest.HarnessPreference == preference && sameExecutionProfiles(latest.Harnesses, profiles) {
			return current, nil
		}
		latest.HarnessPreference = preference
		latest.Harnesses = profiles
		value, err := json.Marshal(latest)
		if err != nil {
			return current, err
		}
		current.PluginSettings[i].Value = value
		return current, nil
	}
	return current, conflict
}

func mergeCapturedProfiles(base, captured, current map[string]json.RawMessage,
	beforePreference, capturedPreference, preference string,
	beforeDefaults, defaults map[string]json.RawMessage, initializeOnly bool) (map[string]json.RawMessage, string, error) {
	conflict := model.NewError("REVISION_CONFLICT", "execution settings changed during native snapshot")
	profiles := mergeProfiles(current)
	for id, profile := range captured {
		if sameExecutionProfile(base[id], profile) {
			continue
		}
		if _, exists := current[id]; initializeOnly && exists {
			continue
		}
		if sameExecutionProfile(current[id], profile) {
			continue
		}
		if !sameExecutionProfile(base[id], current[id]) {
			return nil, "", conflict
		}
		// A pinned profile is its own native source. Only a missing profile
		// depends on this Harness's defaults, never on other Harness entries.
		if _, exists := base[id]; !exists && !sameExecutionProfile(beforeDefaults[id], defaults[id]) {
			return nil, "", conflict
		}
		profiles[id] = model.CloneRaw(profile)
	}
	if beforePreference != capturedPreference {
		if preference == beforePreference {
			preference = capturedPreference
		} else if preference != capturedPreference && !(initializeOnly && beforePreference == "auto") {
			return nil, "", conflict
		}
	}
	return profiles, preference, nil
}

func sameExecutionProfile(left, right json.RawMessage) bool {
	if len(left) == 0 || len(right) == 0 {
		return len(left) == len(right)
	}
	before, beforeErr := model.Decode(left)
	after, afterErr := model.Decode(right)
	return beforeErr == nil && afterErr == nil && same(before, after)
}

func sameExecutionProfiles(left, right map[string]json.RawMessage) bool {
	if len(left) != len(right) {
		return false
	}
	for id, profile := range left {
		// Public saves canonicalize object-key order, while native defaults may
		// retain their original JSON encoding. Compare the settings, not bytes.
		if !sameExecutionProfile(profile, right[id]) {
			return false
		}
	}
	return true
}

func (r *Runtime) persistCapturedSettings(ctx context.Context, expected int64, settings model.Settings) error {
	_, err := r.config.Store.Update(ctx, func(tx *store.Tx) error {
		var current model.Settings
		var revision int64
		if _, err := tx.Get("settings", &current); err != nil {
			return err
		}
		if _, err := tx.Get("settings-revision", &revision); err != nil {
			return err
		}
		if revision != expected {
			return errors.New("settings changed during native snapshot")
		}
		if same(current, settings) {
			return nil
		}
		revision++
		if err := tx.Put("settings", settings); err != nil {
			return err
		}
		if err := tx.Put("settings-revision", revision); err != nil {
			return err
		}
		return r.appendEvent(tx, "settings.changed", store.Subject{Kind: "settings", ID: "mokusei", TypeID: "settings"}, "application", map[string]any{"settingsRevision": revision}, nil)
	})
	return err
}
func (r *Runtime) captureExecutionProfiles(ctx context.Context, settings model.Settings, owner, requested string, initializeOnly bool) (model.Settings, error) {
	if err := ctx.Err(); err != nil {
		return settings, err
	}
	settings.PluginSettings = append([]model.PluginSettings{}, settings.PluginSettings...)
	var background *backgroundSettings
	entryIndex := -1
	if owner != "" {
		for i, entry := range settings.PluginSettings {
			if entry.ID == owner {
				var value backgroundSettings
				if err := model.Unmarshal(entry.Value, &value); err != nil {
					return settings, err
				}
				if value.Mode != "inherit" && value.Mode != "override" {
					return settings, errors.New("application setting is not an execution binding")
				}
				background = &value
				entryIndex = i
				break
			}
		}
		if background == nil {
			return settings, errors.New("unknown application execution settings")
		}
		if background.Mode == "inherit" {
			return r.captureExecutionProfiles(ctx, settings, "", requested, initializeOnly)
		}
	}
	profiles := settings.Moku.ExecutionHarnesses
	preference := settings.Moku.HostHarnessPreference
	if background != nil {
		profiles = background.Harnesses
		preference = background.HarnessPreference
	}
	source := mergeProfiles(settings.Harnesses, settings.Moku.ExecutionHarnesses, profiles)
	cwd, cwdErr := r.configurationCwd(owner)
	if cwdErr != nil {
		return settings, cwdErr
	}
	if err := os.MkdirAll(cwd, 0700); err != nil {
		return settings, err
	}
	harnessID := requested
	if harnessID == "" {
		if preference == "auto" {
			current := ""
			if threads, e := r.Threads(); e == nil {
				for _, thread := range threads {
					if thread.Moku {
						current = thread.HarnessID
						break
					}
				}
			}
			selectedPreference := preference
			if current != "" && r.config.DisabledHarnesses[current] == "" {
				if h := r.config.Harnesses[current]; h != nil && h.Descriptor().ThreadCapabilities.CanHostMoku() {
					if probe, ok := h.(plugin.AvailabilityProbe); ok {
						available, e := probe.Probe(ctx, plugin.SettingsRequest{Settings: source[current], Cwd: cwd}, "exclusive")
						if e == nil && available.Available {
							selectedPreference = current
						} else if e == nil && available.RequiresExplicitSelection {
							return settings, fmt.Errorf("current Moku host requires explicit compatible selection: %s", available.Reason)
						}
					}
				}
			}
			id, err := r.ResolveHost(ctx, selectedPreference, source, cwd)
			if err != nil {
				return settings, err
			}
			harnessID = id
		} else {
			harnessID = preference
		}
	}
	h := r.config.Harnesses[harnessID]
	if h == nil || !h.Descriptor().ThreadCapabilities.CanHostMoku() {
		return settings, fmt.Errorf("harness cannot host internal execution: %s", harnessID)
	}
	if reason := r.config.DisabledHarnesses[harnessID]; reason != "" {
		return settings, fmt.Errorf("harness disabled: %s", reason)
	}
	existing, exists := profiles[harnessID]
	captured := existing
	if !(initializeOnly && exists) {
		settingsSource := source[harnessID]
		if len(settingsSource) == 0 {
			settingsSource = h.DefaultSettings()
		}
		value, err := h.Settings().SnapshotExecution(ctx, plugin.SettingsRequest{Settings: settingsSource, Cwd: cwd}, !exists)
		if err != nil {
			return settings, err
		}
		captured = value
	}
	if !json.Valid(captured) {
		return settings, errors.New("execution snapshot is not JSON")
	}
	nextProfiles := mergeProfiles(profiles, map[string]json.RawMessage{harnessID: captured})
	if preference == "auto" {
		preference = harnessID
	}
	if background == nil {
		settings.Moku.ExecutionHarnesses = nextProfiles
		settings.Moku.HostHarnessPreference = preference
	} else {
		background.Harnesses = nextProfiles
		background.HarnessPreference = preference
		value, err := json.Marshal(background)
		if err != nil {
			return settings, err
		}
		settings.PluginSettings[entryIndex].Value = value
	}
	return settings, nil
}
func (r *Runtime) configurationCwd(owner string) (string, error) {
	if owner == "" {
		if r.config.Workspaces != nil && r.config.Workspaces.Paths().MokuCwd != "" {
			return r.config.Workspaces.Paths().MokuCwd, nil
		}
		return filepath.Join(r.config.DefaultCwd, "moku-workspace"), nil
	}
	if applications, ok := r.config.Applications.(interface {
		BackgroundSettingsWorkspace(string) (string, string, bool)
	}); ok {
		if pluginID, templateID, found := applications.BackgroundSettingsWorkspace(owner); found {
			return filepath.Join(r.config.DefaultCwd, "plugins", pluginID, templateID), nil
		}
	}
	return "", errors.New("unknown background execution settings binding")
}
func mergeProfiles(all ...map[string]json.RawMessage) map[string]json.RawMessage {
	result := map[string]json.RawMessage{}
	for _, profiles := range all {
		for id, value := range profiles {
			result[id] = model.CloneRaw(value)
		}
	}
	return result
}
func retainExecutionProfiles(settings, previous model.Settings) (model.Settings, error) {
	settings.Moku.ExecutionHarnesses = mergeProfiles(previous.Moku.ExecutionHarnesses, settings.Moku.ExecutionHarnesses)
	old := map[string]backgroundSettings{}
	for _, entry := range previous.PluginSettings {
		var value backgroundSettings
		if json.Unmarshal(entry.Value, &value) == nil && (value.Mode == "inherit" || value.Mode == "override") {
			old[entry.ID] = value
		}
	}
	for i, entry := range settings.PluginSettings {
		var value backgroundSettings
		if json.Unmarshal(entry.Value, &value) != nil || (value.Mode != "inherit" && value.Mode != "override") {
			continue
		}
		before, ok := old[entry.ID]
		if !ok {
			continue
		}
		var profiles *executionProfiles
		if before.Mode == "override" {
			profiles = &executionProfiles{HarnessPreference: before.HarnessPreference, Harnesses: before.Harnesses}
		} else {
			profiles = before.Independent
		}
		if profiles == nil {
			continue
		}
		if value.Mode == "override" {
			value.Harnesses = mergeProfiles(profiles.Harnesses, value.Harnesses)
		} else {
			if value.Independent == nil {
				value.Independent = &executionProfiles{HarnessPreference: profiles.HarnessPreference, Harnesses: profiles.Harnesses}
			} else {
				value.Independent.Harnesses = mergeProfiles(profiles.Harnesses, value.Independent.Harnesses)
			}
		}
		raw, err := json.Marshal(value)
		if err != nil {
			return settings, err
		}
		settings.PluginSettings[i].Value = raw
	}
	return settings, nil
}
func (r *Runtime) validateChangedProfiles(ctx context.Context, settings, previous model.Settings) (model.Settings, error) {
	var err error
	for id, value := range settings.Moku.ExecutionHarnesses {
		if !same(value, previous.Moku.ExecutionHarnesses[id]) {
			settings, err = r.captureExecutionProfiles(ctx, settings, "", id, false)
			if err != nil {
				return settings, err
			}
		}
	}
	if settings.Moku.HostHarnessPreference != previous.Moku.HostHarnessPreference {
		settings, err = r.captureExecutionProfiles(ctx, settings, "", "", false)
		if err != nil {
			return settings, err
		}
	}
	old := map[string]backgroundSettings{}
	for _, entry := range previous.PluginSettings {
		var value backgroundSettings
		if json.Unmarshal(entry.Value, &value) == nil {
			old[entry.ID] = value
		}
	}
	for _, entry := range settings.PluginSettings {
		var value backgroundSettings
		if json.Unmarshal(entry.Value, &value) != nil || value.Mode != "override" {
			continue
		}
		before := old[entry.ID]
		oldProfiles := before.Harnesses
		oldPreference := before.HarnessPreference
		if before.Mode != "override" && before.Independent != nil {
			oldProfiles = before.Independent.Harnesses
			oldPreference = before.Independent.HarnessPreference
		}
		for id, profile := range value.Harnesses {
			if !same(profile, oldProfiles[id]) {
				settings, err = r.captureExecutionProfiles(ctx, settings, entry.ID, id, false)
				if err != nil {
					return settings, err
				}
			}
		}
		if before.Mode != "override" || oldPreference != value.HarnessPreference {
			settings, err = r.captureExecutionProfiles(ctx, settings, entry.ID, "", false)
			if err != nil {
				return settings, err
			}
		}
	}
	return settings, nil
}
func sameMokuConfiguration(a, b model.Settings) bool {
	return same(a.Harnesses, b.Harnesses) && same(a.Moku.ExecutionHarnesses, b.Moku.ExecutionHarnesses) && a.Moku.HostHarnessPreference == b.Moku.HostHarnessPreference && same(a.Moku.TargetHarnessIDs, b.Moku.TargetHarnessIDs) && same(a.Moku.RoutingGuidance, b.Moku.RoutingGuidance)
}
