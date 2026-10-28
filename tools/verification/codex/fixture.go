package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
)

type peer struct {
	encoder           *json.Encoder
	writeMu           sync.Mutex
	delayedSettlement bool
	session, turn     string
	turnNumber        int
	bridge            object
	serviceTier       string
	background        *exec.Cmd
	backgroundMode    string
	recoveryMode      string
	settlementMode    string
	holdSettlement    bool
	earlySpeeches     int
}

func (p *peer) send(value any) error {
	p.writeMu.Lock()
	defer p.writeMu.Unlock()
	return p.encoder.Encode(value)
}
func (p *peer) event(method string, params object) error {
	return p.send(object{"method": method, "params": params})
}
func (p *peer) completed(answer string) error {
	item := object{"type": "agentMessage", "id": "answer-" + p.turn, "text": answer, "phase": "final_answer"}
	if e := p.event("item/completed", object{"threadId": p.session, "turnId": p.turn, "item": item}); e != nil {
		return e
	}
	return p.event("turn/completed", object{"threadId": p.session, "turn": object{"id": p.turn, "status": "completed", "items": []any{item}}})
}
func fixtureMain() error {
	if len(os.Args) > 1 && os.Args[1] == "--fixture-descendant" {
		time.Sleep(5 * time.Minute)
		return nil
	}
	for _, arg := range os.Args[1:] {
		switch arg {
		case "--version":
			fmt.Println("codex-cli 0.164.0")
			return nil
		case "debug":
			if err := captureVoiceLaunch("catalog"); err != nil {
				return err
			}
			return json.NewEncoder(os.Stdout).Encode(object{"models": []any{object{"slug": fixtureModel(), "display_name": "Luna", "input_modalities": []string{"text"}, "context_window": 128000, "supports_reasoning_summaries": true, "supported_reasoning_levels": []any{object{"effort": fixtureEffort(), "description": fixtureEffort()}}}}})
		}
	}
	p := &peer{encoder: json.NewEncoder(os.Stdout), session: "fixture-thread"}
	if root := os.Getenv("MOKUSEI_SETTINGS_PERFORMANCE"); root != "" {
		if err := os.WriteFile(filepath.Join(root, fmt.Sprintf("start-%d", os.Getpid())), nil, 0600); err != nil {
			return err
		}
		time.Sleep(200 * time.Millisecond)
	}
	// Normal owner retirement must reap the fixture's child before its leader
	// exits. Otherwise macOS can leave an orphan zombie whose group probe is
	// EPERM. Explicit crash branches still use os.Exit and exercise uncertainty.
	stopping := make(chan os.Signal, 1)
	signal.Notify(stopping, syscall.SIGTERM)
	finished := make(chan struct{})
	defer close(finished)
	defer signal.Stop(stopping)
	defer func() {
		if p.background != nil {
			_ = p.background.Process.Kill()
			_ = p.background.Wait()
		}
	}()
	go func() {
		select {
		case <-stopping:
			_ = os.Stdin.Close()
		case <-finished:
		}
	}()
	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 64*1024), 16*1024*1024)
	for scanner.Scan() {
		frame := object{}
		if e := json.Unmarshal(scanner.Bytes(), &frame); e != nil {
			return e
		}
		if e := p.receive(frame); e != nil {
			return e
		}
	}
	return scanner.Err()
}
func (p *peer) receive(frame object) error {
	method := text(frame["method"])
	params := record(frame["params"])
	id := frame["id"]
	if handled, err := p.streamFixture(method, params, id); handled {
		return err
	}
	if method == "" {
		if id == float64(99) {
			if record(frame["result"])["decision"] != "accept" {
				return fmt.Errorf("fixture expected native accept decision")
			}
			return p.completed("Hello fixture")
		}
		return nil
	}
	if id == nil {
		return nil
	}
	if handled, err := p.voiceConfigurationFixture(method, params, id); handled {
		return err
	}
	if handled, err := p.voiceReceiptFixture(method, params, id); handled {
		return err
	}
	if handled, err := p.recoveryFixture(method, params, id); handled {
		return err
	}
	if handled, err := p.settlementFixture(method, params, id); handled {
		return err
	}
	if path := os.Getenv("MOKUSEI_CODEX_REPLAY_TIER_CAPTURE"); path != "" && (strings.HasPrefix(method, "thread/") || method == "turn/start") {
		_, present := params["serviceTier"]
		data := encoded(object{"method": method, "serviceTier": params["serviceTier"], "present": present})
		file, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0600)
		if err != nil {
			return err
		}
		_, err = file.Write(append(data, '\n'))
		closeErr := file.Close()
		if err != nil {
			return err
		}
		if closeErr != nil {
			return closeErr
		}
	}
	result := object{}
	switch method {
	case "initialize":
		if err := captureVoiceLaunch("initialize"); err != nil {
			return err
		}
		result["userAgent"] = "codex-cli/0.164.0 (fixture)"
		if agent, ok := os.LookupEnv("MOKUSEI_CODEX_REPLAY_USER_AGENT"); ok {
			result["userAgent"] = agent
		}
	case "config/read":
		tier := os.Getenv("MOKUSEI_CODEX_REPLAY_DEFAULT_TIER")
		if tier == "" {
			tier = "default"
		}
		result["config"] = object{"model": fixtureModel(), "model_provider": "openai", "approvals_reviewer": "user", "approval_policy": "on-request", "sandbox_mode": "workspace-write", "service_tier": tier}
		if raw := os.Getenv("MOKUSEI_CODEX_REPLAY_FEATURES"); raw != "" {
			features := object{}
			if err := json.Unmarshal([]byte(raw), &features); err != nil {
				return err
			}
			record(result["config"])["features"] = features
		}
	case "configRequirements/read":
		result["requirements"] = nil
	case "account/read":
		result["account"] = object{"type": "chatgpt"}
	case "model/list":
		result["data"] = []any{object{"model": fixtureModel(), "displayName": "Luna", "isDefault": true, "supportsReasoning": true, "supportedReasoningEfforts": []any{object{"reasoningEffort": fixtureEffort()}}, "defaultReasoningEffort": fixtureEffort(), "serviceTiers": []any{object{"id": "priority"}}, "defaultServiceTier": nil}}
	case "skills/list", "plugin/installed":
		result["data"] = []any{}
		result["marketplaces"] = []any{}
	case "thread/start", "thread/resume", "thread/fork":
		p.bridge = record(record(record(params["config"])["mcp_servers"])["mokusei_injected"])
		if method == "thread/resume" {
			p.session = text(params["threadId"])
		}
		if method == "thread/fork" {
			p.session = "fixture-fork"
		}
		sandbox := map[string]string{"workspace-write": "workspaceWrite", "read-only": "readOnly", "danger-full-access": "dangerFullAccess"}[text(params["sandbox"])]
		p.serviceTier = text(params["serviceTier"])
		if p.serviceTier == "" {
			p.serviceTier = os.Getenv("MOKUSEI_CODEX_REPLAY_DEFAULT_TIER")
		}
		if p.serviceTier == "" {
			p.serviceTier = "default"
		}
		var reportedTier any = p.serviceTier
		if reportedTier == "default" {
			reportedTier = nil
		}
		result = object{"thread": object{"id": p.session}, "model": fixtureModel(), "serviceTier": reportedTier, "sandbox": object{"type": sandbox}, "reasoningEffort": record(params["config"])["model_reasoning_effort"], "approvalPolicy": params["approvalPolicy"], "approvalsReviewer": params["approvalsReviewer"]}
		switch os.Getenv("MOKUSEI_CODEX_REPLAY_TIER_REPLY") {
		case "missing":
			delete(result, "serviceTier")
		case "mismatch":
			result["serviceTier"] = "priority"
		}
	case "turn/start":
		if tier := text(params["serviceTier"]); tier != "" {
			p.serviceTier = tier
		}
		if directory := os.Getenv("MOKUSEI_CODEX_REPLAY_CAPTURE_DIR"); directory != "" {
			data, err := json.Marshal(params)
			if err != nil {
				return err
			}
			if err = os.WriteFile(filepath.Join(directory, fmt.Sprintf("input-%d-%d.json", os.Getpid(), p.turnNumber)), data, 0600); err != nil {
				return err
			}
		}
		p.turnNumber++
		p.turn = fmt.Sprintf("fixture-turn-%d", p.turnNumber)
		parts := []string{}
		for _, v := range list(params["input"]) {
			parts = append(parts, text(record(v)["text"]))
		}
		input := strings.Join(parts, " ")
		if e := p.event("turn/started", object{"threadId": p.session, "turn": object{"id": p.turn}}); e != nil {
			return e
		}
		if strings.Contains(input, "fixture-tool") || strings.Contains(input, "Read the source") || strings.Contains(input, "Answer using only") {
			if strings.Contains(input, "fixture-tool") {
				if e := p.callTool(); e != nil {
					return e
				}
			}
			if e := p.send(object{"id": id, "result": object{"turn": object{"id": p.turn}}}); e != nil {
				return e
			}
			return p.completed("Fixture read/tool answer")
		}
		if strings.Contains(input, "<task-notification>") {
			if err := p.send(object{"id": id, "result": object{"turn": object{"id": p.turn}}}); err != nil {
				return err
			}
			return p.completed("Background reported")
		}
		if strings.Contains(input, "fixture-background:") {
			p.backgroundMode = strings.TrimPrefix(input, "fixture-background:")
			if err := p.event("hook/started", object{"threadId": p.session, "turnId": p.turn, "run": object{"id": "stale-hook", "name": "PreToolUse"}}); err != nil {
				return err
			}
			if p.backgroundMode != "hook" {
				binary, err := os.Executable()
				if err != nil {
					return err
				}
				p.background = exec.Command(binary, "--fixture-descendant")
				p.background.Env = os.Environ()
				if err = p.background.Start(); err != nil {
					return err
				}
				if err = os.WriteFile(filepath.Join(os.Getenv("MOKUSEI_CODEX_REPLAY_ROOT"), "background.pid"), []byte(fmt.Sprint(p.background.Process.Pid)), 0600); err != nil {
					return err
				}
				if err = p.event("item/started", object{"threadId": p.session, "turnId": p.turn, "item": object{"type": "commandExecution", "id": "background-command", "command": "fixture worker"}}); err != nil {
					return err
				}
			}
			if err := p.send(object{"id": id, "result": object{"turn": object{"id": p.turn}}}); err != nil {
				return err
			}
			return p.completed("Background fixture")
		}
		if strings.Contains(input, "fixture-interrupt") {
			return p.send(object{"id": id, "result": object{"turn": object{"id": p.turn}}})
		}
		if strings.Contains(input, "fixture-steer") {
			return p.send(object{"id": id, "result": object{"turn": object{"id": p.turn}}})
		}
		if e := p.event("item/agentMessage/delta", object{"threadId": p.session, "turnId": p.turn, "itemId": "answer-" + p.turn, "delta": "Hello "}); e != nil {
			return e
		}
		if e := p.send(object{"id": 99, "method": "item/commandExecution/requestApproval", "params": object{"threadId": p.session, "turnId": p.turn, "interactionId": "permission-1", "command": "echo fixture"}}); e != nil {
			return e
		}
		result["turn"] = object{"id": p.turn}
	case "turn/steer":
		for _, raw := range list(params["input"]) {
			if text(record(raw)["text"]) == "fixture-pending-steer" {
				return os.WriteFile(filepath.Join(os.Getenv("MOKUSEI_CODEX_REPLAY_ROOT"), "pending-steer"), []byte("pending"), 0600)
			}
		}
		if params["expectedTurnId"] != p.turn {
			return fmt.Errorf("fixture steer turn mismatch")
		}
		if e := p.send(object{"id": id, "result": object{}}); e != nil {
			return e
		}
		return p.completed("Steered fixture")
	case "turn/interrupt":
		if e := p.event("turn/completed", object{"threadId": p.session, "turn": object{"id": p.turn, "status": "interrupted", "items": []any{}}}); e != nil {
			return e
		}
	case "thread/backgroundTerminals/clean":
		if p.backgroundMode == "fail" {
			return p.send(object{"id": id, "error": object{"code": -32000, "message": "fixture cancellation refused"}})
		}
		if p.background != nil && p.backgroundMode != "pending" {
			_ = p.background.Process.Kill()
			_ = p.background.Wait()
			p.background = nil
			// Completion racing explicit cancellation must not admit a successor.
			if err := p.event("item/completed", object{"threadId": p.session, "turnId": p.turn, "item": object{"type": "commandExecution", "id": "background-command", "status": "completed", "exitCode": 0}}); err != nil {
				return err
			}
		}
	case "thread/backgroundTerminals/list":
		root := os.Getenv("MOKUSEI_CODEX_REPLAY_ROOT")
		if _, err := os.Stat(filepath.Join(root, "crash-background")); err == nil {
			os.Exit(7)
		}
		if _, err := os.Stat(filepath.Join(root, "complete-background")); err == nil && p.background != nil {
			_ = p.background.Process.Kill()
			_ = p.background.Wait()
			p.background = nil
			if err := p.event("item/completed", object{"threadId": p.session, "turnId": p.turn, "item": object{"type": "commandExecution", "id": "background-command", "status": "completed", "exitCode": 0}}); err != nil {
				return err
			}
		}
		if p.backgroundMode == "unknown" {
			return p.send(object{"id": id, "error": object{"code": -32000, "message": "fixture list unavailable"}})
		}
		result["data"] = []any{}
		if p.background != nil && syscall.Kill(p.background.Process.Pid, 0) == nil {
			result["data"] = []any{object{"itemId": "background-command", "processId": "fixture-process", "command": "fixture worker", "cwd": root}}
		}
		result["nextCursor"] = nil
	case "thread/realtime/start":
		if params["version"] != "v3" || record(params["transport"])["type"] != "webrtc" || params["clientManagedHandoffs"] != true {
			return p.send(object{"id": id, "error": object{"code": -32602, "message": "fixture requires V3 WebRTC with client-managed handoffs"}})
		}
		if err := captureVoiceLaunch("realtime.start"); err != nil {
			return err
		}
		switch os.Getenv("MOKUSEI_CODEX_REPLAY_VOICE_REJECTION") {
		case "method":
			return p.send(object{"id": id, "error": object{"code": -32601, "message": "thread/realtime/start is not supported"}})
		case "protocol":
			return p.send(object{"id": id, "error": object{"code": -32602, "message": "realtime V3 transport is not supported"}})
		}
		for _, method := range []string{"thread/realtime/sdp", "thread/realtime/error", "thread/realtime/closed"} {
			if err := p.event(method, object{"threadId": "unrelated-old-thread", "sdp": "stale-answer", "message": "stale-error"}); err != nil {
				return err
			}
		}
		if e := p.event("thread/realtime/sdp", object{"threadId": p.session, "sdp": "fixture-answer-sdp"}); e != nil {
			return e
		}
		if os.Getenv("MOKUSEI_CODEX_REPLAY_VOICE_CONFIGURATION") == "1" {
			return p.send(object{"id": id, "result": object{}})
		}
		// Native flat ASR notifications: no media, model or canonical history.
		for _, notification := range []struct {
			method string
			params object
		}{
			{"thread/realtime/transcript/done", object{"role": "user", "text": "hello"}},
			{"thread/realtime/transcript/delta", object{"role": "assistant", "delta": "Hello"}},
			{"thread/realtime/transcript/delta", object{"role": "user", "delta": "voice "}},
			{"thread/realtime/transcript/done", object{"role": "assistant", "text": "Hello there"}},
			{"thread/realtime/transcript/done", object{"role": "user", "text": "voice request"}},
			{"thread/realtime/itemAdded", object{"item": object{"type": "handoff_request", "handoff_id": "fixture-voice-handoff", "input_transcript": "voice request"}}},
			{"thread/realtime/transcript/delta", object{"role": "assistant", "delta": "Accepted"}},
			{"thread/realtime/transcript/delta", object{"role": "user", "delta": "new request"}},
			{"thread/realtime/transcript/done", object{"role": "assistant", "text": "Accepted first request"}},
			{"thread/realtime/transcript/done", object{"role": "user", "text": "new request"}},
		} {
			notification.params["threadId"] = p.session
			if e := p.event(notification.method, notification.params); e != nil {
				return e
			}
		}
	case "thread/realtime/stop":
		if e := p.event("thread/realtime/closed", object{"threadId": p.session, "reason": "client request"}); e != nil {
			return e
		}
	case "thread/turns/list":
		result["data"] = []any{object{"id": p.turn, "itemsView": "full", "items": []any{}}}
		result["nextCursor"] = nil
	case "thread/inject_items":
		if strings.Contains(string(encoded(params)), "fixture-handoff-before-final") {
			for _, notification := range []struct {
				method string
				params object
			}{
				{"thread/realtime/transcript/delta", object{"role": "user", "delta": "partial"}},
				{"thread/realtime/itemAdded", object{"item": object{"type": "handoff_request", "handoff_id": "fixture-handoff-before-final", "input_transcript": "complete request"}}},
				{"thread/realtime/transcript/done", object{"role": "user", "text": "complete request"}},
			} {
				notification.params["threadId"] = p.session
				if e := p.event(notification.method, notification.params); e != nil {
					return e
				}
			}
		}
		if strings.Contains(string(encoded(params)), "fixture-feedback-before-final") {
			if e := p.event("thread/realtime/transcript/delta", object{"threadId": p.session, "role": "user", "delta": "early partial"}); e != nil {
				return e
			}
			if e := p.event("thread/realtime/itemAdded", object{"threadId": p.session, "item": object{"type": "handoff_request", "handoff_id": "fixture-feedback-before-final", "input_transcript": "feedback before final request"}}); e != nil {
				return e
			}
		}
	case "thread/realtime/appendSpeech":
		if text(params["text"]) == "Moku handoff-before-final feedback" {
			if e := p.event("thread/realtime/transcript/done", object{"threadId": p.session, "role": "user", "text": "newer request after feedback"}); e != nil {
				return e
			}
		}
		if text(params["text"]) == "Moku feedback before final" {
			p.earlySpeeches++
			if p.earlySpeeches != 1 {
				return fmt.Errorf("feedback identity repair repeated appendSpeech")
			}
			for _, value := range []string{"feedback before final request", "newer request after early feedback"} {
				if e := p.event("thread/realtime/transcript/done", object{"threadId": p.session, "role": "user", "text": value}); e != nil {
					return e
				}
			}
		}
	case "crash":
		binary, e := os.Executable()
		if e != nil {
			return e
		}
		child := exec.Command(binary, "--fixture-descendant")
		child.Env = os.Environ()
		child.Stdout = os.Stdout
		child.Stderr = os.Stderr
		if e = child.Start(); e != nil {
			return e
		}
		if e = os.WriteFile(filepath.Join(os.Getenv("MOKUSEI_CODEX_REPLAY_ROOT"), "child.pid"), []byte(fmt.Sprint(child.Process.Pid)), 0600); e != nil {
			return e
		}
		os.Exit(7)
	case "malformed":
		fmt.Fprintln(os.Stdout, "{broken JSON")
		time.Sleep(5 * time.Minute)
	default:
		return fmt.Errorf("fixture received unexpected method %q", method)
	}
	return p.send(object{"id": id, "result": result})
}
func (p *peer) callTool() error {
	request := object{"jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": object{"name": "echo_fixture", "arguments": object{"text": "tool works"}, "_meta": object{"callId": "tool-call-1", "threadId": p.session, "x-codex-turn-metadata": object{"turn_id": p.turn}}}}
	req, e := http.NewRequest(http.MethodPost, text(p.bridge["url"]), bytes.NewReader(encoded(request)))
	if e != nil {
		return e
	}
	req.Header.Set("Content-Type", "application/json")
	for key, value := range record(p.bridge["http_headers"]) {
		req.Header.Set(key, text(value))
	}
	client := &http.Client{Timeout: 10 * time.Second}
	response, e := client.Do(req)
	if e != nil {
		return e
	}
	defer response.Body.Close()
	body, e := io.ReadAll(io.LimitReader(response.Body, 1<<20))
	if e != nil {
		return e
	}
	result := record(decoded(body)["result"])
	if record(result["structuredContent"])["text"] != "tool works" {
		return fmt.Errorf("fixture tool reply failed: %s", body)
	}
	return nil
}

func captureVoiceLaunch(kind string) error {
	path := os.Getenv("MOKUSEI_CODEX_REPLAY_LAUNCH_CAPTURE")
	if path == "" {
		return nil
	}
	file, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0600)
	if err != nil {
		return err
	}
	defer file.Close()
	return json.NewEncoder(file).Encode(object{"kind": kind, "pid": os.Getpid()})
}

func fixtureModel() string {
	if value := os.Getenv("MOKUSEI_CODEX_REPLAY_MODEL"); value != "" {
		return value
	}
	return "gpt-6-luna"
}
func fixtureEffort() string {
	if fixtureModel() == "gpt-6.1-sol" {
		return "medium"
	}
	return "low"
}
