package moku

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

func (c *Coordinator) tools(owner string, description ThreadCreationDescription) []plugin.ToolBinding {
	c.mu.Lock()
	generation := c.generation
	c.mu.Unlock()
	bindings := ToolSchemas(description)
	for index := range bindings {
		binding := bindings[index]
		validate := newToolJSONValidator(binding.InputSchema)
		bindings[index].Execute = func(ctx context.Context, call plugin.ToolCall) (json.RawMessage, error) {
			ctx, finish, err := c.begin(ctx)
			if err != nil {
				return nil, err
			}
			defer finish()
			c.mu.Lock()
			stale := c.generation != generation
			c.mu.Unlock()
			if stale {
				return nil, errors.New("Moku tool belongs to a retired settings generation")
			}
			record, err := c.current()
			if err != nil {
				return nil, err
			}
			if record.ID != owner {
				return nil, errors.New("Moku tool belongs to a replaced Thread")
			}
			execution := record.Observation.LatestExecution
			if execution == nil || execution.Terminal() {
				return nil, errors.New("Moku tool has no active execution")
			}
			c.mu.Lock()
			scope, ok := c.scopes[execution.ExecutionID]
			stale = c.generation != generation
			c.mu.Unlock()
			if !ok || stale || scope.threadID != owner {
				return nil, errors.New("Moku tool has no active execution scope")
			}
			if err = scope.ctx.Err(); err != nil {
				return nil, err
			}
			linked, cancel := context.WithCancel(ctx)
			stop := context.AfterFunc(scope.ctx, cancel)
			defer func() { stop(); cancel() }()
			if err = linked.Err(); err != nil {
				return nil, err
			}
			if len(call.Arguments) > 8*1024*1024 || !json.Valid(call.Arguments) {
				return nil, errors.New("Moku tool arguments must be bounded JSON")
			}
			callID := newID()
			operationID := newID()
			created := time.Now().UnixMilli()
			if err = c.appendTranscript(linked, owner, map[string]any{"type": "tool-operation", "id": operationID, "executionId": execution.ExecutionID, "callId": callID, "name": binding.Name, "arguments": call.Arguments, "createdAt": created}); err != nil {
				return nil, err
			}
			var result json.RawMessage
			invokeErr := plugin.CallerError(validate(call.Arguments))
			if invokeErr == nil {
				result, invokeErr = c.executeTool(linked, owner, binding.Name, call.Arguments, description)
			}
			if invokeErr == nil && (len(result) > 8*1024*1024 || !json.Valid(result)) {
				invokeErr = errors.New("Moku tool result exceeds the JSON boundary")
			}
			if invokeErr != nil {
				message := invokeErr.Error()
				if len(message) > 8192 {
					message = message[:8192]
				}
				result, _ = json.Marshal(map[string]any{"error": message})
			}
			recordErr := c.completeTool(context.WithoutCancel(linked), owner, execution.ExecutionID, callID, result, invokeErr != nil)
			if failure := toolInvocationFailure(invokeErr, recordErr); failure != nil {
				return nil, failure
			}
			return result, nil
		}
	}
	return bindings
}

// toolInvocationFailure keeps an internal failure internal: when recording the
// result failed too, the tool call is a Harness fault even if the invocation
// itself carried a caller-correctable error, so the marker is flattened away.
func toolInvocationFailure(invokeErr, recordErr error) error {
	switch {
	case recordErr == nil:
		return invokeErr
	case invokeErr == nil:
		return recordErr
	default:
		return fmt.Errorf("%v; Moku tool record failed: %w", invokeErr, recordErr)
	}
}
func (c *Coordinator) executeTool(ctx context.Context, owner, name string, raw json.RawMessage, description ThreadCreationDescription) (result json.RawMessage, err error) {
	defer func() {
		if recover() != nil {
			result = nil
			err = errors.New("Moku tool handler failed")
		}
	}()
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	object, err := model.DecodeObject(raw)
	if err != nil {
		return nil, err
	}
	getText := func(key string, max int) (string, error) {
		value, ok := object[key].(string)
		value = strings.TrimSpace(value)
		if !ok || value == "" || model.UTF16Length(value) > max || strings.ContainsRune(value, 0) {
			return "", fmt.Errorf("%s 无效", key)
		}
		return value, nil
	}
	encode := func(value any) (json.RawMessage, error) { return json.Marshal(value) }
	switch name {
	case "read_clipboard":
		maxCharacters := clipboardDefaultCharacters
		if value, present := object["maxCharacters"]; present {
			// The installed binding has already validated the integer and bounds.
			number, _ := value.(json.Number).Float64()
			maxCharacters = int(number)
		}
		reader := c.readClipboardText
		if reader == nil {
			reader = readSystemClipboardText
		}
		value, err := readClipboard(ctx, maxCharacters, reader)
		if err != nil {
			return nil, err
		}
		return encode(value)
	case "list_threads":
		records, err := c.config.Threads()
		if err != nil {
			return nil, err
		}
		ordinary := []model.ThreadRecord{}
		for _, record := range records {
			if !record.Moku && !record.MokuHistory {
				ordinary = append(ordinary, record)
			}
		}
		return ListThreads(ordinary, raw)
	case "create_thread":
		target, err := ParseCreateRequest(raw)
		if err != nil {
			return nil, plugin.CallerError(err)
		}
		resolve := func(ctx context.Context, cwd string) (json.RawMessage, error) {
			h, settings, err := c.target(ctx, target.HarnessID, description)
			if err != nil {
				return nil, err
			}
			schema, err := h.Settings().Describe(ctx, plugin.SettingsRequest{Settings: settings, Cwd: cwd})
			if err != nil {
				return nil, err
			}
			if err = validateToolJSON(schema, target.Options); err != nil {
				return nil, plugin.CallerError(err)
			}
			defaults, err := h.Settings().DefaultThread(settings)
			if err != nil {
				return nil, err
			}
			return h.Settings().ResolveThread(ctx, plugin.ResolveSettingsRequest{Merged: defaults, Requested: target.Options, Cwd: cwd})
		}
		if c.config.CreateThread == nil {
			return nil, errors.New("Moku thread creation unavailable")
		}
		var worktree *model.WorktreeOptions
		if target.Worktree != nil && *target.Worktree {
			worktree = &model.WorktreeOptions{Enabled: target.Worktree, Name: target.WorktreeName}
		}
		created, err := c.config.CreateThread(ctx, CreateThreadRequest{HarnessID: target.HarnessID, Input: textInput(target.Prompt), Cwd: target.Cwd, ResolveSettings: resolve, Worktree: worktree})
		if err != nil {
			return nil, err
		}
		result := map[string]any{"ok": true, "threadId": created.Record.ID, "executionId": created.Execution.ExecutionID, "workspace": publicWorkspace(created.Record), "acknowledgement": created.Acknowledgement, "hint": ThreadNotificationHint}
		if created.WorktreeName != "" {
			result["worktreeName"] = created.WorktreeName
			result["worktreeNameAdjusted"] = created.WorktreeNameAdjusted
			if created.WorktreeNameNotice != "" {
				result["notice"] = created.WorktreeNameNotice
			}
		}
		return encode(result)
	case "describe_native_harness":
		if len(object) != 1 {
			return nil, errors.New("Invalid native Harness selection")
		}
		id, err := getText("harnessId", 128)
		if err != nil {
			return nil, err
		}
		h, settings, err := c.target(ctx, id, description)
		if err != nil {
			return nil, err
		}
		schema, err := h.Settings().Describe(ctx, plugin.SettingsRequest{Settings: settings, Cwd: c.config.Workspace})
		if err != nil {
			return nil, err
		}
		return encode(map[string]any{"harnessId": id, "options": schema, "creation": "Call create_thread with this harnessId and explicit options matching every required field. " + threadCreationWorktreeGuidance})
	case "interrupt_thread":
		var request struct {
			ThreadIDs []string `json:"threadIds"`
		}
		if err := json.Unmarshal(raw, &request); err != nil {
			return nil, err
		}
		type interruptResult struct {
			ThreadID string `json:"threadId"`
			OK       bool   `json:"ok"`
			Error    string `json:"error,omitempty"`
		}
		results := make([]interruptResult, 0, len(request.ThreadIDs))
		ok := true
		for _, id := range request.ThreadIDs {
			record, interruptErr := c.config.Thread(id)
			if interruptErr == nil {
				switch {
				case record.Moku || record.MokuHistory:
					interruptErr = errors.New("Moku tools may only target ordinary Agent Threads")
				case c.config.InterruptThread == nil:
					interruptErr = errors.New("Thread interrupt unavailable")
				default:
					interruptErr = c.config.InterruptThread(ctx, id)
				}
			}
			item := interruptResult{ThreadID: id, OK: interruptErr == nil}
			if interruptErr != nil {
				item.Error = interruptErr.Error()
				ok = false
			}
			results = append(results, item)
		}
		return encode(map[string]any{"ok": ok, "results": results})
	case "get_thread_status", "send_to_thread", "read_thread":
		id, err := getText("threadId", 128)
		if err != nil {
			return nil, err
		}
		record, err := c.config.Thread(id)
		if err != nil {
			return nil, err
		}
		if record.Moku || record.MokuHistory {
			return nil, errors.New("Moku tools may only target ordinary Agent Threads")
		}
		switch name {
		case "get_thread_status":
			return encode(map[string]any{"ok": true, "thread": publicThread(record)})
		case "send_to_thread":
			prompt, err := getText("prompt", 1_000_000)
			if err != nil {
				return nil, err
			}
			if c.config.SendThread == nil {
				return nil, errors.New("Thread send unavailable")
			}
			sent, err := c.config.SendThread(ctx, id, textInput(prompt))
			if err != nil {
				return nil, err
			}
			return encode(map[string]any{"ok": true, "threadId": id, "executionId": sent.ExecutionID, "startedNewExecution": sent.StartedNewExecution, "hint": ThreadNotificationHint})
		case "read_thread":
			question, err := getText("question", 1_000_000)
			if err != nil {
				return nil, err
			}
			if c.config.ReadThread == nil {
				return nil, errors.New("Thread history read unavailable")
			}
			answer, err := c.config.ReadThread(ctx, id, question)
			if err != nil {
				return nil, err
			}
			return encode(map[string]any{"ok": true, "threadId": id, "answer": answer})
		}
	case "update_note":
		text, expected, err := parseNoteUpdate(raw)
		if err != nil {
			return nil, plugin.CallerError(err)
		}
		if c.config.UpdateNote == nil {
			return nil, errors.New("Moku note update unavailable")
		}
		updated, err := c.config.UpdateNote(ctx, owner, text, expected)
		if err != nil {
			return nil, err
		}
		return encode(updated)
	case "talk":
		original, ok := object["text"].(string)
		if !ok {
			return nil, errors.New("talk 的 text 必须是纯文本字符串")
		}
		if utf8.RuneCountInString(original) > TalkTextMaxCharacters {
			return nil, fmt.Errorf("talk 的 text 最多 %d 个 Unicode 码点（含空白和换行）；请缩短后重试，内容不会截断", TalkTextMaxCharacters)
		}
		if len(object) != 1 {
			return nil, errors.New("talk 只接受 text 参数")
		}
		if strings.TrimFunc(original, func(r rune) bool { return r == '\u0085' || mokuWhitespace(r) }) == "" || strings.ContainsRune(original, 0) {
			return nil, errors.New("talk 的 text 必须包含非空白内容，且不能包含 NUL")
		}
		return encode(map[string]any{"ok": true})
	}
	return nil, errors.New("Unknown Moku tool")
}

// parseNoteUpdate is the protocol boundary for update_note. The whole note is
// replaced, so an exactly empty string is the explicit clear and every other
// input must be usable, user-visible Markdown. Rejections are caller-correctable
// and never truncate the submitted content.
func parseNoteUpdate(raw json.RawMessage) (string, *model.NoteBasis, error) {
	object, err := model.DecodeObject(raw)
	if err != nil {
		return "", nil, errors.New("update_note 参数无效")
	}
	text, ok := object["text"].(string)
	value, present := object["expected"]
	if !ok || !present || len(object) != 2 {
		return "", nil, errors.New("update_note 只接受 text 和 expected 参数")
	}
	if utf8.RuneCountInString(text) > NoteTextMaxCharacters {
		return "", nil, fmt.Errorf("update_note 的 text 最多 %d 个 Unicode 码点（含空白和换行）；请缩短后重试，内容不会截断", NoteTextMaxCharacters)
	}
	if text != "" {
		blank := strings.TrimFunc(text, func(r rune) bool { return r == '\u0085' || mokuWhitespace(r) }) == ""
		if blank || strings.ContainsRune(text, 0) {
			return "", nil, errors.New("update_note 的 text 必须包含非空白内容，且不能包含 NUL；仅空字符串可以清除笔记")
		}
	}
	if value == nil {
		return text, nil, nil
	}
	basis, ok := value.(map[string]any)
	if !ok || len(basis) != 3 {
		return "", nil, errors.New("update_note expected 无效")
	}
	id, ok := basis["noteId"].(string)
	if !ok || !noteUUID.MatchString(id) {
		return "", nil, errors.New("update_note expected.noteId 无效")
	}
	revision, ok := noteSafeInteger(basis["revision"], 1)
	if !ok {
		return "", nil, errors.New("update_note expected.revision 无效")
	}
	reading, ok := noteSafeInteger(basis["readingRevision"], 0)
	if !ok {
		return "", nil, errors.New("update_note expected.readingRevision 无效")
	}
	return text, &model.NoteBasis{NoteID: id, Revision: revision, ReadingRevision: reading}, nil
}

var noteUUID = regexp.MustCompile(`(?i)^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)

func noteSafeInteger(value any, minimum int64) (int64, bool) {
	n, ok := value.(json.Number)
	if !ok {
		return 0, false
	}
	v, err := n.Int64()
	return v, err == nil && v >= minimum && v <= model.MaximumSafeInteger
}

func (c *Coordinator) target(ctx context.Context, id string, description ThreadCreationDescription) (plugin.Harness, json.RawMessage, error) {
	settings, _, err := c.config.Settings()
	if err != nil {
		return nil, nil, err
	}
	contains := func(values []string) bool {
		for _, value := range values {
			if value == id {
				return true
			}
		}
		return false
	}
	if !contains(settings.Moku.TargetHarnessIDs) || !contains(description.TargetHarnessIDs) {
		return nil, nil, plugin.CallerError(fmt.Errorf("Harness is absent from the current Thread creation schema: %s", id))
	}
	if c.config.HarnessEnabled != nil && !c.config.HarnessEnabled(id) {
		return nil, nil, plugin.CallerError(errors.New("Moku Target Harness is disabled"))
	}
	harness := c.config.Harnesses[id]
	if harness == nil {
		return nil, nil, plugin.CallerError(fmt.Errorf("Unknown Harness %s", id))
	}
	merged := mergedSettings(settings, id, false)
	availability, err := c.available(ctx, harness, merged)
	if err != nil {
		return nil, nil, err
	}
	if !availability.Available {
		return nil, nil, fmt.Errorf("Moku Target Harness 不可用: %s (%s)", id, availability.Reason)
	}
	return harness, merged, nil
}
