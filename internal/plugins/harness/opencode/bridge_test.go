package opencode

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

func newToolBridge(t *testing.T, execute func(context.Context, plugin.ToolCall) (json.RawMessage, error)) (*Bridge, int) {
	t.Helper()
	bridge, err := NewBridge(false)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = bridge.Close(false) })
	revision, err := bridge.Configure("ses_root", BridgeConfiguration{Injection: &plugin.Injection{Tools: &plugin.ToolInjection{Mode: "extend", Bindings: []plugin.ToolBinding{{
		Name:        "create_thread",
		InputSchema: json.RawMessage(`{"type":"object"}`),
		Execute:     execute,
	}}}}})
	if err != nil {
		t.Fatal(err)
	}
	return bridge, revision
}

func callBridgeTool(t *testing.T, bridge *Bridge, revision int) (int, string) {
	t.Helper()
	body, err := json.Marshal(Object{"rootSessionID": "ses_root", "sessionID": "ses_root", "revision": revision, "name": "create_thread", "callId": "call_1", "arguments": Object{}})
	if err != nil {
		t.Fatal(err)
	}
	request, err := http.NewRequest(http.MethodPost, "http://"+bridge.listener.Addr().String()+"/tool", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Authorization", "Bearer "+bridge.token)
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	data, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatal(err)
	}
	return response.StatusCode, string(data)
}

// A rejected native model selection must reach the native caller as a client error
// that still names the omission, not as an opaque 500.
func TestBridgeReportsCallerToolErrorsVerbatim(t *testing.T) {
	message := `create_thread options.model "missing" is unavailable; choose a model from describe_native_harness and retry`
	bridge, revision := newToolBridge(t, func(context.Context, plugin.ToolCall) (json.RawMessage, error) {
		return nil, plugin.CallerError(errors.New(message))
	})
	status, body := callBridgeTool(t, bridge, revision)
	if status != http.StatusUnprocessableEntity {
		t.Fatalf("caller tool failure status = %d, want %d (%s)", status, http.StatusUnprocessableEntity, body)
	}
	for _, want := range []string{"options.model", "missing", "describe_native_harness"} {
		if !strings.Contains(body, want) {
			t.Fatalf("bridge response dropped %q: %s", want, body)
		}
	}
	if strings.Contains(body, "Mokusei bridge operation failed") {
		t.Fatalf("bridge replaced the real cause: %s", body)
	}
}

// Internal faults keep the internal status but still carry the real cause.
func TestBridgeReportsInternalToolErrorsWithCause(t *testing.T) {
	bridge, revision := newToolBridge(t, func(context.Context, plugin.ToolCall) (json.RawMessage, error) {
		return nil, errors.New("Moku configuration persistence unavailable")
	})
	status, body := callBridgeTool(t, bridge, revision)
	if status != http.StatusInternalServerError {
		t.Fatalf("internal tool failure status = %d, want %d (%s)", status, http.StatusInternalServerError, body)
	}
	if !strings.Contains(body, "Moku configuration persistence unavailable") {
		t.Fatalf("bridge response dropped the cause: %s", body)
	}
}

// A valid native model selection remains a successful tool result.
func TestBridgeReturnsToolResult(t *testing.T) {
	bridge, revision := newToolBridge(t, func(context.Context, plugin.ToolCall) (json.RawMessage, error) {
		return json.RawMessage(`{"ok":true,"threadId":"thread_1"}`), nil
	})
	status, body := callBridgeTool(t, bridge, revision)
	if status != http.StatusOK {
		t.Fatalf("tool result status = %d, want %d (%s)", status, http.StatusOK, body)
	}
	if !strings.Contains(body, `"threadId":"thread_1"`) {
		t.Fatalf("tool result was not forwarded: %s", body)
	}
}

func requestBridge(ctx context.Context, bridge *Bridge, path string, value Object) (int, []byte, error) {
	body, err := json.Marshal(value)
	if err != nil {
		return 0, nil, err
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, "http://"+bridge.listener.Addr().String()+path, bytes.NewReader(body))
	if err != nil {
		return 0, nil, err
	}
	request.Header.Set("Authorization", "Bearer "+bridge.token)
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		return 0, nil, err
	}
	defer response.Body.Close()
	data, err := io.ReadAll(response.Body)
	return response.StatusCode, data, err
}

func TestBridgeCloseDrainsCallbacksBeforeRemovingFiles(t *testing.T) {
	for _, path := range []string{"/tool", "/before-model"} {
		t.Run(path, func(t *testing.T) {
			bridge, err := NewBridge(false)
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { _ = bridge.Close(false) })
			entered, canceled, finished := make(chan struct{}), make(chan struct{}), make(chan struct{})
			release := make(chan struct{})
			var releaseOnce sync.Once
			finish := func() { releaseOnce.Do(func() { close(release) }) }
			t.Cleanup(finish)
			callback := func(ctx context.Context) error {
				close(entered)
				<-ctx.Done()
				close(canceled)
				<-release
				close(finished)
				return ctx.Err()
			}
			config := BridgeConfiguration{BeforeModel: func(ctx context.Context, _ ModelRequest) error { return callback(ctx) }}
			config.Injection = &plugin.Injection{Tools: &plugin.ToolInjection{Mode: "extend", Bindings: []plugin.ToolBinding{{
				Name: "fixture", InputSchema: json.RawMessage(`{"type":"object"}`),
				Execute: func(ctx context.Context, _ plugin.ToolCall) (json.RawMessage, error) { return nil, callback(ctx) },
			}}}}
			revision, err := bridge.Configure("ses_root", config)
			if err != nil {
				t.Fatal(err)
			}
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			requestDone := make(chan struct{})
			go func() {
				defer close(requestDone)
				_, _, _ = requestBridge(ctx, bridge, path, Object{"rootSessionID": "ses_root", "sessionID": "ses_root", "revision": revision,
					"name": "fixture", "callId": "call_1", "arguments": Object{}, "kind": "primary", "model": Object{"providerID": "fixture", "id": "model"}})
			}()
			select {
			case <-entered:
			case <-ctx.Done():
				t.Fatal("bridge callback did not start")
			}
			closed := make(chan error, 1)
			go func() { closed <- bridge.Close(false) }()
			select {
			case <-canceled:
			case <-ctx.Done():
				t.Fatal("Close did not cancel the bridge callback")
			}
			select {
			case err := <-closed:
				t.Fatalf("Close returned before callback cleanup: %v", err)
			case <-time.After(50 * time.Millisecond):
			}
			if _, err := os.Stat(bridge.Directory); err != nil {
				t.Fatalf("bridge files removed before callback cleanup: %v", err)
			}
			finish()
			select {
			case err := <-closed:
				if err != nil {
					t.Fatal(err)
				}
			case <-ctx.Done():
				t.Fatal("Close did not finish after callback cleanup")
			}
			select {
			case <-finished:
			default:
				t.Fatal("Close returned before callback finished")
			}
			if _, err := os.Stat(bridge.Directory); !errors.Is(err, os.ErrNotExist) {
				t.Fatalf("bridge files remain after Close: %v", err)
			}
			select {
			case <-requestDone:
			case <-ctx.Done():
				t.Fatal("HTTP request did not finish after Close")
			}
		})
	}
}

func TestBridgeRejectsInvalidConfigurationWithoutPublishing(t *testing.T) {
	for _, test := range []struct {
		name   string
		change func(*BridgeConfiguration)
	}{
		{"tool output schema", func(c *BridgeConfiguration) { c.Injection.Tools.Bindings[0].OutputSchema = json.RawMessage(`{`) }},
		{"structured output schema", func(c *BridgeConfiguration) { c.OutputSchema = Object{"type": func() {}} }},
		{"model options", func(c *BridgeConfiguration) { c.ModelOptions = Object{"fixture": func() {}} }},
		{"read prefix", func(c *BridgeConfiguration) { c.ReadPrefix = Object{"system": func() {}} }},
		{"seed arguments", func(c *BridgeConfiguration) {
			c.Injection.Seed = []plugin.SeedItem{{Type: "tool-call", Name: "fixture", CallID: "seed", Arguments: json.RawMessage(`{`)}}
		}},
	} {
		t.Run(test.name, func(t *testing.T) {
			bridge, revision := newToolBridge(t, func(context.Context, plugin.ToolCall) (json.RawMessage, error) {
				return json.RawMessage(`{"ok":true}`), nil
			})
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			status, before, err := requestBridge(ctx, bridge, "/configuration", Object{})
			if err != nil || status != http.StatusOK {
				t.Fatalf("read initial configuration: %d %s %v", status, before, err)
			}
			config := BridgeConfiguration{Injection: &plugin.Injection{Tools: &plugin.ToolInjection{Mode: "extend", Bindings: []plugin.ToolBinding{{
				Name: "fixture", InputSchema: json.RawMessage(`{"type":"object"}`),
				Execute: func(context.Context, plugin.ToolCall) (json.RawMessage, error) { return json.RawMessage(`{}`), nil },
			}}}}}
			test.change(&config)
			if _, err := bridge.Configure("ses_root", config); err == nil {
				t.Fatal("invalid configuration was accepted")
			}
			status, after, err := requestBridge(ctx, bridge, "/configuration", Object{})
			if err != nil || status != http.StatusOK || !bytes.Equal(before, after) {
				t.Fatalf("failed Configure changed the published configuration: %d %s %v; before %s", status, after, err, before)
			}
			if status, body := callBridgeTool(t, bridge, revision); status != http.StatusOK {
				t.Fatalf("previous binding was revoked: %d %s", status, body)
			}
			if next, err := bridge.Configure("ses_root", BridgeConfiguration{}); err != nil || next != revision+1 {
				t.Fatalf("failed Configure consumed a revision: %d %v", next, err)
			}
		})
	}
}

func TestBridgeConfigurationOwnsPublishedData(t *testing.T) {
	bridge, err := NewBridge(true)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = bridge.Close(false) })
	input := json.RawMessage(`{"type":"object"}`)
	output := Object{"type": "object"}
	options := Object{"mokuseiStructuredOutput": "openai-chat-json-schema", "fixture": Object{"original": true}, "exact": json.Number("9007199254740993")}
	prefix := Object{"system": []any{"original"}}
	revision, err := bridge.Configure("ses_root", BridgeConfiguration{OutputSchema: output, ModelOptions: options, ReadPrefix: prefix,
		Injection: &plugin.Injection{Tools: &plugin.ToolInjection{Mode: "exclusive", Bindings: []plugin.ToolBinding{{
			Name: "fixture", InputSchema: input,
			Execute: func(context.Context, plugin.ToolCall) (json.RawMessage, error) { return json.RawMessage(`{}`), nil },
		}}}}})
	if err != nil {
		t.Fatal(err)
	}
	input[0] = '!'
	output["type"] = func() {}
	options["mokuseiStructuredOutput"] = "changed"
	options["fixture"].(Object)["original"] = false
	prefix["system"].([]any)[0] = "changed"
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	status, body, err := requestBridge(ctx, bridge, "/configuration", Object{})
	if err != nil || status != http.StatusOK || !json.Valid(body) {
		t.Fatalf("published snapshot became invalid: %d %s %v", status, body, err)
	}
	if !strings.Contains(string(body), `"exact":9007199254740993`) {
		t.Fatalf("configuration snapshot rounded an exact number: %s", body)
	}
	var configuration struct {
		Sessions []Object `json:"sessions"`
	}
	if err := json.Unmarshal(body, &configuration); err != nil || len(configuration.Sessions) != 1 {
		t.Fatalf("decode configuration: %s %v", body, err)
	}
	observed := configuration.Sessions[0]
	if object(object(observed["modelOptions"])["fixture"])["original"] != true || array(object(observed["readPrefix"])["system"])[0] != "original" {
		t.Fatalf("Configure retained caller-owned data: %s", body)
	}
	request := Object{"rootSessionID": "ses_root", "sessionID": "ses_root", "revision": revision, "name": "fixture", "path": "/v1/chat/completions"}
	status, body, err = requestBridge(ctx, bridge, "/http-request", request)
	if err != nil || status != http.StatusOK || !strings.Contains(string(body), `"schema":{"type":"object"}`) {
		t.Fatalf("structured output snapshot changed: %d %s %v", status, body, err)
	}
	status, body, err = requestBridge(ctx, bridge, "/before-tool", request)
	if err != nil || status != http.StatusOK {
		t.Fatalf("exclusive snapshot lost its allowed tool: %d %s %v", status, body, err)
	}
	request["name"] = "ambient"
	status, body, err = requestBridge(ctx, bridge, "/before-tool", request)
	if err != nil || status != http.StatusForbidden {
		t.Fatalf("exclusive snapshot admitted an ambient tool: %d %s %v", status, body, err)
	}
}
