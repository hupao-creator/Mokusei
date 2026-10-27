package main

import (
	"context"
	"fmt"
	"path/filepath"
	"sync/atomic"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/services/localembedding"
	"github.com/hupao-creator/Mokusei/internal/services/threadsearch"
)

func verifyAsync(ctx context.Context, directory string, provider *localembedding.Provider, s *service) {
	db, err := store.Open(filepath.Join(directory, "async.sqlite"))
	must(err)
	defer db.Close()
	seed(db, thread("a", "自动更新", "different subject"))
	manager := newManager(ctx, db, provider)
	defer func() { manager.Close() }()
	config, err := manager.Configure(ctx, threadsearch.ConfigureRequest{IncludeContent: true, AutoUpdate: true})
	must(err)
	_, err = manager.Index(ctx, threadsearch.IndexRequest{Action: "start", Consent: true, ExpectedRevision: config.Config.Revision})
	must(err)
	wait("initial auto index", func() bool { x, _ := manager.Status(ctx); return !x.Working && x.Indexed == 1 })
	before := s.calls.Load()
	seed(db, thread("b", "自动更新新增", "离线删除"))
	wait("auto index new source", func() bool { x, _ := manager.Status(ctx); return !x.Working && x.Indexed == 2 })
	assert(s.calls.Load() == before+1, "new source gets only its new chunk, not a full rebuild")
	manager.Close()
	seed(db, thread("b", "自动更新新增", "离线删除 offline update"))
	before = s.calls.Load()
	manager = newManager(ctx, db, provider)
	wait("persisted auto consent catches offline source changes on reopen", func() bool { x, _ := manager.Status(ctx); return !x.Working && x.Indexed == 2 })
	assert(s.calls.Load() == before+1, "restart reuses unchanged source and updates only the offline changed chunk")
	_, err = manager.Index(ctx, threadsearch.IndexRequest{Action: "cancel"})
	must(err)
	manager.Close()
	seed(db, thread("b", "自动更新新增", "离线删除 paused update"))
	before = s.calls.Load()
	manager = newManager(ctx, db, provider)
	time.Sleep(2200 * time.Millisecond) // cross the automatic reconciler's first tick
	paused, err := manager.Status(ctx)
	must(err)
	assert(!paused.Working && paused.Reason == "paused" && s.calls.Load() == before, "explicit pause survives restart without indexing offline changes")
	_, err = manager.Index(ctx, threadsearch.IndexRequest{Action: "start", Consent: true, ExpectedRevision: paused.Config.Revision})
	must(err)
	wait("explicitly continue persisted pause", func() bool { x, _ := manager.Status(ctx); return !x.Working && x.Indexed == 2 })
	before = s.calls.Load()
	_, err = db.Update(ctx, func(tx *store.Tx) error {
		var t model.ThreadRecord
		_, e := tx.Get("thread:a", &t)
		if e != nil {
			return e
		}
		t.UpdatedAt++
		t.Revision++
		return tx.Put("thread:a", t)
	})
	must(err)
	wait("metadata-only owner revision updates without recomputing vectors", func() bool { x, _ := manager.Status(ctx); return x.Indexed == 2 && !x.Working })
	assert(s.calls.Load() == before, "unchanged text updates source stamp without repeated embeddings")
	_, entered := s.hold()
	cancelled, cancel := context.WithCancel(ctx)
	done := make(chan error, 1)
	go func() {
		_, e := manager.Query(cancelled, threadsearch.QueryRequest{Query: "cancel this synthetic query", Threads: refs("a")})
		done <- e
	}()
	<-entered
	cancel()
	select {
	case e := <-done:
		assert(e != nil, "native cancellation reaches embedding HTTP")
	case <-time.After(time.Second):
		panic("cancel did not release embedding HTTP")
	}
	s.release()
	_, entered = s.hold()
	result := make(chan threadsearch.QueryResult, 1)
	go func() {
		v, e := manager.Query(ctx, threadsearch.QueryRequest{Query: "fresh delayed query", Threads: refs("a")})
		must(e)
		result <- v
	}()
	<-entered
	_, err = db.Update(ctx, func(tx *store.Tx) error {
		if e := threadsearch.DeleteOwner(tx, "thread:a"); e != nil {
			return e
		}
		return tx.Delete("thread:a")
	})
	must(err)
	s.release()
	assert(len((<-result).Hits) == 0, "delayed semantic query cannot return a deleted owner")
	_, err = manager.Index(ctx, threadsearch.IndexRequest{Action: "disable"})
	must(err)
	assert(len(db.Snapshot().Keys("search-document:")) == 0, "disable deletes persistent chunks and vectors")
}

func verifyPauseDuringReconcile(ctx context.Context, directory string, provider *localembedding.Provider, s *service) {
	db, err := store.Open(filepath.Join(directory, "reconcile-pause.sqlite"))
	must(err)
	defer db.Close()
	seed(db, thread("a", "Initial", "different subject"))
	entered, release := make(chan struct{}), make(chan struct{})
	var armed atomic.Bool
	m, err := threadsearch.New(ctx, threadsearch.Options{Store: db, Provider: provider, Interval: time.Nanosecond,
		Sources: func(snapshot store.Snapshot, body bool) ([]threadsearch.Source, error) {
			if snapshot.Has("thread:b") && armed.CompareAndSwap(true, false) {
				close(entered)
				<-release
			}
			return source(snapshot, body)
		}})
	must(err)
	defer m.Close()
	config, err := m.Configure(ctx, threadsearch.ConfigureRequest{AutoUpdate: true})
	must(err)
	_, err = m.Index(ctx, threadsearch.IndexRequest{Action: "start", Consent: true, ExpectedRevision: config.Config.Revision})
	must(err)
	wait("reconcile initial index", func() bool { x, _ := m.Status(ctx); return !x.Working && x.Indexed == 1 })
	before := s.calls.Load()
	armed.Store(true)
	seed(db, thread("b", "Pending", "new source"))
	select {
	case <-entered:
	case <-time.After(5 * time.Second):
		panic("automatic source reconciliation did not start")
	}
	_, err = m.Index(ctx, threadsearch.IndexRequest{Action: "cancel"})
	must(err)
	close(release)
	time.Sleep(300 * time.Millisecond) // let the older status finish its launch decision
	paused, err := m.Status(ctx)
	must(err)
	assert(paused.Config.IndexPaused && !paused.Working && paused.Reason == "paused" && s.calls.Load() == before,
		"a reconciliation started before manual pause cannot resume indexing afterward")
	fmt.Println("PASS late automatic reconciliation cannot restart an explicitly paused index")
}
