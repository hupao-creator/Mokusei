package pi

import (
	"errors"
	"fmt"
	"github.com/hupao-creator/Mokusei/internal/core/model"
	"slices"
	"strings"
)

var ThinkingLevels = []string{"off", "minimal", "low", "medium", "high", "xhigh", "max"}

func NativeThinkingLevels(m Model) []string {
	if m.Reasoning == nil {
		return []string{}
	}
	if !*m.Reasoning {
		return []string{"off"}
	}
	levels := []string{}
	for _, level := range ThinkingLevels {
		mapped, found := m.ThinkingLevelMap[level]
		if found && mapped == nil {
			continue
		}
		if (level == "xhigh" || level == "max") && !found {
			continue
		}
		levels = append(levels, level)
	}
	return levels
}
func unknownThinking(reason string) model.ThinkingCapability {
	return model.ThinkingCapability{Kind: "unknown", Reason: reason}
}

// Pi's Chat RPC metadata contains explicit compat overrides, not the resolved
// defaults. Match the installed Pi 1.3 Chat encoder's detectCompat/getCompat
// effort-forwarding rule; an explicit value always takes precedence. This is
// transport behavior, not evidence that a model supports any particular effort.
func forwardsChatEffort(m Model) bool {
	if m.SupportsReasoningEffort != nil {
		return *m.SupportsReasoningEffort
	}
	if slices.Contains([]string{"xai", "zai", "zai-coding-cn", "moonshotai", "moonshotai-cn", "together", "cloudflare-ai-gateway", "nvidia", "ant-ling"}, m.Provider) {
		return false
	}
	for _, host := range []string{"api.x.ai", "api.z.ai", "open.bigmodel.cn", "api.moonshot.", "api.together.ai", "api.together.xyz", "gateway.ai.cloudflare.com", "integrate.api.nvidia.com", "api.ant-ling.com"} {
		if strings.Contains(m.BaseURL, host) {
			return false
		}
	}
	return true
}

func nativeService(m Model, levels []string) model.ThinkingCapability {
	if m.API != "openai-completions" {
		return unknownThinking("This Pi native transport has no verified exact thinking encoding")
	}
	if !forwardsChatEffort(m) {
		if m.ThinkingFormat == "deepseek" {
			return model.ThinkingCapability{Kind: "toggle"}
		}
		return unknownThinking("Pi disables effort forwarding and does not expose a confirmed thinking switch")
	}
	if m.ThinkingFormat != "deepseek" && m.ThinkingFormat != "openai" {
		return unknownThinking("Pi Chat model thinking dialect has no verified effort encoding")
	}
	efforts := []string{}
	for _, level := range levels {
		mapped := m.ThinkingLevelMap[level]
		if level != "off" && mapped != nil && *mapped != "none" && *mapped != "off" && !slices.Contains(efforts, *mapped) {
			efforts = append(efforts, *mapped)
		}
	}
	if len(efforts) == 0 {
		return unknownThinking("Pi native Chat model does not declare concrete effort mappings")
	}
	return model.ThinkingCapability{Kind: "effort", Efforts: efforts, CanDisable: m.ThinkingFormat == "deepseek" || mappedLevel(m, "off") == "none"}
}
func mappedLevel(m Model, level string) string {
	if value, ok := m.ThinkingLevelMap[level]; ok {
		if value == nil {
			return ""
		}
		return *value
	}
	return level
}
func ThinkingCapability(m Model, levels []string) model.ThinkingCapability {
	if levels == nil {
		levels = NativeThinkingLevels(m)
	}
	if m.HasRequestOverrides {
		return unknownThinking("Pi model has custom request overrides that can replace its selected model or thinking choice")
	}
	if m.Reasoning == nil {
		return unknownThinking("Pi did not report whether this exact model has a thinking control")
	}
	if !*m.Reasoning {
		return model.ThinkingCapability{Kind: "fixed"}
	}
	filtered := []string{}
	for _, level := range levels {
		if value, ok := m.ThinkingLevelMap[level]; !ok || value != nil {
			filtered = append(filtered, level)
		}
	}
	levels = filtered
	if m.API == "openai-responses" {
		// Pi's Responses transport forwards thinkingLevelMap values directly
		// to reasoning.effort. Require explicit mappings; never infer support
		// merely from reasoning=true or an authenticated provider.
		efforts := []string{}
		for _, level := range levels {
			mapped, exists := m.ThinkingLevelMap[level]
			if level != "off" && exists && mapped != nil && slices.Contains([]string{"minimal", "low", "medium", "high", "xhigh", "max"}, *mapped) && !slices.Contains(efforts, *mapped) {
				efforts = append(efforts, *mapped)
			}
		}
		if len(efforts) == 0 {
			return unknownThinking("Pi Responses model has no explicit supported effort mappings")
		}
		off := m.ThinkingLevelMap["off"]
		return model.ThinkingCapability{Kind: "effort", Efforts: efforts, CanDisable: slices.Contains(levels, "off") && off != nil && *off == "none"}
	}
	if m.API != "openai-completions" {
		return unknownThinking("This Pi native transport has no verified exact thinking encoding")
	}
	service := nativeService(m, levels)
	if service.Kind == "unknown" {
		return service
	}
	if len(levels) == 0 {
		return unknownThinking("Pi returned no supported thinking levels for this model")
	}
	if service.Kind == "toggle" {
		if m.ThinkingFormat == "deepseek" && slices.Contains(levels, "off") && len(levels) > 1 {
			return service
		}
		return unknownThinking("Pi cannot faithfully encode this model thinking switch")
	}
	if service.Kind == "effort" {
		if m.ThinkingFormat != "deepseek" && m.ThinkingFormat != "openai" {
			return unknownThinking("Pi has no verified effort encoding for this thinking dialect")
		}
		efforts := []string{}
		for _, effort := range service.Efforts {
			if effort == "none" || effort == "off" {
				continue
			}
			for _, level := range levels {
				if level != "off" && mappedLevel(m, level) == effort {
					efforts = append(efforts, effort)
					break
				}
			}
		}
		if len(efforts) == 0 {
			return unknownThinking("Pi cannot encode any declared model effort level")
		}
		return model.ThinkingCapability{Kind: "effort", Efforts: efforts, CanDisable: service.CanDisable && slices.Contains(levels, "off") && (m.ThinkingFormat == "deepseek" || mappedLevel(m, "off") == "none")}
	}
	return unknownThinking("Pi reported reasoning without a confirmed adjustable control")
}
func ThinkingLevel(choice model.ThinkingChoice, m Model, levels []string) (string, error) {
	if levels == nil {
		levels = NativeThinkingLevels(m)
	}
	capability := ThinkingCapability(m, levels)
	switch choice.Mode {
	case "fixed":
		if capability.Kind == "fixed" {
			return "off", nil
		}
	case "off":
		if capability.Kind == "toggle" || capability.Kind == "effort" && capability.CanDisable {
			return "off", nil
		}
	case "on":
		if capability.Kind == "toggle" {
			for _, level := range levels {
				if level != "off" {
					return level, nil
				}
			}
		}
	case "effort":
		if capability.Kind == "effort" && slices.Contains(capability.Efforts, choice.Effort) {
			for _, level := range levels {
				if level != "off" && mappedLevel(m, level) == choice.Effort {
					return level, nil
				}
			}
		}
	default:
		return "", errors.New("invalid Pi thinking choice")
	}
	return "", fmt.Errorf("Pi %s/%s cannot encode thinking choice %s: %s", m.Provider, m.ID, choice.Mode, capability.Reason)
}
