package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	aa "github.com/hupao-creator/Mokusei/internal/plugins/contexts/artificialanalysis"
	"net/http"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"time"
)

type registry struct {
	plugin.ContextRegistry
	definition plugin.MokuContextDefinition
}

func (r *registry) MokuContext(d plugin.MokuContextDefinition) error { r.definition = d; return nil }

type blocked struct {
	requests  atomic.Int64
	started   chan struct{}
	once      sync.Once
	cancelled atomic.Bool
}

func (b *blocked) Do(req *http.Request) (*http.Response, error) {
	b.requests.Add(1)
	b.once.Do(func() { close(b.started) })
	<-req.Context().Done()
	b.cancelled.Store(true)
	return nil, req.Context().Err()
}
func check(ok bool, label string) {
	if !ok {
		panic(label)
	}
}
func main() {
	hostReplay()
	runtimeReplay()
	catalogDrainReplay()
	root, _ := os.MkdirTemp("", "oa-aa-lease-")
	defer os.RemoveAll(root)
	httpClient := &blocked{started: make(chan struct{})}
	r := &registry{}
	p := aa.NewWithOptions(aa.Options{CacheRoot: root, HTTPClient: httpClient})
	if err := p.Register(r); err != nil {
		panic(err)
	}
	check(r.definition.TimeoutMS == 21000 && r.definition.OnFailure == "abort-send" && r.definition.InjectAt == "before-send", "context declaration")
	first, _ := r.definition.Create()
	second, _ := r.definition.Create()
	input := plugin.MokuContextInput{Catalogs: []plugin.BoundModelCatalog{{ID: "codex", DisplayName: "Codex", Load: func(context.Context) (json.RawMessage, error) {
		return json.RawMessage(`{"models":[{"selector":"model-a","provenance":{"kind":"native"}}]}`), nil
	}}}}
	out1, out2 := make(chan error, 1), make(chan error, 1)
	go func() { _, err := first.Collect(context.Background(), input); out1 <- err }()
	<-httpClient.started
	go func() { _, err := second.Collect(context.Background(), input); out2 <- err }()
	time.Sleep(20 * time.Millisecond)
	check(first.Close() == nil, "first lease closes")
	select {
	case <-out1:
	case <-time.After(time.Second):
		panic("first cancellation does not settle")
	}
	check(!httpClient.cancelled.Load(), "closing one lease keeps shared HTTP alive")
	check(second.Close() == nil, "last lease closes")
	select {
	case <-out2:
	case <-time.After(time.Second):
		panic("last cancellation does not settle")
	}
	check(httpClient.cancelled.Load(), "last lease aborts HTTP")
	check(httpClient.requests.Load() == 1, "equal catalogs share acquisition")
	_, err := os.Stat(filepath.Join(root, "moku-evaluation-facts.json"))
	check(os.IsNotExist(err), "cancelled generation publishes no cache")
	third, err := r.definition.Create()
	check(err == nil, "new source after disposal")
	fallback, err := third.(plugin.MokuContextFallback).Fallback(context.Background(), input)
	check(err == nil && len(fallback) > 0, "empty cache explicit unavailable fallback")
	third.Close()
	fmt.Println("AA lease replay passed: declaration, shared catalog dedup, independent cancellation, last-lease abort/drain, no late cache write, fresh recreation, fallback")
}

func catalogDrainReplay() {
	for _, callerCancels := range []bool{true, false} {
		root, err := os.MkdirTemp("", "oa-aa-catalog-drain-")
		must(err)
		defer os.RemoveAll(root)
		r := &registry{}
		var catalogFailures, catalogCancellations atomic.Int64
		must(aa.NewWithOptions(aa.Options{CacheRoot: root, Log: func(event string, _ map[string]any) {
			switch event {
			case "aa.context.catalog.failed":
				catalogFailures.Add(1)
			case "aa.context.catalog.cancelled":
				catalogCancellations.Add(1)
			}
		}}).Register(r))
		service, err := r.definition.Create()
		must(err)
		started, cancelled, release, exited := make(chan struct{}), make(chan struct{}), make(chan struct{}), make(chan struct{})
		input := plugin.MokuContextInput{Catalogs: []plugin.BoundModelCatalog{{ID: "codex", DisplayName: "Codex", Load: func(ctx context.Context) (json.RawMessage, error) {
			defer close(exited)
			close(started)
			<-ctx.Done()
			close(cancelled)
			// A cooperative callback may need to drain its own native resources
			// after cancellation. The service must retain ownership until then.
			<-release
			return nil, ctx.Err()
		}}}}
		ctx, cancel := context.WithCancel(context.Background())
		collected, closed := make(chan error, 1), make(chan error, 1)
		go func() { _, err := service.Collect(ctx, input); collected <- err }()
		select {
		case <-started:
		case <-time.After(3 * time.Second):
			panic("catalog callback did not start")
		}
		if callerCancels {
			cancel()
		}
		go func() { closed <- service.Close() }()
		select {
		case <-cancelled:
		case <-time.After(3 * time.Second):
			panic("catalog callback was not cancelled")
		}
		select {
		case <-collected:
			panic("collection returned before catalog callback drained")
		case <-closed:
			panic("Close returned before catalog callback drained")
		case <-time.After(50 * time.Millisecond):
		}
		close(release)
		must(await(closed, "Close joins catalog callback"))
		check(errors.Is(await(collected, "collection joins catalog callback"), context.Canceled), "catalog cancellation preserved")
		check(catalogFailures.Load() == 0 && catalogCancellations.Load() == 1, "catalog cancellation is not a failure")
		select {
		case <-exited:
		default:
			panic("catalog callback outlived service")
		}
		cancel()
	}
	fmt.Println("PASS AA caller/Close cancellation joins catalog callbacks after cooperative cleanup")
}
