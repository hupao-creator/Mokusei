package plugin

import (
	"encoding/json"
	"fmt"

	"github.com/hupao-creator/Mokusei/internal/core/model"
)

// BackgroundExecutionEnabled defaults omitted enablement to the existing behavior.
// Values reach this reader through the owning settings contract.
func BackgroundExecutionEnabled(value json.RawMessage) (bool, error) {
	var control struct {
		Enabled *bool `json:"enabled"`
	}
	if err := json.Unmarshal(value, &control); err != nil {
		return false, err
	}
	return control.Enabled == nil || *control.Enabled, nil
}

// RequireBackgroundExecution fences work against the same saved settings snapshot
// used by a native admission or a write transaction. Empty IDs have no switch.
func RequireBackgroundExecution(settings model.Settings, id string) error {
	if id == "" {
		return nil
	}
	for _, entry := range settings.PluginSettings {
		if entry.ID != id {
			continue
		}
		enabled, err := BackgroundExecutionEnabled(entry.Value)
		if err != nil {
			return err
		}
		if !enabled {
			return model.NewError("BACKGROUND_AGENT_DISABLED", "Background agent is disabled")
		}
		return nil
	}
	return fmt.Errorf("missing background settings: %s", id)
}
