package main

import (
	"context"
	"encoding/json"
	"fmt"
	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	oc "github.com/hupao-creator/Mokusei/internal/plugins/harness/opencode"
	"net/http"
	"net/http/httptest"
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
	initialReasoning := strings.Repeat("😀", 32768)
	firstObserved, tailObserved := make(chan struct{}), make(chan struct{})
	assistantObserved := make(chan struct{})
	acknowledgeFirst := sync.OnceFunc(func() { close(firstObserved) })
	acknowledgeTail := sync.OnceFunc(func() { close(tailObserved) })
	acknowledgeAssistant := sync.OnceFunc(func() { close(assistantObserved) })
	published := []<-chan struct{}{firstObserved, tailObserved, assistantObserved}
	var requests atomic.Int32
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
		withTool := false
		if declared, ok := body["tools"].([]any); ok {
			for _, raw := range declared {
				tool := raw.(map[string]any)
				if tool["function"].(map[string]any)["name"] == "fixture_echo" {
					withTool = true
				}
			}
		}
		requestText, _ := json.Marshal(body["messages"])
		permission := strings.Contains(string(requestText), "PERMISSION_MARKER")
		delta := map[string]any{"role": "assistant", "content": `{"reply":"fixture"}`}
		finish := "stop"
		if withTool && !called {
			delta = map[string]any{"role": "assistant", "tool_calls": []any{map[string]any{"index": 0, "id": "call_fixture", "type": "function", "function": map[string]any{"name": "fixture_echo", "arguments": `{"value":"hello"}`}}}}
			finish = "tool_calls"
		}
		if permission && !called {
			delta = map[string]any{"role": "assistant", "tool_calls": []any{map[string]any{"index": 0, "id": "call_permission", "type": "function", "function": map[string]any{"name": "shell", "arguments": `{"command":"printf permission-fixture","description":"Print fixture"}`}}}}
			finish = "tool_calls"
		}
		w.Header().Set("Content-Type", "text/event-stream")
		f := w.(http.Flusher)
		chunks := []any{map[string]any{"id": fmt.Sprintf("chat_%d", requests.Load()), "object": "chat.completion.chunk", "created": time.Now().Unix(), "model": "fixture-model", "choices": []any{map[string]any{"index": 0, "delta": delta, "finish_reason": nil}}}, map[string]any{"id": "chat_end", "object": "chat.completion.chunk", "created": time.Now().Unix(), "model": "fixture-model", "choices": []any{map[string]any{"index": 0, "delta": map[string]any{}, "finish_reason": finish}}, "usage": map[string]any{"prompt_tokens": 12, "completion_tokens": 3, "total_tokens": 15}}}
		reasoningChunks := []any{}
		for _, text := range []string{initialReasoning, "tail"} {
			reasoningChunks = append(reasoningChunks, map[string]any{"id": "reasoning_fixture", "object": "chat.completion.chunk", "created": time.Now().Unix(), "model": "fixture-model", "choices": []any{map[string]any{"index": 0, "delta": map[string]any{"reasoning_content": text}, "finish_reason": nil}}})
		}
		chunks = append(reasoningChunks, chunks...)
		for index, chunk := range chunks {
			b, _ := json.Marshal(chunk)
			fmt.Fprintf(w, "data: %s\n\n", b)
			f.Flush()
			if index < len(published) {
				// Native SSE and foreground publication may coalesce fast input.
				// Advance only after the real adapter exposes this source segment,
				// so streaming coverage does not depend on a 120ms scheduling gap.
				select {
				case <-published[index]:
				case <-r.Context().Done():
					return
				case <-time.After(10 * time.Second):
					panic(fmt.Sprintf("native foreground segment %d was not published before the next source segment", index+1))
				}
			}
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
	ctx, cancel := context.WithTimeout(parent, 100*time.Second)
	defer cancel()
	settings := json.RawMessage(`{"provider":"fixture","model":"fixture-model","thinking":{"mode":"effort","effort":"low"},"variant":"low","permissionMode":"auto"}`)
	mkOpen := func(id string, s *store, injection *plugin.Injection) plugin.OpenContext {
		return plugin.OpenContext{ThreadID: id, SessionState: s, RequireExplicitSettings: true, ReadThread: func() model.SessionRecord {
			return model.SessionRecord{ID: id, HarnessID: "opencode", Cwd: cwd, Settings: settings}
		}, Injection: injection}
	}

	var activityMu sync.Mutex
	var activities []model.HarnessActivity
	state := &store{}
	open := mkOpen("foreground", state, nil)
	open.PublishActivity = func(activity model.HarnessActivity) {
		activityMu.Lock()
		activities = append(activities, activity)
		activityMu.Unlock()
		if activity.Kind == "reasoning" {
			if activity.Text == initialReasoning {
				acknowledgeFirst()
			}
			if strings.HasSuffix(activity.Text, "tail") {
				acknowledgeTail()
			}
		} else if activity.Kind == "assistant-text" {
			acknowledgeAssistant()
		}
	}
	handle, err := h.Open(ctx, open)
	must(err)
	defer handle.Close()
	must(handle.Send(ctx, plugin.SendRequest{ExecutionID: "foreground1", Input: model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "Return fixture JSON."}}}}))
	wait(ctx, state, "foreground1")
	must(handle.Close())
	activityMu.Lock()
	defer activityMu.Unlock()
	reasoningCount := 0
	assistantCount := 0
	offset := int64(0)
	for _, activity := range activities {
		if activity.Kind == "reasoning" {
			reasoningCount++
			check(activity.Sequence == 1, "reasoning delta changed semantic sequence")
			check(len([]rune(activity.Text)) <= 32768, "reasoning window exceeded point budget")
			offset = activity.TextOffset
		} else if activity.Kind == "assistant-text" {
			assistantCount++
			check(activity.Sequence == 2, "assistant transition did not advance sequence exactly once")
			check(activity.Text == "", "assistant foreground leaked delta text")
		}
	}
	fmt.Printf("activity counts reasoning=%d assistant=%d offset=%d\n", reasoningCount, assistantCount, offset)
	for _, activity := range activities {
		fmt.Printf("activity kind=%s sequence=%d textPoints=%d\n", activity.Kind, activity.Sequence, len([]rune(activity.Text)))
	}
	check(reasoningCount >= 2, "reasoning stream not published")
	check(assistantCount == 1, fmt.Sprintf("assistant transition count=%d, want one without duplicate ended fragments", assistantCount))
	check(offset == 8, "reasoning source UTF-16 offset did not count surrogate pairs")
	projected, err := oc.DecodeState(state.Read())
	must(err)
	check(len(projected.Foregrounds) == 1, "foreground not durably retained")
	fg := projected.Foregrounds[0]["foreground"].(map[string]any)
	check(fg["kind"] == "assistant-text" && fg["sequence"] == float64(2), "durable semantic foreground differs from published one")
	fmt.Printf("PASS native foreground: %d reasoning windows, %d assistant transition, UTF-16 offset %d, durable sequence 2\n", reasoningCount, assistantCount, offset)
}
