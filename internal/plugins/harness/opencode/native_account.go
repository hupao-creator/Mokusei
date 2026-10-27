package opencode

import (
	"context"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"strings"
)

func hostEnvironment(ctx context.Context, host plugin.HostContext) (map[string]string, error) {
	env := inheritedEnvironment(nil)
	if host.Environment != nil {
		var err error
		env, err = host.Environment(ctx)
		if err != nil {
			return nil, err
		}
		env = inheritedEnvironment(env)
	}
	return env, nil
}

func usesNativeAccount(ctx context.Context, host plugin.HostContext, provider *CatalogNativeProvider, native *CatalogNativeModel, credential *ProviderCredential) (bool, error) {
	if provider == nil {
		return false, nil
	}
	settings := copyConfigObject(provider.Settings)
	if native != nil {
		settings = shallowConfigMerge(settings, native.Settings)
	}
	env := inheritedEnvironment(nil)
	if host.Environment != nil {
		var err error
		env, err = host.Environment(ctx)
		if err != nil {
			return false, err
		}
	}
	base := settings["baseURL"]
	if credential != nil {
		base = credential.BaseURL
	}
	baseURL := resolveProviderValue(base, env)
	if baseURL == "" {
		return false, nil
	}
	return isNativeProviderEndpoint(provider.ID, baseURL), nil
}

func isNativeProviderEndpoint(provider, baseURL string) bool {
	if provider != "opencode" && provider != "opencode-go" {
		return false
	}
	scope := ""
	if provider == "opencode-go" {
		scope = "/go"
	}
	return officialCatalogURL(baseURL, "/zen"+scope, "/zen"+scope+"/v1", "/inference"+scope+"/openai/v1", "/inference"+scope+"/anthropic/v1", "/inference"+scope+"/google/v1beta")
}

func resolveProviderValue(raw any, env map[string]string) string {
	value, ok := raw.(string)
	if !ok {
		return ""
	}
	missing := false
	value = substitutionPattern.ReplaceAllStringFunc(value, func(match string) string {
		parts := substitutionPattern.FindStringSubmatch(match)
		if parts[1] != "env" {
			return match
		}
		found := env[parts[2]]
		if found == "" {
			missing = true
		}
		return found
	})
	if missing || value == "" || strings.Contains(value, "{env:") || strings.Contains(value, "{file:") {
		return ""
	}
	return value
}
