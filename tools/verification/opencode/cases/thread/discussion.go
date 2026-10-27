package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"path/filepath"
	"strings"
)

func discussionReply(w http.ResponseWriter, r *http.Request, body map[string]any, cwd string, holding chan<- struct{}) {
	raw, _ := json.Marshal(body["messages"])
	all := string(raw)
	lastUser := ""
	toolResult := false
	for _, item := range body["messages"].([]any) {
		message := item.(map[string]any)
		if message["role"] == "user" {
			b, _ := json.Marshal(message["content"])
			lastUser = string(b)
			toolResult = false
		}
		if message["role"] == "tool" {
			toolResult = true
		}
	}
	check(strings.Contains(all, "Return fixture JSON"), "discussion lost native source history")
	check(strings.Contains(all, "independent read-only discussion"), "discussion lost instructions")
	names := map[string]bool{}
	for _, item := range body["tools"].([]any) {
		names[item.(map[string]any)["function"].(map[string]any)["name"].(string)] = true
	}
	check(len(names) == 2 && names["read_project_file"] && names["list_project_directory"], "discussion advertised unsafe tools")
	if strings.Contains(lastUser, "DISCUSSION_CANCEL") {
		holding <- struct{}{}
		<-r.Context().Done()
		return
	}
	if strings.Contains(lastUser, "DISCUSSION_FAILURE") {
		http.Error(w, `{"error":{"message":"fixture discussion provider failure","type":"invalid_request_error"}}`, 400)
		return
	}
	delta := map[string]any{"role": "assistant"}
	finish := "stop"
	switch {
	case strings.Contains(lastUser, "DISCUSSION_SECOND"):
		check(strings.Contains(all, "discussion-first-canary"), "discussion lost its previous answer")
		delta["content"] = "discussion-second-canary"
	case strings.Contains(lastUser, "DISCUSSION_ATTACK"):
		if !toolResult {
			delta["tool_calls"] = []any{map[string]any{"index": 0, "id": "discussion_attack", "type": "function", "function": map[string]any{"name": "shell", "arguments": `{"command":"touch ` + filepath.Join(cwd, "discussion-must-not-exist.txt") + `","description":"forbidden write"}`}}}
			finish = "tool_calls"
		} else {
			delta["content"] = "discussion-attack-blocked"
		}
	default:
		if !toolResult {
			delta["tool_calls"] = []any{map[string]any{"index": 0, "id": "discussion_read", "type": "function", "function": map[string]any{"name": "read_project_file", "arguments": `{"path":"discussion-proof.txt"}`}}}
			finish = "tool_calls"
		} else {
			check(strings.Contains(all, "project-read-canary"), "Core read result missing")
			delta["content"] = "discussion-first-canary"
		}
	}
	w.Header().Set("Content-Type", "text/event-stream")
	for _, frame := range []any{map[string]any{"id": "discussion", "object": "chat.completion.chunk", "model": "fixture-model", "choices": []any{map[string]any{"index": 0, "delta": delta, "finish_reason": nil}}}, map[string]any{"id": "discussion", "object": "chat.completion.chunk", "model": "fixture-model", "choices": []any{map[string]any{"index": 0, "delta": map[string]any{}, "finish_reason": finish}}}} {
		b, _ := json.Marshal(frame)
		fmt.Fprintf(w, "data: %s\n\n", b)
	}
	fmt.Fprint(w, "data: [DONE]\n\n")
}
