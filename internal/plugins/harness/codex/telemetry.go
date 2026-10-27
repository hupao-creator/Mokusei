package codex

import (
	"fmt"
	"math"
	"regexp"
	"strings"
	"time"
)

func usageAttributionKeys(model string) []string {
	id := strings.ToLower(strings.TrimSpace(model))
	if regexp.MustCompile(`^(?:gpt-\d[\w.-]*|o\d+(?:-[\w.-]+)?)$`).MatchString(id) {
		return []string{"model:" + id}
	}
	return []string{}
}
func NormalizeTelemetry(response Map, observed int64) Map {
	primary := obj(response["rateLimits"])
	buckets := Map{}
	for id, v := range obj(response["rateLimitsByLimitId"]) {
		bucket := obj(v)
		if len(bucket) > 0 {
			buckets[first(str(bucket["limitId"]), id)] = bucket
		}
	}
	if len(primary) > 0 {
		id := first(str(primary["limitId"]), "codex")
		if buckets[id] == nil {
			buckets[id] = primary
		}
	}
	snapshot := Map{"source": "Codex account/rateLimits/read", "observedAt": observed, "availability": "unknown", "plan": nil, "limitReached": nil, "windows": []any{}}
	if plan := strings.TrimSpace(str(primary["planType"])); plan != "" {
		snapshot["plan"] = plan
	}
	windows := []any{}
	reached := false
	for id, v := range buckets {
		bucket := obj(v)
		scope := "model"
		if id == str(primary["limitId"]) || (str(primary["limitId"]) == "" && id == "codex") {
			scope = "provider"
		}
		if scope == "provider" && (bucket["spendControlReached"] == true || str(bucket["rateLimitReachedType"]) != "") {
			reached = true
		}
		for _, name := range []string{"primary", "secondary"} {
			w := obj(bucket[name])
			if len(w) == 0 {
				continue
			}
			duration := num(w["windowDurationMins"])
			label := name + " window"
			if duration > 0 {
				label = fmt.Sprintf("%g-minute window", duration)
			}
			if duration == 300 {
				label = "5-hour window"
			} else if duration == 10080 {
				label = "7-day window"
			}
			label = first(str(bucket["limitName"]), "Codex shared") + " " + label
			window := Map{"id": id + ":" + name, "label": label, "scope": scope, "usedPercent": nil, "remainingPercent": nil, "resetsAt": nil, "exhausted": nil, "metering": "token"}
			attribution := Map{"type": "unknown"}
			if id == "codex" {
				attribution = Map{"type": "all"}
			} else if keys := usageAttributionKeys(id); len(keys) > 0 {
				attribution = Map{"type": "matching", "keys": keys}
			}
			window["usageAttribution"] = attribution
			if scope == "model" {
				window["selector"] = first(str(bucket["limitName"]), id)
			}
			if duration > 0 {
				window["durationMinutes"] = duration
			}
			used, has := w["usedPercent"]
			_, numeric := used.(float64)
			if has && numeric && num(used) >= 0 {
				percent := math.Round(num(used)*100) / 100
				window["usedPercent"] = percent
				window["remainingPercent"] = math.Max(0, 100-percent)
				window["exhausted"] = percent >= 100
				if scope == "provider" && percent >= 100 {
					reached = true
				}
			}
			window["resetsAt"] = telemetryISO(w["resetsAt"])
			if window["usedPercent"] != nil && window["resetsAt"] != nil && duration > 0 {
				if pace := telemetryPace(num(window["usedPercent"]), duration, str(window["resetsAt"]), observed); pace != nil {
					window["pace"] = pace
				}
			}

			windows = append(windows, window)
		}
	}
	snapshot["windows"] = windows
	if len(windows) > 0 {
		snapshot["availability"] = "available"
		snapshot["limitReached"] = reached
		if !reached {
			providerWindows := 0
			unknown := false
			for _, v := range windows {
				w := obj(v)
				if w["scope"] == "provider" {
					providerWindows++
					if w["exhausted"] == nil {
						unknown = true
					}
				}
			}
			if providerWindows == 0 || unknown {
				snapshot["limitReached"] = nil
			}
		}
	} else {
		snapshot["note"] = "Codex returned no recognizable usage windows; do not assume Codex has unlimited capacity."
		if reached {
			snapshot["limitReached"] = true
		}
	}
	return snapshot
}
func telemetryISO(value any) any {
	if s, ok := value.(string); ok {
		parsed, e := time.Parse(time.RFC3339Nano, s)
		if e == nil {
			return parsed.UTC().Format("2006-01-02T15:04:05.000Z")
		}
		return nil
	}
	n, ok := value.(float64)
	if !ok {
		if i, yes := value.(int64); yes {
			n = float64(i)
			ok = true
		}
	}
	if !ok || math.IsNaN(n) || math.IsInf(n, 0) {
		return nil
	}
	if n < 1e12 {
		n *= 1000
	}
	return time.UnixMilli(int64(n)).UTC().Format("2006-01-02T15:04:05.000Z")
}
func telemetryPace(used, duration float64, reset string, observed int64) Map {
	parsed, e := time.Parse(time.RFC3339Nano, reset)
	if e != nil {
		return nil
	}
	durationMS := duration * 60000
	remaining := float64(parsed.UnixMilli() - observed)
	if durationMS <= 0 || remaining <= 0 || remaining > durationMS {
		return nil
	}
	elapsed := durationMS - remaining
	expected := elapsed / durationMS * 100
	if expected < 3 {
		return nil
	}
	actual := math.Max(0, math.Min(100, used))
	delta := actual - expected
	capacity := 100 - actual
	projected := actual * remaining / elapsed
	stage := "on_pace"
	if math.Abs(delta) > 2 {
		prefix := "under"
		if delta > 0 {
			prefix = "over"
		}
		switch {
		case math.Abs(delta) <= 6:
			stage = "slightly_" + prefix + "_pace"
		case math.Abs(delta) <= 12:
			stage = prefix + "_pace"
		default:
			stage = "far_" + prefix + "_pace"
		}
	}
	r := Map{"expectedUsedPercent": math.Round(expected*100) / 100, "deltaPercent": math.Round(delta*100) / 100, "stage": stage, "willLastToReset": true, "etaSeconds": nil, "projectedExhaustionAt": nil, "sustainableRateMultiplier": nil}
	if capacity > 0 && projected > 0 {
		r["sustainableRateMultiplier"] = math.Round(capacity/projected*1000) / 1000
	}
	if actual >= 100 {
		r["willLastToReset"] = false
		r["etaSeconds"] = float64(0)
		r["projectedExhaustionAt"] = telemetryISO(observed)
	} else if actual > 0 {
		candidate := capacity / (actual / elapsed)
		if candidate < remaining {
			eta := math.Max(0, math.Round(candidate/1000))
			r["willLastToReset"] = false
			r["etaSeconds"] = eta
			r["projectedExhaustionAt"] = telemetryISO(observed + int64(eta)*1000)
		}
	}
	return r
}
func formatTelemetry(namespace string, snapshot Map) string {
	out := clone(snapshot)
	out["namespace"] = namespace
	out["observedAt"] = telemetryISO(int64(num(snapshot["observedAt"])))
	return jsonText(out)
}
