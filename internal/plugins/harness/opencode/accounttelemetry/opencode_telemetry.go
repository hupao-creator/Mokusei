package accounttelemetry

import (
	"context"
	_ "embed"
	"encoding/json"
	"fmt"
	"math"
	"math/big"
	"reflect"
	"regexp"
	"slices"
	"sort"
	"strings"
	"sync"
	"time"
)

const goUsageURL = "https://opencode.ai/zen/go/v1/usage"
const goUsageSource = "OpenCode Go GET /zen/go/v1/usage"
const goPricesURL = "https://models.dev/api.json"

type GoUsage struct {
	Subscription string          `json:"subscription"`
	Telemetry    json.RawMessage `json:"telemetry"`
}

func unavailableGo(note, availability string, now time.Time) json.RawMessage {
	return jsonValue(object{"source": goUsageSource, "observedAt": now.UnixMilli(), "availability": availability, "plan": nil, "limitReached": nil, "windows": []any{}, "note": note})
}

func NormalizeOpenCodeGoTelemetry(payload any, attribution []string, now time.Time) json.RawMessage {
	usage := record(record(payload)["usage"])
	windows := []object{}
	for _, definition := range []struct {
		id, label string
		minutes   float64
	}{{"rolling", "OpenCode Go 5-hour subscription window", 300}, {"weekly", "OpenCode Go weekly subscription window", 10080}, {"monthly", "OpenCode Go monthly subscription window", 0}} {
		raw := record(usage[definition.id])
		status := text(raw["status"])
		limited := status == "rate-limited"
		used, valid := finiteNumber(raw["percent"])
		if limited {
			used = 100
			valid = true
		}
		reset, hasReset := telemetryTime(raw["resetsAt"])
		if (status != "ok" && !limited) || !valid || used < 0 || used > 100 || !hasReset {
			continue
		}
		used = rounded(used)
		id := "opencode-go:unattributed"
		attributed := object{"type": "unknown"}
		if len(attribution) > 0 {
			id = attribution[0]
			attributed = object{"type": "matching", "keys": slices.Clone(attribution)}
		}
		window := object{"id": id + ":" + definition.id, "label": definition.label, "scope": "feature", "selector": "OpenCode Go subscription", "usageAttribution": attributed, "usedPercent": used, "remainingPercent": rounded(max(0.0, 100-used)), "resetsAt": reset.UTC().Format("2006-01-02T15:04:05.000Z"), "exhausted": limited || used >= 100, "quality": "exact", "confidence": "high", "metering": "monetary"}
		if definition.minutes > 0 {
			window["durationMinutes"] = definition.minutes
			if pace := calculatePace(used, definition.minutes, reset, now); pace != nil {
				window["pace"] = pace
			}
		}
		windows = append(windows, window)
	}
	if len(windows) == 0 {
		return unavailableGo("OpenCode Go returned no recognizable usage windows. Account capacity remains unknown.", "unknown", now)
	}
	return jsonValue(object{"source": goUsageSource, "observedAt": now.UnixMilli(), "availability": "available", "plan": nil, "limitReached": nil, "windows": windows, "note": "These are server-reported Go subscription windows for the selected credential. The usage endpoint alone does not expose the plan, Zen balance or paid-overflow setting; any separate Console facts are identified by their own source. Exhausted subscription windows do not establish exhaustion of free models or Zen balance; local generation costs are not an account balance."})
}

// ReadOpenCodeGoUsage never forwards a native secret until the effective model
// endpoint is verified. Only the official EntitlementError establishes absence.
func ReadOpenCodeGoUsage(ctx context.Context, host ClientOptions, baseURL, apiKey string) (GoUsage, error) {
	host = normalizeOptions(host)
	unknown := func(note, status string) GoUsage { return GoUsage{"unknown", unavailableGo(note, status, host.Now())} }
	if err := ctx.Err(); err != nil {
		return GoUsage{}, err
	}
	if !IsOpenCodeGoEndpoint(baseURL) {
		return unknown("The effective native model endpoint is not OpenCode Go. No Go credential was forwarded.", "unknown"), nil
	}
	if strings.TrimSpace(apiKey) == "" {
		return unknown("The selected OpenCode Go model has no resolved API key. Account usage is unknown.", "unknown"), nil
	}
	status, payload, err := readJSON(ctx, host, goUsageURL, apiKey, 10*time.Second)
	if ctx.Err() != nil {
		return GoUsage{}, ctx.Err()
	}
	if err != nil {
		return unknown("OpenCode Go usage request failed, timed out, or returned an invalid response. Account capacity remains unknown.", "error"), nil
	}
	if status == httpForbidden && text(record(record(payload)["error"])["type"]) == "EntitlementError" {
		return GoUsage{"absent", unavailableGo("The selected credential has no OpenCode Go subscription entitlement. This does not report Zen balance or unlimited capacity.", "not_applicable", host.Now())}, nil
	}
	if status < 200 || status >= 300 {
		return unknown(fmt.Sprintf("OpenCode Go usage endpoint returned HTTP %d. Account capacity remains unknown.", status), "error"), nil
	}
	telemetry := NormalizeOpenCodeGoTelemetry(payload, OpenCodeGoAttributionKeys(apiKey), host.Now())
	var value struct {
		Availability string `json:"availability"`
	}
	_ = json.Unmarshal(telemetry, &value)
	subscription := "unknown"
	if value.Availability == "available" {
		subscription = "present"
	}
	return GoUsage{subscription, telemetry}, nil
}

const httpForbidden = 403

type goTelemetryReader struct {
	host   ClientOptions
	prices *priceCache
}

func newGoTelemetryReader(host ClientOptions) *goTelemetryReader {
	return &goTelemetryReader{host: host, prices: pricesFor(host)}
}

// ReadOpenCodeGoTelemetry enriches the account's usage with facts proven by the
// same credential and optional public pricing, including the full dated allowance
// table in the explanatory context.
func ReadOpenCodeGoTelemetry(ctx context.Context, host ClientOptions, baseURL, apiKey string) (json.RawMessage, error) {
	host = normalizeOptions(host)
	return newGoTelemetryReader(host).read(ctx, baseURL, apiKey)
}
func (reader *goTelemetryReader) read(ctx context.Context, baseURL, key string) (json.RawMessage, error) {
	if !IsOpenCodeGoEndpoint(baseURL) || strings.TrimSpace(key) == "" || strings.TrimSpace(key) == "public" {
		usage, err := ReadOpenCodeGoUsage(ctx, reader.host, baseURL, key)
		return usage.Telemetry, err
	}
	var usage GoUsage
	var account object
	var prices goPrices
	var usageErr, accountErr, pricesErr error
	var workers sync.WaitGroup
	workers.Add(3)
	go func() { defer workers.Done(); usage, usageErr = ReadOpenCodeGoUsage(ctx, reader.host, baseURL, key) }()
	go func() { defer workers.Done(); account, _, accountErr = readGoConsole(ctx, reader.host, key) }()
	go func() { defer workers.Done(); prices, pricesErr = reader.prices.read(ctx, reader.host) }()
	workers.Wait()
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if usageErr != nil {
		return nil, usageErr
	}
	_ = accountErr
	_ = pricesErr
	var snapshot object
	if err := json.Unmarshal(usage.Telemetry, &snapshot); err != nil {
		return nil, err
	}
	if account != nil {
		if plan := account["plan"]; plan != nil {
			snapshot["plan"] = plan
		}
		if balance := account["balance"]; balance != nil {
			snapshot["balances"] = []any{balance}
		}
	}
	console := account
	if console == nil {
		console = object{"plan": nil, "useBalance": nil, "balance": nil, "note": "The selected credential could not expose verified Console account facts. No other login was consulted."}
	}
	snapshot["note"] = strings.Join([]string{text(snapshot["note"]), "Console account facts: " + string(jsonValue(console)), goBillingContext(prices)}, "\n")
	return jsonValue(snapshot), nil
}

var organizationPattern = regexp.MustCompile(`^(org|wrk)_[A-Za-z0-9_-]+$`)
var microCentPattern = regexp.MustCompile(`^-?\d{1,30}$`)

func readGoConsole(ctx context.Context, host ClientOptions, key string) (object, object, error) {
	bounded, cancel := context.WithTimeout(ctx, 2500*time.Millisecond)
	defer cancel()
	paths := []string{"/api/orgs/current", "/api/go/status", "/api/billing/status"}
	values := make([]any, 3)
	var workers sync.WaitGroup
	for i, path := range paths {
		workers.Add(1)
		go func() {
			defer workers.Done()
			status, payload, err := readJSON(bounded, host, "https://opencode.ai/console"+path, key, 2500*time.Millisecond)
			if err == nil && status >= 200 && status < 300 {
				values[i] = payload
			}
		}()
	}
	workers.Wait()
	if err := ctx.Err(); err != nil {
		return nil, nil, err
	}
	org := text(record(record(values[0])["org"])["id"])
	if !organizationPattern.MatchString(org) {
		return nil, nil, nil
	}
	status := record(values[1])
	billing := record(values[2])
	var plan, useBalance, endsAt, active any
	if value := text(status["product"]); value == "go" || value == "go-plus" {
		plan = value
	}
	if value, ok := status["useBalance"].(bool); ok {
		useBalance = value
	}
	access := record(status["access"])
	start, startOK := telemetryTime(text(access["startsAt"]))
	end, endOK := telemetryTime(text(access["endsAt"]))
	if endOK {
		endsAt = end.UTC().Format("2006-01-02T15:04:05.000Z")
	}
	if accessValue, exists := status["access"]; exists && accessValue == nil {
		active = false
	} else if startOK && endOK && start.Before(end) {
		active = !host.Now().Before(start) && host.Now().Before(end)
	}
	total := ""
	if billing["billingMode"] == "prepaid" && billing["mode"] == "pay-as-you-go" {
		total = microCentsToUSD(billing["balanceMicroCents"])
	}
	if plan == nil && useBalance == nil && total == "" {
		return nil, nil, nil
	}
	result := object{"source": "https://opencode.ai/console/api/go/status + /api/billing/status", "observedAt": host.Now().UTC().Format("2006-01-02T15:04:05.000Z"), "plan": plan, "useBalance": useBalance, "accessEndsAt": endsAt, "accessActive": active}
	if total != "" {
		result["balance"] = object{"currency": "USD", "total": total}
	}
	return result, status, nil
}
func microCentsToUSD(value any) string {
	s := text(value)
	if !microCentPattern.MatchString(s) {
		return ""
	}
	amount, ok := new(big.Int).SetString(s, 10)
	if !ok {
		return ""
	}
	negative := amount.Sign() < 0
	amount.Abs(amount)
	divisor := big.NewInt(100000000)
	whole, remainder := new(big.Int), new(big.Int)
	whole.QuoRem(amount, divisor, remainder)
	result := whole.String()
	fraction := remainder.String()
	fraction = strings.Repeat("0", 8-len(fraction)) + fraction
	fraction = strings.TrimRight(fraction, "0")
	if fraction != "" {
		result += "." + fraction
	}
	if negative {
		result = "-" + result
	}
	return result
}

type goPrices struct {
	Source     string            `json:"source"`
	ObservedAt any               `json:"observedAt"`
	Status     string            `json:"status"`
	Models     map[string]object `json:"models"`
}
type priceCache struct {
	mu      sync.Mutex
	at      time.Time
	models  map[string]object
	pending chan struct{}
	retryAt time.Time
}

var publicPriceCaches sync.Map

func pricesFor(host ClientOptions) *priceCache {
	var identity any = host.HTTP
	if safe, ok := host.HTTP.(*safeClient); ok && safe.identity != nil {
		identity = safe.identity
	}
	if reflect.TypeOf(identity).Comparable() {
		value, _ := publicPriceCaches.LoadOrStore(identity, &priceCache{})
		return value.(*priceCache)
	}
	return &priceCache{}
}
func (cache *priceCache) read(ctx context.Context, host ClientOptions) (goPrices, error) {
	if err := ctx.Err(); err != nil {
		return goPrices{}, err
	}
	cache.mu.Lock()
	now := host.Now()
	if (cache.models == nil || now.Sub(cache.at) >= 24*time.Hour) && !now.Before(cache.retryAt) && cache.pending == nil {
		cache.retryAt = now.Add(5 * time.Minute)
		cache.pending = make(chan struct{})
		pending := cache.pending
		go func() {
			status, payload, err := readJSON(context.Background(), host, goPricesURL, "", 2500*time.Millisecond)
			var models map[string]object
			if err == nil && status >= 200 && status < 300 {
				models = normalizeGoPrices(payload)
			}
			cache.mu.Lock()
			if len(models) > 0 {
				cache.models = models
				cache.at = host.Now()
			}
			cache.pending = nil
			close(pending)
			cache.mu.Unlock()
		}()
	}
	pending := cache.pending
	cache.mu.Unlock()
	if pending != nil {
		select {
		case <-ctx.Done():
			return goPrices{}, ctx.Err()
		case <-pending:
		}
	}
	cache.mu.Lock()
	defer cache.mu.Unlock()
	result := goPrices{Source: goPricesURL, Status: "unknown", Models: map[string]object{}}
	if cache.models != nil {
		result.Status = "available"
		if host.Now().Sub(cache.at) >= 24*time.Hour {
			result.Status = "stale"
		}
		result.ObservedAt = cache.at.UTC().Format("2006-01-02T15:04:05.000Z")
		raw := jsonValue(cache.models)
		_ = json.Unmarshal(raw, &result.Models)
	}
	return result, ctx.Err()
}

var modelIDPattern = regexp.MustCompile(`^[a-z0-9][a-z0-9._-]{0,127}$`)

func price(value object) object {
	amount := func(key string) (float64, bool) {
		number, ok := finiteNumber(value[key])
		return number, ok && number >= 0 && number <= 1000000
	}
	input, inputOK := amount("input")
	output, outputOK := amount("output")
	if !inputOK || !outputOK {
		return nil
	}
	result := object{"input": input, "output": output}
	for source, target := range map[string]string{"cache_read": "cacheRead", "cache_write": "cacheWrite"} {
		if _, exists := value[source]; exists {
			number, ok := amount(source)
			if !ok {
				return nil
			}
			result[target] = number
		}
	}
	return result
}
func normalizeGoPrices(value any) map[string]object {
	models := record(record(record(value)["opencode-go"])["models"])
	result := map[string]object{}
	ids := make([]string, 0, len(models))
	for id := range models {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	if len(ids) > 256 {
		ids = ids[:256]
	}
	for _, id := range ids {
		if !modelIDPattern.MatchString(id) {
			continue
		}
		cost := record(record(models[id])["cost"])
		base := price(cost)
		if base == nil {
			continue
		}
		if tiers, exists := cost["tiers"]; exists {
			rows, ok := tiers.([]any)
			if !ok || len(rows) > 8 {
				continue
			}
			contextTiers := []object{}
			valid := true
			for _, item := range rows {
				row := record(item)
				tier := record(row["tier"])
				prices := price(row)
				size, ok := finiteNumber(tier["size"])
				if prices == nil || tier["type"] != "context" || !ok || size <= 0 || size > 9007199254740991 || math.Trunc(size) != size {
					valid = false
					break
				}
				prices["aboveTokens"] = size
				contextTiers = append(contextTiers, prices)
			}
			if !valid {
				continue
			}
			if len(contextTiers) > 0 {
				base["contextTiers"] = contextTiers
			}
		} else if _, exists := cost["context_over_200k"]; exists {
			continue
		}
		result[id] = base
	}
	return result
}

//go:embed assets/opencode-go-allowances.json
var goAllowancesJSON []byte

type allowance struct {
	ID              string `json:"id"`
	MonthlyUSD      any    `json:"monthlyUsd"`
	LimitedTimeFree bool   `json:"limitedTimeFree,omitempty"`
}
type allowanceTable struct {
	Source     string      `json:"source"`
	VerifiedAt string      `json:"verifiedAt"`
	Models     []allowance `json:"models"`
}

func goBillingContext(prices goPrices) string {
	var table allowanceTable
	if err := json.Unmarshal(goAllowancesJSON, &table); err != nil {
		panic("invalid embedded OpenCode Go allowances")
	}
	allowances := map[string]allowance{}
	for _, row := range table.Models {
		allowances[row.ID] = row
	}
	modelIDs := make([]string, 0, len(table.Models))
	for _, row := range table.Models {
		modelIDs = append(modelIDs, row.ID)
	}
	ids := []string{}
	for _, id := range modelIDs {
		if !slices.Contains(ids, id) {
			ids = append(ids, id)
		}
		if len(ids) == 64 {
			break
		}
	}
	offPeak := map[string][3]float64{"deepseek-flash": {0.15, 0.60, 0.003}, "deepseek-v4.1-flash": {0.15, 0.60, 0.003}, "deepseek-v4-pro": {0.66, 1.98, 0.022}, "deepseek-v4-flash": {0.15, 0.60, 0.003}, "deepseek-v4-flash-vision-exp": {0.15, 0.60, 0.003}}
	models := []object{}
	for _, id := range ids {
		allowance := allowances[id]
		price := prices.Models[id]
		base, peak := offPeak[id]
		verified := price != nil && price["input"] == base[0] && price["output"] == base[1] && price["cacheRead"] == base[2]
		row := object{"id": id, "monthlyAllowanceUsd": allowance.MonthlyUSD, "tokenUsdPerMillion": nil}
		if allowance.LimitedTimeFree {
			row["limitedTimeFree"] = true
		}
		if price != nil && (!peak || verified) {
			row["tokenUsdPerMillion"] = price
		}
		if peak {
			condition := "Peak/off-peak pricing could not be reconciled with the verified policy; token price is unknown."
			if verified {
				condition = "off-peak; peak prices are 2x each listed token price"
			}
			row["pricingCondition"] = condition
		}
		models = append(models, row)
	}
	rules := object{"source": "https://opencode.ai/v2/docs/console/go#usage-limits", "verifiedAt": "2026-10-09", "allowanceSource": table.Source, "allowanceVerifiedAt": table.VerifiedAt, "windowFractions": object{"fiveHour": 0.2, "week": 0.5, "month": 1}, "peakSchedule": "For rows marked off-peak: Monday-Friday 01:00-04:00 and 06:00-10:00 UTC are peak; weekends and all other hours are off-peak.", "caveat": "Public policy snapshot; prices and limited-time offers may change. A null value is unknown. This table does not advertise model availability."}
	return strings.Join([]string{
		"OpenCode Go billing policy: token costs, including cache reads/writes, consume shared subscription windows with model-specific weights. Monthly allowances below describe consumption weights, not independent per-model balances or spendable credit. Go Plus is not a uniform multiple of Go.",
		"For estimates only: sum(request USD cost / that plan and model monthly allowance) within a window; divide by 0.2 for the 5-hour fraction, 0.5 for weekly, or 1 for monthly. Server usage percentages remain authoritative. Estimated request counts are not hard limits. Unknown plan, price, or model allowance must remain unknown; never substitute another provider or model alias.",
		"Subscription exhaustion does not exhaust limited-time free models. Paid overflow also requires useBalance=true and sufficient account funds; an unknown setting or balance does not establish availability. Local generation cost is neither the subscription balance nor its weighted quota debit.",
		string(jsonValue(object{"rules": rules, "prices": object{"source": prices.Source, "observedAt": prices.ObservedAt, "status": prices.Status}, "models": models})),
	}, "\n")
}
