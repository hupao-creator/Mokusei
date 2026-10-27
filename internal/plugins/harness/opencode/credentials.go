package opencode

import (
	"encoding/json"
	"errors"
	"math"
	"regexp"
	"strings"
	"time"
)

// ConsoleAccount is transient: never serialize it into session or UI state.
type ConsoleAccount struct {
	ExpiresAt   time.Time `json:"-"`
	AccessToken string    `json:"accessToken"`
	Server      string    `json:"server"`
	OrgID       string    `json:"orgID"`
}

type ProviderCredential struct {
	BaseURL        string `json:"baseUrl,omitempty"`
	APIKey         string `json:"apiKey,omitempty"`
	Authentication string `json:"authentication,omitempty"`
}

func credentialObject(value any) map[string]any { result, _ := value.(map[string]any); return result }
func credentialString(value any) string         { result, _ := value.(string); return result }
func cloneCredentialObject(value map[string]any) map[string]any {
	data, _ := json.Marshal(value)
	var result map[string]any
	_ = json.Unmarshal(data, &result)
	return result
}

func validLeaseMetadata(value map[string]any) bool {
	metadata, exists := value["metadata"]
	return !exists || credentialObject(metadata) != nil
}

func credentialExpiry(value any) (int64, bool) {
	var f float64
	switch n := value.(type) {
	case float64:
		f = n
	case int64:
		f = float64(n)
	case int:
		f = float64(n)
	case json.Number:
		var err error
		f, err = n.Float64()
		if err != nil {
			return 0, false
		}
	default:
		return 0, false
	}
	if math.IsNaN(f) || math.IsInf(f, 0) || f < 0 || f > 9007199254740991 || math.Trunc(f) != f {
		return 0, false
	}
	return int64(f), true
}

func ParseOAuthLease(input any) (map[string]any, error) {
	value := credentialObject(input)
	_, hasRefresh := value["refresh"]
	expires, validExpiry := credentialExpiry(value["expires"])
	if value == nil || value["type"] != "oauth" || hasRefresh || !validExpiry ||
		credentialString(value["methodID"]) == "" || credentialString(value["access"]) == "" || !validLeaseMetadata(value) {
		return nil, errors.New("OpenCode returned an invalid Console OAuth access lease")
	}
	lease := map[string]any{"type": "oauth", "methodID": value["methodID"], "access": value["access"], "expires": expires}
	if metadata := credentialObject(value["metadata"]); metadata != nil {
		lease["metadata"] = cloneCredentialObject(metadata)
	}
	return lease, nil
}

var consoleOrgPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$`)

func ParseConsoleAccount(input any) (*ConsoleAccount, error) {
	value := credentialObject(input)
	if value != nil && len(value) == 0 {
		return nil, nil
	}
	if value == nil || len(value) != 3 || strings.TrimSpace(credentialString(value["accessToken"])) == "" || value["server"] != "https://opencode.ai/console" || !consoleOrgPattern.MatchString(credentialString(value["orgID"])) {
		return nil, errors.New("OpenCode returned an invalid Console account lease")
	}
	return &ConsoleAccount{AccessToken: value["accessToken"].(string), Server: value["server"].(string), OrgID: value["orgID"].(string)}, nil
}
