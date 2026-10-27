package composition

import (
	"context"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/store"
)

// Removed plugin preferences must not prevent startup. Registered disabled
// plugins retain their explicit preference, including in the applied snapshot.
func reconcilePluginPreferences(ctx context.Context, database *store.Store, known map[string]bool) error {
	_, err := database.Update(ctx, func(tx *store.Tx) error {
		retain := func(settings *model.Settings) bool {
			changed := false
			for key := range settings.PluginEnabled {
				if !known[key] {
					delete(settings.PluginEnabled, key)
					changed = true
				}
			}
			return changed
		}
		var current model.Settings
		if exists, err := tx.Get("settings", &current); err != nil {
			return err
		} else if exists && retain(&current) {
			if err := tx.Put("settings", current); err != nil {
				return err
			}
		}
		var applied struct {
			Settings         model.Settings `json:"settings"`
			SettingsRevision int64          `json:"settingsRevision"`
		}
		if exists, err := tx.Get("moku-applied-settings", &applied); err != nil {
			return err
		} else if exists && retain(&applied.Settings) {
			return tx.Put("moku-applied-settings", applied)
		}
		return nil
	})
	return err
}
