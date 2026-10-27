package moku

import (
	"bytes"
	"encoding/json"
	"math"
	"reflect"
	"sort"
	"strings"
	"unicode/utf16"
)

const (
	ledgerMaxFileBytes        = 8 * 1024 * 1024
	ledgerMaxPendingBytes     = ledgerMaxFileBytes / 2
	ledgerMaxWindows          = 256
	ledgerMaxRecentIDs        = 4096
	ledgerMaxPendingSamples   = 4096
	ledgerMaxCompletedCycles  = 3
	ledgerMaxModelRows        = 32
	ledgerMaxModelLength      = 256
	ledgerMaxIDLength         = 512
	ledgerMaxAttributionKeys  = 32
	ledgerMaxAttributionBytes = 4 * 1024
	ledgerOverflowModel       = "(other models)"
	ledgerMaxSafeInteger      = float64(9007199254740991)
)

var ledgerTokenFields = []string{
	"inputTokens", "uncachedInputTokens", "cachedReadTokens", "cacheWriteTokens",
	"outputTokens", "reasoningTokens",
}

var ledgerTotalFields = []string{
	"inputTokens", "uncachedInputTokens", "cachedReadTokens", "cacheWriteTokens",
	"outputTokens", "reasoningTokens", "costUsd",
}

type ledgerReading struct {
	ObservedAt  float64  `json:"observedAt"`
	UsedPercent *float64 `json:"usedPercent"`
	UsedUnits   *float64 `json:"usedUnits,omitempty"`
	LimitUnits  *float64 `json:"limitUnits,omitempty"`
}

type ledgerCycle struct {
	First    ledgerReading       `json:"first"`
	Latest   ledgerReading       `json:"latest"`
	ClosesAt *float64            `json:"closesAt,omitempty"`
	ByModel  []ledgerModelTotals `json:"byModel"`
}

type ledgerWindow struct {
	ID               string            `json:"id"`
	Metering         string            `json:"metering"`
	UsageAttribution ledgerAttribution `json:"usageAttribution"`
	Current          ledgerCycle       `json:"current"`
	Completed        []ledgerCycle     `json:"completed"`
}

type ledgerAttribution struct {
	Type string   `json:"type"`
	Keys []string `json:"keys,omitempty"`
}

type ledgerModelTotals = map[string]any
type pendingUsage = map[string]any

func normalizeExecutionUsageSample(sample map[string]any) (pendingUsage, bool) {
	if !validSampleID(sample["sampleId"]) || !validTimestamp(sample["observedAt"]) {
		return nil, false
	}
	kind, _ := sample["usageKind"].(string)
	if kind != "generation" && kind != "summary" {
		return nil, false
	}
	_, hasUncachedInput := nonnegativeNumber(sample["uncachedInputTokens"])
	hasTokens := false
	if kind == "generation" {
		for _, field := range ledgerTokenFields {
			if field == "inputTokens" && hasUncachedInput {
				continue
			}
			if _, ok := positiveNumber(sample[field]); ok {
				hasTokens = true
				break
			}
		}
	}
	cost, hasCost := positiveNumber(sample["costUsd"])
	if !hasTokens && !hasCost {
		return nil, false
	}
	keys, ok := normalizeAttributionKeys(sample["attributionKeys"])
	if !ok {
		keys = []string{}
	}
	at, _ := finiteNumber(sample["observedAt"])
	normalized := pendingUsage{
		"sampleId": sample["sampleId"], "observedAt": at,
		"model": normalizedModel(sample["model"]), "attributionKeys": keys, "usageKind": kind,
	}
	if kind == "generation" {
		for _, field := range ledgerTokenFields {
			if value, ok := nonnegativeNumber(sample[field]); ok {
				normalized[field] = math.Min(ledgerMaxSafeInteger, value)
			}
		}
	}
	if hasCost {
		normalized["costUsd"] = math.Min(ledgerMaxSafeInteger, cost)
	}
	return normalized, true
}

func normalizePendingExecutionSamples(value any) ([]pendingUsage, bool) {
	values, ok := ledgerArray(value)
	if !ok || len(values) > ledgerMaxPendingSamples {
		return nil, false
	}
	result := make([]pendingUsage, 0, len(values))
	seen := make(map[string]bool, len(values))
	totalBytes := 0
	for _, value := range values {
		parsed, ok := normalizePersistedExecutionUsageSample(value)
		if !ok {
			return nil, false
		}
		id := parsed["sampleId"].(string)
		if seen[id] {
			return nil, false
		}
		totalBytes += pendingUsageBytes(parsed)
		if totalBytes > ledgerMaxPendingBytes {
			return nil, false
		}
		seen[id] = true
		result = append(result, parsed)
	}
	return result, true
}

func normalizePersistedExecutionUsageSample(value any) (pendingUsage, bool) {
	m, ok := ledgerObject(value)
	if !ok || !ledgerOnlyKeys(m, []string{"sampleId", "observedAt", "model", "attributionKeys", "usageKind"}, ledgerTotalFields) {
		return nil, false
	}
	kind, _ := m["usageKind"].(string)
	if !validSampleID(m["sampleId"]) || !validTimestamp(m["observedAt"]) || (kind != "generation" && kind != "summary") {
		return nil, false
	}
	model := normalizedPersistedModel(m["model"])
	keys, ok := normalizeAttributionKeys(m["attributionKeys"])
	if model == "" || !ok {
		return nil, false
	}
	at, _ := finiteNumber(m["observedAt"])
	normalized := pendingUsage{
		"sampleId": m["sampleId"], "observedAt": at, "model": model,
		"attributionKeys": keys, "usageKind": kind,
	}
	for _, field := range ledgerTokenFields {
		value, exists := m[field]
		if !exists {
			continue
		}
		if kind != "generation" {
			return nil, false
		}
		parsed, ok := nonnegativeNumber(value)
		if !ok || parsed > ledgerMaxSafeInteger {
			return nil, false
		}
		normalized[field] = parsed
	}
	if value, exists := m["costUsd"]; exists {
		parsed, ok := positiveNumber(value)
		if !ok || parsed > ledgerMaxSafeInteger {
			return nil, false
		}
		normalized["costUsd"] = parsed
	}
	_, hasUncachedInput := normalized["uncachedInputTokens"]
	_, hasCost := normalized["costUsd"]
	hasTokens := false
	if kind == "generation" {
		for _, field := range ledgerTokenFields {
			if field == "inputTokens" && hasUncachedInput {
				continue
			}
			if _, ok := positiveNumber(normalized[field]); ok {
				hasTokens = true
				break
			}
		}
	}
	if !hasTokens && !hasCost {
		return nil, false
	}
	return normalized, true
}

func normalizeRecentSampleIDs(value any) ([]string, bool) {
	values, ok := ledgerArray(value)
	if !ok || len(values) > ledgerMaxRecentIDs {
		return nil, false
	}
	result := make([]string, 0, len(values))
	seen := make(map[string]bool, len(values))
	for _, value := range values {
		if !validSampleID(value) {
			return nil, false
		}
		id := value.(string)
		if seen[id] {
			return nil, false
		}
		seen[id] = true
		result = append(result, id)
	}
	return result, true
}

func normalizeWindows(value any) []ledgerWindow {
	values, _ := ledgerArray(value)
	windows := make([]ledgerWindow, 0, len(values))
	positions := make(map[string]int, len(values))
	for _, value := range values {
		parsed, ok := normalizeWindow(value)
		if !ok {
			continue
		}
		if index, exists := positions[parsed.ID]; exists {
			if parsed.Current.Latest.ObservedAt >= windows[index].Current.Latest.ObservedAt {
				windows[index] = parsed
			}
			continue
		}
		positions[parsed.ID] = len(windows)
		windows = append(windows, parsed)
	}
	for len(windows) > ledgerMaxWindows {
		windows = dropStalestWindow(windows)
	}
	sortLedgerWindows(windows)
	return windows
}

func normalizeWindow(value any) (ledgerWindow, bool) {
	m, ok := ledgerObject(value)
	if !ok || !ledgerOnlyKeys(m, []string{"id", "metering", "usageAttribution", "current", "completed"}) {
		return ledgerWindow{}, false
	}
	id := normalizedIdentifier(m["id"])
	metering, _ := m["metering"].(string)
	if id == "" || (metering != "token" && metering != "monetary" && metering != "credit") {
		return ledgerWindow{}, false
	}
	current, ok := normalizeCycle(m["current"])
	if !ok {
		return ledgerWindow{}, false
	}
	attribution, ok := normalizeUsageAttribution(m["usageAttribution"])
	if !ok {
		return ledgerWindow{}, false
	}
	completed := make([]ledgerCycle, 0, ledgerMaxCompletedCycles)
	values, _ := ledgerArray(m["completed"])
	for _, value := range values {
		if cycle, ok := normalizeCycle(value); ok {
			completed = append(completed, cycle)
			if len(completed) == ledgerMaxCompletedCycles {
				break
			}
		}
	}
	return ledgerWindow{ID: id, Metering: metering, UsageAttribution: attribution, Current: current, Completed: completed}, true
}

func normalizeAttributionKeys(value any) ([]string, bool) {
	values, ok := ledgerArray(value)
	if !ok || len(values) > ledgerMaxAttributionKeys {
		return nil, false
	}
	keys := make([]string, 0, len(values))
	seen := make(map[string]bool, len(values))
	for _, value := range values {
		key, ok := value.(string)
		if !ok || ledgerTrim(key) == "" || ledgerUTF16Length(key) > ledgerMaxIDLength {
			return nil, false
		}
		if !seen[key] {
			seen[key] = true
			keys = append(keys, key)
		}
	}
	// Attribution keys are opaque, so preserve their bytes and match JavaScript's
	// UTF-16 lexicographic sort instead of locale or whitespace normalization.
	sort.Slice(keys, func(i, j int) bool {
		left, right := utf16.Encode([]rune(keys[i])), utf16.Encode([]rune(keys[j]))
		for k := 0; k < len(left) && k < len(right); k++ {
			if left[k] != right[k] {
				return left[k] < right[k]
			}
		}
		return len(left) < len(right)
	})
	encoded, err := ledgerJSON(keys)
	if err != nil || len(encoded) > ledgerMaxAttributionBytes {
		return nil, false
	}
	return keys, true
}

func normalizeUsageAttribution(value any) (ledgerAttribution, bool) {
	m, ok := ledgerObject(value)
	if !ok {
		return ledgerAttribution{}, false
	}
	kind, _ := m["type"].(string)
	if kind == "all" || kind == "unknown" {
		return ledgerAttribution{Type: kind}, ledgerOnlyKeys(m, []string{"type"})
	}
	if kind != "matching" || !ledgerOnlyKeys(m, []string{"type", "keys"}) {
		return ledgerAttribution{}, false
	}
	keys, ok := normalizeAttributionKeys(m["keys"])
	if !ok || len(keys) == 0 {
		return ledgerAttribution{}, false
	}
	return ledgerAttribution{Type: kind, Keys: keys}, true
}

func normalizeCycle(value any) (ledgerCycle, bool) {
	m, ok := ledgerObject(value)
	if !ok || !ledgerOnlyKeys(m, []string{"first", "latest", "byModel"}, []string{"closesAt"}) {
		return ledgerCycle{}, false
	}
	first, firstOK := normalizePersistedReading(m["first"])
	latest, latestOK := normalizePersistedReading(m["latest"])
	if !firstOK || !latestOK || latest.ObservedAt < first.ObservedAt {
		return ledgerCycle{}, false
	}
	cycle := ledgerCycle{First: first, Latest: latest, ByModel: compactModelRows(m["byModel"])}
	if validTimestamp(m["closesAt"]) {
		at, _ := finiteNumber(m["closesAt"])
		cycle.ClosesAt = &at
	}
	return cycle, true
}

func normalizePersistedReading(value any) (ledgerReading, bool) {
	m, ok := ledgerObject(value)
	if !ok || !ledgerOnlyKeys(m, []string{"observedAt", "usedPercent"}, []string{"usedUnits", "limitUnits"}) || !validTimestamp(m["observedAt"]) {
		return ledgerReading{}, false
	}
	at, _ := finiteNumber(m["observedAt"])
	reading := ledgerReading{ObservedAt: at}
	if m["usedPercent"] != nil {
		percent, ok := finiteNumber(m["usedPercent"])
		if !ok {
			return ledgerReading{}, false
		}
		reading.UsedPercent = &percent
	}
	if used, ok := nonnegativeNumber(m["usedUnits"]); ok {
		reading.UsedUnits = &used
	}
	if limit, ok := nonnegativeNumber(m["limitUnits"]); ok {
		reading.LimitUnits = &limit
	}
	return reading, true
}

func compactModelRows(value any) []ledgerModelTotals {
	values, _ := ledgerArray(value)
	cycle := ledgerCycle{ByModel: []ledgerModelTotals{}}
	for _, value := range values {
		parsed, ok := normalizeModelTotals(value)
		if !ok {
			continue
		}
		target := modelRow(&cycle, parsed["model"].(string))
		mergeModelTotals(target, parsed)
	}
	return cycle.ByModel
}

func normalizeModelTotals(value any) (ledgerModelTotals, bool) {
	m, ok := ledgerObject(value)
	if !ok || !ledgerOnlyKeys(m, []string{"model", "usageEvents"}, ledgerTotalFields) {
		return nil, false
	}
	model := normalizedPersistedModel(m["model"])
	events, ok := nonnegativeNumber(m["usageEvents"])
	if model == "" || !ok {
		return nil, false
	}
	row := ledgerModelTotals{"model": model, "usageEvents": events}
	nonzero := events > 0
	for _, field := range ledgerTotalFields {
		if parsed, ok := nonnegativeNumber(m[field]); ok {
			row[field] = parsed
			nonzero = nonzero || parsed > 0
		}
	}
	return row, nonzero
}

func mergeModelTotals(target, source ledgerModelTotals) {
	left, _ := nonnegativeNumber(target["usageEvents"])
	right, _ := nonnegativeNumber(source["usageEvents"])
	target["usageEvents"] = boundedSum(left, right)
	for _, field := range ledgerTotalFields {
		if value, ok := nonnegativeNumber(source[field]); ok {
			old, _ := nonnegativeNumber(target[field])
			target[field] = boundedSum(old, value)
		}
	}
}

func modelRow(cycle *ledgerCycle, model string) ledgerModelTotals {
	concreteRows := 0
	var overflow ledgerModelTotals
	for _, row := range cycle.ByModel {
		if row["model"] == model {
			return row
		}
		if row["model"] == ledgerOverflowModel {
			overflow = row
		} else {
			concreteRows++
		}
	}
	if model == ledgerOverflowModel || concreteRows >= ledgerMaxModelRows-1 {
		if overflow != nil {
			return overflow
		}
		model = ledgerOverflowModel
	}
	row := ledgerModelTotals{"model": model, "usageEvents": float64(0)}
	cycle.ByModel = append(cycle.ByModel, row)
	sort.SliceStable(cycle.ByModel, func(i, j int) bool {
		left, _ := cycle.ByModel[i]["model"].(string)
		right, _ := cycle.ByModel[j]["model"].(string)
		if left == ledgerOverflowModel {
			return false
		}
		if right == ledgerOverflowModel {
			return true
		}
		return left < right
	})
	return row
}

func dropStalestWindow(windows []ledgerWindow) []ledgerWindow {
	if len(windows) == 0 {
		return windows
	}
	selected := 0
	for i := 1; i < len(windows); i++ {
		if windows[i].Current.Latest.ObservedAt < windows[selected].Current.Latest.ObservedAt {
			selected = i
		}
	}
	copy(windows[selected:], windows[selected+1:])
	windows[len(windows)-1] = ledgerWindow{}
	return windows[:len(windows)-1]
}

func sortLedgerWindows(windows []ledgerWindow) {
	sort.SliceStable(windows, func(i, j int) bool { return windows[i].ID < windows[j].ID })
}

func normalizedIdentifier(value any) string {
	text, _ := value.(string)
	text = ledgerTrim(text)
	if ledgerUTF16Length(text) > ledgerMaxIDLength {
		return ""
	}
	return text
}

func normalizedModel(value any) string {
	text, _ := value.(string)
	text = ledgerTrim(text)
	if text == "" {
		text = "unknown"
	}
	return ledgerUTF16Prefix(text, ledgerMaxModelLength)
}

func normalizedPersistedModel(value any) string {
	text, _ := value.(string)
	return ledgerUTF16Prefix(ledgerTrim(text), ledgerMaxModelLength)
}

func validTimestamp(value any) bool {
	number, ok := nonnegativeNumber(value)
	return ok && number <= 8640000000000000
}

func validSampleID(value any) bool {
	text, ok := value.(string)
	return ok && len(text) > 0 && ledgerUTF16Length(text) <= ledgerMaxIDLength
}

func finiteNumber(value any) (float64, bool) {
	var number float64
	if n, ok := value.(json.Number); ok {
		var err error
		number, err = n.Float64()
		if err != nil {
			return 0, false
		}
	} else {
		raw := reflect.ValueOf(value)
		if !raw.IsValid() {
			return 0, false
		}
		switch raw.Kind() {
		case reflect.Float32, reflect.Float64:
			number = raw.Float()
		case reflect.Int, reflect.Int8, reflect.Int16, reflect.Int32, reflect.Int64:
			number = float64(raw.Int())
		case reflect.Uint, reflect.Uint8, reflect.Uint16, reflect.Uint32, reflect.Uint64:
			number = float64(raw.Uint())
		default:
			return 0, false
		}
	}
	return number, !math.IsNaN(number) && !math.IsInf(number, 0)
}

func positiveNumber(value any) (float64, bool) {
	number, ok := finiteNumber(value)
	return number, ok && number > 0
}

func nonnegativeNumber(value any) (float64, bool) {
	number, ok := finiteNumber(value)
	return number, ok && number >= 0
}

func boundedSum(left, right float64) float64 {
	return math.Min(ledgerMaxSafeInteger, left+right)
}

func pendingUsageBytes(sample pendingUsage) int {
	encoded, err := ledgerJSON(sample)
	if err != nil {
		return ledgerMaxPendingBytes + 1
	}
	// Count the separating comma as well, conservatively including the last one.
	return len(encoded) + 1
}

func ledgerJSON(value any) ([]byte, error) {
	var buffer bytes.Buffer
	encoder := json.NewEncoder(&buffer)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(value); err != nil {
		return nil, err
	}
	encoded := bytes.TrimSuffix(buffer.Bytes(), []byte{'\n'})
	// encoding/json escapes the JavaScript line separators even with HTML
	// escaping disabled. JSON.stringify preserves them; use that representation
	// so the persisted byte budget does not penalize opaque attribution keys.
	if !bytes.Contains(encoded, []byte(`\u2028`)) && !bytes.Contains(encoded, []byte(`\u2029`)) {
		return encoded, nil
	}
	result := make([]byte, 0, len(encoded))
	for i := 0; i < len(encoded); i++ {
		if encoded[i] == '\\' && i+1 < len(encoded) {
			if i+5 < len(encoded) && bytes.Equal(encoded[i+1:i+5], []byte("u202")) && (encoded[i+5] == '8' || encoded[i+5] == '9') {
				result = append(result, 0xe2, 0x80, 0xa8+(encoded[i+5]-'8'))
				i += 5
				continue
			}
			// Skip each complete escape so literal backslash-u text stays literal.
			result = append(result, encoded[i], encoded[i+1])
			i++
			continue
		}
		result = append(result, encoded[i])
	}
	return result, nil
}

func ledgerObject(value any) (map[string]any, bool) {
	if m, ok := value.(map[string]any); ok {
		return m, m != nil
	}
	// Typed ledger structs are also normalized before persistence. JSON applies
	// their field tags and pointer/null semantics without exposing internal names.
	raw := reflect.ValueOf(value)
	if !raw.IsValid() || (raw.Kind() != reflect.Struct && raw.Kind() != reflect.Pointer && raw.Kind() != reflect.Map) {
		return nil, false
	}
	encoded, err := ledgerJSON(value)
	if err != nil {
		return nil, false
	}
	var m map[string]any
	if err := json.Unmarshal(encoded, &m); err != nil || m == nil {
		return nil, false
	}
	return m, true
}

func ledgerArray(value any) ([]any, bool) {
	if values, ok := value.([]any); ok {
		return values, true
	}
	raw := reflect.ValueOf(value)
	if !raw.IsValid() || (raw.Kind() != reflect.Slice && raw.Kind() != reflect.Array) {
		return nil, false
	}
	values := make([]any, raw.Len())
	for i := range values {
		values[i] = raw.Index(i).Interface()
	}
	return values, true
}

func ledgerOnlyKeys(value map[string]any, required []string, optional ...[]string) bool {
	allowed := make(map[string]bool, len(required))
	for _, key := range required {
		if _, exists := value[key]; !exists {
			return false
		}
		allowed[key] = true
	}
	for _, group := range optional {
		for _, key := range group {
			allowed[key] = true
		}
	}
	for key := range value {
		if !allowed[key] {
			return false
		}
	}
	return true
}

func ledgerUTF16Length(value string) int {
	length := 0
	for _, r := range value {
		length += utf16.RuneLen(r)
	}
	return length
}

func ledgerUTF16Prefix(value string, limit int) string {
	length := 0
	for offset, r := range value {
		length += utf16.RuneLen(r)
		if length > limit {
			// Do not create the unpaired surrogate that JS slice permits.
			return value[:offset]
		}
	}
	return value
}

func ledgerTrim(value string) string {
	// ECMAScript WhiteSpace + LineTerminator (unlike strings.TrimSpace, this
	// includes BOM and excludes NEXT LINE U+0085).
	return strings.TrimFunc(value, func(r rune) bool {
		return (r >= '\t' && r <= '\r') || r == ' ' || r == '\u00a0' || r == '\u1680' ||
			(r >= '\u2000' && r <= '\u200a') || r == '\u2028' || r == '\u2029' ||
			r == '\u202f' || r == '\u205f' || r == '\u3000' || r == '\ufeff'
	})
}
