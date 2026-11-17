package runtime

import (
	"bytes"
	"context"
	"encoding/json"

	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/services/threadsearch"
)

// GrepThreads is Moku's profile-local ordinary-thread read capability. It does
// not use Overview eligibility, index freshness or native session discovery.
func (r *Runtime) GrepThreads(ctx context.Context, raw json.RawMessage) (any, error) {
	ctx, cancel := r.operationContext(ctx)
	defer cancel()
	snapshot := r.config.Store.Snapshot()
	threads, err := r.cachedThreads(snapshot)
	if err != nil {
		return nil, err
	}
	sources := make([]threadsearch.GrepSource, 0, len(threads))
	for _, thread := range threads {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		if thread.Moku || thread.MokuHistory || r.IsDeleting(thread.ID) {
			continue
		}
		hash, _ := snapshot.RecordHash("thread:" + thread.ID)
		source := threadsearch.GrepSource{ID: thread.ID, Title: thread.Title, ScopeID: directoryScope(thread).ID, Hash: hash, Archived: archived(&thread), StateBytes: len(thread.SessionState)}
		if harness := r.config.Harnesses[thread.HarnessID]; harness != nil {
			if adapter, ok := harness.SessionState().(plugin.SearchPassageAdapter); ok {
				source.Load = func() ([]plugin.SearchPassage, error) {
					return adapter.SearchPassages(bytes.Clone(thread.SessionState))
				}
			}
		}
		sources = append(sources, source)
	}
	var current *store.Snapshot
	return threadsearch.Grep(ctx, raw, sources, func(source threadsearch.GrepSource) bool {
		if current == nil {
			latest := r.config.Store.Snapshot()
			current = &latest
		}
		hash, exists := current.RecordHash("thread:" + source.ID)
		return exists && hash == source.Hash && !r.IsDeleting(source.ID)
	})
}
