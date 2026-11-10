package moku

import (
	"encoding/json"
	"strings"

	"github.com/hupao-creator/Mokusei/internal/core/model"
)

// These are product routing groups, not price or benchmark claims. Match exact
// native IDs in the admitted catalog; unknown models never acquire a tier just
// because their name contains "free", "pro" or another suggestive substring.
var routingModelGroups = map[string]string{
	"gpt-reserve": "economy", "gpt-6-luna": "economy", "gpt-5.6-luna": "economy",
	"gpt-5.6-terra": "economy", "gpt-5.4-mini": "economy", "gpt-5.4-nano": "economy",
	"claude-haiku-5-5": "economy", "claude-haiku-4-5": "economy", "claude-haiku-4-5-20251001": "economy",
	"deepseek-flash": "economy", "deepseek-v4-flash": "economy", "deepseek-v4-flash-free": "economy", "bonsai-2-27b": "economy",
	"gpt-6-astra": "frontier", "gpt-6.1-sol": "frontier", "gpt-6.1-terra": "frontier", "gpt-6-sol": "frontier",
	"claude-opus-5-5": "frontier", "claude-fable-5": "frontier", "claude-fable-5-1": "frontier", "claude-fable-5-2": "frontier",
}

// ModelRoutingGuidance uses the same immutable discovery snapshot as creation
// tools. Manual guidance is retained separately and applies only in custom mode.
// This remains model guidance; native creation admission owns actual availability.
func ModelRoutingGuidance(settings model.MokuSettings, description ThreadCreationDescription) string {
	if settings.RoutingPreset == "" || settings.RoutingPreset == "custom" {
		return valueOrEmpty(settings.RoutingGuidance)
	}
	groups := map[string][]map[string]string{"economy": {}, "frontier": {}}
	for _, entry := range description.RoutingModels {
		if group := routingModelGroups[entry.ID]; group != "" {
			groups[group] = append(groups[group], map[string]string{"harness": entry.HarnessID, "provider": entry.Provider, "model": entry.ID})
		}
	}
	var policy string
	switch settings.RoutingPreset {
	case "economy":
		policy = "Economy: delegate only to the cost-effective models listed below. Do not upgrade to frontier or unclassified models."
		delete(groups, "frontier")
	case "balanced":
		policy = "Balanced: use the listed cost-effective models for routine, bounded tasks; use the listed frontier models for complex reasoning, difficult debugging and high-impact decisions. Choose the least expensive suitable tier."
	case "performance":
		policy = "Performance: delegate only to the frontier models listed below, including routine tasks. Do not downgrade to cost-effective or unclassified models."
		delete(groups, "economy")
	default:
		return valueOrEmpty(settings.RoutingGuidance)
	}
	encoded, _ := json.Marshal(groups)
	return strings.Join([]string{policy,
		"Candidates are exact native identities from the selected Harness catalogs, not guarantees of credentials or quota. Use only candidates with supported creation options. If no suitable listed model is available, explain that and ask the user to change the preference or configure a model; do not silently choose outside these groups.",
		"Candidate groups: " + string(encoded)}, "\n")
}
