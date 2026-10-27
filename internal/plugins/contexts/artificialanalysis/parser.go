package artificialanalysis

import (
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
)

var embeddedArray = regexp.MustCompile(`\\"([A-Za-z0-9_]+)\\":\[\{\\"`)

type embedded struct {
	key     string
	entries []any
}

func readEmbeddedJSON(raw string, start int) string {
	var decoded strings.Builder
	depth := 0
	inString, escaped := false, false
	for index := start; index < len(raw); index++ {
		character := raw[index]
		if character == '\\' && index+1 < len(raw) && (raw[index+1] == '"' || raw[index+1] == '\\') {
			index++
			character = raw[index]
		}
		decoded.WriteByte(character)
		if inString {
			if escaped {
				escaped = false
			} else if character == '\\' {
				escaped = true
			} else if character == '"' {
				inString = false
			}
			continue
		}
		switch character {
		case '"':
			inString = true
		case '{', '[':
			depth++
		case '}', ']':
			depth--
			if depth == 0 {
				return decoded.String()
			}
		}
	}
	return ""
}
func embeddedArrays(html string) []embedded {
	result := []embedded{}
	for _, match := range embeddedArray.FindAllStringSubmatchIndex(html, -1) {
		key := html[match[2]:match[3]]
		start := match[0] + strings.IndexByte(html[match[0]:match[1]], '[')
		data := readEmbeddedJSON(html, start)
		var entries []any
		if data != "" && json.Unmarshal([]byte(data), &entries) == nil {
			result = append(result, embedded{key, entries})
		}
	}
	return result
}
func configurationIdentity(value any) *target {
	v := record(value)
	release := record(v["release"])
	slug := canonical(v["slug"], 512)
	reasoning, ok := v["isReasoning"].(bool)
	releaseSlug, releaseName := canonical(release["slug"], 512), canonical(release["name"], 512)
	if slug == "" || !ok || releaseSlug == "" || releaseName == "" {
		return nil
	}
	config := Configuration{Reasoning: reasoning}
	if reasoning {
		config.Effort = canonical(record(v["effort"])["slug"], 512)
	}
	return &target{Slug: slug, ReleaseSlug: releaseSlug, ReleaseName: releaseName, Configuration: &config}
}
func parseIndex(html string) []target {
	configurations := []target{}
	seen := map[string]bool{}
	releases := map[string]string{}
	roster := []any{}
	for _, array := range embeddedArrays(html) {
		for _, entry := range array.entries {
			identity := configurationIdentity(entry)
			if identity != nil && !seen[identity.Slug] {
				seen[identity.Slug] = true
				configurations = append(configurations, *identity)
			}
			v := record(entry)
			if v == nil {
				continue
			}
			if array.key == "releases" {
				slug, name := canonical(v["slug"], 512), canonical(v["name"], 512)
				if slug != "" && name != "" {
					releases[slug] = name
				}
			} else if array.key == "models" {
				roster = append(roster, entry)
			}
		}
	}
	for _, entry := range roster {
		v := record(entry)
		slug, releaseSlug := canonical(v["slug"], 512), canonical(v["releaseSlug"], 512)
		name := releases[releaseSlug]
		if slug != "" && releaseSlug != "" && name != "" && !seen[slug] {
			seen[slug] = true
			configurations = append(configurations, target{Slug: slug, ReleaseSlug: releaseSlug, ReleaseName: name})
		}
	}
	return configurations
}
func parsePage(html, expected string) (target, Facts, error) {
	var model any
	marker := `\"currentModel\":`
	if index := strings.Index(html, marker); index >= 0 {
		data := readEmbeddedJSON(html, index+len(marker))
		if data != "" {
			if err := json.Unmarshal([]byte(data), &model); err != nil {
				return target{}, Facts{}, err
			}
		}
	}
	if record(model) == nil || record(model)["slug"] != expected {
		model = nil
	search:
		for _, array := range embeddedArrays(html) {
			for _, entry := range array.entries {
				if record(entry)["slug"] == expected && configurationIdentity(entry) != nil {
					model = entry
					break search
				}
			}
		}
	}
	identity := configurationIdentity(model)
	v := record(model)
	if identity == nil || v == nil {
		return target{}, Facts{}, fmt.Errorf("AA model identity is invalid")
	}
	name := canonical(v["name"], 512)
	if name == "" {
		name = identity.Slug
	}
	deprecated, _ := v["deprecated"].(bool)
	facts := Facts{EvaluatedModel: name, Deprecated: deprecated, IntelligenceIndex: nonnegative(v["intelligenceIndex"]), MedianOutputTokensPerSecond: nonnegative(record(v["timescaleData"])["medianOutputSpeed"]), CostPerIntelligenceIndexTaskUSD: nonnegative(record(record(v["intelligenceIndexCostPerTask"])["cost"])["total"]), BenchmarkScores: BenchmarkScores{HLEText: proportion(v["hle"]), TerminalBenchV21: proportion(v["terminalBench21"]), Tau3Banking: proportion(v["tauBanking"])}, MedianTimeToFirstAnswerTokenSeconds: nonnegative(record(v["timeToFirstAnswerToken"])["total"]), InputUSDPer1MTokens: nonnegative(v["price1mInputTokens"]), OutputUSDPer1MTokens: nonnegative(v["price1mOutputTokens"])}
	return *identity, facts, nil
}
