package runtime

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/platform/workpool"
	"github.com/hupao-creator/Mokusei/internal/services/directorytag"
)

type cachedThread struct {
	hash   string
	record model.ThreadRecord
}
type cachedOverview struct {
	hash   string
	record model.ThreadRecord
}

func (r *Runtime) computeTasks(ctx context.Context, tasks []workpool.Task) error {
	if r.compute == nil { // Private construction used by isolated diagnostic harnesses.
		for _, task := range tasks {
			if err := ctx.Err(); err != nil {
				return err
			}
			if err := task.Run(ctx); err != nil {
				return err
			}
		}
		return nil
	}
	fanout := 2
	if len(tasks) >= 4 {
		fanout = 4
	}
	return r.compute.Run(ctx, tasks, fanout)
}

// Cached records are private immutable values. Decode misses outside the cache
// lock, and never install an older snapshot over a newer cache generation.
func (r *Runtime) cachedThreads(snapshot store.Snapshot) ([]model.ThreadRecord, error) {
	ids := snapshot.Order("threads")
	seen := make(map[string]bool, len(ids))
	ordered := make([]string, 0, len(ids))
	for _, id := range ids {
		if !seen[id] {
			seen[id] = true
			ordered = append(ordered, id)
		}
	}
	for _, key := range snapshot.Keys("thread:") {
		id := key[len("thread:"):]
		if !seen[id] {
			seen[id] = true
			ordered = append(ordered, id)
		}
	}
	entries := make([]cachedThread, len(ordered))
	tasks := []workpool.Task{}
	r.threadCacheMu.Lock()
	for index, id := range ordered {
		key := "thread:" + id
		hash, exists := snapshot.RecordHash(key)
		if !exists {
			continue
		}
		entry, ok := r.threadCache[id]
		if ok && entry.hash == hash {
			entries[index] = entry
			continue
		}
		tasks = append(tasks, workpool.Task{Bytes: snapshot.RecordBytes(key), Run: func(ctx context.Context) error {
			entry := cachedThread{hash: hash}
			if _, err := snapshot.Get(key, &entry.record); err != nil {
				return err
			}
			entries[index] = entry
			return ctx.Err()
		}})
	}
	r.threadCacheMu.Unlock()
	if err := r.computeTasks(r.ctx, tasks); err != nil {
		return nil, err
	}
	next := make(map[string]cachedThread, len(entries))
	threads := make([]model.ThreadRecord, 0, len(entries))
	for i, entry := range entries {
		if entry.hash != "" {
			next[ordered[i]] = entry
			threads = append(threads, entry.record)
		}
	}
	r.threadCacheMu.Lock()
	if snapshot.Revision() >= r.threadCacheRevision {
		r.threadCache = next
		r.threadCacheRevision = snapshot.Revision()
	}
	r.threadCacheMu.Unlock()
	return threads, nil
}

func (r *Runtime) cachedThread(ctx context.Context, snapshot store.Snapshot, id string) (model.ThreadRecord, error) {
	key := "thread:" + id
	hash, exists := snapshot.RecordHash(key)
	if !exists {
		return model.ThreadRecord{}, fmt.Errorf("unknown thread: %s", id)
	}
	r.threadCacheMu.Lock()
	entry, ok := r.threadCache[id]
	r.threadCacheMu.Unlock()
	if ok && entry.hash == hash {
		return entry.record, nil
	}
	entry = cachedThread{hash: hash}
	err := r.computeTasks(ctx, []workpool.Task{{Bytes: snapshot.RecordBytes(key), Run: func(ctx context.Context) error { _, err := snapshot.Get(key, &entry.record); return err }}})
	if err != nil {
		return model.ThreadRecord{}, err
	}
	r.threadCacheMu.Lock()
	liveHash, _ := r.config.Store.Snapshot().RecordHash(key)
	if liveHash == hash {
		if r.threadCache == nil {
			r.threadCache = map[string]cachedThread{}
		}
		r.threadCache[id] = entry
		r.threadCacheRevision = max(r.threadCacheRevision, snapshot.Revision())
	}
	r.threadCacheMu.Unlock()
	return entry.record, nil
}

// Called under projectionMu, which orders whole-snapshot computation and cache
// installation independently of short publication/activity bookkeeping locks.
func (r *Runtime) projectThreads(snapshot store.Snapshot) ([]model.ThreadRecord, error) {
	threads, err := r.cachedThreads(snapshot)
	if err != nil {
		return nil, err
	}
	entries := make([]cachedOverview, len(threads))
	tasks := []workpool.Task{}
	for index, thread := range threads {
		hash, _ := snapshot.RecordHash("thread:" + thread.ID)
		entry, ok := r.overviewCache[thread.ID]
		if ok && entry.hash == hash {
			entries[index] = entry
			continue
		}
		tasks = append(tasks, workpool.Task{Bytes: snapshot.RecordBytes("thread:" + thread.ID), Run: func(ctx context.Context) error {
			entry := cachedOverview{hash: hash, record: thread}
			if harness := r.config.Harnesses[thread.HarnessID]; harness != nil {
				value, err := harness.SessionState().ProjectRenderer(bytes.Clone(thread.SessionState), model.RendererScope{Kind: "overview"})
				if err != nil {
					r.log("catalog.projection", err)
					entry.record.SessionState = json.RawMessage("null")
					entry.hash = ""
				} else {
					entry.record.SessionState = value
				}
			}
			if thread.Moku || thread.MokuHistory {
				entry.record.Transcript = auditPreview(thread.Transcript)
			}
			entries[index] = entry
			return ctx.Err()
		}})
	}
	if err := r.computeTasks(r.ctx, tasks); err != nil {
		return nil, err
	}
	next := make(map[string]cachedOverview, len(threads))
	for i, entry := range entries {
		next[threads[i].ID] = entry
		threads[i] = entry.record
		// Resolve against the host filesystem after copying the cached record.
		// Derived values must not enter durable storage or depend on a client
		// being able to resolve the host's symlinks and worktree metadata.
		threads[i].DirectoryTag = directorytag.Name(threads[i].Cwd)
		threads[i].DirectoryScope = directorytag.Scope(threads[i].Cwd)
	}
	r.overviewCache = next
	return threads, nil
}
