package claude

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

func TestMCPRequestIdentityUsesDecodedString(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	started := make(chan struct{})
	bridge, err := NewToolBridge("fixture", []plugin.ToolBinding{{
		Name: "wait", InputSchema: json.RawMessage(`{"type":"object"}`),
		Execute: func(ctx context.Context, call plugin.ToolCall) (json.RawMessage, error) {
			close(started)
			<-ctx.Done()
			return nil, ctx.Err()
		},
	}})
	if err != nil {
		t.Fatal(err)
	}
	defer bridge.Close()
	if err := bridge.Activate(ctx); err != nil {
		t.Fatal(err)
	}
	in, input := io.Pipe()
	output, out := io.Pipe()
	defer input.Close()
	defer output.Close()
	done := make(chan error, 1)
	go func() {
		done <- ServeMCP(ctx, in, out, MCPOptions{Endpoint: bridge.endpoint, Token: bridge.token})
		out.Close()
	}()
	write := func(frame string) {
		t.Helper()
		if _, err := io.WriteString(input, frame+"\n"); err != nil {
			t.Fatal(err)
		}
	}
	write(`{"jsonrpc":"2.0","id":"\u0061","method":"tools/call","params":{"name":"wait","arguments":{}}}`)
	select {
	case <-started:
	case <-ctx.Done():
		t.Fatal("tool was not dispatched")
	}
	write(`{"jsonrpc":"2.0","id":"a","method":"tools/call","params":{"name":"wait","arguments":{}}}`)
	decoder := json.NewDecoder(output)
	var duplicate struct {
		ID    string `json:"id"`
		Error struct {
			Code int `json:"code"`
		} `json:"error"`
	}
	if err := decoder.Decode(&duplicate); err != nil {
		t.Fatal(err)
	}
	if duplicate.ID != "a" || duplicate.Error.Code != -32600 {
		t.Fatalf("escaped duplicate was not rejected: %+v", duplicate)
	}
	write(`{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"a"}}`)
	var cancelled struct {
		ID    string `json:"id"`
		Error struct {
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := decoder.Decode(&cancelled); err != nil {
		t.Fatal(err)
	}
	if cancelled.ID != "a" || !strings.Contains(cancelled.Error.Message, "cancelled") {
		t.Fatalf("escaped request was not cancelled: %+v", cancelled)
	}
	input.Close()
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}

func TestToolBridgeCloseDrainsCancellationCleanup(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	started, cancelled, cleanup := make(chan struct{}), make(chan struct{}), make(chan struct{})
	var cleanupOnce sync.Once
	release := func() { cleanupOnce.Do(func() { close(cleanup) }) }
	defer release()
	bridge, err := NewToolBridge("fixture", []plugin.ToolBinding{{
		Name: "wait", InputSchema: json.RawMessage(`{"type":"object"}`),
		Execute: func(ctx context.Context, call plugin.ToolCall) (json.RawMessage, error) {
			close(started)
			<-ctx.Done()
			close(cancelled)
			<-cleanup
			return nil, ctx.Err()
		},
	}})
	if err != nil {
		t.Fatal(err)
	}
	defer func() { release(); bridge.Close() }()
	if err := bridge.Activate(ctx); err != nil {
		t.Fatal(err)
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, bridge.endpoint, strings.NewReader(`{"name":"wait","arguments":{},"callId":"cleanup"}`))
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Authorization", "Bearer "+bridge.token)
	responseDone := make(chan struct{})
	go func() {
		defer close(responseDone)
		response, err := http.DefaultClient.Do(request)
		if err == nil {
			response.Body.Close()
		}
	}()
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
	<-responseDone
}
