package main

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	core "github.com/hupao-creator/Mokusei/internal/core/runtime"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/services/localembedding"
	"github.com/hupao-creator/Mokusei/internal/services/threadsearch"
)

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

type heldDownloadClose struct {
	io.ReadCloser
	entered, release chan struct{}
}

type heldModelRemoval struct {
	*localembedding.Provider
	entered, release chan struct{}
}

func (p heldModelRemoval) Remove() error {
	close(p.entered)
	<-p.release
	return p.Provider.Remove()
}

func verifyExclusiveModelRemoval(ctx context.Context, directory string, provider *localembedding.Provider) {
	db, err := store.Open(filepath.Join(directory, "remove-model.sqlite"))
	must(err)
	defer db.Close()
	seed(db, thread("remove", "Removal fixture", "synthetic history"))
	held := heldModelRemoval{provider, make(chan struct{}), make(chan struct{})}
	r, err := core.New(ctx, core.Config{Store: db, Harnesses: map[string]plugin.Harness{"fixture": harness{}}, DataDir: directory, DefaultCwd: directory, Embeddings: held})
	must(err)
	defer r.Close(ctx)
	removed, enabled := make(chan threadsearch.Status, 1), make(chan threadsearch.Status, 1)
	go func() { removed <- invoke(r, "search:model", map[string]any{"action": "remove"}).(threadsearch.Status) }()
	<-held.entered
	revision := status(r).Config.Revision
	go func() {
		enabled <- invoke(r, "search:index", threadsearch.IndexRequest{Action: "start", Consent: true, ExpectedRevision: revision}).(threadsearch.Status)
	}()
	var early bool
	select {
	case <-enabled:
		early = true
	case <-time.After(50 * time.Millisecond):
	}
	close(held.release)
	afterRemoval := <-removed
	if !early {
		afterEnable := <-enabled
		assert(!afterEnable.Config.Enabled && !afterEnable.ModelAvailable, "enable queued behind removal falls back to missing model without authorization")
	}
	assert(!early && !afterRemoval.Config.Enabled && !afterRemoval.ModelAvailable, "model removal and index revocation form one control operation across windows")
	fmt.Println("PASS model removal excludes overlapping index enable and leaves consent revoked")
}

func (b heldDownloadClose) Close() error {
	close(b.entered)
	<-b.release
	return b.ReadCloser.Close()
}

func verifyConcurrentAssetActions(directory string) {
	engine, model := archiveBytes("engine/llama-server"), []byte("synthetic model")
	var modelRequests atomic.Int64
	streaming, wrappedReady, closing, release := make(chan struct{}), make(chan struct{}), make(chan struct{}), make(chan struct{})
	var releaseOnce sync.Once
	releaseClose := func() { releaseOnce.Do(func() { close(release) }) }
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/engine" {
			w.Write(engine)
			return
		}
		if modelRequests.Add(1) == 1 {
			w.Write(model[:1])
			w.(http.Flusher).Flush()
			close(streaming)
			<-r.Context().Done()
			return
		}
		w.Write(model)
	}))
	defer server.Close()
	var wrapped atomic.Bool
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		response, err := server.Client().Transport.RoundTrip(r)
		if err == nil && r.URL.Path == "/model" && wrapped.CompareAndSwap(false, true) {
			response.Body = heldDownloadClose{response.Body, closing, release}
			close(wrappedReady)
		}
		return response, err
	})}
	assets := localembedding.Assets{Model: asset(server.URL+"/model", model), Runtime: asset(server.URL+"/engine", engine)}
	p := localembedding.New(localembedding.Options{Directory: filepath.Join(directory, "concurrent-assets"), Assets: &assets, DownloadHTTP: client})
	defer func() { releaseClose(); p.Close() }()
	must(p.Download(context.Background()))
	await := func(ch <-chan struct{}, label string) {
		select {
		case <-ch:
		case <-time.After(5 * time.Second):
			panic(fmt.Sprintf("%s timed out: %+v", label, p.SetupStatus()))
		}
	}
	await(streaming, "streaming fixture model")
	await(wrappedReady, "wrapped fixture response")
	removed, downloaded := make(chan error, 1), make(chan error, 1)
	go func() { removed <- p.Remove() }()
	await(closing, "joined removal")
	go func() { downloaded <- p.Download(context.Background()) }()
	var early bool
	select {
	case err := <-downloaded:
		must(err)
		early = true
	case <-time.After(50 * time.Millisecond):
	}
	releaseClose()
	must(<-removed)
	if !early {
		must(<-downloaded)
	}
	assert(!early, "a new explicit download waits for overlapping removal instead of being silently discarded")
	wait("download after joined removal", func() bool { return !p.SetupStatus().Downloading })
	assert(p.Available(context.Background()) && modelRequests.Load() == 2, "later explicit download installs only after removal completes")
	fmt.Println("PASS joined model removal serializes overlapping explicit download actions")
}

func verifyCancelledReplacement(ctx context.Context, directory string, p *localembedding.Provider, s *service) {
	defer p.Close()
	modelPath := filepath.Join(directory, "models", "embeddinggemma-2", "text.gguf")
	before, err := os.Stat(modelPath)
	must(err)
	_, entered := s.hold()
	defer s.release()
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	done := make(chan error, 1)
	go func() {
		_, err := p.Embed(ctx, "task: search result | query: replacement fixture", 768)
		done <- err
	}()
	<-entered
	must(p.Download(ctx))
	wait("replacement staged behind active inference", func() bool {
		paths, err := filepath.Glob(filepath.Join(directory, "models", "embeddinggemma-2", "install-*", "ready.json"))
		must(err)
		return len(paths) == 1
	})
	// The caller cancels while installation is waiting for the inference lock.
	// Release that inference afterward so cancellation can join the installer.
	go func() { time.Sleep(100 * time.Millisecond); s.release() }()
	p.CancelDownload()
	must(<-done)
	after, err := os.Stat(modelPath)
	must(err)
	assert(p.SetupStatus().Reason == "cancelled" && before.ModTime().Equal(after.ModTime()) && p.Available(ctx),
		"cancelling a staged replacement preserves the previous ready installation")
	fmt.Println("PASS cancellation behind active inference cannot publish a staged model replacement")
}
