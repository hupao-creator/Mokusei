package main

import (
	"context"
	"encoding/json"
	"errors"
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
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/pi"
	"github.com/hupao-creator/Mokusei/internal/services/threadvoice"
	"github.com/hupao-creator/Mokusei/tools/verification/discussioncheck"
)

// This mode runs the installed external Pi, including its real extension loader.
// Only the local scripted Chat Completions endpoint is reachable by the child;
// credentials and configuration are fabricated inside a disposable HOME.
func runNative(ctx context.Context) error {
	if runtime.GOOS != "darwin" {
		return errors.New("native Pi verification requires macOS sandbox-exec for loopback-only egress; deterministic mode is portable")
	}
	if _, err := os.Stat("/usr/bin/sandbox-exec"); err != nil {
		return fmt.Errorf("native Pi network isolation unavailable: %w", err)
	}
	executable := os.Getenv("MOKUSEI_PI_NATIVE_EXECUTABLE")
	if executable == "" {
		var err error
		executable, err = exec.LookPath("pi")
		if err != nil {
			return errors.New("installed Pi missing; set MOKUSEI_PI_NATIVE_EXECUTABLE")
		}
	}
	executable, err := filepath.Abs(executable)
	if err != nil {
		return err
	}
	node, err := exec.LookPath("node")
	if err != nil {
		return errors.New("the external installed Pi requires Node on PATH")
	}
	root, err := os.MkdirTemp("", "mokusei-pi-native-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(root)
	realHome, _ := os.UserHomeDir()
	env := map[string]string{"HOME": filepath.Join(root, "home"), "PATH": filepath.Dir(node) + ":/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": filepath.Join(root, "tmp"), "XDG_CONFIG_HOME": filepath.Join(root, "config"), "XDG_DATA_HOME": filepath.Join(root, "share"), "XDG_CACHE_HOME": filepath.Join(root, "cache"), "PI_CODING_AGENT_DIR": filepath.Join(root, "agent"), "TERM": "dumb", "NO_COLOR": "1", "FORCE_COLOR": "0", "PI_NO_AUTO_UPDATE": "1"}
	for _, directory := range []string{env["HOME"], env["TMPDIR"], env["XDG_CONFIG_HOME"], env["XDG_DATA_HOME"], env["XDG_CACHE_HOME"], env["PI_CODING_AGENT_DIR"], filepath.Join(root, "work")} {
		if err = os.MkdirAll(directory, 0700); err != nil {
			return err
		}
	}
	provider := &nativeScriptProvider{root: root, requests: []nativeRequestEvidence{}, holding: make(chan struct{}, 16)}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return err
	}
	server := &http.Server{Handler: provider, ReadHeaderTimeout: 5 * time.Second, MaxHeaderBytes: 64 * 1024}
	go func() { _ = server.Serve(listener) }()
	defer server.Close()
	origin := "http://" + listener.Addr().String()
	provider.origin = origin
	env["HTTP_PROXY"] = origin
	env["HTTPS_PROXY"] = origin
	env["ALL_PROXY"] = origin
	env["NO_PROXY"] = "127.0.0.1,localhost,::1"
	policy := "(version 1)\n(allow default)\n(deny network*)\n(allow network-outbound (remote ip \"localhost:*\"))\n"
	if realHome != "" {
		policy += "(deny file-write* (subpath " + strconv.Quote(realHome) + "))\n"
	}
	sandbox := filepath.Join(root, "loopback.sb")
	if err = os.WriteFile(sandbox, []byte(policy), 0600); err != nil {
		return err
	}
	wrapper := filepath.Join(root, "pi-isolated")
	script := "#!/bin/sh\nexec /usr/bin/sandbox-exec -f " + nativeShellQuote(sandbox) + " " + nativeShellQuote(executable) + " \"$@\"\n"
	if err = os.WriteFile(wrapper, []byte(script), 0700); err != nil {
		return err
	}
	version, err := pi.GetVersion(ctx, pi.ProcessOptions{ExecutablePath: wrapper, Cwd: filepath.Join(root, "work"), Env: env})
	if err != nil {
		return fmt.Errorf("installed Pi version/isolation: %w", err)
	}
	fmt.Println("REAL Pi version:", version)
	if !verificationConfig.nativeShutdownOnly {
		if err = verifyNativeChatThinking(ctx, root, wrapper, env); err != nil {
			return err
		}
	}
	models := map[string]any{"providers": map[string]any{"mock": map[string]any{
		"baseUrl": origin + "/v1", "api": "openai-completions", "apiKey": "local-scripted-provider-only",
		"models": []any{map[string]any{"id": "mock-model", "name": "Mock model", "reasoning": false,
			"input": []string{"text"}, "contextWindow": 128000, "maxTokens": 4096,
			"compat": map[string]any{"supportsDeveloperRole": false, "supportsStore": false}}},
	}}}
	modelData, err := json.Marshal(models)
	if err != nil {
		return err
	}
	if err = os.WriteFile(filepath.Join(env["PI_CODING_AGENT_DIR"], "models.json"), modelData, 0600); err != nil {
		return err
	}
	if err = verifyNativeShutdown(ctx, root, wrapper, env); err != nil {
		return err
	}
	if verificationConfig.nativeShutdownOnly {
		return nil
	}
	if err = verifyNativeSettingsDiscovery(ctx, root, wrapper, env); err != nil {
		return err
	}
	host := plugin.HostContext{HarnessDataRoot: filepath.Join(root, "data"), TemporaryWorkspaceRoot: filepath.Join(root, "temporary"), Environment: func(context.Context) (map[string]string, error) {
		copy := map[string]string{}
		for k, v := range env {
			copy[k] = v
		}
		return copy, nil
	}, ResolveExecutable: func(context.Context, string, string, string) (string, error) { return wrapper, nil }}
	adapter := pi.New(host)
	requested := json.RawMessage(`{"provider":"mock","model":"mock-model","thinking":{"mode":"fixed"}}`)
	settings, err := adapter.Settings().ResolveThread(ctx, plugin.ResolveSettingsRequest{Merged: requested, Requested: requested, Cwd: filepath.Join(root, "work")})
	if err != nil {
		return fmt.Errorf("real Pi exact provider/model/thinking resolution: %w", err)
	}
	var selected pi.ThreadSettings
	if err = json.Unmarshal(settings, &selected); err != nil {
		return err
	}
	if selected.Provider != "mock" || selected.Model != "mock-model" || selected.ThinkingLevel != "off" {
		return fmt.Errorf("unexpected real Pi selection: %+v", selected)
	}
	presentation, err := adapter.Settings().Presentation(ctx, plugin.SettingsPresentationRequest{Settings: adapter.DefaultSettings(), ThreadSettings: settings, Cwd: filepath.Join(root, "work")})
	if err != nil {
		return err
	}
	if err = writeArtifact("native-presentation.json", presentation); err != nil {
		return err
	}
	var toolCalls atomic.Int64
	injection := &plugin.Injection{Instructions: []string{"MOKUSEI_NATIVE_HOST_INSTRUCTION. Invoke multiply for the fixture request, then state the result."}, Tools: &plugin.ToolInjection{Mode: "exclusive", Bindings: []plugin.ToolBinding{{Name: "multiply", Description: "Multiply two integers in the Go host.", InputSchema: json.RawMessage(`{"type":"object","properties":{"a":{"type":"integer"},"b":{"type":"integer"}},"required":["a","b"],"additionalProperties":false}`), Execute: func(ctx context.Context, call plugin.ToolCall) (json.RawMessage, error) {
		if call.CallID != "native-multiply-1" {
			return nil, fmt.Errorf("unexpected native tool identity %q", call.CallID)
		}
		var arguments struct {
			A int `json:"a"`
			B int `json:"b"`
		}
		if err := json.Unmarshal(call.Arguments, &arguments); err != nil {
			return nil, err
		}
		if arguments.A != 6 || arguments.B != 7 {
			return nil, errors.New("native tool arguments changed")
		}
		toolCalls.Add(1)
		return json.Marshal(map[string]int{"product": arguments.A * arguments.B})
	}}}}}
	bridgeStore := &nativeMemoryStore{}
	bridgeRecord := model.SessionRecord{ID: "native-host-bridge", HarnessID: "pi", Cwd: filepath.Join(root, "work"), Settings: settings}
	bridge, err := adapter.Open(ctx, plugin.OpenContext{ThreadID: bridgeRecord.ID, ReadThread: func() model.SessionRecord { return bridgeRecord }, SessionState: bridgeStore, RequireExplicitSettings: true, Injection: injection})
	if err != nil {
		return err
	}
	defer bridge.Close()
	if err = nativeSend(ctx, bridge, "native-bridge", "HOST_TOOL_PROOF"); err != nil {
		return fmt.Errorf("native extension send: %w", err)
	}
	if _, err = nativeWait(ctx, bridgeStore, "native-bridge", "completed"); err != nil {
		return fmt.Errorf("native extension execution: %w", err)
	}
	if toolCalls.Load() != 1 {
		return fmt.Errorf("actual Pi Host extension executed Go tool %d times", toolCalls.Load())
	}
	if err = bridge.Close(); err != nil {
		return err
	}
	fmt.Println("PASS real Pi Host extension: native loader, exclusive registration, instructions, FD3 call/result, Go tool execution")
	ordinaryStore := &nativeMemoryStore{}
	ordinaryRecord := model.SessionRecord{ID: "native-ordinary", HarnessID: "pi", Cwd: filepath.Join(root, "work"), Settings: settings}
	open := plugin.OpenContext{ThreadID: ordinaryRecord.ID, ReadThread: func() model.SessionRecord { return ordinaryRecord }, SessionState: ordinaryStore, RequireExplicitSettings: true}
	handle, err := adapter.Open(ctx, open)
	if err != nil {
		return err
	}
	defer handle.Close()
	if err = nativeSend(ctx, handle, "native-normal", "NORMAL_PROOF"); err != nil {
		return err
	}
	normal, err := nativeWait(ctx, ordinaryStore, "native-normal", "completed")
	if err != nil {
		return err
	}
	if normal.NativeSessionJSONL == "" {
		return errors.New("real Pi did not persist native history")
	}
	projectedUsage, err := adapter.SessionState().ProjectRenderer(ordinaryStore.Read(), model.RendererScope{Kind: "overview"})
	if err != nil {
		return err
	}
	var usageProjection struct {
		ExecutionUsage map[string]pi.Usage `json:"executionUsage"`
	}
	if err = json.Unmarshal(projectedUsage, &usageProjection); err != nil {
		return err
	}
	// The loopback provider reports 20 prompt + 5 completion tokens. Check the
	// installed Pi's real message_end contract, not just our protocol fixture.
	if u, ok := usageProjection.ExecutionUsage["native-normal"]; !ok || u.Input != 20 || u.Output != 5 || u.CacheRead != 0 || u.CacheWrite != 0 {
		return fmt.Errorf("real Pi usage did not survive RPC/persistence/projection: %+v", usageProjection.ExecutionUsage)
	}
	fmt.Println("PASS real Pi usage: provider → native message_end → durable state → compact execution total (25 tokens)")
	discussionTools, closeDiscussionTools, err := threadvoice.ProjectReadTools(ordinaryRecord.Cwd)
	if err != nil {
		return err
	}
	defer closeDiscussionTools()
	if err = os.WriteFile(filepath.Join(ordinaryRecord.Cwd, "discussion-proof.txt"), []byte("project-read-canary"), 0600); err != nil {
		return err
	}
	discussionFrozen := ordinaryStore.Read()
	sourceJSONL, err := os.ReadFile(normal.SessionFile)
	if err != nil {
		return err
	}
	verifyDiscussion := func(private bool) error {
		if string(ordinaryStore.Read()) != string(discussionFrozen) {
			return errors.New("discussion changed source Thread state")
		}
		nativeAfter, e := os.ReadFile(normal.SessionFile)
		if e != nil {
			return e
		}
		if string(nativeAfter) != string(sourceJSONL) {
			return errors.New("discussion changed native source JSONL")
		}
		dirs, e := filepath.Glob(filepath.Join(host.TemporaryWorkspaceRoot, "pi-discussion-*"))
		if e != nil {
			return e
		}
		expected := 0
		if private {
			expected = 1
		}
		if len(dirs) != expected {
			return fmt.Errorf("discussion leaked private history directories: %v", dirs)
		}
		if _, e = os.Stat(filepath.Join(ordinaryRecord.Cwd, "discussion-must-not-exist.txt")); !errors.Is(e, os.ErrNotExist) {
			return errors.New("discussion executed native write")
		}
		return nil
	}
	discussionRecord := ordinaryRecord
	discussionRecord.SessionState = discussionFrozen
	if err = discussioncheck.Run(ctx, adapter, plugin.DiscussionRequest{Source: model.ThreadRecord{SessionRecord: discussionRecord}, Tools: discussionTools}, verifyDiscussion, provider.holding); err != nil {
		return fmt.Errorf("real Pi discussion: %w", err)
	}
	// ForkSource carries a frozen branch without requiring a source session file.
	lazyRecord := discussionRecord
	lazyState := normal
	lazyState.ForkSource = &pi.ForkSource{JSONL: normal.NativeSessionJSONL}
	lazyState.NativeSessionJSONL = ""
	lazyState.SessionFile = ""
	lazyRecord.SessionState, _ = json.Marshal(lazyState)
	lazyDiscussion, e := adapter.PrepareDiscussion(ctx, plugin.DiscussionRequest{Source: model.ThreadRecord{SessionRecord: lazyRecord}, Tools: discussionTools, Instructions: threadvoice.DiscussionInstructions})
	if e != nil {
		return e
	}
	lazyAnswer, e := lazyDiscussion.Ask(ctx, "DISCUSSION_FIRST")
	closeLazy := lazyDiscussion.Close()
	if e != nil {
		return e
	}
	if closeLazy != nil {
		return closeLazy
	}
	if lazyAnswer != "discussion-first-canary" {
		return errors.New("Pi lazy fork discussion lost native history")
	}
	broken := normal
	broken.NativeSessionJSONL += "\n{broken"
	lazyRecord.SessionState, _ = json.Marshal(broken)
	if d, e := adapter.PrepareDiscussion(ctx, plugin.DiscussionRequest{Source: model.ThreadRecord{SessionRecord: lazyRecord}}); e == nil {
		d.Close()
		return errors.New("Pi damaged JSONL admitted partial discussion")
	}
	if e = verifyDiscussion(false); e != nil {
		return e
	}
	fmt.Println("PASS real Pi discussion relay: native source/history unchanged, continuous private fork, Core read, forbidden write, provider failure, cancellation, media failure and cleanup")
	answer, err := handle.Read(ctx, "READ_PROOF: What exact answer did the source task give?")
	if err != nil {
		return fmt.Errorf("actual embedded read guard: %w", err)
	}
	if answer != "native fixture answer" {
		return fmt.Errorf("real Pi read answer mismatch: %q", answer)
	}
	if err = nativeReadGuardProof(ctx, root, wrapper, env, normal.NativeSessionJSONL, provider); err != nil {
		return err
	}
	fmt.Println("PASS real Pi read guard: exact extension registered, frozen fork, native write tool blocked, source unchanged")
	fork, err := adapter.Fork(ctx, plugin.ForkRequest{Source: model.ThreadRecord{SessionRecord: model.SessionRecord{Settings: settings, SessionState: ordinaryStore.Read()}}})
	if err != nil {
		return err
	}
	forkStore := &nativeMemoryStore{raw: fork.SessionState}
	forkRecord := model.SessionRecord{ID: "native-fork", HarnessID: "pi", Cwd: ordinaryRecord.Cwd, Settings: settings}
	forkHandle, err := adapter.Open(ctx, plugin.OpenContext{ThreadID: forkRecord.ID, ReadThread: func() model.SessionRecord { return forkRecord }, SessionState: forkStore, RequireExplicitSettings: true})
	if err != nil {
		return err
	}
	defer forkHandle.Close()
	if err = nativeSend(ctx, forkHandle, "native-fork-run", "FORK_PROOF"); err != nil {
		return err
	}
	forkState, err := nativeWait(ctx, forkStore, "native-fork-run", "completed")
	if err != nil {
		return err
	}
	if forkState.SessionFile == normal.SessionFile || forkState.ForkSource != nil {
		return errors.New("real Pi fork did not establish independent native identity")
	}
	if err = forkHandle.Close(); err != nil {
		return err
	}
	if err = nativeSend(ctx, handle, "native-cancel", "CANCEL_PROOF"); err != nil {
		return err
	}
	select {
	case <-provider.holding:
	case <-ctx.Done():
		return ctx.Err()
	}
	snapshot := ordinaryStore.Read()
	activeRecord := ordinaryRecord
	activeRecord.SessionState = snapshot
	activeHistory, e := os.ReadFile(normal.SessionFile)
	if e != nil {
		return e
	}
	activeDiscussion, e := adapter.PrepareDiscussion(ctx, plugin.DiscussionRequest{Source: model.ThreadRecord{SessionRecord: activeRecord}, Tools: discussionTools, Instructions: threadvoice.DiscussionInstructions})
	if e != nil {
		return e
	}
	activeAnswer, e := activeDiscussion.Ask(ctx, "DISCUSSION_FIRST")
	closeActive := activeDiscussion.Close()
	if e != nil {
		return e
	}
	if closeActive != nil {
		return closeActive
	}
	if activeAnswer != "discussion-first-canary" {
		return errors.New("Pi active source discussion lost persisted history")
	}
	var activeSource pi.State
	if e = json.Unmarshal(ordinaryStore.Read(), &activeSource); e != nil {
		return e
	}
	stillRunning := false
	for _, execution := range activeSource.Executions {
		if execution.ExecutionID == "native-cancel" && execution.Status == "running" {
			stillRunning = true
		}
	}
	if !stillRunning {
		return errors.New("Pi discussion interrupted active source execution")
	}
	afterActive, e := os.ReadFile(normal.SessionFile)
	if e != nil {
		return e
	}
	if string(afterActive) != string(activeHistory) {
		return errors.New("Pi discussion changed active native source file")
	}
	fmt.Println("PASS Pi discussion during active source: persisted tree frozen read-only; source execution and JSONL unchanged after private close")
	if err = handle.Interrupt(ctx); err != nil {
		return err
	}
	if _, err = nativeWait(ctx, ordinaryStore, "native-cancel", "interrupted"); err != nil {
		return err
	}
	if err = handle.Close(); err != nil {
		return err
	}
	restoredStore := &nativeMemoryStore{raw: snapshot}
	open.SessionState = restoredStore
	restored, err := adapter.Open(ctx, open)
	if err != nil {
		return err
	}
	defer restored.Close()
	if _, err = nativeWait(ctx, restoredStore, "native-cancel", "interrupted"); err != nil {
		return err
	}
	if err = nativeSend(ctx, restored, "native-recovered", "RECOVERY_PROOF"); err != nil {
		return err
	}
	if _, err = nativeWait(ctx, restoredStore, "native-recovered", "completed"); err != nil {
		return err
	}
	if err = restored.Close(); err != nil {
		return err
	}
	fmt.Println("PASS real Pi lifecycle: native persistence, independent clone, cancellation, stale-running recovery, resumed execution")
	completion, err := adapter.Complete(ctx, plugin.PromptRequest{Settings: settings, Messages: []plugin.PromptMessage{{Role: "user", Content: "JSON_PROOF"}}, OutputFormat: plugin.PromptOutputFormat{Type: "json_schema", Schema: json.RawMessage(`{"type":"object","properties":{"ok":{"const":true}},"required":["ok"],"additionalProperties":false}`)}})
	if err != nil {
		return err
	}
	if completion.Output.Type != "json" || string(completion.Output.Value) != `{"ok":true}` {
		return fmt.Errorf("real Pi isolated completion mismatch: %+v", completion)
	}
	provider.mu.Lock()
	evidence := append([]nativeRequestEvidence{}, provider.requests...)
	failure := provider.failure
	blocked := append([]string{}, provider.blocked...)
	provider.mu.Unlock()
	if failure != "" {
		return errors.New(failure)
	}
	report, _ := json.MarshalIndent(map[string]any{"version": version, "network": "OS sandbox: loopback-only; non-loopback proxy requests rejected", "userConfiguration": "isolated HOME/PI_CODING_AGENT_DIR; real HOME writes denied", "hostToolCalls": toolCalls.Load(), "requests": evidence, "blockedExternalAttempts": blocked, "checks": []string{"provider/model/thinking exact selection", "actual Host .mjs loader and FD3", "actual read-guard .mjs loader and blocked native write", "native clone", "cancel/recovery", "isolated JSON completion"}}, "", "  ")
	if err = writeArtifact("native-evidence.json", report); err != nil {
		return err
	}
	if err = writeArtifact("native-state.json", restoredStore.Read()); err != nil {
		return err
	}
	if err = verifyNativeResponses(ctx, root, wrapper, env); err != nil {
		return err
	}
	fmt.Println("PASS real Pi local scripted Provider / isolated JSON completion / no paid or external model requests")
	return nil
}

func verifyNativeShutdown(ctx context.Context, root, executable string, env map[string]string) error {
	marker := filepath.Join(root, "shutdown.lock")
	quoted, _ := json.Marshal(marker)
	// Exercise the installed engine's own async session_shutdown dispatch. No
	// prompt is sent; a normal EOF must let this native owner release its lock.
	extension := `import { writeFileSync, unlinkSync } from "node:fs";
export default function (pi) {
  writeFileSync(` + string(quoted) + `, "locked", { flag: "wx" });
  pi.on("session_shutdown", async () => {
    await new Promise(resolve => setTimeout(resolve, 150));
    unlinkSync(` + string(quoted) + `);
  });
}
`
	path := filepath.Join(root, "shutdown-extension.mjs")
	if err := os.WriteFile(path, []byte(extension), 0600); err != nil {
		return err
	}
	evidence := []map[string]any{}
	for attempt := 1; attempt <= 2; attempt++ {
		session, err := pi.StartSession(ctx, pi.ProcessOptions{ExecutablePath: executable, Cwd: filepath.Join(root, "work"), Env: env,
			Args: []string{"--no-session", "--no-extensions", "--no-skills", "--no-prompt-templates", "--extension", path, "--provider", "mock", "--model", "mock-model"}})
		if err != nil {
			return fmt.Errorf("native shutdown start %d: %w", attempt, err)
		}
		if _, err := os.Stat(marker); err != nil {
			_ = session.Close()
			return fmt.Errorf("native shutdown hook did not load: %w", err)
		}
		before := time.Now()
		if err := session.Close(); err != nil {
			return err
		}
		if _, err := os.Stat(marker); !errors.Is(err, os.ErrNotExist) {
			return fmt.Errorf("native shutdown returned before the session_shutdown hook released its lock: %v", err)
		}
		evidence = append(evidence, map[string]any{"attempt": attempt, "version": session.Version, "closeDurationMs": time.Since(before).Milliseconds(), "lockReleased": true})
	}
	data, _ := json.MarshalIndent(evidence, "", "  ")
	if err := writeArtifact("native-shutdown.json", data); err != nil {
		return err
	}
	fmt.Println("PASS real Pi shutdown: stdin EOF awaits native session_shutdown lock cleanup; second native start succeeds without a model request")
	return nil
}

func nativeShellQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "'\\''") + "'"
}

type nativeMemoryStore struct {
	mu  sync.Mutex
	raw json.RawMessage
}

func (s *nativeMemoryStore) Read() json.RawMessage {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append(json.RawMessage(nil), s.raw...)
}
func (s *nativeMemoryStore) Commit(_ context.Context, raw json.RawMessage) error {
	s.mu.Lock()
	s.raw = append(json.RawMessage(nil), raw...)
	s.mu.Unlock()
	return nil
}
func nativeSend(ctx context.Context, handle plugin.Handle, id, text string) error {
	return handle.Send(ctx, plugin.SendRequest{ExecutionID: id, Input: model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: text}}}})
}
func nativeWait(ctx context.Context, store *nativeMemoryStore, id, status string) (pi.State, error) {
	timer := time.NewTimer(25 * time.Second)
	defer timer.Stop()
	ticker := time.NewTicker(10 * time.Millisecond)
	defer ticker.Stop()
	for {
		var state pi.State
		raw := store.Read()
		if len(raw) > 0 {
			if err := json.Unmarshal(raw, &state); err != nil {
				return state, err
			}
		}
		for _, execution := range state.Executions {
			if execution.ExecutionID == id {
				if execution.Status == status {
					return state, nil
				}
				if execution.Terminal() {
					reason := ""
					if execution.Error != nil {
						reason = *execution.Error
					}
					return state, fmt.Errorf("execution %s: expected %s, got %s: %s", id, status, execution.Status, reason)
				}
			}
		}
		select {
		case <-ctx.Done():
			return state, ctx.Err()
		case <-timer.C:
			return state, fmt.Errorf("native execution %s timed out; state=%s", id, raw)
		case <-ticker.C:
		}
	}
}

type nativeRequestEvidence struct {
	Marker     string   `json:"marker"`
	Model      string   `json:"model"`
	Tools      []string `json:"tools"`
	ToolResult bool     `json:"toolResult"`
}
type nativeScriptProvider struct {
	mu           sync.Mutex
	root, origin string
	requests     []nativeRequestEvidence
	blocked      []string
	failure      string
	holding      chan struct{}
}

func (p *nativeScriptProvider) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" || r.URL.Path != "/v1/chat/completions" || r.URL.IsAbs() {
		p.mu.Lock()
		p.blocked = append(p.blocked, r.Method+" "+r.URL.String())
		p.mu.Unlock()
		http.Error(w, "external traffic is forbidden in verification", 403)
		return
	}
	var request struct {
		Model    string `json:"model"`
		Stream   bool   `json:"stream"`
		Messages []struct {
			Role       string `json:"role"`
			Content    any    `json:"content"`
			ToolCallID string `json:"tool_call_id"`
		} `json:"messages"`
		Tools []struct {
			Function struct {
				Name string `json:"name"`
			} `json:"function"`
		} `json:"tools"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 4*1024*1024)).Decode(&request); err != nil {
		http.Error(w, err.Error(), 400)
		return
	}
	all := ""
	lastUser := ""
	toolResult := false
	for _, message := range request.Messages {
		encoded, _ := json.Marshal(message.Content)
		text := string(encoded)
		all += text + "\n"
		if message.Role == "user" {
			lastUser = text
			toolResult = false
		}
		if message.Role == "tool" {
			toolResult = true
		}
	}
	if strings.Contains(lastUser, "DISCUSSION_") {
		discussionNames := []string{}
		for _, tool := range request.Tools {
			discussionNames = append(discussionNames, tool.Function.Name)
		}
		p.discussionReply(w, r, discussionNames, all, lastUser, toolResult)
		return
	}
	marker := "NORMAL_PROOF"
	for _, candidate := range []string{"HOST_TOOL_PROOF", "READ_PROOF", "GUARD_ATTACK_PROOF", "FORK_PROOF", "CANCEL_PROOF", "RECOVERY_PROOF", "JSON_PROOF"} {
		if strings.Contains(lastUser, candidate) {
			marker = candidate
			break
		}
	}
	names := []string{}
	for _, tool := range request.Tools {
		names = append(names, tool.Function.Name)
	}
	p.mu.Lock()
	p.requests = append(p.requests, nativeRequestEvidence{Marker: marker, Model: request.Model, Tools: names, ToolResult: toolResult})
	if request.Model != "mock-model" || !request.Stream {
		p.failure = "Pi changed configured model or failed to request streaming"
	}
	if marker == "HOST_TOOL_PROOF" && (len(names) != 1 || names[0] != "multiply" || !strings.Contains(all, "MOKUSEI_NATIVE_HOST_INSTRUCTION")) {
		p.failure = "native Host extension did not enforce exclusive tool set/instructions"
	}
	p.mu.Unlock()
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.WriteHeader(200)
	flusher, _ := w.(http.Flusher)
	emit := func(delta any, finish any) {
		frame := map[string]any{"id": "pi-fixture-completion", "object": "chat.completion.chunk", "created": time.Now().Unix(), "model": "mock-model", "choices": []any{map[string]any{"index": 0, "delta": delta, "finish_reason": finish}}}
		encoded, _ := json.Marshal(frame)
		fmt.Fprintf(w, "data: %s\n\n", encoded)
		if flusher != nil {
			flusher.Flush()
		}
	}
	emit(map[string]any{"role": "assistant"}, nil)
	if marker == "CANCEL_PROOF" {
		select {
		case p.holding <- struct{}{}:
		default:
		}
		<-r.Context().Done()
		return
	}
	if marker == "HOST_TOOL_PROOF" && !toolResult {
		emit(map[string]any{"tool_calls": []any{map[string]any{"index": 0, "id": "native-multiply-1", "type": "function", "function": map[string]any{"name": "multiply", "arguments": `{"a":6,"b":7}`}}}}, nil)
		emit(map[string]any{}, "tool_calls")
	} else if marker == "GUARD_ATTACK_PROOF" && !toolResult {
		arguments, _ := json.Marshal(map[string]string{"path": filepath.Join(p.root, "guard-must-not-exist.txt"), "content": "guard failed"})
		emit(map[string]any{"tool_calls": []any{map[string]any{"index": 0, "id": "native-write-guard-1", "type": "function", "function": map[string]any{"name": "write", "arguments": string(arguments)}}}}, nil)
		emit(map[string]any{}, "tool_calls")
	} else {
		answer := "native fixture answer"
		if marker == "HOST_TOOL_PROOF" {
			if !strings.Contains(all, "42") {
				p.mu.Lock()
				p.failure = "native Host result did not reach next model request"
				p.mu.Unlock()
			}
			answer = "bridge result 42"
		}
		if marker == "GUARD_ATTACK_PROOF" {
			if !strings.Contains(all, "Thread reads may only answer from conversation history.") {
				p.mu.Lock()
				p.failure = "native read-guard block reason missing from tool result"
				p.mu.Unlock()
			}
			answer = "guard blocked write"
		}
		if marker == "JSON_PROOF" {
			answer = `{"ok":true}`
		}
		emit(map[string]any{"content": answer}, nil)
		emit(map[string]any{}, "stop")
	}
	usage, _ := json.Marshal(map[string]any{"id": "pi-fixture-completion", "object": "chat.completion.chunk", "created": time.Now().Unix(), "model": "mock-model", "choices": []any{}, "usage": map[string]int{"prompt_tokens": 20, "completion_tokens": 5, "total_tokens": 25}})
	fmt.Fprintf(w, "data: %s\n\ndata: [DONE]\n\n", usage)
	if flusher != nil {
		flusher.Flush()
	}
}

func nativeReadGuardProof(ctx context.Context, root, executable string, env map[string]string, snapshot string, provider *nativeScriptProvider) error {
	repository, err := os.Getwd()
	if err != nil {
		return err
	}
	for {
		if _, err := os.Stat(filepath.Join(repository, "go.mod")); err == nil {
			break
		}
		parent := filepath.Dir(repository)
		if parent == repository {
			return errors.New("run native verification from repository root to load production read-guard resource")
		}
		repository = parent
	}
	guard := filepath.Join(repository, "internal", "plugins", "harness", "pi", "resources", "read-guard.mjs")
	guardBytes, err := os.ReadFile(guard)
	if err != nil {
		return err
	}
	directory := filepath.Join(root, "direct-read-guard")
	if err = os.MkdirAll(directory, 0700); err != nil {
		return err
	}
	guard = filepath.Join(directory, "read-guard.mjs")
	if err = os.WriteFile(guard, guardBytes, 0600); err != nil {
		return err
	}
	source := filepath.Join(directory, "source.jsonl")
	if err = os.WriteFile(source, []byte(snapshot), 0600); err != nil {
		return err
	}
	nativeEnv := map[string]string{}
	for k, v := range env {
		nativeEnv[k] = v
	}
	models, err := os.ReadFile(filepath.Join(env["PI_CODING_AGENT_DIR"], "models.json"))
	if err != nil {
		return err
	}
	nativeEnv["PI_CODING_AGENT_DIR"] = filepath.Join(directory, "agent")
	if err = os.MkdirAll(nativeEnv["PI_CODING_AGENT_DIR"], 0700); err != nil {
		return err
	}
	if err = os.WriteFile(filepath.Join(nativeEnv["PI_CODING_AGENT_DIR"], "models.json"), models, 0600); err != nil {
		return err
	}
	session, err := pi.StartSession(ctx, pi.ProcessOptions{ExecutablePath: executable, Cwd: filepath.Join(root, "work"), Env: nativeEnv, Args: []string{"--session-dir", directory, "--fork", source, "--provider", "mock", "--model", "mock-model", "--thinking", "off", "-e", guard}})
	if err != nil {
		return err
	}
	defer session.Close()
	commands, err := session.Commands(ctx)
	if err != nil {
		return err
	}
	loaded := false
	for _, command := range commands {
		if command.Name == "mokusei-thread-read-guard" && command.Source == "extension" && command.SourcePath == guard {
			loaded = true
		}
	}
	if !loaded {
		return errors.New("real Pi did not register production read-guard extension")
	}
	var blocked atomic.Bool
	session.Subscribe(func(event pi.Event) {
		if event.Type == "tool" && event.Phase == "end" && event.Name == "write" && event.IsError && strings.Contains(event.Text, "Thread reads may only answer from conversation history.") {
			blocked.Store(true)
		}
	})
	result, err := session.Complete(ctx, pi.PromptInput{Message: "GUARD_ATTACK_PROOF: attempt writing the requested sentinel file."}, pi.CompletionPolicy{})
	if err != nil {
		return fmt.Errorf("actual read guard native run: %w", err)
	}
	if err = session.FlushEvents(ctx); err != nil {
		return err
	}
	if !blocked.Load() || result.Text != "guard blocked write" {
		return errors.New("actual native read guard did not block the write at its tool hook")
	}
	if _, err = os.Stat(filepath.Join(root, "guard-must-not-exist.txt")); !errors.Is(err, os.ErrNotExist) {
		return errors.New("read-only guard allowed native file modification")
	}
	after, err := os.ReadFile(source)
	if err != nil {
		return err
	}
	if string(after) != snapshot {
		return errors.New("read-only native fork modified source snapshot")
	}
	return nil
}
