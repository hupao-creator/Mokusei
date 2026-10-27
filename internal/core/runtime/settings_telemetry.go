package runtime

import (
	"context"
	"encoding/json"
	"errors"
	"math"
	"regexp"
	"strings"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/platform/transport"
)

// Settings diagnostics contain only bounded identifiers and structural metadata.
// Validation errors and actual settings values must never enter these records.
func (r *Runtime) settingsTrace(ctx context.Context, event string, fields model.Object) {
	if r.config.SettingsTrace == nil {
		return
	}
	copy := model.Object{}
	for key, value := range fields {
		copy[key] = value
	}
	if value, ok := copy["harnessId"].(string); ok && r.config.Harnesses[value] == nil {
		copy["harnessId"] = "*"
	}
	if value, ok := copy["owner"].(string); ok && value != "moku" && value != "global" {
		known := false
		if settings, _, err := r.Settings(); err == nil {
			for _, entry := range settings.PluginSettings {
				if entry.ID == value {
					known = true
					break
				}
			}
		}
		if !known {
			copy["owner"] = "*"
		}
	}
	if _, exists := copy["traceId"]; !exists {
		if id := transport.CommandID(ctx); id != "" {
			copy["traceId"] = id
		}
	}
	// Diagnostics are observational and must not turn a successful state commit
	// into a failed command if a user-supplied sink is unavailable.
	defer func() { _ = recover() }()
	r.config.SettingsTrace(event, copy)
}
func (r *Runtime) settingsSpan(ctx context.Context, event string, fields model.Object) func(error) {
	started := time.Now()
	r.settingsTrace(ctx, event+".started", fields)
	return func(err error) {
		end := model.Object{}
		for key, value := range fields {
			end[key] = value
		}
		end["durationMs"] = float64(time.Since(started)) / float64(time.Millisecond)
		end["outcome"] = "completed"
		if err != nil {
			end["outcome"] = "failed"
		}
		r.settingsTrace(ctx, event+".completed", end)
	}
}

type settingsSchemaError struct {
	field string
	code  string
	path  []any
}

func (e *settingsSchemaError) Error() string { return "Invalid settings request: " + e.field }
func schemaError(field, code string, path ...any) error {
	return &settingsSchemaError{field: field, code: code, path: append([]any{}, path...)}
}
func settingsInteger(value any, minimum int64) (int64, bool) {
	number, ok := value.(json.Number)
	if !ok {
		return 0, false
	}
	n, err := number.Float64()
	if err != nil || math.IsNaN(n) || math.IsInf(n, 0) || math.Trunc(n) != n || n < float64(minimum) || n > float64(model.MaximumSafeInteger) {
		return 0, false
	}
	return int64(n), true
}
func settingsIssues(err error) []model.Object {
	var issue *settingsSchemaError
	if errors.As(err, &issue) {
		return []model.Object{{"code": issue.code, "path": issue.path}}
	}
	return []model.Object{{"code": "invalid_type", "path": []any{}}}
}
func parseSettingsRequest(raw json.RawMessage) (int64, model.Settings, error) {
	value, err := model.Decode(raw)
	if err != nil {
		return 0, model.Settings{}, schemaError("JSON", "invalid_type")
	}
	if err := model.CommandJSONSize(value, 2_000_000); err != nil {
		return 0, model.Settings{}, schemaError("settings payload exceeds limit", "too_big", "settings")
	}
	request, err := closedSettingsObject(value, []string{"expectedSettingsRevision", "settings"}, []string{"expectedSettingsRevision", "settings"})
	if err != nil {
		return 0, model.Settings{}, err
	}
	expected, ok := settingsInteger(request["expectedSettingsRevision"], 0)
	if !ok {
		return 0, model.Settings{}, schemaError("invalid settings revision", "invalid_type", "expectedSettingsRevision")
	}
	settings, err := parseSettingsShell(request["settings"])
	return expected, settings, err
}
func closedSettingsObject(value any, allowed, required []string, path ...any) (model.Object, error) {
	object, ok := value.(map[string]any)
	if !ok {
		return nil, schemaError("expected object", "invalid_type", path...)
	}
	known := map[string]bool{}
	for _, key := range allowed {
		known[key] = true
	}
	for key := range object {
		if !known[key] {
			return nil, schemaError("unknown field", "unrecognized_keys", appendPath(path, "*")...)
		}
	}
	for _, key := range required {
		if _, ok := object[key]; !ok {
			return nil, schemaError("missing field", "invalid_type", appendPath(path, key)...)
		}
	}
	return object, nil
}
func appendPath(path []any, value any) []any { return append(append([]any{}, path...), value) }
func settingsObjectMap(value any, path ...any) (map[string]json.RawMessage, error) {
	object, ok := value.(map[string]any)
	if !ok {
		return nil, schemaError("expected settings map", "invalid_type", path...)
	}
	result := map[string]json.RawMessage{}
	for key, child := range object {
		if _, ok := child.(map[string]any); !ok {
			return nil, schemaError("Harness settings must be an object", "invalid_type", appendPath(path, "*")...)
		}
		raw, err := json.Marshal(child)
		if err != nil {
			return nil, err
		}
		result[key] = raw
	}
	return result, nil
}
func settingsText(value any, optional bool, path ...any) (*string, error) {
	if value == nil && optional {
		return nil, nil
	}
	text, ok := value.(string)
	if !ok {
		return nil, schemaError("expected text", "invalid_type", path...)
	}
	return &text, nil
}

// ECMAScript trim excludes U+0085 and includes BOM, unlike strings.TrimSpace.
func settingsSpace(r rune) bool {
	return r == '\t' || r == '\n' || r == '\v' || r == '\f' || r == '\r' || r == ' ' || r == 0xa0 || r == 0x1680 || (r >= 0x2000 && r <= 0x200a) || r == 0x2028 || r == 0x2029 || r == 0x202f || r == 0x205f || r == 0x3000 || r == 0xfeff
}
func normalizedGuidance(value any, path ...any) (*string, error) {
	text, err := settingsText(value, true, path...)
	if err != nil || text == nil {
		return text, err
	}
	trimmed := strings.TrimFunc(*text, settingsSpace)
	if model.UTF16Length(trimmed) > 12000 {
		return nil, schemaError("guidance must be at most 12000 UTF-16 code units", "too_big", path...)
	}
	if trimmed == "" {
		return nil, nil
	}
	return &trimmed, nil
}

var pluginPreferenceKey = regexp.MustCompile(`^(extension|context|harness|sidecard):[a-z][a-z0-9-]*$`)

func parseSettingsShell(value any) (model.Settings, error) {
	result := model.Settings{}
	object, err := closedSettingsObject(value, []string{"moku", "harnesses", "pluginSettings", "pluginEnabled"}, []string{"moku", "harnesses", "pluginSettings"}, "settings")
	if err != nil {
		return result, err
	}
	moku, err := closedSettingsObject(object["moku"], []string{"hostHarnessPreference", "executionHarnesses", "targetHarnessIds", "routingGuidance"}, []string{"hostHarnessPreference", "targetHarnessIds", "routingGuidance"}, "settings", "moku")
	if err != nil {
		return result, err
	}
	preference, err := settingsText(moku["hostHarnessPreference"], false, "settings", "moku", "hostHarnessPreference")
	if err != nil {
		return result, err
	}
	result.Moku.HostHarnessPreference = *preference
	result.Moku.ExecutionHarnesses = map[string]json.RawMessage{}
	if profiles, exists := moku["executionHarnesses"]; exists {
		result.Moku.ExecutionHarnesses, err = settingsObjectMap(profiles, "settings", "moku", "executionHarnesses")
		if err != nil {
			return result, err
		}
	}
	ids, ok := moku["targetHarnessIds"].([]any)
	if !ok {
		return result, schemaError("target Harnesses must be an array", "invalid_type", "settings", "moku", "targetHarnessIds")
	}
	result.Moku.TargetHarnessIDs = []string{}
	seen := map[string]bool{}
	for index, value := range ids {
		id, ok := value.(string)
		if !ok || seen[id] {
			return result, schemaError("invalid or duplicate target Harness", "custom", "settings", "moku", "targetHarnessIds", index)
		}
		seen[id] = true
		result.Moku.TargetHarnessIDs = append(result.Moku.TargetHarnessIDs, id)
	}
	result.Moku.RoutingGuidance, err = normalizedGuidance(moku["routingGuidance"], "settings", "moku", "routingGuidance")
	if err != nil {
		return result, err
	}
	result.Harnesses, err = settingsObjectMap(object["harnesses"], "settings", "harnesses")
	if err != nil {
		return result, err
	}
	entries, ok := object["pluginSettings"].([]any)
	if !ok {
		return result, schemaError("pluginSettings must be an array", "invalid_type", "settings", "pluginSettings")
	}
	result.PluginSettings = []model.PluginSettings{}
	seen = map[string]bool{}
	for index, entry := range entries {
		path := []any{"settings", "pluginSettings", index}
		row, err := closedSettingsObject(entry, []string{"id", "schemaVersion", "value"}, []string{"id", "schemaVersion", "value"}, path...)
		if err != nil {
			return result, err
		}
		id, ok := row["id"].(string)
		if !ok || strings.TrimSpace(id) == "" || strings.ContainsRune(id, 0) || model.UTF16Length(id) > 128 || seen[id] {
			return result, schemaError("invalid or duplicate plugin settings ID", "custom", appendPath(path, "id")...)
		}
		seen[id] = true
		version, ok := settingsInteger(row["schemaVersion"], 1)
		if !ok {
			return result, schemaError("invalid settings schema version", "invalid_type", appendPath(path, "schemaVersion")...)
		}
		raw, err := json.Marshal(row["value"])
		if err != nil {
			return result, err
		}
		result.PluginSettings = append(result.PluginSettings, model.PluginSettings{ID: id, SchemaVersion: int(version), Value: raw})
	}
	if preferences, exists := object["pluginEnabled"]; exists {
		values, ok := preferences.(map[string]any)
		if !ok {
			return result, schemaError("pluginEnabled must be an object", "invalid_type", "settings", "pluginEnabled")
		}
		result.PluginEnabled = map[string]bool{}
		for key, raw := range values {
			enabled, ok := raw.(bool)
			if !ok || !pluginPreferenceKey.MatchString(key) {
				return result, schemaError("invalid plugin preference", "invalid_type", "settings", "pluginEnabled", "*")
			}
			result.PluginEnabled[key] = enabled
		}
	}
	return result, nil
}
func normalizeSettingsShell(settings model.Settings) (model.Settings, error) {
	raw, err := json.Marshal(settings)
	if err != nil {
		return settings, err
	}
	object, err := model.Decode(raw)
	if err != nil {
		return settings, err
	}
	return parseSettingsShell(object)
}
func changedSettingsFields(before, after model.Settings) []string {
	result := []string{}
	for _, entry := range []struct {
		key           string
		before, after any
	}{{"moku.hostHarnessPreference", before.Moku.HostHarnessPreference, after.Moku.HostHarnessPreference}, {"moku.executionHarnesses", before.Moku.ExecutionHarnesses, after.Moku.ExecutionHarnesses}, {"moku.targetHarnessIds", before.Moku.TargetHarnessIDs, after.Moku.TargetHarnessIDs}, {"moku.routingGuidance", before.Moku.RoutingGuidance, after.Moku.RoutingGuidance}, {"harnesses", before.Harnesses, after.Harnesses}, {"pluginSettings", before.PluginSettings, after.PluginSettings}, {"pluginEnabled", before.PluginEnabled, after.PluginEnabled}} {
		if !same(entry.before, entry.after) {
			result = append(result, entry.key)
		}
	}
	return result
}

var clientDiagnosticEvents = stringSet("page", "edit", "composition", "close", "retry", "conflict", "validation", "save", "command", "receive", "availability", "discard", "preferences", "presentation")
var clientDiagnosticOutcomes = stringSet("started", "completed", "failed", "pending", "blocked", "saved", "conflict", "keep", "discard", "available", "unavailable", "opened", "closed")
var diagnosticFields = stringSet("moku.hostHarnessPreference", "moku.executionHarnesses", "moku.targetHarnessIds", "moku.routingGuidance", "harnesses", "pluginSettings", "pluginEnabled", "appearance", "locale", "glassWorld")
var diagnosticUUID = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)
var diagnosticCommandID = regexp.MustCompile(`^[a-zA-Z0-9_-]{16,128}$`)

func stringSet(values ...string) map[string]bool {
	result := map[string]bool{}
	for _, value := range values {
		result[value] = true
	}
	return result
}
func parseClientDiagnostics(raw json.RawMessage) ([]model.Object, error) {
	value, err := model.Decode(raw)
	if err != nil {
		return nil, schemaError("diagnostics JSON", "invalid_type")
	}
	events, ok := value.([]any)
	if !ok || len(events) < 1 || len(events) > 32 {
		return nil, schemaError("diagnostics requires 1 to 32 events", "too_big")
	}
	result := []model.Object{}
	for index, event := range events {
		object, err := closedSettingsObject(event, []string{"event", "outcome", "flowId", "operationId", "revision", "durationMs", "fields"}, []string{"event", "outcome", "flowId"}, index)
		if err != nil {
			return nil, err
		}
		name, nameOK := object["event"].(string)
		outcome, outcomeOK := object["outcome"].(string)
		flow, flowOK := object["flowId"].(string)
		if !nameOK || !clientDiagnosticEvents[name] || !outcomeOK || !clientDiagnosticOutcomes[outcome] || !flowOK || !diagnosticUUID.MatchString(flow) {
			return nil, schemaError("invalid diagnostic metadata", "invalid_type", index)
		}
		if value, exists := object["operationId"]; exists {
			id, ok := value.(string)
			if !ok || !diagnosticCommandID.MatchString(id) {
				return nil, schemaError("invalid diagnostic operation identity", "invalid_type", index, "operationId")
			}
		}
		for _, key := range []string{"revision", "durationMs"} {
			if value, exists := object[key]; exists {
				number, ok := value.(json.Number)
				if !ok {
					return nil, schemaError("invalid diagnostic number", "invalid_type", index, key)
				}
				n, err := number.Float64()
				if err != nil || math.IsNaN(n) || math.IsInf(n, 0) || n < 0 || (key == "revision" && (math.Trunc(n) != n || n > float64(model.MaximumSafeInteger))) {
					return nil, schemaError("invalid diagnostic number", "invalid_type", index, key)
				}
				object[key] = n
			}
		}
		if fields, exists := object["fields"]; exists {
			array, ok := fields.([]any)
			if !ok || len(array) > 10 {
				return nil, schemaError("invalid diagnostic fields", "invalid_type", index, "fields")
			}
			names := []string{}
			for _, entry := range array {
				name, ok := entry.(string)
				if !ok || !diagnosticFields[name] {
					return nil, schemaError("invalid diagnostic field name", "invalid_type", index, "fields")
				}
				names = append(names, name)
			}
			object["fields"] = names
		}
		result = append(result, object)
	}
	return result, nil
}
func (r *Runtime) recordClientDiagnostics(ctx context.Context, raw json.RawMessage) error {
	events, err := parseClientDiagnostics(raw)
	if err != nil {
		return err
	}
	for _, event := range events {
		name := event["event"].(string)
		fields := model.Object{}
		for key, value := range event {
			if key != "event" && key != "operationId" {
				fields[key] = value
			}
		}
		if id, ok := event["operationId"].(string); ok {
			fields["traceId"] = id
		}
		r.settingsTrace(ctx, "client."+name, fields)
	}
	return nil
}

func settingsSchemaFailure(err error) bool {
	var failure *settingsSchemaError
	return errors.As(err, &failure)
}
func (r *Runtime) traceCommand(ctx context.Context, channel string) func(error) {
	span := r.settingsSpan(ctx, "command", model.Object{"channel": channel})
	return func(err error) {
		if settingsSchemaFailure(err) {
			r.settingsTrace(ctx, "command.rejected", model.Object{"channel": channel, "stage": "schema", "outcome": "failed", "issues": settingsIssues(err)})
		}
		span(err)
	}
}
