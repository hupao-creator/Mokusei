package opencode

import (
	"net/url"
	"strings"
)

func hasCredentialOverride(value map[string]any) bool {
	for _, key := range []string{"baseURL", "apiKey", "headers"} {
		if _, ok := value[key]; ok {
			return true
		}
	}
	return false
}

func validConsoleServer(raw string) bool {
	u, err := url.Parse(raw)
	return err == nil && u.Scheme == "https" && u.Host == "opencode.ai" && strings.TrimSuffix(u.Path, "/") == "/console" && u.RawPath == "" && u.User == nil && u.RawQuery == "" && u.Fragment == "" && !u.ForceQuery
}

func officialInferenceRoute(raw string) string {
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "https" || u.Host != "opencode.ai" || u.RawPath != "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" || u.ForceQuery {
		return ""
	}
	path := strings.TrimSuffix(u.Path, "/")
	switch path {
	case "/inference/openai/v1", "/inference/anthropic/v1", "/inference/google/v1beta",
		"/inference/go/openai/v1", "/inference/go/anthropic", "/zen/go/v1":
		return "https://opencode.ai" + path
	}
	return ""
}

func consoleAccountOverrides(layer map[string]any) bool {
	settings := credentialObject(layer["settings"])
	for _, key := range []string{"apiKey", "headers"} {
		if _, ok := settings[key]; ok {
			return true
		}
	}
	for name := range credentialObject(layer["headers"]) {
		switch strings.ToLower(name) {
		case "authorization", "proxy-authorization", "x-api-key", "api-key":
			return true
		}
	}
	body := credentialObject(layer["body"])
	for _, key := range []string{"model", "messages", "input", "tools", "tool_choice"} {
		if _, ok := body[key]; ok {
			return true
		}
	}
	return false
}

func describeConsoleRoute(facts map[string]any, providerID, modelID, variantID string) (string, map[string]any) {
	provider, model, variant := credentialObject(facts["provider"]), credentialObject(facts["model"]), credentialObject(facts["variant"])
	if provider["integrationID"] != "opencode" || provider["id"] != providerID || model["providerID"] != providerID || model["id"] != modelID {
		return "", nil
	}
	if variantID != "" && variantID != "default" && variant["id"] != variantID {
		return "", nil
	}
	pkg := credentialString(model["package"])
	if pkg == "" {
		pkg = credentialString(provider["package"])
	}
	switch pkg {
	case "@opencode/ai/providers/openai-compatible", "@opencode/ai/providers/openai", "@opencode/ai/providers/anthropic", "@opencode/ai/providers/google":
	default:
		return "", nil
	}
	route := officialInferenceRoute(credentialString(credentialObject(provider["settings"])["baseURL"]))
	if route == "" {
		return "", nil
	}
	headers := make(map[string]any)
	for _, layer := range []map[string]any{provider, model, variant} {
		if consoleAccountOverrides(layer) {
			return "", nil
		}
		settings := credentialObject(layer["settings"])
		if raw, exists := settings["baseURL"]; exists && officialInferenceRoute(credentialString(raw)) != route {
			return "", nil
		}
		for key, value := range credentialObject(layer["headers"]) {
			headers[key] = value
		}
	}
	return route, headers
}
