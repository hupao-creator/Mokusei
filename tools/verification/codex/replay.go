package main

import (
	"context"
	"encoding/json"
	"fmt"
	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/codex"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"syscall"
	"time"
)

func runSynthetic(ctx context.Context, root string) error {
	if err := verifyUnicodeState(); err != nil {
		return err
	}
	environment, e := isolatedEnvironment(root)
	if e != nil {
		return e
	}
	environment["MOKUSEI_CODEX_REPLAY_PEER"] = "1"
	environment["MOKUSEI_CODEX_REPLAY_ROOT"] = root
	self, e := os.Executable()
	if e != nil {
		return e
	}
	binary := filepath.Join(root, "codex-fixture")
	if e = os.Symlink(self, binary); e != nil {
		return e
	}
	if e = verifyStreaming(ctx, filepath.Join(root, "stream"), binary); e != nil {
		return e
	}
	if e = verifyConnectionRecovery(ctx, filepath.Join(root, "connection-recovery"), binary); e != nil {
		return e
	}
	if e = verifyCanonicalClose(ctx, filepath.Join(root, "canonical-close"), binary); e != nil {
		return e
	}
	if e = verifyFollowUpSettlement(ctx, filepath.Join(root, "follow-up-settlement"), binary); e != nil {
		return e
	}
	if e = verifyVoiceConfiguration(ctx, filepath.Join(root, "voice-configuration"), binary); e != nil {
		return e
	}
	if e = verifyRequiredServiceTier(ctx, filepath.Join(root, "service-tier"), binary); e != nil {
		return e
	}
	if e = verifyBackgroundHistory(ctx, filepath.Join(root, "background-history"), binary); e != nil {
		return e
	}
	if e = verifyLaunchCatalogCache(ctx, root, binary, environment); e != nil {
		return e
	}
	environment["MOKUSEI_CODEX_REPLAY_LAUNCH_CAPTURE"] = filepath.Join(root, "voice-launch.jsonl")
	store := &memoryStore{}
	adapter := codex.New(host(root, environment))
	defer adapter.Close()
	if e = verifyPromptSteering(ctx, adapter, binary); e != nil {
		return e
	}
	settings := object{"executablePath": binary, "model": "gpt-6-luna", "thinking": object{"mode": "effort", "effort": "low"}, "serviceTier": "default", "permissionMode": "ask-for-approval", "approvalPolicy": "on-request", "approvalsReviewer": "user", "sandbox": "workspace-write"}
	record := model.SessionRecord{ID: "fixture-host-thread", CreatedAt: time.Now().UnixMilli(), Cwd: filepath.Join(root, "work"), Settings: encoded(settings)}
	handle, e := adapter.Open(ctx, plugin.OpenContext{ThreadID: record.ID, RequireExplicitSettings: true, ReadThread: func() model.SessionRecord { return record }, SessionState: store})
	if e != nil {
		return e
	}
	defer handle.Close()
	var admissions atomic.Int64
	send := func(id, input string) error {
		return handle.Send(ctx, plugin.SendRequest{ExecutionID: id, Input: model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: input}}}, Admitted: func() error { admissions.Add(1); return nil }})
	}
	if e = send("fixture-execution", "Hello"); e != nil {
		return e
	}
	execution, e := awaitExecution(ctx, adapter, store, handle, true)
	if e != nil {
		return e
	}
	if e = check(execution.Summary != nil && *execution.Summary == "Hello fixture" && admissions.Load() == 1, "streamed final or admission callback mismatched"); e != nil {
		return e
	}
	fmt.Printf("PASS synthetic explicit thinking and service tier / stream-before-ACK / approval / final projection (%d durable commits)\n", store.Count())
	answer, e := handle.Read(ctx, "fixture source")
	if e != nil {
		return e
	}
	if e = check(answer == "Fixture read/tool answer", "read fork answer mismatch"); e != nil {
		return e
	}
	fmt.Println("PASS synthetic isolated history read")
	record.SessionState = store.Read()
	fork, e := adapter.Fork(ctx, plugin.ForkRequest{Source: model.ThreadRecord{SessionRecord: record}, Request: encoded(object{})})
	if e != nil {
		return e
	}
	if e = check(decoded(fork.SessionState)["primarySessionId"] == "fixture-fork", "fork did not return independent native identity"); e != nil {
		return e
	}
	fmt.Println("PASS synthetic native fork identity")
	if e = send("fixture-steered", "fixture-steer"); e != nil {
		return e
	}
	if e = send("fixture-followup", "follow-up input"); e != nil {
		return e
	}
	execution, e = awaitExecution(ctx, adapter, store, handle, false)
	if e != nil {
		return e
	}
	if e = check(execution.ExecutionID == "fixture-steered" && execution.Summary != nil && *execution.Summary == "Steered fixture" && admissions.Load() == 3, "steering changed execution identity or lost per-input admission"); e != nil {
		return e
	}
	fmt.Println("PASS synthetic steering / per-input durable admission")
	if e = send("fixture-interrupted", "fixture-interrupt"); e != nil {
		return e
	}
	if e = handle.Interrupt(ctx); e != nil {
		return e
	}
	for {
		ob, e := adapter.SessionState().Project(store.Read())
		if e != nil {
			return e
		}
		if ob.LatestExecution != nil && ob.LatestExecution.Status == "interrupted" {
			break
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(5 * time.Millisecond):
		}
	}
	fmt.Println("PASS synthetic interrupt settlement")
	native, ok := handle.(plugin.NativeVoiceCapability)
	if !ok {
		return fmt.Errorf("native voice capability unavailable")
	}
	voice, e := native.PrepareNativeVoice(ctx, []plugin.ContextEntry{{ID: "fixture", Content: "safe replay"}})
	if e != nil {
		return e
	}
	launches := launchCount(environment["MOKUSEI_CODEX_REPLAY_LAUNCH_CAPTURE"], "initialize")
	if e = verifyVoiceEvents(ctx, voice); e != nil {
		return e
	}
	for launchCount(environment["MOKUSEI_CODEX_REPLAY_LAUNCH_CAPTURE"], "initialize") == launches {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(time.Millisecond):
		}
	}
	warmCount := launchCount(environment["MOKUSEI_CODEX_REPLAY_LAUNCH_CAPTURE"], "initialize")
	voice, e = native.PrepareNativeVoice(ctx, []plugin.ContextEntry{{ID: "fixture", Content: "safe replay"}})
	if e != nil {
		return e
	}
	if launchCount(environment["MOKUSEI_CODEX_REPLAY_LAUNCH_CAPTURE"], "initialize") != warmCount {
		return fmt.Errorf("reopening voice started another process instead of using its prewarmed connection")
	}
	if e = verifyVoiceEvents(ctx, voice); e != nil {
		return e
	}
	fmt.Println("PASS native voice fresh-process prewarm / reopen / unrelated-thread late event isolation")
	if e = handle.Close(); e != nil {
		return e
	}
	resumed, e := adapter.Open(ctx, plugin.OpenContext{ThreadID: record.ID, ReadThread: func() model.SessionRecord { return record }, SessionState: store})
	if e != nil {
		return e
	}
	if e = resumed.Send(ctx, plugin.SendRequest{ExecutionID: "fixture-resumed", Input: model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "Hello"}}}}); e != nil {
		return e
	}
	if _, e = awaitExecution(ctx, adapter, store, resumed, true); e != nil {
		return e
	}
	if e = resumed.Close(); e != nil {
		return e
	}
	fmt.Println("PASS synthetic persisted session resume")
	for _, method := range []string{"crash", "malformed"} {
		server, e := codex.StartAppServer(ctx, codex.LaunchOptions{Executable: binary, Cwd: record.Cwd, Environment: environmentList(environment)})
		if e != nil {
			return e
		}
		started := time.Now()
		_, callError := server.Call(ctx, method, object{})
		closeError := server.Close()
		if callError == nil || time.Since(started) > 4*time.Second {
			return fmt.Errorf("%s did not fail promptly: %v", method, callError)
		}
		if closeError != nil {
			return closeError
		}
		if method == "crash" {
			bytes, e := os.ReadFile(filepath.Join(root, "child.pid"))
			if e != nil {
				return e
			}
			pid, e := strconv.Atoi(strings.TrimSpace(string(bytes)))
			if e != nil {
				return e
			}
			deadline := time.Now().Add(time.Second)
			for syscall.Kill(pid, 0) == nil && time.Now().Before(deadline) {
				time.Sleep(10 * time.Millisecond)
			}
			if syscall.Kill(pid, 0) == nil {
				return fmt.Errorf("fixture descendant survived process group cleanup")
			}
		}
		fmt.Println("PASS synthetic transport", method, "and process-group retirement")
	}
	toolStore := &memoryStore{}
	var called atomic.Bool
	tools, e := adapter.Open(ctx, plugin.OpenContext{ThreadID: "fixture-tools", ReadThread: func() model.SessionRecord { return record }, SessionState: toolStore, Injection: &plugin.Injection{Tools: &plugin.ToolInjection{Mode: "extend", Bindings: []plugin.ToolBinding{{Name: "echo_fixture", Description: "fixture", InputSchema: encoded(object{"type": "object", "properties": object{"text": object{"type": "string"}}}), Execute: func(ctx context.Context, call plugin.ToolCall) (json.RawMessage, error) {
		called.Store(true)
		return call.Arguments, nil
	}}}}}})
	if e != nil {
		return e
	}
	defer tools.Close()
	if e = tools.Send(ctx, plugin.SendRequest{ExecutionID: "fixture-tools", Input: model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "fixture-tool"}}}}); e != nil {
		return e
	}
	if _, e = awaitExecution(ctx, adapter, toolStore, tools, false); e != nil {
		return e
	}
	if !called.Load() {
		return fmt.Errorf("private MCP callback never ran")
	}
	if e = tools.Close(); e != nil {
		return e
	}
	fmt.Println("PASS synthetic authenticated MCP tool injection")
	return nil
}
