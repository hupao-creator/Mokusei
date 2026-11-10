package moku

import "github.com/hupao-creator/Mokusei/internal/core/model"

// Presets express routing priorities without assigning models to fixed tiers.
// Manual guidance is retained separately and applies only in custom mode.
func ModelRoutingGuidance(settings model.MokuSettings) string {
	switch settings.RoutingPreset {
	case "economy":
		return "Economy: prioritize cost-effective models when delegating tasks."
	case "balanced":
		// Before presets, defaults added no routing policy to the base prompt.
		// The coordinator already injects that base exactly once.
		return ""
	case "performance":
		return "Performance: prioritize frontier model capabilities when delegating tasks, including routine tasks."
	default:
		return valueOrEmpty(settings.RoutingGuidance)
	}
}
