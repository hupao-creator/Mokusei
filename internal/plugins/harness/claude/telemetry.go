package claude

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

func (h *Harness) MokuContext(ctx context.Context, purpose string, r plugin.SettingsRequest, ledger plugin.TelemetryLedger) (string, error) {
	if err := ctx.Err(); err != nil {
		return "", err
	}
	if purpose != "telemetry" {
		return "", nil
	}
	_, env, e := h.resolveEnvironment(ctx)
	if e != nil {
		return "", e
	}
	nativeAccount, e := usesNativeAccount(ctx, r.Cwd, env, "")
	if e != nil {
		if ctx.Err() != nil {
			return "", ctx.Err()
		}
		nativeAccount = false
	}
	if !nativeAccount {
		b, _ := json.Marshal(map[string]any{"namespace": "external-provider", "source": "Unresolved external model service", "observedAt": time.Now().UTC().Format(time.RFC3339Nano), "availability": "unknown", "windows": []any{}, "limitReached": nil, "note": "Account capacity is unknown. Do not substitute a Harness subscription quota."})
		return string(b), nil
	}
	snapshot, e := h.nativeTelemetry(ctx, r.Cwd, env)
	if e != nil {
		if ctx.Err() != nil {
			return "", ctx.Err()
		}
		snapshot = map[string]any{"source": "Claude Code get_usage", "observedAt": time.Now().UnixMilli(), "availability": "error", "plan": nil, "limitReached": nil, "windows": []any{}, "error": clip(e.Error(), 500), "note": "Claude native subscription quota could not be read; route as unknown capacity rather than unlimited capacity."}
	}
	if ledger != nil {
		reading := map[string]any{"type": "window-reading", "observedAt": snapshot["observedAt"], "windows": snapshot["windows"]}
		raw, _ := json.Marshal(reading)
		if e = ledger.Record(ctx, raw); e != nil {
			return "", e
		}
		raw, e = ledger.Read(ctx)
		if e != nil {
			return "", e
		}
		var stored map[string]any
		if json.Unmarshal(raw, &stored) == nil {
			byID := map[string]any{}
			for _, v := range arr(stored["windows"]) {
				m := obj(v)
				byID[str(m["id"])] = m["ledger"]
			}
			for _, v := range arr(snapshot["windows"]) {
				m := obj(v)
				if v, ok := byID[str(m["id"])]; ok {
					m["ledger"] = v
				}
			}
		}
	}
	snapshot["namespace"] = "claude"
	snapshot["observedAt"] = time.UnixMilli(int64(number(snapshot["observedAt"]))).UTC().Format(time.RFC3339Nano)
	raw, e := json.Marshal(snapshot)
	return string(raw), e
}
func (h *Harness) nativeTelemetry(ctx context.Context, cwd string, env map[string]string) (map[string]any, error) {
	path, _, e := h.resolve(ctx, cwd, "")
	if e != nil {
		return nil, e
	}
	t := NewTransport(TransportOptions{Executable: path, Cwd: cwd, Environment: env, SessionID: newID(), Settings: Settings{ExecutablePath: path}, ApplicationToolsOnly: true})
	defer t.Close()
	if _, e = t.Initialize(ctx); e != nil {
		return nil, e
	}
	response, e := t.Control(ctx, map[string]any{"subtype": "get_usage"})
	if e != nil {
		return nil, e
	}
	return normalizeTelemetry(obj(response), time.Now()), nil
}
func normalizeTelemetry(root map[string]any, now time.Time) map[string]any {
	snapshot := map[string]any{"source": "Claude Code get_usage", "observedAt": now.UnixMilli(), "availability": "unknown", "plan": root["subscription_type"], "limitReached": nil, "windows": []any{}, "note": "Claude returned no recognizable plan usage windows; do not assume Claude has unlimited capacity."}
	if root["rate_limits_available"] == false {
		snapshot["availability"] = "not_applicable"
		snapshot["note"] = "Claude plan windows are not exposed for this API-key, third-party, Bedrock, Vertex, or otherwise non-plan session. This does not prove unlimited capacity."
		return snapshot
	}
	windows := []any{}
	limits := obj(root["rate_limits"])
	keys := make([]string, 0, len(limits))
	for id := range limits {
		keys = append(keys, id)
	}
	sort.Strings(keys)
	for _, id := range keys {
		if id == "model_scoped" || id == "extra_usage" {
			continue
		}
		raw := obj(limits[id])
		if raw == nil {
			continue
		}
		scope := "provider"
		if regexp.MustCompile(`(?i)(opus|sonnet|haiku|fable|model)`).MatchString(id) {
			scope = "model"
		} else if regexp.MustCompile(`(?i)(oauth|app|overage|extra)`).MatchString(id) {
			scope = "feature"
		}
		duration := 0
		if strings.Contains(id, "five_hour") {
			duration = 300
		}
		if strings.Contains(id, "seven_day") {
			duration = 10080
		}
		attribution := map[string]any{"type": "unknown"}
		if id == "five_hour" || id == "seven_day" {
			attribution["type"] = "all"
		} else if m := regexp.MustCompile(`^seven_day_(opus|sonnet|haiku|fable)$`).FindStringSubmatch(id); len(m) == 2 {
			attribution = modelAttribution(m[1])
		}
		labels := map[string]string{"five_hour": "5-hour shared window", "seven_day": "7-day shared window", "seven_day_oauth_apps": "7-day OAuth apps window", "seven_day_opus": "7-day Opus window", "seven_day_sonnet": "7-day Sonnet window", "seven_day_overage_included": "7-day overage-included window"}
		window := telemetryWindow(id, nonempty(labels[id], humanize(id)), scope, humanize(strings.TrimPrefix(strings.TrimPrefix(id, "seven_day_"), "five_hour_")), duration, attribution, raw, now)
		if window != nil {
			windows = append(windows, window)
		}
	}
	for _, v := range arr(limits["model_scoped"]) {
		raw := obj(v)
		name := str(raw["display_name"])
		id := strings.Trim(regexp.MustCompile(`[^a-z0-9]+`).ReplaceAllString(strings.ToLower(name), "-"), "-")
		if id == "" {
			continue
		}
		window := telemetryWindow("model_scoped:"+id, name+" 7-day model window", "model", name, 10080, modelAttribution(name), raw, now)
		if window != nil {
			windows = append(windows, window)
		}
	}
	if len(windows) > 0 {
		snapshot["availability"] = "available"
		snapshot["windows"] = windows
		delete(snapshot, "note")
		known, unknown, exhausted := false, false, false
		for _, v := range windows {
			w := obj(v)
			if w["scope"] != "provider" {
				continue
			}
			known = true
			if w["exhausted"] == nil {
				unknown = true
			}
			if w["exhausted"] == true {
				exhausted = true
			}
		}
		if exhausted {
			snapshot["limitReached"] = true
		} else if known && !unknown {
			snapshot["limitReached"] = false
		}
	}
	return snapshot
}
func humanize(s string) string {
	return strings.Join(strings.Fields(strings.NewReplacer("_", " ", "-", " ").Replace(s)), " ")
}
func telemetryWindow(id, label, scope, selector string, duration int, attribution map[string]any, raw map[string]any, now time.Time) map[string]any {
	used, hasUsage := raw["utilization"].(float64)
	if !hasUsage || math.IsNaN(used) || math.IsInf(used, 0) || used < 0 {
		hasUsage = false
	}
	reset := telemetryTimestamp(raw["resets_at"])
	if !hasUsage && reset == "" {
		return nil
	}
	w := map[string]any{"id": id, "label": label, "scope": scope, "usageAttribution": attribution, "usedPercent": nil, "remainingPercent": nil, "resetsAt": nullable(reset), "exhausted": nil, "metering": "token"}
	if scope != "provider" {
		w["selector"] = selector
	}
	if duration > 0 {
		w["durationMinutes"] = duration
	}
	if hasUsage {
		used = math.Round(used*100) / 100
		w["usedPercent"] = used
		w["remainingPercent"] = math.Round(math.Max(0, 100-used)*100) / 100
		w["exhausted"] = used >= 100
		if pace := telemetryPace(used, duration, reset, now); pace != nil {
			w["pace"] = pace
		}
	}
	return w
}
func telemetryTimestamp(value any) string {
	if n, ok := value.(float64); ok {
		if n < 1e12 {
			n *= 1000
		}
		return time.UnixMilli(int64(n)).UTC().Format(time.RFC3339Nano)
	}
	s := str(value)
	if parsed, e := time.Parse(time.RFC3339Nano, s); e == nil {
		return parsed.UTC().Format(time.RFC3339Nano)
	}
	return ""
}
func telemetryPace(used float64, duration int, reset string, now time.Time) map[string]any {
	deadline, e := time.Parse(time.RFC3339Nano, reset)
	if e != nil || duration <= 0 {
		return nil
	}
	total := float64(duration) * 60
	left := deadline.Sub(now).Seconds()
	if left <= 0 || left > total {
		return nil
	}
	elapsed := total - left
	expected := elapsed / total * 100
	if expected < 3 {
		return nil
	}
	actual := math.Max(0, math.Min(100, used))
	delta := actual - expected
	stage := "on_pace"
	magnitude := math.Abs(delta)
	suffix := "under_pace"
	if delta > 0 {
		suffix = "over_pace"
	}
	if magnitude > 12 {
		stage = "far_" + suffix
	} else if magnitude > 6 {
		stage = suffix
	} else if magnitude > 2 {
		stage = "slightly_" + suffix
	}
	p := map[string]any{"expectedUsedPercent": math.Round(expected*100) / 100, "deltaPercent": math.Round(delta*100) / 100, "stage": stage, "willLastToReset": true, "etaSeconds": nil, "projectedExhaustionAt": nil, "sustainableRateMultiplier": nil}
	remaining := 100 - actual
	projected := actual * left / elapsed
	if remaining > 0 && projected > 0 {
		p["sustainableRateMultiplier"] = math.Round(remaining/projected*1000) / 1000
	}
	if actual > 0 {
		eta := remaining / (actual / elapsed)
		if actual >= 100 || eta < left {
			if actual >= 100 {
				eta = 0
			}
			p["willLastToReset"] = false
			p["etaSeconds"] = math.Max(0, math.Round(eta))
			p["projectedExhaustionAt"] = now.Add(time.Duration(math.Round(eta)) * time.Second).UTC().Format(time.RFC3339Nano)
		}
	}
	return p
}

var familyFirst = regexp.MustCompile(`^(?:claude-)?(opus|sonnet|haiku|fable)(?:-(\d+(?:-\d+)?))?$`)
var versionFirst = regexp.MustCompile(`^claude-(\d+(?:-\d+)?)-(opus|sonnet|haiku|fable)$`)

func modelIdentity(name string) (string, string) {
	name = strings.ToLower(strings.TrimSpace(name))
	name = regexp.MustCompile(`[.\s_]+`).ReplaceAllString(name, "-")
	name = regexp.MustCompile(`-\d{8}$`).ReplaceAllString(name, "")
	name = strings.TrimSuffix(name, "-latest")
	if m := familyFirst.FindStringSubmatch(name); len(m) > 0 {
		return m[1], m[2]
	}
	if m := versionFirst.FindStringSubmatch(name); len(m) > 0 {
		return m[2], m[1]
	}
	return "", ""
}
func modelAttribution(name string) map[string]any {
	family, version := modelIdentity(name)
	if family == "" {
		return map[string]any{"type": "unknown"}
	}
	key := "family:" + family
	if version != "" {
		key = "model:" + family + ":" + version
	}
	return map[string]any{"type": "matching", "keys": []string{key}}
}
func usageAttribution(name string) []string {
	family, version := modelIdentity(name)
	keys := []string{}
	if family != "" {
		keys = append(keys, "family:"+family)
		if version != "" {
			keys = append(keys, "model:"+family+":"+version)
		}
	}
	return keys
}
func (h *Handle) recordUsage(model, generation, kind string, usage map[string]any) {
	if !h.recordNativeUsage || h.open.TelemetryLedger == nil || h.state.PrimarySessionID == "" {
		return
	}
	hash := sha256.New()
	_, _ = hash.Write([]byte("mokusei.moku.telemetry.sample.v1"))
	for _, part := range []string{"claude", h.open.ThreadID, h.state.PrimarySessionID, generation} {
		_, _ = fmt.Fprintf(hash, "%d:%s", len([]byte(part)), part)
	}
	sample := map[string]any{"type": "execution-usage", "sampleId": "sha256:" + hex.EncodeToString(hash.Sum(nil)), "observedAt": time.Now().UnixMilli(), "model": model, "attributionKeys": usageAttribution(model), "usageKind": kind}
	for native, key := range map[string]string{"inputTokens": "uncachedInputTokens", "cachedTokens": "cachedReadTokens", "cacheWriteTokens": "cacheWriteTokens", "outputTokens": "outputTokens", "reasoningTokens": "reasoningTokens", "costUsd": "costUsd"} {
		if v, ok := usage[native]; ok {
			sample[key] = v
		}
	}
	raw, _ := json.Marshal(sample)
	_ = h.open.TelemetryLedger.Record(context.WithoutCancel(h.ctx), raw)
}
