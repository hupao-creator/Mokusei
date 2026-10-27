package pi

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/platform/discovery"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"time"
)

type ThreadSettings struct {
	ExecutablePath string                `json:"executablePath,omitempty"`
	Provider       string                `json:"provider,omitempty"`
	Model          string                `json:"model,omitempty"`
	ThinkingLevel  string                `json:"thinkingLevel,omitempty"`
	Thinking       *model.ThinkingChoice `json:"thinking,omitempty"`
}
type HarnessSettings struct {
	ThreadSettings           ThreadSettings `json:"threadSettings"`
	UseDefaultThreadSettings *bool          `json:"useDefaultThreadSettings,omitempty"`
}
type observation struct {
	Executable, Version string
	State               NativeState
	Models              []Model
	Levels              []string
	DiscoveryError      string
	Catalog             bool
	At                  time.Time
}
type settingsAPI struct {
	host          plugin.HostContext
	mu            sync.Mutex
	observations  map[string]observation
	generation    uint64
	sequence      uint64
	started       map[string]uint64
	pending       map[string]*observationFlight
	installations map[string]string
	active        map[*observationFlight]bool
	closed        bool
	cleanupErr    error
}

func newSettings(host plugin.HostContext) *settingsAPI {
	return &settingsAPI{host: host, observations: map[string]observation{}, started: map[string]uint64{}, pending: map[string]*observationFlight{}, installations: map[string]string{}, active: map[*observationFlight]bool{}}
}
func (s *settingsAPI) close() error {
	s.mu.Lock()
	s.closed = true
	active := make([]*observationFlight, 0, len(s.active))
	for flight := range s.active {
		flight.cancel()
		active = append(active, flight)
	}
	s.mu.Unlock()
	for _, flight := range active {
		<-flight.done
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.cleanupErr
}

func canonical(value, key string) error {
	limit := 256
	if key == "executablePath" {
		limit = 4096
	}
	if key == "thinkingLevel" {
		limit = 64
	}
	if value != "" && (strings.TrimSpace(value) != value || strings.ContainsRune(value, 0) || len(value) > limit) {
		return fmt.Errorf("Pi %s must be a canonical identifier", key)
	}
	return nil
}
func normalizeThread(raw json.RawMessage) (ThreadSettings, error) {
	var result ThreadSettings
	if model.IsNull(raw) {
		return result, nil
	}
	fields, err := model.DecodeObject(raw)
	if err != nil {
		return result, err
	}
	for key, value := range fields {
		if key == "thinking" {
			if value == nil {
				return result, errors.New("Pi thinking cannot be null")
			}
			continue
		}
		text, ok := value.(string)
		if !ok || text == "" {
			return result, fmt.Errorf("Pi %s must be nonempty string", key)
		}
	}
	if err := model.Unmarshal(raw, &result); err != nil {
		return result, err
	}
	for key, value := range map[string]string{"executablePath": result.ExecutablePath, "provider": result.Provider, "model": result.Model, "thinkingLevel": result.ThinkingLevel} {
		if err := canonical(value, key); err != nil {
			return result, err
		}
	}
	if result.Thinking != nil {
		switch result.Thinking.Mode {
		case "fixed", "off", "on":
			if result.Thinking.Effort != "" {
				return result, errors.New("Pi non-effort thinking cannot carry effort")
			}
		case "effort":
			if result.Thinking.Effort == "" {
				return result, errors.New("Pi thinking effort is required")
			}
		default:
			return result, errors.New("invalid Pi thinking choice")
		}
	}
	return result, nil
}
func normalizeHarness(raw json.RawMessage) (HarnessSettings, error) {
	result := HarnessSettings{ThreadSettings: ThreadSettings{}}
	if model.IsNull(raw) {
		return result, nil
	}
	if err := model.Unmarshal(raw, &result); err != nil {
		return result, err
	}
	fields, err := model.DecodeObject(raw)
	if err != nil {
		return result, err
	}
	if value, exists := fields["useDefaultThreadSettings"]; exists {
		if _, ok := value.(bool); !ok {
			return result, errors.New("Pi useDefaultThreadSettings must be boolean")
		}
	}
	if value, exists := fields["threadSettings"]; exists {
		object, ok := value.(map[string]any)
		if !ok {
			return result, errors.New("Pi threadSettings must be object")
		}
		for key := range object {
			if key != "provider" && key != "model" && key != "thinkingLevel" {
				return result, fmt.Errorf("unknown Pi Harness thread settings field: %s", key)
			}
		}
		data, _ := json.Marshal(object)
		if _, err := normalizeThread(data); err != nil {
			return result, err
		}
	}
	if result.ThreadSettings.ExecutablePath != "" || result.ThreadSettings.Thinking != nil {
		return result, errors.New("Pi Harness settings cannot pin executable or thinking choice")
	}
	if result.UseDefaultThreadSettings == nil || *result.UseDefaultThreadSettings {
		result = HarnessSettings{ThreadSettings: ThreadSettings{}}
	}
	data, _ := json.Marshal(result.ThreadSettings)
	_, err = normalizeThread(data)
	return result, err
}
func requireExplicit(settings ThreadSettings, resolved bool) error {
	if settings.Provider == "" || settings.Model == "" || strings.EqualFold(settings.Provider, "default") || strings.EqualFold(settings.Model, "default") || settings.Thinking == nil {
		return errors.New("Pi ordinary Threads require exact provider, model, and explicit thinking choice")
	}
	if resolved && settings.ThinkingLevel == "" {
		return errors.New("Pi thinking choice must be resolved before execution")
	}
	return nil
}
func normalizeCreate(raw json.RawMessage) (ThreadSettings, error) {
	values, err := model.DecodeObject(raw)
	if err != nil {
		return ThreadSettings{}, err
	}
	for key := range values {
		if key != "provider" && key != "model" && key != "thinking" {
			return ThreadSettings{}, fmt.Errorf("unknown Pi Thread create field: %s", key)
		}
	}
	result, err := normalizeThread(raw)
	if err == nil {
		err = requireExplicit(result, false)
	}
	return result, err
}
func modelArguments(settings ThreadSettings) []string {
	args := []string{}
	if settings.Provider != "" {
		args = append(args, "--provider", settings.Provider)
	}
	if settings.Model != "" {
		args = append(args, "--model", settings.Model)
	}
	if settings.ThinkingLevel != "" {
		args = append(args, "--thinking", settings.ThinkingLevel)
	}
	return args
}
func resolveExecutable(ctx context.Context, host plugin.HostContext, cwd, configured string) (string, error) {
	if host.ResolveExecutable != nil {
		return host.ResolveExecutable(ctx, "pi", cwd, configured)
	}
	if configured != "" {
		return exec.LookPath(configured)
	}
	return exec.LookPath("pi")
}
func (s *settingsAPI) invalidate() {
	s.mu.Lock()
	s.generation++
	s.observations = map[string]observation{}
	s.started = map[string]uint64{}
	s.pending = map[string]*observationFlight{}
	s.mu.Unlock()
	RetireVersions()
}

type observationFlight struct {
	done     chan struct{}
	value    observation
	err      error
	cancel   context.CancelFunc
	refs     int
	finished bool
	refresh  bool
	catalog  bool
}

func (s *settingsAPI) observe(ctx context.Context, settings ThreadSettings, cwd string, catalog, refresh bool) (observation, error) {
	if err := ctx.Err(); err != nil {
		return observation{}, err
	}
	env, err := inheritedEnvironment(ctx, s.host)
	if err != nil {
		return observation{}, err
	}
	executable, err := resolveExecutable(ctx, s.host, cwd, settings.ExecutablePath)
	if err != nil {
		return observation{}, err
	}
	home := env["PI_CODING_AGENT_DIR"]
	if home == "" {
		home = filepath.Join(env["HOME"], ".pi", "agent")
	}
	identity := discovery.Identity(env, executable, filepath.Join(home, "settings.json"), filepath.Join(home, "models.json"), filepath.Join(home, "auth.json"), filepath.Join(cwd, ".pi", "settings.json"))
	keyBytes, _ := json.Marshal([]any{settings, cwd, identity})
	key := string(keyBytes)
	flightKey := key
	s.mu.Lock()
	if s.closed || s.cleanupErr != nil {
		err := errors.Join(errors.New("Pi discovery is closed"), s.cleanupErr)
		s.mu.Unlock()
		return observation{}, err
	}
	cached, exists := s.observations[key]
	ttl := 15 * time.Second
	if reusableObservation(settings, cached) {
		ttl = 5 * time.Minute
	}
	if !refresh && s.pending[flightKey] == nil && exists && time.Since(cached.At) < ttl && (!catalog || cached.Catalog) {
		s.mu.Unlock()
		return cached, nil
	}
	flight := s.pending[flightKey]
	if refresh && (flight == nil || !flight.refresh) {
		flight = nil
		if exists {
			cached.At = time.Time{}
			s.observations[key] = cached
		}
	}
	if flight != nil {
		flight.refs++
		flight.catalog = flight.catalog || catalog
	} else {
		shared, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		flight = &observationFlight{done: make(chan struct{}), cancel: cancel, refs: 1, refresh: refresh, catalog: catalog}
		s.pending[flightKey] = flight
		s.active[flight] = true
		generation := s.generation
		s.sequence++
		sequence := s.sequence
		s.started[key] = sequence
		go func() {
			value, probeErr := s.readObservation(shared, settings, cwd, executable, env, func() bool {
				s.mu.Lock()
				defer s.mu.Unlock()
				return flight.catalog
			})
			s.mu.Lock()
			flight.value = value
			flight.err = probeErr
			flight.finished = true
			delete(s.active, flight)
			if probeErr == nil && shared.Err() == nil && !s.closed && s.generation == generation && s.started[key] == sequence && s.pending[flightKey] == flight &&
				(value.Catalog || !s.observations[key].Catalog) {
				s.observations[key] = value
			}
			if s.pending[flightKey] == flight {
				delete(s.pending, flightKey)
			}
			close(flight.done)
			s.mu.Unlock()
			cancel()
		}()
	}
	s.mu.Unlock()
	defer func() {
		s.mu.Lock()
		flight.refs--
		if flight.refs == 0 && !flight.finished {
			if s.pending[flightKey] == flight {
				delete(s.pending, flightKey)
			}
			flight.cancel()
		}
		s.mu.Unlock()
	}()
	select {
	case <-ctx.Done():
		return observation{}, ctx.Err()
	case <-flight.done:
		if err := ctx.Err(); err != nil {
			return observation{}, err
		}
		// A catalog reader arriving after a basic read's last native request
		// upgrades on the next flight; it never accepts a state-only result as
		// a catalog, and never overlaps a second native owner with this one.
		if catalog && !flight.value.Catalog && flight.err == nil && flight.value.DiscoveryError == "" {
			return s.observe(ctx, settings, cwd, true, false)
		}
		return flight.value, flight.err
	}
}
func reusableObservation(settings ThreadSettings, value observation) bool {
	if !value.Catalog || value.State.Model == nil || !slices.Contains(value.Levels, value.State.ThinkingLevel) {
		return false
	}
	m := value.State.Model
	if settings.Provider != "" && settings.Provider != m.Provider || settings.Model != "" && settings.Model != m.ID || settings.ThinkingLevel != "" && settings.ThinkingLevel != value.State.ThinkingLevel {
		return false
	}
	for _, catalog := range value.Models {
		if catalog.ID == m.ID && catalog.Provider == m.Provider {
			return true
		}
	}
	return false
}
func (s *settingsAPI) readObservation(ctx context.Context, settings ThreadSettings, cwd, executable string, env map[string]string, wantCatalog func() bool) (value observation, err error) {
	rpc, err := StartSession(ctx, ProcessOptions{ExecutablePath: executable, Cwd: cwd, Env: env, Args: append([]string{"--no-session", "--no-extensions", "--no-skills", "--no-prompt-templates"}, modelArguments(settings)...)})
	if err != nil {
		return observation{}, selectionFailure(settings, err)
	}
	defer func() {
		cleanupErr := rpc.Close()
		err = errors.Join(err, cleanupErr)
		if cleanupErr != nil {
			s.mu.Lock()
			s.cleanupErr = errors.Join(s.cleanupErr, cleanupErr)
			s.mu.Unlock()
		}
	}()
	native, err := rpc.State(ctx)
	if err != nil {
		return observation{}, selectionFailure(settings, err)
	}
	value = observation{Executable: executable, Version: rpc.Version, State: native, At: time.Now()}
	if wantCatalog() {
		var modelsErr, levelsErr error
		var reads sync.WaitGroup
		reads.Add(2)
		go func() { defer reads.Done(); value.Models, modelsErr = rpc.Models(ctx) }()
		go func() { defer reads.Done(); value.Levels, levelsErr = rpc.ThinkingLevels(ctx) }()
		reads.Wait()
		err = errors.Join(modelsErr, levelsErr)
		if err != nil {
			if ctx.Err() != nil {
				return observation{}, ctx.Err()
			}
			value.DiscoveryError = err.Error()
		} else {
			value.Catalog = true
		}
	}
	if err := ctx.Err(); err != nil {
		return observation{}, err
	}
	return value, nil
}

// selectionFailure names the requested provider/model. A native catalog miss
// otherwise reports only a process exit, which reads as a generic Harness
// failure instead of the actual rejected selection. Only a rejection the caller
// can correct keeps the caller-error mark; every other startup failure stays an
// internal Harness fault.
func selectionFailure(settings ThreadSettings, err error) error {
	if settings.Provider == "" && settings.Model == "" {
		return err
	}
	failure := fmt.Errorf("Pi could not start with provider %q model %q (a provider must come from the local Pi catalog): %w", settings.Provider, settings.Model, err)
	if !selectionRejected(err) {
		return failure
	}
	return plugin.CallerError(failure)
}

// selectionRejected recognizes the diagnostics Pi emits when it refuses a
// provider/model the caller selected. Other exit reasons are Harness faults.
func selectionRejected(err error) bool {
	text := strings.ToLower(err.Error())
	for _, marker := range []string{"unknown provider", "unknown model", "invalid provider", "invalid model", "unsupported model", "provider not found", "model not found", "not logged in"} {
		if strings.Contains(text, marker) {
			return true
		}
	}
	return false
}

// unavailableSelection is a rejected provider/model selection the caller can
// correct by choosing an exact available pair, so the native caller may retry.
func unavailableSelection(provider, selected string) error {
	return plugin.CallerError(fmt.Errorf("Pi provider/model %q/%q is unavailable or ambiguous; run pi /login and select an exact available model", provider, selected))
}

func (s *settingsAPI) resolve(ctx context.Context, next ThreadSettings, cwd string, refresh bool) (ThreadSettings, error) {
	observed, err := s.observe(ctx, next, cwd, true, refresh)
	if err != nil {
		return next, err
	}
	if !observed.Catalog {
		detail := observed.DiscoveryError
		if detail == "" {
			detail = "Pi returned no model catalog"
		}
		return next, fmt.Errorf("Pi model catalog unavailable for provider %q model %q: %s", next.Provider, next.Model, detail)
	}
	provider, selected := next.Provider, next.Model
	if observed.State.Model != nil {
		if provider == "" {
			provider = observed.State.Model.Provider
		}
		if selected == "" {
			selected = observed.State.Model.ID
		}
	}
	matches := []Model{}
	for _, m := range observed.Models {
		if (provider == "" || m.Provider == provider) && (selected == "" || m.ID == selected) {
			matches = append(matches, m)
		}
	}
	if len(matches) != 1 {
		return next, unavailableSelection(provider, selected)
	}
	m := matches[0]
	if observed.State.Model == nil || observed.State.Model.ID != m.ID || observed.State.Model.Provider != m.Provider {
		return next, errors.New("Pi did not select the requested exact provider/model pair")
	}
	next.ExecutablePath = observed.Executable
	next.Provider = m.Provider
	next.Model = m.ID
	if next.Thinking != nil {
		level, err := ThinkingLevel(*next.Thinking, m, observed.Levels)
		if err != nil {
			return next, err
		}
		next.ThinkingLevel = level
		if observed.State.ThinkingLevel != level {
			applied, err := s.observe(ctx, next, cwd, false, false)
			if err != nil {
				return next, err
			}
			if applied.State.Model == nil || applied.State.Model.ID != m.ID || applied.State.Model.Provider != m.Provider || applied.State.ThinkingLevel != level {
				return next, errors.New("Pi did not apply explicit provider/model/thinking choice")
			}
		}
	} else {
		if next.ThinkingLevel == "" {
			next.ThinkingLevel = observed.State.ThinkingLevel
		}
		if next.ThinkingLevel == "" || !slices.Contains(observed.Levels, next.ThinkingLevel) || observed.State.ThinkingLevel != next.ThinkingLevel {
			return next, errors.New("Pi did not apply a supported thinking level")
		}
	}
	return next, nil
}
func assertRuntimeSettings(ctx context.Context, rpc *Session, settings ThreadSettings, explicitRequired bool) error {
	if explicitRequired {
		if err := requireExplicit(settings, true); err != nil {
			return err
		}
	}
	resolved := settings
	if resolved.Provider == "" || resolved.Model == "" || resolved.ThinkingLevel == "" {
		return errors.New("Pi execution requires saved provider, model, and thinking level")
	}
	state, err := rpc.State(ctx)
	if err != nil {
		return err
	}
	if state.Model == nil || state.Model.Provider != resolved.Provider || state.Model.ID != resolved.Model {
		return errors.New("Pi did not select configured provider/model")
	}
	levels, err := rpc.ThinkingLevels(ctx)
	if err != nil {
		return err
	}
	if !slices.Contains(levels, resolved.ThinkingLevel) || state.ThinkingLevel != resolved.ThinkingLevel {
		return errors.New("Pi did not apply configured thinking level")
	}
	if resolved.Thinking != nil {
		level, err := ThinkingLevel(*resolved.Thinking, *state.Model, levels)
		if err != nil {
			return err
		}
		if level != state.ThinkingLevel {
			return errors.New("Pi runtime thinking differs from explicit choice")
		}
	}
	return nil
}

func (s *settingsAPI) Normalize(raw json.RawMessage) (json.RawMessage, error) {
	settings, err := normalizeHarness(raw)
	if err != nil {
		return nil, err
	}
	return json.Marshal(settings)
}
func (s *settingsAPI) DefaultThread(raw json.RawMessage) (json.RawMessage, error) {
	settings, err := normalizeHarness(raw)
	if err != nil {
		return nil, err
	}
	return json.Marshal(settings.ThreadSettings)
}
func (s *settingsAPI) SnapshotExecution(ctx context.Context, input plugin.SettingsRequest, initial bool) (json.RawMessage, error) {
	settings, err := normalizeHarness(input.Settings)
	if err != nil {
		return nil, err
	}
	if !initial && (settings.UseDefaultThreadSettings == nil || *settings.UseDefaultThreadSettings || settings.ThreadSettings.Provider == "" || settings.ThreadSettings.Model == "" || settings.ThreadSettings.ThinkingLevel == "") {
		return nil, errors.New("Pi execution settings require explicit provider/model/thinking level")
	}
	resolved, err := s.resolve(ctx, settings.ThreadSettings, input.Cwd, initial)
	if err != nil {
		return nil, err
	}
	flag := false
	return json.Marshal(HarnessSettings{ThreadSettings: ThreadSettings{Provider: resolved.Provider, Model: resolved.Model, ThinkingLevel: resolved.ThinkingLevel}, UseDefaultThreadSettings: &flag})
}
func (s *settingsAPI) HasThreadContent(raw json.RawMessage) bool {
	state, err := decodeState(raw)
	return err == nil && (state.SessionFile != "" || state.NativeSessionJSONL != "" || state.ForkSource != nil || len(state.Messages) > 0 || len(state.Executions) > 0)
}
func (s *settingsAPI) ResolveThread(ctx context.Context, input plugin.ResolveSettingsRequest) (json.RawMessage, error) {
	next, err := normalizeThread(input.Merged)
	if err != nil {
		return nil, err
	}
	existing, err := normalizeThread(input.Existing)
	if err != nil {
		return nil, err
	}
	hasContent := s.HasThreadContent(input.SessionState)
	if next.ExecutablePath == "" && hasContent {
		next.ExecutablePath = existing.ExecutablePath
	}
	if !model.IsNull(input.Requested) {
		request, err := normalizeCreate(input.Requested)
		if err != nil {
			return nil, err
		}
		request.ExecutablePath = next.ExecutablePath
		next = request
	}
	if hasContent && existing.ExecutablePath != "" && next.ExecutablePath != existing.ExecutablePath {
		return nil, errors.New("Pi executable cannot change after history exists")
	}
	next, err = s.resolve(ctx, next, input.Cwd, false)
	if err != nil {
		return nil, err
	}
	if hasContent && existing.ExecutablePath != "" && next.ExecutablePath != existing.ExecutablePath {
		return nil, errors.New("Pi executable cannot change after history exists")
	}
	return json.Marshal(next)
}
func (s *settingsAPI) ApplyThreadUpdate(ctx context.Context, input plugin.UpdateSettingsRequest) (json.RawMessage, error) {
	current, err := normalizeThread(input.Current)
	if err != nil {
		return nil, err
	}
	update, err := model.DecodeObject(input.Update)
	if err != nil {
		return nil, err
	}
	for key := range update {
		if key != "provider" && key != "model" && key != "thinking" {
			return nil, fmt.Errorf("unknown Pi update field: %s", key)
		}
	}
	next := current
	changed := false
	for key, value := range update {
		if key == "thinking" {
			data, _ := json.Marshal(value)
			var choice model.ThinkingChoice
			if err := model.Unmarshal(data, &choice); err != nil {
				return nil, err
			}
			next.Thinking = &choice
			continue
		}
		text, ok := value.(string)
		if !ok || text == "" || strings.EqualFold(text, "default") {
			return nil, errors.New("Pi provider/model cannot be cleared")
		}
		if key == "provider" {
			changed = changed || text != current.Provider
			next.Provider = text
		} else {
			changed = changed || text != current.Model
			next.Model = text
		}
	}
	if changed {
		if _, ok := update["thinking"]; !ok {
			return nil, errors.New("Pi model changes require matching explicit thinking choice")
		}
	}
	if len(update) > 0 {
		next.ThinkingLevel = ""
	}
	data, _ := json.Marshal(next)
	next, err = normalizeThread(data)
	if err != nil {
		return nil, err
	}
	if err = requireExplicit(next, false); err != nil {
		return nil, err
	}
	next, err = s.resolve(ctx, next, input.Cwd, false)
	if err != nil {
		return nil, err
	}
	if input.HasContent && current.ExecutablePath != "" && next.ExecutablePath != current.ExecutablePath {
		return nil, errors.New("Pi executable cannot change after history exists")
	}
	return json.Marshal(next)
}
func (s *settingsAPI) PromptSettings(raw, source json.RawMessage) (json.RawMessage, error) {
	if model.IsNull(source) {
		return s.DefaultThread(raw)
	}
	settings, err := normalizeThread(source)
	if err != nil {
		return nil, err
	}
	return json.Marshal(settings)
}
func (s *settingsAPI) Presentation(ctx context.Context, input plugin.SettingsPresentationRequest) (json.RawMessage, error) {
	raw := input.ThreadSettings
	if model.IsNull(raw) {
		var err error
		raw, err = s.DefaultThread(input.Settings)
		if err != nil {
			return nil, err
		}
	}
	selected, err := normalizeThread(raw)
	if err != nil {
		return nil, err
	}
	observed, err := s.observe(ctx, selected, input.Cwd, true, input.Refresh)
	if err != nil || !observed.Catalog {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		message := observed.DiscoveryError
		if err != nil {
			message = err.Error()
		}
		return json.Marshal(model.Object{"cli": model.Object{"status": "unavailable", "message": message}, "models": []any{}})
	}
	models := []model.Object{}
	for _, m := range observed.Models {
		levels := NativeThinkingLevels(m)
		isSelected := observed.State.Model != nil && m.Provider == observed.State.Model.Provider && m.ID == observed.State.Model.ID
		if isSelected {
			levels = observed.Levels
		}
		data, _ := json.Marshal(m)
		entry, _ := model.DecodeObject(data)
		delete(entry, "baseUrl")
		entry["thinkingLevels"] = levels
		entry["thinking"] = ThinkingCapability(m, levels)
		models = append(models, entry)
	}
	return json.Marshal(model.Object{"cli": model.Object{"status": "ready", "executablePath": observed.Executable, "version": observed.Version}, "models": models})
}
func (s *settingsAPI) Describe(ctx context.Context, input plugin.SettingsRequest) (json.RawMessage, error) {
	raw, err := s.Presentation(ctx, plugin.SettingsPresentationRequest{Settings: input.Settings, Cwd: input.Cwd})
	if err != nil {
		return nil, err
	}
	var presentation struct {
		Models []struct {
			Provider string                   `json:"provider"`
			ID       string                   `json:"id"`
			Thinking model.ThinkingCapability `json:"thinking"`
		}
	}
	if err = json.Unmarshal(raw, &presentation); err != nil {
		return nil, err
	}
	type group struct {
		Provider string
		Models   []string
		Thinking model.ThinkingCapability
	}
	groups := []group{}
	indices := map[string]int{}
	for _, m := range presentation.Models {
		if m.Thinking.Kind == "unknown" {
			continue
		}
		key, _ := json.Marshal([]any{m.Provider, m.Thinking})
		index, found := indices[string(key)]
		if !found {
			index = len(groups)
			indices[string(key)] = index
			groups = append(groups, group{Provider: m.Provider, Thinking: m.Thinking})
		}
		if !slices.Contains(groups[index].Models, m.ID) {
			groups[index].Models = append(groups[index].Models, m.ID)
		}
	}
	branches := []any{}
	for _, m := range groups {
		choices := []any{}
		choice := func(mode string) model.Object {
			return model.Object{"type": "object", "additionalProperties": false, "required": []string{"mode"}, "properties": model.Object{"mode": model.Object{"const": mode}}}
		}
		switch m.Thinking.Kind {
		case "fixed":
			choices = append(choices, choice("fixed"))
		case "toggle":
			choices = append(choices, choice("off"), choice("on"))
		case "effort":
			if m.Thinking.CanDisable {
				choices = append(choices, choice("off"))
			}
			choices = append(choices, model.Object{"type": "object", "additionalProperties": false, "required": []string{"mode", "effort"}, "properties": model.Object{"mode": model.Object{"const": "effort"}, "effort": model.Object{"type": "string", "enum": m.Thinking.Efforts}}})
		}
		branches = append(branches, model.Object{"type": "object", "additionalProperties": false, "required": []string{"provider", "model", "thinking"}, "properties": model.Object{"provider": model.Object{"const": m.Provider}, "model": model.Object{"type": "string", "enum": m.Models}, "thinking": model.Object{"oneOf": choices}}})
	}
	result := model.Object{"type": "object", "description": "Pi ordinary Threads require exact provider, model, and explicit thinking choice.", "oneOf": branches}
	if len(branches) == 0 {
		delete(result, "oneOf")
		result["not"] = model.Object{}
	}
	return json.Marshal(result)
}

func (s *settingsAPI) recordInstallation(cwd, path string) {
	s.mu.Lock()
	previous, known := s.installations[cwd]
	s.installations[cwd] = path
	s.mu.Unlock()
	if known && previous != path {
		s.invalidate()
	}
}
