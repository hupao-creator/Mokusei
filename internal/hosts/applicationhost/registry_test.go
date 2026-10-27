package applicationhost

import (
	"context"
	"encoding/json"
	"path/filepath"
	"testing"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/core/store"
)

type registrationApplication struct {
	manifest plugin.ApplicationManifest
	register func(plugin.Registry) error
}

func (a registrationApplication) Manifest() plugin.ApplicationManifest { return a.manifest }
func (a registrationApplication) Register(registry plugin.Registry) error {
	return a.register(registry)
}

type registrationCapabilities struct{ calls int }

func (c *registrationCapabilities) Require(plugin.CapabilityKey) (any, error) {
	c.calls++
	return nil, nil
}

func TestRegistrationFreezesDeclarationsBeforeStartingHost(t *testing.T) {
	ctx := context.Background()
	db, err := store.Open(filepath.Join(t.TempDir(), "state.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if _, err := db.Update(ctx, func(tx *store.Tx) error { return tx.Put("settings", model.Settings{}) }); err != nil {
		t.Fatal(err)
	}
	contract := plugin.ValueContract{ID: "frozen.value", SchemaVersion: 1,
		Parse: func(raw json.RawMessage) (json.RawMessage, error) { return raw, nil }}
	manifest := plugin.ApplicationManifest{ID: "frozen", DisplayName: "Frozen", APIVersion: 1,
		Contributes: plugin.Contributions{Settings: []string{"frozen.settings"}, Queries: []string{"frozen.query"}}}
	declared := plugin.CapabilityKey{ID: "declared", APIVersion: 1, Phase: "runtime"}
	undeclared := plugin.CapabilityKey{ID: "undeclared", APIVersion: 1, Phase: "runtime"}
	requires := []plugin.CapabilityKey{declared}
	defaults := json.RawMessage(`{"mode":"saved"}`)
	var retained plugin.Registry
	application := registrationApplication{manifest: manifest, register: func(registry plugin.Registry) error {
		retained = registry
		if err := registry.Settings(plugin.SettingsDefinition{ID: "frozen.settings", OwnerPluginID: "frozen", Contract: contract, Defaults: defaults}); err != nil {
			return err
		}
		if err := registry.ExternalQuery(plugin.ExternalQueryDefinition{
			Operation: plugin.Operation{ID: "frozen.query", OwnerPluginID: "frozen", Input: contract, Output: contract},
			Audience:  plugin.QueryAudience{User: true}, Requires: requires,
			Read: func(_ context.Context, _ json.RawMessage, read plugin.ExternalReadContext) (json.RawMessage, error) {
				_, err := read.Capabilities.Require(undeclared)
				return json.RawMessage(`{}`), err
			},
		}); err != nil {
			return err
		}
		// Registration takes ownership of declarations at each call, including
		// data that the application may reuse while declaring its next feature.
		requires[0] = undeclared
		copy(defaults, `{"mode":"other"}`)
		return nil
	}}
	capabilities := &registrationCapabilities{}
	host, err := New(ctx, Config{Store: db, Applications: []plugin.Application{application},
		RuntimeCapabilities: func(string) plugin.CapabilityAccess { return capabilities }})
	if err != nil {
		t.Fatal(err)
	}
	var settings model.Settings
	if _, err := db.Snapshot().Get("settings", &settings); err != nil {
		t.Fatal(err)
	}
	if len(settings.PluginSettings) != 1 || string(settings.PluginSettings[0].Value) != `{"mode":"saved"}` {
		t.Fatalf("application changed registered defaults through an alias: %+v", settings.PluginSettings)
	}
	if _, err := host.Query(ctx, plugin.OperationRequest{PluginID: "frozen", OperationID: "frozen.query", Input: json.RawMessage(`{}`)}); err == nil {
		t.Fatal("application changed registered capability requirements through an alias")
	}
	if capabilities.calls != 0 {
		t.Fatal("undeclared requirement reached the capability binder")
	}
	manifest.Contributes.Settings[0] = "frozen.rewritten"
	if got := host.Manifests()[0].Contributes.Settings[0]; got != "frozen.settings" {
		t.Fatalf("application changed its frozen manifest: %s", got)
	}
	public := host.Manifests()
	public[0].Contributes.Queries[0] = "frozen.rewritten"
	if got := host.Manifests()[0].Contributes.Queries[0]; got != "frozen.query" {
		t.Fatalf("manifest consumer changed the host declaration: %s", got)
	}

	operation := plugin.Operation{ID: "frozen.late", OwnerPluginID: "frozen", Input: contract, Output: contract}
	late := []struct {
		name string
		call func() error
	}{
		{"collection", func() error {
			return retained.Collection(plugin.CollectionDefinition{ID: "frozen.late", OwnerPluginID: "frozen", Retention: "history", Contract: contract})
		}},
		{"settings", func() error {
			return retained.Settings(plugin.SettingsDefinition{ID: "frozen.late", OwnerPluginID: "frozen", Contract: contract, Defaults: json.RawMessage(`{}`)})
		}},
		{"query", func() error {
			return retained.Query(plugin.QueryDefinition{Operation: operation, Read: func(json.RawMessage, plugin.ReadContext) (json.RawMessage, error) { return json.RawMessage(`{}`), nil }})
		}},
		{"external query", func() error {
			return retained.ExternalQuery(plugin.ExternalQueryDefinition{Operation: operation, Read: func(context.Context, json.RawMessage, plugin.ExternalReadContext) (json.RawMessage, error) {
				return json.RawMessage(`{}`), nil
			}})
		}},
		{"command", func() error {
			return retained.Command(plugin.CommandDefinition{Operation: operation, Audience: plugin.CommandAudience{Background: "deny"},
				Plan: func(json.RawMessage, plugin.ReadContext) ([]plugin.MutationScope, error) { return nil, nil },
				Reduce: func(json.RawMessage, plugin.TransactionContext) (json.RawMessage, error) {
					return json.RawMessage(`{}`), nil
				}})
		}},
		{"thread type", func() error {
			return retained.ThreadType(plugin.ThreadTypeDefinition{ID: "frozen.late", OwnerPluginID: "frozen", DisplayName: "Late", Contract: contract,
				Project: func(model.ApplicationThreadRecord) (plugin.ThreadProjection, error) {
					return plugin.ThreadProjection{}, nil
				}})
		}},
		{"background agent", func() error {
			return retained.BackgroundAgent(plugin.BackgroundAgentDefinition{ID: "frozen.late", InstancePolicy: plugin.GlobalInstance,
				Create: func(plugin.BackgroundAgentContext) (plugin.RuntimeParticipant, error) {
					return &scopeTestParticipant{}, nil
				}})
		}},
	}
	for _, entry := range late {
		t.Run(entry.name, func(t *testing.T) {
			if err := entry.call(); err == nil {
				t.Fatal("retained registry accepted a contribution after manifest validation")
			}
		})
	}
}
