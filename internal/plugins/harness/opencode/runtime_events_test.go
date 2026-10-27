package opencode

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"
)

func TestRuntimeCloseDrainsEventCallbacks(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = fmt.Fprint(w, "data: {\"type\":\"server.connected\"}\n\n")
		w.(http.Flusher).Flush()
		<-r.Context().Done()
	}))
	t.Cleanup(server.Close)
	life, cancel := context.WithCancel(context.Background())
	runtime := &Runtime{URL: server.URL, client: server.Client(), ctx: life, cancel: cancel, listeners: map[uint64]listener{}, ready: make(chan struct{}), streamDone: make(chan struct{})}
	entered, cancelling, release, cleaned := make(chan struct{}), make(chan struct{}), make(chan struct{}), make(chan struct{})
	var releaseOnce sync.Once
	finish := func() { releaseOnce.Do(func() { close(release) }) }
	t.Cleanup(func() {
		finish()
		_ = runtime.Close()
	})
	runtime.Subscribe(func(Event) error {
		close(entered)
		<-life.Done()
		close(cancelling)
		<-release
		close(cleaned)
		return nil
	}, nil)
	select {
	case <-entered:
	case <-time.After(3 * time.Second):
		cancel()
		t.Fatal("native event did not reach callback")
	}
	done := make(chan error, 1)
	go func() { done <- runtime.Close() }()
	select {
	case <-cancelling:
	case <-time.After(3 * time.Second):
		t.Fatal("runtime close did not cancel events")
	}
	select {
	case err := <-done:
		t.Fatalf("runtime closed before callback cleanup: %v", err)
	case <-time.After(30 * time.Millisecond):
	}
	finish()
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("runtime did not join event callback after cleanup")
	}
	select {
	case <-cleaned:
	default:
		t.Fatal("event cleanup did not finish")
	}
}

func TestClosedRuntimeDoesNotRestartEventStream(t *testing.T) {
	life, cancel := context.WithCancel(context.Background())
	runtime := &Runtime{ctx: life, cancel: cancel, listeners: map[uint64]listener{}, ready: make(chan struct{}), streamDone: make(chan struct{})}
	if err := runtime.Close(); err != nil {
		t.Fatal(err)
	}
	unsubscribe := runtime.Subscribe(func(Event) error { t.Error("closed runtime emitted an event"); return nil }, nil)
	defer unsubscribe()
	if err := runtime.EventsReady(context.Background()); !errors.Is(err, context.Canceled) {
		t.Fatalf("closed event stream = %v", err)
	}
	runtime.mu.Lock()
	started := runtime.streamStarted
	runtime.mu.Unlock()
	if started {
		t.Fatal("closed runtime started another event goroutine")
	}
}
