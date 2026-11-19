package system_test

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
)

// Read identities from the model's actual input/receipts, never from the test's
// database or a globally shared child ID. This preserves the scope boundary.
func latestBatch(input any) (string, any, object) {
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
			payload := tail[nl+1:]
			var status object
			if strings.HasPrefix(payload, "Statusbar: ") {
				payload = strings.TrimPrefix(payload, "Statusbar: ")
			} else if events, snapshot, found := strings.Cut(payload, "\nStatusbar: "); found {
				if json.Unmarshal([]byte(snapshot), &status) != nil {
					continue
				}
				payload = events
			}
			if json.Unmarshal([]byte(payload), &v) == nil {
				return strings.TrimSpace(tail[:nl]), v, status
			}
		}
	}
	return "", nil, nil
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
	tag, _ := findTool(declarations, "create_tag", "")
	if report == "" && tag == "" {
		return "", "", nil, false, nil
	}
	batch, data, status := latestBatch(req["input"])
	if batch == "" {
		return "", "", nil, true, fmt.Errorf("background request missing batch identity")
	}
	prefix := "batch_" + strings.ReplaceAll(batch, "-", "")
	if report != "" {
		if text(status["scope"]) == "" || text(status["revision"]) == "" {
			return "", "", nil, true, fmt.Errorf("Report delivery lacks scoped Statusbar")
		}
		for _, raw := range list(data) {
			event := record(raw)
			id := text(record(event["subject"])["id"])
			// The completed execution belongs to this delivered event, even if
			// the live task has since moved to a different execution.
			execution := record(event["data"])
			if id == "" || event["scope"] != status["scope"] || text(event["id"]) == "" || event["type"] != "execution.completed" || text(execution["executionId"]) == "" || execution["status"] != "completed" || execution["summary"] != "SYSTEM_CHILD_DONE" {
				return "", "", nil, true, fmt.Errorf("Report batch evidence mismatch: %v", event)
			}
			if len(p.workspaces) > 1 {
				probeID := prefix + "_" + strings.ReplaceAll(id, "-", "") + "_foreign_report"
				if !hasResult(req["input"], probeID) {
					foreign, e := p.foreignThread(ctx, id)
					if e != nil {
						return "", "", nil, true, e
					}
					p.mu.Lock()
					foreignExecution := p.childExecutions[foreign]
					p.mu.Unlock()
					return "create_report", probeID, object{"title": "Foreign source", "emoji": "📊", "shortDescription": "Scope rejection probe", "html": "<p>Foreign</p>", "coverHTML": "<div>Foreign</div>", "relatedExecutions": []any{object{"threadId": foreign, "executionId": foreignExecution}}}, true, nil
				}
				if e := expectToolError(req["input"], probeID); e != nil {
					return "", "", nil, true, e
				}
				p.markScopeProof("report-write", id)
			}
			eventPrefix := prefix + "_" + strings.ReplaceAll(text(event["id"]), "-", "")
			if tool, call, args, err := reportWritePlan(req["input"], eventPrefix, id, execution); err != nil || tool != "" {
				return tool, call, args, true, err
			}
		}
		return "", "", nil, true, nil
	}
	tool, call, args, err = p.tagPlan(ctx, req["input"], prefix)
	return tool, call, args, true, err
}

// Moku retains its independent native-history question capability. Read only
// after an actual completion notification; this is evidence review, not polling.
func mokuTerminalPlan(input any) (tool, call string, args object, err error) {
	const marker = "Mokusei Agent Thread terminal event:\n"
	for _, raw := range list(input) {
		message := record(raw)
		if message["role"] != "user" {
			continue
		}
		for _, content := range list(message["content"]) {
			s := text(record(content)["text"])
			at := strings.Index(s, marker)
			if at < 0 {
				continue
			}
			var thread object
			if err := json.Unmarshal([]byte(s[at+len(marker):]), &thread); err != nil {
				return "", "", nil, fmt.Errorf("Moku terminal notification is not JSON: %w", err)
			}
			execution := record(record(thread["observation"])["latestExecution"])
			if execution["status"] != "completed" {
				continue
			}
			id, executionID := text(thread["threadId"]), text(execution["executionId"])
			if id == "" || executionID == "" {
				return "", "", nil, fmt.Errorf("Moku terminal notification lacks source identity: %v", thread)
			}
			readID := mokuReadCallID(executionID)
			if !hasResult(input, readID) {
				return "ask_thread", readID, object{"threadId": id, "question": "What is the exact SYSTEM_CHAIN_CHILD result?"}, nil
			}
			value, err := resultJSON(input, readID)
			if err != nil {
				return "", "", nil, err
			}
			result := record(value)
			if result["ok"] != true || result["threadId"] != id || result["answer"] != "SYSTEM_CHILD_DONE" {
				return "", "", nil, fmt.Errorf("Moku native read evidence mismatch: %v", value)
			}
		}
	}
	// The history read follows a completed-child notification. The driver
	// withholds successor inputs until the peer has received the stop results.
	if hasResult(input, createCallID(0)) && !hasResult(input, "system_stale_stop") {
		created, err := resultJSON(input, createCallID(0))
		if err != nil {
			return "", "", nil, err
		}
		child := record(created)
		if hasResult(input, mokuReadCallID(text(child["executionId"]))) {
			id := text(child["threadId"])
			return "interrupt_thread", "system_stale_stop", object{"threadIds": []string{id, "missing-stop-target", id}}, nil
		}
	}
	return "", "", nil, nil
}

func mokuReadCallID(executionID string) string {
	return "system_read_" + strings.ReplaceAll(executionID, "-", "")
}

func (p *provider) registerChild(id, cwd, execution string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.childExecutions == nil {
		p.childExecutions = map[string]string{}
	}
	p.childExecutions[id] = execution
	if previous, exists := p.children[id]; exists && previous == cwd {
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
				if candidate != own && p.childExecutions[candidate] != "" && s != scope && (best == "" || s < best || s == best && candidate < id) {
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
			expected := "report execution reference is outside its scope"
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
