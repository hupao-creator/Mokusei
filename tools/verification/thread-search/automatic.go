package main

import (
	"context"
	"fmt"
	"path/filepath"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/services/threadsearch"
)

func verifyAutomaticSearch(ctx context.Context, directory, target string, s *service) {
	directory = filepath.Join(directory, "automatic")
	db, err := store.Open(filepath.Join(directory, "state.sqlite"))
	must(err)
	defer db.Close()
	_, err = db.Update(ctx, func(tx *store.Tx) error {
		if err := tx.Put("search-document:old-turns", map[string]any{"chunks": []any{map[string]any{"text": "NEVER_UPLOAD_RUNNING"}}}); err != nil {
			return err
		}
		return tx.Put("search-config", map[string]any{
			"pipeline": plugin.LocalEmbeddingSpace + "/text-v3/runes1200-overlap150/v1",
			"revision": 9, "epoch": 4, "enabled": false, "includeContent": false,
			"autoUpdate": false, "indexPaused": true,
		})
	})
	must(err)
	stats := &automaticAssetStats{gate: make(chan struct{})}
	stats.failures.Store(1)
	factory, stop := fixtureAssets(directory, target, stats)
	defer stop()
	p := factory()
	defer p.Close()
	seed(db, thread("semantic", "Maintenance", "离线删除与后台清理"), thread("literal", "exact-ID-42", "different subject"))
	newAutomatic := func() *threadsearch.Manager {
		m, err := threadsearch.New(ctx, threadsearch.Options{Store: db, Provider: p, Sources: source,
			Interval: time.Millisecond, WatchInterval: 15 * time.Millisecond,
			RetryMin: 120 * time.Millisecond, RetryMax: 300 * time.Millisecond})
		must(err)
		return m
	}
	started := time.Now()
	m := newAutomatic()
	assert(time.Since(started) < time.Second, "startup does not wait for asset download or inference")
	defer func() { m.Close() }()
	assert(!db.Snapshot().Has("search-document:old-turns"), "previous turn policy cannot retain indexed unfinished content")
	status, err := m.Status(ctx)
	must(err)
	assert(status.Config.Enabled && status.Config.IncludeContent && status.Config.AutoUpdate && !status.Config.IndexPaused && status.Config.Revision == 10,
		"former disabled, metadata-only and paused settings migrate to automatic search")
	wait("automatic retry reaches gated download", func() bool { return stats.requests.Load() >= 2 })
	stats.mu.Lock()
	retryGap := stats.times[1].Sub(stats.times[0])
	stats.mu.Unlock()
	assert(retryGap >= 120*time.Millisecond, "failed asset download respects retry backoff")
	for i := 0; i < 10; i++ {
		seed(db, thread("literal", "exact-ID-42", "different subject"))
	}
	time.Sleep(70 * time.Millisecond)
	assert(stats.requests.Load() == 2, "catalog events do not duplicate the in-flight automatic download")
	fallback, err := m.Query(ctx, threadsearch.QueryRequest{Query: "exact-ID-42", Threads: refs("semantic", "literal")})
	must(err)
	assert(fallback.Mode == "keyword" && len(fallback.Hits) == 1 && fallback.Hits[0].Ref.ThreadID == "literal", "basic search stays usable while preparation is blocked")
	close(stats.gate)
	wait("automatic setup immediately leads to indexing", func() bool { x, _ := m.Status(ctx); return !x.Working && x.Indexed == 2 })
	assert(stats.requests.Load() == 3 && p.Available(ctx), "one failed download plus one verified engine/model installation")
	result, err := m.Query(ctx, threadsearch.QueryRequest{Query: "清空历史", Threads: refs("semantic", "literal")})
	must(err)
	assert(result.Mode == "hybrid" && len(result.Hits) == 1 && result.Hits[0].Ref.ThreadID == "semantic", "default search recalls body text without configure, download or index actions")
	before := s.calls.Load()
	s.mode.Store(1)
	defer s.mode.Store(0)
	seed(db, thread("semantic", "Maintenance", "离线删除与后台清理：更新"))
	wait("automatic inference failure is recorded", func() bool { x, _ := m.Status(ctx); return !x.Working && x.Reason != "" })
	s.mode.Store(0)
	wait("automatic inference retries without another catalog event", func() bool { x, _ := m.Status(ctx); return !x.Working && x.Indexed == 2 })
	assert(s.calls.Load() >= before+2, "transient evaluation failure recovers instead of freezing maintenance")
	seed(db, thread("new", "New thread", "后台清理"))
	wait("new thread automatically indexed", func() bool { x, _ := m.Status(ctx); return !x.Working && x.Indexed == 3 })
	must(m.Close())
	seed(db, thread("new", "New thread", "后台清理：离线更新"))
	m = newAutomatic()
	wait("offline changes automatically reconciled", func() bool { x, _ := m.Status(ctx); return !x.Working && x.Indexed == 3 })
	assert(stats.requests.Load() == 3, "restart reuses verified assets instead of downloading again")
	_, err = db.Update(ctx, func(tx *store.Tx) error {
		for _, key := range tx.Keys("thread:") {
			if err := tx.Delete(key); err != nil {
				return err
			}
		}
		return threadsearch.ClearHistory(tx)
	})
	must(err)
	status, err = m.Status(ctx)
	must(err)
	assert(status.Config.Enabled && status.Config.AutoUpdate && status.Indexed == 0, "clearing history deletes derived content while keeping search automatic")
	seed(db, thread("after-clear", "Future thread", "后台清理"))
	wait("future thread indexes after history clear", func() bool { x, _ := m.Status(ctx); return !x.Working && x.Indexed == 1 })
	must(m.Close())
	// A separate missing installation proves shutdown cancels and joins the
	// real downloader; no completed or failed request may restart it afterward.
	stats2 := &automaticAssetStats{gate: make(chan struct{})}
	factory2, stop2 := fixtureAssets(filepath.Join(directory, "closing"), target, stats2)
	defer stop2()
	p2 := factory2()
	defer p2.Close()
	m2, err := threadsearch.New(ctx, threadsearch.Options{Store: db, Provider: p2, Sources: source,
		WatchInterval: 15 * time.Millisecond, RetryMin: 30 * time.Millisecond})
	must(err)
	defer m2.Close()
	wait("automatic downloader starts before close", func() bool { return stats2.requests.Load() == 1 })
	must(m2.Close())
	assert(!p2.SetupStatus().Downloading && !p2.Available(ctx), "manager close joins automatic download cancellation")
	time.Sleep(70 * time.Millisecond)
	assert(stats2.requests.Load() == 1, "closed manager cannot retry or publish a late installation")
	fmt.Println("PASS default-on legacy migration, automatic verified setup, deduplication/backoff, keyword fallback, automatic content indexing, transient retry, new/offline updates, history reset and joined shutdown")
}
