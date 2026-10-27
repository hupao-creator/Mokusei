package opencode

import (
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"embed"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"

	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

// These resources execute only inside the external OpenCode process. They have
// no build step and retain native executor / credential object identities.
//
//go:embed assets/*.mjs
var assets embed.FS

type ModelRequest struct {
	SessionID     string      `json:"sessionID"`
	RootSessionID string      `json:"rootSessionID"`
	Kind          string      `json:"kind"`
	ReadPrefix    Object      `json:"readPrefix,omitempty"`
	Model         NativeModel `json:"model"`
}
type NativeModel struct {
	ProviderID string `json:"providerID"`
	ID         string `json:"id"`
	Variant    string `json:"variant,omitempty"`
}
type BridgeConfiguration struct {
	ReadPrefix     Object
	Injection      *plugin.Injection
	ContextEntries []plugin.ContextEntry
	ModelOptions   Object
	OutputSchema   Object
	BeforeModel    func(context.Context, ModelRequest) error
}
type registration struct {
	revision int
	config   BridgeConfiguration
	wire     Object
	bindings map[string]plugin.ToolBinding
}
type Bridge struct {
	Directory string
	mu        sync.Mutex
	closed    bool
	isolated  bool
	token     string
	current   map[string]*registration
	parents   map[string]string
	versions  map[string]*registration
	server    *http.Server
	listener  net.Listener
	ctx       context.Context
	cancel    context.CancelFunc
	handlers  sync.WaitGroup
	closeOnce sync.Once
	closeErr  error
}

func NewBridge(isolated bool) (*Bridge, error) {
	dir, err := os.MkdirTemp("", "mokusei-opencode-bridge-")
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithCancel(context.Background())
	b := &Bridge{Directory: dir, isolated: isolated, token: randomToken(), current: map[string]*registration{}, parents: map[string]string{}, versions: map[string]*registration{}, ctx: ctx, cancel: cancel}
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		cancel()
		_ = os.RemoveAll(dir)
		return nil, err
	}
	b.listener = listener
	b.server = &http.Server{Handler: http.HandlerFunc(b.serve), BaseContext: func(net.Listener) context.Context { return ctx }, MaxHeaderBytes: 8192}
	for _, name := range []string{"index.mjs", "credentials.mjs"} {
		body, e := assets.ReadFile("assets/" + name)
		if e != nil {
			_ = b.Close(false)
			return nil, e
		}
		if e = os.WriteFile(filepath.Join(dir, name), body, 0600); e != nil {
			_ = b.Close(false)
			return nil, e
		}
	}
	configuration, _ := json.Marshal(Object{"endpoint": "http://" + listener.Addr().String(), "token": b.token, "isolated": isolated})
	if err = os.WriteFile(filepath.Join(dir, "transport.json"), configuration, 0600); err != nil {
		_ = b.Close(false)
		return nil, err
	}
	if err = os.WriteFile(filepath.Join(dir, "package.json"), []byte(`{"type":"module","main":"index.mjs"}`), 0600); err != nil {
		_ = b.Close(false)
		return nil, err
	}
	go func() { _ = b.server.Serve(listener) }()
	return b, nil
}

var toolPattern = regexp.MustCompile(`^[A-Za-z0-9_-]+$`)

func (b *Bridge) Configure(id string, c BridgeConfiguration) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.closed {
		return 0, errors.New("OpenCode bridge closed")
	}
	if !strings.HasPrefix(id, "ses_") {
		return 0, errors.New("invalid OpenCode session identity")
	}
	injection := c.Injection
	if injection == nil {
		injection = &plugin.Injection{}
	}
	mode := "extend"
	bindings := map[string]plugin.ToolBinding{}
	if injection.Tools != nil {
		mode = injection.Tools.Mode
		if mode != "extend" && mode != "exclusive" {
			return 0, errors.New("invalid OpenCode tool mode")
		}
		if mode == "exclusive" && !b.isolated {
			return 0, errors.New("exclusive OpenCode tools require isolated configuration")
		}
		for _, binding := range injection.Tools.Bindings {
			if !toolPattern.MatchString(binding.Name) || strings.HasPrefix(binding.Name, "mokusei_host_") || binding.Execute == nil {
				return 0, errors.New("invalid OpenCode tool binding")
			}
			if _, ok := bindings[binding.Name]; ok {
				return 0, errors.New("duplicate OpenCode tool name")
			}
			bindings[binding.Name] = binding
		}
	}
	revision := 1
	if prev := b.current[id]; prev != nil {
		revision = prev.revision + 1
	}
	identity := fmt.Sprintf("%s:%d", id, revision)
	digest := sha256.Sum256([]byte(identity))
	prefix := hex.EncodeToString(digest[:])[:16]
	tools := []Object{}
	if injection.Tools != nil {
		for i, v := range injection.Tools.Bindings {
			input := json.RawMessage(v.InputSchema)
			if len(input) == 0 || !json.Valid(input) {
				return 0, errors.New("invalid tool input schema")
			}
			output := json.RawMessage(v.OutputSchema)
			if len(output) == 0 {
				output = json.RawMessage(`{}`)
			} else if !json.Valid(output) {
				return 0, errors.New("invalid tool output schema")
			}
			tools = append(tools, Object{"id": fmt.Sprintf("mokusei_host_%s_%d", prefix, i), "name": v.Name, "description": v.Description, "inputSchema": input, "outputSchema": output})
		}
	}
	instructions := append([]string{}, injection.Instructions...)
	for _, v := range append(append([]plugin.ContextEntry{}, injection.ContextEntries...), c.ContextEntries...) {
		instructions = append(instructions, "["+v.ID+"]\n"+v.Content)
	}
	if c.OutputSchema != nil {
		encoded, err := json.Marshal(c.OutputSchema)
		if err != nil {
			return 0, fmt.Errorf("invalid OpenCode output schema: %w", err)
		}
		instructions = append(instructions, "Return only valid JSON matching this JSON Schema:\n"+string(encoded))
	}
	seed := []Object{}
	names := map[string]string{}
	for _, v := range injection.Seed {
		if v.Type == "tool-call" {
			names[v.CallID] = v.Name
		}
	}
	for _, v := range injection.Seed {
		switch v.Type {
		case "message":
			seed = append(seed, Object{"role": v.Role, "content": []Object{{"type": "text", "text": v.Content}}})
		case "tool-call":
			seed = append(seed, Object{"role": "assistant", "content": []Object{{"type": "tool-call", "id": v.CallID, "name": v.Name, "input": v.Arguments}}})
		case "tool-result":
			name := names[v.CallID]
			if name == "" {
				name = "tool"
			}
			kind := "json"
			if v.IsError {
				kind = "error"
			}
			seed = append(seed, Object{"role": "tool", "content": []Object{{"type": "tool-result", "id": v.CallID, "name": name, "result": Object{"type": kind, "value": v.Result}}}})
		}
	}
	options := Object{}
	for k, v := range c.ModelOptions {
		if k != "mokuseiStructuredOutput" {
			options[k] = v
		}
	}
	wire := Object{"sessionID": id, "revision": revision, "mode": mode, "tools": tools, "instructions": strings.Join(instructions, "\n\n"), "seed": seed, "modelOptions": options}
	if c.ReadPrefix != nil {
		wire["readPrefix"] = c.ReadPrefix
	}
	// Validate and freeze all wire data before publishing this revision. Callers
	// may reuse their configuration maps after Configure returns.
	snapshot := struct {
		Wire         Object
		OutputSchema Object
		ModelOptions Object
	}{wire, c.OutputSchema, c.ModelOptions}
	encoded, err := json.Marshal(snapshot)
	if err != nil {
		return 0, fmt.Errorf("invalid OpenCode bridge configuration: %w", err)
	}
	snapshot.Wire, snapshot.OutputSchema, snapshot.ModelOptions = nil, nil, nil
	decoder := json.NewDecoder(bytes.NewReader(encoded))
	decoder.UseNumber()
	if err = decoder.Decode(&snapshot); err != nil {
		return 0, err
	}
	c.OutputSchema, c.ModelOptions = snapshot.OutputSchema, snapshot.ModelOptions
	reg := &registration{revision, c, snapshot.Wire, bindings}
	b.current[id] = reg
	b.versions[identity] = reg
	return revision, nil
}

// Registered roots come from Mokusei session state; children are accepted only
// through a native parent relation or the authenticated plugin's root lookup.
func (b *Bridge) Owns(id string) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.current[id] != nil || b.parents[id] != ""
}
func (b *Bridge) TrackChild(id, parent string) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	if id == "" || (b.current[parent] == nil && b.parents[parent] == "") {
		return false
	}
	b.parents[id] = parent
	return true
}
func (b *Bridge) Revoke() { b.mu.Lock(); b.closed = true; b.mu.Unlock(); b.cancel() }
func (b *Bridge) Close(preserve bool) error {
	b.closeOnce.Do(func() {
		b.Revoke()
		if b.server != nil {
			b.closeErr = b.server.Close()
		}
		if b.listener != nil {
			_ = b.listener.Close()
		}
		// Server.Close cancels HTTP requests but does not join handlers. Tool
		// callbacks may still be releasing owned resources after cancellation.
		b.handlers.Wait()
		if !preserve {
			b.closeErr = errors.Join(b.closeErr, os.RemoveAll(b.Directory))
		}
	})
	return b.closeErr
}
func (b *Bridge) serve(w http.ResponseWriter, r *http.Request) {
	provided := r.Header.Get("Authorization")
	expected := "Bearer " + b.token
	b.mu.Lock()
	if b.closed || r.Method != "POST" || subtle.ConstantTimeCompare([]byte(provided), []byte(expected)) != 1 {
		b.mu.Unlock()
		w.WriteHeader(401)
		return
	}
	// Revoke closes admission under this same lock before Close waits, so Add
	// cannot race a zero-count Wait while a new request enters the bridge.
	b.handlers.Add(1)
	b.mu.Unlock()
	defer b.handlers.Done()
	var value Object
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 16<<20)).Decode(&value); err != nil {
		http.Error(w, "invalid bridge body", 400)
		return
	}
	result, code, err := b.invoke(r.Context(), r.URL.Path, value)
	if err != nil {
		http.Error(w, bridgeFailureMessage(err), code)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(result)
}
func (b *Bridge) invoke(ctx context.Context, path string, value Object) (any, int, error) {
	if path == "/configuration" {
		b.mu.Lock()
		sessions := make([]Object, 0, len(b.current))
		for _, v := range b.current {
			sessions = append(sessions, v.wire)
		}
		b.mu.Unlock()
		return Object{"sessions": sessions}, 200, nil
	}
	root, session := str(value["rootSessionID"]), str(value["sessionID"])
	revision := int(number(value["revision"]))
	b.mu.Lock()
	reg := b.versions[fmt.Sprintf("%s:%d", root, revision)]
	b.mu.Unlock()
	if reg == nil || session == "" {
		return nil, 409, errors.New("expired session bridge registration")
	}
	b.TrackChild(session, root)
	switch path {
	case "/before-model":
		var request ModelRequest
		encoded, _ := json.Marshal(value)
		if err := json.Unmarshal(encoded, &request); err != nil {
			return nil, 400, err
		}
		if request.Model.ID == "" || request.Model.ProviderID == "" || (request.Kind != "primary" && request.Kind != "compaction" && request.Kind != "generate") {
			return nil, 400, errors.New("invalid model request")
		}
		if reg.config.BeforeModel != nil {
			if err := reg.config.BeforeModel(ctx, request); err != nil {
				return nil, 403, err
			}
		}
		return Object{"admitted": true}, 200, nil
	case "/before-tool":
		name := str(value["name"])
		if str(reg.wire["mode"]) == "exclusive" {
			allowed := false
			for _, item := range array(reg.wire["tools"]) {
				v := object(item)
				if v["name"] == name || v["id"] == name {
					allowed = true
					break
				}
			}
			if !allowed {
				return nil, 403, errors.New("unbound exclusive tool")
			}
		}
		return Object{"admitted": true}, 200, nil
	case "/http-request":
		if reg.config.OutputSchema != nil && reg.config.ModelOptions["mokuseiStructuredOutput"] == "openai-chat-json-schema" && strings.HasSuffix(str(value["path"]), "/chat/completions") {
			return Object{"responseFormat": Object{"type": "json_schema", "json_schema": Object{"name": "mokusei_result", "strict": true, "schema": reg.config.OutputSchema}}}, 200, nil
		}
		return Object{}, 200, nil
	case "/tool":
		name, call := str(value["name"]), str(value["callId"])
		binding, ok := reg.bindings[name]
		if !ok || call == "" {
			return nil, 403, errors.New("unknown tool")
		}
		arguments, err := json.Marshal(value["arguments"])
		if err != nil {
			return nil, 400, err
		}
		result, err := binding.Execute(ctx, plugin.ToolCall{CallID: call, Arguments: arguments})
		if err != nil {
			return nil, toolFailureStatus(err), err
		}
		if !json.Valid(result) {
			return nil, 500, errors.New("non JSON tool result")
		}
		return Object{"value": result}, 200, nil
	default:
		return nil, 404, errors.New("unknown bridge route")
	}
}
func str(v any) string { s, _ := v.(string); return s }

// toolFailureStatus separates caller-correctable tool failures (bad arguments,
// unavailable settings, rejected Provider selections) from bridge or Harness
// faults. The native caller can only act on the distinction and the message.
func toolFailureStatus(err error) int {
	var caller *plugin.ToolCallError
	if errors.As(err, &caller) {
		return http.StatusUnprocessableEntity
	}
	return http.StatusInternalServerError
}

// bridgeFailureMessage keeps the real cause. The native caller never sees the
// Go error, so a fixed status line destroys the only available diagnostic.
func bridgeFailureMessage(err error) string {
	message := strings.Join(strings.Fields(err.Error()), " ")
	runes := []rune(message)
	if len(runes) > 2000 {
		message = string(runes[:2000]) + "..."
	}
	if message == "" {
		return "Mokusei bridge operation failed"
	}
	return message
}
func number(v any) float64 {
	switch n := v.(type) {
	case float64:
		return n
	case int:
		return float64(n)
	case int64:
		return float64(n)
	case json.Number:
		f, _ := n.Float64()
		return f
	}
	return 0
}
func object(v any) Object {
	o, _ := v.(map[string]any)
	if o == nil {
		return Object{}
	}
	return o
}
func array(v any) []any  { a, _ := v.([]any); return a }
func clone[T any](v T) T { b, _ := json.Marshal(v); var out T; _ = json.Unmarshal(b, &out); return out }
