package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/hupao-creator/Mokusei/tools/verification/firstresponse"
	"os"
	"os/exec"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/claude"
)

func main() {
	if len(os.Args) > 1 && os.Args[1] == "claude-mcp" {
		must(claude.ServeMCP(context.Background(), os.Stdin, os.Stdout, claude.MCPOptionsFromEnvironment()))
		return
	}
	if os.Getenv("CLAUDE_FIXTURE") == "1" {
		native()
		return
	}
	if len(os.Args) > 1 && os.Args[1] == "-settings-performance" {
		verifySettingsPerformance()
		return
	}
	verify()
}
func must(e error) {
	if e != nil {
		panic(e)
	}
}

var outputMu sync.Mutex

func send(v any) {
	outputMu.Lock()
	defer outputMu.Unlock()
	b, _ := json.Marshal(v)
	fmt.Println(string(b))
}

// nativeArgument returns the last value supplied for a Claude CLI flag.
func nativeArgument(name string) string {
	value := ""
	for i, argument := range os.Args {
		if argument == name && i+1 < len(os.Args) {
			value = os.Args[i+1]
		} else if strings.HasPrefix(argument, name+"=") {
			value = strings.TrimPrefix(argument, name+"=")
		}
	}
	return value
}

// nativeAppliedEffort models the precedence observed in Claude Code: a
// CLAUDE_CODE_EFFORT_LEVEL inherited from settings wins over --effort unless
// the session settings environment masks that key. Session settings are the
// highest-priority CLI layer, so an empty value still masks the inherited one.
func nativeAppliedEffort() string {
	selected := nativeArgument("--effort")
	masked := false
	if raw := nativeArgument("--settings"); raw != "" {
		var settings struct {
			Environment map[string]any `json:"env"`
		}
		if json.Unmarshal([]byte(raw), &settings) == nil {
			_, masked = settings.Environment["CLAUDE_CODE_EFFORT_LEVEL"]
		}
	}
	inherited := os.Getenv("CLAUDE_FIXTURE_INHERITED_EFFORT")
	if inherited != "" && (!masked || os.Getenv("CLAUDE_FIXTURE_IGNORE_MASK") == "1") {
		return inherited
	}
	return selected
}

func native() {
	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 4096), 4<<20)
	var delayed string
	pending := map[string]string{}
	for scanner.Scan() {
		var f map[string]any
		must(json.Unmarshal(scanner.Bytes(), &f))
		switch f["type"] {
		case "control_request":
			r := f["request"].(map[string]any)
			result := map[string]any{}
			switch r["subtype"] {
			case "initialize":
				if root := os.Getenv("CLAUDE_SETTINGS_PERFORMANCE"); root != "" {
					must(os.WriteFile(fmt.Sprintf("%s/start-%d", root, os.Getpid()), nil, 0600))
					time.Sleep(200 * time.Millisecond)
				}
				result = map[string]any{"models": []any{map[string]any{"value": "claude-fixture", "displayName": "Fixture", "supportedEffortLevels": []string{"low", "high"}}}, "claudeVersion": "fixture"}
				if os.Getenv("CLAUDE_SETTINGS_IDENTITY") == "1" {
					data, err := os.ReadFile(os.Getenv("CLAUDE_CONFIG_DIR") + "/settings.json")
					must(err)
					result["models"].([]any)[0].(map[string]any)["value"] = string(data)
				}
				if os.Getenv("CLAUDE_FIXTURE_EFFORT_DISABLED") == "1" {
					result["models"].([]any)[0].(map[string]any)["supportsEffort"] = false
				}
				if os.Getenv("CLAUDE_ALIAS_CATALOG_FIXTURE") == "1" {
					result = map[string]any{"models": []any{map[string]any{"value": "default", "supportedEffortLevels": []string{"low", "high"}}, map[string]any{"value": "haiku", "supportedEffortLevels": []string{"low", "high"}}}, "claudeVersion": "fixture"}
				}
			case "get_settings":
				result = map[string]any{"applied": map[string]any{"model": "claude-fixture", "effort": nativeAppliedEffort()}}
				if os.Getenv("CLAUDE_ALIAS_CATALOG_FIXTURE") == "1" {
					result = map[string]any{"applied": map[string]any{"model": "claude-haiku-5-5", "effort": nativeAppliedEffort()}}
				}
			case "get_usage":
				result = map[string]any{"subscription_type": "fixture", "rate_limits_available": true, "rate_limits": map[string]any{"five_hour": map[string]any{"utilization": 25, "resets_at": "2030-01-01T01:00:00Z"}}}
			}
			send(map[string]any{"type": "control_response", "response": map[string]any{"subtype": "success", "request_id": f["request_id"], "response": result}})
			if r["subtype"] == "interrupt" && delayed != "" {
				finish(delayed, "interrupted")
				delayed = ""
			}
		case "user":
			id := f["uuid"].(string)
			send(f)
			message := f["message"].(map[string]any)
			text, _ := message["content"].(string)
			if strings.Contains(text, "question") {
				pending["ask-1"] = id
				question := map[string]any{"question": "Pick", "multiSelect": false, "options": []any{map[string]any{"label": "A"}, map[string]any{"label": "B"}}}
				request := map[string]any{"subtype": "can_use_tool", "tool_name": "AskUserQuestion", "tool_use_id": "question-call", "input": map[string]any{"questions": []any{question}}}
				send(map[string]any{"type": "control_request", "request_id": "ask-1", "request": request})
				continue
			}
			if strings.Contains(text, "wrong-session") {
				send(map[string]any{"type": "system", "subtype": "init", "session_id": "different-session", "cwd": "/wrong"})
				continue
			}
			if strings.Contains(text, "crash") {
				child := exec.Command("/bin/sleep", "30")
				child.Stdout = os.Stdout
				child.Stderr = os.Stderr
				must(child.Start())
				must(os.WriteFile(os.Getenv("CLAUDE_CONFIG_DIR")+"/descendant-pid", []byte(fmt.Sprint(child.Process.Pid)), 0600))
				os.Exit(4)
			}
			if strings.Contains(text, "long") {
				delayed = id
				stream(id, "waiting")
				continue
			}
			if delayed != "" {
				finish(delayed, "completed")
				delayed = ""
			}
			if strings.Contains(text, "background") {
				send(map[string]any{"type": "system", "subtype": "background_tasks_changed", "tasks": []any{map[string]any{"task_id": "bg", "description": "work", "status": "running"}}})
			}
			stream(id, "answer")
			finish(id, "completed")
			if strings.Contains(text, "background") {
				go func() {
					time.Sleep(80 * time.Millisecond)
					send(map[string]any{"type": "system", "subtype": "task_notification", "task_id": "bg", "status": "completed", "summary": "done"})
					send(map[string]any{"type": "user", "uuid": "native-wake", "message": map[string]any{"role": "user", "content": "task finished"}, "origin": map[string]any{"kind": "task-notification"}, "parent_tool_use_id": nil})
					stream("native-wake", "background answer")
					finish("native-wake", "completed")
				}()
			}
		case "control_response":
			r := f["response"].(map[string]any)
			id, _ := r["request_id"].(string)
			if user := pending[id]; user != "" {
				p := r["response"].(map[string]any)
				input := p["updatedInput"].(map[string]any)
				answers := input["answers"].(map[string]any)
				if answers["Pick"] != "B" {
					panic("question mapping")
				}
				stream(user, "chosen B")
				finish(user, "completed")
				delete(pending, id)
			}
		}
	}
}
func stream(id, text string) {
	send(map[string]any{"type": "stream_event", "event": map[string]any{"type": "message_start", "message": map[string]any{"id": "assistant-" + id, "model": "claude-fixture", "usage": map[string]any{"input_tokens": 10}}}})
	send(map[string]any{"type": "stream_event", "event": map[string]any{"type": "content_block_delta", "delta": map[string]any{"type": "thinking_delta", "thinking": "consider"}}})
	send(map[string]any{"type": "stream_event", "event": map[string]any{"type": "content_block_delta", "delta": map[string]any{"type": "text_delta", "text": text}}})
	send(map[string]any{"type": "stream_event", "event": map[string]any{"type": "message_delta", "usage": map[string]any{"output_tokens": 2}}})
	send(map[string]any{"type": "stream_event", "event": map[string]any{"type": "message_stop"}})
}
func finish(id, status string) {
	send(map[string]any{"type": "result", "user_message_uuid": id, "subtype": "success", "result": "must not duplicate", "modelUsage": map[string]any{"claude-fixture": map[string]any{"costUSD": 0.01}}})
}

type store struct {
	mu    sync.Mutex
	state json.RawMessage
}

func (s *store) Read() json.RawMessage {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append(json.RawMessage{}, s.state...)
}
func (s *store) Commit(ctx context.Context, r json.RawMessage) error {
	if e := ctx.Err(); e != nil {
		return e
	}
	if _, e := claude.ParseState(r); e != nil {
		return e
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.state = append(json.RawMessage{}, r...)
	return nil
}

type ledger struct {
	mu      sync.Mutex
	samples []map[string]any
}

func (l *ledger) Record(ctx context.Context, raw json.RawMessage) error {
	var v map[string]any
	must(json.Unmarshal(raw, &v))
	if v["type"] != "execution-usage" && v["type"] != "window-reading" {
		return errors.New("invalid telemetry sample")
	}
	l.mu.Lock()
	l.samples = append(l.samples, v)
	l.mu.Unlock()
	return nil
}
func (l *ledger) Read(context.Context) (json.RawMessage, error) {
	return json.RawMessage(`{"windows":[]}`), nil
}

type admission struct{ s *store }

func (a admission) Accept(ctx context.Context, f func(string) (json.RawMessage, error)) (string, error) {
	r, e := f("native-admitted")
	if e != nil {
		return "", e
	}
	return "native-admitted", a.s.Commit(ctx, r)
}
func verify() {
	_, initialErr := firstresponse.Verify("claude")
	must(initialErr)
	verifyConditionalSchemas()
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	exe, e := os.Executable()
	must(e)
	cwd, e := os.MkdirTemp("", "claude-protocol-fixture-")
	must(e)
	defer os.RemoveAll(cwd)
	verifyEffortSnapshot(ctx, exe, cwd)
	verifyNativeCatalog(ctx, exe, cwd)
	verifySettingsIdentity(ctx, exe)
	h := claude.New(plugin.HostContext{ResolveExecutable: func(context.Context, string, string, string) (string, error) { return exe, nil }, Environment: func(context.Context) (map[string]string, error) {
		return map[string]string{"CLAUDE_FIXTURE": "1", "CLAUDE_CONFIG_DIR": cwd, "PATH": os.Getenv("PATH")}, nil
	}, TemporaryWorkspaceRoot: cwd})
	settings := json.RawMessage(`{"executablePath":"claude","model":"claude-fixture","thinking":{"mode":"effort","effort":"high"},"effort":"high","permissionMode":"auto"}`)
	state := &store{state: json.RawMessage(`null`)}
	usage := &ledger{}
	record := model.SessionRecord{ID: "t", HarnessID: "claude", Cwd: cwd, Settings: settings}
	handle, e := h.Open(ctx, plugin.OpenContext{ThreadID: "t", ReadThread: func() model.SessionRecord { return record }, SessionState: state, TelemetryLedger: usage, RequireExplicitSettings: true, ExecutionAdmission: admission{state}})
	must(e)
	defer handle.Close()
	submit := func(id, text string) {
		admitted := 0
		must(handle.Send(ctx, plugin.SendRequest{ExecutionID: id, Input: model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: text}}}, Admitted: func() error {
			admitted++
			s, e := claude.ParseState(state.Read())
			must(e)
			if s.Find(id) == nil {
				panic("admitted before durable input")
			}
			return nil
		}}))
		if admitted != 1 {
			panic("input admission callback count")
		}
	}
	wait := func(id, status string) model.PublicObservation {
		deadline := time.Now().Add(5 * time.Second)
		for time.Now().Before(deadline) {
			o, e := h.SessionState().Project(state.Read())
			must(e)
			if o.LatestExecution != nil && o.LatestExecution.ExecutionID == id && o.LatestExecution.Status == status {
				return o
			}
			time.Sleep(10 * time.Millisecond)
		}
		panic(string(state.Read()))
	}
	submit("one", "hello")
	wait("one", "completed")
	s, e := claude.ParseState(state.Read())
	must(e)
	if s.Turns[0].Text != "answer" {
		panic("duplicate fallback: " + s.Turns[0].Text)
	}
	if s.Turns[0].Usage["inputTokens"] != float64(10) {
		panic("usage")
	}
	if s.Turns[0].Timeline[0]["checkpointId"] == nil {
		panic("checkpoint")
	}
	submit("two", "question")
	o := wait("two", "waiting-for-user")
	i := o.LatestExecution.Interactions[0]
	q := i.Questions[0]
	b, _ := json.Marshal(q.Options[1].Value)
	if err := handle.Respond(ctx, model.RespondRequest{ExecutionID: "stale-execution", InteractionID: i.ID, ActionID: "submit", Answers: map[string]json.RawMessage{q.ID: b}}); err == nil {
		panic("stale execution answered Claude interaction")
	}
	must(handle.Respond(ctx, model.RespondRequest{ExecutionID: o.LatestExecution.ExecutionID, InteractionID: i.ID, ActionID: "submit", Answers: map[string]json.RawMessage{q.ID: b}}))
	wait("two", "completed")
	submit("three", "long")
	submit("three", "follow-up")
	wait("three", "completed")
	submit("four", "long")
	must(handle.Interrupt(ctx))
	wait("four", "interrupted")
	submit("five", "background")
	wait("native-admitted", "completed")
	o, e = h.SessionState().Project(state.Read())
	must(e)
	if o.BackgroundWork != nil {
		panic("stale background")
	}
	source := model.ThreadRecord{SessionRecord: record}
	source.SessionState = state.Read()
	fork, e := h.Fork(ctx, plugin.ForkRequest{Source: source})
	must(e)
	fs, e := claude.ParseState(fork.SessionState)
	must(e)
	if fs.PendingFork == nil || len(fs.Turns) != 0 {
		panic("fork")
	}
	answer, e := handle.Read(ctx, "what happened")
	must(e)
	if answer != "answer" {
		panic("read: " + answer)
	}
	_, e = h.Complete(ctx, plugin.PromptRequest{Messages: []plugin.PromptMessage{{Role: "user", Content: "hello"}}, OutputFormat: plugin.PromptOutputFormat{Type: "text"}, Settings: json.RawMessage(`{"model":"claude-fixture","effort":"high"}`)})
	must(e)
	verifyPromptSteering(ctx, h)
	telemetry, e := h.MokuContext(ctx, "telemetry", plugin.SettingsRequest{Settings: h.DefaultSettings(), Cwd: cwd}, usage)
	must(e)
	var report map[string]any
	must(json.Unmarshal([]byte(telemetry), &report))
	if report["namespace"] != "claude" || report["availability"] != "available" {
		panic(telemetry)
	}
	usage.mu.Lock()
	if len(usage.samples) < 2 {
		panic("usage ledger missing")
	}
	usage.mu.Unlock()
	deferred, e := h.SessionState().ProjectRenderer(state.Read(), model.RendererScope{Kind: "turn", Key: "one"})
	must(e)
	var envelope map[string]any
	must(json.Unmarshal(deferred, &envelope))
	if envelope["kind"] != "deferred-execution" {
		panic("missing deferred projection")
	}
	discussion, e := h.PrepareDiscussion(ctx, plugin.DiscussionRequest{Source: source, Instructions: "Read only"})
	must(e)
	reply, e := discussion.Ask(ctx, "hello")
	must(e)
	if reply != "answer" {
		panic("discussion")
	}
	must(discussion.Close())
	submit("crash-exec", "crash")
	wait("crash-exec", "failed")
	data, e := os.ReadFile(cwd + "/descendant-pid")
	must(e)
	var pid int
	_, e = fmt.Sscan(string(data), &pid)
	must(e)
	deadline := time.Now().Add(3 * time.Second)
	for syscall.Kill(pid, 0) == nil && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	if syscall.Kill(pid, 0) == nil {
		panic("orphaned descendant")
	}
	submit("recovered", "hello")
	wait("recovered", "completed")
	submit("wrong-session-exec", "wrong-session")
	wait("wrong-session-exec", "failed")
	current, e := claude.ParseState(state.Read())
	must(e)
	if current.PrimarySessionID == "different-session" {
		panic("replaced primary session binding")
	}
	must(handle.Close())
	handle2, e := h.Open(ctx, plugin.OpenContext{ThreadID: "t", ReadThread: func() model.SessionRecord { return record }, SessionState: state})
	must(e)
	must(handle2.Send(ctx, plugin.SendRequest{ExecutionID: "close-race", Input: model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "long"}}}}))
	var race sync.WaitGroup
	race.Add(2)
	go func() { defer race.Done(); _ = handle2.Interrupt(ctx) }()
	go func() { defer race.Done(); must(handle2.Close()) }()
	race.Wait()
	must(handle2.Close())
	if err := handle.Send(ctx, plugin.SendRequest{ExecutionID: "after"}); err == nil {
		panic("closed send succeeded")
	}
	verifyMCP(ctx, exe)
	must(ctx.Err())
	fmt.Println("Claude real stream-json fixture passed: catalog, exact settings, text dedupe, usage, questions, steering, interrupt, native wake, fork, read, prompt, telemetry, deferred content, discussion, descendant cleanup, recovery, session fencing, concurrent close/interrupt, Go MCP tool bridge")
}

func verifyMCP(ctx context.Context, exe string) {
	cancelled := make(chan struct{}, 1)
	bridge, e := claude.NewToolBridge(exe, []plugin.ToolBinding{
		{Name: "echo", Description: "Echo fixture arguments", InputSchema: json.RawMessage(`{"type":"object","properties":{"value":{"type":"string"}},"required":["value"]}`), Execute: func(_ context.Context, call plugin.ToolCall) (json.RawMessage, error) { return call.Arguments, nil }},
		{Name: "slow", Description: "Wait for cancellation", InputSchema: json.RawMessage(`{"type":"object"}`), Execute: func(ctx context.Context, _ plugin.ToolCall) (json.RawMessage, error) {
			<-ctx.Done()
			cancelled <- struct{}{}
			return nil, ctx.Err()
		}},
	})
	must(e)
	defer bridge.Close()
	configuration := bridge.Configuration()["mcpServers"].(map[string]any)["mokusei"].(map[string]any)
	command := exec.CommandContext(ctx, exe, "claude-mcp")
	for key, value := range configuration["env"].(map[string]string) {
		command.Env = append(command.Env, key+"="+value)
	}
	input, e := command.StdinPipe()
	must(e)
	output, e := command.StdoutPipe()
	must(e)
	must(command.Start())
	defer command.Process.Kill()
	encoder := json.NewEncoder(input)
	decoder := json.NewDecoder(output)
	request := func(id int, method string, params any) map[string]any {
		must(encoder.Encode(map[string]any{"jsonrpc": "2.0", "id": id, "method": method, "params": params}))
		var response map[string]any
		must(decoder.Decode(&response))
		return response
	}
	init := request(1, "initialize", map[string]any{"protocolVersion": "2025-06-18"})
	if init["error"] != nil {
		panic("MCP initialize")
	}
	listed := request(2, "tools/list", map[string]any{})
	result := listed["result"].(map[string]any)
	if len(result["tools"].([]any)) != 2 {
		panic("MCP tool definitions")
	}
	denied := request(3, "tools/call", map[string]any{"name": "echo", "arguments": map[string]any{"value": "inactive"}})
	if denied["result"].(map[string]any)["isError"] != true {
		panic("inactive MCP dispatch")
	}
	execution, cancel := context.WithCancel(ctx)
	defer cancel()
	must(bridge.Activate(execution))
	echoed := request(4, "tools/call", map[string]any{"name": "echo", "arguments": map[string]any{"value": "roundtrip"}})
	value := echoed["result"].(map[string]any)["structuredContent"].(map[string]any)
	if value["value"] != "roundtrip" {
		panic("MCP roundtrip")
	}
	must(encoder.Encode(map[string]any{"jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": map[string]any{"name": "slow", "arguments": map[string]any{}}}))
	time.Sleep(50 * time.Millisecond)
	bridge.Deactivate()
	select {
	case <-cancelled:
	case <-time.After(time.Second):
		panic("MCP execution cancellation")
	}
	must(input.Close())
	done := make(chan error, 1)
	go func() { done <- command.Wait() }()
	select {
	case err := <-done:
		must(err)
	case <-time.After(2 * time.Second):
		panic("MCP child did not exit")
	}
}
