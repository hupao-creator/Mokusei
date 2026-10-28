package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/platform/sqlite"
	oc "github.com/hupao-creator/Mokusei/internal/plugins/harness/opencode"
	"github.com/hupao-creator/Mokusei/internal/services/threadvoice"
	"github.com/hupao-creator/Mokusei/tools/verification/discussioncheck"
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

type store struct {
	mu      sync.Mutex
	raw     json.RawMessage
	commits int
}

func (s *store) Read() json.RawMessage {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append(json.RawMessage{}, s.raw...)
}
func (s *store) Commit(ctx context.Context, raw json.RawMessage) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.raw = append(json.RawMessage{}, raw...)
	s.commits++
	return nil
}

type automaticAdmission struct {
	state *store
	next  atomic.Int64
}

func (a *automaticAdmission) Accept(ctx context.Context, project func(string) (json.RawMessage, error)) (string, error) {
	id := fmt.Sprintf("automatic-%d", a.next.Add(1))
	raw, err := project(id)
	if err != nil {
		return "", err
	}
	if err = a.state.Commit(ctx, raw); err != nil {
		return "", err
	}
	return id, nil
}

func must(err error) {
	if err != nil {
		panic(err)
	}
}
func check(ok bool, text string) {
	if !ok {
		panic(text)
	}
}
func wait(ctx context.Context, s *store, execution string) {
	for {
		state, err := oc.DecodeState(s.Read())
		must(err)
		for _, e := range state.Executions {
			if e.ExecutionID == execution && e.Terminal() {
				if e.Status != "completed" {
					encoded, _ := json.Marshal(e)
					panic(string(encoded))
				}
				return
			}
		}
		select {
		case <-ctx.Done():
			panic(ctx.Err())
		case <-time.After(20 * time.Millisecond):
		}
	}
}

// Public completion can arrive over SSE before the asynchronous durable export.
// Freeze only after that export contains the completed execution, so a later
// background reconciliation cannot be mistaken for a mutation caused by Read.
func waitNativeSnapshot(ctx context.Context, s *store, execution string) json.RawMessage {
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	for {
		raw := s.Read()
		state, err := oc.DecodeState(raw)
		must(err)
		var finished int64
		for _, e := range state.Executions {
			if e.ExecutionID == execution && e.Status == "completed" && e.FinishedAt != nil {
				finished = *e.FinishedAt
			}
		}
		info, _ := state.NativeTranscript["info"].(map[string]any)
		nativeTime, _ := info["time"].(map[string]any)
		idle, _ := nativeTime["idle"].(float64)
		if finished > 0 && info["id"] == state.NativeSessionID && info["outcome"] == "succeeded" && int64(idle) >= finished {
			messages, _ := state.NativeTranscript["messages"].([]any)
			seenInput := false
			for _, value := range messages {
				message, _ := value.(map[string]any)
				metadata, _ := message["metadata"].(map[string]any)
				if message["type"] == "user" && metadata["mokuseiExecutionId"] == execution {
					seenInput = true
				}
				messageTime, _ := message["time"].(map[string]any)
				created, _ := messageTime["created"].(float64)
				if seenInput && message["type"] == "idle" && message["outcome"] == "succeeded" && int64(created) >= finished {
					return raw
				}
			}
		}
		select {
		case <-ctx.Done():
			panic(fmt.Sprintf("native snapshot for %s did not settle: %v", execution, ctx.Err()))
		case <-time.After(20 * time.Millisecond):
		}
	}
}

func main() {
	parent, stopSignal := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stopSignal()
	nativeCLI := os.Getenv("MOKUSEI_OPENCODE_NATIVE_CLI")
	if nativeCLI == "" {
		panic("native replay requires explicit -native-cli via the verification runner")
	}
	root, err := os.MkdirTemp("", "opencode-thread-replay-")
	must(err)
	defer os.RemoveAll(root)
	cwd := filepath.Join(root, "workspace")
	must(os.MkdirAll(cwd, 0700))
	discussionHolding := make(chan struct{}, 1)
	cancelReadStarted := make(chan struct{}, 1)
	cancelReadStopped := make(chan struct{}, 1)
	activeSourceStarted := make(chan struct{})
	releaseActiveSource := make(chan struct{})
	var activeSourceGated atomic.Bool
	isolatedStarted := make(chan struct{})
	releaseIsolated := make(chan struct{})
	var isolatedGated atomic.Bool
	var requests atomic.Int32
	var tools atomic.Int32
	var captureMu sync.Mutex
	var primary, reading map[string]any
	var primaryAffinity, readAffinity string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/chat/completions" {
			http.NotFound(w, r)
			return
		}
		var body map[string]any
		must(json.NewDecoder(r.Body).Decode(&body))
		requests.Add(1)
		called := false
		for _, raw := range body["messages"].([]any) {
			if raw.(map[string]any)["role"] == "tool" {
				called = true
			}
		}
		withTool := ""
		if declared, ok := body["tools"].([]any); ok {
			for _, raw := range declared {
				tool := raw.(map[string]any)
				if name := tool["function"].(map[string]any)["name"]; name == "fixture_echo" || name == "__proto__" {
					withTool = name.(string)
				}
			}
		}
		requestText, _ := json.Marshal(body["messages"])
		captureMu.Lock()
		if strings.Contains(string(requestText), "Question: What was returned?") {
			reading = body
			readAffinity = r.Header.Get("x-session-affinity")
		} else if reading == nil {
			primary = body
			primaryAffinity = r.Header.Get("x-session-affinity")
		}
		captureMu.Unlock()
		if strings.Contains(string(requestText), "CANCEL_READ_MARKER") {
			cancelReadStarted <- struct{}{}
			<-r.Context().Done()
			cancelReadStopped <- struct{}{}
			return
		}
		if strings.Contains(string(requestText), "ACTIVE_SOURCE_MARKER") && activeSourceGated.CompareAndSwap(false, true) {
			close(activeSourceStarted)
			select {
			case <-releaseActiveSource:
			case <-r.Context().Done():
				return
			}
		}
		if strings.Contains(string(requestText), "ISOLATED_INITIAL_MARKER") && isolatedGated.CompareAndSwap(false, true) {
			close(isolatedStarted)
			select {
			case <-releaseIsolated:
			case <-r.Context().Done():
				return
			}
		}
		if strings.Contains(string(requestText), "DISCUSSION_") {
			discussionReply(w, r, body, cwd, discussionHolding)
			return
		}
		permission := strings.Contains(string(requestText), "PERMISSION_MARKER")
		delta := map[string]any{"role": "assistant", "content": `{"reply":"fixture"}`}
		if strings.Contains(string(requestText), "ISOLATED_UPDATE_MARKER") {
			delta["content"] = `{"reply":"steered"}`
		}
		finish := "stop"
		if withTool != "" && !called {
			delta = map[string]any{"role": "assistant", "tool_calls": []any{map[string]any{"index": 0, "id": "call_fixture", "type": "function", "function": map[string]any{"name": withTool, "arguments": `{"value":"hello"}`}}}}
			finish = "tool_calls"
		}
		if permission && !called {
			delta = map[string]any{"role": "assistant", "tool_calls": []any{map[string]any{"index": 0, "id": "call_permission", "type": "function", "function": map[string]any{"name": "shell", "arguments": `{"command":"printf permission-fixture","description":"Print fixture"}`}}}}
			finish = "tool_calls"
		}
		w.Header().Set("Content-Type", "text/event-stream")
		f := w.(http.Flusher)
		chunks := []any{map[string]any{"id": fmt.Sprintf("chat_%d", requests.Load()), "object": "chat.completion.chunk", "created": time.Now().Unix(), "model": "fixture-model", "choices": []any{map[string]any{"index": 0, "delta": delta, "finish_reason": nil}}}, map[string]any{"id": "chat_end", "object": "chat.completion.chunk", "created": time.Now().Unix(), "model": "fixture-model", "choices": []any{map[string]any{"index": 0, "delta": map[string]any{}, "finish_reason": finish}}, "usage": map[string]any{"prompt_tokens": 12, "completion_tokens": 3, "total_tokens": 15}}}
		for _, chunk := range chunks {
			b, _ := json.Marshal(chunk)
			fmt.Fprintf(w, "data: %s\n\n", b)
			f.Flush()
		}
		fmt.Fprint(w, "data: [DONE]\n\n")
		f.Flush()
	}))
	defer server.Close()
	config := oc.Object{"permissions": []oc.Object{{"action": "shell", "resource": "*", "effect": "ask"}}, "model": oc.Object{"providerID": "fixture", "model": "fixture-model"}, "providers": oc.Object{"fixture": oc.Object{"name": "Fixture", "package": "@opencode/ai/providers/openai-compatible", "settings": oc.Object{"baseURL": server.URL + "/v1", "apiKey": "synthetic-only"}, "models": oc.Object{"fixture-model": oc.Object{"name": "Fixture", "modelID": "fixture-model", "capabilities": oc.Object{"tools": true, "input": []string{"text"}, "output": []string{"text"}}, "limit": oc.Object{"context": 32000, "output": 1024}}}}}}
	encoded, _ := json.Marshal(config)
	env := map[string]string{"PATH": os.Getenv("PATH"), "HOME": root, "XDG_DATA_HOME": filepath.Join(root, "data"), "XDG_CONFIG_HOME": filepath.Join(root, "config"), "XDG_CACHE_HOME": filepath.Join(root, "cache"), "XDG_STATE_HOME": filepath.Join(root, "state"), "OPENCODE_TEST_HOME": root, "OPENCODE_CONFIG_PROJECT_DISABLE": "1", "OPENCODE_DISABLE_MODELS_FETCH": "1", "OPENCODE_CONFIG_CONTENT": string(encoded)}
	host := plugin.HostContext{HarnessDataRoot: filepath.Join(root, "harness"), TemporaryWorkspaceRoot: filepath.Join(root, "temporary"), Environment: func(context.Context) (map[string]string, error) {
		copy := map[string]string{}
		for k, v := range env {
			copy[k] = v
		}
		return copy, nil
	}, ResolveExecutable: func(context.Context, string, string, string) (string, error) {
		return nativeCLI, nil
	}}
	h := oc.New(host)
	defer h.Close()
	ctx, cancel := context.WithTimeout(parent, 180*time.Second)
	defer cancel()
	settings := json.RawMessage(`{"provider":"fixture","model":"fixture-model","thinking":{"mode":"effort","effort":"low"},"variant":"low","permissionMode":"auto"}`)
	mkOpen := func(id string, s *store, injection *plugin.Injection) plugin.OpenContext {
		return plugin.OpenContext{ThreadID: id, SessionState: s, RequireExplicitSettings: true, ReadThread: func() model.SessionRecord {
			return model.SessionRecord{ID: id, HarnessID: "opencode", Cwd: cwd, Settings: settings}
		}, Injection: injection}
	}
	state := &store{}
	handle, err := h.Open(ctx, mkOpen("thread", state, nil))
	must(err)
	defer handle.Close()
	admitted := 0
	must(handle.Send(ctx, plugin.SendRequest{ExecutionID: "e1", Input: model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "Return fixture JSON."}}}, Admitted: func() error {
		admitted++
		check(strings.Contains(string(state.Read()), "Return fixture JSON"), "admission before durable input")
		return nil
	}}))
	wait(ctx, state, "e1")
	must(os.WriteFile(filepath.Join(cwd, "AGENTS.md"), []byte("Fixture instructions updated after source admission. Answer history questions without executing tools."), 0600))
	must(handle.Send(ctx, plugin.SendRequest{ExecutionID: "e2", Input: model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "Again."}}}, Admitted: func() error { admitted++; return nil }}))
	wait(ctx, state, "e2")
	check(admitted == 2, "send admission count")
	beforeRead := waitNativeSnapshot(ctx, state, "e2")
	answer, err := handle.Read(ctx, "What was returned?")
	must(err)
	check(strings.Contains(answer, "fixture"), "read answer")
	if string(beforeRead) != string(state.Read()) {
		var a, b map[string]json.RawMessage
		must(json.Unmarshal(beforeRead, &a))
		must(json.Unmarshal(state.Read(), &b))
		changed := []string{}
		for key, value := range b {
			if string(a[key]) != string(value) {
				changed = append(changed, key)
			}
		}
		must(os.WriteFile(filepath.Join(os.TempDir(), "mokusei-voice-read-before.json"), beforeRead, 0600))
		must(os.WriteFile(filepath.Join(os.TempDir(), "mokusei-voice-read-after.json"), state.Read(), 0600))
		panic(fmt.Sprintf("read changed source durable state fields: %v", changed))
	}
	captureMu.Lock()
	check(primaryAffinity != "" && readAffinity == primaryAffinity, fmt.Sprintf("read lost native cache affinity: primary=%q read=%q", primaryAffinity, readAffinity))
	for _, key := range []string{"model", "tools", "prompt_cache_key"} {
		a, _ := json.Marshal(primary[key])
		b, _ := json.Marshal(reading[key])
		check(string(a) == string(b), "read changed provider prefix field: "+key)
	}
	sourceMessages := primary["messages"].([]any)
	readMessages := reading["messages"].([]any)
	check(len(readMessages) > len(sourceMessages), "read lost source history")
	for i, message := range sourceMessages {
		a, _ := json.Marshal(message)
		b, _ := json.Marshal(readMessages[i])
		check(string(a) == string(b), fmt.Sprintf("read changed provider history prefix at %d", i))
	}
	captureMu.Unlock()
	countNativeSessions := func() int {
		db, err := sqlite.Open(filepath.Join(root, "data", "opencode", "opencode.db"), true)
		must(err)
		defer db.Close()
		rows, err := db.Query("SELECT id FROM session_v2")
		must(err)
		return len(rows)
	}
	check(countNativeSessions() == 1, "successful native fork read left a temporary native session")
	discussionTools, closeTools, err := threadvoice.ProjectReadTools(cwd)
	must(err)
	defer closeTools()
	must(os.WriteFile(filepath.Join(cwd, "discussion-proof.txt"), []byte("project-read-canary"), 0600))
	discussionFrozen := state.Read()
	sourceState, err := oc.DecodeState(discussionFrozen)
	must(err)
	inspector, err := oc.NewRuntime(ctx, oc.Options{CWD: cwd, ExecutablePath: nativeCLI, Environment: env, Config: config})
	must(err)
	must(inspector.ConfigureSession(ctx, sourceState.NativeSessionID, oc.BridgeConfiguration{}))
	sourceBefore, err := inspector.Snapshot(ctx, sourceState.NativeSessionID)
	must(err)
	verifyDiscussion := func(private bool) error {
		expected := 1
		if private {
			expected++
		}
		check(countNativeSessions() == expected, "discussion leaked or reused native session")
		check(string(state.Read()) == string(discussionFrozen), "discussion changed source Thread state")
		sourceAfter, err := inspector.Snapshot(ctx, sourceState.NativeSessionID)
		if err != nil {
			return err
		}
		a, _ := json.Marshal(sourceBefore)
		b, _ := json.Marshal(sourceAfter)
		check(string(a) == string(b), "discussion changed native source history")
		_, err = os.Stat(filepath.Join(cwd, "discussion-must-not-exist.txt"))
		check(errors.Is(err, os.ErrNotExist), "discussion executed write tool")
		return nil
	}
	must(discussioncheck.Run(ctx, h, plugin.DiscussionRequest{Source: model.ThreadRecord{SessionRecord: model.SessionRecord{ID: "thread", Cwd: cwd, Settings: settings, SessionState: discussionFrozen}}, Tools: discussionTools}, verifyDiscussion, discussionHolding))
	// A lazy ordinary fork must be discussed without materializing its source.
	lazy, err := h.Fork(ctx, plugin.ForkRequest{Source: model.ThreadRecord{SessionRecord: model.SessionRecord{SessionState: discussionFrozen, Settings: settings}}})
	must(err)
	lazyDiscussion, err := h.PrepareDiscussion(ctx, plugin.DiscussionRequest{Source: model.ThreadRecord{SessionRecord: model.SessionRecord{ID: "lazy-fork", Cwd: cwd, Settings: settings, SessionState: lazy.SessionState}}, Tools: discussionTools, Instructions: threadvoice.DiscussionInstructions})
	must(err)
	lazyAnswer, err := lazyDiscussion.Ask(ctx, "DISCUSSION_FIRST")
	must(err)
	check(lazyAnswer == "discussion-first-canary", "lazy fork discussion lost native history")
	must(lazyDiscussion.Close())
	must(verifyDiscussion(false))
	must(inspector.Close())
	fmt.Println("PASS real OpenCode discussion relay: native source/history unchanged, continuous private branch, Core reads, forbidden write, native failure, cancellation, media failure and cleanup")
	readContext, cancelRead := context.WithCancel(ctx)
	readDone := make(chan error, 1)
	go func() { _, err := handle.Read(readContext, "CANCEL_READ_MARKER"); readDone <- err }()
	select {
	case <-cancelReadStarted:
	case <-ctx.Done():
		panic("cancelled read did not reach provider")
	}
	check(countNativeSessions() == 2, "read did not create a distinct native branch")
	must(handle.Send(ctx, plugin.SendRequest{ExecutionID: "during-read", Input: model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "SOURCE_CONTINUES_DURING_READ"}}}}))
	wait(ctx, state, "during-read")
	cancelRead()
	select {
	case err := <-readDone:
		check(err != nil, "cancelled read succeeded")
	case <-ctx.Done():
		panic("cancelled read cleanup did not finish")
	}
	select {
	case <-cancelReadStopped:
	case <-ctx.Done():
		panic("read cancellation did not disconnect the Provider")
	}
	check(countNativeSessions() == 1, "cancelled native fork read left a temporary native session")
	must(handle.Send(ctx, plugin.SendRequest{ExecutionID: "active-source", Input: model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "ACTIVE_SOURCE_MARKER"}}}}))
	select {
	case <-activeSourceStarted:
	case <-ctx.Done():
		panic("active source did not reach the Provider")
	}
	_, err = handle.Read(ctx, "What did the completed turns return while the source is running?")
	must(err)
	activeState, err := oc.DecodeState(state.Read())
	must(err)
	check(activeState.Active() != nil && activeState.Active().ExecutionID == "active-source", "reading interrupted the active source")
	check(countNativeSessions() == 1, "active-source read left a temporary branch")
	activeDiscussion, err := h.PrepareDiscussion(ctx, plugin.DiscussionRequest{Source: model.ThreadRecord{SessionRecord: model.SessionRecord{ID: "thread", Cwd: cwd, Settings: settings, SessionState: state.Read()}}, Tools: discussionTools, Instructions: threadvoice.DiscussionInstructions})
	must(err)
	_, err = activeDiscussion.Ask(ctx, "DISCUSSION_FIRST")
	must(err)
	must(activeDiscussion.Close())
	activeAfter, err := oc.DecodeState(state.Read())
	must(err)
	check(activeAfter.Active() != nil && activeAfter.Active().ExecutionID == "active-source", "discussion stop interrupted active source")
	check(countNativeSessions() == 1, "active-source discussion leaked private branch")
	close(releaseActiveSource)
	wait(ctx, state, "active-source")

	must(handle.Close())
	snapshot := state.Read()
	check(strings.Contains(string(snapshot), "nativeTranscript"), "native history missing after close")
	restored, err := h.Open(ctx, mkOpen("thread", state, nil))
	must(err)
	defer restored.Close()
	restoredBefore := state.Read()
	_, err = restored.Read(ctx, "What was returned before restart?")
	must(err)
	check(string(restoredBefore) == string(state.Read()), "restored read changed source durable state")
	check(countNativeSessions() == 1, "restored read left a temporary native session")
	must(restored.Send(ctx, plugin.SendRequest{ExecutionID: "e3", Input: model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "After restart."}}}}))
	wait(ctx, state, "e3")
	must(restored.Close())
	fork, err := h.Fork(ctx, plugin.ForkRequest{Source: model.ThreadRecord{SessionRecord: model.SessionRecord{SessionState: state.Read(), Settings: settings}}, Request: json.RawMessage(`{}`)})
	must(err)
	forkState := &store{raw: fork.SessionState}
	forked, err := h.Open(ctx, mkOpen("fork", forkState, nil))
	must(err)
	defer forked.Close()
	_, err = forked.Read(ctx, "What happened before this ordinary fork?")
	must(err)
	must(forked.Send(ctx, plugin.SendRequest{ExecutionID: "f1", Input: model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "Fork continuation."}}}}))
	wait(ctx, forkState, "f1")
	must(forked.Close())

	complete, err := h.Complete(ctx, plugin.PromptRequest{Settings: settings, Messages: []plugin.PromptMessage{{Role: "user", Content: "Return fixture JSON."}}, OutputFormat: plugin.PromptOutputFormat{Type: "json_schema", Schema: json.RawMessage(`{"type":"object","required":["reply"],"properties":{"reply":{"type":"string"}},"additionalProperties":false}`)}})
	must(err)
	check(complete.Output.Type == "json" && string(complete.Output.Value) == `{"reply":"fixture"}`, "JSON completion")
	steering := plugin.NewPromptSteering()
	isolatedDone := make(chan error, 1)
	go func() {
		result, err := h.Complete(ctx, plugin.PromptRequest{Steering: steering, Settings: settings, Messages: []plugin.PromptMessage{{Role: "user", Content: "ISOLATED_INITIAL_MARKER"}}, OutputFormat: plugin.PromptOutputFormat{Type: "json_schema", Schema: json.RawMessage(`{"type":"object","required":["reply"],"properties":{"reply":{"type":"string"}},"additionalProperties":false}`)}})
		if err == nil && string(result.Output.Value) != `{"reply":"steered"}` {
			err = fmt.Errorf("isolated native steer did not return final JSON: %s", result.Output.Value)
		}
		isolatedDone <- err
	}()
	select {
	case <-isolatedStarted:
	case <-ctx.Done():
		panic(ctx.Err())
	}
	steerErr := steering.Send(ctx, "ISOLATED_UPDATE_MARKER")
	check(steerErr == nil || errors.Is(steerErr, plugin.ErrPromptSettled), "isolated native steer admission")
	close(releaseIsolated)
	select {
	case err := <-isolatedDone:
		must(err)
	case <-ctx.Done():
		panic(ctx.Err())
	}
	check(errors.Is(steering.Send(ctx, "late"), plugin.ErrPromptSettled), "isolated native completion terminal fence")

	for _, name := range []string{"fixture_echo", "__proto__"} {
		toolState := &store{}
		before := tools.Load()
		injection := &plugin.Injection{Tools: &plugin.ToolInjection{Mode: "exclusive", Bindings: []plugin.ToolBinding{{Name: name, Description: "Echo value", InputSchema: json.RawMessage(`{"type":"object","properties":{"value":{"type":"string"}},"required":["value"]}`), Execute: func(ctx context.Context, call plugin.ToolCall) (json.RawMessage, error) {
			tools.Add(1)
			if !strings.Contains(string(call.Arguments), "hello") {
				return nil, errors.New("bad arguments")
			}
			return json.RawMessage(`{"echo":"hello"}`), nil
		}}}}}
		toolHandle, err := h.Open(ctx, mkOpen("tools_"+name, toolState, injection))
		must(err)
		defer toolHandle.Close()
		must(toolHandle.Send(ctx, plugin.SendRequest{ExecutionID: "t1", Input: model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "Call " + name + "."}}}}))
		wait(ctx, toolState, "t1")
		must(toolHandle.Close())
		check(tools.Load() == before+1, "custom tool bridge not invoked exactly once: "+name)
		check(strings.Contains(string(toolState.Read()), `"toolName":"`+name+`"`), "native tool projection missing: "+name)
	}
	settings = json.RawMessage(strings.ReplaceAll(string(settings), `"permissionMode":"auto"`, `"permissionMode":"default"`))
	permissionState := &store{}
	permissionHandle, err := h.Open(ctx, mkOpen("permission", permissionState, nil))
	must(err)
	defer permissionHandle.Close()
	must(permissionHandle.Send(ctx, plugin.SendRequest{ExecutionID: "p1", Input: model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "PERMISSION_MARKER"}}}}))
	var interaction model.PublicInteraction
	for {
		state, err := oc.DecodeState(permissionState.Read())
		must(err)
		if state.Current() != nil && len(state.Current().Interactions) > 0 {
			interaction = state.Current().Interactions[0]
			break
		}
		select {
		case <-ctx.Done():
			panic("permission never asked")
		case <-time.After(20 * time.Millisecond):
		}
	}
	check(permissionHandle.Respond(ctx, model.RespondRequest{ExecutionID: "stale-execution", InteractionID: interaction.ID, ActionID: "allow"}) != nil, "stale execution answered OpenCode interaction")
	must(permissionHandle.Respond(ctx, model.RespondRequest{ExecutionID: "p1", InteractionID: interaction.ID, ActionID: "allow"}))
	wait(ctx, permissionState, "p1")
	must(permissionHandle.Close())
	var captured atomic.Pointer[oc.Runtime]
	launch := func(ctx context.Context, s oc.Settings, cwd string, isolated bool) (*oc.Runtime, error) {
		runtime, err := oc.NewRuntime(ctx, oc.Options{CWD: cwd, ExecutablePath: nativeCLI, Environment: env, Config: config, IsolateConfig: isolated})
		if err == nil {
			captured.Store(runtime)
		}
		return runtime, err
	}
	started := make(chan struct{}, 4)
	release := make(chan struct{})
	gateTool := &plugin.Injection{Tools: &plugin.ToolInjection{Mode: "exclusive", Bindings: []plugin.ToolBinding{{Name: "fixture_echo", Description: "Wait for fixture controller", InputSchema: json.RawMessage(`{"type":"object","properties":{"value":{"type":"string"}},"required":["value"]}`), Execute: func(ctx context.Context, call plugin.ToolCall) (json.RawMessage, error) {
		started <- struct{}{}
		select {
		case <-release:
			return json.RawMessage(`{"echo":"released"}`), nil
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}}}}}
	formState := &store{}
	formOpen := mkOpen("forms", formState, gateTool)
	formOpen.ExecutionAdmission = &automaticAdmission{state: formState}
	formHandle, err := oc.OpenThread(ctx, formOpen, launch)
	must(err)
	defer formHandle.Close()
	must(formHandle.Send(ctx, plugin.SendRequest{ExecutionID: "form1", Input: model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "Use fixture_echo and wait."}}}}))
	select {
	case <-started:
	case <-ctx.Done():
		panic("gate did not start")
	}
	frozen, err := oc.DecodeState(formState.Read())
	must(err)
	native := captured.Load()
	var nativeForm oc.Object
	must(native.Request(ctx, "POST", "/api/session/"+frozen.NativeSessionID+"/form", oc.Object{"id": "frm_fixture_typed", "title": "Fixture typed form", "fields": []oc.Object{{"key": "mode", "type": "string", "required": true, "options": []oc.Object{{"value": "go", "label": "Go"}, {"value": "stop", "label": "Stop"}}}, {"key": "count", "type": "integer", "minimum": 1, "maximum": 4, "required": true}, {"key": "enabled", "type": "boolean", "default": true}, {"key": "choices", "type": "multiselect", "when": []oc.Object{{"key": "mode", "op": "eq", "value": "go"}}, "required": true, "minItems": 1, "options": []oc.Object{{"value": "a", "label": "A"}, {"value": "b", "label": "B"}}}, {"key": "external", "type": "external", "url": "https://example.invalid/fixture"}}}, &nativeForm))
	var publicForm model.PublicInteraction
	for {
		observed, err := oc.DecodeState(formState.Read())
		must(err)
		if observed.Current() != nil {
			for _, interaction := range observed.Current().Interactions {
				if interaction.Kind == "question" {
					publicForm = interaction
				}
			}
		}
		if publicForm.ID != "" {
			break
		}
		select {
		case <-ctx.Done():
			panic("typed form missing")
		case <-time.After(20 * time.Millisecond):
		}
	}
	answers := map[string]json.RawMessage{}
	for _, q := range publicForm.Questions {
		var value any
		switch q.Form.Type {
		case "integer":
			value = "0x3"
		case "multiselect":
			value = []string{q.Options[0].Value}
		case "string", "boolean", "external":
			value = q.Options[0].Value
		}
		answers[q.ID], _ = json.Marshal(value)
	}
	bad := map[string]json.RawMessage{}
	for k, v := range answers {
		bad[k] = v
	}
	for _, q := range publicForm.Questions {
		if q.Form.Type == "integer" {
			bad[q.ID] = json.RawMessage(`"0"`)
		}
	}
	check(formHandle.Respond(ctx, model.RespondRequest{InteractionID: publicForm.ID, ActionID: "submit", Answers: bad}) != nil, "invalid typed form accepted")
	must(formHandle.Respond(ctx, model.RespondRequest{InteractionID: publicForm.ID, ActionID: "submit", Answers: answers}))
	var detail oc.Object
	must(native.Request(ctx, "GET", "/api/session/"+frozen.NativeSessionID+"/form/frm_fixture_typed", nil, &detail))
	check(detail["state"].(map[string]any)["status"] == "answered", "native form not answered")
	steerAdmitted := 0
	must(formHandle.Send(ctx, plugin.SendRequest{ExecutionID: "form1", Input: model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "Steer current execution."}}}, Admitted: func() error { steerAdmitted++; return nil }}))
	close(release)
	wait(ctx, formState, "form1")
	check(steerAdmitted == 1, "steering admission incorrect")

	// No active execution owns this event. The production SSE admission must
	// initialize an empty automatic-execution map before publishing the form.
	idleFields := []oc.Object{
		{"key": "emoji", "type": "string", "minLength": 2, "default": "😀"},
		{"key": "email", "type": "string", "format": "email", "default": "a..b@example.com"},
		{"key": "uri", "type": "string", "format": "uri", "default": "https://example.com/%zz"},
		{"key": "date", "type": "string", "format": "date-time", "default": "+010000-01-01T00:00:00.000Z"},
		{"key": "external", "type": "external", "url": "https://example.com/%zz"},
		{"key": "prefix", "type": "string", "required": true},
		{"key": "number", "type": "integer", "required": true, "minimum": 16, "maximum": 16},
		{"key": "optional", "type": "string", "required": false},
		{"key": "hidden", "type": "string", "hidden": true, "default": "hidden-default"},
		{"key": "inactive", "type": "string", "required": true, "when": []oc.Object{{"key": "prefix", "op": "eq", "value": "other"}}},
	}
	must(native.Request(ctx, "POST", "/api/session/"+frozen.NativeSessionID+"/form", oc.Object{"id": "frm_fixture_idle", "title": "", "fields": idleFields}, &nativeForm))
	var automaticID string
	for {
		observed, err := oc.DecodeState(formState.Read())
		must(err)
		if current := observed.Current(); current != nil && current.ExecutionID != "form1" && len(current.Interactions) > 0 {
			publicForm = current.Interactions[0]
			automaticID = current.ExecutionID
			break
		}
		select {
		case <-ctx.Done():
			panic("idle native form was not admitted")
		case <-time.After(20 * time.Millisecond):
		}
	}
	check(publicForm.Title == "OpenCode request", "empty native form title gets public fallback")
	idleAnswers := map[string]json.RawMessage{}
	for _, question := range publicForm.Questions {
		if question.Form.Type == "external" {
			idleAnswers[question.ID], _ = json.Marshal(question.Options[0].Value)
		}
		if question.Form.Type == "integer" {
			idleAnswers[question.ID] = json.RawMessage(`"0x10"`)
		}
		if question.Form.Type == "string" && question.Form.Required && len(question.Form.When) == 0 {
			idleAnswers[question.ID] = json.RawMessage(`"opencode-option-user-data"`)
		}
	}
	must(formHandle.Respond(ctx, model.RespondRequest{ExecutionID: automaticID, InteractionID: publicForm.ID, ActionID: "submit", Answers: idleAnswers}))
	must(native.Request(ctx, "GET", "/api/session/"+frozen.NativeSessionID+"/form/frm_fixture_idle", nil, &detail))
	idleResult := detail["state"].(map[string]any)
	check(idleResult["status"] == "answered", "idle native form reply failed")
	nativeAnswers := idleResult["answer"].(map[string]any)
	check(nativeAnswers["prefix"] == "opencode-option-user-data" && nativeAnswers["number"] == float64(16) && nativeAnswers["hidden"] == "hidden-default" && len(nativeAnswers) == 8 && nativeAnswers["emoji"] == "😀" && nativeAnswers["email"] == "a..b@example.com" && nativeAnswers["uri"] == "https://example.com/%zz" && nativeAnswers["date"] == "+010000-01-01T00:00:00.000Z" && nativeAnswers["external"] == true, "typed form values/defaults/omissions did not reach native form")
	fmt.Println("PASS idle SSE automatic admission, literal option-prefix text, typed radix numbers, hidden defaults and optional/conditional omission")
	must(formHandle.Close())
	release = make(chan struct{})
	cancelState := &store{}
	cancelHandle, err := oc.OpenThread(ctx, mkOpen("cancel", cancelState, gateTool), launch)
	must(err)
	defer cancelHandle.Close()
	must(cancelHandle.Send(ctx, plugin.SendRequest{ExecutionID: "cancel1", Input: model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "Call fixture_echo until cancelled."}}}}))
	select {
	case <-started:
	case <-ctx.Done():
		panic("cancellable tool not started")
	}
	var interruptions sync.WaitGroup
	for i := 0; i < 2; i++ {
		interruptions.Add(1)
		go func() { defer interruptions.Done(); must(cancelHandle.Interrupt(ctx)) }()
	}
	interruptions.Wait()
	cancelled, err := oc.DecodeState(cancelState.Read())
	must(err)
	check(cancelled.Current() != nil && cancelled.Current().Status == "interrupted", "native cancellation not persisted")
	must(cancelHandle.Close())
	var cut atomic.Bool
	var cutPerformed atomic.Bool
	var proxiesMu sync.Mutex
	var proxies []*httptest.Server
	defer func() {
		proxiesMu.Lock()
		defer proxiesMu.Unlock()
		for _, proxy := range proxies {
			proxy.Close()
		}
	}()
	reconnectLaunch := func(ctx context.Context, settings oc.Settings, cwd string, isolated bool) (*oc.Runtime, error) {
		runtime, err := launch(ctx, settings, cwd, isolated)
		if err != nil {
			return nil, err
		}
		upstream, err := url.Parse(runtime.URL)
		must(err)
		reverse := httputil.NewSingleHostReverseProxy(upstream)
		reverse.FlushInterval = -1
		proxy := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Path != "/api/event" || !cut.CompareAndSwap(false, true) {
				reverse.ServeHTTP(w, r)
				return
			}
			forwarded := r.Clone(r.Context())
			forwarded.URL.Scheme = upstream.Scheme
			forwarded.URL.Host = upstream.Host
			forwarded.RequestURI = ""
			response, err := http.DefaultClient.Do(forwarded)
			if err != nil {
				http.Error(w, "fixture upstream", 502)
				return
			}
			defer response.Body.Close()
			w.Header().Set("Content-Type", "text/event-stream")
			scanner := bufio.NewScanner(response.Body)
			scanner.Buffer(make([]byte, 4096), 4<<20)
			ending := false
			for scanner.Scan() {
				line := scanner.Text()
				fmt.Fprintln(w, line)
				if strings.Contains(line, `"type":"session.text.delta"`) {
					ending = true
				}
				if line == "" {
					w.(http.Flusher).Flush()
					if ending {
						cutPerformed.Store(true)
						return
					}
				}
			}
		}))
		runtime.URL = proxy.URL
		proxiesMu.Lock()
		proxies = append(proxies, proxy)
		proxiesMu.Unlock()
		return runtime, nil
	}
	reconnectState := &store{}
	reconnectHandle, err := oc.OpenThread(ctx, mkOpen("reconnect", reconnectState, nil), reconnectLaunch)
	must(err)
	defer reconnectHandle.Close()
	must(reconnectHandle.Send(ctx, plugin.SendRequest{ExecutionID: "reconnect1", Input: model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "Reconnect fixture."}}}}))
	wait(ctx, reconnectState, "reconnect1")
	reconnected, err := oc.DecodeState(reconnectState.Read())
	must(err)
	check(cutPerformed.Load(), "SSE gap was not injected")
	answersSeen := 0
	for _, message := range reconnected.Messages {
		if message.Role == "assistant" && message.ExecutionID == "reconnect1" {
			if message.Text != `{"reply":"fixture"}` {
				fmt.Printf("reconnect message %s has unexpected content length %d\n", message.ID, len(message.Text))
				panic("reconciled text duplicated or truncated")
			}
			answersSeen++
		}
	}
	check(answersSeen == 1, "reconnect duplicated native message identity")
	must(reconnectHandle.Close())
	fmt.Printf("PASS native Thread replay: send/admission, follow-up, native fork read/cache affinity/prefix, active-source and concurrent continuation, native session and cancellation cleanup, restart/read, fork import, JSON completion, exclusive Go tool bridge, permission, typed conditional form validation, steering, concurrent cancellation, forced SSE gap/durable reconciliation; %d loopback inference calls\n", requests.Load())
}
