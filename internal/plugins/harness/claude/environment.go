package claude

import (
	"context"
	"os/exec"
	"runtime"
	"strings"
	"time"
)

// Native Claude settings may override inherited environment variables. Proxy
// values are applied at the same explicit session layer as provider settings.
func systemProxy(environment map[string]string) map[string]string {
	result := map[string]string{}
	for k, v := range environment {
		result[k] = v
	}
	if runtime.GOOS != "darwin" {
		return result
	}
	for _, key := range []string{"HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy"} {
		if result[key] != "" {
			return result
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "/usr/sbin/scutil", "--proxy").Output()
	if err != nil {
		return result
	}
	values := map[string]string{}
	for _, line := range strings.Split(string(out), "\n") {
		key, value, ok := strings.Cut(line, ":")
		if ok {
			values[strings.TrimSpace(key)] = strings.TrimSpace(value)
		}
	}
	for _, prefix := range []string{"HTTPS", "HTTP"} {
		if values[prefix+"Enable"] == "1" && values[prefix+"Proxy"] != "" {
			url := "http://" + values[prefix+"Proxy"]
			if port := values[prefix+"Port"]; port != "" {
				url += ":" + port
			}
			result[prefix+"_PROXY"] = url
		}
	}
	if result["HTTPS_PROXY"] != "" || result["HTTP_PROXY"] != "" {
		result["NO_PROXY"] = nonempty(result["NO_PROXY"], nonempty(result["no_proxy"], "127.0.0.1,localhost"))
	}
	return result
}
func proxySettings(environment map[string]string) map[string]string {
	result := map[string]string{}
	for _, key := range []string{"HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY", "NO_PROXY"} {
		if v := nonempty(environment[key], environment[strings.ToLower(key)]); v != "" {
			result[key] = v
		}
	}
	return result
}
func bareAuthentication(environment map[string]string) bool {
	if strings.TrimSpace(environment["ANTHROPIC_API_KEY"]) != "" {
		return true
	}
	for _, key := range []string{"CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY"} {
		if disabled(strings.TrimSpace(environment[key])) {
			return true
		}
	}
	return false
}
