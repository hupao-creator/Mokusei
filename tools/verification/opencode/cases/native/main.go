package main

import (
	"context"
	"encoding/json"
	"fmt"
	oc "github.com/hupao-creator/Mokusei/internal/plugins/harness/opencode"
	"net/http"
	"net/http/httptest"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
)

func must(err error) {
	if err != nil {
		panic(err)
	}
}
func main() {
	parent, stopSignal := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stopSignal()
	nativeCLI := os.Getenv("MOKUSEI_OPENCODE_NATIVE_CLI")
	if nativeCLI == "" {
		panic("native replay requires explicit -native-cli via the verification runner")
	}
	root, e := os.MkdirTemp("", "mokusei-native-opencode-smoke-")
	must(e)
	defer os.RemoveAll(root)
	cwd := filepath.Join(root, "workspace")
	must(os.MkdirAll(cwd, 0700))
	var mu sync.Mutex
	requests := []map[string]any{}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/chat/completions" {
			http.NotFound(w, r)
			return
		}
		var body map[string]any
		if e := json.NewDecoder(r.Body).Decode(&body); e != nil {
			http.Error(w, "bad request", 400)
			return
		}
		mu.Lock()
		requests = append(requests, body)
		mu.Unlock()
		text := `{"reply":"fixture"}`
		w.Header().Set("Content-Type", "text/event-stream")
		f := w.(http.Flusher)
		chunks := []any{map[string]any{"id": "chatcmpl_fixture", "object": "chat.completion.chunk", "created": time.Now().Unix(), "model": "fixture-model", "choices": []any{map[string]any{"index": 0, "delta": map[string]any{"role": "assistant", "content": text}, "finish_reason": nil}}}, map[string]any{"id": "chatcmpl_fixture", "object": "chat.completion.chunk", "created": time.Now().Unix(), "model": "fixture-model", "choices": []any{map[string]any{"index": 0, "delta": map[string]any{}, "finish_reason": "stop"}}, "usage": map[string]any{"prompt_tokens": 12, "completion_tokens": 3, "total_tokens": 15}}}
		for _, chunk := range chunks {
			b, _ := json.Marshal(chunk)
			fmt.Fprintf(w, "data: %s\n\n", b)
			f.Flush()
		}
		fmt.Fprint(w, "data: [DONE]\n\n")
		f.Flush()
	}))
	defer server.Close()
	env := map[string]string{"PATH": os.Getenv("PATH"), "HOME": root, "XDG_DATA_HOME": filepath.Join(root, "data"), "XDG_CONFIG_HOME": filepath.Join(root, "config"), "XDG_CACHE_HOME": filepath.Join(root, "cache"), "XDG_STATE_HOME": filepath.Join(root, "state"), "OPENCODE_TEST_HOME": root, "OPENCODE_CONFIG_PROJECT_DISABLE": "1", "OPENCODE_DISABLE_MODELS_FETCH": "1"}
	config := oc.Object{"model": oc.Object{"providerID": "fixture", "model": "fixture-model"}, "providers": oc.Object{"fixture": oc.Object{"name": "Fixture", "package": "@opencode/ai/providers/openai-compatible", "settings": oc.Object{"baseURL": server.URL + "/v1", "apiKey": "synthetic-only"}, "models": oc.Object{"fixture-model": oc.Object{"name": "Fixture model", "modelID": "fixture-model", "capabilities": oc.Object{"tools": true, "input": []string{"text"}, "output": []string{"text"}}, "limit": oc.Object{"context": 32000, "output": 1024}}}}}}
	ctx, cancel := context.WithTimeout(parent, 45*time.Second)
	defer cancel()
	runtime, e := oc.NewRuntime(ctx, oc.Options{CWD: cwd, ExecutablePath: nativeCLI, Environment: env, Config: config, IsolateConfig: true})
	must(e)
	defer runtime.Close()
	id := oc.NewSessionID()
	schema := oc.Object{"type": "object", "properties": oc.Object{"reply": oc.Object{"type": "string"}}, "required": []string{"reply"}, "additionalProperties": false}
	must(runtime.ConfigureSession(ctx, id, oc.BridgeConfiguration{OutputSchema: schema, ModelOptions: oc.Object{"mokuseiStructuredOutput": "openai-chat-json-schema"}}))
	var session oc.Object
	must(runtime.Request(ctx, "POST", "/api/session", oc.Object{"id": id, "location": oc.Object{"directory": cwd}, "model": oc.Object{"providerID": "fixture", "id": "fixture-model"}}, &session))
	var eventsMu sync.Mutex
	events := []string{}
	gap := make(chan error, 4)
	unsub := runtime.Subscribe(func(event oc.Event) error {
		eventsMu.Lock()
		events = append(events, event.Type)
		eventsMu.Unlock()
		return nil
	}, func(err error) {
		select {
		case gap <- err:
		default:
		}
	})
	defer unsub()
	must(runtime.EventsReady(ctx))
	must(runtime.Request(ctx, "POST", "/api/session/"+id+"/prompt", oc.Object{"id": "msg_fixture_native", "text": "Return fixture JSON.", "delivery": "steer"}, nil))
	must(runtime.Request(ctx, "POST", "/api/experimental/session/"+id+"/wait", nil, nil))
	snapshot, e := runtime.Snapshot(ctx, id)
	must(e)
	encoded, _ := json.Marshal(snapshot)
	mu.Lock()
	count := len(requests)
	hasSchema := false
	for _, request := range requests {
		if v, ok := request["response_format"].(map[string]any); ok && v["type"] == "json_schema" {
			hasSchema = true
		}
	}
	mu.Unlock()
	eventsMu.Lock()
	allEvents := strings.Join(events, ",")
	eventsMu.Unlock()
	fmt.Printf("Native fixture requests=%d strictSchema=%v terminal=%v\n", count, hasSchema, strings.Contains(allEvents, "session.execution.succeeded"))
	if count != 1 || !hasSchema || !strings.Contains(string(encoded), "fixture") || !strings.Contains(allEvents, "session.execution.succeeded") {
		panic("native bridge fixture verification incomplete")
	}
	must(runtime.Close())
	fmt.Println("PASS: real OpenCode 2.0.25 isolated native plugin, refresh acknowledgement, session/prompt, local mocked inference, schema transform, SSE and durable export")
	verifyNativeSettings(parent, nativeCLI, cwd, env, config, func() []map[string]any {
		mu.Lock()
		defer mu.Unlock()
		return append([]map[string]any{}, requests...)
	})
	verifyNativeOAuth(nativeCLI)
}

func verifyNativeOAuth(nativeCLI string) {
	root, e := os.MkdirTemp("", "mokusei-native-oauth-proof-")
	must(e)
	defer os.RemoveAll(root)
	dir := filepath.Join(root, "plugin")
	must(os.MkdirAll(dir, 0700))
	must(os.WriteFile(filepath.Join(dir, "package.json"), []byte(`{"type":"module","main":"index.mjs"}`), 0600))
	must(os.WriteFile(filepath.Join(dir, "index.mjs"), []byte(`
export default {id:'mokusei.refresh-proof',async setup(ctx){
 let refreshes=0;
 const integration=(await ctx.integration.get({integrationID:'opencode'})).data;
 const method=integration.methods.find(value=>value.type==='oauth');const methodID=method.id;
 await ctx.integration.transform(editor=>{
  editor.method.update({integrationID:'opencode',method:{...method,label:'Synthetic refresh proof'},authorize:async()=>{throw Error('unused')},refresh:async value=>{refreshes++;return {...value,access:'synthetic-renewed',refresh:'synthetic-rotated',expires:Date.now()+3600000}}});
 });
 await ctx.rpc.register({id:'mokusei.refresh-proof',methods:{info:{input:{type:'object'},output:{type:'object'}},resolve:{input:{type:'object'},output:{type:'object'}}},events:{}},{info:async()=>({methodID,refreshes}),resolve:async()=>{const connection=await ctx.integration.connection.active('opencode');const value=await ctx.integration.connection.resolve(connection);return {renewed:value.access==='synthetic-renewed',rotated:value.refresh==='synthetic-rotated',refreshes}}});
}};`), 0600))
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	env := map[string]string{"PATH": os.Getenv("PATH"), "HOME": root, "XDG_DATA_HOME": filepath.Join(root, "data"), "XDG_CONFIG_HOME": filepath.Join(root, "config"), "XDG_CACHE_HOME": filepath.Join(root, "cache"), "XDG_STATE_HOME": filepath.Join(root, "state"), "OPENCODE_TEST_HOME": root, "OPENCODE_CONFIG_PROJECT_DISABLE": "1", "OPENCODE_DISABLE_MODELS_FETCH": "1"}
	r, e := oc.NewRuntime(ctx, oc.Options{CWD: root, ExecutablePath: nativeCLI, Environment: env, Config: oc.Object{"plugins": []any{dir}}})
	must(e)
	defer r.Close()
	var info struct {
		Output oc.Object `json:"output"`
	}
	must(r.Request(ctx, "POST", "/api/rpc/mokusei.refresh-proof/info", oc.Object{"input": oc.Object{}}, &info))
	must(r.Request(ctx, "POST", "/api/credential", oc.Object{"id": "cred_mokusei_proof", "integrationID": "opencode", "label": "synthetic-only", "activate": true, "value": oc.Object{"type": "oauth", "methodID": info.Output["methodID"], "access": "synthetic-expired", "refresh": "synthetic-original", "expires": 1}}, nil))
	var result struct {
		Output oc.Object `json:"output"`
	}
	must(r.Request(ctx, "POST", "/api/rpc/mokusei.refresh-proof/resolve", oc.Object{"input": oc.Object{}}, &result))
	if result.Output["renewed"] != true || result.Output["rotated"] != true || result.Output["refreshes"] != float64(1) {
		panic("native OAuth refresh did not rotate and resolve")
	}
	must(r.Request(ctx, "POST", "/api/rpc/mokusei.refresh-proof/resolve", oc.Object{"input": oc.Object{}}, &result))
	if result.Output["refreshes"] != float64(1) {
		panic("native OAuth resolver refreshed a valid credential again")
	}
	must(r.Close())
	r, e = oc.NewRuntime(ctx, oc.Options{CWD: root, ExecutablePath: nativeCLI, Environment: env, Config: oc.Object{"plugins": []any{dir}}})
	must(e)
	defer r.Close()
	must(r.Request(ctx, "POST", "/api/rpc/mokusei.refresh-proof/resolve", oc.Object{"input": oc.Object{}}, &result))
	if result.Output["renewed"] != true || result.Output["rotated"] != true || result.Output["refreshes"] != float64(0) {
		panic("native OAuth rotation was not persisted across server restart")
	}
	must(r.Close())
	fmt.Println("PASS native OAuth: expired synthetic credential refreshed by native resolver, cached and persisted across single-server restart")
}
