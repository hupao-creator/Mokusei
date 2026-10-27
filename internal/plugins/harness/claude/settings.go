package claude

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/hupao-creator/Mokusei/internal/platform/discovery"
	"path/filepath"
	"strings"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

var efforts = []string{"low", "medium", "high", "xhigh", "max"}
var permissionModes = []string{"acceptEdits", "auto", "bypassPermissions", "manual", "dontAsk", "plan"}

type harnessSettings struct {
	UseDefaultThreadSettings *bool          `json:"useDefaultThreadSettings,omitempty"`
	ThreadSettings           map[string]any `json:"threadSettings"`
}
type modelPresentation struct {
	Value            string                   `json:"value"`
	DisplayName      string                   `json:"displayName"`
	Description      string                   `json:"description,omitempty"`
	SupportedEfforts []string                 `json:"supportedEfforts"`
	Thinking         model.ThinkingCapability `json:"thinking"`
}
type catalog struct {
	CLI    map[string]any      `json:"cli"`
	Models []modelPresentation `json:"models"`
}
type settingsAdapter struct {
	harness  *Harness
	catalogs discovery.Cache[catalog]
}

func normalizeHarness(raw json.RawMessage) (harnessSettings, error) {
	value := harnessSettings{ThreadSettings: map[string]any{}}
	if model.IsNull(raw) {
		return value, nil
	}
	if err := model.Unmarshal(raw, &value); err != nil {
		return value, err
	}
	if value.ThreadSettings == nil {
		return value, errors.New("Claude threadSettings must be an object")
	}
	for key := range value.ThreadSettings {
		if !contains([]string{"model", "effort", "goalMode", "permissionMode", "allowedTools", "disallowedTools"}, key) {
			return value, fmt.Errorf("unknown Claude harness thread setting %s", key)
		}
	}
	validated := map[string]any{"executablePath": "claude"}
	for k, v := range value.ThreadSettings {
		validated[k] = v
	}
	bytes, err := json.Marshal(validated)
	if err != nil {
		return value, err
	}
	if _, err = parseSettings(bytes); err != nil {
		return value, err
	}
	if value.UseDefaultThreadSettings == nil || *value.UseDefaultThreadSettings {
		value.UseDefaultThreadSettings = nil
		value.ThreadSettings = map[string]any{}
	}
	return value, nil
}
func parseSettings(raw json.RawMessage) (Settings, error) {
	var s Settings
	if model.IsNull(raw) {
		s.ExecutablePath = "claude"
		s.PermissionMode = "auto"
		return s, nil
	}
	if err := model.Unmarshal(raw, &s); err != nil {
		return s, err
	}
	object, err := model.DecodeObject(raw)
	if err != nil {
		return s, err
	}
	for _, key := range []string{"executablePath", "model", "effort", "permissionMode"} {
		if v, ok := object[key]; ok {
			text, ok := v.(string)
			if !ok || text == "" {
				return s, fmt.Errorf("invalid Claude %s", key)
			}
		}
	}
	if value, ok := object["thinking"]; ok && obj(value) == nil {
		return s, errors.New("Claude thinking must be an object")
	}
	if value, ok := object["goalMode"]; ok {
		if _, ok := value.(bool); !ok {
			return s, errors.New("Claude goalMode must be boolean")
		}
	}
	for _, key := range []string{"allowedTools", "disallowedTools"} {
		if value, ok := object[key]; ok {
			if _, ok := value.([]any); !ok {
				return s, fmt.Errorf("Claude %s must be an array", key)
			}
		}
	}
	if s.ExecutablePath == "" {
		return s, errors.New("Claude executablePath is required")
	}
	for name, v := range map[string]string{"executablePath": s.ExecutablePath, "model": s.Model} {
		if v != "" && (strings.TrimSpace(v) != v || len(v) > 512 || strings.ContainsRune(v, 0)) {
			return s, fmt.Errorf("invalid Claude %s", name)
		}
	}
	if s.Effort != "" && !contains(efforts, s.Effort) {
		return s, errors.New("invalid Claude effort")
	}
	if s.PermissionMode != "" && !contains(permissionModes, s.PermissionMode) {
		return s, errors.New("invalid Claude permission mode")
	}
	if s.Thinking != nil {
		if s.Thinking.Mode == "effort" {
			if !contains(efforts, s.Thinking.Effort) {
				return s, errors.New("invalid Claude thinking effort")
			}
		} else if s.Thinking.Mode != "fixed" {
			return s, errors.New("Claude supports effort or fixed thinking")
		}
	}
	for _, tools := range [][]string{s.AllowedTools, s.DisallowedTools} {
		seen := map[string]bool{}
		if len(tools) > 128 {
			return s, errors.New("too many Claude tool filters")
		}
		for _, tool := range tools {
			if tool == "" || len(tool) > 512 || strings.TrimSpace(tool) != tool || strings.ContainsRune(tool, 0) || seen[tool] {
				return s, errors.New("invalid Claude tool filter")
			}
			seen[tool] = true
		}
	}
	return s, nil
}
func explicit(s Settings) error {
	if s.Model == "" || strings.EqualFold(s.Model, "default") || s.Thinking == nil {
		return errors.New("Claude requires explicit model and thinking selections")
	}
	return nil
}
func (a *settingsAdapter) Normalize(raw json.RawMessage) (json.RawMessage, error) {
	s, e := normalizeHarness(raw)
	if e != nil {
		return nil, e
	}
	return json.Marshal(s)
}
func (a *settingsAdapter) DefaultThread(raw json.RawMessage) (json.RawMessage, error) {
	s, e := normalizeHarness(raw)
	if e != nil {
		return nil, e
	}
	value := map[string]any{"executablePath": "claude", "permissionMode": "auto"}
	for k, v := range s.ThreadSettings {
		value[k] = v
	}
	b, e := json.Marshal(value)
	if e != nil {
		return nil, e
	}
	if _, e = parseSettings(b); e != nil {
		return nil, e
	}
	return b, nil
}
func (a *settingsAdapter) HasThreadContent(raw json.RawMessage) bool {
	s, e := ParseState(raw)
	return e == nil && (s.PrimarySessionID != "" || s.PendingFork != nil || len(s.Turns) > 0)
}
func (a *settingsAdapter) PromptSettings(harness, source json.RawMessage) (json.RawMessage, error) {
	raw := source
	if model.IsNull(raw) {
		var err error
		raw, err = a.DefaultThread(harness)
		if err != nil {
			return nil, err
		}
	}
	s, err := parseSettings(raw)
	if err != nil {
		return nil, err
	}
	out := map[string]any{"executablePath": s.ExecutablePath}
	if s.Model != "" {
		out["model"] = s.Model
	}
	if s.Effort != "" {
		out["effort"] = s.Effort
	}
	return json.Marshal(out)
}
func (a *settingsAdapter) ResolveThread(ctx context.Context, r plugin.ResolveSettingsRequest) (json.RawMessage, error) {
	s, e := parseSettings(r.Merged)
	if e != nil {
		return nil, e
	}
	if !model.IsNull(r.Requested) {
		var request struct {
			Model          string                `json:"model"`
			Thinking       *model.ThinkingChoice `json:"thinking"`
			PermissionMode string                `json:"permissionMode,omitempty"`
		}
		if e = model.Unmarshal(r.Requested, &request); e != nil {
			return nil, e
		}
		s.Model = request.Model
		s.Thinking = request.Thinking
		if request.PermissionMode != "" {
			s.PermissionMode = request.PermissionMode
		}
		if e = explicit(s); e != nil {
			return nil, e
		}
		s.Effort = ""
		if s.Thinking.Mode == "effort" {
			s.Effort = s.Thinking.Effort
		}
	}
	if a.HasThreadContent(r.SessionState) && !model.IsNull(r.Existing) {
		old, err := parseSettings(r.Existing)
		if err != nil {
			return nil, err
		}
		if old.GoalMode != s.GoalMode {
			return nil, errors.New("cannot change Claude goal mode after session creation")
		}
		s.ExecutablePath = old.ExecutablePath
		s.AllowedTools = old.AllowedTools
		s.DisallowedTools = old.DisallowedTools
	}
	if e = a.validate(ctx, s, r.Cwd); e != nil {
		return nil, e
	}
	return json.Marshal(s)
}
func (a *settingsAdapter) ApplyThreadUpdate(ctx context.Context, r plugin.UpdateSettingsRequest) (json.RawMessage, error) {
	current, e := parseSettings(r.Current)
	if e != nil {
		return nil, e
	}
	defaults, e := parseSettings(r.Defaults)
	if e != nil {
		return nil, e
	}
	update, e := model.DecodeObject(r.Update)
	if e != nil {
		return nil, e
	}
	for k := range update {
		if !contains([]string{"model", "thinking", "permissionMode", "allowedTools", "disallowedTools"}, k) {
			return nil, fmt.Errorf("unknown Claude thread setting %s", k)
		}
	}
	for _, key := range []string{"model", "thinking"} {
		if v, ok := update[key]; ok && v == nil {
			return nil, errors.New("Claude model and thinking cannot reset to defaults")
		}
	}
	if modelValue, ok := update["model"]; ok && str(modelValue) != current.Model {
		if _, ok = update["thinking"]; !ok {
			return nil, errors.New("changing Claude model requires explicit thinking")
		}
	}
	b, _ := json.Marshal(current)
	value, _ := model.DecodeObject(b)
	db, _ := json.Marshal(defaults)
	def, _ := model.DecodeObject(db)
	for k, v := range update {
		if r.HasContent && (k == "allowedTools" || k == "disallowedTools") {
			return nil, errors.New("cannot change Claude tool filters after session creation")
		}
		if v == nil {
			if d, ok := def[k]; ok {
				value[k] = d
			} else {
				delete(value, k)
			}
		} else {
			value[k] = v
		}
	}
	b, _ = json.Marshal(value)
	s, e := parseSettings(b)
	if e != nil {
		return nil, e
	}
	if e = explicit(s); e != nil {
		return nil, e
	}
	s.Effort = ""
	if s.Thinking.Mode == "effort" {
		s.Effort = s.Thinking.Effort
	}
	if e = a.validate(ctx, s, r.Cwd); e != nil {
		return nil, e
	}
	return json.Marshal(s)
}
func (a *settingsAdapter) load(ctx context.Context, configured, cwd string, refresh bool) (catalog, error) {
	path, env, err := a.harness.resolve(ctx, cwd, configured)
	if err != nil {
		if ctx.Err() != nil {
			return catalog{}, ctx.Err()
		}
		return catalog{CLI: map[string]any{"status": "unavailable", "executablePath": nonempty(configured, "claude"), "message": err.Error()}, Models: []modelPresentation{}}, nil
	}
	home := env["CLAUDE_CONFIG_DIR"]
	if home == "" {
		home = filepath.Join(env["HOME"], ".claude")
	}
	key := path + "\x00" + cwd + "\x00" + discovery.Identity(env, path,
		filepath.Join(home, "settings.json"), filepath.Join(home, ".credentials.json"),
		filepath.Join(cwd, ".claude", "settings.json"), filepath.Join(cwd, ".claude", "settings.local.json"))
	result, err := a.catalogs.Get(ctx, key, refresh, 5*time.Minute, 45*time.Second, func(shared context.Context) (catalog, error) {
		return a.readCatalog(shared, path, cwd, env)
	})
	if err != nil && ctx.Err() == nil {
		return catalog{CLI: map[string]any{"status": "unavailable", "executablePath": path, "message": err.Error()}, Models: []modelPresentation{}}, nil
	}
	return result, err
}

func (a *settingsAdapter) readCatalog(ctx context.Context, path, cwd string, env map[string]string) (result catalog, err error) {
	t := NewTransport(TransportOptions{Executable: path, Cwd: cwd, Environment: env, Settings: Settings{ExecutablePath: path}, SessionID: newID(), ApplicationToolsOnly: true})
	defer func() { err = errors.Join(err, discovery.Cleanup(t.Close())) }()
	init, err := t.Initialize(ctx)
	if err != nil {
		return catalog{}, err
	}
	value := obj(init)
	result = catalog{CLI: map[string]any{"status": "available", "executablePath": path}, Models: []modelPresentation{}}
	if version := nonempty(str(value["claudeVersion"]), str(value["version"])); version != "" {
		result.CLI["version"] = version
	}
	seen := map[string]bool{}
	for _, v := range arr(value["models"]) {
		m := obj(v)
		id := nonempty(str(m["value"]), nonempty(str(m["id"]), str(m["model"])))
		if id == "" || m["disabled"] == true || seen[id] {
			continue
		}
		seen[id] = true
		advertised := []string{}
		for _, v := range arr(m["supportedEffortLevels"]) {
			if effort := str(v); contains(efforts, effort) && !contains(advertised, effort) && m["supportsEffort"] != false {
				advertised = append(advertised, effort)
			}
		}
		thinking := model.ThinkingCapability{Kind: "unknown", Reason: "Claude native catalog does not provide accurately encodable thinking controls"}
		if len(advertised) > 0 {
			thinking = model.ThinkingCapability{Kind: "effort", Efforts: advertised}
		}
		result.Models = append(result.Models, modelPresentation{Value: id, DisplayName: nonempty(str(m["displayName"]), nonempty(str(m["display_name"]), id)), Description: str(m["description"]), SupportedEfforts: advertised, Thinking: thinking})
	}
	if len(result.Models) == 0 {
		return result, errors.New("Claude native catalog is empty")
	}
	return result, nil
}
func (a *settingsAdapter) validate(ctx context.Context, s Settings, cwd string) error {
	if s.Model == "" && s.Effort == "" && s.Thinking == nil {
		return nil
	}
	c, e := a.load(ctx, s.ExecutablePath, cwd, false)
	if e != nil {
		return e
	}
	if str(c.CLI["status"]) != "available" || len(c.Models) == 0 {
		return errors.New("Claude model catalog unavailable; refresh and select model and thinking")
	}
	for _, m := range c.Models {
		if m.Value != s.Model {
			continue
		}
		if s.Effort != "" && !contains(m.SupportedEfforts, s.Effort) {
			return errors.New("Claude model does not support selected effort")
		}
		if s.Thinking != nil {
			if s.Thinking.Mode != m.Thinking.Kind {
				return errors.New("Claude selected thinking mode is not supported")
			}
			if s.Thinking.Mode == "effort" && !contains(m.Thinking.Efforts, s.Thinking.Effort) {
				return errors.New("Claude selected thinking effort is not supported")
			}
		}
		return nil
	}
	return fmt.Errorf("unknown Claude model %q", s.Model)
}
func (a *settingsAdapter) Presentation(ctx context.Context, r plugin.SettingsPresentationRequest) (json.RawMessage, error) {
	raw := r.ThreadSettings
	if model.IsNull(raw) {
		var e error
		raw, e = a.DefaultThread(r.Settings)
		if e != nil {
			return nil, e
		}
	}
	s, e := parseSettings(raw)
	if e != nil {
		return nil, e
	}
	c, e := a.load(ctx, s.ExecutablePath, r.Cwd, r.Refresh)
	if e != nil {
		return nil, e
	}
	return json.Marshal(c)
}
func (a *settingsAdapter) Describe(ctx context.Context, r plugin.SettingsRequest) (json.RawMessage, error) {
	c, e := a.load(ctx, "claude", r.Cwd, false)
	if e != nil {
		return nil, e
	}
	groups := []any{}
	for _, m := range c.Models {
		if strings.EqualFold(m.Value, "default") {
			continue
		}
		schema := map[string]any{"not": map[string]any{}}
		switch m.Thinking.Kind {
		case "fixed":
			schema = map[string]any{"type": "object", "additionalProperties": false, "required": []string{"mode"}, "properties": map[string]any{"mode": map[string]any{"const": "fixed"}}}
		case "effort":
			schema = map[string]any{"type": "object", "additionalProperties": false, "required": []string{"mode", "effort"}, "properties": map[string]any{"mode": map[string]any{"const": "effort"}, "effort": map[string]any{"type": "string", "enum": m.Thinking.Efforts}}}
		}
		groups = append(groups, map[string]any{"properties": map[string]any{"model": map[string]any{"type": "string", "enum": []string{m.Value}}, "thinking": schema}, "required": []string{"model", "thinking"}})
	}
	if len(groups) == 0 {
		groups = append(groups, map[string]any{"not": map[string]any{}})
	}
	return json.Marshal(map[string]any{"type": "object", "additionalProperties": false, "required": []string{"model", "thinking"}, "properties": map[string]any{"model": map[string]any{"type": "string", "minLength": 1}, "thinking": map[string]any{"type": "object"}, "permissionMode": map[string]any{"type": "string", "enum": permissionModes}}, "oneOf": groups})
}
func (a *settingsAdapter) SnapshotExecution(ctx context.Context, r plugin.SettingsRequest, initial bool) (json.RawMessage, error) {
	raw, e := a.DefaultThread(r.Settings)
	if e != nil {
		return nil, e
	}
	s, e := parseSettings(raw)
	if e != nil {
		return nil, e
	}
	if !initial && (s.Model == "" || s.Model == "default" || s.PermissionMode == "") {
		return nil, errors.New("Claude execution settings require explicit model and permission mode")
	}
	path, env, e := a.harness.resolve(ctx, r.Cwd, s.ExecutablePath)
	if e != nil {
		return nil, e
	}
	t := NewTransport(TransportOptions{Executable: path, Cwd: r.Cwd, Environment: env, Settings: s, SessionID: newID(), ApplicationToolsOnly: true})
	defer t.Close()
	if _, e = t.Initialize(ctx); e != nil {
		return nil, e
	}
	current, e := t.Control(ctx, map[string]any{"subtype": "get_settings"})
	if e != nil {
		return nil, e
	}
	applied := obj(obj(current)["applied"])
	concrete := str(applied["model"])
	if concrete == "" || contains([]string{"default", "opusplan", "opus", "sonnet", "haiku", "opus[1m]", "sonnet[1m]", "haiku[1m]"}, strings.ToLower(concrete)) {
		return nil, errors.New("Claude did not report a concrete applied model")
	}
	if s.Model != "" && !contains([]string{"default", "opusplan", "opus", "sonnet", "haiku", "opus[1m]", "sonnet[1m]", "haiku[1m]"}, strings.ToLower(s.Model)) && s.Model != concrete {
		return nil, errors.New("Claude did not apply the explicitly selected model")
	}
	captured := s
	captured.Model = concrete
	captured.Effort = str(applied["effort"])
	catalog, e := a.load(ctx, s.ExecutablePath, r.Cwd, false)
	if e != nil {
		return nil, e
	}
	var capability *model.ThinkingCapability
	for _, m := range catalog.Models {
		if m.Value == concrete {
			c := m.Thinking
			capability = &c
			break
		}
	}
	if capability == nil || capability.Kind == "unknown" {
		return nil, errors.New("Claude concrete model thinking capability is unknown")
	}
	if capability.Kind == "fixed" && applied["effort"] != nil {
		return nil, errors.New("Claude fixed model unexpectedly applied effort")
	}
	if capability.Kind == "effort" && (!contains(capability.Efforts, captured.Effort) || !initial && s.Effort == "") {
		return nil, errors.New("Claude actual effort is not explicitly supported")
	}
	if s.Effort != "" && s.Effort != captured.Effort {
		return nil, errors.New("Claude did not apply selected effort")
	}
	if e = assertApplied(current, captured, env, true); e != nil {
		return nil, e
	}
	value := map[string]any{"model": captured.Model, "permissionMode": captured.PermissionMode}
	if captured.Effort != "" {
		value["effort"] = captured.Effort
	}
	return json.Marshal(map[string]any{"useDefaultThreadSettings": false, "threadSettings": value})
}
