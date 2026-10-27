package main

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
)

// Read identities from the model's actual input/receipts, never from the test's
// database or a globally shared child ID. This preserves the scope boundary.
func latestBatch(input any) (string, any) {
	items := list(input)
	for i := len(items) - 1; i >= 0; i-- {
		m := record(items[i])
		if m["role"] != "user" {
			continue
		}
		for _, c := range list(m["content"]) {
			s := text(record(c)["text"])
			at := strings.LastIndex(s, "Batch: ")
			if at < 0 {
				continue
			}
			tail := s[at+7:]
			nl := strings.IndexByte(tail, '\n')
			if nl < 0 {
				continue
			}
			var v any
			if json.Unmarshal([]byte(tail[nl+1:]), &v) == nil {
				return strings.TrimSpace(tail[:nl]), v
			}
		}
	}
	return "", nil
}
func resultJSON(input any, id string) (any, error) {
	for _, v := range list(input) {
		m := record(v)
		if m["type"] != "function_call_output" || m["call_id"] != id {
			continue
		}
		s := outputText(m["output"])
		var value any
		if err := json.Unmarshal([]byte(s), &value); err != nil {
			return nil, fmt.Errorf("tool %s output is not JSON: %w", id, err)
		}
		return value, nil
	}
	return nil, fmt.Errorf("missing tool receipt %s", id)
}
func (p *provider) fanoutPlan(ctx context.Context, req object, declarations []any) (tool, call string, args object, handled bool, err error) {
	report, _ := findTool(declarations, "create_report", "")
	tag, _ := findTool(declarations, "create_tags", "")
	if report == "" && tag == "" {
		return "", "", nil, false, nil
	}
	batch, data := latestBatch(req["input"])
	if batch == "" {
		return "", "", nil, true, fmt.Errorf("background request missing batch identity")
	}
	prefix := "batch_" + strings.ReplaceAll(batch, "-", "")
	if report != "" {
		listID := prefix + "_list"
		if !hasResult(req["input"], listID) {
			return "list_threads", listID, object{}, true, nil
		}
		page, e := resultJSON(req["input"], listID)
		if e != nil {
			return "", "", nil, true, e
		}
		var tasks []object
		if e = json.Unmarshal([]byte(text(record(page)["text"])), &tasks); e != nil {
			return "", "", nil, true, e
		}
		eligible := map[string]bool{}
		for _, event := range list(data) {
			eligible[text(record(record(event)["subject"])["id"])] = true
		}
		for _, task := range tasks {
			if !eligible[text(task["id"])] {
				continue
			}
			execution := record(record(task["observation"])["latestExecution"])
			if execution["status"] != "completed" {
				continue
			}
			id := text(task["id"])
			if len(p.workspaces) > 1 {
				for _, other := range tasks {
					if other["cwd"] != task["cwd"] {
						return "", "", nil, true, fmt.Errorf("scoped Report list crossed directories")
					}
				}
				probeID := prefix + "_" + strings.ReplaceAll(id, "-", "") + "_foreign_read"
				if !hasResult(req["input"], probeID) {
					foreign, e := p.foreignThread(ctx, id)
					if e != nil {
						return "", "", nil, true, e
					}
					return "read_thread", probeID, object{"threadId": foreign, "question": "Scope isolation probe: read another directory task"}, true, nil
				}
				if e := expectToolError(req["input"], probeID); e != nil {
					return "", "", nil, true, e
				}
				p.markScopeProof("report-read", id)
			}
			readID := prefix + "_" + strings.ReplaceAll(id, "-", "") + "_read"
			createID := prefix + "_" + strings.ReplaceAll(id, "-", "") + "_report"
			if !hasResult(req["input"], readID) {
				return "read_thread", readID, object{"threadId": id, "question": "What is the exact SYSTEM_CHAIN_CHILD result?"}, true, nil
			}
			readResult, e := resultJSON(req["input"], readID)
			if e != nil {
				return "", "", nil, true, e
			}
			if record(readResult)["ok"] != true || record(readResult)["threadId"] != id || record(readResult)["answer"] != "SYSTEM_CHILD_DONE" {
				return "", "", nil, true, fmt.Errorf("Report read evidence mismatch: %v", readResult)
			}
			if !hasResult(req["input"], createID) {
				return "create_report", createID, object{"title": "System chain report", "html": "<html><body><p>SYSTEM_CHILD_DONE</p></body></html>", "relatedExecutions": []any{object{"threadId": id, "executionId": execution["executionId"]}}}, true, nil
			}
		}
		return "", "", nil, true, nil
	}
	createID, assignID := prefix+"_tags", prefix+"_assign"
	tagName := "Verified"
	if len(p.workspaces) > 1 {
		tagName += "_" + text(record(data)["scope"])
	}
	if !hasResult(req["input"], createID) {
		return "create_tags", createID, object{"tags": []any{object{"name": tagName, "emoji": "✅"}}}, true, nil
	}
	if !hasResult(req["input"], assignID) {
		assignments := []any{}
		seen := map[string]bool{}
		for _, raw := range list(record(data)["events"]) {
			subject := record(record(raw)["subject"])
			id := text(subject["id"])
			if id != "" && !seen[id] {
				seen[id] = true
				assignments = append(assignments, object{"thread": object{"threadId": id, "typeId": "agent"}, "tags": []string{tagName}})
			}
		}
		if len(assignments) > 0 {
			if len(p.workspaces) > 1 {
				probeID := prefix + "_foreign_assign"
				own := text(record(record(assignments[0])["thread"])["threadId"])
				if !hasResult(req["input"], probeID) {
					foreign, e := p.foreignThread(ctx, own)
					if e != nil {
						return "", "", nil, true, e
					}
					return "set_thread_tags", probeID, object{"assignments": []any{object{"thread": object{"threadId": foreign, "typeId": "agent"}, "tags": []string{tagName}}}}, true, nil
				}
				if e := expectToolError(req["input"], probeID); e != nil {
					return "", "", nil, true, e
				}
				p.markScopeProof("tag-write", own)
			}
			return "set_thread_tags", assignID, object{"assignments": assignments}, true, nil
		}
	}
	return "", "", nil, true, nil
}

func (p *provider) registerChild(id, cwd string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.children[id] == cwd {
		return
	}
	p.children[id] = cwd
	if p.childrenWake != nil {
		close(p.childrenWake)
	}
	p.childrenWake = make(chan struct{})
}
func (p *provider) foreignThread(ctx context.Context, own string) (string, error) {
	for {
		p.mu.Lock()
		scope, known := p.children[own]
		id, best := "", ""
		if known {
			for candidate, s := range p.children {
				if candidate != own && s != scope && (best == "" || s < best || s == best && candidate < id) {
					id, best = candidate, s
				}
			}
		}
		if p.childrenWake == nil {
			p.childrenWake = make(chan struct{})
		}
		wake := p.childrenWake
		p.mu.Unlock()
		if id != "" {
			return id, nil
		}
		select {
		case <-ctx.Done():
			return "", ctx.Err()
		case <-wake:
		}
	}
}

func expectToolError(input any, id string) error {
	for _, raw := range list(input) {
		m := record(raw)
		if m["type"] == "function_call_output" && m["call_id"] == id {
			data := outputText(m["output"])
			expected := "unknown ordinary task"
			if strings.HasSuffix(id, "_foreign_assign") {
				expected = "thread belongs to a different tag scope"
			}
			if strings.TrimSpace(data) == expected {
				return nil
			}
			return fmt.Errorf("cross-scope tool was not rejected: %s", data)
		}
	}
	return fmt.Errorf("missing cross-scope rejection %s", id)
}

func outputText(value any) string {
	s := text(value)
	if _, ok := value.([]any); ok {
		parts := []string{}
		for _, part := range list(value) {
			parts = append(parts, text(record(part)["text"]))
		}
		s = strings.Join(parts, "\n")
	}
	if at := strings.Index(s, "\nOutput:\n"); at >= 0 {
		s = s[at+9:]
	}
	return s
}

func (p *provider) markScopeProof(role, own string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.scopeChecks[p.children[own]+"/"+role] = true
}
