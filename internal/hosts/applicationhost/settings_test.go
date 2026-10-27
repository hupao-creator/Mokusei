package applicationhost

import (
	"context"
	"encoding/json"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/core/store"
)

type settingsTestApplication struct{ id string }

func (a settingsTestApplication) Manifest() plugin.ApplicationManifest {
	return plugin.ApplicationManifest{ID: a.id, DisplayName: a.id, APIVersion: 1,
		Contributes: plugin.Contributions{Settings: []string{a.id + ".settings"}, BackgroundAgents: []string{a.id + ".agent"}}}
}

func (a settingsTestApplication) Register(registry plugin.Registry) error {
	id := a.id + ".settings"
	if err := registry.Settings(plugin.SettingsDefinition{ID: id, OwnerPluginID: a.id,
		Contract: plugin.ValueContract{ID: id, SchemaVersion: 1,
			Parse: func(raw json.RawMessage) (json.RawMessage, error) { return raw, nil }},
		Defaults: json.RawMessage(`{"mode":"default"}`)}); err != nil {
		return err
	}
	return registry.BackgroundAgent(plugin.BackgroundAgentDefinition{ID: a.id + ".agent", InstancePolicy: plugin.PerDirectoryScope,
		Create: func(plugin.BackgroundAgentContext) (plugin.RuntimeParticipant, error) {
			return &scopeTestParticipant{}, nil
		}})
}

func TestStartupSettingsFollowRegisteredPlugins(t *testing.T) {
	ctx := context.Background()
	db, err := store.Open(filepath.Join(t.TempDir(), "state.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	kept := model.PluginSettings{ID: "kept.settings", SchemaVersion: 1, Value: json.RawMessage(`{"mode":"custom"}`)}
	if _, err := db.Update(ctx, func(tx *store.Tx) error {
		settings := model.Settings{PluginSettings: []model.PluginSettings{
			{ID: "removed.settings", SchemaVersion: 1, Value: json.RawMessage(`{}`)}, kept,
		}}
		if err := tx.Put("settings", settings); err != nil {
			return err
		}
		if err := tx.Put("moku-applied-settings", map[string]any{"settings": settings, "settingsRevision": 7}); err != nil {
			return err
		}
		for _, source := range []string{"kept", "kept.agent", "kept.agent.scope", "removed.agent", "kept.retired", "keptx.agent"} {
			if err := tx.Put("application-command-receipt:"+source+":receipt", map[string]any{}); err != nil {
				return err
			}
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	config := Config{Store: db, Applications: []plugin.Application{settingsTestApplication{"kept"}, settingsTestApplication{"added"}},
		Enabled: func(string) bool { return false }}
	host, err := New(ctx, config)
	if err != nil {
		t.Fatal(err)
	}
	var settings model.Settings
	if _, err := db.Snapshot().Get("settings", &settings); err != nil {
		t.Fatal(err)
	}
	want := []model.PluginSettings{kept, {ID: "added.settings", SchemaVersion: 1, Value: json.RawMessage(`{"mode":"default"}`)}}
	if !reflect.DeepEqual(settings.PluginSettings, want) {
		t.Fatalf("registered disabled plugin settings must survive; removed settings must not: %+v", settings.PluginSettings)
	}
	if _, err := host.ValidateSettings(ctx, settings); err != nil {
		t.Fatalf("startup left settings unsaveable: %v", err)
	}
	var applied struct {
		Settings         model.Settings `json:"settings"`
		SettingsRevision int64          `json:"settingsRevision"`
	}
	if _, err := db.Snapshot().Get("moku-applied-settings", &applied); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(applied.Settings.PluginSettings, []model.PluginSettings{kept}) || applied.SettingsRevision != 7 {
		t.Fatalf("applied settings cleanup changed execution state: %+v", applied)
	}
	for _, source := range []string{"kept", "kept.agent", "kept.agent.scope", "removed.agent", "kept.retired", "keptx.agent"} {
		want := source == "kept" || source == "kept.agent" || source == "kept.agent.scope"
		if db.Snapshot().Has("application-command-receipt:"+source+":receipt") != want {
			t.Fatalf("wrong receipt retention for %s", source)
		}
	}
	revision := db.Snapshot().Revision()
	if _, err := New(ctx, config); err != nil {
		t.Fatal(err)
	}
	if db.Snapshot().Revision() != revision {
		t.Fatal("unchanged plugin registry rewrote settings on restart")
	}
	settings.PluginSettings = append(settings.PluginSettings, model.PluginSettings{ID: "removed.settings", SchemaVersion: 1, Value: json.RawMessage(`{}`)})
	if _, err := host.ValidateSettings(ctx, settings); err == nil {
		t.Fatal("save accepted an unregistered settings contribution")
	}
}
