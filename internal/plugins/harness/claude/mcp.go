package claude

import (
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

const maxToolMessageBytes = 8 * 1024 * 1024
const toolServerName = "mokusei"

type ToolDefinition struct {
	Name         string          `json:"name"`
	Description  string          `json:"description"`
	InputSchema  json.RawMessage `json:"inputSchema"`
	OutputSchema json.RawMessage `json:"outputSchema,omitempty"`
}

// ToolBridge keeps Go-owned tools in the runtime process. Claude starts the
// same Go executable in claude-mcp mode and forwards calls over authenticated
// loopback HTTP. No generated executable script or definitions file is needed.
type ToolBridge struct {
	mu           sync.Mutex
	executable   string
	endpoint     string
	token        string
	definitions  []ToolDefinition
	tools        map[string]plugin.ToolBinding
	server       *http.Server
	listener     net.Listener
	active       context.Context
	activeCancel context.CancelFunc
	closed       bool
	workers      sync.WaitGroup
	closeOnce    sync.Once
	closeError   error
}

func NewToolBridge(executable string, tools []plugin.ToolBinding) (*ToolBridge, error) {
	if executable == "" {
		var err error
		executable, err = os.Executable()
		if err != nil {
			return nil, err
		}
	}
	secret := make([]byte, 32)
	if _, err := rand.Read(secret); err != nil {
		return nil, err
	}
	bridge := &ToolBridge{executable: executable, token: base64.RawURLEncoding.EncodeToString(secret), tools: map[string]plugin.ToolBinding{}, definitions: []ToolDefinition{}}
	for _, tool := range tools {
		if tool.Name == "" || tool.Execute == nil {
			return nil, errors.New("Claude tool requires a name and executor")
		}
		if _, exists := bridge.tools[tool.Name]; exists {
			return nil, fmt.Errorf("duplicate Claude tool: %s", tool.Name)
		}
		schema, err := ToolSchema(tool.InputSchema)
		if err != nil {
			return nil, fmt.Errorf("invalid Claude input schema for %s: %w", tool.Name, err)
		}
		if len(tool.OutputSchema) != 0 {
			if _, err := model.DecodeObject(tool.OutputSchema); err != nil {
				return nil, fmt.Errorf("invalid Claude output schema for %s: %w", tool.Name, err)
			}
		}
		bridge.tools[tool.Name] = tool
		bridge.definitions = append(bridge.definitions, ToolDefinition{Name: tool.Name, Description: tool.Description, InputSchema: schema, OutputSchema: bytes.Clone(tool.OutputSchema)})
	}
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return nil, err
	}
	bridge.listener = listener
	bridge.endpoint = "http://" + listener.Addr().String() + "/tool-call"
	bridge.server = &http.Server{Handler: http.HandlerFunc(bridge.handleRequest), ReadHeaderTimeout: 5 * time.Second, IdleTimeout: 30 * time.Second, MaxHeaderBytes: 16 * 1024}
	go func() { _ = bridge.server.Serve(listener) }()
	return bridge, nil
}

// Activate replaces the execution lifetime. An in-flight call from the prior
// execution keeps its original context and cannot dispatch into the new one.
func (b *ToolBridge) Activate(ctx context.Context) error {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.closed {
		return errors.New("Claude tool bridge is closed")
	}
	if b.activeCancel != nil {
		b.activeCancel()
	}
	b.active, b.activeCancel = context.WithCancel(ctx)
	return ctx.Err()
}

func (b *ToolBridge) Deactivate() {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.activeCancel != nil {
		b.activeCancel()
	}
	b.active, b.activeCancel = nil, nil
}

func (b *ToolBridge) Configuration() map[string]any {
	return map[string]any{"mcpServers": map[string]any{toolServerName: map[string]any{
		"type": "stdio", "command": b.executable, "args": []string{"claude-mcp"}, "alwaysLoad": true,
		"env": map[string]string{"MOKUSEI_TOOL_BRIDGE_URL": b.endpoint, "MOKUSEI_TOOL_BRIDGE_TOKEN": b.token, "MOKUSEI_TOOL_SERVER_NAME": toolServerName},
	}}}
}

func (b *ToolBridge) CanonicalToolName(name string) string {
	prefix := "mcp__" + toolServerName + "__"
	if strings.HasPrefix(name, prefix) {
		canonical := strings.TrimPrefix(name, prefix)
		if _, exists := b.tools[canonical]; exists {
			return canonical
		}
	}
	return name
}

func (b *ToolBridge) Close() error {
	b.closeOnce.Do(func() {
		b.mu.Lock()
		b.closed = true
		if b.activeCancel != nil {
			b.activeCancel()
		}
		b.active, b.activeCancel = nil, nil
		b.mu.Unlock()
		// Closing HTTP interrupts incomplete bodies and response writes. Tool
		// callbacks still own resources until their cancellation cleanup returns.
		b.closeError = b.server.Close()
		b.workers.Wait()
	})
	return b.closeError
}

func (b *ToolBridge) handleRequest(w http.ResponseWriter, request *http.Request) {
	if subtle.ConstantTimeCompare([]byte(request.Header.Get("Authorization")), []byte("Bearer "+b.token)) != 1 {
		bridgeJSON(w, http.StatusUnauthorized, map[string]any{"error": "Invalid Claude tool bridge token"})
		return
	}
	if request.Method == http.MethodGet && request.URL.Path == "/tools" {
		bridgeJSON(w, http.StatusOK, map[string]any{"tools": b.definitions})
		return
	}
	if request.Method != http.MethodPost || request.URL.Path != "/tool-call" {
		bridgeJSON(w, http.StatusNotFound, map[string]any{"error": "Not found"})
		return
	}
	b.mu.Lock()
	execution := b.active
	closed := b.closed
	b.mu.Unlock()
	if closed || execution == nil || execution.Err() != nil {
		bridgeJSON(w, http.StatusConflict, map[string]any{"error": "Claude execution is not active"})
		return
	}
	ctx, cancel := context.WithCancel(request.Context())
	defer cancel()
	stop := context.AfterFunc(execution, cancel)
	defer stop()
	// Cancellation has to interrupt a stalled body before any tool is invoked.
	request.Body = http.MaxBytesReader(w, request.Body, maxToolMessageBytes)
	stopRead := context.AfterFunc(ctx, func() {
		_ = http.NewResponseController(w).SetReadDeadline(time.Now())
		_ = request.Body.Close()
	})
	defer stopRead()
	body, err := io.ReadAll(request.Body)
	if err != nil {
		var tooLarge *http.MaxBytesError
		status := http.StatusUnprocessableEntity
		if errors.As(err, &tooLarge) {
			status = http.StatusRequestEntityTooLarge
		}
		bridgeJSON(w, status, map[string]any{"error": "Cannot read Claude tool call"})
		return
	}
	var call struct {
		Name      string          `json:"name"`
		Arguments json.RawMessage `json:"arguments"`
		CallID    json.RawMessage `json:"callId"`
	}
	if err := json.Unmarshal(body, &call); err != nil || call.Name == "" {
		bridgeJSON(w, http.StatusUnprocessableEntity, map[string]any{"error": "Invalid Claude tool call"})
		return
	}
	if ctx.Err() != nil || execution.Err() != nil {
		return
	}
	tool, exists := b.tools[call.Name]
	if !exists {
		bridgeJSON(w, http.StatusNotFound, map[string]any{"error": "Unknown Mokusei tool"})
		return
	}
	if len(call.Arguments) == 0 {
		call.Arguments = json.RawMessage("null")
	}
	callID := ""
	if len(call.CallID) != 0 {
		if value, err := model.Decode(call.CallID); err == nil {
			switch value := value.(type) {
			case string:
				callID = value
			case json.Number:
				callID = value.String()
			}
		}
		if len(callID) > 256 {
			callID = callID[:256]
		}
	}
	type outcome struct {
		result json.RawMessage
		err    error
	}
	done := make(chan outcome, 1)
	b.mu.Lock()
	if b.closed || execution.Err() != nil {
		b.mu.Unlock()
		return
	}
	b.workers.Add(1)
	b.mu.Unlock()
	go func() {
		defer b.workers.Done()
		// A faulty plugin must not crash the entire runtime or strand the client.
		defer func() {
			if recover() != nil {
				done <- outcome{err: errors.New("Mokusei tool failed unexpectedly")}
			}
		}()
		if err := ctx.Err(); err != nil {
			done <- outcome{err: err}
			return
		}
		result, err := tool.Execute(ctx, plugin.ToolCall{CallID: callID, Arguments: call.Arguments})
		done <- outcome{result: result, err: err}
	}()
	select {
	case <-ctx.Done():
		bridgeJSON(w, http.StatusConflict, map[string]any{"error": "Claude tool call cancelled"})
	case completed := <-done:
		if ctx.Err() != nil {
			return
		}
		if completed.err != nil {
			bridgeJSON(w, http.StatusUnprocessableEntity, map[string]any{"error": completed.err.Error()})
			return
		}
		if len(completed.result) == 0 {
			completed.result = json.RawMessage("null")
		}
		if !json.Valid(completed.result) {
			bridgeJSON(w, http.StatusUnprocessableEntity, map[string]any{"error": "Mokusei tool returned invalid JSON"})
			return
		}
		bridgeJSON(w, http.StatusOK, map[string]any{"result": completed.result})
	}
}

func bridgeJSON(w http.ResponseWriter, status int, value any) {
	data, err := json.Marshal(value)
	if err != nil {
		status = http.StatusInternalServerError
		data = []byte(`{"error":"Cannot encode Claude tool response"}`)
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_, _ = w.Write(data)
}

// ToolSchema removes root oneOf without weakening exactly-one validation.
// Claude drops such MCP tools even though nested union schemas are supported.
func ToolSchema(schema json.RawMessage) (json.RawMessage, error) {
	root, err := model.DecodeObject(schema)
	if err != nil {
		return nil, err
	}
	variants, ok := root["oneOf"].([]any)
	if !ok || len(variants) == 0 {
		return bytes.Clone(schema), nil
	}
	if len(variants) == 1 {
		return conditionalOneOf(root, variants)
	}
	if _, exists := root["if"]; exists {
		return conditionalOneOf(root, variants)
	}
	objects := make([]map[string]any, len(variants))
	for index, value := range variants {
		object, ok := value.(map[string]any)
		if !ok {
			return conditionalOneOf(root, variants)
		}
		objects[index] = object
	}
	properties, ok := objects[0]["properties"].(map[string]any)
	if !ok {
		return conditionalOneOf(root, variants)
	}
	discriminator := ""
	propertyNames := make([]string, 0, len(properties))
	for key := range properties {
		propertyNames = append(propertyNames, key)
	}
	sort.Strings(propertyNames)
	for _, key := range propertyNames {
		seen := map[string]bool{}
		valid := true
		for _, variant := range objects {
			fields, _ := variant["properties"].(map[string]any)
			property, _ := fields[key].(map[string]any)
			constant, exists := property["const"]
			required, _ := variant["required"].([]any)
			isRequired := false
			for _, item := range required {
				if item == key {
					isRequired = true
					break
				}
			}
			if !exists || !isRequired {
				valid = false
				break
			}
			encoded, err := json.Marshal(constant)
			if err != nil || seen[string(encoded)] {
				valid = false
				break
			}
			seen[string(encoded)] = true
		}
		if valid {
			discriminator = key
			break
		}
	}
	if discriminator == "" {
		return conditionalOneOf(root, variants)
	}
	conditional := objects[len(objects)-1]
	for index := len(objects) - 2; index >= 0; index-- {
		variant := objects[index]
		fields := variant["properties"].(map[string]any)
		conditional = map[string]any{"if": map[string]any{"properties": map[string]any{discriminator: fields[discriminator]}, "required": []string{discriminator}}, "then": variant, "else": conditional}
	}
	delete(root, "oneOf")
	for key, value := range conditional {
		root[key] = value
	}
	return json.Marshal(root)
}

// Match one branch, reject any later match, otherwise consider the next
// branch. This also handles native/provider variants sharing a harnessId.
func conditionalOneOf(root map[string]any, variants []any) (json.RawMessage, error) {
	var conditional any = map[string]any{"not": map[string]any{}}
	for index := len(variants) - 1; index >= 0; index-- {
		then := map[string]any{}
		if index+1 < len(variants) {
			then["not"] = map[string]any{"anyOf": variants[index+1:]}
		}
		conditional = map[string]any{"if": variants[index], "then": then, "else": conditional}
	}
	delete(root, "oneOf")
	if condition, exists := root["if"]; exists {
		previous := map[string]any{"if": condition}
		for _, key := range []string{"then", "else"} {
			if value, ok := root[key]; ok {
				previous[key] = value
				delete(root, key)
			}
		}
		root["if"] = previous
		root["then"] = conditional
		root["else"] = map[string]any{"not": map[string]any{}}
		return json.Marshal(root)
	}
	for key, value := range conditional.(map[string]any) {
		root[key] = value
	}
	return json.Marshal(root)
}

type MCPOptions struct {
	Endpoint   string
	Token      string
	ServerName string
	// A nil Tools slice fetches definitions from the authenticated bridge.
	Tools      []ToolDefinition
	HTTPClient *http.Client
}

func MCPOptionsFromEnvironment() MCPOptions {
	return MCPOptions{Endpoint: os.Getenv("MOKUSEI_TOOL_BRIDGE_URL"), Token: os.Getenv("MOKUSEI_TOOL_BRIDGE_TOKEN"), ServerName: os.Getenv("MOKUSEI_TOOL_SERVER_NAME")}
}

type mcpRequest struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params"`
}

type mcpPeer struct {
	ctx         context.Context
	options     MCPOptions
	writer      io.Writer
	writeMu     sync.Mutex
	writeErrors chan error
	pendingMu   sync.Mutex
	pending     map[string]context.CancelFunc
	workers     sync.WaitGroup
}

// ServeMCP implements newline-delimited MCP JSON-RPC on the given streams. It
// writes protocol frames only, supports concurrent tool calls and cancellation,
// and lets already submitted requests finish when the input reaches EOF.
func ServeMCP(ctx context.Context, reader io.Reader, writer io.Writer, options MCPOptions) error {
	if options.ServerName == "" {
		options.ServerName = toolServerName
	}
	if options.Endpoint == "" {
		options.Endpoint = os.Getenv("MOKUSEI_TOOL_BRIDGE_URL")
	}
	if options.Token == "" {
		options.Token = os.Getenv("MOKUSEI_TOOL_BRIDGE_TOKEN")
	}
	endpoint, err := url.Parse(options.Endpoint)
	if err != nil || endpoint.Scheme != "http" || endpoint.User != nil || endpoint.RawQuery != "" || endpoint.Fragment != "" || endpoint.Path != "/tool-call" || options.Token == "" {
		return errors.New("invalid Claude tool bridge configuration")
	}
	ip := net.ParseIP(endpoint.Hostname())
	if ip == nil || !ip.IsLoopback() {
		return errors.New("Claude tool bridge must use a loopback address")
	}
	if options.HTTPClient == nil {
		options.HTTPClient = &http.Client{Transport: &http.Transport{Proxy: nil, MaxIdleConns: 4, IdleConnTimeout: 30 * time.Second}, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
		defer options.HTTPClient.CloseIdleConnections()
	}
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	peer := &mcpPeer{ctx: ctx, options: options, writer: writer, writeErrors: make(chan error, 1), pending: map[string]context.CancelFunc{}}
	type inputLine struct {
		data []byte
		err  error
	}
	lines := make(chan inputLine)
	go func() {
		defer close(lines)
		scanner := bufio.NewScanner(reader)
		scanner.Buffer(make([]byte, 4096), maxToolMessageBytes)
		for scanner.Scan() {
			line := bytes.Clone(scanner.Bytes())
			select {
			case lines <- inputLine{data: line}:
			case <-ctx.Done():
				return
			}
		}
		if err := scanner.Err(); err != nil {
			select {
			case lines <- inputLine{err: err}:
			case <-ctx.Done():
			}
		}
	}()
	// Closing a cancellable input unblocks a native pipe read on shutdown.
	var closeOnce sync.Once
	closeInput := func() {
		closeOnce.Do(func() {
			if closer, ok := reader.(io.ReadCloser); ok {
				_ = closer.Close()
			}
		})
	}
	stopRead := context.AfterFunc(ctx, closeInput)
	defer func() { cancel(); closeInput(); stopRead() }()
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case err := <-peer.writeErrors:
			return err
		case line, open := <-lines:
			if !open {
				finished := make(chan struct{})
				go func() { peer.workers.Wait(); close(finished) }()
				select {
				case <-finished:
					select {
					case err := <-peer.writeErrors:
						return err
					default:
						return nil
					}
				case err := <-peer.writeErrors:
					return err
				case <-ctx.Done():
					return ctx.Err()
				}
			}
			if line.err != nil {
				return line.err
			}
			data := bytes.TrimSpace(line.data)
			if len(data) == 0 {
				continue
			}
			if data[0] == '[' {
				var batch []json.RawMessage
				if err := json.Unmarshal(data, &batch); err != nil {
					peer.rpcError(nil, -32700, "Parse error")
					continue
				}
				if len(batch) == 0 {
					peer.rpcError(nil, -32600, "Invalid request")
				}
				for _, item := range batch {
					peer.dispatch(item)
				}
			} else {
				peer.dispatch(data)
			}
		}
	}
}

func (p *mcpPeer) dispatch(data []byte) {
	var request mcpRequest
	if err := json.Unmarshal(data, &request); err != nil {
		if json.Valid(data) {
			p.rpcError(nil, -32600, "Invalid request")
		} else {
			p.rpcError(nil, -32700, "Parse error")
		}
		return
	}
	if request.Method == "" || (request.JSONRPC != "" && request.JSONRPC != "2.0") {
		p.rpcError(nil, -32600, "Invalid request")
		return
	}
	if len(request.ID) == 0 {
		if request.Method == "notifications/cancelled" {
			var params struct {
				RequestID json.RawMessage `json:"requestId"`
			}
			if json.Unmarshal(request.Params, &params) == nil {
				key, err := requestIdentifier(params.RequestID)
				if err != nil {
					return
				}
				p.pendingMu.Lock()
				if cancel := p.pending[key]; cancel != nil {
					cancel()
				}
				p.pendingMu.Unlock()
			}
		}
		return
	}
	key, err := requestIdentifier(request.ID)
	if err != nil {
		p.rpcError(nil, -32600, "Invalid request identifier")
		return
	}
	ctx, cancel := context.WithCancel(p.ctx)
	p.pendingMu.Lock()
	if _, exists := p.pending[key]; exists {
		p.pendingMu.Unlock()
		cancel()
		p.rpcError(request.ID, -32600, "Duplicate request identifier")
		return
	}
	p.pending[key] = cancel
	p.pendingMu.Unlock()
	p.workers.Add(1)
	go func() {
		defer p.workers.Done()
		defer func() { cancel(); p.pendingMu.Lock(); delete(p.pending, key); p.pendingMu.Unlock() }()
		p.handle(ctx, request)
	}()
}

// JSON string escaping is a wire detail, not part of request identity. Keep
// the original ID in responses while matching cancellation and duplicates by
// its decoded value.
func requestIdentifier(raw json.RawMessage) (string, error) {
	value, err := model.Decode(raw)
	if err != nil {
		return "", err
	}
	switch value.(type) {
	case nil, string, json.Number:
		canonical, err := json.Marshal(value)
		return string(canonical), err
	default:
		return "", errors.New("invalid request identifier")
	}
}

func (p *mcpPeer) handle(ctx context.Context, request mcpRequest) {
	switch request.Method {
	case "initialize":
		var params struct {
			ProtocolVersion string `json:"protocolVersion"`
		}
		_ = json.Unmarshal(request.Params, &params)
		if params.ProtocolVersion == "" {
			params.ProtocolVersion = "2025-06-18"
		}
		p.result(request.ID, map[string]any{"protocolVersion": params.ProtocolVersion, "capabilities": map[string]any{"tools": map[string]any{"listChanged": false}}, "serverInfo": map[string]any{"name": p.options.ServerName, "version": "1.0.0"}})
	case "ping":
		p.result(request.ID, map[string]any{})
	case "tools/list":
		definitions := p.options.Tools
		if definitions == nil {
			endpoint, _ := url.Parse(p.options.Endpoint)
			endpoint.Path = "/tools"
			var result struct {
				Tools []ToolDefinition `json:"tools"`
			}
			if _, err := p.fetch(ctx, http.MethodGet, endpoint.String(), nil, &result); err != nil {
				p.rpcError(request.ID, -32603, err.Error())
				return
			}
			definitions = result.Tools
		}
		if definitions == nil {
			definitions = []ToolDefinition{}
		}
		p.result(request.ID, map[string]any{"tools": definitions})
	case "tools/call":
		var params struct {
			Name      string          `json:"name"`
			Arguments json.RawMessage `json:"arguments"`
		}
		if err := json.Unmarshal(request.Params, &params); err != nil || params.Name == "" {
			p.rpcError(request.ID, -32602, "Invalid tool arguments")
			return
		}
		if len(params.Arguments) == 0 {
			params.Arguments = json.RawMessage("{}")
		}
		callID := string(request.ID)
		var stringID string
		if json.Unmarshal(request.ID, &stringID) == nil {
			callID = stringID
		}
		body, err := json.Marshal(map[string]any{"name": params.Name, "arguments": params.Arguments, "callId": callID})
		if err != nil {
			p.rpcError(request.ID, -32602, "Invalid tool arguments")
			return
		}
		var payload struct {
			Result json.RawMessage `json:"result"`
			Error  string          `json:"error"`
		}
		status, err := p.fetch(ctx, http.MethodPost, p.options.Endpoint, body, &payload)
		if err != nil {
			p.rpcError(request.ID, -32603, err.Error())
			return
		}
		if status < 200 || status >= 300 {
			if payload.Error == "" {
				payload.Error = "Mokusei tool failed"
			}
			p.result(request.ID, map[string]any{"content": []any{map[string]any{"type": "text", "text": payload.Error}}, "isError": true})
			return
		}
		if len(payload.Result) == 0 {
			payload.Result = json.RawMessage("null")
		}
		value, err := model.Decode(payload.Result)
		if err != nil {
			p.rpcError(request.ID, -32603, "Invalid Mokusei tool result")
			return
		}
		text := string(payload.Result)
		if s, ok := value.(string); ok {
			text = s
		}
		result := map[string]any{"content": []any{map[string]any{"type": "text", "text": text}}}
		if object, ok := value.(map[string]any); ok {
			result["structuredContent"] = object
		}
		p.result(request.ID, result)
	default:
		p.rpcError(request.ID, -32601, "Method not found")
	}
}

func (p *mcpPeer) fetch(ctx context.Context, method, endpoint string, body []byte, target any) (int, error) {
	request, err := http.NewRequestWithContext(ctx, method, endpoint, bytes.NewReader(body))
	if err != nil {
		return 0, errors.New("cannot create Claude tool bridge request")
	}
	request.Header.Set("Authorization", "Bearer "+p.options.Token)
	request.Header.Set("Content-Type", "application/json")
	response, err := p.options.HTTPClient.Do(request)
	if err != nil {
		if ctx.Err() != nil {
			return 0, errors.New("Claude tool call cancelled")
		}
		return 0, errors.New("cannot reach Claude tool bridge")
	}
	defer response.Body.Close()
	data, err := io.ReadAll(io.LimitReader(response.Body, maxToolMessageBytes+1))
	if err != nil || len(data) > maxToolMessageBytes {
		return 0, errors.New("cannot read Claude tool bridge response")
	}
	if err := json.Unmarshal(data, target); err != nil {
		return 0, errors.New("invalid Claude tool bridge response")
	}
	if method == http.MethodGet && (response.StatusCode < 200 || response.StatusCode >= 300) {
		return response.StatusCode, errors.New("cannot read Claude tool definitions")
	}
	return response.StatusCode, nil
}

func (p *mcpPeer) result(id json.RawMessage, result any) {
	p.send(map[string]any{"jsonrpc": "2.0", "id": id, "result": result})
}
func (p *mcpPeer) rpcError(id json.RawMessage, code int, message string) {
	p.send(map[string]any{"jsonrpc": "2.0", "id": id, "error": map[string]any{"code": code, "message": message}})
}
func (p *mcpPeer) send(value any) {
	p.writeMu.Lock()
	defer p.writeMu.Unlock()
	if err := json.NewEncoder(p.writer).Encode(value); err != nil {
		select {
		case p.writeErrors <- err:
		default:
		}
	}
}
