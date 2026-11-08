package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"sync/atomic"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	core "github.com/hupao-creator/Mokusei/internal/core/runtime"
	"github.com/hupao-creator/Mokusei/internal/core/store"
)

type publicationAdapter struct {
	stateAdapter
	fail      *atomic.Bool
	unrelated *atomic.Int64
}

func (a publicationAdapter) ProjectRenderer(value json.RawMessage, scope model.RendererScope) (json.RawMessage, error) {
	if model.IsNull(value) {
		return a.stateAdapter.ProjectRenderer(value, scope)
	}
	var valueState state
	if err := json.Unmarshal(value, &valueState); err != nil {
		return nil, err
	}
	if len(valueState.Messages) > 0 {
		id := valueState.Messages[0]
		if strings.HasPrefix(id, "publication-seed-") && id != "publication-seed-000" && id != "publication-seed-001" {
			a.unrelated.Add(1)
		}
		if id == "publication-seed-000" && a.fail.Load() {
			return nil, errors.New("controlled overview projection failure")
		}
	}
	return a.stateAdapter.ProjectRenderer(value, scope)
}

type publicationHarness struct {
	harness
	fail      *atomic.Bool
	unrelated *atomic.Int64
	opened    chan plugin.OpenContext
}

func (h publicationHarness) SessionState() plugin.SessionStateAdapter {
	return publicationAdapter{fail: h.fail, unrelated: h.unrelated}
}
func (h publicationHarness) Open(ctx context.Context, open plugin.OpenContext) (plugin.Handle, error) {
	h.opened <- open
	return h.harness.Open(ctx, open)
}

type publicationLog struct {
	mu        sync.Mutex
	last      int64
	mutations []model.StateMutation
	err       error
}

func (l *publicationLog) record(value json.RawMessage) {
	var mutation model.StateMutation
	err := json.Unmarshal(value, &mutation)
	l.mu.Lock()
	defer l.mu.Unlock()
	if err != nil {
		l.err = err
		return
	}
	if mutation.BaseRevision != l.last || mutation.Revision <= l.last {
		l.err = fmt.Errorf("discontinuous publication: previous=%d, base=%d, next=%d", l.last, mutation.BaseRevision, mutation.Revision)
	}
	l.last = mutation.Revision
	l.mutations = append(l.mutations, mutation)
}
func (l *publicationLog) find(match func(model.StateMutation) bool) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	must(l.err)
	for _, value := range l.mutations {
		if match(value) {
			return true
		}
	}
	return false
}
func (l *publicationLog) count() int {
	l.mu.Lock()
	defer l.mu.Unlock()
	must(l.err)
	return len(l.mutations)
}
func publicationThread(m model.StateMutation, id string, match func(model.ThreadRecord) bool) bool {
	if m.Threads != nil {
		for _, thread := range m.Threads.Upserts {
			if thread.ID == id && match(thread) {
				return true
			}
		}
	}
	return false
}

type publicationApplications struct {
	core.Applications
	entries []model.ApplicationThread
	err     error
}

func (a publicationApplications) Catalog(context.Context) ([]model.ApplicationThread, error) {
	return a.entries, a.err
}

func verifyPublisherFanout(ctx context.Context, directory string) {
	db, err := store.Open(filepath.Join(directory, "publisher-fanout.sqlite"))
	must(err)
	defer db.Close()
	_, err = db.Update(ctx, func(tx *store.Tx) error {
		ids := []string{}
		for n := range 64 {
			id := fmt.Sprintf("publication-seed-%03d", n)
			ids = append(ids, id)
			value := model.ThreadRecord{SessionRecord: model.SessionRecord{ID: id, HarnessID: "fixture", Revision: 1, CreatedAt: 1, UpdatedAt: 1, SessionState: raw(state{Messages: []string{id}}), Settings: raw(map[string]any{})}, Title: id, Tags: []string{}}
			if err := tx.Put("thread:"+id, value); err != nil {
				return err
			}
		}
		return tx.SetOrder("threads", ids)
	})
	must(err)
	var fail atomic.Bool
	var unrelated atomic.Int64
	opened := make(chan plugin.OpenContext, 16)
	r, err := core.New(ctx, core.Config{Store: db, DataDir: directory, Harnesses: map[string]plugin.Harness{"fixture": publicationHarness{fail: &fail, unrelated: &unrelated, opened: opened}}})
	must(err)
	defer r.Close(ctx)
	initial, err := r.Snapshot()
	must(err)
	observed := &publicationLog{last: initial.Revision}
	unsubscribe := r.SubscribeMutations(observed.record)
	defer unsubscribe()
	initialUnrelated := unrelated.Load()

	// These edits change only map contents. Decoding into a shallow baseline copy
	// would mutate the previous state and suppress or corrupt its settings patch.
	settings, _, err := r.Settings()
	must(err)
	settings.Harnesses["fixture"] = raw(map[string]string{"value": "nested-map-edit"})
	settings.Harnesses["remove-me"] = raw(map[string]bool{"present": true})
	_, err = db.Update(ctx, func(tx *store.Tx) error { return tx.Put("settings", settings) })
	must(err)
	r.Publish()
	waitFor(func() bool {
		return observed.find(func(m model.StateMutation) bool {
			return m.Settings != nil && string(m.Settings.Harnesses["fixture"]) == string(settings.Harnesses["fixture"]) && m.Settings.Harnesses["remove-me"] != nil
		})
	})
	delete(settings.Harnesses, "remove-me")
	_, err = db.Update(ctx, func(tx *store.Tx) error { return tx.Put("settings", settings) })
	must(err)
	r.Publish()
	waitFor(func() bool {
		return observed.find(func(m model.StateMutation) bool {
			return m.Settings != nil && m.Settings.Harnesses["remove-me"] == nil && string(m.Settings.Harnesses["fixture"]) == string(settings.Harnesses["fixture"])
		})
	})

	created, err := r.CreateThread(ctx, core.CreateThreadRequest{HarnessID: "fixture", Input: model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "activity publisher"}}}})
	must(err)
	open := <-opened
	r.Publish()
	open.PublishActivity(model.HarnessActivity{ExecutionID: created.Execution.ExecutionID, Sequence: 77, Kind: "text", Text: "activity-only"})
	r.Publish()
	waitFor(func() bool {
		return observed.find(func(m model.StateMutation) bool {
			for _, activity := range m.Activities {
				if activity.ThreadID == created.Record.ID && activity.Activity.Sequence == 77 {
					if m.Threads != nil || m.ApplicationThreads != nil || m.AgentRuns != nil {
						panic("activity-only publication traversed catalog state")
					}
					return true
				}
			}
			return false
		})
	})

	fail.Store(true)
	must(r.UpdateThread(ctx, "publication-seed-000", func(t *model.ThreadRecord) error { t.Title = "failed projection metadata"; return nil }))
	must(r.UpdateThread(ctx, "publication-seed-001", func(t *model.ThreadRecord) error { t.Title = "healthy projection survives"; return nil }))
	r.Publish()
	waitFor(func() bool {
		return observed.find(func(m model.StateMutation) bool {
			return publicationThread(m, "publication-seed-000", func(t model.ThreadRecord) bool {
				return t.Title == "failed projection metadata" && model.IsNull(t.SessionState)
			})
		}) && observed.find(func(m model.StateMutation) bool {
			return publicationThread(m, "publication-seed-001", func(t model.ThreadRecord) bool { return t.Title == "healthy projection survives" })
		})
	})
	fail.Store(false)
	// A fresh subscriber can request a complete snapshot while an existing
	// subscriber still holds the failed renderer projection. Populating the
	// projection cache must not acknowledge that existing subscriber's retry.
	recoveredSnapshot, err := r.Snapshot()
	must(err)
	recovered := false
	for _, thread := range recoveredSnapshot.Threads {
		if thread.ID == "publication-seed-000" {
			recovered = thread.Title == "failed projection metadata" && !model.IsNull(thread.SessionState)
		}
	}
	if !recovered {
		panic("full snapshot did not recover the renderer projection")
	}
	r.Publish()
	waitFor(func() bool {
		return observed.find(func(m model.StateMutation) bool {
			return publicationThread(m, "publication-seed-000", func(t model.ThreadRecord) bool {
				return t.Title == "failed projection metadata" && !model.IsNull(t.SessionState)
			})
		})
	})
	// A later application projector can abort publication after the renderer has
	// recovered. Only an accepted publication can consume the renderer retry.
	fail.Store(true)
	must(r.UpdateThread(ctx, "publication-seed-000", func(t *model.ThreadRecord) error { t.Title = "renderer retry after application failure"; return nil }))
	r.Publish()
	waitFor(func() bool {
		return observed.find(func(m model.StateMutation) bool {
			return publicationThread(m, "publication-seed-000", func(t model.ThreadRecord) bool {
				return t.Title == "renderer retry after application failure" && model.IsNull(t.SessionState)
			})
		})
	})
	r.SetApplications(publicationApplications{err: errors.New("controlled application projection failure")})
	fail.Store(false)
	r.Publish()
	applicationFailureRecovery := func(m model.StateMutation) bool {
		return publicationThread(m, "publication-seed-000", func(t model.ThreadRecord) bool {
			return t.Title == "renderer retry after application failure" && !model.IsNull(t.SessionState)
		})
	}
	if observed.find(applicationFailureRecovery) {
		panic("renderer recovery escaped an aborted application projection")
	}
	r.SetApplications(nil)
	waitFor(func() bool { return observed.find(applicationFailureRecovery) })
	if unrelated.Load() != initialUnrelated {
		panic("point publications reprojected unrelated seeded threads")
	}

	// A host without CatalogChanges still preserves the old no-op and order
	// contract; replacing the host registration needs no store write to publish.
	entries := []model.ApplicationThread{{ID: "app-a", Ref: model.ThreadRef{ThreadID: "app-a", TypeID: "fixture.document"}, Revision: 1, View: raw(map[string]any{})}, {ID: "app-b", Ref: model.ThreadRef{ThreadID: "app-b", TypeID: "fixture.document"}, Revision: 1, View: raw(map[string]any{})}}
	r.SetApplications(publicationApplications{entries: entries})
	waitFor(func() bool {
		return observed.find(func(m model.StateMutation) bool {
			return m.ApplicationThreads != nil && len(m.ApplicationThreads.Upserts) == 2
		})
	})
	before := observed.count()
	r.Publish()
	if observed.count() != before {
		panic("unchanged fallback application catalog emitted a patch")
	}
	r.SetApplications(publicationApplications{entries: []model.ApplicationThread{entries[1], entries[0]}})
	waitFor(func() bool {
		return observed.find(func(m model.StateMutation) bool {
			return m.ApplicationThreads != nil && m.ApplicationThreads.Order != nil && reflect.DeepEqual(*m.ApplicationThreads.Order, []string{"app-b", "app-a"})
		})
	})
	r.SetApplications(nil)
	waitFor(func() bool {
		return observed.find(func(m model.StateMutation) bool {
			return m.ApplicationThreads != nil && len(m.ApplicationThreads.RemovedIDs) == 2
		})
	})

	// Multiple session keys belong to one agent. Incremental publication must
	// retire only the changed session, rather than its entire agent/scope group.
	private := func(key string, running bool) plugin.PrivateSessionSnapshot {
		status := "completed"
		if running {
			status = "running"
		}
		return plugin.PrivateSessionSnapshot{Ref: plugin.PrivateSessionRef{Owner: plugin.BackgroundAgentRef{PluginID: "fixture", AgentID: "fixture.agent", Binding: plugin.ScopeBinding{Kind: plugin.GlobalScope}}, SessionKey: key, SessionID: "private-" + key}, Record: model.SessionRecord{ID: "private-" + key, HarnessID: "fixture", Revision: 1, Settings: raw(map[string]any{}), SessionState: raw(map[string]any{}), Observation: model.PublicObservation{LatestExecution: &model.PublicExecution{ExecutionID: "execution-" + key, Status: status, StartedAt: 1}}}}
	}
	_, err = db.Update(ctx, func(tx *store.Tx) error {
		if err := tx.Put("private-session:fixture.agent:primary", private("primary", true)); err != nil {
			return err
		}
		return tx.Put("private-session:fixture.agent:secondary", private("secondary", true))
	})
	must(err)
	r.Publish()
	waitFor(func() bool {
		return observed.find(func(m model.StateMutation) bool { return m.AgentRuns != nil && len(*m.AgentRuns) == 2 })
	})
	_, err = db.Update(ctx, func(tx *store.Tx) error {
		return tx.Put("private-session:fixture.agent:primary", private("primary", false))
	})
	must(err)
	r.Publish()
	waitFor(func() bool {
		return observed.find(func(m model.StateMutation) bool {
			return m.AgentRuns != nil && len(*m.AgentRuns) == 1 && (*m.AgentRuns)[0].ExecutionID == "execution-secondary"
		})
	})
	_, err = db.Update(ctx, func(tx *store.Tx) error { return tx.Delete("private-session:fixture.agent:secondary") })
	must(err)
	r.Publish()
	waitFor(func() bool {
		return observed.find(func(m model.StateMutation) bool { return m.AgentRuns != nil && len(*m.AgentRuns) == 0 })
	})
	fmt.Println("PASS point publication isolation, settings map edits/removal, activity-only delivery, snapshot-first and aborted-publication renderer recovery, application replacement/order/no-op and per-session agent runs")
}
