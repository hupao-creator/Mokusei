package accounttelemetry

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"net/http"
	"strings"
	"time"
)

// ConsoleAccount contains only the native account facts needed for telemetry.
type ConsoleAccount struct {
	AccessToken string    `json:"-"`
	OrgID       string    `json:"-"`
	ExpiresAt   time.Time `json:"-"`
}
type consoleWorkspaceClient struct {
	client HTTPClient
	org    string
}

func (c consoleWorkspaceClient) Do(r *http.Request) (*http.Response, error) {
	if r.URL.Scheme != "https" || r.URL.Host != "opencode.ai" || !strings.HasPrefix(r.URL.Path, "/console/api/") {
		return nil, errors.New("Console OAuth telemetry refuses a foreign route")
	}
	request := r.Clone(r.Context())
	request.Header.Set("x-org-id", c.org)
	request.Header.Set("x-opencode-org-id", c.org)
	return c.client.Do(request)
}

// ReadConsoleGoTelemetry keeps Console OAuth distinct from workspace API-key
// usage. Only server-reported access meters establish subscription windows.
func ReadConsoleGoTelemetry(ctx context.Context, host ClientOptions, credentials ConsoleAccount) (json.RawMessage, error) {
	host = normalizeOptions(host)
	org := credentials.OrgID
	if !organizationPattern.MatchString(org) || strings.TrimSpace(credentials.AccessToken) == "" || !credentials.ExpiresAt.After(host.Now()) {
		return nil, errors.New("Console OAuth telemetry requires a live workspace lease")
	}
	host.HTTP = consoleWorkspaceClient{host.HTTP, org}
	status, current, err := readJSON(ctx, host, "https://opencode.ai/console/api/orgs/current", credentials.AccessToken, 2500*time.Millisecond)
	if err != nil {
		return nil, err
	}
	if status != 200 || text(record(record(current)["org"])["id"]) != org {
		return nil, errors.New("Console OAuth workspace could not be verified")
	}
	account, statusPayload, err := readGoConsole(ctx, host, credentials.AccessToken)
	if err != nil {
		return nil, err
	}
	result := object{"source": "OpenCode Console OAuth", "observedAt": host.Now().UnixMilli(), "availability": "unknown", "windows": []object{}, "limitReached": nil,
		"note": "Console subscription meters are unknown. No API-key usage endpoint or other login was consulted."}
	if account != nil {
		result["plan"] = account["plan"]
		if balance := account["balance"]; balance != nil {
			result["balances"] = []any{balance}
		}
		result["console"] = account
		if account["accessActive"] == true && account["plan"] != nil {
			windows := consoleGoWindows(statusPayload, org, host.Now())
			result["windows"] = windows
			if len(windows) > 0 {
				result["availability"] = "available"
				result["note"] = "Server-reported Console Go subscription meters for this workspace. Subscription exhaustion does not establish exhaustion of free models or account balance. No API-key usage endpoint or other login was consulted."
			}
		}
	}
	return jsonValue(result), nil
}

// Console uses decimal integer strings, not the percentages returned by the
// legacy key endpoint. Derive ratios without rounding the micro-cent operands.
func consoleGoWindows(status object, org string, now time.Time) []object {
	meters := record(record(status["access"])["meters"])
	windows := []object{}
	// Workspace capacity survives token rotation and is shared by native readers. This identity is separate from API-key attribution.
	hash := sha256.Sum256([]byte("mokusei.opencode-console.workspace.v1:" + org))
	key := fmt.Sprintf("opencode-go:console:sha256:%x", hash)
	for _, definition := range []struct {
		field, id, label string
		minutes          float64
	}{
		{"fiveHour", "rolling", "OpenCode Go 5-hour subscription window", 300},
		{"week", "weekly", "OpenCode Go weekly subscription window", 10080},
		{"month", "monthly", "OpenCode Go monthly subscription window", 0},
	} {
		meter := record(meters[definition.field])
		parse := func(value any) *big.Int {
			s := text(value)
			if !microCentPattern.MatchString(s) {
				return nil
			}
			n, ok := new(big.Int).SetString(s, 10)
			if !ok || n.Sign() < 0 {
				return nil
			}
			return n
		}
		used, limit := parse(meter["usedMicroCents"]), parse(meter["limitMicroCents"])
		if used == nil || limit == nil || limit.Sign() <= 0 {
			continue
		}
		reset, hasReset := telemetryTime(meter["resetsAt"])
		// A five-hour window starts on first use; null dates with zero consumption
		// are authoritative unused capacity, not a fabricated reset timestamp.
		startValue, hasStart := meter["startsAt"]
		resetValue, hasResetField := meter["resetsAt"]
		unused := definition.field == "fiveHour" && used.Sign() == 0 && hasStart && startValue == nil && hasResetField && resetValue == nil
		if !hasReset && !unused {
			continue
		}
		ratio, _ := new(big.Rat).SetFrac(new(big.Int).Mul(used, big.NewInt(100)), limit).Float64()
		percent := rounded(min(100.0, ratio))
		window := object{"id": key + ":" + definition.id, "label": definition.label, "scope": "feature", "selector": "OpenCode Go subscription", "usageAttribution": object{"type": "matching", "keys": []string{key}}, "usedPercent": percent, "remainingPercent": rounded(100 - percent), "resetsAt": nil, "exhausted": used.Cmp(limit) >= 0, "quality": "exact", "confidence": "high", "metering": "monetary"}
		if hasReset {
			window["resetsAt"] = reset.UTC().Format("2006-01-02T15:04:05.000Z")
		}
		if definition.minutes > 0 {
			window["durationMinutes"] = definition.minutes
			if hasReset {
				if pace := calculatePace(percent, definition.minutes, reset, now); pace != nil {
					window["pace"] = pace
				}
			}
		}
		windows = append(windows, window)
	}
	return windows
}
