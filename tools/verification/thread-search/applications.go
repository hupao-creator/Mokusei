package main

import (
	"context"
	"encoding/json"
	"fmt"
	"path/filepath"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	core "github.com/hupao-creator/Mokusei/internal/core/runtime"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/hosts/applicationhost"
	"github.com/hupao-creator/Mokusei/internal/plugins/applications/report"
	"github.com/hupao-creator/Mokusei/internal/services/localembedding"
)

const appCollection = "fixture-app.documents"
const appType = "fixture-app.document"

type application struct{}

func (application) Manifest() plugin.ApplicationManifest {
	return plugin.ApplicationManifest{ID: "fixture-app", DisplayName: "Synthetic search fixture", APIVersion: 1, Contributes: plugin.Contributions{Collections: []string{appCollection}, ThreadTypes: []string{appType}, Commands: []string{"fixture-app.delete"}}}
}
func contract(id string) plugin.ValueContract {
	return plugin.ValueContract{ID: id, SchemaVersion: 1, Parse: func(b json.RawMessage) (json.RawMessage, error) { return b, nil }}
}
func (application) Register(r plugin.Registry) error {
	if e := r.Collection(plugin.CollectionDefinition{ID: appCollection, OwnerPluginID: "fixture-app", Retention: "history", Contract: contract("fixture-app.data")}); e != nil {
		return e
	}
	if e := r.ThreadType(plugin.ThreadTypeDefinition{ID: appType, OwnerPluginID: "fixture-app", DisplayName: "Fixture", CollectionID: appCollection, Contract: contract("fixture-app.view"), Project: func(record model.ApplicationThreadRecord) (plugin.ThreadProjection, error) {
		var data struct{ Title string }
		e := json.Unmarshal(record.Value, &data)
		return plugin.ThreadProjection{Title: data.Title, View: raw(map[string]any{})}, e
	}, Tags: extension{}, Classification: extension{}, Archive: extension{}}); e != nil {
		return e
	}
	return r.Command(plugin.CommandDefinition{Operation: plugin.Operation{ID: "fixture-app.delete", OwnerPluginID: "fixture-app", Input: contract("fixture-app.input"), Output: contract("fixture-app.output")}, Audience: plugin.CommandAudience{User: true, Background: "deny"}, Plan: func(_ json.RawMessage, c plugin.ReadContext) ([]plugin.MutationScope, error) {
		scope, e := c.Records.Scope(appCollection, "doc")
		return []plugin.MutationScope{scope}, e
	}, Reduce: func(_ json.RawMessage, c plugin.TransactionContext) (json.RawMessage, error) {
		record, e := c.Records.Get(appCollection, "doc")
		if e != nil {
			return nil, e
		}
		return raw(map[string]bool{"deleted": true}), c.Records.Delete(appCollection, "doc", record.Revision)
	}})
}

type extension struct{}

func (extension) Project(model.ApplicationThreadRecord) (model.TagProjection, error) {
	return model.TagProjection{TagEmojis: map[string]string{"Shared": "🔧"}, Tags: []string{"项目", "Shared"}, SemanticTags: []string{"Shared"}, DirectoryTags: []string{"项目"}}, nil
}
func (extension) Sources(model.ApplicationThreadRecord) ([]model.ThreadRef, error) { return nil, nil }
func (extension) Apply(r model.ApplicationThreadRecord, _ plugin.SemanticTagEffect) (plugin.ThreadStateChange, error) {
	return plugin.ThreadStateChange{Value: r.Value}, nil
}
func (extension) Evidence(r model.ApplicationThreadRecord) (plugin.ClassificationEvidence, error) {
	var data struct{ Text string }
	e := json.Unmarshal(r.Value, &data)
	return plugin.ClassificationEvidence{Content: data.Text, Revision: fmt.Sprint(r.Revision)}, e
}
func (extension) Archived(r model.ApplicationThreadRecord) bool {
	var data struct{ Archived bool }
	_ = json.Unmarshal(r.Value, &data)
	return data.Archived
}
func (extension) Change(r model.ApplicationThreadRecord, archived bool) (plugin.ThreadStateChange, error) {
	var data map[string]any
	must(json.Unmarshal(r.Value, &data))
	data["archived"] = archived
	return plugin.ThreadStateChange{Value: raw(data)}, nil
}
func (extension) RelatedLatestExecutions(model.ApplicationThreadRecord, bool) ([]model.ExecutionRef, error) {
	return nil, nil
}
func verifyApplications(ctx context.Context, directory string, provider *localembedding.Provider, s *service) {
	db, e := store.Open(filepath.Join(directory, "applications.sqlite"))
	must(e)
	defer db.Close()
	r, e := core.New(ctx, core.Config{Store: db, Harnesses: map[string]plugin.Harness{}, DataDir: filepath.Join(directory, "app-runtime"), DefaultCwd: directory, Embeddings: provider})
	must(e)
	defer r.Close(ctx)
	host, e := applicationhost.New(ctx, applicationhost.Config{Store: db, Applications: []plugin.Application{application{}, reportDomain{}}, RuntimeCapabilities: r.RuntimeCapabilities, SnapshotCapabilities: r.SnapshotCapabilities})
	must(e)
	r.SetApplications(host)
	owner := "application:" + appCollection + ":doc"
	_, e = db.Update(ctx, func(tx *store.Tx) error {
		return tx.Put(owner, model.VersionedRecord{ID: "doc", Revision: 1, CreatedAt: 1, UpdatedAt: 1, Value: raw(map[string]any{"title": "应用检索", "text": "离线删除", "archived": false, "private": "NEVER_UPLOAD"})})
	})
	must(e)
	_, e = db.Update(ctx, func(tx *store.Tx) error {
		return tx.Put("application:"+report.CollectionID+":report", model.VersionedRecord{ID: "report", Revision: 1, CreatedAt: 1, UpdatedAt: 1, Value: raw(report.Data{Scope: "inbox", Title: "正文报告", HTML: "<html><head><script>NEVER_UPLOAD_SCRIPT</script></head><body><h1>正文报告</h1><p>离线删除与本机数据清理</p><style>NEVER_UPLOAD_STYLE</style></body></html>", ContentRevision: "fixture-v1", RelatedExecutions: []model.ExecutionRef{}, TagSources: map[string]report.TagSource{}})})
	})
	must(e)
	configure(r, true, false)
	start(r)
	result := query(r, "清空历史", model.ThreadRef{ThreadID: "doc", TypeID: appType})
	assert(result.Mode == "hybrid" && len(result.Hits) == 1, "real application evidence indexed and queried")
	reportResult := query(r, "清空历史", model.ThreadRef{ThreadID: "report", TypeID: report.ThreadTypeID})
	assert(reportResult.Mode == "hybrid" && len(reportResult.Hits) == 1, "real Report reader text indexed, with script/style excluded")
	must(host.Archive(ctx, model.ThreadRef{ThreadID: "doc", TypeID: appType}, true))
	assert(len(db.Snapshot().Keys("search-document:")) == 1, "application archive removes derived vectors in same transaction")
	must(host.Archive(ctx, model.ThreadRef{ThreadID: "doc", TypeID: appType}, false))
	start(r)
	invoke(r, "application:command", plugin.OperationRequest{PluginID: "fixture-app", OperationID: "fixture-app.delete", Input: raw(map[string]any{}), RequestID: "delete-fixture-application"})
	assert(!db.Snapshot().Has(owner) && len(db.Snapshot().Keys("search-document:")) == 1, "real application reducer deletes source and vector/text atomically")
	must(r.ClearHistory(ctx))
	assert(!db.Snapshot().Has("application:"+report.CollectionID+":report") && len(db.Snapshot().Keys("search-document:")) == 0, "application history and report index clear atomically")
	fmt.Println("PASS automatic incremental indexing, cancelled HTTP, stale query discard, disable purge, application evidence, archive and reducer deletion")
}

// Keep the production Report domain and text projection, without a background
// model participant in the fixture.
type reportDomain struct{}

func (reportDomain) Manifest() plugin.ApplicationManifest {
	m := report.New().Manifest()
	m.Contributes.BackgroundAgents = nil
	m.Contributes.Settings = nil
	return m
}
func (reportDomain) Register(r plugin.Registry) error { return report.RegisterDomain(r) }
