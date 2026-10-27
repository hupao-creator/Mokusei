package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"path/filepath"
	"slices"
	"strings"
)

func (p *nativeScriptProvider) discussionReply(w http.ResponseWriter, r *http.Request, names []string, all, lastUser string, toolResult bool) {
	p.mu.Lock()
	if !strings.Contains(all, "NORMAL_PROOF") || !strings.Contains(all, "independent read-only discussion") {
		p.failure = "Pi discussion lost native source history or instructions"
	}
	if len(names) != 2 || !slices.Contains(names, "read_project_file") || !slices.Contains(names, "list_project_directory") {
		p.failure = "Pi discussion advertised unsafe tools"
	}
	p.mu.Unlock()
	if strings.Contains(lastUser, "DISCUSSION_CANCEL") {
		p.holding <- struct{}{}
		<-r.Context().Done()
		return
	}
	if strings.Contains(lastUser, "DISCUSSION_FAILURE") {
		http.Error(w, `{"error":{"message":"fixture discussion provider failure","type":"invalid_request_error"}}`, 400)
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	emit := func(delta any, finish any) {
		b, _ := json.Marshal(map[string]any{"id": "discussion", "object": "chat.completion.chunk", "model": "mock-model", "choices": []any{map[string]any{"index": 0, "delta": delta, "finish_reason": finish}}})
		fmt.Fprintf(w, "data: %s\n\n", b)
		w.(http.Flusher).Flush()
	}
	tool := func(name, id string, args map[string]string) {
		b, _ := json.Marshal(args)
		emit(map[string]any{"role": "assistant", "tool_calls": []any{map[string]any{"index": 0, "id": id, "type": "function", "function": map[string]any{"name": name, "arguments": string(b)}}}}, nil)
		emit(map[string]any{}, "tool_calls")
	}
	switch {
	case strings.Contains(lastUser, "DISCUSSION_SECOND"):
		if !strings.Contains(all, "discussion-first-canary") {
			p.mu.Lock()
			p.failure = "Pi discussion lost previous answer"
			p.mu.Unlock()
		}
		emit(map[string]any{"role": "assistant", "content": "discussion-second-canary"}, nil)
		emit(map[string]any{}, "stop")
	case strings.Contains(lastUser, "DISCUSSION_ATTACK"):
		if !toolResult {
			tool("write", "discussion-write", map[string]string{"path": filepath.Join(p.root, "work", "discussion-must-not-exist.txt"), "content": "forbidden"})
		} else {
			emit(map[string]any{"role": "assistant", "content": "discussion-attack-blocked"}, nil)
			emit(map[string]any{}, "stop")
		}
	default:
		if !toolResult {
			tool("read_project_file", "discussion-read", map[string]string{"path": "discussion-proof.txt"})
		} else {
			if !strings.Contains(all, "project-read-canary") {
				p.mu.Lock()
				p.failure = "Pi discussion lost Core read result"
				p.mu.Unlock()
			}
			emit(map[string]any{"role": "assistant", "content": "discussion-first-canary"}, nil)
			emit(map[string]any{}, "stop")
		}
	}
	fmt.Fprint(w, "data: [DONE]\n\n")
}
