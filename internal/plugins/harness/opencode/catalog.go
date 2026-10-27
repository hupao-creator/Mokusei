package opencode

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"math"
	"math/big"
	"net/http"
	"net/url"
	"regexp"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

type CatalogVariant struct {
	ID                         string `json:"id"`
	Settings                   Object `json:"settings,omitempty"`
	Body                       Object `json:"body,omitempty"`
	ExclusiveUnavailableReason string `json:"exclusiveUnavailableReason,omitempty"`
}
type CatalogModel struct {
	Provider                   string                    `json:"provider"`
	ID                         string                    `json:"id"`
	ModelID                    string                    `json:"modelID,omitempty"`
	Name                       string                    `json:"name"`
	Package                    string                    `json:"package,omitempty"`
	Settings                   Object                    `json:"settings"`
	Body                       Object                    `json:"body"`
	Variants                   []CatalogVariant          `json:"variants"`
	Input                      []string                  `json:"input"`
	Output                     []string                  `json:"output"`
	HasRequestOverrides        bool                      `json:"hasRequestOverrides,omitempty"`
	UnavailableReason          string                    `json:"unavailableReason,omitempty"`
	ExclusiveUnavailableReason string                    `json:"exclusiveUnavailableReason,omitempty"`
	Thinking                   *model.ThinkingCapability `json:"thinking,omitempty"`
}
type CatalogAgent struct {
	ID                  string       `json:"id"`
	Name                string       `json:"name"`
	Description         string       `json:"description,omitempty"`
	Mode                string       `json:"mode"`
	Model               *NativeModel `json:"model,omitempty"`
	Body                Object       `json:"body,omitempty"`
	HasRequestOverrides bool         `json:"hasRequestOverrides,omitempty"`
}
type CatalogNativeVariant struct {
	ID       string `json:"id"`
	Settings Object `json:"settings,omitempty"`
	Body     Object `json:"body,omitempty"`
	Headers  Object `json:"headers,omitempty"`
}
type CatalogNativeModel struct {
	ID           string                 `json:"id"`
	ModelID      string                 `json:"modelID"`
	ProviderID   string                 `json:"providerID"`
	Name         string                 `json:"name"`
	Package      string                 `json:"package,omitempty"`
	Settings     Object                 `json:"settings,omitempty"`
	Body         Object                 `json:"body,omitempty"`
	Headers      Object                 `json:"headers,omitempty"`
	Cost         []Object               `json:"cost,omitempty"`
	Variants     []CatalogNativeVariant `json:"variants"`
	Capabilities struct {
		Input  []string `json:"input"`
		Output []string `json:"output"`
		Tools  bool     `json:"tools"`
	} `json:"capabilities"`
	Enabled bool `json:"enabled"`
}
type CatalogNativeAgent struct {
	ID          string       `json:"id"`
	Name        string       `json:"name"`
	Description string       `json:"description,omitempty"`
	Mode        string       `json:"mode"`
	Hidden      bool         `json:"hidden"`
	Model       *NativeModel `json:"model,omitempty"`
	Request     struct {
		Body    Object `json:"body,omitempty"`
		Headers Object `json:"headers,omitempty"`
	} `json:"request"`
}
type CatalogNativeProvider struct {
	ID       string `json:"id"`
	Package  string `json:"package,omitempty"`
	Settings Object `json:"settings,omitempty"`
	Body     Object `json:"body,omitempty"`
	Headers  Object `json:"headers,omitempty"`
}
type CatalogSelection struct {
	Provider string `json:"provider"`
	Model    string `json:"model"`
	Variant  string `json:"variant,omitempty"`
}
type CatalogSnapshot struct {
	AccountCheckPending bool
	ExecutablePath      string
	Version             string
	Models              []CatalogModel
	Agents              []CatalogAgent
	DefaultAgent        string
	DefaultModel        *CatalogSelection
	NativeAccounts      map[string]bool `json:"-"`
	ExcludedModels      map[string]string
	NativeModels        []CatalogNativeModel    `json:"-"`
	Providers           []CatalogNativeProvider `json:"-"`
}
type catalogConfigDocument struct {
	Type string `json:"type"`
	Info struct {
		Model any `json:"model"`
	} `json:"info"`
}

func ModelKey(provider, id string) string { return provider + "\x00" + id }

func readCatalog(ctx context.Context, host plugin.HostContext, runtime *Runtime, nativeComplete func(*CatalogSnapshot) error, beforeBilling func() error) (*CatalogSnapshot, error) {
	var models []CatalogNativeModel
	var agents []CatalogNativeAgent
	var providers []CatalogNativeProvider
	var defaultModel *CatalogNativeModel
	var configuration []catalogConfigDocument
	requests := []struct {
		path   string
		output any
	}{{"/api/model", &models}, {"/api/agent", &agents}, {"/api/provider", &providers}, {"/api/model/default", &defaultModel}, {"/api/config", &configuration}}
	errorsByRequest := make([]error, len(requests))
	var pending sync.WaitGroup
	for i, request := range requests {
		pending.Add(1)
		go func(i int, path string, out any) {
			defer pending.Done()
			errorsByRequest[i] = runtime.Request(ctx, "GET", path, nil, out)
		}(i, request.path, request.output)
	}
	pending.Wait()
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	for _, err := range errorsByRequest {
		if err != nil {
			return nil, err
		}
	}
	value := &CatalogSnapshot{ExecutablePath: runtime.ExecutablePath, Version: runtime.Version, Models: []CatalogModel{}, Agents: []CatalogAgent{}, NativeAccounts: map[string]bool{}, ExcludedModels: map[string]string{}, NativeModels: models, Providers: providers}
	agentOverridesAccount := false
	for _, agent := range agents {
		if !agent.Hidden && agent.Mode != "subagent" && (hasCatalogAccountHeader(agent.Request.Headers) || hasCatalogField(agent.Request.Body, "model")) {
			agentOverridesAccount = true
		}
		if !agent.Hidden && agent.Mode != "subagent" {
			value.Agents = append(value.Agents, CatalogAgentFromNative(agent))
		}
	}
	var facts []catalogAccountFact
	projected := make([]*CatalogModel, len(models))
	nativeAccounts := make([]bool, len(models))
	factResults := make([]*catalogAccountFact, len(models))
	discoveryErrors := make([]error, len(models))
	slots := make(chan struct{}, 8)
	for index, native := range models {
		if !native.Enabled || !native.Capabilities.Tools || !slices.Contains(native.Capabilities.Input, "text") {
			continue
		}
		pending.Add(1)
		go func(index int, native CatalogNativeModel) {
			defer pending.Done()
			select {
			case slots <- struct{}{}:
			case <-ctx.Done():
				discoveryErrors[index] = ctx.Err()
				return
			}
			defer func() { <-slots }()
			var provider *CatalogNativeProvider
			for i := range providers {
				if providers[i].ID == native.ProviderID {
					provider = &providers[i]
					break
				}
			}
			var credential *ProviderCredential
			var err error
			credential, err = runtime.ReadProviderCredential(ctx, native.ProviderID, native.ID, "")
			if err != nil {
				if ctx.Err() != nil {
					discoveryErrors[index] = ctx.Err()
					return
				}
				credential = &ProviderCredential{}
			}

			if !agentOverridesAccount && hasKnownPaidCost(native, provider) {
				fact := catalogAccountFact{key: ModelKey(native.ProviderID, native.ID), providerID: native.ProviderID, modelID: native.ID, credential: credential}
				var headers Object
				if provider != nil {
					headers = provider.Headers
				}
				fact.expectedOrgID, fact.conflictingOrgHeaders = sourceOrganization(headers, native.Headers)
				factResults[index] = &fact
			}
			nativeAccount, err := usesNativeAccount(ctx, host, provider, &native, credential)
			if err != nil {
				discoveryErrors[index] = err
				return
			}
			nativeAccounts[index] = nativeAccount
			safe := CatalogModelFromNative(native)
			if provider != nil && hasIdentityOverride(provider.Body) {
				safe.HasRequestOverrides = true
			}
			base := ""
			if credential != nil {
				base = credential.BaseURL
			}
			safe.ExclusiveUnavailableReason = NativeExclusiveReason(native, provider, base, "")
			for i, variant := range native.Variants {
				effective := credential
				if variantOverridesAccount(variant) {
					var err error
					effective, err = runtime.ReadProviderCredential(ctx, native.ProviderID, native.ID, variant.ID)
					if err != nil {
						if ctx.Err() != nil {
							discoveryErrors[index] = ctx.Err()
							return
						}
						effective = &ProviderCredential{}
					}
				}
				base = ""
				if effective != nil {
					base = effective.BaseURL
				}
				safe.Variants[i].ExclusiveUnavailableReason = NativeExclusiveReason(native, provider, base, variant.ID)
			}

			thinking := ThinkingCapability(safe)
			safe.Thinking = &thinking
			projected[index] = &safe
		}(index, native)
	}
	pending.Wait()
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}
	for index, safe := range projected {
		if discoveryErrors[index] != nil {
			return nil, discoveryErrors[index]
		}
		if safe == nil {
			continue
		}
		value.Models = append(value.Models, *safe)
		value.NativeAccounts[ModelKey(safe.Provider, safe.ID)] = nativeAccounts[index]
		if factResults[index] != nil {
			facts = append(facts, *factResults[index])
		}
	}
	for _, entry := range configuration {
		if entry.Type == "document" {
			if entry.Info.Model != nil {
				value.DefaultModel = parseCatalogSelection(entry.Info.Model)
			}
		}
	}
	// Agent.list places the resolved native default first, including defaults
	// supplied by native plugins rather than an explicit default_agent setting.
	if len(value.Agents) > 0 {
		value.DefaultAgent = value.Agents[0].ID
	}
	if value.DefaultModel == nil && defaultModel != nil {
		value.DefaultModel = &CatalogSelection{Provider: defaultModel.ProviderID, Model: defaultModel.ID}
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	// Optional account evidence cannot invalidate the already observed catalog.
	if nativeComplete != nil {
		// The remaining phase only replaces Models and mutates these maps.
		// Detach them before exposing the native catalog to presentation readers.
		preliminary := *value
		preliminary.AccountCheckPending = len(facts) > 0
		preliminary.NativeAccounts = make(map[string]bool, len(value.NativeAccounts))
		for key, native := range value.NativeAccounts {
			preliminary.NativeAccounts[key] = native
		}
		preliminary.ExcludedModels = map[string]string{}
		if err := nativeComplete(&preliminary); err != nil {
			return nil, err
		}
	}
	leaseBudget, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	for i := range facts {
		pending.Add(1)
		go func(i int) {
			defer pending.Done()
			account, err := runtime.ReadConsoleAccount(leaseBudget, facts[i].providerID, facts[i].modelID, "")
			if err == nil {
				facts[i].account = account
			}
		}(i)
	}
	pending.Wait()
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}
	if beforeBilling != nil {
		if err := beforeBilling(); err != nil {
			return nil, err
		}
	}
	if err := filterUnavailableAccounts(ctx, value, facts); err != nil {
		return nil, err
	}
	return value, nil
}

func CatalogModelFromNative(native CatalogNativeModel) CatalogModel {
	value := CatalogModel{Provider: native.ProviderID, ID: native.ID, ModelID: native.ModelID, Name: native.Name, Package: native.Package, Settings: safeCatalogSettings(native.Settings), Body: safeCatalogBody(native.Body, false), Variants: []CatalogVariant{}, Input: append([]string{}, native.Capabilities.Input...), Output: append([]string{}, native.Capabilities.Output...), HasRequestOverrides: hasIdentityOverride(native.Body)}
	for _, variant := range native.Variants {
		value.Variants = append(value.Variants, CatalogVariant{ID: variant.ID, Settings: safeCatalogSettings(variant.Settings), Body: safeCatalogBody(variant.Body, false)})
		if hasIdentityOverride(variant.Body) || hasCatalogField(variant.Settings, "baseURL", "apiKey") {
			value.HasRequestOverrides = true
		}
	}
	return value
}
func CatalogAgentFromNative(native CatalogNativeAgent) CatalogAgent {
	value := CatalogAgent{ID: native.ID, Name: native.Name, Description: native.Description, Mode: native.Mode, Model: native.Model, HasRequestOverrides: hasCatalogAuthenticationHeader(native.Request.Headers, false)}
	if native.Request.Body != nil {
		value.Body = safeCatalogBody(native.Request.Body, true)
	}
	return value
}
func parseCatalogSelection(value any) *CatalogSelection {
	if text, ok := value.(string); ok {
		provider, tail, exists := strings.Cut(text, "/")
		if !exists || provider == "" {
			return nil
		}
		parts := strings.Split(tail, "#")
		if parts[0] == "" {
			return nil
		}
		selection := &CatalogSelection{Provider: provider, Model: parts[0]}
		if len(parts) > 1 {
			selection.Variant = parts[1]
		}
		return selection
	}
	object := configRecord(value)
	if object == nil {
		return nil
	}
	return &CatalogSelection{Provider: str(object["providerID"]), Model: str(object["model"]), Variant: str(object["variant"])}
}
func scalarCatalogFields(value Object, keys ...string) Object {
	result := Object{}
	for _, key := range keys {
		switch item := value[key].(type) {
		case string, bool, float64, json.Number, int, int64:
			result[key] = item
		}
	}
	return result
}
func safeCatalogThinking(value any) Object {
	return scalarCatalogFields(configRecord(value), "type", "budgetTokens", "budget_tokens", "display")
}
func safeCatalogThinkingConfig(value any) Object {
	return scalarCatalogFields(configRecord(value), "includeThoughts", "thinkingLevel", "thinkingBudget")
}
func safeCatalogSettings(value Object) Object {
	result := scalarCatalogFields(value, "reasoningEffort", "effort", "enableThinking")
	if hasCatalogField(value, "thinking") {
		result["thinking"] = safeCatalogThinking(value["thinking"])
	}
	if hasCatalogField(value, "thinkingConfig") {
		result["thinkingConfig"] = safeCatalogThinkingConfig(value["thinkingConfig"])
	}
	if hasCatalogField(value, "reasoning") {
		result["reasoning"] = scalarCatalogFields(configRecord(value["reasoning"]), "effort", "enabled")
	}
	return result
}
func safeCatalogBody(value Object, identity bool) Object {
	result := scalarCatalogFields(value, "reasoning_effort", "enable_thinking", "thinking_budget")
	if hasCatalogField(value, "thinking") {
		result["thinking"] = safeCatalogThinking(value["thinking"])
	}
	if hasCatalogField(value, "reasoning") {
		result["reasoning"] = scalarCatalogFields(configRecord(value["reasoning"]), "effort", "enabled")
	}
	if hasCatalogField(value, "output_config") {
		result["output_config"] = scalarCatalogFields(configRecord(value["output_config"]), "effort")
	}
	if hasCatalogField(value, "generationConfig") {
		result["generationConfig"] = Object{"thinkingConfig": safeCatalogThinkingConfig(configRecord(value["generationConfig"])["thinkingConfig"])}
	}
	if hasCatalogField(value, "chat_template_kwargs") {
		result["chat_template_kwargs"] = Object{}
	}
	if identity && hasIdentityOverride(value) {
		result["model"] = true
	}
	return result
}
func hasCatalogField(value Object, keys ...string) bool {
	for _, key := range keys {
		if _, exists := value[key]; exists {
			return true
		}
	}
	return false
}
func hasIdentityOverride(value Object) bool {
	return hasCatalogField(value, "model", "messages", "input", "tools", "tool_choice")
}
func hasCatalogAuthenticationHeader(headers Object, proxy bool) bool {
	for key := range headers {
		switch strings.ToLower(key) {
		case "authorization", "x-api-key", "api-key":
			return true
		case "proxy-authorization":
			if proxy {
				return true
			}
		}
	}
	return false
}
func hasCatalogAccountHeader(headers Object) bool {
	if hasCatalogAuthenticationHeader(headers, true) {
		return true
	}
	for key := range headers {
		if strings.EqualFold(key, "x-org-id") || strings.EqualFold(key, "x-opencode-org-id") {
			return true
		}
	}
	return false
}
func variantOverridesAccount(variant CatalogNativeVariant) bool {
	return hasCatalogField(variant.Settings, "baseURL", "apiKey", "headers") || hasCatalogAccountHeader(variant.Headers)
}
func hasKnownPaidCost(native CatalogNativeModel, provider *CatalogNativeProvider) bool {
	if len(native.Cost) == 0 || hasCatalogAuthenticationHeader(native.Headers, true) || hasCatalogField(native.Settings, "headers") || hasCatalogField(native.Body, "model") {
		return false
	}
	if provider != nil && (hasCatalogAuthenticationHeader(provider.Headers, true) || hasCatalogField(provider.Settings, "headers") || hasCatalogField(provider.Body, "model")) {
		return false
	}
	for _, variant := range native.Variants {
		if variantOverridesAccount(variant) || hasCatalogField(variant.Body, "model") {
			return false
		}
	}
	positive := false
	for _, cost := range native.Cost {
		cache := configRecord(cost["cache"])
		for _, raw := range []any{cost["input"], cost["output"], cache["read"], cache["write"]} {
			value, ok := raw.(float64)
			if !ok || math.IsNaN(value) || math.IsInf(value, 0) || value < 0 {
				return false
			}
			positive = positive || value > 0
		}
	}
	return positive
}

const ExclusiveModelReason = "该 OpenCode 免费模型可用于保留原生工具的普通任务和线程问答，但不支持 Moku 或独占工具的元数据生成。请选择其他已配置的 Host 或模型；不会自动改用付费模型。"

func NativeExclusiveReason(native CatalogNativeModel, provider *CatalogNativeProvider, baseURL, variantID string) string {
	if native.ProviderID != "opencode" || provider == nil || provider.ID != "opencode" || len(native.Cost) == 0 {
		return ""
	}
	packageName := native.Package
	if packageName == "" {
		packageName = provider.Package
	}
	if !slices.Contains([]string{"@opencode/ai/providers/openai-compatible", "@opencode/ai/providers/openai", "@opencode/ai/providers/anthropic"}, packageName) {
		return ""
	}
	for _, cost := range native.Cost {
		cache := configRecord(cost["cache"])
		for _, raw := range []any{cost["input"], cost["output"], cache["read"], cache["write"]} {
			value, ok := raw.(float64)
			if !ok || value != 0 {
				return ""
			}
		}
	}
	var overlay Object
	if variantID != "" && variantID != "default" {
		found := false
		for _, variant := range native.Variants {
			if variant.ID == variantID {
				overlay = variant.Body
				found = true
				break
			}
		}
		if !found {
			return ""
		}
	}
	if hasIdentityOverride(provider.Body) || hasIdentityOverride(native.Body) || hasIdentityOverride(overlay) {
		return ""
	}
	if officialCatalogURL(baseURL, "/zen/v1") {
		return ExclusiveModelReason
	}
	return ""
}
func ExclusiveReason(native CatalogModel, variantID string, agent *CatalogAgent) string {
	if agent != nil && (agent.HasRequestOverrides || configTruthy(agent.Body["model"])) {
		return ""
	}
	if variantID != "" && variantID != "default" {
		for _, variant := range native.Variants {
			if variant.ID == variantID {
				return variant.ExclusiveUnavailableReason
			}
		}
		return ""
	}
	return native.ExclusiveUnavailableReason
}
func officialCatalogURL(raw string, paths ...string) bool {
	u, err := url.Parse(raw)
	if err != nil || !strings.EqualFold(u.Scheme, "https") || !strings.EqualFold(u.Hostname(), "opencode.ai") || (u.Port() != "" && u.Port() != "443") || u.User != nil || u.RawQuery != "" || u.ForceQuery || u.Fragment != "" {
		return false
	}
	return slices.Contains(paths, strings.TrimSuffix(u.EscapedPath(), "/"))
}
func officialPaidEndpoint(raw string) bool {
	return officialCatalogURL(raw, "/zen/v1", "/zen/go/v1", "/inference/openai/v1", "/inference/anthropic/v1", "/inference/google/v1beta")
}

type catalogAccountFact struct {
	key, providerID, modelID, expectedOrgID string
	conflictingOrgHeaders                   bool
	credential                              *ProviderCredential
	account                                 *ConsoleAccount
}

var orgIDPattern = regexp.MustCompile(`^(org|wrk)_[A-Za-z0-9_-]+$`)

func sourceOrganization(sources ...Object) (string, bool) {
	expected := ""
	for _, source := range sources {
		for key, value := range source {
			if !strings.EqualFold(key, "x-org-id") && !strings.EqualFold(key, "x-opencode-org-id") {
				continue
			}
			id, ok := value.(string)
			if !ok || !orgIDPattern.MatchString(id) || (expected != "" && id != expected) {
				return "", true
			}
			expected = id
		}
	}
	return expected, false
}

type consoleAccountStatus struct{ subscription, balance string }

func filterUnavailableAccounts(ctx context.Context, snapshot *CatalogSnapshot, facts []catalogAccountFact) error {
	budget, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	type billingRequest struct {
		token, org, expected string
		keys                 []string
		status               consoleAccountStatus
	}
	requests := map[string]*billingRequest{}
	for _, fact := range facts {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if fact.conflictingOrgHeaders || (fact.account != nil && fact.expectedOrgID != "" && fact.expectedOrgID != fact.account.OrgID) {
			continue
		}
		key, token, org, expected := "", "", "", fact.expectedOrgID
		authenticated := false
		if fact.account != nil {
			if fact.account.Server != "https://opencode.ai/console" || !orgIDPattern.MatchString(fact.account.OrgID) {
				continue
			}
			token, org, expected = fact.account.AccessToken, fact.account.OrgID, fact.account.OrgID
			key = "oauth\x00" + fact.account.Server + "\x00" + org + "\x00" + token
			authenticated = true
		} else if fact.credential != nil && officialPaidEndpoint(fact.credential.BaseURL) && strings.TrimSpace(fact.credential.APIKey) != "" && strings.TrimSpace(fact.credential.APIKey) != "public" {
			token = fact.credential.APIKey
			key = "api-key\x00" + token + "\x00" + expected
			authenticated = true
		}
		if authenticated {
			request := requests[key]
			if request == nil {
				request = &billingRequest{token: token, org: org, expected: expected}
				requests[key] = request
			}
			request.keys = append(request.keys, fact.key)
			continue
		}
		if fact.credential != nil && fact.credential.Authentication != "oauth" && officialPaidEndpoint(fact.credential.BaseURL) && (strings.TrimSpace(fact.credential.APIKey) == "" || strings.TrimSpace(fact.credential.APIKey) == "public") {
			snapshot.ExcludedModels[fact.key] = "当前 OpenCode 官方模型路由未配置付费凭据。请在 OpenCode 中配置账号后刷新模型列表。"
		}
	}
	var pending sync.WaitGroup
	for _, request := range requests {
		pending.Add(1)
		go func(request *billingRequest) {
			defer pending.Done()
			request.status = readConsoleAccountStatus(budget, request.token, request.org, request.expected)
		}(request)
	}
	pending.Wait()
	for _, request := range requests {
		if request.status.subscription == "absent" && request.status.balance == "empty" {
			for _, key := range request.keys {
				snapshot.ExcludedModels[key] = "当前 OpenCode 账号没有 Go 订阅，且该组织的预付余额已用尽。请在 OpenCode 中切换账号、订阅或充值后刷新模型列表。"
			}
		}
	}
	if ctx.Err() != nil {
		return ctx.Err()
	}
	models := make([]CatalogModel, 0, len(snapshot.Models))
	for _, entry := range snapshot.Models {
		key := ModelKey(entry.Provider, entry.ID)
		if snapshot.ExcludedModels[key] == "" {
			models = append(models, entry)
		} else {
			delete(snapshot.NativeAccounts, key)
		}
	}
	snapshot.Models = models
	return nil
}
func readConsoleAccountStatus(ctx context.Context, token, org, expected string) consoleAccountStatus {
	unknown := consoleAccountStatus{"unknown", "unknown"}
	if strings.TrimSpace(token) == "" || strings.TrimSpace(token) == "public" || (expected != "" && !orgIDPattern.MatchString(expected)) {
		return unknown
	}
	client := &http.Client{Timeout: 10 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return errors.New("redirect refused") }}
	defer client.CloseIdleConnections()
	results := make([]Object, 2)
	var pending sync.WaitGroup
	for i, path := range []string{"/api/billing/status", "/api/orgs/current"} {
		pending.Add(1)
		go func(i int, path string) {
			defer pending.Done()
			req, err := http.NewRequestWithContext(ctx, "GET", "https://opencode.ai/console"+path, nil)
			if err != nil {
				return
			}
			req.Header.Set("Authorization", "Bearer "+token)
			req.Header.Set("Accept", "application/json")
			req.Header.Set("User-Agent", "Mokusei/0.1")
			req.Header.Set("Cache-Control", "no-store")
			if org != "" {
				req.Header.Set("x-org-id", org)
			}
			response, err := client.Do(req)
			if err != nil {
				return
			}
			defer response.Body.Close()
			if response.StatusCode < 200 || response.StatusCode >= 300 {
				return
			}
			_ = json.NewDecoder(io.LimitReader(response.Body, 1<<20)).Decode(&results[i])
		}(i, path)
	}
	pending.Wait()
	current := results[1]
	orgID := str(configRecord(current["org"])["id"])
	if !orgIDPattern.MatchString(orgID) || (expected != "" && orgID != expected) {
		return unknown
	}
	result := unknown
	if current["hasGoSubscription"] == true {
		result.subscription = "present"
	} else if current["hasGoSubscription"] == false {
		result.subscription = "absent"
	}
	result.balance = prepaidBalance(results[0])
	return result
}

var integerLedgerPattern = regexp.MustCompile(`^[+-]?\d+$`)

func prepaidBalance(value Object) string {
	balance, ok := value["balanceMicroCents"].(string)
	if value["billingMode"] != "prepaid" || value["mode"] != "pay-as-you-go" || !ok || !integerLedgerPattern.MatchString(balance) {
		return "unknown"
	}
	number, ok := new(big.Int).SetString(balance, 10)
	if !ok {
		return "unknown"
	}
	if number.Sign() > 0 {
		return "positive"
	}
	available, ok := value["availableMicroCents"].(string)
	if !ok || !integerLedgerPattern.MatchString(available) {
		return "unknown"
	}
	number, ok = new(big.Int).SetString(available, 10)
	if !ok || number.Sign() > 0 {
		return "unknown"
	}
	return "empty"
}
