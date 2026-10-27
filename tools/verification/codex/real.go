package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/codex"
	"github.com/hupao-creator/Mokusei/internal/services/moku"
)

// The real CLI is optional. Its Provider is a localhost SSE script and a macOS
// network sandbox denies every non-loopback destination, including telemetry.
// No account credential or user configuration is inherited.
func runReal(ctx context.Context, root, requestedBinary string) error {
	if runtime.GOOS != "darwin" {
		return fmt.Errorf("real native verification requires macOS sandbox-exec to enforce loopback-only egress; synthetic replay remains portable")
	}
	if _, e := os.Stat("/usr/bin/sandbox-exec"); e != nil {
		return fmt.Errorf("cannot enforce native loopback-only egress: %w", e)
	}
	native, e := filepath.Abs(requestedBinary)
	if e != nil {
		return e
	}
	info, e := os.Stat(native)
	if e != nil || info.IsDir() {
		return fmt.Errorf("native Codex executable is unavailable: %s", native)
	}
	environment, e := isolatedEnvironment(root)
	if e != nil {
		return e
	}
	provider := &localProvider{}
	listener, e := net.Listen("tcp", "127.0.0.1:0")
	if e != nil {
		return e
	}
	server := &http.Server{Handler: provider, ReadHeaderTimeout: 5 * time.Second, MaxHeaderBytes: 64 * 1024}
	go func() { _ = server.Serve(listener) }()
	defer server.Close()
	endpoint := "http://" + listener.Addr().String() + "/v1"
	environment["MOKUSEI_FIXTURE_KEY"] = "local-scripted-provider-only"
	environment["HTTP_PROXY"] = "http://" + listener.Addr().String()
	environment["HTTPS_PROXY"] = "http://" + listener.Addr().String()
	environment["ALL_PROXY"] = "http://" + listener.Addr().String()
	environment["NO_PROXY"] = "127.0.0.1,localhost,::1"
	config := fmt.Sprintf(`model = "gpt-5.4"
model_provider = "mokusei_fixture"
approval_policy = "never"
sandbox_mode = "read-only"
cli_auth_credentials_store = "file"
check_for_update_on_startup = false
web_search = "disabled"
service_tier = "fast"

[model_providers.mokusei_fixture]
name = "Mokusei local scripted verification"
base_url = %s
wire_api = "responses"
env_key = "MOKUSEI_FIXTURE_KEY"
requires_openai_auth = false
supports_websockets = false
stream_max_retries = 10

[features]
apps = false
plugins = false
remote_plugin = false
hooks = false
goals = false
memories = false
shell_snapshot = false
multi_agent = false
image_generation = false
responses_websockets = false
responses_websockets_v2 = false

[otel]
exporter = "none"
trace_exporter = "none"
`, strconv.Quote(endpoint))
	if e = os.WriteFile(filepath.Join(environment["CODEX_HOME"], "config.toml"), []byte(config), 0600); e != nil {
		return e
	}
	profile := filepath.Join(root, "loopback-only.sb")
	if e = os.WriteFile(profile, []byte("(version 1)\n(allow default)\n(deny network*)\n(allow network-outbound (remote ip \"localhost:*\"))\n"), 0600); e != nil {
		return e
	}
	wrapper := filepath.Join(root, "codex-isolated")
	script := "#!/bin/sh\nexec /usr/bin/sandbox-exec -f " + shellQuote(profile) + " " + shellQuote(native) + " \"$@\"\n"
	if e = os.WriteFile(wrapper, []byte(script), 0700); e != nil {
		return e
	}
	probe := exec.CommandContext(ctx, wrapper, "--version")
	probe.Env = environmentList(environment)
	probe.WaitDelay = 2 * time.Second
	output, e := probe.CombinedOutput()
	version := strings.TrimSpace(string(output))
	if e != nil {
		return fmt.Errorf("cannot run installed Codex under loopback-only isolation: %w: %s", e, version)
	}
	fmt.Println("REAL native version:", version)
	adapter := codex.New(host(root, environment))
	defer adapter.Close()
	if e = replayRejectedNativeStart(ctx, root, wrapper, environment, adapter); e != nil {
		return e
	}
	store := &memoryStore{}
	thread := model.SessionRecord{ID: "real-native-fixture", CreatedAt: time.Now().UnixMilli(), Cwd: filepath.Join(root, "work"), Settings: encoded(object{"executablePath": wrapper, "model": "gpt-5.4", "serviceTier": "default", "approvalPolicy": "never", "approvalsReviewer": "user", "sandbox": "workspace-write"})}
	handle, e := adapter.Open(ctx, plugin.OpenContext{ThreadID: thread.ID, ReadThread: func() model.SessionRecord { return thread }, SessionState: store})
	if e != nil {
		return e
	}
	defer handle.Close()
	if e = handle.Send(ctx, plugin.SendRequest{ExecutionID: "real-local-execution", Input: model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "Return the local scripted response; do not call tools."}}}}); e != nil {
		return fmt.Errorf("real native turn admission: %w", e)
	}
	execution, e := awaitExecution(ctx, adapter, store, handle, false)
	if e != nil {
		if execution != nil && execution.Error != nil {
			return fmt.Errorf("real native execution: %s", *execution.Error)
		}
		return e
	}
	if execution.Summary == nil || *execution.Summary != realAnswer {
		return fmt.Errorf("real native final projection mismatch: %#v", execution.Summary)
	}

	fmt.Println("PASS real native app-server / local Responses SSE / durable projection")
	answer, e := handle.Read(ctx, "What was the fixture answer?")
	if e != nil {
		return fmt.Errorf("real native isolated read: %w", e)
	}
	if answer != realAnswer {
		return fmt.Errorf("real native read answer mismatch: %q", answer)
	}
	thread.SessionState = store.Read()
	fork, e := adapter.Fork(ctx, plugin.ForkRequest{Source: model.ThreadRecord{SessionRecord: thread}, Request: encoded(object{})})
	if e != nil {
		return fmt.Errorf("real native fork: %w", e)
	}
	if decoded(fork.SessionState)["primarySessionId"] == decoded(store.Read())["primarySessionId"] {
		return fmt.Errorf("real native fork reused source identity")
	}
	fmt.Println("PASS real native independent fork / isolated history read")
	for i := 0; i < 3; i++ {
		source := model.ThreadRecord{SessionRecord: thread}
		source.SessionState = store.Read()
		start := time.Now()
		discussion, err := adapter.PrepareDiscussion(ctx, plugin.DiscussionRequest{Source: source, Instructions: "Private read-only preparation probe. Do not advance the source task."})
		if err != nil {
			return fmt.Errorf("real native discussion preparation: %w", err)
		}
		elapsed := time.Since(start)
		if err = discussion.Close(); err != nil {
			return err
		}
		fmt.Printf("PASS real native restricted discussion preparation %d: %.2fms (no inference)\n", i+1, float64(elapsed.Nanoseconds())/1e6)
	}

	if e = handle.Close(); e != nil {
		return e
	}
	resumed, e := adapter.Open(ctx, plugin.OpenContext{ThreadID: thread.ID, ReadThread: func() model.SessionRecord { return thread }, SessionState: store})
	if e != nil {
		return e
	}
	defer resumed.Close()
	if e = resumed.Send(ctx, plugin.SendRequest{ExecutionID: "real-resumed", Input: model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "Repeat the fixture answer after resume."}}}}); e != nil {
		return fmt.Errorf("real native resume admission: %w", e)
	}
	if _, e = awaitExecution(ctx, adapter, store, resumed, false); e != nil {
		return e
	}
	if e = resumed.Close(); e != nil {
		return e
	}
	fmt.Println("PASS real native process restart / persisted session resume")
	creation, e := moku.DescribeThreadCreation([]moku.TargetDescription{{HarnessID: "codex", DisplayName: "Codex", NativeSchema: encoded(codex.SettingsSchemaForModels([]codex.Map{{"value": "gpt-5.4", "thinking": codex.Map{"kind": "effort", "efforts": []string{"low"}}, "serviceTiers": []codex.Map{{"value": "priority"}}}}))}}, thread.Cwd)
	if e != nil {
		return e
	}
	toolStore := &memoryStore{}
	var called atomic.Bool
	toolHandle, e := adapter.Open(ctx, plugin.OpenContext{ThreadID: "real-native-tool", ReadThread: func() model.SessionRecord { return thread }, SessionState: toolStore, Injection: &plugin.Injection{Tools: &plugin.ToolInjection{Mode: "extend", Bindings: []plugin.ToolBinding{{Name: "echo_fixture", Description: "Echo the local integration fixture argument", InputSchema: encoded(object{"type": "object", "properties": object{"text": object{"type": "string"}}, "required": []string{"text"}, "additionalProperties": false}), Execute: func(ctx context.Context, call plugin.ToolCall) (json.RawMessage, error) {
		if decoded(call.Arguments)["text"] != "native tool works" {
			return nil, fmt.Errorf("native MCP arguments mismatch")
		}
		called.Store(true)
		return call.Arguments, nil
	}}, {Name: "create_thread", Description: "Inspect the Moku creation contract; this fixture must never execute it", InputSchema: creation.InputSchema, Execute: func(context.Context, plugin.ToolCall) (json.RawMessage, error) {
		return nil, fmt.Errorf("fixture must not create delegated threads")
	}}}}}})
	if e != nil {
		return e
	}
	defer toolHandle.Close()
	if e = toolHandle.Send(ctx, plugin.SendRequest{ExecutionID: "real-tool-execution", Input: model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "native-mcp-fixture: call echo_fixture exactly once, then return the scripted answer."}}}}); e != nil {
		return fmt.Errorf("real native MCP admission: %w", e)
	}
	if _, e = awaitExecution(ctx, adapter, toolStore, toolHandle, false); e != nil {
		return e
	}
	if !called.Load() {
		requests, _ := provider.snapshot()
		details := []any{}
		for _, request := range requests {
			for _, item := range list(request["input"]) {
				if record(item)["type"] == "function_call_output" {
					details = append(details, item)
				}
			}
		}
		return fmt.Errorf("real native MCP callback never executed; native tool outputs: %s", encoded(details))
	}
	if e = toolHandle.Close(); e != nil {
		return e
	}
	fmt.Println("PASS real native Provider tool call / authenticated MCP callback")
	requests, failures := provider.snapshot()
	if len(requests) != 6 || len(failures) > 0 {
		return fmt.Errorf("local Provider request audit failed: requests=%d failures=%v", len(requests), failures)
	}
	for _, request := range requests {
		if request["model"] != "gpt-5.4" || request["stream"] != true {
			return fmt.Errorf("native request changed model or stream")
		}
		if tier := request["service_tier"]; tier != nil && tier != "default" {
			return fmt.Errorf("native standard service inherited Fast: %v", tier)
		}
	}
	toolSchema := findNativeToolSchema(requests[len(requests)-1]["tools"], "create_thread")
	options := record(record(toolSchema["properties"])["options"])
	if record(record(options["properties"])["serviceTier"])["type"] != "string" || !containsText(options["required"], "serviceTier") {
		return fmt.Errorf("native model-facing Moku declaration hid the required service tier: %s", encoded(options))
	}
	fmt.Println("PASS real native standard tier overrides Fast defaults / model-facing Moku serviceTier is required")
	fmt.Printf("PASS real native network audit (%d scripted Provider requests, loopback-only OS sandbox)\n", len(requests))

	return verifyRealHTTPRecovery(ctx, root, wrapper, adapter, provider)
}

// Reproduce an empty native thread whose first turn is rejected by the real
// app-server before a rollout exists, then retry after the process exits.
func replayRejectedNativeStart(ctx context.Context, root, wrapper string, environment map[string]string, adapter *codex.Adapter) error {
	settings := object{"executablePath": wrapper, "model": "gpt-5.4", "serviceTier": "default", "approvalPolicy": "never", "approvalsReviewer": "user", "sandbox": "workspace-write"}
	thread := model.SessionRecord{ID: "real-rejected-start", CreatedAt: time.Now().UnixMilli(), Cwd: filepath.Join(root, "work"), Settings: encoded(settings)}
	store := &memoryStore{}
	state, err := codex.StageExecutionChecked(codex.EmptyState(thread.CreatedAt), "rejected-first-turn", object{"text": "rejected input must not be replayed"}, thread.CreatedAt, settings)
	if err != nil {
		return err
	}
	if err = store.Commit(ctx, encoded(state)); err != nil {
		return err
	}
	server, err := codex.StartAppServer(ctx, codex.LaunchOptions{Executable: wrapper, Cwd: thread.Cwd, Environment: environmentList(environment)})
	if err != nil {
		return err
	}
	native := codex.NewNativeSession(server)
	err = native.Start(ctx, codex.NativeOptions{Cwd: thread.Cwd, Settings: settings}, "rejected-first-turn", nil, func(event codex.Map) {
		_ = store.Commit(ctx, encoded(codex.ReduceEvent(decoded(store.Read()), "rejected-first-turn", event)))
	})
	_ = native.Close()
	if err == nil || !strings.Contains(err.Error(), "Invalid request: invalid type: null, expected a sequence") {
		return fmt.Errorf("expected real pre-turn rejection, got %v", err)
	}
	before := store.Read()
	oldID := text(decoded(before)["primarySessionId"])
	if oldID == "" {
		return fmt.Errorf("rejected first turn did not retain its native thread binding")
	}
	// Persist the same failed resume that occurs when the app is restarted
	// before this repair, so recovery also covers repeated attempts.
	server, err = codex.StartAppServer(ctx, codex.LaunchOptions{Executable: wrapper, Cwd: thread.Cwd, Environment: environmentList(environment)})
	if err != nil {
		return err
	}
	native = codex.NewNativeSession(server)
	_, err = native.Prepare(ctx, codex.NativeOptions{Cwd: thread.Cwd, SessionID: oldID, Settings: settings})
	_ = native.Close()
	if err == nil || !strings.Contains(err.Error(), "no rollout found for thread id "+oldID) {
		return fmt.Errorf("expected missing empty rollout after process exit, got %v", err)
	}
	state, stageErr := codex.StageExecutionChecked(decoded(before), "failed-resume", object{"text": "second rejected input"}, time.Now().UnixMilli(), settings)
	if stageErr != nil {
		return stageErr
	}
	state = codex.ReduceEvent(state, "failed-resume", object{"type": "error", "message": err.Error()})
	state = codex.ReduceEvent(state, "failed-resume", object{"type": "done", "outcome": "failed"})
	before = encoded(state)
	if err = store.Commit(ctx, before); err != nil {
		return err
	}
	// The same missing native ID must not reset a completed conversation or
	// a failure whose native outcome is uncertain.
	for _, scenario := range []string{"completed-history", "uncertain-failure", "inherited-history"} {
		guarded := decoded(before)
		first := record(list(guarded["turns"])[0])
		switch scenario {
		case "completed-history":
			first["status"], first["answer"] = "completed", "Retain this established answer"
			delete(first, "error")
		case "uncertain-failure":
			first["error"] = "Codex app-server exited before acknowledging admission"
		case "inherited-history":
			guarded["forkHistory"] = list(guarded["turns"])
		}
		guardStore := &memoryStore{state: encoded(guarded)}
		guardThread := thread
		guardThread.ID += "-" + scenario
		guardHandle, err := adapter.Open(ctx, plugin.OpenContext{ThreadID: guardThread.ID, ReadThread: func() model.SessionRecord { return guardThread }, SessionState: guardStore})
		if err != nil {
			return err
		}
		err = guardHandle.Send(ctx, plugin.SendRequest{ExecutionID: "guard-" + scenario, Input: model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "Do not reset the missing established session."}}}})
		_ = guardHandle.Close()
		if err == nil || text(decoded(guardStore.Read())["primarySessionId"]) != oldID {
			return fmt.Errorf("missing rollout incorrectly reset %s", scenario)
		}
	}
	thread.SessionState = before
	handle, err := adapter.Open(ctx, plugin.OpenContext{ThreadID: thread.ID, ReadThread: func() model.SessionRecord { return thread }, SessionState: store})
	if err != nil {
		return fmt.Errorf("reopen rejected native start: %w", err)
	}
	defer handle.Close()
	if err = handle.Send(ctx, plugin.SendRequest{ExecutionID: "retry-after-rejection", Input: model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "Return the local scripted response for the new request."}}}}); err != nil {
		return fmt.Errorf("retry rejected native start: %w", err)
	}
	if _, err = awaitExecution(ctx, adapter, store, handle, false); err != nil {
		return err
	}
	after := decoded(store.Read())
	turns := list(after["turns"])
	if text(after["primarySessionId"]) == oldID || len(turns) != 3 || record(turns[0])["status"] != "failed" || record(turns[1])["status"] != "failed" || record(turns[2])["status"] != "completed" {
		return fmt.Errorf("recovery lost failure history or reused the missing native binding")
	}
	fmt.Println("PASS real rejected first turn / missing rollout / new-input retry with both failed audits retained; established, inherited and uncertain histories are never reset")
	return nil
}
func shellQuote(value string) string { return "'" + strings.ReplaceAll(value, "'", "'\\''") + "'" }

const realAnswer = "Local scripted Provider reached the real Codex app-server."

type localProvider struct {
	mu       sync.Mutex
	requests []object
	failures []string
}

func (p *localProvider) snapshot() ([]object, []string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	return append([]object{}, p.requests...), append([]string{}, p.failures...)
}
func (p *localProvider) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost || r.URL.Path != "/v1/responses" {
		p.mu.Lock()
		p.failures = append(p.failures, r.Method+" "+r.URL.Path)
		p.mu.Unlock()
		http.Error(w, "fixture only implements POST /v1/responses", http.StatusNotFound)
		return
	}
	if r.Header.Get("Authorization") != "Bearer local-scripted-provider-only" {
		p.mu.Lock()
		p.failures = append(p.failures, "unexpected authorization")
		p.mu.Unlock()
		http.Error(w, "fixture authorization mismatch", http.StatusUnauthorized)
		return
	}
	body, e := io.ReadAll(io.LimitReader(r.Body, 4*1024*1024))
	if e != nil {
		http.Error(w, e.Error(), 400)
		return
	}
	request := object{}
	if e = json.Unmarshal(body, &request); e != nil {
		http.Error(w, e.Error(), 400)
		return
	}
	p.mu.Lock()
	p.requests = append(p.requests, request)
	requestNumber := len(p.requests)
	p.mu.Unlock()
	if payload := string(encoded(request["input"])); strings.Contains(payload, "native-retry-fixture") && !strings.Contains(payload, "native-retry-successor") {
		// Establish HTTP SSE, then end the response before response.completed.
		// This exercises the installed CLI's actual Responses retry -> error
		// willRetry notifications rather than synthesizing the JSONL payload.
		w.Header().Set("Content-Type", "text/event-stream")
		fmt.Fprint(w, "event: response.created\ndata: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_retry\",\"status\":\"in_progress\",\"output\":[]}}\n\n")
		w.(http.Flusher).Flush()
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("x-request-id", "mokusei-native-fixture-request")
	responseID := fmt.Sprintf("resp_mokusei_native_fixture_%d", requestNumber)
	itemID := fmt.Sprintf("msg_mokusei_native_fixture_%d", requestNumber)
	part := object{"type": "output_text", "text": realAnswer, "annotations": []any{}}
	item := object{"id": itemID, "type": "message", "role": "assistant", "phase": "final_answer", "status": "completed", "content": []any{part}}
	initial := object{"id": responseID, "object": "response", "created_at": time.Now().Unix(), "status": "in_progress", "model": "gpt-5.4", "output": []any{}}
	final := object{"id": responseID, "object": "response", "created_at": time.Now().Unix(), "status": "completed", "model": "gpt-5.4", "output": []any{item}, "usage": object{"input_tokens": 10, "input_tokens_details": object{"cached_tokens": 0}, "output_tokens": 12, "output_tokens_details": object{"reasoning_tokens": 0}, "total_tokens": 22}}
	events := []object{{"type": "response.created", "response": initial}, {"type": "response.output_item.added", "output_index": 0, "item": object{"id": itemID, "type": "message", "role": "assistant", "status": "in_progress", "content": []any{}}}, {"type": "response.content_part.added", "item_id": itemID, "output_index": 0, "content_index": 0, "part": object{"type": "output_text", "text": "", "annotations": []any{}}}, {"type": "response.output_text.delta", "item_id": itemID, "output_index": 0, "content_index": 0, "delta": realAnswer}, {"type": "response.output_text.done", "item_id": itemID, "output_index": 0, "content_index": 0, "text": realAnswer}, {"type": "response.content_part.done", "item_id": itemID, "output_index": 0, "content_index": 0, "part": part}, {"type": "response.output_item.done", "output_index": 0, "item": item}, {"type": "response.completed", "response": final}}

	if strings.Contains(string(encoded(request["input"])), "native-mcp-fixture") && !hasToolResult(request["input"]) {
		name, namespace := findTool(request["tools"], "")
		if name == "" {
			p.mu.Lock()
			p.failures = append(p.failures, "injected tool definition missing")
			p.mu.Unlock()
			http.Error(w, "injected tool definition missing", 400)
			return
		}
		arguments := string(encoded(object{"text": "native tool works"}))
		call := object{"id": "fc_native_fixture", "type": "function_call", "call_id": "call_native_fixture", "name": name, "namespace": namespace, "arguments": arguments, "status": "completed"}
		final["output"] = []any{call}
		events = []object{{"type": "response.created", "response": initial}, {"type": "response.output_item.added", "output_index": 0, "item": object{"id": "fc_native_fixture", "type": "function_call", "call_id": "call_native_fixture", "name": name, "namespace": namespace, "arguments": "", "status": "in_progress"}}, {"type": "response.function_call_arguments.delta", "item_id": "fc_native_fixture", "output_index": 0, "delta": arguments}, {"type": "response.function_call_arguments.done", "item_id": "fc_native_fixture", "output_index": 0, "arguments": arguments}, {"type": "response.output_item.done", "output_index": 0, "item": call}, {"type": "response.completed", "response": final}}
	}
	for sequence, event := range events {
		event["sequence_number"] = sequence
		_, _ = fmt.Fprintf(w, "event: %s\ndata: %s\n\n", event["type"], encoded(event))
		if f, ok := w.(http.Flusher); ok {
			f.Flush()
		}
	}
}

func hasToolResult(value any) bool {
	for _, v := range list(value) {
		item := record(v)
		if item["type"] == "function_call_output" && item["call_id"] == "call_native_fixture" {
			return true
		}
	}
	return false
}
func findTool(value any, namespace string) (string, string) {
	for _, v := range list(value) {
		tool := record(v)
		if name := text(tool["name"]); strings.Contains(name, "echo_fixture") {
			return name, namespace
		}
		childNamespace := namespace
		if tool["type"] == "namespace" {
			childNamespace = text(tool["name"])
		}
		if name, ns := findTool(tool["tools"], childNamespace); name != "" {
			return name, ns
		}
	}
	return "", ""
}

func findNativeToolSchema(value any, name string) object {
	for _, raw := range list(value) {
		tool := record(raw)
		if strings.Contains(text(tool["name"]), name) {
			return record(tool["parameters"])
		}
		if schema := findNativeToolSchema(tool["tools"], name); len(schema) > 0 {
			return schema
		}
	}
	return object{}
}

func containsText(value any, wanted string) bool {
	for _, raw := range list(value) {
		if raw == wanted {
			return true
		}
	}
	return false
}
