package composition

import (
	"path/filepath"
	"reflect"
	"testing"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/store"
)

func TestReconcilePluginPreferencesPreservesRegisteredDisabledPlugins(t *testing.T) {
	database, err := store.Open(filepath.Join(t.TempDir(), "state.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer database.Close()
	settings := model.Settings{PluginEnabled: map[string]bool{"extension:removed": true, "provider:removed": false, "extension:kept": false}}
	if _, err := database.Update(t.Context(), func(tx *store.Tx) error {
		if err := tx.Put("settings", settings); err != nil {
			return err
		}
		return tx.Put("moku-applied-settings", map[string]any{"settings": settings, "settingsRevision": 9})
	}); err != nil {
		t.Fatal(err)
	}
	known := map[string]bool{"extension:kept": true}
	if err := reconcilePluginPreferences(t.Context(), database, known); err != nil {
		t.Fatal(err)
	}
	var current model.Settings
	if _, err := database.Snapshot().Get("settings", &current); err != nil {
		t.Fatal(err)
	}
	want := map[string]bool{"extension:kept": false}
	if !reflect.DeepEqual(current.PluginEnabled, want) {
		t.Fatalf("wrong current plugin preferences: %v", current.PluginEnabled)
	}
	var applied struct {
		Settings         model.Settings `json:"settings"`
		SettingsRevision int64          `json:"settingsRevision"`
	}
	if _, err := database.Snapshot().Get("moku-applied-settings", &applied); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(applied.Settings.PluginEnabled, want) || applied.SettingsRevision != 9 {
		t.Fatalf("wrong applied snapshot: %+v", applied)
	}
	revision := database.Snapshot().Revision()
	if err := reconcilePluginPreferences(t.Context(), database, known); err != nil {
		t.Fatal(err)
	}
	if database.Snapshot().Revision() != revision {
		t.Fatal("repeated cleanup rewrote settings")
	}
}
