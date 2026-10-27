package accounttelemetry

import (
	"net/url"
	"strings"
)

func IsOpenCodeGoEndpoint(value string) bool { return OfficialOpenCodeGoEndpoint(value, false) }
func OfficialOpenCodeGoEndpoint(value string, allowMessages bool) bool {
	u, err := url.Parse(value)
	if err != nil {
		return false
	}
	path := strings.TrimSuffix(u.Path, "/")
	return strings.EqualFold(u.Scheme, "https") && strings.EqualFold(u.Hostname(), "opencode.ai") && (u.Port() == "" || u.Port() == "443") && u.User == nil && u.RawQuery == "" && !u.ForceQuery && u.Fragment == "" && u.RawPath == "" && (path == "/zen/go/v1" || path == "/inference/go/openai/v1" || (allowMessages && (path == "/zen/go" || path == "/inference/go/anthropic")))
}
