// Package listfixture exposes the production Records.List through a public
// application query for both semantic replay and baseline performance fixtures.
package listfixture

import (
	"context"
	"encoding/json"
	"fmt"
	"sync/atomic"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/hosts/applicationhost"
)

const CollectionID = "list-fixture.records"

type Application struct{ IndexCalls, ProjectCalls *atomic.Int64 }

func (Application) Manifest() plugin.ApplicationManifest {
	return plugin.ApplicationManifest{
		ID: "list-fixture", DisplayName: "Collection list fixture", APIVersion: 1,
		Contributes: plugin.Contributions{Collections: []string{CollectionID}, ThreadTypes: []string{"list-fixture.document"}, Queries: []string{"list-fixture.list", "list-fixture.index"}},
	}
}

func (a Application) Register(registry plugin.Registry) error {
	contract := plugin.ValueContract{ID: "list-fixture.json", SchemaVersion: 1, Parse: func(raw json.RawMessage) (json.RawMessage, error) { return raw, nil }}
	if err := registry.Collection(plugin.CollectionDefinition{ID: CollectionID, OwnerPluginID: "list-fixture", Retention: "history", Contract: contract, Indexes: []plugin.RecordIndex{{ID: "list-fixture.bucket", Keys: func(raw json.RawMessage) ([]string, error) {
		if a.IndexCalls != nil {
			a.IndexCalls.Add(1)
		}
		var value struct {
			Bucket string `json:"bucket"`
		}
		err := json.Unmarshal(raw, &value)
		return []string{value.Bucket}, err
	}}}}); err != nil {
		return err
	}
	if err := registry.ThreadType(plugin.ThreadTypeDefinition{ID: "list-fixture.document", OwnerPluginID: "list-fixture", CollectionID: CollectionID, DisplayName: "Fixture", Contract: contract, Project: func(record model.ApplicationThreadRecord) (plugin.ThreadProjection, error) {
		if a.ProjectCalls != nil {
			a.ProjectCalls.Add(1)
		}
		return plugin.ThreadProjection{Scope: "inbox", Title: record.ID, View: record.Value}, nil
	}}); err != nil {
		return err
	}
	if err := registry.Query(plugin.QueryDefinition{
		Operation: plugin.Operation{ID: "list-fixture.index", OwnerPluginID: "list-fixture", Input: contract, Output: contract},
		Audience:  plugin.QueryAudience{User: true},
		Read: func(raw json.RawMessage, ctx plugin.ReadContext) (json.RawMessage, error) {
			var key string
			if err := json.Unmarshal(raw, &key); err != nil {
				return nil, err
			}
			ids, err := ctx.Records.LookupIDs(CollectionID, "list-fixture.bucket", key)
			if err != nil {
				return nil, err
			}
			count, err := ctx.Records.Count(CollectionID)
			if err != nil {
				return nil, err
			}
			return json.Marshal(IndexResult{IDs: ids, Count: count})
		},
	}); err != nil {
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

type IndexResult struct {
	IDs   []string
	Count int
}

func QueryIndex(ctx context.Context, host *applicationhost.Host, key string) (IndexResult, error) {
	input, _ := json.Marshal(key)
	value, err := host.Query(ctx, plugin.OperationRequest{PluginID: "list-fixture", OperationID: "list-fixture.index", Input: input})
	if err != nil {
		return IndexResult{}, err
	}
	var result IndexResult
	raw, ok := value.(json.RawMessage)
	if !ok {
		return result, fmt.Errorf("unexpected index response %T", value)
	}
	err = json.Unmarshal(raw, &result)
	return result, err
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
