package main

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/services/localembedding"
)

func verifyPipelineReset(ctx context.Context, directory string, p *localembedding.Provider, s *service) {
	defer p.Close()
	db, err := store.Open(filepath.Join(directory, "old-space.sqlite"))
	must(err)
	defer db.Close()
	_, err = db.Update(ctx, func(tx *store.Tx) error {
		if err := tx.Put("search-config", map[string]any{"pipeline": "old-cloud-space", "revision": 7, "epoch": 2, "enabled": true, "autoUpdate": true}); err != nil {
			return err
		}
		if err := tx.Put("search-usage", map[string]any{"requests": 200}); err != nil {
			return err
		}
		return tx.Put("search-document:old", map[string]any{"text": "NEVER_UPLOAD_OLD_CLOUD_SPACE"})
	})
	must(err)
	before := s.calls.Load()
	m := newManager(ctx, db, p)
	defer m.Close()
	status, err := m.Status(ctx)
	must(err)
	assert(status.Config.Enabled && status.Config.AutoUpdate && status.Config.IncludeContent && status.Config.Revision == 8 && len(db.Snapshot().Keys("search-document:")) == 0 && !db.Snapshot().Has("search-usage"), "old embedding spaces are discarded and automatic search policy is enabled")
	assert(s.calls.Load() == before, "model-space migration does not block construction on inference")
	fmt.Println("PASS model-space invalidation, automatic policy migration and idle local-process release")
}

func archiveBytes(name string) []byte {
	var out bytes.Buffer
	gz := gzip.NewWriter(&out)
	tw := tar.NewWriter(gz)
	text := []byte("#!/bin/sh\nexit 1\n")
	must(tw.WriteHeader(&tar.Header{Name: name, Mode: 0700, Size: int64(len(text))}))
	_, err := tw.Write(text)
	must(err)
	must(tw.Close())
	must(gz.Close())
	return out.Bytes()
}
func asset(url string, data []byte) localembedding.Asset {
	h := sha256.Sum256(data)
	return localembedding.Asset{URL: url, Bytes: int64(len(data)), SHA256: hex.EncodeToString(h[:])}
}
func verifySetupFailures(directory string) {
	for _, mode := range []string{"checksum", "traversal", "cancel"} {
		engine := archiveBytes("engine/llama-server")
		if mode == "traversal" {
			engine = archiveBytes("../escape")
		}
		model := bytes.Repeat([]byte("synthetic"), 1000)
		entered := make(chan struct{})
		var once sync.Once
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Path == "/engine" {
				w.Write(engine)
				return
			}
			if mode == "cancel" {
				w.Write(model[:8])
				w.(http.Flusher).Flush()
				once.Do(func() { close(entered) })
				<-r.Context().Done()
				return
			}
			w.Write(model)
		}))
		assets := localembedding.Assets{Model: asset(server.URL+"/model", model), Runtime: asset(server.URL+"/engine", engine)}
		if mode == "checksum" {
			assets.Model.SHA256 = strings.Repeat("0", 64)
		}
		p := localembedding.New(localembedding.Options{Directory: filepath.Join(directory, "setup-"+mode), Assets: &assets, DownloadHTTP: server.Client()})
		must(p.Download(context.Background()))
		if mode == "cancel" {
			select {
			case <-entered:
			case <-time.After(5 * time.Second):
				panic("model download never started")
			}
			p.CancelDownload()
		}
		wait("failed setup settles", func() bool { return !p.SetupStatus().Downloading })
		assert(!p.Available(context.Background()) && p.SetupStatus().Reason != "", "failed/cancelled downloads cannot publish ready state")
		_, err := os.Stat(filepath.Join(directory, "setup-"+mode, "escape"))
		assert(os.IsNotExist(err), "archive never escapes its staging directory")
		p.Close()
		server.Close()
	}
	fmt.Println("PASS explicit artifact downloads, checksum mismatch, unsafe archive rejection and joined download cancellation")
}

// An opt-in, small engine-only smoke check. Real pinned llama.cpp is unpacked
// through the production installer; deliberately invalid tiny model bytes prove
// startup failure is bounded and cleaned up. This is not real-model inference.
func verifyRealEngine(path string) {
	engine, err := os.ReadFile(path)
	must(err)
	h := sha256.Sum256(engine)
	assert(hex.EncodeToString(h[:]) == "003af1321ed9be9485902a2e17aad0c874a456c10f0a4ece5a735c495f3a3afb", "exact pinned arm64 runtime archive")
	directory, err := os.MkdirTemp("", "mokusei-local-engine-smoke-")
	must(err)
	defer os.RemoveAll(directory)
	model := []byte("deliberately invalid synthetic GGUF")
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/engine" {
			w.Write(engine)
		} else {
			w.Write(model)
		}
	}))
	defer server.Close()
	assets := localembedding.Assets{Model: asset(server.URL+"/model", model), Runtime: asset(server.URL+"/engine", engine)}
	p := localembedding.New(localembedding.Options{Directory: directory, Assets: &assets, DownloadHTTP: server.Client()})
	defer p.Close()
	install(p)
	started := time.Now()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	_, err = p.Embed(ctx, "task: search result | query: synthetic", 768)
	assert(err != nil && time.Since(started) < 25*time.Second, "actual engine error/cancellation is bounded by the caller deadline")
	must(p.Release())
	assert(!p.SetupStatus().Loaded, "failed actual engine does not remain loaded")
	fmt.Println("PASS pinned real llama.cpp archive install, actual executable startup failure and process cleanup; no model weights downloaded")
}
