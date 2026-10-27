package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"
)

type object = map[string]any
type provider struct {
	stability      *stabilityReport
	childrenWake   chan struct{}
	barriers       map[string]*responseBarrier
	scopeChecks    map[string]bool
	children       map[string]string
	workspaces     []string
	faultPlan      map[string]string
	faultHits      map[string]int
	blocked        []string
	model, effort  string
	mu             sync.Mutex
	requests       []object
	requestCount   int
	crashInputs    map[string]int
	activeRequests int
	failures       []string
}

func encoded(v any) []byte {
	b, e := json.Marshal(v)
	if e != nil {
		panic(e)
	}
	return b
}
func record(v any) object { m, _ := v.(map[string]any); return m }
func list(v any) []any    { a, _ := v.([]any); return a }
func text(v any) string   { s, _ := v.(string); return s }
func findTool(value any, wanted, namespace string) (string, string) {
	for _, v := range list(value) {
		t := record(v)
		name := text(t["name"])
		if name == wanted || strings.HasSuffix(name, "__"+wanted) {
			return name, namespace
		}
		ns := namespace
		if t["type"] == "namespace" {
			ns = name
		}
		if n, s := findTool(t["tools"], wanted, ns); n != "" {
			return n, s
		}
	}
	return "", ""
}
func hasResult(input any, id string) bool {
	for _, v := range list(input) {
		m := record(v)
		if m["type"] == "function_call_output" && m["call_id"] == id {
			return true
		}
	}
	return false
}
func (p *provider) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodConnect || r.URL.IsAbs() {
		p.mu.Lock()
		p.blocked = append(p.blocked, r.Method+" "+r.URL.Host)
		p.mu.Unlock()
		http.Error(w, "external egress denied", http.StatusForbidden)
		return
	}
	if r.Method != "POST" || r.URL.Path != "/v1/responses" || r.Header.Get("Authorization") != "Bearer fixture-only" {
		p.mu.Lock()
		p.failures = append(p.failures, r.Method+" "+r.URL.String())
		p.mu.Unlock()
		http.Error(w, "unexpected request", 400)
		return
	}
	b, e := io.ReadAll(io.LimitReader(r.Body, 8*1024*1024+1))
	if e != nil || len(b) > 8*1024*1024 {
		http.Error(w, "invalid body", 400)
		return
	}
	var req object
	if json.Unmarshal(b, &req) != nil {
		http.Error(w, "invalid JSON", 400)
		return
	}
	if req["model"] != p.model || req["stream"] != true {
		p.mu.Lock()
		p.failures = append(p.failures, "unexpected model or streaming mode")
		p.mu.Unlock()
		http.Error(w, "unexpected model or streaming mode", 400)
		return
	}
	p.mu.Lock()
	p.requests = append(p.requests, req)
	p.requestCount++
	p.activeRequests++
	number := p.requestCount
	p.mu.Unlock()
	var activeOnce sync.Once
	endActive := func() { activeOnce.Do(func() { p.mu.Lock(); p.activeRequests--; p.mu.Unlock() }) }
	stopActive := context.AfterFunc(r.Context(), endActive)
	defer func() { stopActive(); endActive() }()
	declarations := append([]any{}, list(req["tools"])...)
	for _, item := range list(req["input"]) {
		declarations = append(declarations, list(record(item)["tools"])...)
	}
	// Deliberate adversarial scope probes use only IDs observed through Moku's
	// real create receipts. Background success paths still derive their own IDs
	// exclusively from scoped inputs and list results.
	for i := 0; i < max(1, len(p.workspaces)); i++ {
		id := createCallID(i)
		if hasResult(req["input"], id) {
			if v, e := resultJSON(req["input"], id); e == nil {
				m := record(v)
				if m["ok"] == true {
					p.registerChild(text(m["threadId"]), text(record(m["workspace"])["cwd"]))
				}
			}
		}
	}
	payload := string(encoded(req["input"]))
	role := "auxiliary"
	properties := record(record(record(record(req["text"])["format"])["schema"])["properties"])
	if properties["title"] != nil && properties["emoji"] != nil {
		role = "metadata"
	} else if n, _ := findTool(declarations, "create_thread", ""); n != "" {
		role = "moku"
	} else if n, _ := findTool(declarations, "create_report", ""); n != "" {
		role = "report"
	} else if n, _ := findTool(declarations, "create_tags", ""); n != "" {
		role = "tag"
	} else if strings.Contains(payload, "What is the exact SYSTEM_CHAIN_CHILD result?") {
		role = "read"
	} else if strings.Contains(payload, "SYSTEM_CHAIN_CHILD") {
		role = "child"
	}
	p.mu.Lock()
	req["fixtureRole"] = role
	if role == "child" {
		for marker := range p.crashInputs {
			if latestUserContains(req["input"], marker) {
				p.crashInputs[marker]++
				if p.crashInputs[marker] > 1 {
					p.failures = append(p.failures, "crashed child input replayed: "+marker)
				}
			}
		}
	}
	p.mu.Unlock()
	if role == "read" && !hasCompletedChildEvidence(req["input"]) {
		p.mu.Lock()
		p.failures = append(p.failures, "read fork lacks persisted assistant result")
		p.mu.Unlock()
		http.Error(w, "read fork lacks persisted assistant result", http.StatusBadRequest)
		return
	}
	if role == "child" {
		finish := p.waitBarrier(req["input"])
		defer finish()
	}
	p.mu.Lock()
	fault := p.faultPlan[role]
	if fault != "" && p.faultHits[role] == 0 {
		p.faultHits[role]++
	} else {
		fault = ""
	}
	p.mu.Unlock()
	if fault != "" {
		fmt.Printf("FAULT role=%s mode=%s\n", role, fault)
		switch fault {
		case "429":
			w.Header().Set("Retry-After", "0")
			http.Error(w, `{"error":{"message":"scripted rate limit","type":"rate_limit_error"}}`, 429)
		case "500":
			http.Error(w, `{"error":{"message":"scripted provider failure"}}`, 500)
		case "truncate":
			w.Header().Set("Content-Type", "text/event-stream")
			fmt.Fprint(w, "event: response.created\ndata: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_fault\",\"status\":\"in_progress\",\"output\":[]}}\n\n")
			w.(http.Flusher).Flush()
		}
		return
	}

	tool, call := "", ""
	var args object
	answer := "SYSTEM_ACK"
	host, _ := findTool(declarations, "create_thread", "")
	if host != "" {
		if strings.Contains(payload, "SYSTEM_CHAIN_START") {
			for i := 0; i < max(1, len(p.workspaces)); i++ {
				id := createCallID(i)
				if !hasResult(req["input"], id) {
					tool, call, args = "create_thread", id, object{"prompt": "SYSTEM_CHAIN_CHILD: reply with SYSTEM_CHILD_DONE", "harnessId": "codex", "worktree": false, "options": object{"model": p.model, "thinking": object{"mode": "effort", "effort": p.effort}, "serviceTier": "default"}}
					if len(p.workspaces) > 0 {
						args["cwd"] = p.workspaces[i]
					}
					break
				}
			}
		}
		if tool == "" && strings.Contains(payload, "Mokusei Agent Thread terminal event:") && !hasResult(req["input"], "system_note") {
			tool, call, args = "update_note", "system_note", object{"text": "SYSTEM_CHAIN_VERIFIED", "expected": nil}
		}

	} else if strings.Contains(payload, "SYSTEM_CHAIN_CHILD") {
		answer = "SYSTEM_CHILD_DONE"
	}
	if role == "metadata" {
		answer = string(encoded(object{"title": "System chain task", "emoji": "✅"}))
	}
	if t, c, a, handled, err := p.fanoutPlan(r.Context(), req, declarations); handled {
		if err != nil {
			p.mu.Lock()
			p.failures = append(p.failures, err.Error())
			p.mu.Unlock()
			http.Error(w, err.Error(), 400)
			return
		}
		tool, call, args = t, c, a
	}
	fmt.Printf("MODEL request=%d tool=%s call=%s\n", number, tool, call)
	rid := fmt.Sprintf("resp_system_%d", number)
	iid := fmt.Sprintf("item_system_%d", number)
	initial := object{"id": rid, "object": "response", "status": "in_progress", "model": p.model, "output": []any{}}
	item := object{"id": iid, "type": "message", "role": "assistant", "phase": "final_answer", "status": "completed", "content": []any{object{"type": "output_text", "text": answer, "annotations": []any{}}}}
	events := []object{{"type": "response.created", "response": initial}}
	if tool != "" {
		name, ns := findTool(declarations, tool, "")
		if name == "" {
			p.mu.Lock()
			p.failures = append(p.failures, "missing tool "+tool)
			p.mu.Unlock()
			http.Error(w, "missing tool", 400)
			return
		}
		arguments := string(encoded(args))
		item = object{"id": iid, "type": "function_call", "call_id": call, "name": name, "namespace": ns, "arguments": arguments, "status": "completed"}
		events = append(events, object{"type": "response.output_item.added", "output_index": 0, "item": object{"id": iid, "type": "function_call", "call_id": call, "name": name, "namespace": ns, "arguments": "", "status": "in_progress"}}, object{"type": "response.function_call_arguments.delta", "item_id": iid, "output_index": 0, "delta": arguments}, object{"type": "response.function_call_arguments.done", "item_id": iid, "output_index": 0, "arguments": arguments})
	} else {
		events = append(events, object{"type": "response.output_item.added", "output_index": 0, "item": object{"id": iid, "type": "message", "role": "assistant", "status": "in_progress", "content": []any{}}}, object{"type": "response.content_part.added", "item_id": iid, "output_index": 0, "content_index": 0, "part": object{"type": "output_text", "text": "", "annotations": []any{}}}, object{"type": "response.output_text.delta", "item_id": iid, "output_index": 0, "content_index": 0, "delta": answer}, object{"type": "response.output_text.done", "item_id": iid, "output_index": 0, "content_index": 0, "text": answer})
	}
	final := object{"id": rid, "object": "response", "status": "completed", "model": p.model, "output": []any{item}, "usage": object{"input_tokens": 10, "output_tokens": 10, "total_tokens": 20}}
	events = append(events, object{"type": "response.output_item.done", "output_index": 0, "item": item}, object{"type": "response.completed", "response": final})
	w.Header().Set("Content-Type", "text/event-stream")
	for i, event := range events {
		event["sequence_number"] = i
		fmt.Fprintf(w, "event: %s\ndata: %s\n\n", event["type"], encoded(event))
		w.(http.Flusher).Flush()
	}
}

// The scripted answer is only valid when the native fork actually inherited the
// assistant result. Merely seeing the token in the question or user prompt is
// insufficient evidence of history preservation.
func hasCompletedChildEvidence(input any) bool {
	for _, raw := range list(input) {
		message := record(raw)
		if message["role"] != "assistant" {
			continue
		}
		for _, rawPart := range list(message["content"]) {
			part := record(rawPart)
			if part["type"] == "output_text" && part["text"] == "SYSTEM_CHILD_DONE" {
				return true
			}
		}
	}
	return false
}

func createCallID(index int) string {
	if index == 0 {
		return "system_create"
	}
	return fmt.Sprintf("system_create_%d", index)
}
