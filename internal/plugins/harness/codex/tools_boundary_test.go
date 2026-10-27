package codex

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

func bridgeRequest(ctx context.Context, bridge *ToolBridge, body string) ([]byte, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, bridge.endpoint, strings.NewReader(body))
	if err != nil {
		return nil, err
	}
	request.Header.Set("Authorization", "Bearer "+bridge.token)
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	return io.ReadAll(response.Body)
}

const bridgeCall = `{"jsonrpc":"2.0","id":9007199254740993,"method":"tools/call","params":{"name":"fixture","_meta":{"threadId":"thread","callId":"call","x-codex-turn-metadata":{"turn_id":"turn"}},"arguments":{"integer":9007199254740993,"decimal":1.234567890123456789,"nested":[18446744073709551615]}}}`

func TestToolBridgePreservesJSONNumbers(t *testing.T) {
	const payload = `{"integer":9007199254740993,"decimal":1.234567890123456789,"nested":[18446744073709551615]}`
	arguments := make(chan json.RawMessage, 1)
	bridge, err := NewToolBridge([]plugin.ToolBinding{{Name: "fixture", Execute: func(context.Context, plugin.ToolCall) (json.RawMessage, error) { return nil, nil }}}, func(_ context.Context, _, _, _, _ string, args json.RawMessage) (json.RawMessage, error) {
		arguments <- args
		return json.RawMessage(payload), nil
	})
	if err != nil {
		t.Fatal(err)
	}
	defer bridge.Close()
	bridge.Bind("thread")
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	response, err := bridgeRequest(ctx, bridge, bridgeCall)
	if err != nil {
		t.Fatal(err)
	}
	var reply struct {
		ID     json.RawMessage `json:"id"`
		Result struct {
			Structured json.RawMessage         `json:"structuredContent"`
			Content    []struct{ Text string } `json:"content"`
		} `json:"result"`
	}
	if err = json.Unmarshal(response, &reply); err != nil {
		t.Fatal(err)
	}
	var received json.RawMessage
	select {
	case received = <-arguments:
	case <-ctx.Done():
		t.Fatalf("tool did not receive arguments: %s", response)
	}
	for label, data := range map[string][]byte{"arguments": received, "structuredContent": reply.Result.Structured} {
		var value map[string]json.RawMessage
		if err := json.Unmarshal(data, &value); err != nil {
			t.Fatalf("%s: %v; response=%s", label, err, response)
		}
		if string(value["integer"]) != "9007199254740993" || string(value["decimal"]) != "1.234567890123456789" || string(value["nested"]) != "[18446744073709551615]" {
			t.Fatalf("%s lost JSON precision: %s", label, data)
		}
	}
	if string(reply.ID) != "9007199254740993" || len(reply.Result.Content) != 1 || reply.Result.Content[0].Text != payload {
		t.Fatalf("wire identity or result text changed: %s", response)
	}
}

func TestToolBridgeCloseDrainsCancelledExecution(t *testing.T) {
	started, cancelled, release := make(chan struct{}), make(chan struct{}), make(chan struct{})
	var releaseOnce sync.Once
	unblock := func() { releaseOnce.Do(func() { close(release) }) }
	bridge, err := NewToolBridge([]plugin.ToolBinding{{Name: "fixture", Execute: func(context.Context, plugin.ToolCall) (json.RawMessage, error) { return nil, nil }}}, func(ctx context.Context, _, _, _, _ string, _ json.RawMessage) (json.RawMessage, error) {
		close(started)
		<-ctx.Done()
		close(cancelled)
		<-release
		return nil, ctx.Err()
	})
	if err != nil {
		t.Fatal(err)
	}
	defer func() { unblock(); _ = bridge.Close() }()
	bridge.Bind("thread")
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	requestDone := make(chan struct{})
	go func() { defer close(requestDone); _, _ = bridgeRequest(ctx, bridge, bridgeCall) }()
	select {
	case <-started:
	case <-ctx.Done():
		t.Fatal("tool did not start")
	}
	closed := make(chan error, 1)
	go func() { closed <- bridge.Close() }()
	select {
	case <-cancelled:
	case <-ctx.Done():
		t.Fatal("close did not cancel tool")
	}
	select {
	case err := <-closed:
		t.Fatalf("close returned before tool cleanup: %v", err)
	default:
	}
	// Exercise the handler admission barrier even after the listener closes.
	late := httptest.NewRecorder()
	bridge.ServeHTTP(late, httptest.NewRequest(http.MethodPost, "/mcp", strings.NewReader(bridgeCall)))
	if late.Code != http.StatusServiceUnavailable {
		t.Fatalf("closed bridge admitted handler: %d", late.Code)
	}
	unblock()
	select {
	case err := <-closed:
		if err != nil {
			t.Fatal(err)
		}
	case <-ctx.Done():
		t.Fatal("close did not join tool cleanup")
	}
	<-requestDone
}

func TestNativeTerminalDrainsToolsAndRejectsRetiredTurn(t *testing.T) {
	started, cancelled, release := make(chan struct{}), make(chan struct{}), make(chan struct{})
	var releaseOnce sync.Once
	unblock := func() { releaseOnce.Do(func() { close(release) }) }
	defer unblock()
	toolContext, cancel := context.WithCancel(context.Background())
	defer cancel()
	native := &NativeSession{id: "thread", turnID: "turn", completed: make(chan struct{}), toolContext: toolContext, toolCancel: cancel, toolCalls: map[string]bool{}, toolWorkers: &sync.WaitGroup{}, retiredTurns: map[string]bool{"retired": true}}
	native.bridge = &ToolBridge{tools: map[string]plugin.ToolBinding{"fixture": {Execute: func(ctx context.Context, _ plugin.ToolCall) (json.RawMessage, error) {
		close(started)
		<-ctx.Done()
		close(cancelled)
		<-release
		return nil, ctx.Err()
	}}}}
	ctx, stop := context.WithTimeout(context.Background(), 3*time.Second)
	defer stop()
	toolDone := make(chan struct{})
	go func() {
		defer close(toolDone)
		_, _ = native.executeTool(ctx, "thread", "turn", "call", "fixture", json.RawMessage(`{}`))
	}()
	select {
	case <-started:
	case <-ctx.Done():
		t.Fatal("tool did not start")
	}
	go native.finish(Map{"status": "interrupted"})
	select {
	case <-cancelled:
	case <-ctx.Done():
		t.Fatal("terminal did not cancel tool")
	}
	select {
	case <-native.completed:
		t.Fatal("terminal published before tool cleanup")
	default:
	}
	unblock()
	select {
	case <-native.completed:
	case <-ctx.Done():
		t.Fatal("terminal did not join tool cleanup")
	}
	<-toolDone
	// During successor admission the new native turn ID is not yet known;
	// old turn credentials must still be rejected before capability execution.
	native.terminal, native.turnID = false, ""
	if _, err := native.executeTool(ctx, "thread", "retired", "late-call", "fixture", json.RawMessage(`{}`)); err == nil {
		t.Fatal("retired turn entered successor's tool scope")
	}
}

func TestToolBridgeRejectsTrailingJSON(t *testing.T) {
	called := false
	bridge, err := NewToolBridge([]plugin.ToolBinding{{Name: "fixture", Execute: func(context.Context, plugin.ToolCall) (json.RawMessage, error) { return nil, nil }}}, func(context.Context, string, string, string, string, json.RawMessage) (json.RawMessage, error) {
		called = true
		return json.RawMessage(`{}`), nil
	})
	if err != nil {
		t.Fatal(err)
	}
	defer bridge.Close()
	bridge.Bind("thread")
	request := httptest.NewRequest(http.MethodPost, "/mcp", bytes.NewBufferString(bridgeCall+` {}`))
	request.Header.Set("Authorization", "Bearer "+bridge.token)
	response := httptest.NewRecorder()
	bridge.ServeHTTP(response, request)
	if response.Code != http.StatusBadRequest || called {
		t.Fatalf("trailing JSON accepted: status=%d called=%v", response.Code, called)
	}
}
