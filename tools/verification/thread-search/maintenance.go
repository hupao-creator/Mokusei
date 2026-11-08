package main

import (
	"context"
	"encoding/json"
	"fmt"
	"path/filepath"
	"strings"
	"sync/atomic"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/hosts/applicationhost"
	"github.com/hupao-creator/Mokusei/internal/services/threadsearch"
)

const maintenanceCollection = "maintenance.records"

type maintenanceApplication struct{ projections, extractions *atomic.Int64 }

func (maintenanceApplication) Manifest() plugin.ApplicationManifest {
	return plugin.ApplicationManifest{ID: "maintenance", DisplayName: "Maintenance replay", APIVersion: 1, Contributes: plugin.Contributions{Collections: []string{maintenanceCollection}, ThreadTypes: []string{"maintenance.document"}}}
}
func (a maintenanceApplication) Register(r plugin.Registry) error {
	if err := r.Collection(plugin.CollectionDefinition{ID: maintenanceCollection, OwnerPluginID: "maintenance", Retention: "history", Contract: contract("maintenance.data")}); err != nil {
		return err
	}
	return r.ThreadType(plugin.ThreadTypeDefinition{ID: "maintenance.document", OwnerPluginID: "maintenance", DisplayName: "Maintenance", CollectionID: maintenanceCollection, Contract: contract("maintenance.view"), Project: func(record model.ApplicationThreadRecord) (plugin.ThreadProjection, error) {
		a.projections.Add(1)
		var data struct{ Title string }
		err := json.Unmarshal(record.Value, &data)
		return plugin.ThreadProjection{Title: data.Title, View: raw(map[string]any{})}, err
	}, SearchText: func(record model.ApplicationThreadRecord) (string, error) {
		a.extractions.Add(1)
		var data struct{ Body string }
		err := json.Unmarshal(record.Value, &data)
		return data.Body, err
	}})
}

// Exercise the actual automatic scheduler, application projections and SQLite.
// Counters live at the plugin boundary, so increasing unrelated data must not
// increase any callback count for the local update under test.
func verifyMaintenanceFanout(ctx context.Context, directory string) {
	for _, size := range []int{8, 128} {
		func() {
			db, err := store.Open(filepath.Join(directory, fmt.Sprintf("maintenance-%d.sqlite", size)))
			must(err)
			defer db.Close()
			_, err = db.Update(ctx, func(tx *store.Tx) error {
				if err := tx.Put("settings", model.DefaultSettings([]string{})); err != nil {
					return err
				}
				return tx.Put("settings-revision", int64(1))
			})
			must(err)
			var projections, extractions, scans, changes, candidates, starts atomic.Int64
			host, err := applicationhost.New(ctx, applicationhost.Config{Store: db, Applications: []plugin.Application{maintenanceApplication{&projections, &extractions}}})
			must(err)
			defer host.Stop(ctx)
			putApplication := func(tx *store.Tx, id, body string, revision int64) error {
				return tx.Put("application:"+maintenanceCollection+":"+id, model.VersionedRecord{ID: id, Revision: revision, CreatedAt: 1, UpdatedAt: revision, Value: raw(map[string]string{"title": id, "body": body})})
			}
			_, err = db.Update(ctx, func(tx *store.Tx) error {
				for n := range size {
					if err := putApplication(tx, fmt.Sprintf("doc-%03d", n), strings.Repeat("unrelated body ", 400), 1); err != nil {
						return err
					}
				}
				return tx.Put("probe:busy", true)
			})
			must(err)
			busySource := func(snapshot store.Snapshot) (threadsearch.Source, error) {
				var busy bool
				_, err := snapshot.Get("probe:busy", &busy)
				hash, _ := snapshot.RecordHash("probe:busy")
				return threadsearch.Source{Ref: model.ThreadRef{ThreadID: "busy", TypeID: "agent"}, Owner: "probe:busy", OwnerHash: hash, Busy: busy, Content: "settled busy needle"}, err
			}
			manager, err := threadsearch.New(ctx, threadsearch.Options{Store: db, WatchInterval: 5 * time.Millisecond, RetryMin: 5 * time.Millisecond,
				Sources: func(snapshot store.Snapshot, body bool) ([]threadsearch.Source, error) {
					scans.Add(1)
					values, err := host.SearchSources(snapshot, body)
					if err != nil {
						return nil, err
					}
					busy, err := busySource(snapshot)
					return append(values, busy), err
				}, SourceChanges: func(snapshot, previous store.Snapshot, body bool) ([]threadsearch.Source, error) {
					changes.Add(1)
					values, err := host.SearchSourceChanges(snapshot, previous, body)
					if err != nil {
						return nil, err
					}
					if !snapshot.PrefixEqual(previous, "probe:busy") {
						busy, err := busySource(snapshot)
						if err != nil {
							return nil, err
						}
						values = append(values, busy)
					}
					candidates.Add(int64(len(values)))
					return values, nil
				}, Trace: func(event plugin.SearchDiagnostic) {
					if event.Event == "search.index.started" {
						starts.Add(1)
					}
				}})
			must(err)
			defer manager.Close()
			wait("initial maintenance", func() bool {
				return len(db.Snapshot().Keys("search-document:")) == size && changes.Load() >= 2
			})
			time.Sleep(35 * time.Millisecond)
			initialStarts := starts.Load()
			initialProjections, initialCandidates := projections.Load(), candidates.Load()
			observedChanges := changes.Load()
			_, err = db.Update(ctx, func(tx *store.Tx) error { return tx.Put("telemetry:unrelated", 1) })
			must(err)
			wait("unrelated commit observed", func() bool { return changes.Load() > observedChanges })
			time.Sleep(35 * time.Millisecond)
			assert(scans.Load() == 0 && starts.Load() == initialStarts, "busy owner does not poll global status or restart indexing")
			assert(projections.Load() == initialProjections && candidates.Load() == initialCandidates, "telemetry does not visit unrelated application owners")
			_, err = db.Update(ctx, func(tx *store.Tx) error { return tx.Put("probe:busy", false) })
			must(err)
			wait("busy owner settles", func() bool { return len(db.Snapshot().Keys("search-document:")) == size+1 })
			assert(projections.Load() == initialProjections && candidates.Load() == initialCandidates+1, "settling one owner leaves every application unprojected")
			previousExtractions := extractions.Load()
			_, err = db.Update(ctx, func(tx *store.Tx) error { return putApplication(tx, "doc-000", "changed local needle", 2) })
			must(err)
			wait("one changed application indexed", func() bool { return extractions.Load() == previousExtractions+1 })
			time.Sleep(20 * time.Millisecond)
			assert(scans.Load() == 0 && projections.Load() == initialProjections+1 && candidates.Load() == initialCandidates+2, "one changed application visits one owner regardless of catalog size")
			status, err := manager.Status(ctx)
			must(err)
			assert(status.Indexed == size+1 && status.PendingDocuments == 0, "incremental maintenance converges all indexed sources")
			result, err := manager.Query(ctx, threadsearch.QueryRequest{Query: "changed local needle", Threads: []model.ThreadRef{{ThreadID: "doc-000", TypeID: "maintenance.document"}}})
			must(err)
			assert(len(result.Hits) == 1, "changed application body is queryable")
			before := len(db.Snapshot().Keys("search-document:"))
			_, err = db.Update(ctx, func(tx *store.Tx) error {
				if err := threadsearch.DeleteOwner(tx, "application:"+maintenanceCollection+":doc-000"); err != nil {
					return err
				}
				return tx.Delete("application:" + maintenanceCollection + ":doc-000")
			})
			must(err)
			assert(len(db.Snapshot().Keys("search-document:")) == before-1 && len(db.Snapshot().Keys("search-document-stamp:")) == before-1, "owner deletion removes its body and stamp atomically")
			fmt.Printf("PASS automatic search fan-out N=%d: busy/telemetry 0 projections, local update 1 projection and 1 extraction\n", size)
		}()
	}
}
