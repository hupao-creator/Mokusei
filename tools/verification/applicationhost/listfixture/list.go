// Package listfixture exposes the production Records.List through a public
// application query for both semantic replay and baseline performance fixtures.
package listfixture

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/hosts/applicationhost"
)

const CollectionID = "list-fixture.records"

type Application struct{}

func (Application) Manifest() plugin.ApplicationManifest {
	return plugin.ApplicationManifest{
		ID: "list-fixture", DisplayName: "Collection list fixture", APIVersion: 1,
		Contributes: plugin.Contributions{Collections: []string{CollectionID}, Queries: []string{"list-fixture.list"}},
	}
}

func (Application) Register(registry plugin.Registry) error {
	contract := plugin.ValueContract{ID: "list-fixture.json", SchemaVersion: 1, Parse: func(raw json.RawMessage) (json.RawMessage, error) { return raw, nil }}
	if err := registry.Collection(plugin.CollectionDefinition{ID: CollectionID, OwnerPluginID: "list-fixture", Retention: "history", Contract: contract}); err != nil {
		return err
	}
	return registry.Query(plugin.QueryDefinition{
		Operation: plugin.Operation{ID: "list-fixture.list", OwnerPluginID: "list-fixture", Input: contract, Output: contract},
		Audience:  plugin.QueryAudience{User: true},
		Read: func(_ json.RawMessage, ctx plugin.ReadContext) (json.RawMessage, error) {
			records, err := ctx.Records.List(CollectionID)
			if err != nil {
				return nil, err
			}
			ids := make([]string, len(records))
			for i, record := range records {
				ids[i] = record.ID
			}
			return json.Marshal(ids)
		},
	})
}

func Query(ctx context.Context, host *applicationhost.Host) ([]string, error) {
	value, err := host.Query(ctx, plugin.OperationRequest{PluginID: "list-fixture", OperationID: "list-fixture.list", Input: json.RawMessage(`{}`)})
	if err != nil {
		return nil, err
	}
	raw, ok := value.(json.RawMessage)
	if !ok {
		return nil, fmt.Errorf("unexpected collection list response %T", value)
	}
	var ids []string
	err = json.Unmarshal(raw, &ids)
	return ids, err
}
