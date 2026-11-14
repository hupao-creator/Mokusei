package claude

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

type State struct {
	Version             int              `json:"version"`
	PrimarySessionID    string           `json:"primarySessionId,omitempty"`
	PendingFork         map[string]any   `json:"pendingFork,omitempty"`
	ForkHistory         map[string]any   `json:"forkHistory,omitempty"`
	GoalPromptPending   bool             `json:"goalPromptPending,omitempty"`
	Runtime             map[string]any   `json:"runtime,omitempty"`
	Turns               []*Turn          `json:"turns"`
	NativeNotifications []map[string]any `json:"nativeNotifications"`
}
type Turn struct {
	Author                map[string]any     `json:"author,omitempty"`
	ExecutionID           string             `json:"executionId"`
	CreatedAt             int64              `json:"createdAt"`
	UpdatedAt             int64              `json:"updatedAt"`
	FinishedAt            *int64             `json:"finishedAt,omitempty"`
	Prompts               []string           `json:"prompts"`
	PromptAttachments     [][]map[string]any `json:"promptAttachments"`
	InternalPromptIndexes []int              `json:"internalPromptIndexes,omitempty"`
	Status                string             `json:"status"`
	StatusLabel           string             `json:"statusLabel,omitempty"`
	Foreground            map[string]any     `json:"foreground,omitempty"`
	Error                 string             `json:"error,omitempty"`
	Plan                  []map[string]any   `json:"plan"`
	PlanExplanation       string             `json:"planExplanation,omitempty"`
	Activities            []map[string]any   `json:"activities"`
	Interactions          []map[string]any   `json:"interactions"`
	Notices               []map[string]any   `json:"notices"`
	Timeline              []map[string]any   `json:"timeline"`
	Usage                 map[string]any     `json:"usage,omitempty"`
	Compacted             bool               `json:"compacted,omitempty"`
}

func NewState() *State {
	return &State{Version: 2, Turns: []*Turn{}, NativeNotifications: []map[string]any{}}
}
func ParseState(raw json.RawMessage) (*State, error) {
	if model.IsNull(raw) {
		return NewState(), nil
	}
	var s State
	if err := json.Unmarshal(raw, &s); err != nil {
		return nil, err
	}
	if s.Version != 2 || s.Turns == nil || s.NativeNotifications == nil || len(s.Turns) > 2000 || len(s.NativeNotifications) > 200 {
		return nil, errors.New("invalid Claude session state")
	}
	if s.PrimarySessionID != "" && s.PendingFork != nil {
		return nil, errors.New("Claude session cannot have primary and pending fork")
	}
	ids := map[string]bool{}
	for _, t := range s.Turns {
		if t == nil || t.Prompts == nil || t.PromptAttachments == nil || t.Plan == nil || t.Activities == nil || t.Interactions == nil || t.Notices == nil || t.Timeline == nil || t.ExecutionID == "" || ids[t.ExecutionID] || !contains([]string{"running", "completed", "failed", "interrupted"}, t.Status) || t.Status != "running" && t.FinishedAt == nil || len(t.Prompts) != len(t.PromptAttachments) || len(t.Prompts) > 200 || len(t.Timeline) > 50000 || !validTimelineReferences(t) {
			return nil, errors.New("invalid Claude turn")
		}
		ids[t.ExecutionID] = true
	}
	return &s, nil
}
func (s *State) Encode() (json.RawMessage, error) { return json.Marshal(s) }
func (s *State) Find(id string) *Turn {
	for i := len(s.Turns) - 1; i >= 0; i-- {
		if s.Turns[i].ExecutionID == id {
			return s.Turns[i]
		}
	}
	return nil
}
func (s *State) Current() *Turn {
	if len(s.Turns) == 0 {
		return nil
	}
	return s.Turns[len(s.Turns)-1]
}
func (s *State) NewTurn(id string, input model.AgentInput, settings Settings) *Turn {
	now := time.Now().UnixMilli()
	t := &Turn{ExecutionID: id, CreatedAt: now, UpdatedAt: now, Status: "running", Prompts: []string{}, PromptAttachments: [][]map[string]any{}, Plan: []map[string]any{}, Activities: []map[string]any{}, Interactions: []map[string]any{}, Notices: []map[string]any{}, Timeline: []map[string]any{}}
	if settings.Model != "" {
		t.Author = map[string]any{"model": settings.Model}
		if settings.Thinking != nil {
			t.Author["thinking"] = settings.Thinking
		} else if settings.Effort != "" {
			t.Author["thinking"] = map[string]any{"mode": "effort", "effort": settings.Effort}
		}
	}
	s.Turns = append(s.Turns, t)
	t.addPrompt(input, "")
	return t
}
func (t *Turn) at() int64 {
	now := time.Now().UnixMilli()
	if now <= t.UpdatedAt {
		now = t.UpdatedAt + 1
	}
	t.UpdatedAt = now
	return now
}
func (t *Turn) append(kind string, fields map[string]any) {
	if len(t.Timeline) >= 50000 {
		return
	}
	at := t.at()
	item := map[string]any{"id": fmt.Sprintf("%s:%d:%d", kind, at, len(t.Timeline)), "kind": kind, "createdAt": at}
	for k, v := range fields {
		item[k] = v
	}
	t.Timeline = append(t.Timeline, item)
}

// reference appends one stable timeline position per entity identity. Entity
// updates stay in Activities/Interactions/Notices and never create another
// snapshot in the chronological stream.
func (t *Turn) reference(kind, field, id string) {
	if id == "" {
		return
	}
	for _, item := range t.Timeline {
		if str(item["kind"]) == kind && str(item[field]) == id {
			return
		}
	}
	t.append(kind, map[string]any{field: id})
}

func (t *Turn) review(text string) {
	// Readers only consume the latest review. Replacing the marker keeps one
	// copy while preserving the update's chronological position.
	items := t.Timeline[:0]
	for _, item := range t.Timeline {
		if str(item["kind"]) != "review" {
			items = append(items, item)
		}
	}
	clear(t.Timeline[len(items):])
	t.Timeline = items
	t.append("review", map[string]any{"content": clip(text, 500000)})
}

func (t *Turn) addPrompt(input model.AgentInput, checkpoint string) {
	index := len(t.Prompts)
	parts := []string{}
	attachments := []map[string]any{}
	annotations := []map[string]any{}
	if len(input.Annotations) > 0 {
		_ = json.Unmarshal(input.Annotations, &annotations)
	}
	screenshot := map[string]bool{}
	for _, annotation := range annotations {
		if id := str(annotation["screenshotId"]); id != "" {
			screenshot[id] = true
		}
	}
	for index, p := range input.Parts {
		switch p.Kind {
		case "text":
			if p.AnnotationID == "" {
				parts = append(parts, p.Text)
			}
		case "image-url", "audio-url":
			parts = append(parts, p.URL)
		case "mention", "skill":
			parts = append(parts, p.Name+": "+p.Path)
		default:
			if p.File != nil && !screenshot[p.File.ID] {
				parts = append(parts, p.File.Name)
			}
		}
		if p.File != nil {
			kind := "file"
			if p.Kind == "image" || p.Kind == "audio" {
				kind = p.Kind
			}
			attachments = append(attachments, map[string]any{"id": p.File.ID, "name": p.File.Name, "mimeType": p.File.MimeType, "size": p.File.Size, "kind": kind})
		} else if p.Kind == "image-url" || p.Kind == "audio-url" {
			kind := "image"
			if p.Kind == "audio-url" {
				kind = "audio"
			}
			attachments = append(attachments, map[string]any{"id": fmt.Sprintf("%s:%d", p.Kind, index), "name": clip(p.URL, 8192), "mimeType": kind + "/*", "size": 0, "kind": kind})
		}
	}
	for _, annotation := range annotations {
		found := false
		for _, attachment := range attachments {
			if str(attachment["id"]) == str(annotation["screenshotId"]) {
				attachment["annotation"] = annotation
				found = true
				break
			}
		}
		if !found {
			attachments = append(attachments, map[string]any{"id": annotation["id"], "name": "网页批注", "mimeType": "text/plain", "size": 0, "kind": "file", "annotation": annotation})
		}
	}
	prompt := strings.TrimSpace(strings.Join(parts, "\n"))
	if prompt == "" && len(annotations) == 0 {
		prompt = "[Multimodal input]"
	}
	t.Prompts = append(t.Prompts, clip(prompt, 2000000))
	t.PromptAttachments = append(t.PromptAttachments, attachments)
	if input.Presentation == "internal" {
		t.InternalPromptIndexes = append(t.InternalPromptIndexes, index)
	}
	item := map[string]any{"promptIndex": index}
	if checkpoint != "" {
		item["checkpointId"] = checkpoint
	}
	t.append("user-message", item)
}
func (t *Turn) checkpoint(index int, id string) {
	for _, item := range t.Timeline {
		if str(item["kind"]) == "user-message" && int(number(item["promptIndex"])) == index {
			item["checkpointId"] = id
			return
		}
	}
}
func (t *Turn) foreground(kind string, fields map[string]any) {
	seq := int64(number(t.Foreground["sequence"])) + 1
	if str(t.Foreground["kind"]) == kind && (kind != "tool-call" || str(t.Foreground["callId"]) == str(fields["callId"])) {
		seq--
	}
	f := map[string]any{"kind": kind, "sequence": seq}
	for k, v := range fields {
		f[k] = v
	}
	t.Foreground = f
}
func (t *Turn) text(delta, id string, synthetic bool) {
	delta = strings.ReplaceAll(delta, "\x00", "")
	if delta == "" {
		return
	}
	if id != "" {
		for _, item := range t.Timeline {
			if str(item["kind"]) == "assistant" && str(item["messageId"]) == id && str(item["status"]) == "complete" {
				return
			}
		}
	}
	if len(t.Timeline) > 0 {
		last := t.Timeline[len(t.Timeline)-1]
		if str(last["kind"]) == "assistant" && str(last["messageId"]) == id && str(last["status"]) == "streaming" {
			last["content"] = clip(str(last["content"])+delta, 4000000)
			t.at()
			t.StatusLabel = ""
			t.foreground("assistant-text", nil)
			return
		}
	}
	fields := map[string]any{"content": delta, "status": "streaming"}
	if id != "" {
		fields["messageId"] = id
	}
	t.append("assistant", fields)
	t.StatusLabel = ""
	t.foreground("assistant-text", nil)
}
func (t *Turn) reasoning(delta string) {
	delta = strings.ReplaceAll(delta, "\x00", "")
	if delta == "" {
		return
	}
	same := false
	if len(t.Timeline) > 0 {
		last := t.Timeline[len(t.Timeline)-1]
		if str(last["kind"]) == "reasoning" {
			last["content"] = clip(str(last["content"])+delta, 4000000)
			same = true
			t.at()
		}
	}
	if !same {
		t.append("reasoning", map[string]any{"content": delta})
	}
	text := delta
	if same && str(t.Foreground["kind"]) == "reasoning" {
		text = str(t.Foreground["text"]) + delta
	}
	offset := 0
	if same {
		offset = int(number(t.Foreground["textOffset"]))
	}
	points := []rune(text)
	if len(points) > 32768 {
		removed := points[:len(points)-32768]
		for _, r := range removed {
			if r > 0xffff {
				offset += 2
			} else {
				offset++
			}
		}
		text = string(points[len(points)-32768:])
	}
	fields := map[string]any{"text": text}
	if offset > 0 {
		fields["textOffset"] = offset
	}
	if !same && str(t.Foreground["kind"]) == "reasoning" {
		t.Foreground["sequence"] = number(t.Foreground["sequence"]) + 1
	}
	t.foreground("reasoning", fields)
	t.StatusLabel = "正在思考"
}
func (t *Turn) activity(value map[string]any) {
	value = cloneObject(value)
	id := str(value["id"])
	known := false
	for i, old := range t.Activities {
		if str(old["id"]) == id {
			known = true
			t.Activities[i] = value
			break
		}
	}
	if !known {
		if len(t.Activities) >= 2000 {
			return
		}
		t.Activities = append(t.Activities, value)
	}
	if str(value["kind"]) != "command" && !(str(value["kind"]) == "agent" && str(value["label"]) == "Workflow") {
		delete(value, "detail")
	}
	if !known {
		t.reference("activity", "activityId", id)
		if str(value["toolName"]) != "" {
			t.foreground("tool-call", map[string]any{"callId": id, "toolName": clip(str(value["toolName"]), 64)})
		}
	}
}
func (t *Turn) activityEnd(id, status, detail string) {
	for _, a := range t.Activities {
		if str(a["id"]) == id {
			a = cloneObject(a)
			a["status"] = status
			if str(a["kind"]) == "command" && detail != "" {
				a["detail"] = clip(detail, 100000)
			}
			t.activity(a)
			return
		}
	}
}
func (t *Turn) interaction(value map[string]any) {
	value = cloneObject(value)
	for i, v := range t.Interactions {
		if str(v["id"]) == str(value["id"]) {
			t.Interactions[i] = value
			return
		}
	}
	if len(t.Interactions) < 500 {
		t.Interactions = append(t.Interactions, value)
		t.reference("interaction", "interactionId", str(value["id"]))
	}
	t.StatusLabel = "等待你的回应"
}
func (t *Turn) notice(level, message string) {
	if len(t.Notices) >= 500 {
		return
	}
	n := map[string]any{"id": newID(), "level": level, "message": clip(message, 20000)}
	t.Notices = append(t.Notices, n)
	t.reference("notice", "noticeId", str(n["id"]))
}
func (t *Turn) fail(message string) {
	t.Error = clip(message, 100000)
	items := t.Timeline[:0]
	for _, item := range t.Timeline {
		if str(item["kind"]) != "error" {
			items = append(items, item)
		}
	}
	clear(t.Timeline[len(items):])
	t.Timeline = items
	t.append("error", nil)
}
func (t *Turn) settle(outcome string, at int64, background map[string]bool) {
	if t.Status != "running" {
		return
	}
	if at < t.UpdatedAt {
		at = t.UpdatedAt
	}
	t.Status = outcome
	t.FinishedAt = &at
	t.UpdatedAt = at
	t.StatusLabel = ""
	t.Foreground = nil
	for _, i := range t.Timeline {
		if str(i["kind"]) == "assistant" && str(i["status"]) == "streaming" {
			status := "complete"
			if outcome == "failed" {
				status = "failed"
			}
			if outcome == "interrupted" {
				status = "cancelled"
			}
			i["status"] = status
		}
	}
	for _, a := range t.Activities {
		if str(a["status"]) == "running" && !background[nonempty(str(a["taskId"]), str(a["id"]))] {
			a["status"] = "cancelled"
		}
	}
	for _, i := range t.Interactions {
		if str(i["status"]) == "pending" {
			i["status"] = "cancelled"
		}
	}
}
func (s *State) background() map[string]bool {
	out := map[string]bool{}
	for _, v := range arr(s.Runtime["backgroundTasks"]) {
		m := obj(v)
		if taskStatus(str(m["status"])) == "running" {
			out[str(m["id"])] = true
		}
	}
	return out
}
func validTimelineReferences(t *Turn) bool {
	activities, interactions, notices := map[string]bool{}, map[string]bool{}, map[string]bool{}
	for _, values := range []struct {
		items []map[string]any
		seen  map[string]bool
	}{{t.Activities, activities}, {t.Interactions, interactions}, {t.Notices, notices}} {
		for _, item := range values.items {
			id := str(item["id"])
			if id == "" || values.seen[id] {
				return false
			}
			values.seen[id] = true
		}
	}
	seen := map[string]bool{}
	for _, item := range t.Timeline {
		kind := str(item["kind"])
		var field string
		var current map[string]bool
		switch kind {
		case "activity":
			field, current = "activityId", activities
		case "interaction":
			field, current = "interactionId", interactions
		case "notice":
			field, current = "noticeId", notices
		case "error":
			// The current error owns the body; the timeline carries only its position.
			if _, present := item["message"]; present || !timelineKeys(item, "id", "kind", "createdAt") {
				return false
			}
			continue
		case "user-message":
			if !timelineKeys(item, "id", "kind", "createdAt", "promptIndex", "checkpointId") || item["promptIndex"] == nil {
				return false
			}
			continue
		case "assistant":
			if !timelineKeys(item, "id", "kind", "createdAt", "content", "status", "messageId") || item["content"] == nil || !contains([]string{"complete", "streaming", "failed", "cancelled"}, str(item["status"])) {
				return false
			}
			continue
		case "reasoning", "review":
			if !timelineKeys(item, "id", "kind", "createdAt", "content") || item["content"] == nil {
				return false
			}
			continue
		case "context-compaction":
			if !timelineKeys(item, "id", "kind", "createdAt") {
				return false
			}
			continue
		default:
			return false
		}
		// Inline entity snapshots belong to the previous schema and are not
		// accepted beside the authoritative tables.
		if item[kind] != nil || !timelineKeys(item, "id", "kind", "createdAt", field) {
			return false
		}
		id := str(item[field])
		if id == "" || !current[id] {
			return false
		}
		key := kind + ":" + id
		if seen[key] {
			return false
		}
		seen[key] = true
	}
	return true
}

func timelineKeys(item map[string]any, keys ...string) bool {
	for key := range item {
		if !contains(keys, key) {
			return false
		}
	}
	return true
}

func taskStatus(s string) string {
	switch strings.ToLower(s) {
	case "completed", "done", "success", "succeeded":
		return "completed"
	case "failed", "error":
		return "failed"
	case "cancelled", "canceled", "stopped", "killed":
		return "cancelled"
	default:
		return "running"
	}
}
func (s *State) settleBackground() {
	for _, v := range arr(s.Runtime["backgroundTasks"]) {
		m := obj(v)
		if taskStatus(str(m["status"])) == "running" {
			m["status"] = "failed"
		}
	}
	for _, t := range s.Turns {
		for _, a := range t.Activities {
			if str(a["status"]) == "running" {
				a["status"] = "failed"
			}
		}
	}
}
func timelineText(timeline []map[string]any, kind string, limit int) string {
	var text strings.Builder
	remaining := limit
	for _, item := range timeline {
		if str(item["kind"]) != kind {
			continue
		}
		appendBoundedText(&text, str(item["content"]), &remaining)
		if remaining == 0 {
			break
		}
	}
	return text.String()
}

func timelineHasText(timeline []map[string]any, kind string) bool {
	for _, item := range timeline {
		if str(item["kind"]) == kind && strings.TrimSpace(str(item["content"])) != "" {
			return true
		}
	}
	return false
}

func appendBoundedText(text *strings.Builder, value string, remaining *int) {
	if value == "" || *remaining == 0 {
		return
	}
	for _, r := range value {
		if r == 0 {
			continue
		}
		if *remaining == 0 {
			return
		}
		text.WriteRune(r)
		if *remaining > 0 {
			*remaining--
		}
	}
}

// lastAssistantMessageText returns the latest message identity and its body.
// Multiple streaming segments share one identity and are joined in timeline
// order; a positive limit stops before copying the rest of the body.
func (t *Turn) lastAssistantMessageText(limit int) (string, string) {
	for index := len(t.Timeline) - 1; index >= 0; index-- {
		item := t.Timeline[index]
		if str(item["kind"]) != "assistant" {
			continue
		}
		id := str(item["messageId"])
		remaining := limit
		if remaining <= 0 {
			remaining = -1
		}
		if id == "" {
			var text strings.Builder
			appendBoundedText(&text, str(item["content"]), &remaining)
			return "", text.String()
		}
		var text strings.Builder
		for _, segment := range t.Timeline {
			if str(segment["kind"]) == "assistant" && str(segment["messageId"]) == id {
				appendBoundedText(&text, str(segment["content"]), &remaining)
				if remaining == 0 {
					break
				}
			}
		}
		return id, text.String()
	}
	return "", ""
}

func (t *Turn) lastAssistantMessage() (string, string) { return t.lastAssistantMessageText(0) }
func (t *Turn) assistantText() string                  { return timelineText(t.Timeline, "assistant", 4000000) }
func (t *Turn) reasoningText() string                  { return timelineText(t.Timeline, "reasoning", 4000000) }
func (t *Turn) lastAssistantText() string {
	_, text := t.lastAssistantMessageText(20000)
	return text
}

func clip(s string, n int) string {
	s = strings.ReplaceAll(s, "\x00", "")
	r := []rune(s)
	if len(r) > n {
		return string(r[:n])
	}
	return s
}
func cloneObject(m map[string]any) map[string]any {
	if m == nil {
		return nil
	}
	b, _ := json.Marshal(m)
	var out map[string]any
	_ = json.Unmarshal(b, &out)
	return out
}
func digest(kind, execution, id string, indexes ...int) string {
	hash := sha256.New()
	_, _ = hash.Write([]byte("mokusei.claude.public-interaction.v1"))
	parts := []string{kind, execution, id}
	for _, i := range indexes {
		parts = append(parts, fmt.Sprint(i))
	}
	for _, p := range parts {
		_, _ = fmt.Fprintf(hash, "%d:", len([]byte(p)))
		_, _ = hash.Write([]byte(p))
	}
	return "claude-" + kind + "-sha256-" + hex.EncodeToString(hash.Sum(nil))
}
func publicInteraction(execution string, i map[string]any) model.PublicInteraction {
	id := str(i["id"])
	kind := str(i["kind"])
	out := model.PublicInteraction{ID: digest("interaction", execution, id), Kind: "question", Title: str(i["title"]), Actions: []model.PublicInteractionAction{}, Questions: []model.PublicInteractionQuestion{}}
	if description := str(i["description"]); description != "" {
		out.Description = &description
	}
	add := func(id, intent, label string) {
		out.Actions = append(out.Actions, model.PublicInteractionAction{ID: id, Intent: intent, Label: label})
	}
	if kind == "permission" {
		out.Kind = "permission"
		add("allow", "allow", "Allow")
		if i["canRemember"] == true {
			add("allow-session", "allow", "Allow for session")
		}
		add("deny", "deny", "Deny")
		add("cancel", "cancel", "Cancel")
	} else {
		label := "Submit"
		if kind == "elicitation" && str(i["elicitationMode"]) == "url" {
			label = "Accept and open"
		}
		add("submit", "submit", label)
		if kind == "elicitation" {
			add("deny", "deny", "Decline")
		}
		add("cancel", "cancel", "Cancel")
	}
	question := func(index int, prompt string) model.PublicInteractionQuestion {
		return model.PublicInteractionQuestion{ID: digest("question", execution, id, index), Prompt: clip(prompt, 20000), AllowOther: true, Options: []model.PublicInteractionOption{}}
	}
	switch kind {
	case "permission":
		out.Questions = append(out.Questions, question(0, "Optional denial reason"))
	case "dialog":
		out.Questions = append(out.Questions, question(0, nonempty(str(i["title"]), "Reply")))
	case "elicitation":
		if str(i["elicitationMode"]) != "url" {
			prompt := "JSON form values"
			if schema := i["schema"]; schema != nil {
				// Use the same JavaScript-compatible display spelling as native
				// schemaDisplay so `&`, `<`, `>` and line separators compare
				// exactly in the native public-interaction matcher.
				prompt += " matching this schema:\n" + displayJSON(schema)
			}
			q := question(0, prompt)
			q.AnswerFormat = "json-object"
			out.Questions = append(out.Questions, q)
		}
	case "question":
		for qi, v := range arr(i["questions"]) {
			raw := obj(v)
			q := question(qi, nonempty(str(raw["question"]), "请选择"))
			q.Multiple = raw["multiSelect"] == true
			if h := str(raw["header"]); h != "" {
				q.Header = &h
			}
			for oi, v := range arr(raw["options"]) {
				option := obj(v)
				p := model.PublicInteractionOption{Value: digest("option", execution, id, qi, oi), Label: str(option["label"])}
				if d := str(option["description"]); d != "" {
					p.Description = &d
				}
				q.Options = append(q.Options, p)
			}
			out.Questions = append(out.Questions, q)
		}
	}
	return out
}
func (s *State) observation() model.PublicObservation {
	out := model.PublicObservation{}
	if len(s.background()) > 0 {
		out.BackgroundWork = &model.PublicBackgroundWork{Status: "running"}
	}
	t := s.Current()
	if t == nil {
		return out
	}
	execution := &model.PublicExecution{ExecutionID: t.ExecutionID, Status: t.Status, StartedAt: t.CreatedAt, FinishedAt: t.FinishedAt}
	summary := t.lastAssistantText()
	if t.Status == "running" {
		summary = clip(nonempty(timelineText(t.Timeline, "assistant", 2000), timelineText(t.Timeline, "reasoning", 2000)), 2000)
	}
	if summary != "" {
		execution.Summary = &summary
	}
	if t.Status == "failed" && t.Error != "" {
		execution.Error = &t.Error
	}
	if t.Status == "running" {
		for _, i := range t.Interactions {
			if str(i["status"]) == "pending" {
				execution.Interactions = append(execution.Interactions, publicInteraction(t.ExecutionID, i))
			}
		}
		if len(execution.Interactions) > 0 {
			execution.Status = "waiting-for-user"
		}
	}
	out.LatestExecution = execution
	return out
}

type StateAdapter struct{}

func (StateAdapter) Project(raw json.RawMessage) (model.PublicObservation, error) {
	s, e := ParseState(raw)
	if e != nil {
		return model.PublicObservation{}, e
	}
	return s.observation(), nil
}
func (StateAdapter) ReadContext(raw json.RawMessage) (json.RawMessage, error) {
	s, e := ParseState(raw)
	if e != nil {
		return nil, e
	}
	return json.Marshal(s.Turns)
}
func (StateAdapter) ResolveExecution(raw json.RawMessage, id string) (*model.PublicExecution, error) {
	s, e := ParseState(raw)
	if e != nil {
		return nil, e
	}
	t := s.Find(id)
	if t == nil {
		return nil, nil
	}
	s.Turns = []*Turn{t}
	return s.observation().LatestExecution, nil
}
func (StateAdapter) Settle(req plugin.SettleRequest) (json.RawMessage, error) {
	s, e := ParseState(req.SessionState)
	if e != nil {
		return nil, e
	}
	if t := s.Find(req.ExecutionID); t != nil {
		t.settle(req.Outcome, req.FinishedAt, s.background())
	}
	return s.Encode()
}
func (StateAdapter) ProjectRenderer(raw json.RawMessage, scope model.RendererScope) (json.RawMessage, error) {
	s, e := ParseState(raw)
	if e != nil {
		return nil, e
	}
	initialResponseScope := len(s.Turns) <= 1 && s.PendingFork == nil && s.ForkHistory == nil
	compactRuntime(s)
	if scope.Kind == "turn" || scope.Kind == "execution" {
		turns := []*Turn{}
		for _, t := range s.Turns {
			if t.ExecutionID == scope.Key {
				for _, i := range t.Interactions {
					for _, field := range []string{"input", "schema"} {
						if v, ok := i[field]; ok {
							i[field+"Display"] = displayJSON(v)
						}
					}
				}
				turns = append(turns, t)
			}
		}
		s.Turns = turns
		if scope.Key != "fork-history" {
			s.ForkHistory = nil
		}
		if scope.Kind == "turn" {
			// Plans still belong to canonical/overview state, but the reader
			// no longer consumes them, including inherited timeline entries.
			for _, turn := range turns {
				turn.Plan = []map[string]any{}
				turn.PlanExplanation = ""
				items := turn.Timeline[:0]
				for _, item := range turn.Timeline {
					if str(item["kind"]) != "plan" {
						items = append(items, item)
					}
				}
				clear(turn.Timeline[len(items):])
				turn.Timeline = items
			}
			if s.ForkHistory != nil {
				items := []any{}
				for _, value := range arr(s.ForkHistory["items"]) {
					if str(obj(value)["kind"]) != "plan" {
						items = append(items, value)
					}
				}
				s.ForkHistory["items"] = items
			}
		}
		deferred := scope.Kind == "turn" && (s.ForkHistory != nil || len(turns) > 0)
		for _, turn := range turns {
			if turn.Status == "running" {
				deferred = false
			}
		}
		if deferred {
			presence := []map[string]string{}
			hide := func(id, field, value string) string {
				if strings.TrimSpace(value) != "" {
					presence = append(presence, map[string]string{"id": id, "field": field})
				}
				return ""
			}
			hideActivity := func(activity map[string]any, id string) {
				if activity == nil {
					return
				}
				// Keep bounded failed diagnostics for full readers; Agent detail
				// still classifies failed tools as execution work.
				if activity["status"] == "failed" {
					return
				}
				hide(id, "detail", str(activity["detail"]))
				delete(activity, "detail")
				activity["label"] = ""
			}
			for _, turn := range turns {
				turn.Foreground = nil
				for _, activity := range turn.Activities {
					hideActivity(activity, str(activity["id"]))
				}
				for _, item := range turn.Timeline {
					if str(item["kind"]) == "reasoning" {
						item["content"] = hide(str(item["id"]), "content", str(item["content"]))
					}
				}
			}
			if s.ForkHistory != nil {
				for _, value := range arr(s.ForkHistory["items"]) {
					item := obj(value)
					if str(item["kind"]) == "reasoning" {
						item["content"] = hide(str(item["id"]), "content", str(item["content"]))
					}
					if str(item["kind"]) == "activity" {
						// Inherited activities have no embedded id; their timeline
						// item is the stable native history identity.
						hideActivity(obj(item["activity"]), str(item["id"]))
					}
				}
			}
			return json.Marshal(map[string]any{"kind": "deferred-execution", "state": s, "nonempty": presence})
		}
		return s.Encode()
	}
	return compactRenderer(s, scope, initialResponseScope)
}
