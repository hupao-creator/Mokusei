package main

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync/atomic"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/hosts/contexthost"
)

type contextModule struct {
	id          string
	definitions []plugin.MokuContextDefinition
	declared    []string
}

func (m contextModule) Manifest() plugin.ContextManifest {
	ids := m.declared
	if ids == nil {
		for _, d := range m.definitions {
			ids = append(ids, d.ID)
		}
	}
	return plugin.ContextManifest{ID: m.id, DisplayName: m.id, APIVersion: 1, Contributions: ids}
}
func (m contextModule) Register(r plugin.ContextRegistry) error {
	for _, d := range m.definitions {
		if err := r.MokuContext(d); err != nil {
			return err
		}
	}
	return nil
}

type contextService struct {
	collect func(context.Context, plugin.MokuContextInput) (string, error)
	close   func() error
}

func (s *contextService) Collect(ctx context.Context, input plugin.MokuContextInput) (string, error) {
	return s.collect(ctx, input)
}
func (s *contextService) Close() error {
	if s.close != nil {
		return s.close()
	}
	return nil
}

type fallbackService struct {
	*contextService
	fallback func(context.Context, plugin.MokuContextInput) (string, error)
}

func (s *fallbackService) Fallback(ctx context.Context, input plugin.MokuContextInput) (string, error) {
	return s.fallback(ctx, input)
}

func definition(id, slot, text string) plugin.MokuContextDefinition {
	return plugin.MokuContextDefinition{ID: id, Slot: slot, InjectAt: "before-send", TimeoutMS: 1000, OnFailure: "abort-send", Create: func() (plugin.MokuContextService, error) {
		return &contextService{collect: func(context.Context, plugin.MokuContextInput) (string, error) { return text, nil }}, nil
	}}
}
func must(err error) {
	if err != nil {
		panic(err)
	}
}
func await(result <-chan error, label string) error {
	select {
	case err := <-result:
		return err
	case <-time.After(3 * time.Second):
		panic(label)
	}
}
func collectOnce(definitions ...plugin.MokuContextDefinition) ([]plugin.ContextEntry, error) {
	h, err := contexthost.New(contexthost.Config{Plugins: []plugin.ContextPlugin{contextModule{id: "fixture", definitions: definitions}}})
	must(err)
	must(h.Start(context.Background(), plugin.RuntimeStartContext{}))
	defer h.Stop(context.Background())
	return h.CollectMokuContexts(context.Background(), "before-send", nil)
}

func hostReplay() {
	ctx := context.Background()
	first := definition("fixture.first", "z", "first")
	second := definition("fixture.second", "z", "second")
	start := definition("fixture.start", "start", "session")
	start.InjectAt = "session-start"
	for _, module := range []contextModule{
		{id: "fixture", definitions: []plugin.MokuContextDefinition{first}, declared: []string{}},
		{id: "fixture", definitions: []plugin.MokuContextDefinition{first, first}},
		{id: "other", definitions: []plugin.MokuContextDefinition{first}},
	} {
		_, err := contexthost.New(contexthost.Config{Plugins: []plugin.ContextPlugin{module}})
		check(err != nil, "invalid registration accepted")
	}
	invalid := first
	invalid.InjectAt = "ordinary-task"
	_, err := contexthost.New(contexthost.Config{Plugins: []plugin.ContextPlugin{contextModule{id: "fixture", definitions: []plugin.MokuContextDefinition{invalid}}}})
	check(err != nil, "non-Moku hook accepted")
	module := contextModule{id: "fixture", definitions: []plugin.MokuContextDefinition{first}}
	_, err = contexthost.New(contexthost.Config{Plugins: []plugin.ContextPlugin{module, module}})
	check(err != nil, "duplicate plugin accepted")
	var creations atomic.Int64
	disabled := definition("disabled.value", "ignored", "ignored")
	disabled.Create = func() (plugin.MokuContextService, error) { creations.Add(1); return nil, errors.New("must not create") }
	preferences := map[string]bool{"context:disabled": false}
	h, err := contexthost.New(contexthost.Config{Plugins: []plugin.ContextPlugin{
		contextModule{id: "fixture", definitions: []plugin.MokuContextDefinition{second, start, first, definition("fixture.alpha", "a", "alpha")}},
		contextModule{id: "disabled", definitions: []plugin.MokuContextDefinition{disabled}},
	}, PluginEnabled: preferences})
	must(err)
	preferences["context:disabled"] = true
	_, err = h.CollectMokuContexts(ctx, "before-send", nil)
	check(err != nil, "collect before start")
	must(h.Start(ctx, plugin.RuntimeStartContext{}))
	check(h.Start(ctx, plugin.RuntimeStartContext{}) != nil, "double start")
	entries, err := h.CollectMokuContexts(ctx, "before-send", nil)
	must(err)
	check(len(entries) == 2 && entries[0].ID == "a" && entries[1].ID == "z" && entries[1].Content == "first\n\nsecond", "ordered slots and contributions")
	entries, err = h.CollectMokuContexts(ctx, "session-start", nil)
	must(err)
	check(len(entries) == 1 && entries[0].Content == "session" && creations.Load() == 0, "phase selection and disabled factory")
	must(h.Stop(ctx))
	must(h.Start(ctx, plugin.RuntimeStartContext{}))
	must(h.Stop(ctx))
	_, err = h.CollectMokuContexts(ctx, "before-send", nil)
	check(err != nil, "collect after stop")

	timeout := definition("fixture.timeout", "evaluation", "")
	timeout.TimeoutMS = 10
	timeout.Create = func() (plugin.MokuContextService, error) {
		return &fallbackService{contextService: &contextService{collect: func(ctx context.Context, _ plugin.MokuContextInput) (string, error) {
			<-ctx.Done()
			return "", ctx.Err()
		}}, fallback: func(ctx context.Context, _ plugin.MokuContextInput) (string, error) { return "cached", ctx.Err() }}, nil
	}
	entries, err = collectOnce(timeout)
	must(err)
	check(len(entries) == 1 && entries[0].Content == "cached", "timeout receives independent fallback budget")
	empty := definition("fixture.empty", "evaluation", "")
	_, err = collectOnce(empty)
	check(err != nil, "abort empty context")
	empty.OnFailure = "omit"
	entries, err = collectOnce(empty)
	must(err)
	check(len(entries) == 0, "omit empty context")
	_, err = collectOnce(definition("fixture.large", "evaluation", strings.Repeat("x", 128*1024+1)))
	check(err != nil, "contribution byte limit")
	_, err = collectOnce(definition("fixture.a", "a", strings.Repeat("x", 128*1024)), definition("fixture.b", "b", strings.Repeat("x", 128*1024)), definition("fixture.c", "c", "x"))
	check(err != nil, "aggregate byte limit")
	entries, err = collectOnce(definition("fixture.a", "shared", strings.Repeat("x", 128*1024)), definition("fixture.b", "shared", strings.Repeat("x", 128*1024-2)))
	must(err)
	check(len(entries) == 1 && len(entries[0].Content) == 256*1024, "aggregate exact byte limit includes separators")
	_, err = collectOnce(definition("fixture.a", "shared", strings.Repeat("x", 128*1024)), definition("fixture.b", "shared", strings.Repeat("x", 128*1024)))
	check(err != nil, "merged slot separators cannot exceed aggregate byte limit")

	var closed, fallbackCalls atomic.Int64
	begun := make(chan struct{}, 1)
	blocking := definition("fixture.blocking", "evaluation", "")
	blocking.OnFailure = "omit"
	blocking.Create = func() (plugin.MokuContextService, error) {
		return &fallbackService{contextService: &contextService{collect: func(ctx context.Context, _ plugin.MokuContextInput) (string, error) {
			begun <- struct{}{}
			<-ctx.Done()
			return "", ctx.Err()
		}, close: func() error { closed.Add(1); return nil }}, fallback: func(context.Context, plugin.MokuContextInput) (string, error) {
			fallbackCalls.Add(1)
			return "must not fallback", nil
		}}, nil
	}
	h, err = contexthost.New(contexthost.Config{Plugins: []plugin.ContextPlugin{contextModule{id: "fixture", definitions: []plugin.MokuContextDefinition{blocking}}}})
	must(err)
	must(h.Start(ctx, plugin.RuntimeStartContext{}))
	result := make(chan error, 1)
	caller, cancel := context.WithCancel(ctx)
	go func() { _, err := h.CollectMokuContexts(caller, "before-send", nil); result <- err }()
	<-begun
	cancel()
	check(errors.Is(await(result, "caller cancellation"), context.Canceled), "omit cannot swallow cancellation")
	go func() { _, err := h.CollectMokuContexts(ctx, "before-send", nil); result <- err }()
	<-begun
	must(h.Stop(ctx))
	check(errors.Is(await(result, "stop drain"), context.Canceled), "stop cancels collection")
	check(closed.Load() == 1 && fallbackCalls.Load() == 0, "stop closes service without fallback")
	must(h.Start(ctx, plugin.RuntimeStartContext{}))
	must(h.Stop(ctx))
	check(closed.Load() == 2, "fresh service generation")

	// Stop must include a service whose factory finishes after revocation.
	creating, release := make(chan struct{}), make(chan struct{})
	slow := definition("fixture.slow", "evaluation", "")
	slow.Create = func() (plugin.MokuContextService, error) {
		close(creating)
		<-release
		return &contextService{collect: func(context.Context, plugin.MokuContextInput) (string, error) { return "", nil }, close: func() error { closed.Add(1); return nil }}, nil
	}
	h, err = contexthost.New(contexthost.Config{Plugins: []plugin.ContextPlugin{contextModule{id: "fixture", definitions: []plugin.MokuContextDefinition{slow}}}})
	must(err)
	go func() { result <- h.Start(ctx, plugin.RuntimeStartContext{}) }()
	<-creating
	stopCtx, stopCancel := context.WithCancel(ctx)
	stopCancel()
	check(errors.Is(h.Stop(stopCtx), context.Canceled), "stop waits for in-flight factory")
	close(release)
	check(errors.Is(await(result, "cancelled start drains"), context.Canceled), "start cancelled")
	check(closed.Load() == 3, "late-created service closed")
	must(h.Stop(ctx))

	// Restart may overlap a slow Close, but its new service must survive the
	// previous generation's drain and deferred cleanup.
	closing, finishClose := make(chan struct{}), make(chan struct{})
	var generations atomic.Int64
	restarting := definition("fixture.restart", "evaluation", "")
	restarting.Create = func() (plugin.MokuContextService, error) {
		generation := generations.Add(1)
		return &contextService{collect: func(context.Context, plugin.MokuContextInput) (string, error) {
			return fmt.Sprint(generation), nil
		}, close: func() error {
			if generation == 1 {
				close(closing)
				<-finishClose
			}
			return nil
		}}, nil
	}
	h, err = contexthost.New(contexthost.Config{Plugins: []plugin.ContextPlugin{contextModule{id: "fixture", definitions: []plugin.MokuContextDefinition{restarting}}}})
	must(err)
	must(h.Start(ctx, plugin.RuntimeStartContext{}))
	stopped, restarted := make(chan error, 1), make(chan error, 1)
	go func() { stopped <- h.Stop(ctx) }()
	<-closing
	go func() { restarted <- h.Start(ctx, plugin.RuntimeStartContext{}) }()
	close(finishClose)
	must(await(stopped, "slow Close drains"))
	must(await(restarted, "restart after drain"))
	entries, err = h.CollectMokuContexts(ctx, "before-send", nil)
	must(err)
	check(len(entries) == 1 && entries[0].Content == "2", "old Stop must not close new service")
	must(h.Stop(ctx))

	var partialCloses atomic.Int64
	createdFirst := definition("fixture.a", "evaluation", "")
	createdFirst.Create = func() (plugin.MokuContextService, error) {
		return &contextService{close: func() error { partialCloses.Add(1); return nil }}, nil
	}
	failedSecond := definition("fixture.b", "evaluation", "")
	failedSecond.Create = func() (plugin.MokuContextService, error) { return nil, errors.New("fixture acquisition failed") }
	h, err = contexthost.New(contexthost.Config{Plugins: []plugin.ContextPlugin{contextModule{id: "fixture", definitions: []plugin.MokuContextDefinition{createdFirst, failedSecond}}}})
	must(err)
	check(h.Start(ctx, plugin.RuntimeStartContext{}) != nil, "factory failure propagated")
	check(partialCloses.Load() == 1, "failed startup drains acquired services")
	must(h.Stop(ctx))
	fmt.Println("PASS Context host registration, startup enablement, hooks/order, fallback/bounds, cancellation, stop/create drain and restart")
}
