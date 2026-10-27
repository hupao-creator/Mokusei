package background

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

func SettingsContract() plugin.ValueContract {
	return plugin.ValueContract{ID: "mokusei.background-settings", SchemaVersion: 1, Parse: parseSettings}
}
func parseSettings(raw json.RawMessage) (json.RawMessage, error) {
	object, err := model.DecodeObject(raw)
	if err != nil {
		return nil, err
	}
	mode, _ := object["mode"].(string)
	allowed := map[string]bool{"mode": true}
	if mode == "inherit" {
		allowed["independent"] = true
		if independent, ok := object["independent"]; ok {
			settings, ok := independent.(map[string]any)
			if !ok {
				return nil, errors.New("Invalid independent execution settings")
			}
			for key := range settings {
				if key != "harnessPreference" && key != "harnesses" {
					return nil, errors.New("Invalid independent execution settings")
				}
			}
			next := map[string]any{"mode": "override", "harnessPreference": settings["harnessPreference"], "harnesses": settings["harnesses"]}
			encoded, err := json.Marshal(next)
			if err != nil {
				return nil, err
			}
			if _, err = parseSettings(encoded); err != nil {
				return nil, err
			}
		}
	} else if mode == "override" {
		allowed["harnessPreference"] = true
		allowed["harnesses"] = true
		preference, ok := object["harnessPreference"].(string)
		if !ok || preference == "" {
			return nil, errors.New("Invalid background execution overrides")
		}
		harnesses, ok := object["harnesses"].(map[string]any)
		if !ok {
			return nil, errors.New("Invalid background execution overrides")
		}
		for _, value := range harnesses {
			if _, ok := value.(map[string]any); !ok {
				return nil, errors.New("Invalid background execution overrides")
			}
		}
	} else {
		return nil, errors.New("Invalid background settings")
	}
	for key := range object {
		if !allowed[key] {
			return nil, fmt.Errorf("unexpected background settings field %s", key)
		}
	}
	return json.Marshal(object)
}
func RegisterSettings(registry plugin.Registry, owner, id string) error {
	contract := SettingsContract()
	return registry.Settings(plugin.SettingsDefinition{ID: id, OwnerPluginID: owner, Contract: contract, Defaults: json.RawMessage(`{"mode":"inherit"}`), Validate: func(_ context.Context, value json.RawMessage, _ plugin.CapabilityAccess) (json.RawMessage, error) {
		return contract.Validate(value)
	}})
}
func LanguageInstructions(locale string, policy func(string) string) string {
	language := "English"
	if locale == "zh-CN" {
		language = "Simplified Chinese"
	}
	return fmt.Sprintf("Current application output language: %s (%s). This is the authoritative language for this batch, overriding language inferred from source material and earlier session messages. %s Preserve code, identifiers, proper names, source quotations, and directory names where needed for accuracy.", language, locale, policy(language))
}
