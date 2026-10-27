// The fixture speaks Pi RPC and host-bridge frames through real OS pipes.
// It runs in this command's child process and never invokes an installed Pi.
package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

func emitFixture(v any) {
	if err := json.NewEncoder(os.Stdout).Encode(v); err != nil {
		panic(err)
	}
}
func serveFixture() {
	if os.Getenv("MOKUSEI_PI_VERIFICATION_CHILD") == "1" {
		for {
			time.Sleep(time.Hour)
		}
	}
	if len(os.Args) > 1 && os.Args[1] == "--version" {
		version := os.Getenv("MOKUSEI_PI_VERIFICATION_VERSION")
		if version == "" {
			version = "1.0.0"
		}
		fmt.Println(version)
		return
	}
	mode := os.Getenv("MOKUSEI_PI_VERIFICATION_SCENARIO")
	if mode == "stubborn-close" {
		signal.Ignore(syscall.SIGTERM)
		check(os.WriteFile(os.Getenv("MOKUSEI_PI_VERIFICATION_PID"), []byte(strconv.Itoa(os.Getpid())), 0600) == nil, "write stubborn child PID")
	}
	if mode == "graceful-close" {
		check(os.WriteFile(os.Getenv("MOKUSEI_PI_VERIFICATION_CLOSE"), []byte("locked"), 0600) == nil, "create native cleanup marker")
	}
	if mode == "tree" {
		child := exec.Command(os.Args[0])
		child.Env = append(os.Environ(), "MOKUSEI_PI_VERIFICATION_CHILD=1")
		check(child.Start() == nil, "spawn tree child")
		defer func() { _ = child.Process.Kill(); _ = child.Wait() }()
		check(os.WriteFile(os.Getenv("MOKUSEI_PI_VERIFICATION_PID"), []byte(strconv.Itoa(child.Process.Pid)), 0600) == nil, "write child PID")
	}
	var bridge *os.File
	if path := os.Getenv("MOKUSEI_PI_BRIDGE_CONFIG"); path != "" {
		var config struct {
			Tools []struct {
				Name string `json:"name"`
			}
		}
		data, err := os.ReadFile(path)
		check(err == nil && json.Unmarshal(data, &config) == nil, "bridge config")
		bridge = os.NewFile(3, "native-host-bridge")
		defer bridge.Close()
		names := []string{}
		for _, tool := range config.Tools {
			names = append(names, tool.Name)
		}
		check(json.NewEncoder(bridge).Encode(map[string]any{"type": "ready", "tools": names}) == nil, "bridge ready")
	}
	defaultSessionPath := filepath.Join(os.Getenv("MOKUSEI_PI_VERIFICATION_ROOT"), "unused-session.jsonl")
	sessionPath := defaultSessionPath
	directory := ""
	for i, arg := range os.Args {
		if arg == "--session" && i+1 < len(os.Args) {
			sessionPath = os.Args[i+1]
		}
		if arg == "--session-dir" && i+1 < len(os.Args) {
			directory = os.Args[i+1]
		}
	}
	if directory != "" && sessionPath == defaultSessionPath {
		file, err := os.CreateTemp(directory, "native-*.jsonl")
		if err != nil {
			panic(err)
		}
		sessionPath = file.Name()
		cwd, _ := os.Getwd()
		_ = json.NewEncoder(file).Encode(map[string]any{"type": "session", "cwd": cwd})
		_ = file.Close()
	}
	finish := func() {
		emitFixture(map[string]any{"type": "message_start", "message": map[string]any{"role": "assistant", "content": []any{}}})
		emitFixture(map[string]any{"type": "message_end", "message": map[string]any{"role": "assistant", "content": []any{map[string]any{"type": "text", "text": "Hello world"}}, "stopReason": "stop"}})
		emitFixture(map[string]any{"type": "agent_end"})
		time.Sleep(20 * time.Millisecond)
		emitFixture(map[string]any{"type": "agent_settled"})
	}
	scanner := bufio.NewScanner(os.Stdin)
	for scanner.Scan() {
		var frame map[string]any
		_ = json.Unmarshal(scanner.Bytes(), &frame)
		typ, _ := frame["type"].(string)
		if mode == "startup-timeout" {
			continue
		}
		response := func(data any) {
			emitFixture(map[string]any{"type": "response", "id": frame["id"], "success": true, "data": data})
		}
		switch typ {
		case "get_state":
			if mode == "settings-sharing" {
				root := os.Getenv("MOKUSEI_PI_VERIFICATION_ROOT")
				check(os.WriteFile(filepath.Join(root, fmt.Sprintf("settings-start-%d", os.Getpid())), nil, 0600) == nil, "record settings process")
				time.Sleep(200 * time.Millisecond)
			}
			response(map[string]any{"sessionFile": sessionPath, "sessionId": "id", "thinkingLevel": "high", "model": map[string]any{"id": "model", "provider": "provider", "reasoning": true, "input": []string{"text", "image"}}})
		case "get_commands":
			if mode == "request-timeout" {
				continue
			}
			if mode == "unowned" {
				emitFixture(map[string]any{"type": "extension_ui_request", "method": "notify", "message": "hold"})
				emitFixture(map[string]any{"type": "agent_settled"})
			}
			response(map[string]any{"commands": []any{map[string]any{"name": "command", "source": "extension", "sourceInfo": map[string]any{"path": "/extension"}}}})
		case "get_available_models":
			response(map[string]any{"models": []any{map[string]any{"id": "model", "provider": "provider", "baseUrl": "hidden", "thinkingLevelMap": map[string]any{"off": nil, "high": "high"}, "compat": map[string]any{"supportsReasoningEffort": false}}, map[string]any{"id": "unknown", "provider": "provider"}}})
		case "get_available_thinking_levels":
			response(map[string]any{"levels": []string{"off", "high"}})
		case "clone":
			if directory != "" {
				data, _ := os.ReadFile(sessionPath)
				file, err := os.CreateTemp(directory, "native-clone-*.jsonl")
				if err != nil {
					panic(err)
				}
				sessionPath = file.Name()
				_, _ = file.Write(data)
				_ = file.Close()
			}
			response(map[string]any{"cancelled": false})
		case "extension_ui_response":
			check(frame["value"] == "raw\x00choice", "raw native selection retained")
			finish()
		case "prompt":
			text, _ := frame["message"].(string)
			if text == "handled" {
				response(map[string]any{"disposition": "handled"})
				continue
			}
			response(map[string]any{})
			if strings.HasPrefix(text, "usage-") {
				message := map[string]any{"role": "assistant", "model": "model", "provider": "provider", "content": []any{}}
				emitFixture(map[string]any{"type": "message_start", "message": message})
				// Pi starts with zero usage, but only message_end is authoritative.
				message["usage"] = map[string]any{"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "totalTokens": 0}
				emitFixture(map[string]any{"type": "message_update", "message": message})
				if text == "usage-stream" {
					continue
				}
				message["stopReason"] = "toolUse"
				switch text {
				case "usage-first":
					message["usage"] = map[string]any{"input": 11, "output": 7, "cacheRead": 100, "cacheWrite": 3, "reasoning": 2, "totalTokens": 121, "cost": map[string]any{"total": 0.1}}
				case "usage-next":
					message["usage"] = map[string]any{"input": 13, "output": 5, "cacheRead": 200, "cacheWrite": 4, "reasoning": 3, "totalTokens": 222, "cost": map[string]any{"total": 0.2}}
				case "usage-zero", "usage-missing":
					message["stopReason"] = "error"
					message["errorMessage"] = "Request timed out."
					if text == "usage-missing" {
						delete(message, "usage")
					}
				}
				emitFixture(map[string]any{"type": "message_end", "message": message})
				// No agent_settled: the execution remains running during retry/tool work.
				continue
			}
			if text == "bridge" {
				check(bridge != nil, "bridge descriptor")
				emitFixture(map[string]any{"type": "agent_start"})
				check(json.NewEncoder(bridge).Encode(map[string]any{"type": "call", "id": "request-1", "callId": "native-1", "name": "double", "arguments": map[string]any{"n": 7}}) == nil, "bridge call")
				var result map[string]any
				check(json.NewDecoder(bridge).Decode(&result) == nil, "bridge result")
				value, _ := result["result"].(map[string]any)
				check(value["value"] == float64(14), "bridge returned custom result")
				finish()
				continue
			}
			if text == "ask" {
				emitFixture(map[string]any{"type": "agent_start"})
				emitFixture(map[string]any{"type": "extension_ui_request", "method": "select", "id": "choice", "title": "Choose", "options": []string{"raw\x00choice", "second"}})
				continue
			}
			if mode == "oversize" {
				fmt.Println(strings.Repeat("x", 8*1024*1024+1))
				continue
			}
			if mode == "invalid-delta" {
				emitFixture(map[string]any{"type": "message_update", "assistantMessageEvent": map[string]any{"type": "text_delta", "contentIndex": 0, "delta": "oops"}})
				continue
			}
			if text == "active" {
				emitFixture(map[string]any{"type": "agent_start"})
				continue
			}
			if mode == "tool" {
				emitFixture(map[string]any{"type": "tool_execution_start", "toolName": "read", "toolCallId": "1", "args": map[string]any{}})
			}
			if mode == "interaction" {
				emitFixture(map[string]any{"type": "extension_ui_request", "method": "confirm", "id": "confirm", "title": "Confirm"})
			}
			emitFixture(map[string]any{"type": "agent_start"})
			if text == "todos" {
				for i, todos := range []any{[]any{map[string]any{"id": 1, "text": "one", "done": false}}, []any{}} {
					emitFixture(map[string]any{"type": "tool_execution_end", "toolName": "todo", "toolCallId": fmt.Sprint(i), "result": map[string]any{"content": []any{}, "details": map[string]any{"todos": todos}}})
				}
			}
			emitFixture(map[string]any{"type": "message_start", "message": map[string]any{"role": "assistant", "model": "model", "provider": "provider", "content": []any{}, "usage": map[string]any{"input": -1}}})
			emitFixture(map[string]any{"type": "message_update", "assistantMessageEvent": map[string]any{"type": "text_start", "contentIndex": 0}})
			emitFixture(map[string]any{"type": "message_update", "assistantMessageEvent": map[string]any{"type": "text_delta", "contentIndex": 0, "delta": "Hello"}})
			emitFixture(map[string]any{"type": "message_update", "assistantMessageEvent": map[string]any{"type": "thinking_start", "contentIndex": 1}})
			emitFixture(map[string]any{"type": "message_update", "assistantMessageEvent": map[string]any{"type": "thinking_delta", "contentIndex": 1, "delta": "reason"}})
			emitFixture(map[string]any{"type": "message_update", "assistantMessageEvent": map[string]any{"type": "text_end", "contentIndex": 0, "content": "Hello world"}})
			emitFixture(map[string]any{"type": "message_end", "message": map[string]any{"role": "assistant", "content": []any{map[string]any{"type": "text", "text": "Hello world"}}, "stopReason": "stop", "usage": map[string]any{"input": 1, "output": 2, "cacheRead": 3, "cacheWrite": 4, "cost": map[string]any{"total": 0.1}}}})
			emitFixture(map[string]any{"type": "agent_end"})
			time.Sleep(80 * time.Millisecond)
			emitFixture(map[string]any{"type": "agent_settled"})
			if mode == "exit-settled" {
				return
			}
		}
	}
	if mode == "graceful-close" {
		// Native RPC owns asynchronous session_shutdown hooks. EOF is its normal
		// disposal request; a signal before this finishes loses native cleanup.
		time.Sleep(100 * time.Millisecond)
		check(os.WriteFile(os.Getenv("MOKUSEI_PI_VERIFICATION_CLOSE"), []byte("disposed"), 0600) == nil, "finish native cleanup")
	}
	if mode == "stubborn-close" {
		for {
			time.Sleep(time.Hour)
		}
	}
}
