package opencode

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/hupao-creator/Mokusei/internal/platform/discovery"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

type Settings struct {
	Provider         string                `json:"provider,omitempty"`
	Model            string                `json:"model,omitempty"`
	Agent            string                `json:"agent,omitempty"`
	Variant          string                `json:"variant,omitempty"`
	PermissionMode   string                `json:"permissionMode,omitempty"`
	ExecutablePath   string                `json:"executablePath,omitempty"`
	ConfigurationCWD string                `json:"configurationCwd,omitempty"`
	Thinking         *model.ThinkingChoice `json:"thinking,omitempty"`
}

func (s Settings) NativeModel() *NativeModel {
	if s.Provider == "" || s.Model == "" {
		return nil
	}
	return &NativeModel{ProviderID: s.Provider, ID: s.Model, Variant: s.Variant}
}

type HarnessSettings struct {
	ThreadSettings           Settings `json:"threadSettings"`
	UseDefaultThreadSettings *bool    `json:"useDefaultThreadSettings,omitempty"`
}
type catalogCacheEntry struct {
	at    time.Time
	value *CatalogSnapshot
}
type settingsCatalogFlight struct {
	done        chan struct{}
	nativeDone  chan struct{}
	nativeValue *CatalogSnapshot
	refresh     bool
	cancel      context.CancelFunc
	readers     int
	value       *CatalogSnapshot
	err         error
}
type SettingsAPI struct {
	host       plugin.HostContext
	launch     func(context.Context, Settings, string) (*Runtime, error)
	mu         sync.Mutex
	generation uint64
	cache      map[string]catalogCacheEntry
	pending    map[string]*settingsCatalogFlight
	publishers map[string]*settingsCatalogFlight
	active     map[*settingsCatalogFlight]struct{}
	closed     bool
	cleanupErr error
	closeOnce  sync.Once
	closeErr   error
}

func NewSettings(host plugin.HostContext, launch func(context.Context, Settings, string) (*Runtime, error)) *SettingsAPI {
	if launch == nil {
		launch = func(ctx context.Context, settings Settings, cwd string) (*Runtime, error) {
			env, err := hostEnvironment(ctx, host)
			if err != nil {
				return nil, err
			}
			return NewRuntime(ctx, Options{CWD: cwd, ConfigurationCWD: settings.ConfigurationCWD, ExecutablePath: settings.ExecutablePath, Environment: env})
		}
	}
	return &SettingsAPI{host: host, launch: launch, cache: map[string]catalogCacheEntry{}, pending: map[string]*settingsCatalogFlight{}, publishers: map[string]*settingsCatalogFlight{}, active: map[*settingsCatalogFlight]struct{}{}}
}

// Close cancels and joins every probe owned by this settings source, including
// probes detached by refresh or by cancellation of their final reader.
func (s *SettingsAPI) Close() error {
	s.closeOnce.Do(func() {
		s.mu.Lock()
		s.closed = true
		s.generation++
		s.cache = map[string]catalogCacheEntry{}
		s.pending = map[string]*settingsCatalogFlight{}
		s.publishers = map[string]*settingsCatalogFlight{}
		flights := make([]*settingsCatalogFlight, 0, len(s.active))
		for flight := range s.active {
			flights = append(flights, flight)
			flight.cancel()
		}
		s.mu.Unlock()
		for _, flight := range flights {
			<-flight.done
		}
		s.mu.Lock()
		s.closeErr = s.cleanupErr
		s.mu.Unlock()
	})
	return s.closeErr
}

var _ plugin.HarnessSettings = (*SettingsAPI)(nil)
var profileSettingsKeys = []string{"provider", "model", "agent", "variant", "permissionMode"}
var internalSettingsKeys = []string{"executablePath", "configurationCwd", "provider", "model", "agent", "variant", "permissionMode", "thinking"}
var ordinarySettingsKeys = []string{"provider", "model", "agent", "thinking", "permissionMode"}

func decodeSettingsObject(raw json.RawMessage) (Object, error) {
	if len(raw) == 0 {
		return Object{}, nil
	}
	return model.DecodeObject(raw)
}
func settingsKeys(value Object, allowed []string) error {
	for key := range value {
		if !slices.Contains(allowed, key) {
			return fmt.Errorf("OpenCode settings contain unknown field: %s", key)
		}
	}
	return nil
}
func settingsIdentifier(value any, key string) (string, error) {
	text, ok := value.(string)
	limit := 256
	if key == "executablePath" || key == "configurationCwd" {
		limit = 4096
	}
	if !ok || text == "" || text != strings.TrimSpace(text) || strings.ContainsRune(text, 0) || len(text) > limit {
		return "", fmt.Errorf("OpenCode %s must be a nonempty canonical string", key)
	}
	return text, nil
}
func normalizeSettingsObject(value Object, allowed []string) (Settings, error) {
	var result Settings
	if err := settingsKeys(value, allowed); err != nil {
		return result, err
	}
	for key, target := range map[string]*string{"provider": &result.Provider, "model": &result.Model, "agent": &result.Agent, "variant": &result.Variant, "executablePath": &result.ExecutablePath, "configurationCwd": &result.ConfigurationCWD} {
		if raw, exists := value[key]; exists {
			var err error
			*target, err = settingsIdentifier(raw, key)
			if err != nil {
				return result, err
			}
		}
	}
	if raw, exists := value["thinking"]; exists {
		var err error
		result.Thinking, err = normalizeThinking(raw)
		if err != nil {
			return result, err
		}
	}
	if raw, exists := value["permissionMode"]; exists {
		mode, ok := raw.(string)
		if !ok || mode != "auto" && mode != "default" {
			return result, errors.New("OpenCode permissionMode must be one of: auto, default")
		}
		result.PermissionMode = mode
	}
	return result, nil
}
func NormalizeSettings(raw json.RawMessage) (Settings, error) {
	value, err := decodeSettingsObject(raw)
	if err != nil {
		return Settings{}, err
	}
	return normalizeSettingsObject(value, internalSettingsKeys)
}

func NormalizeThreadSettings(raw json.RawMessage) (Settings, error) { return NormalizeSettings(raw) }
func normalizeHarnessSettings(raw json.RawMessage) (HarnessSettings, error) {
	result := HarnessSettings{}
	value, err := decodeSettingsObject(raw)
	if err != nil {
		return result, err
	}
	if err = settingsKeys(value, []string{"threadSettings", "useDefaultThreadSettings"}); err != nil {
		return result, err
	}
	if raw, exists := value["useDefaultThreadSettings"]; exists {
		enabled, ok := raw.(bool)
		if !ok {
			return result, errors.New("OpenCode useDefaultThreadSettings must be a boolean")
		}
		result.UseDefaultThreadSettings = &enabled
	}
	thread := Object{}
	if raw, exists := value["threadSettings"]; exists {
		var ok bool
		thread, ok = configObject(raw)
		if !ok {
			return result, errors.New("OpenCode settings must be an object")
		}
	}
	result.ThreadSettings, err = normalizeSettingsObject(thread, profileSettingsKeys)
	if err != nil {
		return result, err
	}
	if result.UseDefaultThreadSettings == nil || *result.UseDefaultThreadSettings {
		return HarnessSettings{}, nil
	}
	return result, nil
}
func (s *SettingsAPI) Normalize(raw json.RawMessage) (json.RawMessage, error) {
	settings, err := normalizeHarnessSettings(raw)
	if err != nil {
		return nil, err
	}
	return json.Marshal(settings)
}
func (s *SettingsAPI) defaults(raw json.RawMessage) (Settings, error) {
	current, err := normalizeHarnessSettings(raw)
	if err != nil {
		return Settings{}, err
	}
	next := current.ThreadSettings
	if next.PermissionMode == "" {
		next.PermissionMode = "auto"
	}
	return next, nil
}
func (s *SettingsAPI) DefaultThread(raw json.RawMessage) (json.RawMessage, error) {
	value, err := s.defaults(raw)
	if err != nil {
		return nil, err
	}
	return json.Marshal(value)
}
func (s *SettingsAPI) Invalidate() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return
	}
	s.generation++
	s.cache = map[string]catalogCacheEntry{}
	s.pending = map[string]*settingsCatalogFlight{}
	s.publishers = map[string]*settingsCatalogFlight{}
}
func (s *SettingsAPI) catalogKey(ctx context.Context, settings Settings, cwd string) (string, error) {
	env, err := hostEnvironment(ctx, s.host)
	if err != nil {
		return "", err
	}
	config := env["XDG_CONFIG_HOME"]
	if config == "" {
		config = filepath.Join(env["HOME"], ".config")
	}
	data := env["XDG_DATA_HOME"]
	if data == "" {
		data = filepath.Join(env["HOME"], ".local", "share")
	}
	source := settings.ConfigurationCWD
	if source == "" {
		source = cwd
	}
	identity := discovery.Identity(env, settings.ExecutablePath, env["OPENCODE_CONFIG"],
		filepath.Join(config, "opencode", "opencode.json"), filepath.Join(config, "opencode", "opencode.jsonc"),
		filepath.Join(data, "opencode", "auth.json"), filepath.Join(source, "opencode.json"), filepath.Join(source, "opencode.jsonc"))
	return cwd + "\x00" + settings.ConfigurationCWD + "\x00" + settings.ExecutablePath + "\x00" + identity, nil
}

func (s *SettingsAPI) observe(ctx context.Context, settings Settings, cwd string, refresh bool, presentation ...bool) (*CatalogSnapshot, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	key, err := s.catalogKey(ctx, settings, cwd)
	if err != nil {
		return nil, err
	}
	early := len(presentation) > 0 && presentation[0]
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return nil, errors.New("OpenCode settings are closed")
	}
	if cached, ok := s.cache[key]; !refresh && ok && s.pending[key] == nil && time.Since(cached.at) < 5*time.Minute {
		s.mu.Unlock()
		return cached.value, nil
	}
	flight := s.pending[key]
	if refresh && (flight == nil || !flight.refresh) {
		flight = nil
		if cached, ok := s.cache[key]; ok {
			cached.at = time.Time{}
			s.cache[key] = cached
		}
	}
	if flight == nil {
		probe, cancel := context.WithTimeout(context.WithoutCancel(ctx), 55*time.Second)
		flight = &settingsCatalogFlight{done: make(chan struct{}), nativeDone: make(chan struct{}), cancel: cancel, refresh: refresh}
		s.pending[key] = flight
		s.publishers[key] = flight
		s.active[flight] = struct{}{}
		generation := s.generation
		go func(flight *settingsCatalogFlight) {
			defer cancel()
			deadline := time.AfterFunc(30*time.Second, cancel)
			defer deadline.Stop()
			runtime, err := s.launch(probe, settings, cwd)
			var cleanupErr error
			if err == nil {
				flight.value, err = readCatalog(probe, s.host, runtime, func(value *CatalogSnapshot) error {
					current, sourceErr := s.catalogKey(probe, settings, cwd)
					if sourceErr != nil {
						return sourceErr
					}
					if current != key {
						return errors.New("OpenCode native configuration changed during discovery")
					}
					deadline.Stop()
					s.mu.Lock()
					// The callback publishes an immutable native projection. Billing
					// filters a separate copy; presentation is never an auth verdict.
					flight.nativeValue = value
					close(flight.nativeDone)
					s.mu.Unlock()
					return nil
				}, runtime.Close)
				cleanupErr = runtime.Close()
				err = errors.Join(err, cleanupErr)
			}
			s.mu.Lock()
			flight.err = err
			delete(s.active, flight)
			s.cleanupErr = errors.Join(s.cleanupErr, cleanupErr)
			if s.pending[key] == flight {
				delete(s.pending, key)
			}
			if err == nil && probe.Err() == nil && !s.closed && generation == s.generation && s.publishers[key] == flight {
				s.cache[key] = catalogCacheEntry{at: time.Now(), value: flight.value}
			}
			if s.publishers[key] == flight {
				delete(s.publishers, key)
			}
			if flight.nativeValue == nil {
				close(flight.nativeDone)
			}
			close(flight.done)
			s.mu.Unlock()
		}(flight)
	}
	flight.readers++
	s.mu.Unlock()
	defer func() {
		s.mu.Lock()
		defer s.mu.Unlock()
		flight.readers--
		// Once native facts were published, optional billing belongs to this
		// settings source until its bounded completion or Close. Before that
		// point the last departing reader cancels native startup immediately.
		if flight.readers == 0 && flight.nativeValue == nil {
			select {
			case <-flight.done:
			default:
				flight.cancel()
				if s.pending[key] == flight {
					delete(s.pending, key)
				}
			}
		}
	}()
	done := flight.done
	if early {
		done = flight.nativeDone
	}
	select {
	case <-ctx.Done():
		return nil, ctx.Err()
	case <-done:
		if early {
			s.mu.Lock()
			value, err := flight.nativeValue, flight.err
			s.mu.Unlock()
			if ctx.Err() != nil {
				return nil, ctx.Err()
			}
			if value != nil {
				return value, nil
			}
			return nil, err
		}
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return flight.value, flight.err
	}
}

type ModelChoice struct {
	Model   CatalogModel
	Agent   *CatalogAgent
	Variant string
}

func SelectModel(observed *CatalogSnapshot, settings Settings) (ModelChoice, error) {
	result := ModelChoice{}
	agentID := settings.Agent
	if agentID == "" {
		agentID = observed.DefaultAgent
	}
	var agent *CatalogAgent
	for i := range observed.Agents {
		if observed.Agents[i].ID == agentID {
			agent = &observed.Agents[i]
			break
		}
	}
	if agentID != "" && agent == nil {
		return result, plugin.CallerError(fmt.Errorf("OpenCode primary agent %s is unavailable", agentID))
	}
	provider, id := settings.Provider, settings.Model
	if agent != nil && agent.Model != nil {
		if provider == "" {
			provider = agent.Model.ProviderID
		}
		if id == "" {
			id = agent.Model.ID
		}
	}
	if observed.DefaultModel != nil {
		if provider == "" {
			provider = observed.DefaultModel.Provider
		}
		if id == "" {
			id = observed.DefaultModel.Model
		}
	}
	if reason := observed.ExcludedModels[ModelKey(provider, id)]; provider != "" && id != "" && reason != "" {
		return result, plugin.CallerError(errors.New(reason))
	}
	matches := []CatalogModel{}
	for _, entry := range observed.Models {
		if (provider == "" || entry.Provider == provider) && (id == "" || entry.ID == id) {
			matches = append(matches, entry)
		}
	}
	if len(matches) != 1 {
		return result, plugin.CallerError(errors.New("OpenCode provider/model is unavailable or ambiguous. Connect an account in OpenCode and select an exact enabled model."))
	}
	selected := matches[0]
	if selected.UnavailableReason != "" {
		return result, plugin.CallerError(errors.New(selected.UnavailableReason))
	}
	variant := settings.Variant
	if variant == "" {
		if agent != nil && agent.Model != nil && agent.Model.ProviderID == selected.Provider && agent.Model.ID == selected.ID {
			variant = agent.Model.Variant
		} else if observed.DefaultModel != nil && observed.DefaultModel.Provider == selected.Provider && observed.DefaultModel.Model == selected.ID {
			variant = observed.DefaultModel.Variant
		}
	}
	return ModelChoice{Model: selected, Agent: agent, Variant: variant}, nil
}
func (s *SettingsAPI) resolve(ctx context.Context, next Settings, cwd string) (Settings, error) {
	observed, err := s.observe(ctx, next, cwd, false)
	if err != nil {
		return next, err
	}
	selected, err := SelectModel(observed, next)
	if err != nil {
		return next, err
	}
	result := Settings{ExecutablePath: observed.ExecutablePath, ConfigurationCWD: cwd, Provider: selected.Model.Provider, Model: selected.Model.ID, PermissionMode: next.PermissionMode}
	if result.PermissionMode == "" {
		result.PermissionMode = "auto"
	}
	if selected.Agent != nil {
		result.Agent = selected.Agent.ID
	}
	if next.Thinking != nil {
		if err = assertThinkingChoice(*next.Thinking, AgentThinkingCapability(selected.Model, selected.Agent)); err != nil {
			return result, err
		}
		variant, err := ThinkingVariant(*next.Thinking, selected.Model)
		if err != nil {
			return result, err
		}
		result.Thinking = next.Thinking
		result.Variant = variant
	} else if selected.Variant != "" {
		if selected.Variant != "default" && !hasCatalogVariant(selected.Model, selected.Variant) {
			return result, fmt.Errorf("OpenCode model %s/%s does not support variant %s", result.Provider, result.Model, selected.Variant)
		}
		result.Variant = selected.Variant
	}
	return result, nil
}
func hasCatalogVariant(value CatalogModel, id string) bool {
	for _, variant := range value.Variants {
		if variant.ID == id {
			return true
		}
	}
	return false
}
func normalizeCreateSettings(value Object, allowed []string) (Settings, error) {
	result, err := normalizeSettingsObject(value, allowed)
	if err != nil {
		return result, err
	}
	if result.Provider == "" || strings.EqualFold(result.Provider, "default") || result.Model == "" || strings.EqualFold(result.Model, "default") {
		return result, errors.New("OpenCode ordinary Threads require explicit provider and model identifiers")
	}
	if result.Thinking == nil {
		return result, errors.New("OpenCode ordinary Threads require an explicit thinking choice")
	}
	return result, nil
}
func AssertExplicitSettings(settings Settings) error {
	for key, value := range map[string]string{"provider": settings.Provider, "model": settings.Model} {
		if value == "" || strings.EqualFold(value, "default") || strings.TrimSpace(value) != value || strings.ContainsRune(value, 0) {
			return fmt.Errorf("OpenCode ordinary Threads require an explicit %s", key)
		}
	}
	if settings.Thinking == nil {
		return errors.New("OpenCode ordinary Threads require an explicit thinking choice")
	}
	raw, _ := json.Marshal(settings.Thinking)
	var value Object
	_ = json.Unmarshal(raw, &value)
	if _, err := normalizeThinking(value); err != nil {
		return err
	}
	if settings.Thinking.Mode != "fixed" && (settings.Variant == "" || settings.Variant == "default") {
		return errors.New("OpenCode ordinary Thread thinking must be resolved to an exact native variant")
	}
	return nil
}
func (s *SettingsAPI) HasThreadContent(raw json.RawMessage) bool {
	value, err := model.DecodeObject(raw)
	if err != nil {
		return false
	}
	_, native := value["nativeSessionId"].(string)
	_, fork := configObject(value["forkSource"])
	return native || fork || len(configArray(value["messages"])) > 0 || len(configArray(value["executions"])) > 0
}
func assertSettingsExecutable(existing, next Settings) error {
	if existing.ExecutablePath != "" && existing.ExecutablePath != next.ExecutablePath {
		return errors.New("OpenCode executablePath cannot change after Thread history exists")
	}
	return nil
}
func (s *SettingsAPI) ResolveThread(ctx context.Context, input plugin.ResolveSettingsRequest) (json.RawMessage, error) {
	merged, err := NormalizeSettings(input.Merged)
	if err != nil {
		return nil, err
	}
	var existing Settings
	if !model.IsNull(input.Existing) {
		existing, err = NormalizeSettings(input.Existing)
		if err != nil {
			return nil, err
		}
	}
	hasContent := s.HasThreadContent(input.SessionState)
	path := merged.ExecutablePath
	if path == "" && hasContent {
		path = existing.ExecutablePath
	}
	next := merged
	if len(input.Requested) > 0 {
		value, err := model.DecodeObject(input.Requested)
		if err != nil {
			return nil, err
		}
		requested, err := normalizeCreateSettings(value, ordinarySettingsKeys)
		if err != nil {
			return nil, err
		}
		next = requested
		if next.Agent == "" {
			next.Agent = merged.Agent
		}
		if next.PermissionMode == "" {
			next.PermissionMode = merged.PermissionMode
		}
	}
	next.ExecutablePath = path
	if hasContent {
		if err = assertSettingsExecutable(existing, next); err != nil {
			return nil, err
		}
	}
	next, err = s.resolve(ctx, next, input.Cwd)
	if err != nil {
		return nil, err
	}
	if hasContent {
		if err = assertSettingsExecutable(existing, next); err != nil {
			return nil, err
		}
	}
	return json.Marshal(next)
}
func (s *SettingsAPI) ApplyThreadUpdate(ctx context.Context, input plugin.UpdateSettingsRequest) (json.RawMessage, error) {
	current, err := NormalizeSettings(input.Current)
	if err != nil {
		return nil, err
	}
	defaults, err := NormalizeSettings(input.Defaults)
	if err != nil {
		return nil, err
	}
	update, err := decodeSettingsObject(input.Update)
	if err != nil {
		return nil, err
	}
	if err = settingsKeys(update, ordinarySettingsKeys); err != nil {
		return nil, err
	}
	next := current
	changed := false
	for key, target := range map[string]*string{"provider": &next.Provider, "model": &next.Model, "agent": &next.Agent} {
		if raw, exists := update[key]; exists {
			value, err := settingsIdentifier(raw, key)
			if err != nil || strings.EqualFold(value, "default") {
				return nil, fmt.Errorf("OpenCode ordinary Thread %s cannot be cleared", key)
			}
			if (key == "provider" || key == "model") && *target != value {
				changed = true
			}
			*target = value
		}
	}
	if raw, exists := update["thinking"]; exists {
		next.Thinking, err = normalizeThinking(raw)
		if err != nil {
			return nil, err
		}
	} else if changed {
		return nil, errors.New("OpenCode model changes require a matching explicit thinking choice")
	}
	if raw, exists := update["permissionMode"]; exists {
		if raw == nil {
			next.PermissionMode = defaults.PermissionMode
			if next.PermissionMode == "" {
				next.PermissionMode = "auto"
			}
		} else {
			value, ok := raw.(string)
			if !ok || value != "auto" && value != "default" {
				return nil, errors.New("OpenCode permissionMode must be one of: auto, default")
			}
			next.PermissionMode = value
		}
	}
	if _, exists := update["thinking"]; exists || changed {
		next.Variant = ""
	}
	raw, _ := json.Marshal(next)
	value, _ := model.DecodeObject(raw)
	if _, err = normalizeCreateSettings(value, internalSettingsKeys); err != nil {
		return nil, err
	}
	if input.HasContent {
		if err = assertSettingsExecutable(current, next); err != nil {
			return nil, err
		}
	}
	next, err = s.resolve(ctx, next, input.Cwd)
	if err != nil {
		return nil, err
	}
	if input.HasContent {
		if err = assertSettingsExecutable(current, next); err != nil {
			return nil, err
		}
	}
	return json.Marshal(next)
}
func (s *SettingsAPI) PromptSettings(raw, source json.RawMessage) (json.RawMessage, error) {
	if !model.IsNull(source) {
		value, err := NormalizeSettings(source)
		if err != nil {
			return nil, err
		}
		return json.Marshal(value)
	}
	return s.DefaultThread(raw)
}
func (s *SettingsAPI) SnapshotExecution(ctx context.Context, input plugin.SettingsRequest, initial bool) (json.RawMessage, error) {
	current, err := normalizeHarnessSettings(input.Settings)
	if err != nil {
		return nil, err
	}
	settings := current.ThreadSettings
	if !initial && (current.UseDefaultThreadSettings == nil || *current.UseDefaultThreadSettings || settings.Provider == "" || settings.Model == "" || settings.Variant == "" || settings.Agent == "" || settings.PermissionMode == "") {
		return nil, errors.New("OpenCode execution settings require an explicit provider, model, variant, agent, and permission mode. Complete the settings before saving.")
	}
	next, err := s.defaults(input.Settings)
	if err != nil {
		return nil, err
	}
	observed, err := s.observe(ctx, next, input.Cwd, false, initial)
	if err != nil {
		return nil, err
	}
	agentID := next.Agent
	if agentID == "" {
		agentID = observed.DefaultAgent
	}
	if agentID == "" {
		return nil, errors.New("OpenCode did not report its actual default primary agent. Select an explicit agent in settings.")
	}
	var agent *CatalogAgent
	for i := range observed.Agents {
		if observed.Agents[i].ID == agentID {
			agent = &observed.Agents[i]
			break
		}
	}
	if agent == nil {
		return nil, fmt.Errorf("OpenCode primary agent %s is unavailable", agentID)
	}
	if agent.Model != nil {
		if next.Provider == "" {
			next.Provider = agent.Model.ProviderID
		}
		if next.Model == "" {
			next.Model = agent.Model.ID
		}
	}
	if observed.DefaultModel != nil {
		if next.Provider == "" {
			next.Provider = observed.DefaultModel.Provider
		}
		if next.Model == "" {
			next.Model = observed.DefaultModel.Model
		}
	}
	if next.Provider == "" || next.Model == "" {
		return nil, errors.New("OpenCode did not report its actual provider/model. Select an explicit provider and model in settings.")
	}
	next.Agent = agentID
	selected, err := SelectModel(observed, next)
	if err != nil {
		return nil, err
	}
	variant := selected.Variant
	if variant == "" {
		variant = "default"
	}
	if variant != "default" && !hasCatalogVariant(selected.Model, variant) {
		return nil, fmt.Errorf("OpenCode model %s/%s does not support variant %s", next.Provider, next.Model, variant)
	}
	disabled := false
	return json.Marshal(HarnessSettings{UseDefaultThreadSettings: &disabled, ThreadSettings: Settings{Provider: next.Provider, Model: next.Model, Variant: variant, Agent: agentID, PermissionMode: next.PermissionMode}})
}
func (s *SettingsAPI) Presentation(ctx context.Context, input plugin.SettingsPresentationRequest) (json.RawMessage, error) {
	var selected Settings
	var err error
	if !model.IsNull(input.ThreadSettings) {
		selected, err = NormalizeSettings(input.ThreadSettings)
	} else {
		selected, err = s.defaults(input.Settings)
	}
	if err != nil {
		return nil, err
	}
	observed, err := s.observe(ctx, selected, input.Cwd, input.Refresh, true)
	if err != nil {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return json.Marshal(Object{"cli": Object{"status": "unavailable", "message": err.Error()}, "models": []any{}, "agents": []any{}})
	}
	agentID := selected.Agent
	if agentID == "" {
		agentID = observed.DefaultAgent
	}
	provider, id := selected.Provider, selected.Model
	for _, agent := range observed.Agents {
		if agent.ID == agentID && agent.Model != nil {
			if provider == "" {
				provider = agent.Model.ProviderID
			}
			if id == "" {
				id = agent.Model.ID
			}
		}
	}
	if observed.DefaultModel != nil {
		if provider == "" {
			provider = observed.DefaultModel.Provider
		}
		if id == "" {
			id = observed.DefaultModel.Model
		}
	}
	restriction := observed.ExcludedModels[ModelKey(provider, id)]
	cli := Object{"status": "ready", "executablePath": observed.ExecutablePath, "version": observed.Version}
	if restriction != "" {
		cli["message"] = restriction
	}
	result := Object{"cli": cli, "models": observed.Models, "agents": observed.Agents, "accountCheckPending": observed.AccountCheckPending}
	if choice, err := SelectModel(observed, selected); err == nil {
		effective := Object{"provider": choice.Model.Provider, "model": choice.Model.ID}
		if choice.Variant != "" {
			effective["variant"] = choice.Variant
		}
		if reason := ExclusiveReason(choice.Model, choice.Variant, choice.Agent); reason != "" {
			effective["exclusiveUnavailableReason"] = reason
		}
		result["effectiveModel"] = effective
	}
	return json.Marshal(result)
}
func (s *SettingsAPI) Describe(ctx context.Context, input plugin.SettingsRequest) (json.RawMessage, error) {
	current, err := s.defaults(input.Settings)
	if err != nil {
		return nil, err
	}
	observed, err := s.observe(ctx, current, input.Cwd, false)
	if err != nil {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return json.Marshal(Object{"type": "object", "not": Object{}, "description": err.Error()})
	}
	return describeCatalog(current, observed)
}
func describeCatalog(current Settings, observed *CatalogSnapshot) (json.RawMessage, error) {
	permissions := Object{"type": "string", "enum": []string{"auto", "default"}, "default": current.PermissionMode, "description": "auto approves native permission requests once while preserving deny rules; default asks the user."}
	choices := []any{}
	defaultAgent := current.Agent
	if defaultAgent == "" {
		defaultAgent = observed.DefaultAgent
	}
	for _, entry := range observed.Models {
		if entry.Thinking == nil || entry.Thinking.Kind == "unknown" {
			continue
		}
		agents := []string{}
		for i := range observed.Agents {
			if AgentThinkingCapability(entry, &observed.Agents[i]).Kind != "unknown" {
				agents = append(agents, observed.Agents[i].ID)
			}
		}
		allowed := defaultAgent == "" || slices.Contains(agents, defaultAgent)
		if len(agents) == 0 && !allowed {
			continue
		}
		required := []string{"provider", "model", "thinking"}
		if !allowed {
			required = append(required, "agent")
		}
		properties := Object{"provider": Object{"type": "string", "const": entry.Provider}, "model": Object{"type": "string", "enum": []string{entry.ID}}, "thinking": thinkingSchema(*entry.Thinking), "permissionMode": permissions}
		if len(agents) > 0 {
			properties["agent"] = Object{"type": "string", "enum": agents}
		}
		choices = append(choices, Object{"type": "object", "additionalProperties": false, "required": required, "properties": properties})
	}
	result := Object{"type": "object", "description": "OpenCode ordinary Threads require an exact provider, model, and explicit supported thinking choice. Agent choices are native primary agents.", "additionalProperties": false, "required": []string{"provider", "model", "thinking"}, "properties": Object{"provider": Object{"type": "string", "minLength": 1}, "model": Object{"type": "string", "minLength": 1}, "thinking": Object{"type": "object"}, "agent": Object{"type": "string", "minLength": 1}, "permissionMode": permissions}}
	if len(choices) > 0 {
		result["oneOf"] = choices
	} else {
		result["not"] = Object{}
	}
	return json.Marshal(result)
}
func (s *SettingsAPI) Probe(ctx context.Context, input plugin.SettingsRequest, toolMode string) (plugin.Availability, error) {
	selected, err := s.defaults(input.Settings)
	if err == nil {
		var observed *CatalogSnapshot
		observed, err = s.observe(ctx, selected, input.Cwd, false)
		if err == nil {
			var choice ModelChoice
			choice, err = SelectModel(observed, selected)
			if err == nil {
				if toolMode == "exclusive" {
					if reason := ExclusiveReason(choice.Model, choice.Variant, choice.Agent); reason != "" {
						return plugin.Availability{Available: false, Reason: reason, RequiresExplicitSelection: true}, nil
					}
				}
				return plugin.Availability{Available: true}, nil
			}
		}
	}
	if ctx.Err() != nil {
		return plugin.Availability{}, ctx.Err()
	}
	return plugin.Availability{Available: false, Reason: err.Error()}, nil
}
func (s *SettingsAPI) ModelCatalog(ctx context.Context, input plugin.SettingsRequest) (json.RawMessage, error) {
	selected, err := s.defaults(input.Settings)
	if err != nil {
		return nil, err
	}
	observed, err := s.observe(ctx, selected, input.Cwd, false)
	if err != nil {
		return nil, err
	}
	return catalogProjection(observed)
}
func catalogProjection(observed *CatalogSnapshot) (json.RawMessage, error) {
	models := []Object{}
	for _, entry := range observed.Models {
		if entry.UnavailableReason != "" {
			continue
		}
		kind := "unknown"
		if observed.NativeAccounts[ModelKey(entry.Provider, entry.ID)] && !entry.HasRequestOverrides {
			kind = "native"
		}
		selector := entry.ModelID
		if selector == "" {
			selector = entry.ID
		}
		aliases := []string{entry.ID}
		if selector != entry.ID {
			aliases = append(aliases, selector)
		}
		provenance := Object{"kind": kind}
		models = append(models, Object{"selector": entry.Provider + "/" + entry.ID, "displayName": entry.Name, "aliases": aliases, "provenance": provenance})
	}
	return json.Marshal(Object{"models": models})
}
func (s *SettingsAPI) ValidateRuntimeSettings(ctx context.Context, runtime *Runtime, settings Settings, requireExplicit bool, actual *NativeModel, toolMode string) error {
	return ValidateRuntimeSettings(ctx, runtime, settings, requireExplicit, actual, toolMode)
}

// Live admission reads the already owned process and never trusts catalog cache.
func ValidateRuntimeSettings(ctx context.Context, runtime *Runtime, settings Settings, requireExplicit bool, actual *NativeModel, toolMode string) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if requireExplicit {
		if err := AssertExplicitSettings(settings); err != nil {
			return err
		}
	}
	selected := settings
	var err error
	if actual != nil {
		if selected.Provider != "" && actual.ProviderID != selected.Provider || selected.Model != "" && actual.ID != selected.Model || (selected.Thinking != nil || selected.Variant != "") && effectiveVariant(actual.Variant) != effectiveVariant(selected.Variant) {
			return errors.New("OpenCode changed the configured model or thinking variant before execution")
		}
		if selected.Provider == "" || selected.Model == "" {
			selected.Provider, selected.Model, selected.Variant = actual.ProviderID, actual.ID, actual.Variant
		}
	}
	if selected.Provider == "" || selected.Model == "" {

		return nil
	}
	var models []CatalogNativeModel
	var agents []CatalogNativeAgent
	if err = runtime.Request(ctx, "GET", "/api/model", nil, &models); err != nil {
		return err
	}
	if err = runtime.Request(ctx, "GET", "/api/agent", nil, &agents); err != nil {
		return err
	}
	var native *CatalogNativeModel
	for i := range models {
		if models[i].ProviderID == selected.Provider && models[i].ID == selected.Model {
			native = &models[i]
			break
		}
	}
	if native == nil || !native.Enabled || !native.Capabilities.Tools || !slices.Contains(native.Capabilities.Input, "text") {
		return errors.New("The configured OpenCode model is no longer available")
	}
	var nativeAgent *CatalogNativeAgent
	for i := range agents {
		if agents[i].ID == selected.Agent {
			nativeAgent = &agents[i]
			break
		}
	}
	if selected.Agent != "" && (nativeAgent == nil || nativeAgent.Hidden || nativeAgent.Mode == "subagent") {
		return errors.New("The configured OpenCode primary agent is no longer available")
	}
	safe := CatalogModelFromNative(*native)
	if selected.Variant != "" && (selected.Variant == "default" && selected.Thinking != nil || selected.Variant != "default" && !hasCatalogVariant(safe, selected.Variant)) {
		return errors.New("The configured OpenCode thinking variant is no longer available")
	}
	var providers []CatalogNativeProvider
	var provider *CatalogNativeProvider
	var credential *ProviderCredential
	loaded := false
	load := func() error {
		if loaded {
			return nil
		}
		if err := runtime.Request(ctx, "GET", "/api/provider", nil, &providers); err != nil {
			return err
		}
		for i := range providers {
			if providers[i].ID == native.ProviderID {
				provider = &providers[i]
				break
			}
		}
		var err error
		credential, err = runtime.ReadProviderCredential(ctx, native.ProviderID, native.ID, selected.Variant)
		if err != nil {
			return err
		}
		loaded = true
		return nil
	}
	if toolMode == "exclusive" {
		candidates := agents
		if nativeAgent != nil {
			candidates = []CatalogNativeAgent{*nativeAgent}
		}
		overrides := false
		for _, agent := range candidates {
			safeAgent := CatalogAgentFromNative(agent)
			if safeAgent.HasRequestOverrides || configTruthy(safeAgent.Body["model"]) {
				overrides = true
			}
		}
		if !overrides {
			if err = load(); err != nil {
				return err
			}
			base := ""
			if credential != nil {
				base = credential.BaseURL
			}
			if reason := NativeExclusiveReason(*native, provider, base, selected.Variant); reason != "" {
				return errors.New(reason)
			}
		}
	}
	if selected.Thinking == nil {
		return nil
	}
	capability := ThinkingCapability(safe)
	safe.Thinking = &capability
	var agent *CatalogAgent
	if nativeAgent != nil {
		value := CatalogAgentFromNative(*nativeAgent)
		agent = &value
	}
	if err = assertThinkingChoice(*selected.Thinking, AgentThinkingCapability(safe, agent)); err != nil {
		return err
	}
	if !VariantMatchesThinking(*selected.Thinking, safe, selected.Variant) {
		return errors.New("OpenCode changed the wire encoding of the configured thinking variant")
	}
	return nil
}
func effectiveVariant(value string) string {
	if value == "default" {
		return ""
	}
	return value
}

// cachedCatalog never waits for a running discovery. The owning Harness joins
// its background warm-up on Close, including cancellation during startup.
func (h *Harness) cachedCatalog(ctx context.Context, input plugin.SettingsRequest) (*CatalogSnapshot, Settings, error) {
	if err := ctx.Err(); err != nil {
		return nil, Settings{}, err
	}
	current, err := h.settings.defaults(input.Settings)
	if err != nil {
		return nil, current, err
	}
	key, err := h.settings.catalogKey(ctx, current, input.Cwd)
	if err != nil {
		return nil, current, err
	}
	h.settings.mu.Lock()
	cached, ok := h.settings.cache[key]
	closed := h.settings.closed
	h.settings.mu.Unlock()
	if closed {
		return nil, current, errors.New("OpenCode settings are closed")
	}
	if ok && time.Since(cached.at) < 5*time.Minute {
		return cached.value, current, nil
	}
	h.background("catalog:"+key, func(life context.Context) { _, _ = h.settings.observe(life, current, input.Cwd, false) })
	if ok {
		return cached.value, current, nil
	}
	return nil, current, nil
}
func (h *Harness) CachedModelCatalog(ctx context.Context, input plugin.SettingsRequest) (json.RawMessage, error) {
	cached, _, err := h.cachedCatalog(ctx, input)
	if err != nil {
		return nil, err
	}
	if cached == nil {
		return json.RawMessage(`{"models":[]}`), nil
	}
	return catalogProjection(cached)
}

// DiscoverMokuTarget always advertises stable on-demand native discovery. A
// background catalog becoming ready must not replace Moku's tool schema and
// force a second session preparation before its first message.
func (h *Harness) DiscoverMokuTarget(ctx context.Context, input plugin.SettingsRequest) (json.RawMessage, plugin.Availability, error) {
	current, err := h.settings.defaults(input.Settings)
	if err != nil {
		return nil, plugin.Availability{}, err
	}
	env, err := hostEnvironment(ctx, h.host)
	if err != nil {
		return nil, plugin.Availability{}, err
	}
	if h.host.ResolveExecutable != nil {
		_, err = h.host.ResolveExecutable(ctx, "opencode", input.Cwd, current.ExecutablePath)
	} else {
		_, err = ResolveExecutable(current.ExecutablePath, env)
	}
	if err != nil {
		if ctx.Err() != nil {
			return nil, plugin.Availability{}, ctx.Err()
		}
		return nil, plugin.Availability{Reason: err.Error()}, nil
	}
	if _, _, err := h.cachedCatalog(ctx, input); err != nil {
		return nil, plugin.Availability{}, err
	}
	return nil, plugin.Availability{Available: true}, nil
}
