package opencode

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

func TestCompletionReportsCleanupFailures(t *testing.T) {
	cleanupFailure := errors.New("fixture environment cleanup failed")
	for _, scenario := range []struct {
		name         string
		deleteStatus int
		closeErr     error
	}{
		{"success", http.StatusNoContent, nil},
		{"session-already-deleted", http.StatusNotFound, nil},
		{"session-delete-failed", http.StatusServiceUnavailable, nil},
		{"runtime-close-failed", http.StatusNoContent, cleanupFailure},
	} {
		t.Run(scenario.name, func(t *testing.T) {
			bridge, err := NewBridge(true)
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { _ = bridge.Close(false) })
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				switch {
				case r.URL.Path == "/api/event":
					w.Header().Set("Content-Type", "text/event-stream")
					_, _ = fmt.Fprint(w, "data: {\"type\":\"server.connected\"}\n\n")
					w.(http.Flusher).Flush()
					<-r.Context().Done()
				case r.URL.Path == "/api/rpc/mokusei.harness/refresh":
					bridge.mu.Lock()
					revisions := map[string]int{}
					for id, registration := range bridge.current {
						revisions[id] = registration.revision
					}
					bridge.mu.Unlock()
					_ = json.NewEncoder(w).Encode(Object{"output": Object{"revisions": revisions}})
				case strings.HasSuffix(r.URL.Path, "/export"):
					id := strings.TrimSuffix(strings.TrimPrefix(r.URL.Path, "/api/experimental/session/"), "/export")
					_ = json.NewEncoder(w).Encode(Object{"info": Object{"id": id, "outcome": "succeeded"}, "messages": []any{Object{"type": "assistant", "finish": "stop", "content": []any{Object{"type": "text", "text": "fixture answer"}}}}})
				case r.Method == http.MethodDelete && strings.HasPrefix(r.URL.Path, "/api/session/"):
					w.WriteHeader(scenario.deleteStatus)
				default:
					w.WriteHeader(http.StatusNoContent)
				}
			}))
			t.Cleanup(server.Close)
			life, cancel := context.WithCancel(context.Background())
			runtime := &Runtime{URL: server.URL, ctx: life, cancel: cancel, client: server.Client(), bridge: bridge, ready: make(chan struct{}), streamDone: make(chan struct{}), listeners: map[uint64]listener{}, cleanup: func() error { return scenario.closeErr }}
			t.Cleanup(func() { _ = runtime.Close() })
			directory := ""
			launch := func(_ context.Context, _ Settings, cwd string, isolated bool) (*Runtime, error) {
				directory = cwd
				if !isolated {
					t.Fatal("completion did not request isolated configuration")
				}
				runtime.options.CWD = cwd
				return runtime, nil
			}
			result, err := Complete(context.Background(), plugin.HostContext{TemporaryWorkspaceRoot: t.TempDir()}, launch, plugin.PromptRequest{OutputFormat: plugin.PromptOutputFormat{Type: "text"}})
			if result.Output.Text != "fixture answer" {
				t.Fatalf("completion result = %+v, %v", result, err)
			}
			if scenario.closeErr != nil {
				if !errors.Is(err, scenario.closeErr) {
					t.Fatalf("lost runtime cleanup failure: %v", err)
				}
				if _, statErr := os.Stat(directory); statErr != nil {
					t.Fatalf("failed cleanup discarded its owned workspace: %v", statErr)
				}
			} else {
				if scenario.deleteStatus == http.StatusServiceUnavailable {
					var response *RequestError
					if !errors.As(err, &response) || response.Method != http.MethodDelete || response.Status != scenario.deleteStatus {
						t.Fatalf("lost native session cleanup failure: %v", err)
					}
				} else if err != nil {
					t.Fatal(err)
				}
				if _, statErr := os.Stat(directory); !errors.Is(statErr, os.ErrNotExist) {
					t.Fatalf("successful runtime cleanup retained temporary workspace: %v", statErr)
				}
			}
		})
	}
}
