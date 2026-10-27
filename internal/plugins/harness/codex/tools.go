package codex

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"io"
	"net"
	"net/http"
	"sync"
	"time"
)

type ToolBridge struct {
	mu                        sync.Mutex
	server                    *http.Server
	endpoint, token, threadID string
	tools                     map[string]plugin.ToolBinding
	order                     []string
	pending                   map[string]context.CancelFunc
	call                      func(context.Context, string, string, string, string, json.RawMessage) (json.RawMessage, error)
	ctx                       context.Context
	cancel                    context.CancelFunc
	closed                    bool
	workers                   sync.WaitGroup
	closeOnce                 sync.Once
	closeErr                  error
}

func NewToolBridge(bindings []plugin.ToolBinding, call func(context.Context, string, string, string, string, json.RawMessage) (json.RawMessage, error)) (*ToolBridge, error) {
	b := make([]byte, 32)
	if _, e := rand.Read(b); e != nil {
		return nil, e
	}
	ctx, cancel := context.WithCancel(context.Background())
	t := &ToolBridge{token: base64.RawURLEncoding.EncodeToString(b), tools: map[string]plugin.ToolBinding{}, pending: map[string]context.CancelFunc{}, call: call, ctx: ctx, cancel: cancel}
	for _, tool := range bindings {
		if tool.Name == "" || tool.Execute == nil || t.tools[tool.Name].Execute != nil {
			cancel()
			return nil, errors.New("invalid or duplicate injected Codex tool")
		}
		t.tools[tool.Name] = tool
		t.order = append(t.order, tool.Name)
	}
	l, e := net.Listen("tcp", "127.0.0.1:0")
	if e != nil {
		cancel()
		return nil, e
	}
	t.endpoint = "http://" + l.Addr().String() + "/mcp"
	t.server = &http.Server{Handler: t, ReadHeaderTimeout: 10 * time.Second, MaxHeaderBytes: 32 * 1024, BaseContext: func(net.Listener) context.Context { return ctx }}
	go func() { _ = t.server.Serve(l) }()
	return t, nil
}
func (t *ToolBridge) Bind(id string) { t.mu.Lock(); t.threadID = id; t.mu.Unlock() }
func (t *ToolBridge) Configuration() Map {
	max := 64 * 1024
	for _, tool := range t.tools {
		if len(tool.InputSchema)*8 > max {
			max = len(tool.InputSchema) * 8
		}
	}
	return Map{"url": t.endpoint, "http_headers": Map{"Authorization": "Bearer " + t.token}, "enabled": true, "required": true, "startup_timeout_sec": 15, "tool_timeout_sec": 86400, "tool_input_schema_max_bytes": max, "enabled_tools": t.order, "default_tools_approval_mode": "approve"}
}
func (t *ToolBridge) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	t.mu.Lock()
	if t.closed {
		t.mu.Unlock()
		http.Error(w, "Codex tool session closed", http.StatusServiceUnavailable)
		return
	}
	t.workers.Add(1)
	t.mu.Unlock()
	defer t.workers.Done()
	w.Header().Set("Content-Type", "application/json")
	reply := func(status int, v any) { w.WriteHeader(status); _ = json.NewEncoder(w).Encode(v) }
	if r.URL.Path != "/mcp" {
		reply(404, Map{})
		return
	}
	if subtle.ConstantTimeCompare([]byte(r.Header.Get("Authorization")), []byte("Bearer "+t.token)) != 1 {
		reply(401, Map{})
		return
	}
	if r.Method != "POST" {
		reply(405, Map{})
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 8*1024*1024)
	var m Map
	decoder := json.NewDecoder(r.Body)
	// Tool arguments and MCP request IDs must survive the bridge without a
	// float64 round trip, including integers outside JavaScript's safe range.
	decoder.UseNumber()
	if decoder.Decode(&m) != nil || m["jsonrpc"] != "2.0" || decoder.Decode(new(any)) != io.EOF {
		reply(400, Map{"error": "Invalid MCP JSON-RPC request"})
		return
	}
	p := obj(m["params"])
	id := m["id"]
	key := wireKey(id)
	if id != nil && key == "" {
		reply(400, Map{"error": "Invalid MCP request ID"})
		return
	}
	if id == nil {
		if m["method"] == "notifications/cancelled" {
			t.mu.Lock()
			cancel := t.pending[wireKey(p["requestId"])]
			t.mu.Unlock()
			if cancel != nil {
				cancel()
			}
		}
		w.WriteHeader(202)
		return
	}
	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()
	t.mu.Lock()
	if t.pending[key] != nil {
		t.mu.Unlock()
		reply(200, Map{"jsonrpc": "2.0", "id": id, "error": Map{"code": -32600, "message": "Duplicate MCP request ID"}})
		return
	}
	t.pending[key] = cancel
	thread := t.threadID
	t.mu.Unlock()
	defer func() { t.mu.Lock(); delete(t.pending, key); t.mu.Unlock() }()
	result := Map{}
	var err error
	switch str(m["method"]) {
	case "initialize":
		result = Map{"protocolVersion": first(str(p["protocolVersion"]), "2025-06-18"), "capabilities": Map{"tools": Map{"listChanged": false}}, "serverInfo": Map{"name": "mokusei_injected", "version": "1.0.0"}}
	case "ping":
	case "tools/list":
		defs := []any{}
		for _, name := range t.order {
			tool := t.tools[name]
			def := Map{"name": name, "description": tool.Description, "inputSchema": json.RawMessage(tool.InputSchema)}
			if len(tool.OutputSchema) > 0 {
				def["outputSchema"] = json.RawMessage(tool.OutputSchema)
			}
			defs = append(defs, def)
		}
		result["tools"] = defs
	case "resources/list":
		result["resources"] = []any{}
	case "resources/templates/list":
		result["resourceTemplates"] = []any{}
	case "tools/call":
		meta := obj(p["_meta"])
		name := str(p["name"])
		turn := str(obj(meta["x-codex-turn-metadata"])["turn_id"])
		callID := str(meta["callId"])
		if thread == "" || thread != str(meta["threadId"]) || turn == "" || callID == "" || t.tools[name].Execute == nil {
			err = errors.New("Codex MCP call does not belong to this injected tool session")
			break
		}
		arguments, _ := json.Marshal(p["arguments"])
		value, e := t.call(ctx, thread, turn, callID, name, arguments)
		if e != nil {
			result = Map{"isError": true, "content": []any{Map{"type": "text", "text": e.Error()}}}
		} else {
			var v any
			decoder := json.NewDecoder(bytes.NewReader(value))
			decoder.UseNumber()
			if decoder.Decode(&v) != nil || decoder.Decode(new(any)) != io.EOF {
				err = errors.New("Codex tool returned invalid JSON")
				break
			}
			text := string(value)
			if s, ok := v.(string); ok {
				text = s
			}
			result["content"] = []any{Map{"type": "text", "text": text}}
			if object, ok := v.(map[string]any); ok {
				result["structuredContent"] = object
			}
		}
	default:
		reply(200, Map{"jsonrpc": "2.0", "id": id, "error": Map{"code": -32601, "message": "Method not found"}})
		return
	}
	if err != nil {
		reply(200, Map{"jsonrpc": "2.0", "id": id, "error": Map{"code": -32602, "message": err.Error()}})
		return
	}
	reply(200, Map{"jsonrpc": "2.0", "id": id, "result": result})
}
func (t *ToolBridge) Close() error {
	t.closeOnce.Do(func() {
		t.mu.Lock()
		t.closed = true
		t.mu.Unlock()
		t.cancel()
		t.closeErr = t.server.Close()
		// Server.Close tears down connections but does not join handlers. Keep
		// the capability owner alive until cancelled tool cleanup has returned.
		t.workers.Wait()
	})
	return t.closeErr
}
func (n *NativeSession) executeTool(ctx context.Context, thread, turn, callID, name string, args json.RawMessage) (json.RawMessage, error) {
	n.mu.Lock()
	valid := !n.closed && !n.terminal && !n.retiredTurns[turn] && n.id == thread && (n.turnID == turn || n.turnID == "")
	bridge := n.bridge
	turnContext := n.toolContext
	workers := n.toolWorkers
	if n.toolCalls[callID] {
		n.mu.Unlock()
		return nil, errors.New("Codex repeated an injected tool call ID")
	}
	if valid {
		n.toolCalls[callID] = true
		workers.Add(1)
	}
	n.mu.Unlock()
	if valid {
		defer workers.Done()
	}
	if !valid || bridge == nil {
		return nil, errors.New("injected Codex tool turn is not active")
	}
	tool, ok := bridge.tools[name]
	if !ok {
		return nil, fmt.Errorf("unknown injected tool %s", name)
	}
	combined, cancel := context.WithCancel(ctx)
	defer cancel()
	if turnContext != nil {
		stop := context.AfterFunc(turnContext, cancel)
		defer stop()
		if err := turnContext.Err(); err != nil {
			return nil, err
		}
	}
	if err := combined.Err(); err != nil {
		return nil, err
	}
	return tool.Execute(combined, plugin.ToolCall{CallID: callID, Arguments: args})
}
