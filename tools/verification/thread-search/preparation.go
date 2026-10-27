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

func verifyLazyPreparation(ctx context.Context, directory string, provider *localembedding.Provider, service *service) {
	db, err := store.Open(filepath.Join(directory, "lazy-preparation.sqlite"))
	must(err)
	defer db.Close()
	busy := thread("busy", "Busy", "NEVER_UPLOAD_RUNNING")
	busy.Observation.LatestExecution = &model.PublicExecution{ExecutionID: "active", Status: "running", StartedAt: 1}
	seed(db, busy)
	var extractions, enumerations atomic.Int64
	m, err := threadsearch.New(ctx, threadsearch.Options{Store: db, Provider: provider, WatchInterval: 20 * time.Millisecond, Interval: time.Nanosecond,
		Sources: func(snapshot store.Snapshot, body bool) ([]threadsearch.Source, error) {
			enumerations.Add(1)
			sources, err := source(snapshot, body)
			for i := range sources {
				if load := sources[i].LoadContent; load != nil {
					sources[i].LoadContent = func() (string, error) { extractions.Add(1); return load() }
				}
			}
			return sources, err
		}})
	must(err)
	defer m.Close()
	calls := service.calls.Load()
	// Four metadata passes prove maintenance ticks actually occurred.
	wait("busy-only maintenance ticks", func() bool { return enumerations.Load() >= 4 })
	status, err := m.Status(ctx)
	must(err)
	assert(!status.Working && status.PendingDocuments == 1 && extractions.Load() == 0 && service.calls.Load() == calls, "busy-only sources cause no text extraction or embedding")
	done := thread("busy", "Busy", "completed content")
	done.Observation.LatestExecution = &model.PublicExecution{ExecutionID: "active", Status: "completed", StartedAt: 1}
	finished := int64(2)
	done.Observation.LatestExecution.FinishedAt = &finished
	seed(db, done)
	wait("completed source becomes indexed", func() bool { s, e := m.Status(ctx); return e == nil && !s.Working && s.Indexed == 1 })
	before := extractions.Load()
	calls = service.calls.Load()
	for i := 0; i < 4; i++ {
		_, err = m.Status(ctx)
		must(err)
	}
	passes := enumerations.Load()
	_, err = db.Update(ctx, func(tx *store.Tx) error { return tx.Put("unrelated", map[string]any{"value": 1}) })
	must(err)
	wait("unrelated-write maintenance completes", func() bool { return enumerations.Load() > passes })
	assert(extractions.Load() == before && service.calls.Load() == calls, "unchanged index and unrelated writes reuse completed source without text extraction")
	// A subsequent failed execution must not erase already completed turns.
	done.Observation.LatestExecution = &model.PublicExecution{ExecutionID: "later", Status: "failed", StartedAt: 3, FinishedAt: ptr(int64(4))}
	seed(db, done)
	wait("failed latest execution preserves earlier completed content", func() bool { s, e := m.Status(ctx); return e == nil && !s.Working && s.Indexed == 1 })
	assert(service.calls.Load() == calls, "unchanged completed text reuses vectors after a later failure")
	fmt.Println("PASS lazy text preparation, busy-only quiescence, completion, unchanged source reuse and failed-turn vector reuse")
}

func ptr[T any](value T) *T { return &value }
