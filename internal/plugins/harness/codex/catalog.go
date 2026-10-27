package codex

import (
	"context"
	"errors"
	"fmt"
	"github.com/hupao-creator/Mokusei/internal/platform/discovery"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

type CatalogTransport interface {
	Call(context.Context, string, any) (Map, error)
}
type CatalogFactory func(context.Context, string, string) (*AppServer, error)
type catalogEntry struct {
	at                 time.Time
	generation         uint64
	models             []Map
	modelsError        error
	computerUse        bool
	configuration      Map
	configurationError error
	autoReview         bool
	autoReviewError    error
	cli                Map
}
type Catalog struct {
	factory    CatalogFactory
	identity   func(context.Context, string, string) (string, error)
	mu         sync.Mutex
	generation uint64
	reads      discovery.Cache[catalogEntry]
}

func NewCatalog(factory CatalogFactory) *Catalog { return &Catalog{factory: factory} }
func (c *Catalog) Invalidate()                   { c.mu.Lock(); c.generation++; c.mu.Unlock() }
func (c *Catalog) Close() error                  { return c.reads.Close() }
func (c *Catalog) Load(ctx context.Context, cwd, configured string) (Map, error) {
	entry, err := c.observe(ctx, cwd, configured)
	if err != nil {
		return nil, err
	}
	if entry.modelsError != nil {
		return nil, entry.modelsError
	}
	return Map{"models": csCopy(entry.models), "computerUse": entry.computerUse}, nil
}
func (c *Catalog) LoadPresentation(ctx context.Context, cwd, configured string, refresh bool) (Map, error) {
	entry, err := c.observe(ctx, cwd, configured, refresh)
	if err != nil {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return Map{"cli": Map{"available": false, "error": err.Error()}, "models": []Map{}}, nil
	}
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}
	out := Map{"cli": csCopy(entry.cli), "models": csCopy(entry.models)}
	if entry.modelsError != nil {
		out["modelsError"] = entry.modelsError.Error()
	}
	return out, nil
}

// The probe is shared, but cancellation belongs to each reader. A cancelled
// settings panel cannot abort another reader's model admission check.
var errIncompleteCatalog = errors.New("native catalog is incomplete")

func (c *Catalog) observe(ctx context.Context, cwd, configured string, refresh ...bool) (catalogEntry, error) {
	key := configured + "\x00" + cwd
	identity := ""
	if c.identity != nil {
		var err error
		identity, err = c.identity(ctx, cwd, configured)
		if err != nil {
			return catalogEntry{}, err
		}
		key += "\x00" + identity
	}
	c.mu.Lock()
	generation := c.generation
	c.mu.Unlock()
	key += fmt.Sprintf("\x00%d", generation)
	entry, err := c.reads.Get(ctx, key, len(refresh) > 0 && refresh[0], 5*time.Minute, 60*time.Second, func(shared context.Context) (catalogEntry, error) {
		value, err := c.probe(shared, cwd, configured, generation)
		if err == nil && c.identity != nil {
			current, sourceErr := c.identity(shared, cwd, configured)
			if sourceErr != nil {
				return catalogEntry{}, sourceErr
			}
			if current != identity {
				return catalogEntry{}, errors.New("Codex native configuration changed during discovery")
			}
		}
		if err == nil {
			if value.modelsError != nil || value.configurationError != nil || value.autoReviewError != nil {
				err = errIncompleteCatalog
			}
		}
		return value, err
	})
	// Partial native facts remain useful to their own projection, but do not
	// earn the successful cache TTL or turn a failed defaults read into success.
	if errors.Is(err, errIncompleteCatalog) && !errors.Is(err, context.Canceled) && !errors.Is(err, context.DeadlineExceeded) {
		err = nil
	}
	return entry, err
}
func (c *Catalog) probe(ctx context.Context, cwd, configured string, generation uint64) (entry catalogEntry, err error) {
	if c.factory == nil {
		return catalogEntry{}, fmt.Errorf("Codex model catalog has no target runtime")
	}
	server, err := c.factory(ctx, cwd, configured)
	if err != nil {
		return catalogEntry{}, err
	}
	defer func() { err = errors.Join(err, discovery.Cleanup(server.Close())) }()
	entry = catalogEntry{at: time.Now(), generation: generation, models: []Map{}, cli: Map{"available": true, "executable": server.launch.Executable}}
	var wg sync.WaitGroup
	wg.Add(4)
	go func() {
		defer wg.Done()
		entry.models, entry.modelsError = ListModels(ctx, server)
		if entry.modelsError == nil && len(entry.models) == 0 {
			entry.modelsError = fmt.Errorf("Codex model catalog is empty")
		}
		if entry.models == nil {
			entry.models = []Map{}
		}
	}()
	go func() { defer wg.Done(); entry.computerUse, _ = SupportsComputerUse(ctx, server, cwd) }()
	go func() {
		defer wg.Done()
		limited, cancel := context.WithTimeout(ctx, 7500*time.Millisecond)
		defer cancel()
		entry.configuration, entry.configurationError = ReadThreadConfiguration(limited, server, cwd)
		if entry.configurationError == nil {
			entry.autoReview, entry.autoReviewError = supportsAutoReviewConfiguration(limited, server, server.initialized, entry.configuration)
		}
	}()
	go func() {
		defer wg.Done()
		version, e := server.launch.Version, error(nil)
		if version == "" {
			version, e = ReadCodexVersion(ctx, server.launch.Executable, server.launch.Environment)
		}
		if e == nil {
			entry.cli["version"] = version
		} else {
			entry.cli["available"] = false
			entry.cli["error"] = e.Error()
		}
	}()
	wg.Wait()
	if err := ctx.Err(); err != nil {
		return catalogEntry{}, err
	}
	if entry.cli["available"] != true {
		return entry, errors.New("Codex executable version could not be confirmed")
	}
	return entry, nil
}
func (c *Catalog) LoadExecutionDefaults(ctx context.Context, cwd, configured string) (Map, error) {
	entry, err := c.observe(ctx, cwd, configured)
	if err != nil {
		return nil, err
	}
	if err := errors.Join(entry.configurationError, entry.modelsError); err != nil {
		return nil, err
	}
	return Map{"configuration": csCopy(entry.configuration), "models": csCopy(entry.models)}, nil
}
func (c *Catalog) ProbeAutoReview(ctx context.Context, cwd, configured string) (bool, error) {
	entry, err := c.observe(ctx, cwd, configured)
	if err != nil {
		return false, err
	}
	return entry.autoReview, errors.Join(entry.configurationError, entry.autoReviewError)
}

func ListModels(ctx context.Context, transport CatalogTransport) ([]Map, error) {
	response, err := transport.Call(ctx, "model/list", Map{"limit": 100, "includeHidden": false})
	if err != nil {
		return nil, err
	}
	models := []Map{}
	for _, raw := range csArray(response["data"]) {
		model, ok := csRecord(raw)
		if !ok {
			continue
		}
		id, name := csString(model["model"]), csString(model["displayName"])
		if id == "" || name == "" {
			continue
		}
		efforts := []Map{}
		levels := []string{}
		rawEfforts, reported := csSlice(model["supportedReasoningEfforts"])
		for _, entry := range rawEfforts {
			item, _ := csRecord(entry)
			value := csString(item["reasoningEffort"])
			if value == "" {
				continue
			}
			level := Map{"value": value}
			if description := csString(item["description"]); description != "" {
				level["description"] = description
			}
			efforts = append(efforts, level)
			levels = append(levels, value)
		}
		tiers := []Map{}
		for _, entry := range csArray(model["serviceTiers"]) {
			item, _ := csRecord(entry)
			id := csString(item["id"])
			if id == "" {
				continue
			}
			tier := Map{"value": id}
			if name := csString(item["name"]); name != "" {
				tier["displayName"] = name
			}
			tiers = append(tiers, tier)
		}
		thinking := NativeThinkingCapability(levels, reported, model["supportsReasoning"])
		out := Map{"value": id, "displayName": name, "thinking": thinking, "supportedReasoningEfforts": efforts, "serviceTiers": tiers}
		for _, key := range []string{"description", "defaultReasoningEffort"} {
			if value := csString(model[key]); value != "" {
				out[key] = value
			}
		}
		if model["isDefault"] == true {
			out["isDefault"] = true
		}
		if value, exists := model["defaultServiceTier"]; exists && (value == nil || csString(value) != "") {
			out["defaultServiceTier"] = value
		}
		models = append(models, out)
	}
	return models, nil
}
func NativeThinkingCapability(efforts []string, reported bool, supportsReasoning any) Map {
	if supportsReasoning == false {
		return Map{"kind": "fixed"}
	}
	if len(efforts) == 0 {
		reason := "Codex reported no reasoning levels without confirming a fixed thinking control"
		if !reported {
			reason = "Codex omitted the model's supported reasoning levels"
		}
		return Map{"kind": "unknown", "reason": reason}
	}
	supported := []string{}
	for _, effort := range efforts {
		if effort != "none" && effort != "default" && effort != "" && effort == strings.TrimSpace(effort) && !csContains(supported, effort) {
			supported = append(supported, effort)
		}
	}
	if len(supported) == 0 {
		return Map{"kind": "unknown", "reason": "Codex did not report an encodable enabled reasoning level"}
	}
	return Map{"kind": "effort", "efforts": supported, "canDisable": csContains(efforts, "none")}
}
func SelectModel(models []Map, requested string) Map {
	normalized := strings.ToLower(strings.TrimSpace(requested))
	if normalized == "" || normalized == "codex-default" {
		for _, model := range models {
			if model["isDefault"] == true {
				return model
			}
		}
		if len(models) > 0 {
			return models[0]
		}
		return nil
	}
	for _, model := range models {
		if strings.EqualFold(strings.TrimSpace(csString(model["value"])), normalized) {
			return model
		}
	}
	return nil
}
func ValidateModelSettings(models []Map, settings Map, label string) (Map, error) {
	requested := csString(settings["model"])
	var selected Map
	if raw, explicit := settings["thinking"]; explicit {
		if requested == "" || requested != strings.TrimSpace(requested) || csContains([]string{"default", "codex-default"}, strings.ToLower(requested)) {
			return nil, fmt.Errorf("Codex %s requires an exact model and explicit thinking choice", label)
		}
		if _, exists := settings["effort"]; exists {
			return nil, fmt.Errorf("Codex %s must use thinking, not legacy effort", label)
		}
		for _, candidate := range models {
			if candidate["value"] == requested {
				selected = candidate
				break
			}
		}
		if selected == nil {
			return nil, fmt.Errorf("Codex %s selected unknown model: %s", label, requested)
		}
		thinking, err := NormalizeThinkingChoice(raw)
		if err != nil {
			return nil, err
		}
		capability, _ := csRecord(selected["thinking"])
		kind, mode := csString(capability["kind"]), csString(thinking["mode"])
		supported := (kind == "fixed" && mode == "fixed") || (kind == "effort" && ((mode == "off" && capability["canDisable"] == true) || (mode == "effort" && ccIncludes(capability["efforts"], csString(thinking["effort"]))))) || (kind == "toggle" && (mode == "on" || mode == "off"))
		if !supported {
			return nil, fmt.Errorf("Codex model %s thinking choice is unsupported: %s", requested, csString(capability["reason"]))
		}
	} else {
		selected = SelectModel(models, requested)
	}
	if selected == nil {
		return nil, fmt.Errorf("Codex %s cannot resolve model %q", label, requested)
	}
	if effort := csString(settings["effort"]); effort != "" && !ccOptionsInclude(selected["supportedReasoningEfforts"], effort) {
		return nil, fmt.Errorf("Codex model %s does not report support for effort %s", selected["value"], effort)
	}
	if tier := csString(settings["serviceTier"]); tier != "" && tier != "default" && !ccOptionsInclude(selected["serviceTiers"], tier) {
		return nil, fmt.Errorf("Codex model %s does not report support for service tier %s", selected["value"], tier)
	}
	return selected, nil
}
func ValidateExecutionModelSettings(models []Map, settings Map, label string) (Map, error) {
	id := csString(settings["model"])
	if id == "" || csContains([]string{"default", "codex-default"}, strings.ToLower(id)) {
		return nil, fmt.Errorf("Codex %s requires an exact model", label)
	}
	if csString(settings["serviceTier"]) == "" {
		return nil, fmt.Errorf("Codex %s requires an explicit service tier", label)
	}
	model, err := ValidateModelSettings(models, settings, label)
	if err != nil {
		return nil, err
	}
	if _, exists := settings["thinking"]; exists {
		return model, nil
	}
	thinking, _ := csRecord(model["thinking"])
	if thinking["kind"] == "fixed" {
		if _, exists := settings["effort"]; exists {
			return nil, fmt.Errorf("Codex model %s does not support configurable effort", id)
		}
		return model, nil
	}
	if thinking["kind"] != "effort" {
		return nil, fmt.Errorf("Codex model %s thinking capability is unconfirmed", id)
	}
	effort := csString(settings["effort"])
	if effort == "" || (effort == "none" && thinking["canDisable"] != true) || (effort != "none" && !ccIncludes(thinking["efforts"], effort)) {
		return nil, fmt.Errorf("Codex %s requires an explicit supported effort", label)
	}
	return model, nil
}
func ReadThreadConfiguration(ctx context.Context, transport CatalogTransport, cwd string) (Map, error) {
	response, err := transport.Call(ctx, "config/read", Map{"cwd": cwd, "includeLayers": false})
	if err != nil {
		return nil, err
	}
	config, _ := csRecord(response["config"])
	out := Map{}
	for _, key := range []string{"model", "model_provider", "model_providers", "model_reasoning_effort", "model_context_window", "model_auto_compact_token_limit", "model_reasoning_summary", "service_tier", "personality", "approval_policy", "approvals_reviewer", "sandbox_mode", "sandbox_workspace_write"} {
		if value, exists := config[key]; exists && value != nil {
			out[key] = csCopy(value)
		}
	}
	// Isolated homes must retain the user's native network route without
	// inheriting feature flags that could reopen exclusive tool surfaces.
	features, _ := csRecord(config["features"])
	proxyFeatures := Map{}
	for _, key := range []string{"respect_system_proxy", "system_proxy_fallback"} {
		if value, ok := features[key].(bool); ok {
			proxyFeatures[key] = value
		}
	}
	if len(proxyFeatures) > 0 {
		out["features"] = proxyFeatures
	}
	return out, nil
}
func SupportsAutoReview(ctx context.Context, transport CatalogTransport, cwd string, initialized Map) (bool, error) {
	version := regexp.MustCompile(`/((\d+)\.(\d+)\.(\d+)(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?)(?:[\s(]|$)`).FindStringSubmatch(csString(initialized["userAgent"]))
	if len(version) < 5 {
		return false, nil
	}
	major, _ := strconv.Atoi(version[2])
	minor, _ := strconv.Atoi(version[3])
	patch, _ := strconv.Atoi(version[4])
	if !(major > 0 || minor > 153 || minor == 153 && patch >= 4) {
		return false, nil
	}
	limited, cancel := context.WithTimeout(ctx, 7500*time.Millisecond)
	defer cancel()
	config, err := ReadThreadConfiguration(limited, transport, cwd)
	if err != nil {
		if ctx.Err() != nil {
			return false, ctx.Err()
		}
		return false, nil
	}
	return supportsAutoReviewConfiguration(limited, transport, initialized, config)
}
func supportsAutoReviewConfiguration(ctx context.Context, transport CatalogTransport, initialized, config Map) (bool, error) {
	version := regexp.MustCompile(`/((\d+)\.(\d+)\.(\d+)(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?)(?:[\s(]|$)`).FindStringSubmatch(csString(initialized["userAgent"]))
	if len(version) < 5 {
		return false, nil
	}
	major, _ := strconv.Atoi(version[2])
	minor, _ := strconv.Atoi(version[3])
	patch, _ := strconv.Atoi(version[4])
	if !(major > 0 || minor > 153 || minor == 153 && patch >= 4) {
		return false, nil
	}
	if config["approvals_reviewer"] != "user" && config["approvals_reviewer"] != "auto_review" {
		return false, nil
	}
	constraints, err := transport.Call(ctx, "configRequirements/read", Map{})
	if err != nil {
		if ctx.Err() != nil {
			return false, ctx.Err()
		}
		return false, nil
	}
	requirements, ok := csRecord(constraints["requirements"])
	if constraints["requirements"] != nil && !ok {
		return false, nil
	}
	allowed, exists := requirements["allowedApprovalsReviewers"]
	return !exists || allowed == nil || ccIncludes(allowed, "auto_review"), nil
}
func SupportsComputerUse(ctx context.Context, transport CatalogTransport, cwd string) (bool, error) {
	limited, cancel := context.WithTimeout(ctx, 7500*time.Millisecond)
	defer cancel()
	response, err := transport.Call(limited, "plugin/installed", Map{"cwds": []string{cwd}})
	if err != nil {
		return false, err
	}
	for _, raw := range csArray(response["marketplaces"]) {
		market, _ := csRecord(raw)
		for _, entry := range csArray(market["plugins"]) {
			plugin, _ := csRecord(entry)
			name, id := strings.ToLower(strings.TrimSpace(csString(plugin["name"]))), strings.ToLower(strings.TrimSpace(csString(plugin["id"])))
			if (name == "computer-use" || id == "computer-use" || strings.HasPrefix(id, "computer-use@")) && plugin["installed"] == true && plugin["enabled"] == true && strings.EqualFold(strings.TrimSpace(csString(plugin["availability"])), "AVAILABLE") {
				return true, nil
			}
		}
	}
	return false, nil
}
func HasNativeSubscription(ctx context.Context, transport CatalogTransport) (bool, error) {
	response, err := transport.Call(ctx, "account/read", Map{"refreshToken": false})
	if err != nil {
		return false, err
	}
	account, _ := csRecord(response["account"])
	return account["type"] == "chatgpt", nil
}
func ccIncludes(raw any, value string) bool {
	for _, candidate := range csArray(raw) {
		if csString(candidate) == value {
			return true
		}
	}
	return false
}
func ccOptionsInclude(raw any, value string) bool {
	for _, candidate := range csArray(raw) {
		option, _ := csRecord(candidate)
		if option["value"] == value {
			return true
		}
	}
	return false
}
func ccModels(raw any) []Map {
	out := []Map{}
	for _, value := range csArray(raw) {
		if model, ok := csRecord(value); ok {
			out = append(out, model)
		}
	}
	return out
}
