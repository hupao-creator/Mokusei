package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"strconv"
	"sync"
	"time"

	"github.com/hupao-creator/Mokusei/internal/platform/profile"
)

// Forward production responses unchanged except for explicitly injected read
// failures. Counting at HTTP ingress proves client coalescing, independently of
// the native Harness's own cache. Streaming still uses the real daemon.
func prefetchProxy(connection *profile.Connection) (string, func(), error) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return "", nil, err
	}
	target := &url.URL{Scheme: "http", Host: net.JoinHostPort("127.0.0.1", strconv.Itoa(connection.Port))}
	proxy := httputil.NewSingleHostReverseProxy(target)
	proxy.FlushInterval = -1
	var mu sync.Mutex
	counts := map[string]int{}
	failures := 1
	snapshotFailures := 1
	offline := false
	installationChanged := false
	streams := map[*http.Request]context.CancelFunc{}
	proxy.ModifyResponse = func(response *http.Response) error {
		mu.Lock()
		changed := installationChanged
		snapshotFailure := response.Request.Context().Value(prefetchScopeKey{}) == "codex:moku" && snapshotFailures > 0
		if snapshotFailure {
			snapshotFailures--
		}
		mu.Unlock()
		if snapshotFailure || (changed && (response.Request.URL.Path == "/invoke/harness:detect-installations" || response.Request.URL.Path == "/invoke/harness:detect-installation")) {
			var result map[string]any
			if err := json.NewDecoder(response.Body).Decode(&result); err != nil {
				return err
			}
			_ = response.Body.Close()
			if value, ok := result["value"].(map[string]any); ok {
				if snapshotFailure {
					value["executionSnapshotError"] = "Injected execution snapshot failure"
				}
				if changed && response.Request.URL.Path == "/invoke/harness:detect-installation" {
					value["executablePath"] = "fixture-replaced-codex"
				}
				if codex, ok := value["codex"].(map[string]any); ok && changed {
					codex["executablePath"] = "fixture-replaced-codex"
				}
			}
			raw, err := json.Marshal(result)
			if err != nil {
				return err
			}
			response.Body = io.NopCloser(bytes.NewReader(raw))
			response.ContentLength = int64(len(raw))
			response.Header.Set("Content-Length", strconv.Itoa(len(raw)))
		}
		return nil
	}
	server := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/_prefetch" {
			mu.Lock()
			defer mu.Unlock()
			if r.Method == http.MethodPost {
				var control struct {
					Failures            int   `json:"failures"`
					Offline             *bool `json:"offline"`
					InstallationChanged *bool `json:"installationChanged"`
				}
				if err := json.NewDecoder(r.Body).Decode(&control); err != nil {
					http.Error(w, err.Error(), 400)
					return
				}
				failures = control.Failures
				counts = map[string]int{}
				if control.InstallationChanged != nil {
					installationChanged = *control.InstallationChanged
				}
				if control.Offline != nil {
					offline = *control.Offline
					if offline {
						for _, cancel := range streams {
							cancel()
						}
					}
				}
			}
			_ = json.NewEncoder(w).Encode(counts)
			return
		}
		mu.Lock()
		unavailable := offline
		mu.Unlock()
		if unavailable {
			http.Error(w, "fixture disconnected", http.StatusServiceUnavailable)
			return
		}
		streamContext, cancel := context.WithCancel(r.Context())
		defer cancel()
		mu.Lock()
		streams[r] = cancel
		mu.Unlock()
		defer func() { mu.Lock(); delete(streams, r); mu.Unlock() }()
		if r.URL.Path == "/invoke/harness:settings-presentation" {
			raw, err := io.ReadAll(io.LimitReader(r.Body, 1024*1024))
			if err != nil {
				http.Error(w, err.Error(), 400)
				return
			}
			r.Body = io.NopCloser(bytes.NewReader(raw))
			var command struct {
				Args []struct {
					Scope       string `json:"scope"`
					HarnessID   string `json:"harnessId"`
					Application string `json:"applicationSettings"`
					Owner       string `json:"executionOwner"`
				} `json:"args"`
			}
			if json.Unmarshal(raw, &command) == nil && len(command.Args) == 1 && command.Args[0].Scope == "global" {
				request := command.Args[0]
				key := request.HarnessID + ":global"
				if request.Owner != "" {
					key = request.HarnessID + ":" + request.Owner
				}
				if request.Application != "" {
					key = request.HarnessID + ":" + request.Application
				}
				streamContext = context.WithValue(streamContext, prefetchScopeKey{}, key)
				mu.Lock()
				counts[key]++
				fail := key == "codex:global" && failures > 0
				if fail {
					failures--
				}
				mu.Unlock()
				if fail {
					_ = json.NewEncoder(w).Encode(map[string]any{"ok": false, "error": map[string]any{"code": "PREFETCH_FIXTURE", "message": "Injected settings read failure"}})
					return
				}
				select {
				case <-time.After(150 * time.Millisecond):
				case <-r.Context().Done():
					return
				}
			}
		}
		proxy.ServeHTTP(w, r.WithContext(streamContext))
	})}
	go func() { _ = server.Serve(listener) }()
	return "http://" + listener.Addr().String(), func() { _ = server.Close() }, nil
}

type prefetchScopeKey struct{}
