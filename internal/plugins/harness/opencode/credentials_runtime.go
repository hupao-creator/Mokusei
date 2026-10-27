package opencode

import (
	"context"
	"errors"
	"strings"
	"time"
)

func (runtime *Runtime) ReadProviderCredential(ctx context.Context, providerID, modelID, variant string) (*ProviderCredential, error) {
	input := map[string]any{"providerID": providerID}
	if modelID != "" {
		input["modelID"] = modelID
	}
	if variant != "" {
		input["variant"] = variant
	}
	var value map[string]any
	if err := runtime.RPC(ctx, "credential", input, &value); err != nil {
		return nil, err
	}
	if value == nil {
		return nil, errors.New("OpenCode returned invalid provider credential facts")
	}
	result := &ProviderCredential{BaseURL: credentialString(value["baseUrl"]), APIKey: credentialString(value["apiKey"])}
	if value["authentication"] == "oauth" {
		result.Authentication = "oauth"
	}
	return result, nil
}

// Console account facts are resolved by this same native server, only after the
// effective model route has been validated. Refresh grants never cross RPC.
func (runtime *Runtime) ReadConsoleAccount(ctx context.Context, providerID, modelID, variant string) (*ConsoleAccount, error) {
	if modelID == "" {
		return nil, nil
	}
	input := Object{"providerID": providerID, "modelID": modelID, "variant": variant, "phase": "describe"}
	var facts Object
	if err := runtime.RPC(ctx, "consoleAccount", input, &facts); err != nil {
		return nil, err
	}
	route, _ := describeConsoleRoute(facts, providerID, modelID, variant)
	if route == "" || str(facts["sourceCredentialID"]) == "" {
		return nil, nil
	}
	input["sourceCredentialID"], input["phase"] = facts["sourceCredentialID"], "lease"
	var raw Object
	if err := runtime.RPC(ctx, "consoleAccount", input, &raw); err != nil {
		return nil, err
	}
	if len(raw) == 0 {
		return nil, nil
	}
	lease, err := ParseOAuthLease(raw["lease"])
	if err != nil {
		return nil, err
	}
	metadata := object(lease["metadata"])
	server := str(metadata["server"])
	if _, exists := metadata["server"]; !exists {
		server = "https://opencode.ai/console"
	}
	if !validConsoleServer(server) || hasCredentialOverride(metadata) || hasCredentialOverride(object(raw["configuration"])) {
		return nil, nil
	}
	orgID := str(metadata["orgID"])
	if !consoleOrgPattern.MatchString(orgID) {
		return nil, nil
	}
	input["phase"] = "describe"
	facts = nil
	if err = runtime.RPC(ctx, "consoleAccount", input, &facts); err != nil {
		return nil, err
	}
	currentRoute, headers := describeConsoleRoute(facts, providerID, modelID, variant)
	if currentRoute != route {
		return nil, nil
	}
	for name, value := range headers {
		if (strings.EqualFold(name, "x-org-id") || strings.EqualFold(name, "x-opencode-org-id")) && value != orgID {
			return nil, nil
		}
	}
	account, err := ParseConsoleAccount(Object{"accessToken": lease["access"], "server": "https://opencode.ai/console", "orgID": orgID})
	if err == nil {
		account.ExpiresAt = time.UnixMilli(lease["expires"].(int64))
	}
	return account, err
}
