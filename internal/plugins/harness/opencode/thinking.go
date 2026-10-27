package opencode

import (
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"strings"

	"github.com/hupao-creator/Mokusei/internal/core/model"
)

func unknownThinking(reason string) model.ThinkingCapability {
	return model.ThinkingCapability{Kind: "unknown", Reason: reason}
}
func ThinkingCapability(native CatalogModel) model.ThinkingCapability {
	if native.UnavailableReason != "" {
		return unknownThinking(native.UnavailableReason)
	}
	if native.HasRequestOverrides {
		return unknownThinking("OpenCode custom request fields can replace the selected model or thinking choice")
	}
	var variants []CatalogVariant
	for _, variant := range native.Variants {
		if variant.ID != "default" {
			variants = append(variants, variant)
		}
	}
	if len(variants) == 0 {
		return model.ThinkingCapability{Kind: "fixed"}
	}
	off, on := false, false
	efforts := []string{}
	for _, variant := range variants {
		control := variantControl(native, variant)
		if control == nil {
			return unknownThinking("OpenCode returned a variant without a verified thinking encoding")
		}
		switch control.Mode {
		case "off":
			off = true
		case "on":
			on = true
		case "effort":
			if !slices.Contains(efforts, control.Effort) {
				efforts = append(efforts, control.Effort)
			}
		}
	}
	if len(efforts) > 0 {
		return model.ThinkingCapability{Kind: "effort", Efforts: efforts, CanDisable: off}
	}
	if off && on {
		return model.ThinkingCapability{Kind: "toggle"}
	}
	return unknownThinking("OpenCode does not expose a complete adjustable thinking control")
}
func ThinkingVariant(choice model.ThinkingChoice, native CatalogModel) (string, error) {
	if err := assertThinkingChoice(choice, ThinkingCapability(native)); err != nil {
		return "", err
	}
	if choice.Mode == "fixed" {
		return "", nil
	}
	for _, variant := range native.Variants {
		if variant.ID == "default" {
			continue
		}
		control := variantControl(native, variant)
		if control != nil && control.Mode == choice.Mode && (choice.Mode != "effort" || control.Effort == choice.Effort) {
			return variant.ID, nil
		}
	}
	return "", errors.New("OpenCode has no exact variant for the selected thinking choice")
}
func VariantMatchesThinking(choice model.ThinkingChoice, native CatalogModel, id string) bool {
	if choice.Mode == "fixed" {
		return id == ""
	}
	if id == "" || id == "default" {
		return false
	}
	for _, variant := range native.Variants {
		if variant.ID != id {
			continue
		}
		control := variantControl(native, variant)
		return control != nil && control.Mode == choice.Mode && (choice.Mode != "effort" || control.Effort == choice.Effort)
	}
	return false
}
func AgentThinkingCapability(native CatalogModel, agent *CatalogAgent) model.ThinkingCapability {
	if native.UnavailableReason != "" {
		return unknownThinking(native.UnavailableReason)
	}
	if agent != nil && (agent.HasRequestOverrides || hasThinkingOrModelOverrides(agent.Body)) {
		return unknownThinking("The selected OpenCode agent overrides model, account, or thinking request fields")
	}
	if native.Thinking != nil {
		return *native.Thinking
	}
	return ThinkingCapability(native)
}
func hasThinkingOrModelOverrides(value Object) bool {
	return hasCatalogField(value, "model", "messages", "input", "tools", "tool_choice", "thinking", "reasoning", "reasoning_effort", "output_config", "generationConfig", "enable_thinking", "thinking_budget", "chat_template_kwargs")
}
func firstDefined(values ...any) any {
	for _, value := range values {
		if value != nil {
			return value
		}
	}
	return nil
}
func variantControl(native CatalogModel, variant CatalogVariant) *model.ThinkingChoice {
	settings := mergeOpenCodeConfig(native.Settings, variant.Settings)
	body := mergeOpenCodeConfig(native.Body, variant.Body)
	thinking := configRecord(firstDefined(body["thinking"], settings["thinking"]))
	config := configRecord(firstDefined(configRecord(body["generationConfig"])["thinkingConfig"], settings["thinkingConfig"]))
	reason := configRecord(firstDefined(body["reasoning"], settings["reasoning"]))
	choice := func(mode, effort string) *model.ThinkingChoice {
		return &model.ThinkingChoice{Mode: mode, Effort: effort}
	}
	if thinking["type"] == "disabled" || reason["enabled"] == false || body["enable_thinking"] == false || settings["enableThinking"] == false || numericEquals(config["thinkingBudget"], 0) {
		return choice("off", "")
	}
	effort := firstDefined(body["reasoning_effort"], configRecord(body["output_config"])["effort"], reason["effort"], settings["reasoningEffort"], settings["effort"], config["thinkingLevel"])
	if effort == "none" || effort == "off" {
		return choice("off", "")
	}
	if text, ok := effort.(string); ok && text != "" {
		return choice("effort", text)
	}
	budget := firstDefined(thinking["budget_tokens"], thinking["budgetTokens"], config["thinkingBudget"])
	if budget != nil && number(budget) > 0 {
		return choice("effort", variant.ID)
	}
	if thinking["type"] == "enabled" || thinking["type"] == "adaptive" || reason["enabled"] == true || body["enable_thinking"] == true || settings["enableThinking"] == true || numericEquals(budget, -1) {
		return choice("on", "")
	}
	return nil
}
func numericEquals(value any, expected float64) bool {
	switch value.(type) {
	case float64, int, int64, json.Number:
		return number(value) == expected
	}
	return false
}
func normalizeThinking(raw any) (*model.ThinkingChoice, error) {
	value, ok := configObject(raw)
	if !ok {
		return nil, errors.New("OpenCode thinking must be an object")
	}
	for key := range value {
		if key != "mode" && key != "effort" {
			return nil, fmt.Errorf("OpenCode thinking contains unknown field: %s", key)
		}
	}
	mode, ok := value["mode"].(string)
	if !ok || !slices.Contains([]string{"fixed", "off", "on", "effort"}, mode) {
		return nil, errors.New("OpenCode thinking has an invalid mode")
	}
	choice := &model.ThinkingChoice{Mode: mode}
	effort, exists := value["effort"]
	if mode == "effort" {
		text, ok := effort.(string)
		if !ok || text == "" || strings.TrimSpace(text) != text || strings.ContainsRune(text, 0) || len(text) > 64 || strings.EqualFold(text, "default") {
			return nil, errors.New("OpenCode thinking effort must be a canonical nonempty string")
		}
		choice.Effort = text
	} else if exists {
		return nil, errors.New("OpenCode non-effort thinking choice cannot carry an effort")
	}
	return choice, nil
}
func assertThinkingChoice(choice model.ThinkingChoice, capability model.ThinkingCapability) error {
	if choice.Mode == "effort" {
		if _, err := normalizeThinking(Object{"mode": choice.Mode, "effort": choice.Effort}); err != nil {
			return err
		}
	} else if choice.Effort != "" {
		return errors.New("OpenCode non-effort thinking choice cannot carry an effort")
	}
	switch capability.Kind {
	case "fixed":
		if choice.Mode == "fixed" {
			return nil
		}
	case "toggle":
		if choice.Mode == "off" || choice.Mode == "on" {
			return nil
		}
	case "effort":
		if choice.Mode == "off" && capability.CanDisable || choice.Mode == "effort" && slices.Contains(capability.Efforts, choice.Effort) {
			return nil
		}
	case "unknown":
		return fmt.Errorf("OpenCode thinking is unavailable: %s", capability.Reason)
	}
	return errors.New("OpenCode does not support the selected thinking choice")
}
func thinkingSchema(capability model.ThinkingCapability) Object {
	simple := func(mode string) Object {
		return Object{"type": "object", "additionalProperties": false, "required": []string{"mode"}, "properties": Object{"mode": Object{"type": "string", "const": mode}}}
	}
	choices := []any{}
	switch capability.Kind {
	case "fixed":
		return simple("fixed")
	case "toggle":
		choices = append(choices, simple("off"), simple("on"))
	case "effort":
		if capability.CanDisable {
			choices = append(choices, simple("off"))
		}
		choices = append(choices, Object{"type": "object", "additionalProperties": false, "required": []string{"mode", "effort"}, "properties": Object{"mode": Object{"type": "string", "const": "effort"}, "effort": Object{"type": "string", "enum": capability.Efforts}}})
	default:
		return Object{"not": Object{}}
	}
	return Object{"oneOf": choices}
}
