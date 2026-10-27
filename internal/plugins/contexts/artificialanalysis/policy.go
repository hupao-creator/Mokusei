package artificialanalysis

import (
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"unicode/utf8"
)

const FactsScope = "Objective model evaluation facts and selection advice for native catalog models that uniquely match one source release with at least one source-observed evaluation configuration. Configurations retain their published metrics even when other metrics are missing. Native-supported models remain selectable regardless of missing or poor evaluation results."
const FactsMeaning = "Each evaluation describes only the source-observed configuration named by reasoning and optional effort. Intelligence Index, median output tokens per second, and cost per Intelligence Index task are configuration facts; they do not describe a local subscription, re-hosted route, or service tier. Null means that metric is unavailable, not zero or evidence of poor performance. A local reasoning, variant, or service-tier selection without an exactly matching evaluation is unmeasured. deprecated is evaluator source metadata only: it does not remove a model from its provider-native catalog. Configuration choices and validation belong to the native settings contract; these facts do not add constraints."
const ScoreMeaning = "Benchmark scores are optional evaluator-native proportions for the same evaluation configuration. Null means the source published no score; scores are not normalized, combined, or converted into ranks."
const RoutingGuidance = "When routing models, prefer high-intelligence models for complex planning, critical decisions, and independent review, accepting higher cost when warranted. For execution with verifiable results, prefer models that are sufficiently capable, low-cost, and fast. For low-risk information retrieval and initial screening, always prefer the lowest-cost available candidate capable of completing the task, and upgrade only when there is a clear capability, tooling, or reliability gap. Raise the model tier when a task is high-risk, ambiguous, difficult to verify, or requires synthesis and judgment. Treat only the published quality, speed, cost, and benchmark fields as measured evidence."
const truncatedMarker = "Additional evaluation knowledge omitted by the bounded formatter."

func boundedText(value string, limit int) string {
	value = strings.TrimSpace(strings.NewReplacer("\r", " ", "\n", " ", "\x00", " ").Replace(value))
	runes := []rune(value)
	if len(runes) <= limit {
		return value
	}
	return string(runes[:max(0, limit-1)]) + "…"
}
func bounded(value string) string {
	if len(value) <= MaxFormattedBytes {
		return value
	}
	limit := MaxFormattedBytes - len(truncatedMarker) - 1
	for limit > 0 && !utf8.ValidString(value[:limit]) {
		limit--
	}
	return strings.TrimRight(value[:limit], " \t\r\n") + "\n" + truncatedMarker
}
func number(value *float64) string {
	if value == nil {
		return "null"
	}
	return strconv.FormatFloat(*value, 'f', -1, 64)
}
func observed(snapshot Snapshot) string {
	if snapshot.ObservedAt == nil {
		return "unavailable"
	}
	return *snapshot.ObservedAt
}
func Preamble(snapshot Snapshot, scope string) string {
	if scope == "" {
		scope = FactsScope
	}
	lines := []string{"Evaluation source: " + boundedText(snapshot.Source, 256) + ".", "Evaluation availability: " + snapshot.Availability + ".", "Evaluation knowledge observed at: " + observed(snapshot) + ".", "Scope: " + scope, "Release association: Native catalog names may be associated with source releases through conservative fuzzy matching. Ambiguous matches are omitted. This association is advisory and does not establish that a native route or local configuration reproduces the measured evaluation.", "Routing guidance: " + RoutingGuidance, "Evaluation meaning: " + FactsMeaning, "Benchmark score meaning: " + ScoreMeaning, "Benchmark definitions:", "- hleText: Humanity's Last Exam (text-only); evaluator=Artificial Analysis; dataset=Text-only HLE questions scored inside the Artificial Analysis Intelligence Index; metric=pass@1; unit=proportion; range=0..1; harness=Artificial Analysis zero-shot text evaluation; repeats=1", "- terminalBenchV21: Terminal-Bench 2.1; evaluator=Artificial Analysis; dataset=Terminal-Bench 2.1 scored inside the Artificial Analysis Intelligence Index; metric=test-suite pass@1; unit=proportion; range=0..1; harness=Terminus 2", "- tau3Banking: τ³-Banking; evaluator=Artificial Analysis; dataset=τ³-Banking scored inside the Artificial Analysis Intelligence Index; metric=backend-state pass@1; unit=proportion; range=0..1; harness=Artificial Analysis agent-user simulation"}
	return bounded(strings.Join(lines, "\n"))
}
func FormatRelease(snapshot Snapshot, match Match) string {
	if snapshot.Availability != "available" {
		return "Evaluation facts unavailable; native-supported configurations remain selectable."
	}
	if match.Status == "unmatched" {
		return "No evaluation release matched; this native model is unmeasured and remains selectable."
	}
	if match.Status == "ambiguous" {
		return "Evaluation release matching is ambiguous; uncertain facts are omitted and the native model remains selectable."
	}
	release := match.Release
	lines := []string{fmt.Sprintf("Canonical evaluation release: %s (%s).", boundedText(release.Slug, 512), boundedText(release.Name, 512)), "Evaluation knowledge observed at: " + observed(snapshot) + "."}
	evaluations := release.Evaluations[:min(64, len(release.Evaluations))]
	for _, e := range evaluations {
		configuration := "reasoning:" + strconv.FormatBool(e.Configuration.Reasoning)
		if e.Configuration.Reasoning && e.Configuration.Effort != "" {
			configuration += ",effort:" + boundedText(e.Configuration.Effort, 128)
		}
		lines = append(lines, strings.Join([]string{"- configuration=" + configuration, "slug=" + boundedText(e.Slug, 512), "evaluatedModel=" + boundedText(e.EvaluatedModel, 512), "deprecated=" + strconv.FormatBool(e.Deprecated), "intelligenceIndex=" + number(e.IntelligenceIndex), "medianOutputTokensPerSecond=" + number(e.MedianOutputTokensPerSecond), "costPerIntelligenceIndexTaskUsd=" + number(e.CostPerIntelligenceIndexTaskUSD), "medianTimeToFirstAnswerTokenSeconds=" + number(e.MedianTimeToFirstAnswerTokenSeconds), "inputUsdPer1MTokens=" + number(e.InputUSDPer1MTokens), "outputUsdPer1MTokens=" + number(e.OutputUSDPer1MTokens), "benchmarkScores=hleText:" + number(e.BenchmarkScores.HLEText) + ",terminalBenchV21:" + number(e.BenchmarkScores.TerminalBenchV21) + ",tau3Banking:" + number(e.BenchmarkScores.Tau3Banking)}, "; "))
	}
	if len(release.Evaluations) > len(evaluations) {
		lines = append(lines, fmt.Sprintf("- %d additional evaluation configurations omitted by the bounded formatter.", len(release.Evaluations)-len(evaluations)))
	}
	return bounded(strings.Join(lines, "\n"))
}
func FormatCached(snapshot Snapshot) string {
	available := false
	for _, release := range snapshot.Releases {
		if len(release.Evaluations) > 0 {
			available = true
		}
	}
	if !available {
		snapshot.Availability = "unavailable"
	}
	lines := []string{Preamble(snapshot, "Historical evaluator snapshot used because current native catalog evaluation context is unavailable. Facts may be stale and are not evidence that these models or configurations are currently selectable. Use native settings to determine availability.")}
	if snapshot.Availability == "available" {
		for i := range snapshot.Releases {
			lines = append(lines, FormatRelease(snapshot, Match{Status: "matched", Release: &snapshot.Releases[i]}))
		}
	} else {
		lines = append(lines, "No live or cached AA measurements are available. Model evaluation is unknown; native-supported configurations remain selectable.")
	}
	return bounded(strings.Join(lines, "\n"))
}

type NativeModel struct {
	Label    string
	Identity Identity
}

func FormatModels(snapshot Snapshot, models []NativeModel) string {
	type group struct {
		match  Match
		labels []string
	}
	groups := []group{}
	indexes := map[string]int{}
	unmatched, ambiguous := []string{}, []string{}
	for _, model := range models[:min(512, len(models))] {
		label := boundedText(model.Label, 512)
		match := MatchRelease(snapshot, model.Identity)
		switch match.Status {
		case "unmatched":
			unmatched = append(unmatched, label)
		case "ambiguous":
			ambiguous = append(ambiguous, label)
		default:
			if index, ok := indexes[match.Release.Slug]; ok {
				groups[index].labels = append(groups[index].labels, label)
			} else {
				indexes[match.Release.Slug] = len(groups)
				groups = append(groups, group{match, []string{label}})
			}
		}
	}
	footer := func(compact bool) []string {
		lines := []string{}
		if len(unmatched) > 0 {
			lines = append(lines, "Unmeasured native catalog identities: "+strings.Join(unmatched, ", ")+".")
		}
		if len(ambiguous) > 0 {
			line := "Ambiguous evaluation matches: " + strings.Join(ambiguous, ", ") + "."
			if !compact {
				line += " No evaluation facts are attributed to these identities."
			}
			lines = append(lines, line)
		}
		if len(models) > 512 {
			lines = append(lines, fmt.Sprintf("%d additional native catalog identities omitted by the bounded formatter.", len(models)-512))
		}
		return lines
	}
	lines := []string{Preamble(snapshot, ""), "Objective evaluation facts for this native catalog:"}
	for _, group := range groups {
		lines = append(lines, "Native catalog identities: "+strings.Join(group.labels, ", ")+".", FormatRelease(snapshot, group.match))
	}
	lines = append(lines, footer(false)...)
	full := strings.Join(lines, "\n")
	if len(full) <= MaxFormattedBytes {
		return full
	}
	lines = []string{Preamble(snapshot, ""), "Objective evaluation facts for this native catalog (compact JSON rows):", "Each row uses columns: slug, reasoning, effort, evaluatedModel, deprecated, intelligenceIndex, medianOutputTokensPerSecond, costPerIntelligenceIndexTaskUsd, medianTimeToFirstAnswerTokenSeconds, inputUsdPer1MTokens, outputUsdPer1MTokens, hleText, terminalBenchV21, tau3Banking. Null retains its usual meaning."}
	for _, group := range groups {
		release := group.match.Release
		lines = append(lines, "Native catalog identities: "+strings.Join(group.labels, ", ")+".", fmt.Sprintf("Canonical evaluation release: %s (%s).", release.Slug, release.Name))
		for _, e := range release.Evaluations {
			var effort any
			if e.Configuration.Effort != "" {
				effort = e.Configuration.Effort
			}
			row := []any{e.Slug, e.Configuration.Reasoning, effort, e.EvaluatedModel, e.Deprecated, e.IntelligenceIndex, e.MedianOutputTokensPerSecond, e.CostPerIntelligenceIndexTaskUSD, e.MedianTimeToFirstAnswerTokenSeconds, e.InputUSDPer1MTokens, e.OutputUSDPer1MTokens, e.BenchmarkScores.HLEText, e.BenchmarkScores.TerminalBenchV21, e.BenchmarkScores.Tau3Banking}
			data, _ := json.Marshal(row)
			lines = append(lines, string(data))
		}
	}
	lines = append(lines, footer(true)...)
	accepted := []string{}
	size := 0
	for _, line := range lines {
		next := len(line) + 1
		if size+next+len(truncatedMarker) > MaxCatalogBytes {
			accepted = append(accepted, truncatedMarker)
			break
		}
		accepted = append(accepted, line)
		size += next
	}
	return strings.Join(accepted, "\n")
}
