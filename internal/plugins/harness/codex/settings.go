package codex

import (
	"context"
	"encoding/json"
	"fmt"
	"path/filepath"
	"reflect"
	"regexp"
	"sort"
	"strings"
	"unicode/utf8"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

const DefaultPermissionMode = "approve-for-me"

var permissionModes = []string{"ask-for-approval", "approve-for-me", "full-access"}

func ValidateHarnessSettings(value Map) (Map, error) {
	if value == nil {
		return nil, fmt.Errorf("Codex harness settings must be an object")
	}
	if err := csOnlyKeys(value, []string{"useDefaultThreadSettings", "threadSettings"}, "harness settings"); err != nil {
		return nil, err
	}
	raw, exists := value["threadSettings"]
	if !exists {
		return nil, fmt.Errorf("Codex harness settings requires threadSettings")
	}
	thread, ok := csRecord(raw)
	if !ok {
		return nil, fmt.Errorf("Codex threadSettings must be an object")
	}
	if _, exists := thread["executablePath"]; exists {
		return nil, fmt.Errorf("Codex harness defaults cannot contain executablePath")
	}
	if gate, exists := value["useDefaultThreadSettings"]; exists {
		if _, ok := gate.(bool); !ok {
			return nil, fmt.Errorf("Codex useDefaultThreadSettings must be boolean")
		}
	}
	normalized, err := NormalizeThreadSettings(thread)
	if err != nil {
		return nil, err
	}
	if value["useDefaultThreadSettings"] == false {
		return Map{"useDefaultThreadSettings": false, "threadSettings": normalized}, nil
	}
	return Map{"threadSettings": Map{}}, nil
}

func NormalizeThreadSettings(value Map) (Map, error) {
	if value == nil {
		return nil, fmt.Errorf("Codex settings must be an object")
	}
	if err := csOnlyKeys(value, []string{"executablePath", "model", "effort", "thinking", "serviceTier", "personality", "approvalPolicy", "approvalsReviewer", "sandbox", "sandboxPolicy", "summary", "permissionMode"}, "settings"); err != nil {
		return nil, err
	}
	out := Map{}
	for key, max := range map[string]int{"executablePath": 4096, "model": 256, "effort": 64, "serviceTier": 128} {
		if raw, exists := value[key]; exists {
			v, err := csIdentifier(raw, key, max)
			if err != nil {
				return nil, err
			}
			out[key] = v
		}
	}
	for key, allowed := range map[string][]string{"personality": {"none", "friendly", "pragmatic"}, "approvalPolicy": {"untrusted", "on-request", "never"}, "approvalsReviewer": {"user", "auto_review"}, "sandbox": {"read-only", "workspace-write", "danger-full-access"}, "summary": {"auto", "concise", "detailed", "none"}, "permissionMode": permissionModes} {
		if raw, exists := value[key]; exists {
			v, ok := raw.(string)
			if !ok || !csContains(allowed, v) {
				return nil, fmt.Errorf("Codex %s must be one of %s", key, strings.Join(allowed, ", "))
			}
			out[key] = v
		}
	}
	if raw, exists := value["thinking"]; exists {
		v, err := NormalizeThinkingChoice(raw)
		if err != nil {
			return nil, err
		}
		if _, exists := value["effort"]; exists {
			return nil, fmt.Errorf("Codex settings cannot combine thinking and legacy effort")
		}
		out["thinking"] = v
	}
	if raw, exists := value["sandboxPolicy"]; exists {
		v, err := NormalizeSandboxPolicy(raw)
		if err != nil {
			return nil, err
		}
		if _, exists := value["sandbox"]; exists {
			return nil, fmt.Errorf("Codex settings cannot combine sandbox and sandboxPolicy")
		}
		out["sandboxPolicy"] = v
	}
	return out, nil
}

func NormalizeThinkingChoice(raw any) (Map, error) {
	value, ok := csRecord(raw)
	if !ok {
		return nil, fmt.Errorf("Codex thinking requires an explicit object choice")
	}
	mode := csString(value["mode"])
	if mode == "effort" {
		if err := csOnlyKeys(value, []string{"mode", "effort"}, "thinking"); err != nil {
			return nil, err
		}
		effort, err := csIdentifier(value["effort"], "thinking.effort", 64)
		if err != nil {
			return nil, err
		}
		if strings.EqualFold(effort, "default") {
			return nil, fmt.Errorf("Codex thinking requires a concrete effort")
		}
		return Map{"mode": mode, "effort": effort}, nil
	}
	if len(value) == 1 && csContains([]string{"on", "off", "fixed"}, mode) {
		return Map{"mode": mode}, nil
	}
	return nil, fmt.Errorf("Codex thinking must select effort, on, off, or fixed")
}
func ThinkingEffort(raw any) (string, error) {
	value, err := NormalizeThinkingChoice(raw)
	if err != nil {
		return "", err
	}
	switch value["mode"] {
	case "effort":
		return csString(value["effort"]), nil
	case "off":
		return "none", nil
	case "fixed":
		return "", nil
	default:
		return "", fmt.Errorf("Codex cannot encode a thinking switch without an evidenced native mapping")
	}
}

func NormalizeSandboxPolicy(raw any) (Map, error) {
	value, ok := csRecord(raw)
	if !ok {
		return nil, fmt.Errorf("Codex sandboxPolicy must be an object")
	}
	kind := csString(value["type"])
	allowed := []string{"type"}
	switch kind {
	case "dangerFullAccess":
	case "readOnly", "externalSandbox":
		allowed = append(allowed, "networkAccess")
	case "workspaceWrite":
		allowed = append(allowed, "writableRoots", "networkAccess", "excludeTmpdirEnvVar", "excludeSlashTmp")
	default:
		return nil, fmt.Errorf("Codex sandboxPolicy.type is invalid")
	}
	if err := csOnlyKeys(value, allowed, "sandboxPolicy"); err != nil {
		return nil, err
	}
	out := Map{"type": kind}
	if kind == "externalSandbox" {
		network := csString(value["networkAccess"])
		if network != "restricted" && network != "enabled" {
			return nil, fmt.Errorf("Codex sandboxPolicy.networkAccess is invalid")
		}
		out["networkAccess"] = network
	}
	if kind == "readOnly" || kind == "workspaceWrite" {
		keys := []string{"networkAccess"}
		if kind == "workspaceWrite" {
			keys = append(keys, "excludeTmpdirEnvVar", "excludeSlashTmp")
		}
		for _, key := range keys {
			v, ok := value[key].(bool)
			if !ok {
				return nil, fmt.Errorf("Codex sandboxPolicy.%s must be boolean", key)
			}
			out[key] = v
		}
	}
	if kind == "workspaceWrite" {
		roots, ok := csSlice(value["writableRoots"])
		if !ok || len(roots) > 64 {
			return nil, fmt.Errorf("Codex sandboxPolicy.writableRoots is invalid")
		}
		result := []string{}
		for _, raw := range roots {
			root, err := csIdentifier(raw, "sandboxPolicy.writableRoots", 4096)
			if err != nil {
				return nil, err
			}
			if !filepath.IsAbs(root) && !regexp.MustCompile(`^[A-Za-z]:[\\/]`).MatchString(root) && !strings.HasPrefix(root, `\\`) {
				return nil, fmt.Errorf("Codex sandboxPolicy.writableRoots must contain absolute paths")
			}
			if !csContains(result, root) {
				result = append(result, root)
			}
		}
		out["writableRoots"] = result
	}
	return out, nil
}

func PermissionPreset(mode string) Map {
	if mode == "" {
		mode = DefaultPermissionMode
	}
	out := Map{"sandbox": "workspace-write", "approvalPolicy": "on-request", "approvalsReviewer": "user"}
	if mode == "full-access" {
		out["sandbox"] = "danger-full-access"
		out["approvalPolicy"] = "never"
	}
	if mode == "approve-for-me" {
		out["approvalsReviewer"] = "auto_review"
	}
	return out
}
func NormalizeThreadSettingsRequest(value Map) (Map, error) {
	if value == nil {
		return nil, fmt.Errorf("Codex requested settings must be an object")
	}
	if err := csOnlyKeys(value, []string{"model", "thinking", "serviceTier", "permissionMode"}, "requested"); err != nil {
		return nil, err
	}
	model, err := csIdentifier(value["model"], "requested.model", 256)
	if err != nil {
		return nil, err
	}
	if csContains([]string{"default", "codex-default"}, strings.ToLower(model)) {
		return nil, fmt.Errorf("Codex requested model must name an exact model")
	}
	if _, err = NormalizeThinkingChoice(value["thinking"]); err != nil {
		return nil, err
	}
	if _, err = csIdentifier(value["serviceTier"], "requested.serviceTier", 128); err != nil {
		return nil, fmt.Errorf("Codex requested.serviceTier requires an explicit choice: default for standard speed (Fast off), or a service tier advertised by the selected model")
	}
	return NormalizeThreadSettings(value)
}

func ResolveThreadSettings(merged, requested, existing Map) (Map, error) {
	next, err := NormalizeThreadSettings(merged)
	if err != nil {
		return nil, err
	}
	if requested != nil {
		requested, err = NormalizeThreadSettingsRequest(requested)
		if err != nil {
			return nil, err
		}
	}
	mode := csString(next["permissionMode"])
	if candidate := csString(requested["permissionMode"]); candidate != "" {
		mode = candidate
	}
	if mode != "" || !csHasAny(next, "approvalPolicy", "approvalsReviewer", "sandbox", "sandboxPolicy") {
		effective := mode
		if effective == "" {
			effective = DefaultPermissionMode
		}
		for _, key := range []string{"approvalPolicy", "approvalsReviewer", "sandbox", "sandboxPolicy"} {
			delete(next, key)
		}
		csAssign(next, PermissionPreset(effective))
		if mode != "" {
			next["permissionMode"] = mode
		}
	}
	if _, exists := requested["model"]; exists {
		delete(next, "effort")
		delete(next, "thinking")
	}
	for key, value := range requested {
		if key != "permissionMode" {
			next[key] = value
		}
	}
	next, err = NormalizeThreadSettings(next)
	if err != nil {
		return nil, err
	}
	if old, exists := existing["executablePath"]; exists && old != next["executablePath"] {
		return nil, fmt.Errorf("Existing Codex Primary Native Session cannot change executablePath")
	}
	return next, nil
}

func UpdateThreadSettings(current, update Map) (Map, error) {
	next, err := NormalizeThreadSettings(current)
	if err != nil {
		return nil, err
	}
	if update == nil {
		return nil, fmt.Errorf("Codex update must be an object")
	}
	if err = csOnlyKeys(update, []string{"model", "thinking", "serviceTier", "personality", "approvalPolicy", "sandbox", "sandboxPolicy", "summary", "permissionMode"}, "update"); err != nil {
		return nil, err
	}
	// Validate sparse updates before merging; null clears only nullable members.
	check := Map{}
	for key, value := range update {
		if value != nil {
			check[key] = value
		} else if key == "thinking" {
			return nil, fmt.Errorf("Codex thinking cannot be cleared")
		}
	}
	if _, err = NormalizeThreadSettings(check); err != nil {
		return nil, err
	}
	_, changesModel := update["model"]
	_, changesThinking := update["thinking"]
	if changesModel && csString(update["model"]) == "" {
		return nil, fmt.Errorf("Codex ordinary Thread model cannot be cleared")
	}
	modelChanged := changesModel && update["model"] != current["model"]
	if modelChanged && !changesThinking {
		return nil, fmt.Errorf("Codex changing model requires an explicit thinking choice")
	}
	if modelChanged {
		delete(next, "serviceTier")
	}
	if changesThinking {
		delete(next, "effort")
	}
	for _, key := range []string{"model", "thinking", "serviceTier", "personality", "summary"} {
		if value, exists := update[key]; exists {
			if value == nil {
				delete(next, key)
			} else {
				next[key] = csCopy(value)
			}
		}
	}
	if mode, exists := update["permissionMode"]; exists {
		for _, key := range []string{"permissionMode", "approvalPolicy", "approvalsReviewer", "sandbox", "sandboxPolicy"} {
			delete(next, key)
		}
		effective := csString(mode)
		if effective != "" {
			next["permissionMode"] = effective
		} else {
			effective = DefaultPermissionMode
		}
		csAssign(next, PermissionPreset(effective))
	} else {
		if csHasAny(update, "approvalPolicy", "sandbox", "sandboxPolicy") {
			delete(next, "permissionMode")
		}
		if value, exists := update["approvalPolicy"]; exists {
			if value == nil {
				delete(next, "approvalPolicy")
			} else {
				next["approvalPolicy"] = value
			}
		}
		simple, simpleSet := update["sandbox"]
		policy, policySet := update["sandboxPolicy"]
		if simpleSet || policySet {
			if simple != nil && policy != nil {
				return nil, fmt.Errorf("Codex update cannot combine sandbox and sandboxPolicy")
			}
			switch {
			case simple != nil:
				delete(next, "sandboxPolicy")
				next["sandbox"] = simple
			case policy != nil:
				delete(next, "sandbox")
				next["sandboxPolicy"] = csCopy(policy)
			case simpleSet && policySet:
				delete(next, "sandbox")
				delete(next, "sandboxPolicy")
			case simpleSet:
				delete(next, "sandbox")
			case policySet:
				delete(next, "sandboxPolicy")
			}
		}
	}
	if csHasAny(update, "model", "thinking", "serviceTier") && (next["model"] == nil || next["thinking"] == nil) {
		return nil, fmt.Errorf("Codex ordinary Thread updates require an exact model and explicit thinking choice")
	}
	return NormalizeThreadSettings(next)
}

func PromptSettings(settings, source Map) (Map, error) {
	normalized, err := ValidateHarnessSettings(settings)
	if err != nil {
		return nil, err
	}
	profile, _ := csRecord(normalized["threadSettings"])
	if source != nil {
		profile = source
	}
	out := Map{}
	for _, key := range []string{"model", "effort", "serviceTier"} {
		if value, exists := profile[key]; exists {
			out[key] = csCopy(value)
		}
	}
	if source != nil {
		out["effort"] = "low"
		if value, exists := source["executablePath"]; exists {
			out["executablePath"] = value
		}
	}
	return out, nil
}
func HasThreadContent(state Map) bool {
	return csString(state["primarySessionId"]) != "" || len(csArray(state["turns"])) > 0
}
func SettingsSchemaForModels(models []Map) Map {
	modelIDs := []string{}
	tiers := []string{"default"}
	groups := []Map{}
	groupIndex := map[string]int{}
	for _, model := range models {
		modelIDs = append(modelIDs, csString(model["value"]))
		thinking, _ := csRecord(model["thinking"])
		schema := csThinkingSchema(thinking)
		modelTiers := []string{"default"}
		for _, raw := range csArray(model["serviceTiers"]) {
			tier, _ := csRecord(raw)
			value := csString(tier["value"])
			if value != "" && !csContains(modelTiers, value) {
				modelTiers = append(modelTiers, value)
			}
			if value != "" && !csContains(tiers, value) {
				tiers = append(tiers, value)
			}
		}
		tierSchema := csServiceTierSchema(modelTiers)
		encoded, _ := json.Marshal(Map{"thinking": schema, "serviceTier": tierSchema})
		key := string(encoded)
		if index, ok := groupIndex[key]; ok {
			group := groups[index]
			values := group["models"].([]string)
			group["models"] = append(values, csString(model["value"]))
		} else {
			groupIndex[key] = len(groups)
			groups = append(groups, Map{"models": []string{csString(model["value"])}, "thinking": schema, "serviceTier": tierSchema})
		}
	}
	identifier := func(max int) Map {
		return Map{"type": "string", "minLength": 1, "maxLength": max, "pattern": `^\S(?:[^\u0000]*\S)?$`}
	}
	modelSchema := identifier(256)
	modelSchema["description"] = "Required exact model identifier supported by the target Codex executable and workspace. Native defaults are not accepted."
	tierSchema := csServiceTierSchema(tiers)
	if len(modelIDs) > 0 {
		modelSchema["enum"] = modelIDs
	}
	out := Map{"type": "object", "description": "Ordinary Codex Thread creation requires an exact model, an explicit thinking choice, and an explicit service tier. No service tier is inherited. Choices are validated against the target environment again before execution.", "required": []string{"model", "thinking", "serviceTier"}, "additionalProperties": false, "properties": Map{"model": modelSchema, "thinking": Map{"type": "object", "description": "Required explicit choice; use the model-specific branch. Unknown capabilities cannot be selected."}, "serviceTier": tierSchema, "permissionMode": Map{"type": "string", "enum": permissionModes, "description": "approve-for-me uses workspace-write, on-request and native auto-review, failing when unavailable. ask-for-approval uses user approval. full-access uses danger-full-access and never. Omit to inherit configured Thread defaults."}}}
	if len(models) == 0 {
		out["not"] = Map{}
		out["description"] = "Codex model capabilities are unavailable; refresh the native model catalog before creating a Thread."
	} else {
		branches := []Map{}
		for _, group := range groups {
			branches = append(branches, Map{"type": "object", "properties": Map{"model": Map{"enum": group["models"]}, "thinking": group["thinking"], "serviceTier": group["serviceTier"]}, "required": []string{"model", "thinking", "serviceTier"}})
		}
		out["oneOf"] = branches
	}
	return out
}

func csServiceTierSchema(tiers []string) Map {
	return Map{"type": "string", "enum": tiers, "description": "Required explicit service tier. Choose default for standard speed (Fast off), overriding native Fast settings; choose priority for Fast only when advertised by this model. Never omit or inherit this choice."}
}

func csThinkingSchema(capability Map) Map {
	kind := csString(capability["kind"])
	modes := []string{}
	if kind == "effort" {
		if capability["canDisable"] == true {
			modes = append(modes, "off")
		}
		if len(csArray(capability["efforts"])) > 0 {
			modes = append(modes, "effort")
		}
	} else if kind == "toggle" {
		modes = []string{"off", "on"}
	} else if kind == "fixed" {
		modes = []string{"fixed"}
	}
	if len(modes) == 0 {
		return Map{"type": "object", "not": Map{}, "description": capability["reason"]}
	}
	branches := []Map{}
	for _, mode := range modes {
		properties := Map{"mode": Map{"type": "string", "const": mode}}
		required := []string{"mode"}
		if mode == "effort" {
			properties["effort"] = Map{"type": "string", "enum": capability["efforts"]}
			required = append(required, "effort")
		}
		branches = append(branches, Map{"type": "object", "additionalProperties": false, "properties": properties, "required": required})
	}
	return Map{"type": "object", "description": "Explicit thinking choice for this exact model. No implicit default is accepted.", "oneOf": branches}
}
func csOnlyKeys(value Map, allowed []string, label string) error {
	unknown := []string{}
	for key := range value {
		if !csContains(allowed, key) {
			unknown = append(unknown, key)
		}
	}
	if len(unknown) > 0 {
		sort.Strings(unknown)
		return fmt.Errorf("Codex %s contains unknown fields: %s", label, strings.Join(unknown, ", "))
	}
	return nil
}
func csIdentifier(raw any, label string, max int) (string, error) {
	value, ok := raw.(string)
	if !ok || value == "" || strings.TrimSpace(value) != value || utf8.RuneCountInString(value) > max || strings.ContainsRune(value, 0) {
		return "", fmt.Errorf("Codex %s must be a canonical string of 1-%d characters", label, max)
	}
	return value, nil
}
func csContains(values []string, value string) bool {
	for _, candidate := range values {
		if candidate == value {
			return true
		}
	}
	return false
}
func csHasAny(value Map, keys ...string) bool {
	for _, key := range keys {
		if _, exists := value[key]; exists {
			return true
		}
	}
	return false
}
func csString(value any) string { v, _ := value.(string); return v }
func csRecord(value any) (Map, bool) {
	if value == nil {
		return nil, false
	}
	v := reflect.ValueOf(value)
	if v.Kind() != reflect.Map || v.Type().Key().Kind() != reflect.String {
		return nil, false
	}
	out := Map{}
	iter := v.MapRange()
	for iter.Next() {
		out[iter.Key().String()] = iter.Value().Interface()
	}
	return out, true
}
func csSlice(value any) ([]any, bool) {
	if value == nil {
		return nil, false
	}
	v := reflect.ValueOf(value)
	if v.Kind() != reflect.Slice && v.Kind() != reflect.Array {
		return nil, false
	}
	out := make([]any, v.Len())
	for i := range out {
		out[i] = v.Index(i).Interface()
	}
	return out, true
}
func csArray(value any) []any { out, _ := csSlice(value); return out }
func csCopy(value any) any {
	if record, ok := csRecord(value); ok {
		out := Map{}
		for key, child := range record {
			out[key] = csCopy(child)
		}
		return out
	}
	if values, ok := csSlice(value); ok {
		out := make([]any, len(values))
		for i, child := range values {
			out[i] = csCopy(child)
		}
		return out
	}
	return value
}
func csAssign(target, source Map) {
	for key, value := range source {
		target[key] = csCopy(value)
	}
}

// SettingsAPI is the plugin settings boundary and owns the catalog used both by
// presentation and validation. Runtime admission still repeats capability checks
// against the exact connection that executes the turn.
type SettingsAPI struct {
	catalog *Catalog
}

var _ plugin.HarnessSettings = (*SettingsAPI)(nil)

func NewSettingsAPI(factory CatalogFactory) *SettingsAPI {
	return &SettingsAPI{catalog: NewCatalog(factory)}
}
func (s *SettingsAPI) InvalidateCatalog() { s.catalog.Invalidate() }
func (s *SettingsAPI) Normalize(raw json.RawMessage) (json.RawMessage, error) {
	settings, err := model.DecodeObject(raw)
	if err != nil {
		return nil, err
	}
	normalized, err := ValidateHarnessSettings(settings)
	if err != nil {
		return nil, err
	}
	return json.Marshal(normalized)
}
func (s *SettingsAPI) DefaultThread(raw json.RawMessage) (json.RawMessage, error) {
	normalized, err := s.Normalize(raw)
	if err != nil {
		return nil, err
	}
	value, err := model.DecodeObject(normalized)
	if err != nil {
		return nil, err
	}
	return json.Marshal(value["threadSettings"])
}
func (s *SettingsAPI) Describe(ctx context.Context, request plugin.SettingsRequest) (json.RawMessage, error) {
	if _, err := s.Normalize(request.Settings); err != nil {
		return nil, err
	}
	catalog, err := s.catalog.Load(ctx, request.Cwd, "")
	if err != nil {
		return nil, err
	}
	return json.Marshal(SettingsSchemaForModels(ccModels(catalog["models"])))
}
func (s *SettingsAPI) ResolveThread(ctx context.Context, request plugin.ResolveSettingsRequest) (json.RawMessage, error) {
	merged, err := model.DecodeObject(request.Merged)
	if err != nil {
		return nil, err
	}
	var existing, requested Map
	if !model.IsNull(request.Existing) {
		existing, err = model.DecodeObject(request.Existing)
		if err != nil {
			return nil, err
		}
	}
	if !model.IsNull(request.Requested) {
		requested, err = model.DecodeObject(request.Requested)
		if err != nil {
			return nil, err
		}
	}
	next, err := ResolveThreadSettings(merged, requested, existing)
	if err != nil {
		return nil, err
	}
	if err = s.validate(ctx, next, request.Cwd, "resolved settings", false); err != nil {
		return nil, err
	}
	return json.Marshal(next)
}
func (s *SettingsAPI) HasThreadContent(raw json.RawMessage) bool {
	state, err := model.DecodeObject(raw)
	return err == nil && HasThreadContent(state)
}
func (s *SettingsAPI) ApplyThreadUpdate(ctx context.Context, request plugin.UpdateSettingsRequest) (json.RawMessage, error) {
	current, err := model.DecodeObject(request.Current)
	if err != nil {
		return nil, err
	}
	update, err := model.DecodeObject(request.Update)
	if err != nil {
		return nil, err
	}
	next, err := UpdateThreadSettings(current, update)
	if err != nil {
		return nil, err
	}
	modelChanged := csHasAny(update, "model", "thinking", "serviceTier")
	if modelChanged || csHasAny(update, "permissionMode") {
		if err = s.validate(ctx, next, request.Cwd, "updated settings", !modelChanged); err != nil {
			return nil, err
		}
	}
	return json.Marshal(next)
}
func (s *SettingsAPI) PromptSettings(harness, source json.RawMessage) (json.RawMessage, error) {
	settings, err := model.DecodeObject(harness)
	if err != nil {
		return nil, err
	}
	var thread Map
	if !model.IsNull(source) {
		thread, err = model.DecodeObject(source)
		if err != nil {
			return nil, err
		}
	}
	out, err := PromptSettings(settings, thread)
	if err != nil {
		return nil, err
	}
	return json.Marshal(out)
}
func (s *SettingsAPI) Presentation(ctx context.Context, request plugin.SettingsPresentationRequest) (json.RawMessage, error) {
	if _, err := s.Normalize(request.Settings); err != nil {
		return nil, err
	}
	configured := ""
	if !model.IsNull(request.ThreadSettings) {
		thread, err := model.DecodeObject(request.ThreadSettings)
		if err != nil {
			return nil, err
		}
		configured = csString(thread["executablePath"])
	}
	presentation, err := s.catalog.LoadPresentation(ctx, request.Cwd, configured, request.Refresh)
	if err != nil {
		return nil, err
	}
	return json.Marshal(presentation)
}
func (s *SettingsAPI) SnapshotExecution(ctx context.Context, request plugin.SettingsRequest, initial bool) (json.RawMessage, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	settings, err := model.DecodeObject(request.Settings)
	if err != nil {
		return nil, err
	}
	normalized, err := ValidateHarnessSettings(settings)
	if err != nil {
		return nil, err
	}
	current, _ := csRecord(normalized["threadSettings"])
	if !initial && normalized["useDefaultThreadSettings"] != false {
		return nil, fmt.Errorf("Codex execution settings are not pinned")
	}
	var observed Map
	if initial {
		observed, err = s.catalog.LoadExecutionDefaults(ctx, request.Cwd, "")
	} else {
		observed, err = s.catalog.Load(ctx, request.Cwd, "")
	}
	if err != nil {
		return nil, err
	}
	config, _ := csRecord(observed["configuration"])
	models := ccModels(observed["models"])
	configuredModel := csString(config["model"])
	selectedID := csString(current["model"])
	if selectedID == "" && initial {
		selectedID = configuredModel
		if selectedID == "" {
			defaults := []Map{}
			for _, candidate := range models {
				if candidate["isDefault"] == true {
					defaults = append(defaults, candidate)
				}
			}
			if len(defaults) == 1 {
				selectedID = csString(defaults[0]["value"])
			}
		}
	}
	var selected Map
	for _, candidate := range models {
		if candidate["value"] == selectedID {
			selected = candidate
			break
		}
	}
	if selected == nil {
		return nil, fmt.Errorf("Codex execution settings cannot confirm exact model %q", selectedID)
	}
	effort := csString(current["effort"])
	if choice, exists := current["thinking"]; exists {
		effort, err = ThinkingEffort(choice)
		if err != nil {
			return nil, err
		}
	} else if effort == "" && initial {
		thinking, _ := csRecord(selected["thinking"])
		if thinking["kind"] != "fixed" {
			if configuredModel == "" || configuredModel == selectedID {
				effort = csString(config["model_reasoning_effort"])
			}
			if effort == "" {
				effort = csString(selected["defaultReasoningEffort"])
			}
		}
	}
	tier := csString(current["serviceTier"])
	if tier == "" && initial {
		tier = csString(config["service_tier"])
		if tier == "" {
			if value, exists := selected["defaultServiceTier"]; exists {
				if value == nil {
					tier = "default"
				} else {
					tier = csString(value)
				}
			}
		}
	}
	permission := csString(current["permissionMode"])
	if permission == "" && initial {
		permission = DefaultPermissionMode
	}
	if permission == "" {
		return nil, fmt.Errorf("Codex execution settings require an explicit permission mode")
	}
	thread := Map{"model": selectedID, "permissionMode": permission}
	if effort != "" {
		thread["effort"] = effort
	}
	if tier != "" {
		thread["serviceTier"] = tier
	}
	csAssign(thread, PermissionPreset(permission))
	if choice, exists := current["thinking"]; exists {
		explicit := Map{"model": selectedID, "thinking": choice}
		if tier != "" {
			explicit["serviceTier"] = tier
		}
		if _, err = ValidateModelSettings(models, explicit, "execution settings"); err != nil {
			return nil, err
		}
	}
	if _, err = ValidateExecutionModelSettings(models, thread, "execution settings"); err != nil {
		return nil, err
	}
	if err = s.validate(ctx, thread, request.Cwd, "execution settings", true); err != nil {
		return nil, err
	}
	return json.Marshal(Map{"useDefaultThreadSettings": false, "threadSettings": thread})
}
func (s *SettingsAPI) validate(ctx context.Context, settings Map, cwd, label string, autoReviewOnly bool) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	configured := csString(settings["executablePath"])
	if settings["approvalsReviewer"] == "auto_review" {
		supported, err := s.catalog.ProbeAutoReview(ctx, cwd, configured)
		if err != nil {
			return err
		}
		if !supported {
			return fmt.Errorf("Codex approve-for-me is unavailable: target runtime does not support or forbids auto_review")
		}
	}
	if !autoReviewOnly && csHasAny(settings, "model", "effort", "thinking", "serviceTier") {
		catalog, err := s.catalog.Load(ctx, cwd, configured)
		if err != nil {
			return err
		}
		_, err = ValidateModelSettings(ccModels(catalog["models"]), settings, label)
		return err
	}
	return nil
}
