package main

import (
	"context"
	"encoding/json"
	"fmt"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/codex"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	core "github.com/hupao-creator/Mokusei/internal/core/runtime"
)

func (p *peer) recoveryFixture(method string, params object, id any) (bool, error) {
	root := os.Getenv("MOKUSEI_CODEX_REPLAY_ROOT")
	if method == "account/read" {
		marker := filepath.Join(root, "fail-backend-once")
		if _, err := os.Stat(marker); err == nil {
			if err = os.Remove(marker); err != nil {
				return true, err
			}
			return true, p.send(object{"id": id, "error": object{"code": -32001, "message": "fixture backend temporarily unavailable"}})
		}
	}
	if method == "turn/start" || method == "turn/steer" {
		file, err := os.OpenFile(filepath.Join(root, "recovery-dispatch.jsonl"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0600)
		if err != nil {
			return true, err
		}
		_, err = file.Write(append(encoded(object{"method": method, "input": params["input"], "pid": os.Getpid(), "executionId": params["clientUserMessageId"]}), '\n'))
		closeErr := file.Close()
		if err != nil || closeErr != nil {
			return true, fmt.Errorf("capture recovery dispatch: %v %v", err, closeErr)
		}
	}
	if method == "thread/inject_items" && strings.Contains(string(encoded(params["items"])), "fixture-voice-takeover") {
		if err := p.send(object{"id": id, "result": object{}}); err != nil {
			return true, err
		}
		if err := p.event("thread/realtime/itemAdded", object{"threadId": p.session, "item": object{"type": "handoff_request", "handoff_id": "voice-takeover-request", "input_transcript": "Voice takeover"}}); err != nil {
			return true, err
		}
		p.turnNumber++
		p.turn = fmt.Sprintf("fixture-turn-%d", p.turnNumber)
		if err := p.event("turn/started", object{"threadId": p.session, "turn": object{"id": p.turn}}); err != nil {
			return true, err
		}
		return true, p.completed("Voice takeover completed")
	}
	input := ""
	for _, part := range list(params["input"]) {
		input += text(record(part)["text"])
	}
	if method == "turn/start" && input == "Read the source" && p.recoveryMode == "interrupt" {
		// The successor has been staged, but has no turn ID yet. These retired
		// turn messages must never attach to the fresh execution.
		for _, event := range []struct {
			method string
			params object
		}{
			{"item/agentMessage/delta", object{"threadId": p.session, "turnId": p.turn, "itemId": "late-old-answer", "delta": "LATE OLD OUTPUT"}},
			{"error", object{"threadId": p.session, "turnId": p.turn, "willRetry": false, "message": "LATE OLD FAILURE"}},
			{"turn/completed", object{"threadId": p.session, "turn": object{"id": p.turn, "status": "failed", "error": object{"message": "LATE OLD FAILURE"}}}},
		} {
			if err := p.event(event.method, event.params); err != nil {
				return true, err
			}
		}
	}
	if method == "turn/start" && strings.HasPrefix(input, "fixture-recovery-") {
		p.recoveryMode = strings.TrimPrefix(input, "fixture-recovery-")
		p.turnNumber++
		p.turn = fmt.Sprintf("fixture-turn-%d", p.turnNumber)
		if err := p.event("turn/started", object{"threadId": p.session, "turn": object{"id": p.turn}}); err != nil {
			return true, err
		}
		if err := p.send(object{"id": id, "result": object{"turn": object{"id": p.turn}}}); err != nil {
			return true, err
		}
		count := 1
		if p.recoveryMode == "progress" {
			count = 4
		}
		for i := 0; i < count; i++ {
			if err := p.retryEvent(); err != nil {
				return true, err
			}
		}
		if p.recoveryMode == "long-tool" {
			item := object{"id": "recovered-tool", "type": "commandExecution", "command": "long healthy command"}
			if err := p.event("item/started", object{"threadId": p.session, "turnId": p.turn, "item": item}); err != nil {
				return true, err
			}
			// Deliberately longer than the production retry window. There is no
			// test-only timeout override in the adapter.
			time.Sleep(63 * time.Second)
			item["status"] = "completed"
			if err := p.event("item/completed", object{"threadId": p.session, "turnId": p.turn, "item": item}); err != nil {
				return true, err
			}
			return true, p.completed("Healthy long tool completed")
		}
		return true, nil
	}
	if method == "turn/steer" && p.recoveryMode != "" {
		if err := p.send(object{"id": id, "result": object{}}); err != nil {
			return true, err
		}
		if p.recoveryMode == "interrupt" {
			return true, nil
		}
		if p.recoveryMode == "silent" {
			if err := p.event("thread/status/changed", object{"threadId": p.session, "status": object{"type": "active"}}); err != nil {
				return true, err
			}
			// Acknowledged user input and status are not model progress.
			return true, p.event("item/completed", object{"threadId": p.session, "turnId": p.turn, "item": object{"id": "follow-up", "type": "userMessage", "content": params["input"]}})
		}
		if p.recoveryMode == "progress" {
			if err := p.event("item/agentMessage/delta", object{"threadId": p.session, "turnId": p.turn, "itemId": "recovered-output", "delta": "Recovered"}); err != nil {
				return true, err
			}
		}
		for i := 0; i < 4; i++ {
			if err := p.retryEvent(); err != nil {
				return true, err
			}
		}
		if p.recoveryMode == "progress" {
			return true, p.completed("Recovered progress")
		}
		return true, nil
	}
	return false, nil
}

func (p *peer) retryEvent() error {
	return p.event("error", object{"threadId": p.session, "turnId": p.turn, "willRetry": true, "error": object{"message": "fixture TLS handshake EOF; reconnecting"}})
}

func verifyConnectionRecovery(ctx context.Context, root, binary string) error {
	modes := []string{"storm", "silent", "progress", "long-tool", "interrupt", "backend", "voice"}
	type result struct {
		mode string
		err  error
	}
	results := make(chan result, len(modes))
	for _, mode := range modes {
		go func() {
			results <- result{mode, verifyConnectionRecoveryCase(ctx, filepath.Join(root, mode), binary, mode)}
		}()
	}
	var first error
	for range modes {
		out := <-results
		if out.err != nil && first == nil {
			first = fmt.Errorf("connection recovery %s: %w", out.mode, out.err)
		}
	}
	if first == nil {
		fmt.Println("PASS Codex connection recovery: bounded retries and silence, status/follow-up exclusion, progress reset, healthy 63s tool, interrupt settlement, native capabilities independent of account probes and exactly-once successor")
	}
	return first
}

func verifyConnectionRecoveryCase(lifetime context.Context, root, binary, mode string) error {
	ctx, cancel := context.WithTimeout(lifetime, 80*time.Second)
	defer cancel()
	if mode == "voice" {
		return verifyVoiceOwnerRecovery(ctx, root, binary)
	}
	if mode == "backend" {
		return verifyBackendRecovery(ctx, root, binary)
	}
	r, db, adapter, err := backgroundRuntime(lifetime, root)
	if err != nil {
		return err
	}
	defer db.Close()
	defer adapter.Close()
	defer r.Close(context.Background())
	input := func(s string) model.AgentInput {
		return model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: s}}}
	}
	settings := object{"executablePath": binary, "model": "gpt-6-luna", "thinking": object{"mode": "effort", "effort": "low"}, "serviceTier": "default", "permissionMode": "full-access"}
	started := time.Now()
	created, err := r.CreateThread(ctx, core.CreateThreadRequest{HarnessID: "codex", Cwd: filepath.Join(root, "work"), Settings: encoded(settings), Input: input("fixture-recovery-" + mode)})
	if err != nil {
		return err
	}
	id := created.Record.ID
	if mode == "interrupt" {
		// A steering round trip establishes completed turn/start admission before
		// racing interruption with the armed retry watchdog.
		if _, err = r.SendThread(ctx, id, input("interrupt-barrier")); err != nil {
			return err
		}
		if _, err = r.Invoke(ctx, "thread:interrupt", []json.RawMessage{encoded(model.CancellationRequest{ThreadID: id, ExpectedCancellationID: created.Record.CancellationID})}); err != nil {
			return err
		}
	} else if mode == "storm" || mode == "progress" || mode == "silent" {
		if mode == "silent" {
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(5 * time.Second):
			}
		}
		if _, err = r.Invoke(ctx, "thread:follow-up", []json.RawMessage{encoded(object{"threadId": id, "input": input("accepted-follow-up")})}); err != nil {
			return err
		}
	}
	settled, err := waitBackground(ctx, r, id, false)
	if err != nil {
		return err
	}
	expected := "failed"
	if mode == "progress" || mode == "long-tool" {
		expected = "completed"
	} else if mode == "interrupt" {
		expected = "interrupted"
	}
	if got := settled.Observation.LatestExecution.Status; got != expected {
		return fmt.Errorf("expected %s, got %s", expected, got)
	}
	if mode == "silent" && time.Since(started) > 64*time.Second {
		return fmt.Errorf("user/status traffic extended the recovery window: %s", time.Since(started))
	}
	if _, err = r.Invoke(ctx, "thread:follow-up", []json.RawMessage{encoded(object{"threadId": id, "input": input("Read the source")})}); err != nil {
		return err
	}
	successor, err := waitBackground(ctx, r, id, false)
	if err != nil {
		return err
	}
	if strings.Contains(string(successor.SessionState), "LATE OLD") {
		return fmt.Errorf("retired native turn polluted successor")
	}
	if successor.Observation.LatestExecution.ExecutionID == created.Execution.ExecutionID || successor.Observation.LatestExecution.Status != "completed" {
		return fmt.Errorf("new input did not complete as a fresh execution: %+v", successor.Observation.LatestExecution)
	}
	capture, err := os.ReadFile(filepath.Join(root, "recovery-dispatch.jsonl"))
	if err != nil {
		return err
	}
	counts := map[string]int{}
	pids := map[string]float64{}
	for _, line := range strings.Split(strings.TrimSpace(string(capture)), "\n") {
		request := decoded([]byte(line))
		if request["method"] == "turn/start" {
			executionID := text(request["executionId"])
			counts[executionID]++
			pids[executionID], _ = request["pid"].(float64)
		}
	}
	successorID := successor.Observation.LatestExecution.ExecutionID
	if counts[created.Execution.ExecutionID] != 1 || counts[successorID] != 1 {
		return fmt.Errorf("original/successor dispatch counts = %d/%d, want 1/1", counts[created.Execution.ExecutionID], counts[successorID])
	}
	if (mode == "storm" || mode == "silent") && pids[created.Execution.ExecutionID] == pids[successorID] {
		return fmt.Errorf("failed native owner was reused by successor")
	}
	return nil
}

func verifyBackendRecovery(ctx context.Context, root, binary string) error {
	env, err := isolatedEnvironment(root)
	if err != nil {
		return err
	}
	env["MOKUSEI_CODEX_REPLAY_PEER"] = "1"
	env["CODEX_CLI_PATH"] = binary
	env["MOKUSEI_CODEX_REPLAY_ROOT"] = root
	env["MOKUSEI_CODEX_REPLAY_MODEL"] = "gpt-6.1-sol"
	if err = os.WriteFile(filepath.Join(root, "fail-backend-once"), []byte("fail"), 0600); err != nil {
		return err
	}
	a := codex.New(host(root, env))
	defer a.Close()
	settings := object{"executablePath": binary, "model": "gpt-6.1-sol", "thinking": object{"mode": "effort", "effort": "medium"}, "serviceTier": "default", "permissionMode": "full-access"}
	record := model.SessionRecord{ID: "backend-recovery", CreatedAt: time.Now().UnixMilli(), Cwd: filepath.Join(root, "work"), Settings: encoded(settings)}
	store := &memoryStore{}
	h, err := a.Open(ctx, plugin.OpenContext{ThreadID: record.ID, ReadThread: func() model.SessionRecord { return record }, SessionState: store, RequireExplicitSettings: true})
	if err != nil {
		return err
	}
	defer h.Close()
	send := func(id string) error {
		return h.Send(ctx, plugin.SendRequest{ExecutionID: id, Input: model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "Read the source"}}}})
	}
	if err = send("native-catalog"); err != nil {
		return fmt.Errorf("native model execution depended on an account probe: %w", err)
	}
	execution, err := awaitExecution(ctx, a, store, h, false)
	if err != nil {
		return err
	}
	if execution.Status != "completed" {
		return fmt.Errorf("native model execution did not complete")
	}
	if _, err = os.Stat(filepath.Join(root, "fail-backend-once")); err != nil {
		return fmt.Errorf("ordinary native execution queried account authority: %w", err)
	}
	// Model provenance still needs account evidence and must preserve its error.
	_, err = a.ModelCatalog(ctx, plugin.SettingsRequest{Cwd: record.Cwd})
	if err == nil || !strings.Contains(err.Error(), "fixture backend temporarily unavailable") {
		return fmt.Errorf("account provenance lost its original probe failure: %v", err)
	}
	externalEnv := map[string]string{}
	for key, value := range env {
		externalEnv[key] = value
	}
	externalEnv["CODEX_CLI_PATH"] = binary
	externalEnv["OPENAI_API_KEY"] = "synthetic-external-account"
	external := codex.New(host(root, externalEnv))
	defer external.Close()
	voice, err := external.PrepareVoice(ctx, "fixture")
	if err == nil {
		_ = voice.Stop(ctx)
		return fmt.Errorf("external account incorrectly acquired native ChatGPT voice")
	}
	return check(strings.Contains(err.Error(), "原生 ChatGPT 登录"), "native voice lost its account authority check: "+err.Error())
}
