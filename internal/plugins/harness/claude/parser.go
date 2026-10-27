package claude

import (
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
)

type nativeTool struct {
	ID, Name, Partial string
	Input             any
}
type streamMessage struct{ ID, Model string }
type frameParser struct {
	onUsage             func(model, generation, kind string, usage map[string]any)
	contextTokens       float64
	messages            map[string]streamMessage
	tools               map[string]*nativeTool
	known               map[string]bool
	textMessages        map[string]bool
	reasoningMessages   map[string]bool
	textBoundaries      map[string]bool
	reasoningBoundaries map[string]bool
	usage               map[string]map[string]any
	costs               map[string]float64
	taskMutations       map[string]*nativeTool
	tasks               map[string]map[string]any
	taskOrder           []string
}

func newParser() *frameParser {
	return &frameParser{messages: map[string]streamMessage{}, tools: map[string]*nativeTool{}, known: map[string]bool{}, textMessages: map[string]bool{}, reasoningMessages: map[string]bool{}, textBoundaries: map[string]bool{}, reasoningBoundaries: map[string]bool{}, usage: map[string]map[string]any{}, costs: map[string]float64{}, taskMutations: map[string]*nativeTool{}, tasks: map[string]map[string]any{}}
}
func (p *frameParser) apply(s *State, t *Turn, f map[string]any, canonical func(string) string) {
	typ := str(f["type"])
	if s.Runtime == nil {
		s.Runtime = map[string]any{}
	}
	if typ == "process-exit" {
		s.settleBackground()
		return
	}
	if typ == "system" {
		subtype := str(f["subtype"])
		if subtype == "init" {
			if session := str(f["session_id"]); session != "" {
				s.PrimarySessionID = session
				s.PendingFork = nil
			}
			for native, field := range map[string]string{"model": "model", "cwd": "cwd", "claude_code_version": "claudeVersion", "permissionMode": "permissionMode"} {
				if v := str(f[native]); v != "" {
					s.Runtime[field] = v
				}
			}
		}
		if subtype == "background_tasks_changed" {
			tasks := []any{}
			for i, v := range arr(f["tasks"]) {
				if i >= 512 {
					break
				}
				raw := obj(v)
				task := map[string]any{"id": nonempty(str(raw["task_id"]), "task"), "description": nonempty(str(raw["description"]), "后台任务"), "status": nonempty(str(raw["status"]), "running")}
				if name := str(raw["task_type"]); name != "" {
					task["type"] = name
				}
				tasks = append(tasks, task)
			}
			s.Runtime["backgroundTasks"] = tasks
		}
		if subtype == "task_notification" {
			notice := map[string]any{"summary": clip(nonempty(str(f["summary"]), "Claude task "+str(f["task_id"])+" updated"), 20000)}
			if status := str(f["status"]); status != "" {
				notice["status"] = status
			}
			s.NativeNotifications = append(s.NativeNotifications, notice)
			if len(s.NativeNotifications) > 200 {
				s.NativeNotifications = s.NativeNotifications[len(s.NativeNotifications)-200:]
			}
			id := str(f["task_id"])
			status := taskStatus(str(f["status"]))
			for _, raw := range arr(s.Runtime["backgroundTasks"]) {
				task := obj(raw)
				if str(task["id"]) == id {
					task["status"] = status
				}
			}
			for _, turn := range s.Turns {
				turn.activityEnd(id, status, str(f["summary"]))
			}
			return
		}
	}
	if t == nil {
		return
	}
	boundary := nonempty(str(f["user_message_uuid"]), "$default")
	switch typ {
	case "control_request":
		interaction := interactionFromControl(str(f["request_id"]), obj(f["request"]))
		if interaction != nil {
			t.interaction(interaction)
		}
	case "control_cancel_request":
		for _, i := range t.Interactions {
			if str(i["id"]) == str(f["request_id"]) {
				i = cloneObject(i)
				i["status"] = "cancelled"
				t.interaction(i)
			}
		}
	case "stream_event":
		p.stream(t, obj(f["event"]), str(f["parent_tool_use_id"]), boundary, canonical)
	case "assistant":
		message := obj(f["message"])
		id := str(message["id"])
		parent := str(f["parent_tool_use_id"])
		if parent == "" {
			p.messageStart(t, id, str(message["model"]))
		}
		for _, v := range arr(message["content"]) {
			b := obj(v)
			switch str(b["type"]) {
			case "text":
				if parent == "" && !p.textMessages[id] {
					t.text(str(b["text"]), id, false)
					p.textBoundaries[boundary] = true
				}
			case "thinking":
				if parent == "" && !p.reasoningMessages[id] {
					t.reasoning(str(b["thinking"]))
					p.reasoningBoundaries[boundary] = true
				}
			case "tool_use":
				toolID := str(b["id"])
				if toolID != "" && !p.known[toolID] {
					tool := &nativeTool{ID: toolID, Name: str(b["name"]), Input: b["input"]}
					p.startTool(t, tool, parent, canonical)
					p.recordTask(tool)
				}
			}
		}
		if parent == "" {
			p.textMessages[id] = true
			p.reasoningMessages[id] = true
		}
		if parent == "" && str(message["stop_reason"]) != "" {
			p.messageEnd(t, id)
		}
	case "user":
		for _, v := range arr(obj(f["message"])["content"]) {
			b := obj(v)
			if str(b["type"]) != "tool_result" {
				continue
			}
			id := str(b["tool_use_id"])
			detail := contentText(b["content"])
			status := "completed"
			if b["is_error"] == true {
				status = "failed"
			}
			t.activityEnd(id, status, detail)
			if mutation := p.taskMutations[id]; mutation != nil {
				delete(p.taskMutations, id)
				if status == "completed" {
					p.applyTask(t, mutation, detail)
				}
			}
		}
	case "result":
		if session := str(f["session_id"]); session != "" {
			s.PrimarySessionID = session
			s.PendingFork = nil
		}
		if !p.textBoundaries[boundary] {
			text := str(f["result"])
			if structured, ok := f["structured_output"]; ok {
				if v, ok := structured.(string); ok {
					text = v
				} else {
					b, _ := json.MarshalIndent(structured, "", "  ")
					text = string(b)
				}
			}
			if text != "" {
				t.text(text, "", true)
			}
		}
		delete(p.textBoundaries, boundary)
		delete(p.reasoningBoundaries, boundary)
		for model, v := range obj(f["modelUsage"]) {
			usage := obj(v)
			cost := number(usage["costUSD"])
			if cost >= p.costs[model] {
				if delta := cost - p.costs[model]; delta > 0 && p.onUsage != nil {
					p.onUsage(nonempty(str(usage["canonicalModel"]), model), boundary+":model-cost:"+model, "summary", map[string]any{"costUsd": delta})
				}
				p.costs[model] = cost
			}
			if window := number(usage["contextWindow"]); window > 0 {
				if t.Usage == nil {
					t.Usage = map[string]any{}
				}
				t.Usage["contextWindow"] = window
			}
		}
		p.projectUsage(t)
	case "diff_update":
		t.Diff = clip(str(f["diff"]), 500000)
		t.append("diff", map[string]any{"content": t.Diff})
	case "review_update":
		t.Review = clip(str(f["text"]), 500000)
		t.append("review", map[string]any{"content": t.Review})
	case "rate_limit_event":
		t.notice("warning", "Claude Code 使用额度状态已更新")
	case "auth_status":
		if message := str(f["error"]); message != "" {
			t.fail(message)
		} else if f["isAuthenticating"] == true {
			t.StatusLabel = "正在认证 Claude Code"
		} else {
			t.StatusLabel = ""
		}
	case "system":
		switch str(f["subtype"]) {
		case "status":
			switch str(f["status"]) {
			case "compacting":
				t.StatusLabel = "正在压缩上下文"
			case "requesting":
				t.StatusLabel = "正在请求 Claude"
			}
		case "api_retry":
			t.notice("warning", fmt.Sprintf("Claude API 请求失败，准备第 %v 次重试", f["attempt"]))
		case "compact_boundary":
			t.Compacted = true
			t.append("context-compaction", nil)
		case "hook_started":
			id := nonempty(str(f["hook_id"]), str(f["uuid"]))
			if id != "" {
				t.activity(map[string]any{"id": id, "kind": "hook", "label": nonempty(str(f["hook_name"]), "运行 Hook"), "status": "running"})
			}
		case "hook_response":
			status := "failed"
			if number(f["exit_code"]) == 0 {
				status = "completed"
			}
			t.activityEnd(nonempty(str(f["hook_id"]), str(f["uuid"])), status, "")
		case "task_started":
			id := str(f["task_id"])
			if id != "" {
				t.activity(map[string]any{"id": id, "taskId": id, "kind": "task", "label": nonempty(str(f["description"]), "后台任务"), "status": "running"})
			}
		}
	}
}
func (p *frameParser) stream(t *Turn, e map[string]any, parent, boundary string, canonical func(string) string) {
	stream := nonempty(parent, "$root")
	switch str(e["type"]) {
	case "message_start":
		message := obj(e["message"])
		id := str(message["id"])
		p.messages[stream] = streamMessage{ID: id, Model: str(message["model"])}
		if parent == "" {
			p.messageStart(t, id, str(message["model"]))
		}
		if usage := obj(message["usage"]); usage != nil && id != "" {
			p.usage[id] = nativeUsage(usage)
			if parent == "" {
				p.contextTokens = usageContext(p.usage[id])
			}
			p.projectUsage(t)
		}
	case "content_block_start":
		b := obj(e["content_block"])
		if str(b["type"]) == "tool_use" {
			tool := &nativeTool{ID: str(b["id"]), Name: str(b["name"]), Input: b["input"]}
			p.tools[fmt.Sprintf("%s:%v", stream, e["index"])] = tool
			p.startTool(t, tool, parent, canonical)
		}
		if str(b["type"]) == "thinking" && parent == "" {
			t.StatusLabel = "正在思考"
		}
	case "content_block_delta":
		d := obj(e["delta"])
		switch str(d["type"]) {
		case "text_delta":
			if parent == "" {
				p.textBoundaries[boundary] = true
				p.textMessages[p.messages[stream].ID] = true
				t.text(str(d["text"]), p.messages[stream].ID, false)
			}
		case "thinking_delta":
			if parent == "" {
				p.reasoningBoundaries[boundary] = true
				p.reasoningMessages[p.messages[stream].ID] = true
				t.reasoning(str(d["thinking"]))
			}
		case "input_json_delta":
			if tool := p.tools[fmt.Sprintf("%s:%v", stream, e["index"])]; tool != nil {
				tool.Partial = clip(tool.Partial+str(d["partial_json"]), 100000)
			}
		}
	case "content_block_stop":
		key := fmt.Sprintf("%s:%v", stream, e["index"])
		if tool := p.tools[key]; tool != nil {
			if tool.Partial != "" {
				var input any
				if json.Unmarshal([]byte(tool.Partial), &input) == nil {
					tool.Input = input
				}
			}
			p.recordTask(tool)
			if tool.Name == "Workflow" {
				p.updateWorkflow(t, tool.ID, tool.Input)
			}
			delete(p.tools, key)
		}
	case "message_delta":
		m := p.messages[stream]
		if m.ID != "" {
			if p.usage[m.ID] == nil {
				p.usage[m.ID] = map[string]any{}
			}
			for k, v := range nativeUsage(obj(e["usage"])) {
				p.usage[m.ID][k] = v
			}
			if parent == "" {
				p.contextTokens = usageContext(p.usage[m.ID])
			}
			p.projectUsage(t)
		}
	case "message_stop":
		m := p.messages[stream]
		if m.ID != "" && p.onUsage != nil {
			p.onUsage(m.Model, m.ID, "generation", p.usage[m.ID])
		}
		if parent == "" {
			p.messageEnd(t, m.ID)
		}
		delete(p.messages, stream)
	}
}
func (p *frameParser) messageStart(t *Turn, id, model string) {
	if model != "" {
		if t.Author == nil {
			t.Author = map[string]any{}
		}
		t.Author["model"] = model
	}
	if t.LastAssistantMessage == nil || id == "" || str(t.LastAssistantMessage["id"]) != id {
		t.LastAssistantMessage = map[string]any{"text": ""}
		if id != "" {
			t.LastAssistantMessage["id"] = id
		}
	}
}
func (p *frameParser) messageEnd(t *Turn, id string) {
	if id == "" {
		return
	}
	for _, i := range t.Timeline {
		if str(i["kind"]) == "assistant" && str(i["messageId"]) == id && str(i["status"]) == "streaming" {
			i["status"] = "complete"
		}
	}
}
func (p *frameParser) startTool(t *Turn, tool *nativeTool, parent string, canonical func(string) string) {
	if tool.ID == "" || p.known[tool.ID] {
		return
	}
	p.known[tool.ID] = true
	name := tool.Name
	if canonical != nil {
		name = canonical(name)
	}
	activity := map[string]any{"id": tool.ID, "kind": toolKind(tool.Name), "label": nonempty(tool.Name, "调用工具"), "status": "running"}
	if tool.Name != "" {
		activity["toolName"] = name
	}
	if parent != "" {
		activity["parentId"] = parent
	}
	if tool.Name == "Workflow" {
		if detail := workflowDetail(tool.Input); detail != "" {
			activity["detail"] = detail
		}
	}
	t.activity(activity)
}
func toolKind(name string) string {
	name = strings.ToLower(strings.TrimSpace(name))
	switch name {
	case "bash", "shell", "command", "terminal":
		return "command"
	case "edit", "write", "read", "apply_patch", "patch", "multiedit", "notebookedit":
		return "file"
	case "web_search", "websearch", "webfetch", "web fetch", "grep", "glob":
		return "search"
	case "agent", "workflow":
		return "agent"
	case "task":
		return "task"
	}
	if strings.Contains(name, "terminal") {
		return "command"
	}
	if strings.Contains(name, "search") {
		return "search"
	}
	if strings.Contains(name, "hook") {
		return "hook"
	}
	return "tool"
}
func (p *frameParser) recordTask(tool *nativeTool) {
	if tool.Name == "TaskCreate" || tool.Name == "TaskUpdate" {
		p.taskMutations[tool.ID] = tool
	}
}

var taskCreated = regexp.MustCompile(`(?i)Task\s+#([^\s]+)\s+created\s+successfully`)

func (p *frameParser) applyTask(t *Turn, tool *nativeTool, result string) {
	input := obj(tool.Input)
	if input == nil {
		return
	}
	if tool.Name == "TaskCreate" {
		match := taskCreated.FindStringSubmatch(result)
		if len(match) != 2 || str(input["subject"]) == "" {
			return
		}
		id := match[1]
		if p.tasks[id] == nil {
			p.taskOrder = append(p.taskOrder, id)
		}
		p.tasks[id] = map[string]any{"step": clip(str(input["subject"]), 32000), "status": "pending"}
	} else {
		id := str(input["taskId"])
		current := p.tasks[id]
		if current == nil {
			return
		}
		if str(input["status"]) == "deleted" {
			delete(p.tasks, id)
		} else {
			if subject := str(input["subject"]); subject != "" {
				current["step"] = clip(subject, 32000)
			}
			if status := str(input["status"]); status != "" {
				normalized := "pending"
				if status == "completed" {
					normalized = "completed"
				}
				if contains([]string{"in_progress", "in-progress", "inProgress"}, status) {
					normalized = "inProgress"
				}
				current["status"] = normalized
			}
		}
	}
	t.Plan = []map[string]any{}
	for _, id := range p.taskOrder {
		if item := p.tasks[id]; item != nil {
			t.Plan = append(t.Plan, cloneObject(item))
		}
	}
	t.append("plan", map[string]any{"plan": t.Plan})
}
func nativeUsage(raw map[string]any) map[string]any {
	result := map[string]any{}
	for native, field := range map[string]string{"input_tokens": "inputTokens", "output_tokens": "outputTokens", "cache_read_input_tokens": "cachedTokens", "cache_creation_input_tokens": "cacheWriteTokens", "total_tokens": "totalTokens"} {
		if v, ok := raw[native]; ok {
			result[field] = number(v)
		}
	}
	if value, ok := obj(raw["output_tokens_details"])["thinking_tokens"]; ok {
		result["reasoningTokens"] = number(value)
	}
	return result
}
func (p *frameParser) projectUsage(t *Turn) {
	result := map[string]any{}
	for _, usage := range p.usage {
		for k, v := range usage {
			result[k] = number(result[k]) + number(v)
		}
	}
	for _, cost := range p.costs {
		result["costUsd"] = number(result["costUsd"]) + cost
	}
	if len(p.usage) > 0 {
		result["contextTokens"] = p.contextTokens
	}
	if value, ok := t.Usage["contextWindow"]; ok {
		result["contextWindow"] = value
	}
	if len(result) > 0 {
		t.Usage = result
	}
}
func contentText(v any) string {
	if s, ok := v.(string); ok {
		return clip(s, 100000)
	}
	parts := []string{}
	for _, b := range arr(v) {
		if text := str(obj(b)["text"]); text != "" {
			parts = append(parts, text)
		}
	}
	return clip(strings.Join(parts, "\n"), 100000)
}
func interactionFromControl(id string, r map[string]any) map[string]any {
	i := map[string]any{"id": id, "status": "pending"}
	switch str(r["subtype"]) {
	case "can_use_tool":
		name := nonempty(str(r["tool_name"]), "工具")
		i["kind"] = "permission"
		i["title"] = nonempty(str(r["title"]), "允许 Claude 使用 "+nonempty(str(r["display_name"]), name)+"？")
		i["toolName"] = name
		i["canRemember"] = len(arr(r["permission_suggestions"])) > 0
		if r["input"] != nil {
			i["input"] = r["input"]
		}
		if name == "AskUserQuestion" {
			i["kind"] = "question"
			i["title"] = nonempty(str(r["title"]), "Claude 需要你的选择")
			delete(i, "input")
			questions := []any{}
			for qi, v := range arr(obj(r["input"])["questions"]) {
				if qi >= 32 {
					break
				}
				q := obj(v)
				options := []any{}
				for oi, v := range arr(q["options"]) {
					if oi >= 32 {
						break
					}
					o := obj(v)
					option := map[string]any{"label": nonempty(str(o["label"]), "选项")}
					if d := str(o["description"]); d != "" {
						option["description"] = clip(d, 2000)
					}
					options = append(options, option)
				}
				question := map[string]any{"question": clip(nonempty(str(q["question"]), "请选择"), 20000), "multiSelect": q["multiSelect"] == true, "options": options}
				if h := str(q["header"]); h != "" {
					question["header"] = clip(h, 2000)
				}
				questions = append(questions, question)
			}
			i["questions"] = questions
		}
		if d := nonempty(str(r["description"]), str(r["decision_reason"])); d != "" {
			i["description"] = clip(d, 20000)
		}
	case "elicitation":
		i["kind"] = "elicitation"
		i["title"] = nonempty(str(r["title"]), nonempty(str(r["display_name"]), "MCP 需要输入"))
		i["elicitationMode"] = "form"
		if str(r["mode"]) == "url" || str(r["url"]) != "" {
			i["elicitationMode"] = "url"
		}
		if url := str(r["url"]); strings.HasPrefix(url, "https://") || strings.HasPrefix(url, "http://") {
			i["url"] = url
		}
		schema := r["requested_schema"]
		if schema == nil {
			schema = r["requestedSchema"]
		}
		if schema != nil {
			i["schema"] = schema
		}
		for native, field := range map[string]string{"elicitation_id": "elicitationId", "mcp_server_name": "serverName"} {
			if v := str(r[native]); v != "" {
				i[field] = v
			}
		}
		if d := nonempty(str(r["description"]), str(r["message"])); d != "" {
			i["description"] = clip(d, 20000)
		}
	case "request_user_dialog":
		i["kind"] = "dialog"
		i["title"] = "Claude Code：" + nonempty(str(r["dialog_kind"]), "需要确认")
		if r["payload"] != nil {
			i["input"] = r["payload"]
		}
	default:
		return nil
	}
	i["title"] = clip(str(i["title"]), 1000)
	for _, key := range []string{"input", "schema"} {
		if value, ok := i[key]; ok && !boundedInteractionJSON(value, 0, new(int)) {
			delete(i, key)
		}
	}
	return i
}

func usageContext(u map[string]any) float64 {
	return number(u["inputTokens"]) + number(u["outputTokens"]) + number(u["cachedTokens"]) + number(u["cacheWriteTokens"])
}

func boundedInteractionJSON(value any, depth int, nodes *int) bool {
	*nodes++
	if depth > 32 || *nodes > 10000 {
		return false
	}
	switch value := value.(type) {
	case string:
		if len(value) > 100000 {
			return false
		}
	case []any:
		for _, v := range value {
			if !boundedInteractionJSON(v, depth+1, nodes) {
				return false
			}
		}
	case map[string]any:
		for _, v := range value {
			if !boundedInteractionJSON(v, depth+1, nodes) {
				return false
			}
		}
	}
	if depth == 0 {
		bytes, err := json.Marshal(value)
		return err == nil && len(bytes) <= 100000
	}
	return true
}
func workflowDetail(value any) string {
	var input map[string]any
	text, ok := value.(string)
	if ok {
		_ = json.Unmarshal([]byte(text), &input)
	} else {
		input = obj(value)
	}
	phases := []string{}
	total := 0
	if values := arr(input["phases"]); len(values) > 0 {
		for _, v := range values {
			title := str(v)
			if title == "" {
				title = str(obj(v)["title"])
			}
			if title = strings.TrimSpace(title); title != "" {
				phases = append(phases, clip(title, 200))
			}
		}
		total = int(number(input["total"]))
	} else {
		if input != nil {
			text = str(input["script"])
		}
		text = strings.ReplaceAll(text, `\"`, `"`)
		start := regexp.MustCompile(`\bphases\s*:`).FindStringIndex(text)
		if len(start) > 0 {
			text = text[start[0]:]
			if end := strings.Index(text, "]"); end >= 0 {
				for _, match := range regexp.MustCompile(`\btitle\s*:\s*['"]([^'"]+)['"]`).FindAllStringSubmatch(text[:end], -1) {
					phases = append(phases, clip(match[1], 200))
				}
			}
		}
	}
	if len(phases) == 0 {
		return ""
	}
	if total < len(phases) || total > 10000 {
		total = len(phases)
	}
	if len(phases) > 6 {
		phases = phases[:6]
	}
	result := map[string]any{"phases": phases}
	if total > len(phases) {
		result["total"] = total
	}
	encoded, _ := json.Marshal(result)
	return string(encoded)
}
func (p *frameParser) updateWorkflow(t *Turn, id string, input any) {
	if detail := workflowDetail(input); detail != "" {
		for _, a := range t.Activities {
			if str(a["id"]) == id {
				copy := cloneObject(a)
				copy["detail"] = detail
				t.activity(copy)
				break
			}
		}
	}
}
