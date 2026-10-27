package pi

import (
	"context"
	"encoding/json"
	"net"
	"sync"
	"testing"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

func bridgeFixture(t *testing.T, ctx context.Context, execute func(context.Context, plugin.ToolCall) (json.RawMessage, error)) (*hostBridge, net.Conn) {
	t.Helper()
	host, native := net.Pipe()
	bridge, err := startBridge(ctx, host, BridgeOptions{
		Injection: plugin.Injection{Tools: &plugin.ToolInjection{Mode: "exclusive", Bindings: []plugin.ToolBinding{{
			Name: "fixture", InputSchema: json.RawMessage(`{"type":"object"}`), Execute: execute,
		}}}},
		CanExecute: func() bool { return true },
	}, nil)
	if err != nil {
		host.Close()
		native.Close()
		t.Fatal(err)
	}
	t.Cleanup(func() { native.Close(); bridge.Close() })
	native.SetDeadline(time.Now().Add(5 * time.Second))
	if err := json.NewEncoder(native).Encode(map[string]any{"type": "ready", "tools": []string{"fixture"}}); err != nil {
		t.Fatal(err)
	}
	if err := bridge.Ready(ctx); err != nil {
		t.Fatal(err)
	}
	return bridge, native
}

func TestHostBridgeCloseDrainsCancellationCleanup(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	started, cancelled, cleanup := make(chan struct{}), make(chan struct{}), make(chan struct{})
	var cleanupOnce sync.Once
	release := func() { cleanupOnce.Do(func() { close(cleanup) }) }
	defer release()
	bridge, native := bridgeFixture(t, ctx, func(ctx context.Context, call plugin.ToolCall) (json.RawMessage, error) {
		close(started)
		<-ctx.Done()
		close(cancelled)
		<-cleanup
		return nil, ctx.Err()
	})
	if err := json.NewEncoder(native).Encode(map[string]any{"type": "call", "id": "request", "callId": "native-call", "name": "fixture", "arguments": map[string]any{}}); err != nil {
		t.Fatal(err)
	}
	select {
	case <-started:
	case <-ctx.Done():
		t.Fatal("tool was not dispatched")
	}
	closed := make(chan error, 2)
	go func() { closed <- bridge.Close() }()
	select {
	case <-cancelled:
	case <-ctx.Done():
		t.Fatal("tool did not receive cancellation")
	}
	go func() { closed <- bridge.Close() }()
	select {
	case err := <-closed:
		t.Fatalf("Close returned before tool cleanup: %v", err)
	case <-time.After(25 * time.Millisecond):
	}
	release()
	for range 2 {
		select {
		case err := <-closed:
			if err != nil {
				t.Fatal(err)
			}
		case <-ctx.Done():
			t.Fatal("Close did not drain the tool")
		}
	}
}

func TestHostBridgeToolPanicIsAnErrorAndDoesNotPoisonConnection(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_, native := bridgeFixture(t, ctx, func(ctx context.Context, call plugin.ToolCall) (json.RawMessage, error) {
		if call.CallID == "panic" {
			panic("private diagnostic")
		}
		return json.RawMessage(`{"ok":true}`), nil
	})
	encoder, decoder := json.NewEncoder(native), json.NewDecoder(native)
	for _, callID := range []string{"panic", "healthy"} {
		if err := encoder.Encode(map[string]any{"type": "call", "id": callID, "callId": callID, "name": "fixture", "arguments": map[string]any{}}); err != nil {
			t.Fatal(err)
		}
		var response struct {
			ID     string          `json:"id"`
			Error  string          `json:"error"`
			Result json.RawMessage `json:"result"`
		}
		if err := decoder.Decode(&response); err != nil {
			t.Fatal(err)
		}
		if response.ID != callID {
			t.Fatalf("wrong response: %+v", response)
		}
		if callID == "panic" && response.Error != "Mokusei tool failed unexpectedly" {
			t.Fatalf("panic did not produce a safe tool error: %+v", response)
		}
		if callID == "healthy" && (response.Error != "" || string(response.Result) != `{"ok":true}`) {
			t.Fatalf("subsequent call failed: %+v", response)
		}
	}
}
