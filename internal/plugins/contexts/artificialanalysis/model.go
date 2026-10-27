// Package artificialanalysis owns evaluator acquisition, release attribution and
// advisory Moku context. Unknown measurements never constrain native settings.
package artificialanalysis

import (
	"encoding/json"
	"fmt"
	"math"
	"strings"
	"time"
	"unicode/utf16"
)

const SourceID = "artificial-analysis"
const MaxFactsBytes = 8 * 1024 * 1024
const MaxCatalogBytes = 64 * 1024
const MaxFormattedBytes = 24 * 1024
const ContextTimeoutMS = 21000

var BenchmarkIDs = []string{"hleText", "terminalBenchV21", "tau3Banking"}

type Configuration struct {
	Reasoning bool   `json:"reasoning"`
	Effort    string `json:"effort,omitempty"`
}
type BenchmarkScores struct {
	HLEText          *float64 `json:"hleText"`
	TerminalBenchV21 *float64 `json:"terminalBenchV21"`
	Tau3Banking      *float64 `json:"tau3Banking"`
}
type Facts struct {
	EvaluatedModel                      string          `json:"evaluatedModel"`
	Deprecated                          bool            `json:"deprecated"`
	IntelligenceIndex                   *float64        `json:"intelligenceIndex"`
	MedianOutputTokensPerSecond         *float64        `json:"medianOutputTokensPerSecond"`
	CostPerIntelligenceIndexTaskUSD     *float64        `json:"costPerIntelligenceIndexTaskUsd"`
	BenchmarkScores                     BenchmarkScores `json:"benchmarkScores"`
	MedianTimeToFirstAnswerTokenSeconds *float64        `json:"medianTimeToFirstAnswerTokenSeconds"`
	InputUSDPer1MTokens                 *float64        `json:"inputUsdPer1MTokens"`
	OutputUSDPer1MTokens                *float64        `json:"outputUsdPer1MTokens"`
}
type Evaluation struct {
	Slug          string        `json:"slug"`
	Configuration Configuration `json:"configuration"`
	Facts
}
type Release struct {
	Slug        string       `json:"slug"`
	Name        string       `json:"name"`
	Aliases     []string     `json:"aliases"`
	Evaluations []Evaluation `json:"evaluations"`
}
type Snapshot struct {
	Source       string    `json:"source"`
	ObservedAt   *string   `json:"observedAt"`
	Availability string    `json:"availability"`
	Releases     []Release `json:"releases"`
}
type Identity struct {
	Selector           string   `json:"selector"`
	DisplayName        string   `json:"displayName,omitempty"`
	Aliases            []string `json:"aliases,omitempty"`
	EvaluationRelease  *string  `json:"evaluationRelease,omitempty"`
	SuppressFallback   bool     `json:"-"`
	DisplayNamePresent bool     `json:"-"`
}

// MarshalJSON retains explicit unknown provenance in the bounded acquisition envelope.
func (identity Identity) MarshalJSON() ([]byte, error) {
	value := map[string]any{"selector": identity.Selector}
	if identity.DisplayNamePresent || identity.DisplayName != "" {
		value["displayName"] = identity.DisplayName
	}
	if identity.Aliases != nil {
		value["aliases"] = identity.Aliases
	}
	if identity.SuppressFallback {
		value["evaluationRelease"] = nil
	} else if identity.EvaluationRelease != nil {
		value["evaluationRelease"] = *identity.EvaluationRelease
	}
	return json.Marshal(value)
}

type AcquisitionIdentity struct {
	Names       []string
	ReleaseSlug *string
}
type persistedConfiguration struct {
	Slug          string        `json:"slug"`
	ReleaseSlug   string        `json:"releaseSlug"`
	ReleaseName   string        `json:"releaseName"`
	Configuration Configuration `json:"configuration"`
	ObservedAt    string        `json:"observedAt"`
	ETag          string        `json:"etag,omitempty"`
	Facts         *Facts        `json:"facts,omitempty"`
}
type persistedSnapshot struct {
	SchemaVersion  int                      `json:"schemaVersion"`
	Source         string                   `json:"source"`
	ObservedAt     string                   `json:"observedAt"`
	FetchedAt      string                   `json:"fetchedAt"`
	Configurations []persistedConfiguration `json:"configurations"`
}
type target struct {
	Slug, ReleaseSlug, ReleaseName string
	Configuration                  *Configuration
}

func unavailable() Snapshot {
	return Snapshot{Source: SourceID, Availability: "unavailable", Releases: []Release{}}
}
func snapshot(current *persistedSnapshot) Snapshot {
	if current == nil {
		return unavailable()
	}
	result := Snapshot{Source: SourceID, ObservedAt: &current.ObservedAt, Availability: "unavailable", Releases: []Release{}}
	indexes := map[string]int{}
	for _, entry := range current.Configurations {
		if entry.Facts == nil {
			continue
		}
		index, ok := indexes[entry.ReleaseSlug]
		if !ok {
			index = len(result.Releases)
			indexes[entry.ReleaseSlug] = index
			result.Releases = append(result.Releases, Release{Slug: entry.ReleaseSlug, Name: entry.ReleaseName, Aliases: []string{}, Evaluations: []Evaluation{}})
		}
		result.Releases[index].Evaluations = append(result.Releases[index].Evaluations, Evaluation{Slug: entry.Slug, Configuration: entry.Configuration, Facts: *entry.Facts})
	}
	if len(result.Releases) > 0 {
		result.Availability = "available"
	}
	data, _ := json.Marshal(result)
	var copy Snapshot
	_ = json.Unmarshal(data, &copy)
	return copy
}
func canonical(value any, limit int) string {
	s, ok := value.(string)
	if !ok || s == "" || len(utf16.Encode([]rune(s))) > limit || strings.TrimSpace(s) != s || strings.ContainsRune(s, 0) {
		return ""
	}
	return s
}
func iso(value string) bool {
	parsed, err := time.Parse("2006-01-02T15:04:05.000Z", value)
	return err == nil && parsed.UTC().Format("2006-01-02T15:04:05.000Z") == value
}
func isoNow(now time.Time) string     { return now.UTC().Format("2006-01-02T15:04:05.000Z") }
func record(value any) map[string]any { result, _ := value.(map[string]any); return result }
func text(value any) string           { s, _ := value.(string); return s }
func keys(value map[string]any, required, optional []string) bool {
	if value == nil {
		return false
	}
	allowed := map[string]bool{}
	for _, key := range required {
		allowed[key] = true
		if _, ok := value[key]; !ok {
			return false
		}
	}
	for _, key := range optional {
		allowed[key] = true
	}
	for key := range value {
		if !allowed[key] {
			return false
		}
	}
	return true
}
func nonnegative(value any) *float64 {
	number, ok := value.(float64)
	if !ok || math.IsNaN(number) || math.IsInf(number, 0) || number < 0 {
		return nil
	}
	return &number
}
func proportion(value any) *float64 {
	number := nonnegative(value)
	if number == nil || *number > 1 {
		return nil
	}
	return number
}
func validConfiguration(value any) bool {
	v := record(value)
	if !keys(v, []string{"reasoning"}, []string{"effort"}) {
		return false
	}
	reasoning, ok := v["reasoning"].(bool)
	if !ok {
		return false
	}
	effort, exists := v["effort"]
	return !exists || (reasoning && canonical(effort, 128) != "")
}
func validFacts(value any) bool {
	v := record(value)
	if !keys(v, []string{"evaluatedModel", "deprecated", "intelligenceIndex", "medianOutputTokensPerSecond", "costPerIntelligenceIndexTaskUsd", "benchmarkScores", "medianTimeToFirstAnswerTokenSeconds", "inputUsdPer1MTokens", "outputUsdPer1MTokens"}, nil) || canonical(v["evaluatedModel"], 512) == "" {
		return false
	}
	if _, ok := v["deprecated"].(bool); !ok {
		return false
	}
	for _, key := range []string{"intelligenceIndex", "medianOutputTokensPerSecond", "costPerIntelligenceIndexTaskUsd", "medianTimeToFirstAnswerTokenSeconds", "inputUsdPer1MTokens", "outputUsdPer1MTokens"} {
		if v[key] != nil && nonnegative(v[key]) == nil {
			return false
		}
	}
	scores := record(v["benchmarkScores"])
	if !keys(scores, BenchmarkIDs, nil) {
		return false
	}
	for _, value := range scores {
		if value != nil && proportion(value) == nil {
			return false
		}
	}
	return true
}
func parsePersisted(data []byte) (*persistedSnapshot, error) {
	if len(data) > MaxFactsBytes {
		return nil, fmt.Errorf("evaluation facts exceed %d bytes", MaxFactsBytes)
	}
	var value map[string]any
	if err := json.Unmarshal(data, &value); err != nil {
		return nil, err
	}
	if !keys(value, []string{"schemaVersion", "source", "observedAt", "fetchedAt", "configurations"}, nil) || value["schemaVersion"] != float64(1) || value["source"] != SourceID || !iso(text(value["observedAt"])) || !iso(text(value["fetchedAt"])) {
		return nil, fmt.Errorf("invalid evaluation cache envelope")
	}
	entries, ok := value["configurations"].([]any)
	if !ok || len(entries) > 10000 {
		return nil, fmt.Errorf("invalid evaluation configurations")
	}
	slugs := map[string]bool{}
	for _, raw := range entries {
		entry := record(raw)
		if !keys(entry, []string{"slug", "releaseSlug", "releaseName", "configuration", "observedAt"}, []string{"etag", "facts"}) || !validConfiguration(entry["configuration"]) || !iso(text(entry["observedAt"])) {
			return nil, fmt.Errorf("invalid evaluation configuration")
		}
		for _, key := range []string{"slug", "releaseSlug", "releaseName"} {
			if canonical(entry[key], 512) == "" {
				return nil, fmt.Errorf("invalid evaluation identity")
			}
		}
		slug := text(entry["slug"])
		if slugs[slug] {
			return nil, fmt.Errorf("duplicate evaluation configuration")
		}
		slugs[slug] = true
		if etag, ok := entry["etag"]; ok && canonical(etag, 4096) == "" {
			return nil, fmt.Errorf("invalid evaluation etag")
		}
		if facts, ok := entry["facts"]; ok && !validFacts(facts) {
			return nil, fmt.Errorf("invalid evaluation metrics")
		}
	}
	var result persistedSnapshot
	if err := json.Unmarshal(data, &result); err != nil {
		return nil, err
	}
	return &result, nil
}
