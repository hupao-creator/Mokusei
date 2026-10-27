package main

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	aa "github.com/hupao-creator/Mokusei/internal/plugins/contexts/artificialanalysis"
)

type refreshBarrier struct {
	client           *fixture
	mu               sync.Mutex
	started, release chan struct{}
}

func (b *refreshBarrier) Do(request *http.Request) (*http.Response, error) {
	b.mu.Lock()
	var started, release chan struct{}
	if request.URL.Path == "/models/" && b.release != nil {
		started, release = b.started, b.release
		b.started, b.release = nil, nil
	}
	b.mu.Unlock()
	if release != nil {
		close(started)
		select {
		case <-request.Context().Done():
			return nil, request.Context().Err()
		case <-release:
		}
	}
	return b.client.Do(request)
}

func cacheRefreshReplay() {
	root, err := os.MkdirTemp("", "oa-aa-refresh-")
	require(err == nil, "refresh cache root")
	defer os.RemoveAll(root)
	client := &fixture{}
	barrier := &refreshBarrier{client: client}
	var now atomic.Int64
	now.Store(time.Now().UnixMilli())
	published := make(chan aa.Snapshot, 16)
	source, err := aa.NewSource(aa.Options{CacheRoot: root, HTTPClient: barrier, Now: func() time.Time { return time.UnixMilli(now.Load()) }, OnPublished: func(snapshot aa.Snapshot) { published <- snapshot }})
	require(err == nil, "refresh source")
	defer source.Close()
	publication := func() aa.Snapshot {
		select {
		case snapshot := <-published:
			return snapshot
		case <-time.After(3 * time.Second):
			panic("catalog refresh did not publish")
		}
	}
	a := []aa.AcquisitionIdentity{{Names: []string{"model-a"}}}
	b := []aa.AcquisitionIdentity{{Names: []string{"model-b"}}}
	_, err = source.WaitForBootstrap(context.Background(), a)
	require(err == nil, "initial catalog A")
	publication()
	require(source.Refresh(context.Background(), b) == nil, "initial catalog B")
	publication()
	now.Add(int64(25 * time.Hour / time.Millisecond))
	require(source.Refresh(context.Background(), a) == nil, "expired catalog A refresh completes before B loads")
	publication()
	client.mu.Lock()
	client.mode = "gone"
	client.mu.Unlock()
	started, release := make(chan struct{}), make(chan struct{})
	barrier.mu.Lock()
	barrier.started, barrier.release = started, release
	barrier.mu.Unlock()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	cached, err := source.WaitForBootstrap(ctx, b)
	cancel()
	require(err == nil && len(cached.Releases) == 2, "expired warm catalog returns cached facts immediately")
	select {
	case <-started:
	case <-time.After(3 * time.Second):
		panic("expired catalog B did not acquire independently of A")
	}
	close(release)
	refreshed := publication()
	require(len(refreshed.Releases) == 1 && refreshed.Releases[0].Slug == "model-a", "catalog B independently refreshes and removes gone measurements")
	// A distinct generation drains B even if its publication callback ran
	// just before the generation finished.
	require(source.Refresh(context.Background(), nil) == nil, "catalog B generation drained")
	publication()

	client.mu.Lock()
	client.mode = ""
	countA := func() int {
		count := 0
		for _, request := range client.requests {
			if strings.HasPrefix(request, "/models/model-a-high|") {
				count++
			}
		}
		return count
	}
	before := countA()
	client.mu.Unlock()
	started, release = make(chan struct{}), make(chan struct{})
	barrier.mu.Lock()
	barrier.started, barrier.release = started, release
	barrier.mu.Unlock()
	finished := make(chan error, 1)
	go func() { finished <- source.Refresh(context.Background(), b) }()
	select {
	case <-started:
	case <-time.After(3 * time.Second):
		panic("catalog B acquisition did not start")
	}
	_, err = source.WaitForBootstrap(context.Background(), a)
	require(err == nil, "fresh A remains available while B refreshes")
	close(release)
	select {
	case err := <-finished:
		require(err == nil, "pending B refresh completes")
	case <-time.After(3 * time.Second):
		panic("pending B refresh did not settle")
	}
	// A distinct generation queues behind any work admitted while B was
	// blocked, making the HTTP request count independent of scheduling.
	require(source.Refresh(context.Background(), nil) == nil, "drain interleaved catalog generations")
	client.mu.Lock()
	after := countA()
	client.mu.Unlock()
	require(after == before, "unrelated pending refresh does not reacquire fresh catalog A")

	coldRoot, err := os.MkdirTemp("", "oa-aa-cold-retry-")
	require(err == nil, "cold retry root")
	defer os.RemoveAll(coldRoot)
	coldClient := &fixture{mode: "offline"}
	cold, err := aa.NewSource(aa.Options{CacheRoot: coldRoot, HTTPClient: coldClient})
	require(err == nil, "cold retry source")
	defer cold.Close()
	unavailable, err := cold.WaitForBootstrap(context.Background(), a)
	require(err == nil && unavailable.Availability == "unavailable", "failed cold catalog remains unknown")
	coldClient.mu.Lock()
	coldClient.mode = ""
	coldClient.mu.Unlock()
	available, err := cold.WaitForBootstrap(context.Background(), b)
	require(err == nil && available.Availability == "available" && available.Releases[0].Slug == "model-b", "catalog A failure backoff does not suppress catalog B bootstrap")
	fmt.Println("PASS AA independent catalog expiry, cold failure retry, gone-cache invalidation and no unrelated pending reacquisition")
}
