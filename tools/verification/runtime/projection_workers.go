package main

import (
	"context"
	"encoding/json"
	"fmt"
	"path/filepath"
	goruntime "runtime"
	"sync"
	"sync/atomic"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	core "github.com/hupao-creator/Mokusei/internal/core/runtime"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/platform/transport"
)

type projectionGate struct {
	mu                  sync.Mutex
	held                chan struct{}
	entered             chan struct{}
	active, peak, calls atomic.Int64
}

func (g *projectionGate) hold() { g.mu.Lock(); g.held = make(chan struct{}); g.mu.Unlock() }
func (g *projectionGate) release() {
	g.mu.Lock()
	if g.held != nil {
		close(g.held)
		g.held = nil
	}
	g.mu.Unlock()
}

type parallelAdapter struct {
	stateAdapter
	gate *projectionGate
}

func (a parallelAdapter) ProjectRenderer(value json.RawMessage, scope model.RendererScope) (json.RawMessage, error) {
	g := a.gate
	g.calls.Add(1)
	n := g.active.Add(1)
	defer g.active.Add(-1)
	for old := g.peak.Load(); n > old && !g.peak.CompareAndSwap(old, n); old = g.peak.Load() {
	}
	g.mu.Lock()
	held := g.held
	g.mu.Unlock()
	if held != nil {
		g.entered <- struct{}{}
		<-held
	}
	return a.stateAdapter.ProjectRenderer(value, scope)
}

type parallelHarness struct {
	harness
	gate *projectionGate
}

func (h parallelHarness) SessionState() plugin.SessionStateAdapter {
	return parallelAdapter{gate: h.gate}
}

func verifyProjectionWorkers(ctx context.Context, directory string) {
	db, err := store.Open(filepath.Join(directory, "projection-workers.sqlite"))
	must(err)
	defer db.Close()
	_, err = db.Update(ctx, func(tx *store.Tx) error {
		ids := []string{}
		for i := 0; i < 5; i++ {
			id := fmt.Sprint("parallel-", i)
			ids = append(ids, id)
			t := model.ThreadRecord{SessionRecord: model.SessionRecord{ID: id, HarnessID: "fixture", Revision: 1, SessionState: raw(state{Messages: []string{"old"}}), Settings: raw(map[string]any{}), CreatedAt: 1, UpdatedAt: 1}, Title: id, Tags: []string{}}
			if err := tx.Put("thread:"+id, t); err != nil {
				return err
			}
		}
		return tx.SetOrder("threads", ids)
	})
	must(err)
	gate := &projectionGate{entered: make(chan struct{}, 32)}
	gate.hold()
	defer gate.release()
	type result struct {
		r   *core.Runtime
		err error
	}
	created := make(chan result, 1)
	go func() {
		r, e := core.New(ctx, core.Config{Store: db, DataDir: directory, Harnesses: map[string]plugin.Harness{"fixture": parallelHarness{gate: gate}}})
		created <- result{r, e}
	}()
	expected := min(4, goruntime.GOMAXPROCS(0))
	for i := 0; i < expected; i++ {
		waitPoolSignal(ctx, gate.entered)
	}
	if gate.peak.Load() != int64(expected) {
		panic("independent overview owners did not use bounded parallel workers")
	}
	gate.release()
	ready := <-created
	must(ready.err)
	r := ready.r
	defer func() { gate.release(); must(r.Close(ctx)) }()
	if gate.calls.Load() != 5 {
		panic("initial projection work duplicated")
	}
	_, err = r.Snapshot()
	must(err)
	if gate.calls.Load() != 5 {
		panic("cache hits entered projection pool")
	}
	// An older immutable snapshot may finish after a store write, but the next
	// read must rebuild the changed owner rather than keep its old cached value.
	gate.hold()
	must(r.UpdateThread(ctx, "parallel-0", func(t *model.ThreadRecord) error { t.Title = "first change"; return nil }))
	snapshots := make(chan model.AppState, 1)
	go func() { s, e := r.Snapshot(); must(e); snapshots <- s }()
	waitPoolSignal(ctx, gate.entered)
	must(r.UpdateThread(ctx, "parallel-0", func(t *model.ThreadRecord) error { t.Title = "newest change"; return nil }))
	gate.release()
	<-snapshots
	fresh, err := r.Snapshot()
	must(err)
	if fresh.Threads[0].Title != "newest change" {
		panic("late projection overwrote newer owner")
	}
	known := fresh.Threads[0].Revision
	calls := gate.calls.Load()
	value, err := r.ReadThreadContent(ctx, "parallel-0", transport.ContentScope{Kind: "thread"}, &known)
	must(err)
	if value != nil || gate.calls.Load() != calls {
		panic("known revision scheduled content projection")
	}
	gate.hold()
	readDone := make(chan error, 1)
	go func() {
		_, e := r.ReadThreadContent(ctx, "parallel-0", transport.ContentScope{Kind: "thread"}, nil)
		readDone <- e
	}()
	waitPoolSignal(ctx, gate.entered)
	closed := make(chan error, 1)
	go func() { closed <- r.Close(ctx) }()
	select {
	case <-closed:
		panic("runtime close did not join active content projection")
	case <-time.After(30 * time.Millisecond):
	}
	gate.release()
	if e := <-readDone; e == nil {
		panic("cancelled content projection returned success")
	}
	must(<-closed)
	fmt.Println("PASS bounded cross-owner projection, cache-hit bypass, snapshot freshness, known revision and runtime content shutdown join")
}
