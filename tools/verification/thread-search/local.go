package main

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/services/localembedding"
)

type automaticAssetStats struct {
	requests atomic.Int64
	failures atomic.Int64
	gate     chan struct{}
	mu       sync.Mutex
	times    []time.Time
}

func fixtureAssets(directory, target string, automatic ...*automaticAssetStats) (func() *localembedding.Provider, func()) {
	return fixtureAssetsWithTrace(directory, target, nil, automatic...)
}

func fixtureAssetsWithTrace(directory, target string, trace func(plugin.SearchDiagnostic), automatic ...*automaticAssetStats) (func() *localembedding.Provider, func()) {
	executable, err := os.Executable()
	must(err)
	quote := func(s string) string { return "'" + strings.ReplaceAll(s, "'", "'\\''") + "'" }
	script := []byte("#!/bin/sh\nexec " + quote(executable) + " embedding-fixture-child " + quote(target) + " \"$@\"\n")
	var archive bytes.Buffer
	gz := gzip.NewWriter(&archive)
	tw := tar.NewWriter(gz)
	must(tw.WriteHeader(&tar.Header{Name: "fixture/llama-server", Mode: 0700, Size: int64(len(script))}))
	_, err = tw.Write(script)
	must(err)
	must(tw.Close())
	must(gz.Close())
	engine := archive.Bytes()
	model := []byte("GGUF SYNTHETIC MODEL - NOT REAL WEIGHTS")
	var downloads atomic.Int64
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		assert(r.Method == "GET" && r.Header.Get("Authorization") == "", "asset requests contain no conversation or credential")
		downloads.Add(1)
		if len(automatic) != 0 {
			stats := automatic[0]
			stats.mu.Lock()
			stats.times = append(stats.times, time.Now())
			stats.requests.Add(1)
			stats.mu.Unlock()
			if stats.failures.CompareAndSwap(1, 0) {
				w.WriteHeader(http.StatusServiceUnavailable)
				return
			}
			select {
			case <-stats.gate:
			case <-r.Context().Done():
				return
			}
		}
		switch r.URL.Path {
		case "/engine":
			w.Write(engine)
		case "/model":
			w.Write(model)
		default:
			w.WriteHeader(404)
		}
	}))
	hash := func(data []byte) string { h := sha256.Sum256(data); return hex.EncodeToString(h[:]) }
	assets := localembedding.Assets{Model: localembedding.Asset{URL: server.URL + "/model", Bytes: int64(len(model)), SHA256: hash(model)}, Runtime: localembedding.Asset{URL: server.URL + "/engine", Bytes: int64(len(engine)), SHA256: hash(engine)}}
	factory := func() *localembedding.Provider {
		return localembedding.New(localembedding.Options{Directory: filepath.Join(directory, "models"), Trace: trace, Assets: &assets, DownloadHTTP: server.Client(), IdleTimeout: 200 * time.Millisecond})
	}
	if len(automatic) != 0 {
		return factory, server.Close
	}
	p := factory()
	assert(!p.Available(context.Background()) && downloads.Load() == 0, "constructing/status never downloads")
	must(p.Download(context.Background()))
	wait("verified local model installation", func() bool { return !p.SetupStatus().Downloading })
	assert(p.Available(context.Background()) && downloads.Load() == 2, "hash-checked engine and model installed only on explicit action")
	must(p.Remove())
	assert(!p.Available(context.Background()), "remove clears model readiness")
	p.Close()
	return factory, server.Close
}
func install(p *localembedding.Provider) {
	must(p.Download(context.Background()))
	wait("local fixture installation", func() bool { return !p.SetupStatus().Downloading })
	assert(p.Available(context.Background()), "installed fixture validates")
}
func runEmbeddingPeer() {
	target := os.Args[2]
	args := os.Args[3:]
	values := map[string]string{}
	flags := map[string]bool{}
	for i := 0; i < len(args); i++ {
		if i+1 < len(args) && !strings.HasPrefix(args[i+1], "--") {
			values[args[i]] = args[i+1]
			i++
		} else {
			flags[args[i]] = true
		}
	}
	assert(values["--host"] == "127.0.0.1" && values["--pooling"] == "mean" && values["--parallel"] == "1", "local process address/pooling/parallelism")
	assert(values["--ctx-size"] == "8192" && values["--batch-size"] == "8192" && values["--ubatch-size"] == "8192", "whole text in one noncausal batch")
	assert(flags["--offline"] && flags["--no-webui"] && flags["--embedding"] && flags["--log-disable"], "offline embedding-only process")
	assert(values["--threads"] == "4" && len(os.Getenv("LLAMA_API_KEY")) == 64 && os.Getenv("GEMINI_API_KEY") == "" && os.Getenv("HTTPS_PROXY") == "", "minimal environment and private token")
	port, err := strconv.Atoi(values["--port"])
	must(err)
	listener, err := net.Listen("tcp4", fmt.Sprintf("127.0.0.1:%d", port))
	must(err)
	client := &http.Client{Transport: &http.Transport{Proxy: nil}, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer "+os.Getenv("LLAMA_API_KEY") {
			w.WriteHeader(401)
			return
		}
		if r.URL.Path == "/health" {
			w.Header().Set("Content-Type", "application/json")
			io.WriteString(w, `{"status":"ok"}`)
			return
		}
		if r.URL.Path == "/v1/models" {
			must(json.NewEncoder(w).Encode(map[string]any{"data": []any{map[string]any{"id": values["--alias"]}}}))
			return
		}
		assert(r.URL.Path == "/v1/embeddings", "text-only inference endpoint")
		request, err := http.NewRequestWithContext(r.Context(), r.Method, target, r.Body)
		if err != nil {
			return
		}
		request.Header = r.Header.Clone()
		response, err := client.Do(request)
		if err != nil {
			if connection, _, failure := w.(http.Hijacker).Hijack(); failure == nil {
				_ = connection.Close()
			}
			return
		}
		defer response.Body.Close()
		for key, values := range response.Header {
			for _, value := range values {
				w.Header().Add(key, value)
			}
		}
		w.WriteHeader(response.StatusCode)
		io.Copy(w, response.Body)
	})
	server := &http.Server{Handler: handler, ReadHeaderTimeout: time.Second}
	must(server.Serve(listener))
}
