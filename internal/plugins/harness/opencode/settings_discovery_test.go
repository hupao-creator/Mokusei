package opencode

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

// The production catalog reaches its native boundary while an account RPC is
// held. Selection validation must continue waiting; the editor must not.
func TestSettingsPresentationDoesNotWaitForAccount(t *testing.T) {
	leaseStarted, releaseLease := make(chan struct{}), make(chan struct{})
	var releaseOnce, startedOnce sync.Once
	release := func() { releaseOnce.Do(func() { close(releaseLease) }) }
	defer release()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var value any
		switch r.URL.Path {
		case "/api/model":
			value = []Object{{"id": "paid", "providerID": "opencode", "name": "Native paid model", "enabled": true,
				"package": "@opencode/ai/providers/openai-compatible", "variants": []any{},
				"capabilities": Object{"tools": true, "input": []string{"text"}},
				"cost":         []Object{{"input": 1, "output": 1, "cache": Object{"read": 0, "write": 0}}}}}
		case "/api/agent":
			value = []Object{{"id": "primary", "name": "Primary", "mode": "primary"}}
		case "/api/provider":
			value = []Object{{"id": "opencode"}}
		case "/api/model/default":
			value = nil
		case "/api/config":
			value = []any{}
		case "/api/rpc/mokusei.harness/credential":
			value = Object{"output": Object{"baseUrl": "https://opencode.ai/zen/v1", "apiKey": "public"}}
		case "/api/rpc/mokusei.harness/consoleAccount":
			startedOnce.Do(func() { close(leaseStarted) })
			select {
			case <-releaseLease:
			case <-r.Context().Done():
				return
			}
			value = Object{"output": Object{}}
		default:
			t.Errorf("unexpected native request %s", r.URL.Path)
			http.NotFound(w, r)
			return
		}
		_ = json.NewEncoder(w).Encode(value)
	}))
	defer server.Close()
	var starts atomic.Int32
	home := t.TempDir()
	api := NewSettings(plugin.HostContext{Environment: func(context.Context) (map[string]string, error) { return map[string]string{"HOME": home}, nil }}, nil)
	api.launch = func(ctx context.Context, _ Settings, cwd string) (*Runtime, error) {
		starts.Add(1)
		life, cancel := context.WithCancel(ctx)
		return &Runtime{URL: server.URL, ExecutablePath: "fixture", Version: "2.0.25", ctx: life, cancel: cancel, client: server.Client(), options: Options{CWD: cwd}}, nil
	}
	defer api.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	started := time.Now()
	raw, err := api.Presentation(ctx, plugin.SettingsPresentationRequest{Settings: json.RawMessage(`{"threadSettings":{}}`), Cwd: home})
	if err != nil {
		t.Fatal(err)
	}
	earlyElapsed := time.Since(started)
	var presentation struct {
		Models              []CatalogModel
		AccountCheckPending bool
	}
	if err := json.Unmarshal(raw, &presentation); err != nil {
		t.Fatal(err)
	}
	if len(presentation.Models) != 1 || !presentation.AccountCheckPending {
		t.Fatalf("native partial result missing: %s", raw)
	}
	select {
	case <-leaseStarted:
	case <-ctx.Done():
		t.Fatal("account phase did not start")
	}
	full := make(chan *CatalogSnapshot, 1)
	go func() { value, _ := api.observe(ctx, Settings{}, home, false); full <- value }()
	select {
	case <-full:
		t.Fatal("validation accepted partial account facts")
	case <-time.After(30 * time.Millisecond):
	}
	t.Logf("native presentation returned in %s while account RPC remained held", earlyElapsed)
	release()
	value := <-full
	if value == nil || len(value.Models) != 0 || len(value.ExcludedModels) != 1 {
		t.Fatal("complete catalog did not enforce native credential policy")
	}
	if len(presentation.Models) != 1 {
		t.Fatal("billing mutated published native projection")
	}
	if starts.Load() != 1 {
		t.Fatalf("presentation and validation launched %d runtimes", starts.Load())
	}
}
