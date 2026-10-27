package main

import (
	"context"
	"encoding/json"
	"fmt"
	"path/filepath"
	"sync/atomic"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	core "github.com/hupao-creator/Mokusei/internal/core/runtime"
	"github.com/hupao-creator/Mokusei/internal/core/store"
)

type countedProjection struct {
	stateAdapter
	calls *atomic.Int64
}

func (a countedProjection) ProjectRenderer(value json.RawMessage, scope model.RendererScope) (json.RawMessage, error) {
	a.calls.Add(1)
	return a.stateAdapter.ProjectRenderer(value, scope)
}

type countedHarness struct {
	harness
	calls *atomic.Int64
}

func (h countedHarness) SessionState() plugin.SessionStateAdapter {
	return countedProjection{calls: h.calls}
}

func verifyProjectionReuse(ctx context.Context, directory string) {
	db, err := store.Open(filepath.Join(directory, "projection-cache.sqlite"))
	must(err)
	defer db.Close()
	records := []model.ThreadRecord{}
	for _, id := range []string{"first", "second"} {
		records = append(records, model.ThreadRecord{SessionRecord: model.SessionRecord{ID: id, HarnessID: "fixture", Revision: 1, SessionState: raw(state{Messages: []string{"original"}}), Settings: raw(map[string]any{}), CreatedAt: 1, UpdatedAt: 1}, Title: id, Tags: []string{"original"}})
	}
	_, err = db.Update(ctx, func(tx *store.Tx) error {
		for _, record := range records {
			if err := tx.Put("thread:"+record.ID, record); err != nil {
				return err
			}
		}
		return tx.SetOrder("threads", []string{"first", "second"})
	})
	must(err)
	before := db.Snapshot()
	firstHash, _ := before.RecordHash("thread:first")
	var calls atomic.Int64
	r, err := core.New(ctx, core.Config{Store: db, Harnesses: map[string]plugin.Harness{"fixture": countedHarness{calls: &calls}}, DataDir: directory})
	must(err)
	defer r.Close(ctx)
	initialCalls := calls.Load()
	check := func(ok bool, message string) {
		if !ok {
			panic(message)
		}
	}
	check(initialCalls == 2, "each initial overview projected once")
	for i := 0; i < 4; i++ {
		snapshot, err := r.Snapshot()
		must(err)
		snapshot.Threads[0].Tags[0] = "mutated"
		snapshot.Threads[0].SessionState[0] = 'x'
		r.Publish()
	}
	snapshot, err := r.Snapshot()
	must(err)
	check(snapshot.Threads[0].Tags[0] == "original" && json.Valid(snapshot.Threads[0].SessionState), "returned snapshots must not mutate cached projection")
	check(calls.Load() == initialCalls, "unchanged snapshot and publication reuse every overview")
	_, err = db.Update(ctx, func(tx *store.Tx) error { return tx.Put("unrelated-receipt", map[string]any{"value": 1}) })
	must(err)
	r.Publish()
	check(calls.Load() == initialCalls, "unrelated writes do not project any conversation")
	must(r.UpdateThread(ctx, "first", func(t *model.ThreadRecord) error { t.Title = "changed"; return nil }))
	r.Publish()
	check(calls.Load() == initialCalls+1, "only changed owner is projected")
	hash, _ := db.Snapshot().RecordHash("thread:first")
	old, _ := before.RecordHash("thread:first")
	check(hash != firstHash && old == firstHash, "record hashes follow immutable snapshots")
	_, err = db.Update(ctx, func(tx *store.Tx) error { return tx.Delete("thread:first") })
	must(err)
	r.Publish()
	snapshot, err = r.Snapshot()
	must(err)
	check(len(snapshot.Threads) == 1, "deleted records are absent from the cached catalog")
	_, err = db.Update(ctx, func(tx *store.Tx) error { return tx.Put("thread:first", records[0]) })
	must(err)
	r.Publish()
	check(calls.Load() == initialCalls+2, "deleted identities are evicted before recreation")
	fmt.Println("PASS incremental overview projection, unrelated writes, detached reads, immutable record hashes and deletion/recreation")
}
