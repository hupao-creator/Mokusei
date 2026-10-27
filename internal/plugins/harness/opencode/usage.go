package opencode

import (
	"context"
	"encoding/json"
	"net/url"
	"regexp"
	"strings"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/opencode/accounttelemetry"
)

var authHeaderPattern = regexp.MustCompile(`(?i)authorization|api[-_]?key|token`)

func usageAttribution(ctx context.Context, runtime *Runtime, session, id, provider, modelID string) []string {
	keys := []string{}
	if runtime == nil || provider == "" {
		return keys
	}
	var message Object
	if runtime.Request(ctx, "GET", sessionPath(session, "/message/"+url.PathEscape(id)), nil, &message) != nil || message["type"] != "assistant" {
		return keys
	}
	agentID := str(message["agent"])
	if agentID == "" {
		return keys
	}
	var agent Object
	if runtime.Request(ctx, "GET", "/api/agent/"+url.PathEscape(agentID), nil, &agent) != nil {
		return keys
	}
	request := object(agent["request"])
	for name := range object(request["headers"]) {
		if authHeaderPattern.MatchString(name) {
			return keys
		}
	}
	if object(request["body"])["model"] != nil {
		return keys
	}
	variant := str(object(message["model"])["variant"])
	credential, err := runtime.ReadProviderCredential(ctx, provider, modelID, variant)
	if err != nil || credential == nil || !accounttelemetry.IsOpenCodeGoEndpoint(credential.BaseURL) {
		return keys
	}
	return accounttelemetry.OpenCodeGoAttributionKeys(credential.APIKey)
}
func unknownTelemetry(note, availability string) Object {
	return Object{"source": "OpenCode account telemetry", "observedAt": time.Now().UnixMilli(), "availability": availability, "limitReached": nil, "windows": []any{}, "note": note}
}
func formatTelemetry(value Object) string {
	value = clone(value)
	value["namespace"] = "opencode"
	if at := number(value["observedAt"]); at != 0 {
		value["observedAt"] = time.UnixMilli(int64(at)).UTC().Format("2006-01-02T15:04:05.000Z")
	}
	for _, raw := range array(value["windows"]) {
		delete(object(raw), "usageAttribution")
	}
	raw, _ := json.Marshal(value)
	return string(raw)
}
func attachLedger(ctx context.Context, snapshot Object, ledger plugin.TelemetryLedger) error {
	if ledger == nil {
		return nil
	}
	windows := []Object{}
	for _, raw := range array(snapshot["windows"]) {
		window := object(raw)
		if window["metering"] == nil {
			continue
		}
		reading := Object{}
		for _, key := range []string{"id", "metering", "usageAttribution", "usedPercent", "usedUnits", "limitUnits", "resetsAt", "durationMinutes"} {
			if value, ok := window[key]; ok {
				reading[key] = value
			}
		}
		windows = append(windows, reading)
	}
	encoded, _ := json.Marshal(Object{"type": "window-reading", "observedAt": snapshot["observedAt"], "windows": windows})
	if err := ledger.Record(ctx, encoded); err != nil {
		return err
	}
	raw, err := ledger.Read(ctx)
	if err != nil {
		return err
	}
	var observed Object
	if err = json.Unmarshal(raw, &observed); err != nil {
		return err
	}
	byID := map[string]any{}
	for _, v := range array(observed["windows"]) {
		window := object(v)
		byID[str(window["id"])] = window["ledger"]
	}
	for _, v := range array(snapshot["windows"]) {
		window := object(v)
		if previous := byID[str(window["id"])]; previous != nil {
			window["ledger"] = previous
		}
	}
	return nil
}

type telemetryCacheEntry struct {
	at   time.Time
	text string
}

func (h *Harness) MokuContext(ctx context.Context, purpose string, request plugin.SettingsRequest, ledger plugin.TelemetryLedger) (string, error) {
	if err := ctx.Err(); err != nil {
		return "", err
	}
	if purpose != "telemetry" {
		return "", nil
	}
	key := request.Cwd + "\x00" + string(request.Settings)
	h.backgroundMu.Lock()
	cached, ok := h.telemetry[key]
	h.backgroundMu.Unlock()
	if !ok || time.Since(cached.at) >= 5*time.Minute {
		h.background("telemetry:"+key, func(life context.Context) {
			text, err := h.readTelemetry(life, request, ledger)
			if err == nil {
				h.backgroundMu.Lock()
				h.telemetry[key] = telemetryCacheEntry{at: time.Now(), text: text}
				h.backgroundMu.Unlock()
			}
		})
	}
	if ok {
		return cached.text, nil
	}
	return formatTelemetry(unknownTelemetry("Native account telemetry is refreshing in the background; account capacity is unknown.", "unknown")), nil
}
func (h *Harness) readTelemetry(ctx context.Context, request plugin.SettingsRequest, ledger plugin.TelemetryLedger) (string, error) {
	read := func() (string, error) {
		settings, err := h.settings.defaults(request.Settings)
		if err != nil {
			return "", err
		}
		snapshot, err := h.settings.observe(ctx, settings, request.Cwd, false)
		if err != nil {
			return "", err
		}
		selected, err := SelectModel(snapshot, settings)
		if err != nil {
			return "", err
		}
		if selected.Model.HasRequestOverrides || selected.Agent != nil && (selected.Agent.HasRequestOverrides || selected.Agent.Body["model"] != nil) {
			return formatTelemetry(unknownTelemetry("Native request overrides prevent establishing which account serves the selected model. Account capacity is unknown.", "unavailable")), nil
		}
		settings.ExecutablePath = snapshot.ExecutablePath
		runtime, err := h.launch(ctx, settings, request.Cwd, false)
		if err != nil {
			return "", err
		}
		defer runtime.Close()
		credential, err := runtime.ReadProviderCredential(ctx, selected.Model.Provider, selected.Model.ID, selected.Variant)
		if err != nil {
			return "", err
		}
		if credential == nil || (!accounttelemetry.IsOpenCodeGoEndpoint(credential.BaseURL) && !(credential.Authentication == "oauth" && selected.Model.Provider == "opencode-go")) {
			return formatTelemetry(unknownTelemetry("This native model does not expose verified OpenCode Go account capacity.", "unknown")), nil
		}
		var raw json.RawMessage
		if credential.Authentication == "oauth" {
			account, accountErr := runtime.ReadConsoleAccount(ctx, selected.Model.Provider, selected.Model.ID, selected.Variant)
			if accountErr != nil {
				return "", accountErr
			}
			if account == nil {
				return formatTelemetry(unknownTelemetry("The selected model has no verified native Console OAuth account. Account capacity is unknown.", "unknown")), nil
			}
			raw, err = accounttelemetry.ReadConsoleGoTelemetry(ctx, accounttelemetry.ClientOptions{}, accounttelemetry.ConsoleAccount{
				AccessToken: account.AccessToken, OrgID: account.OrgID, ExpiresAt: account.ExpiresAt,
			})
		} else {
			raw, err = accounttelemetry.ReadOpenCodeGoTelemetry(ctx, accounttelemetry.ClientOptions{}, credential.BaseURL, credential.APIKey)
		}
		if err != nil {
			return "", err
		}
		var telemetry Object
		if err = json.Unmarshal(raw, &telemetry); err != nil {
			return "", err
		}
		if err = attachLedger(ctx, telemetry, ledger); err != nil {
			return "", err
		}
		return formatTelemetry(telemetry), nil
	}
	result, err := read()
	if err != nil {
		if ctx.Err() != nil {
			return "", ctx.Err()
		}
		return formatTelemetry(unknownTelemetry("OpenCode account usage could not be resolved.", "error")), nil
	}
	if strings.TrimSpace(result) == "" {
		return formatTelemetry(unknownTelemetry("This native model does not expose OpenCode Go account capacity.", "unavailable")), nil
	}
	return result, nil
}
