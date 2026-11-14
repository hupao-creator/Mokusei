package claude

import (
	"encoding/json"
	"strings"

	"github.com/hupao-creator/Mokusei/internal/core/model"
)

func compactRuntime(s *State) {
	s.PendingFork = nil
	s.GoalPromptPending = false
	if s.Runtime != nil {
		runtime := map[string]any{}
		for _, k := range []string{"model", "cwd"} {
			if v := str(s.Runtime[k]); v != "" {
				runtime[k] = v
			}
		}
		if tasks := arr(s.Runtime["backgroundTasks"]); tasks != nil {
			if len(tasks) > 32 {
				tasks = tasks[len(tasks)-32:]
			}
			for _, v := range tasks {
				task := obj(v)
				task["description"] = clip(str(task["description"]), 1200)
			}
			runtime["backgroundTasks"] = tasks
		}
		s.Runtime = runtime
	}
	if len(s.NativeNotifications) > 8 {
		s.NativeNotifications = s.NativeNotifications[len(s.NativeNotifications)-8:]
	}
	for _, notice := range s.NativeNotifications {
		notice["summary"] = clip(str(notice["summary"]), 1200)
	}
}
func cardItem(turn *Turn) map[string]any {
	unfinished := map[string]bool{}
	for _, item := range turn.Timeline {
		if str(item["kind"]) == "assistant" && str(item["messageId"]) != "" && str(item["status"]) != "complete" {
			unfinished[str(item["messageId"])] = true
		}
	}
	// Prefer an assistant reply over a later reasoning segment. Failed and
	// cancelled assistant bodies remain the user-visible terminal preview.
	for i := len(turn.Timeline) - 1; i >= 0; i-- {
		item := turn.Timeline[i]
		if str(item["kind"]) != "assistant" {
			continue
		}
		status := str(item["status"])
		allowed := status == "complete" && !unfinished[str(item["messageId"])] || status == "failed" || status == "cancelled"
		if allowed && strings.TrimSpace(str(item["content"])) != "" {
			return item
		}
	}
	for i := len(turn.Timeline) - 1; i >= 0; i-- {
		item := turn.Timeline[i]
		if str(item["kind"]) == "reasoning" && (turn.Status == "running" || turn.Status == "completed") && strings.TrimSpace(str(item["content"])) != "" {
			return item
		}
	}
	return nil
}
func replyItem(turn *Turn) map[string]any {
	if turn.Status != "completed" {
		return nil
	}
	for i := len(turn.Timeline) - 1; i >= 0; i-- {
		item := turn.Timeline[i]
		if str(item["kind"]) == "assistant" && strings.TrimSpace(str(item["content"])) != "" {
			return item
		}
	}
	return nil
}
func compactRenderer(s *State, scope model.RendererScope, initialResponseScope bool) (json.RawMessage, error) {
	overview := scope.Kind == "overview"
	current := s.Current()
	preview := map[*Turn]bool{}
	if current != nil {
		preview[current] = true
	}
	for i := len(s.Turns) - 1; i >= 0; i-- {
		turn := s.Turns[i]
		if cardItem(turn) != nil || turn.Status == "completed" && (timelineHasText(turn.Timeline, "assistant") || timelineHasText(turn.Timeline, "reasoning")) {
			preview[turn] = true
			break
		}
	}
	for i := len(s.Turns) - 1; i >= 0; i-- {
		turn := s.Turns[i]
		if replyItem(turn) != nil {
			preview[turn] = true
			break
		}
	}
	for _, turn := range s.Turns {
		compactTurn(turn, scope.Kind == "thread" || preview[turn], overview && turn == current, overview)
	}
	if s.ForkHistory != nil {
		history := s.ForkHistory
		items := arr(history["items"])
		projected := []any{}
		if overview {
			for i := len(items) - 1; i >= 0; i-- {
				item := obj(items[i])
				kind := str(item["kind"])
				var field string
				switch kind {
				case "user-message", "diff", "review":
					field = "content"
				case "assistant":
					if str(item["status"]) == "complete" {
						field = "content"
					}
				case "error":
					field = "message"
				case "notice":
					if strings.TrimSpace(str(obj(item["notice"])["message"])) != "" {
						notice := cloneObject(obj(item["notice"]))
						notice["message"] = clip(str(notice["message"]), 1200)
						item["notice"] = notice
						projected = append(projected, item)
					}
				}
				if field != "" && strings.TrimSpace(str(item[field])) != "" {
					item[field] = clip(str(item[field]), 1200)
					projected = append(projected, item)
				}
				if len(projected) > 0 {
					break
				}
			}
		}
		if len(projected) == 0 && len(items) > 0 {
			first := obj(items[0])
			projected = append(projected, map[string]any{"id": first["id"], "createdAt": first["createdAt"], "kind": "context-compaction"})
		}
		s.ForkHistory = map[string]any{"sourceSessionId": history["sourceSessionId"], "items": projected}
	}
	if overview {
		return json.Marshal(struct {
			*State
			InitialResponseScope bool `json:"initialResponseScope"`
		}{s, initialResponseScope})
	}
	return s.Encode()
}
func compactTurn(t *Turn, preview, current, overview bool) {
	originalTimeline := t.Timeline
	card, reply := cardItem(t), replyItem(t)
	visible := []string{}
	first, last := -1, -1
	for index, prompt := range t.Prompts {
		if intContains(t.InternalPromptIndexes, index) {
			continue
		}
		if first < 0 {
			first = index
		}
		last = index
		if preview {
			visible = append(visible, prompt)
		}
	}
	prompts := []string{}
	if overview && current {
		for index, prompt := range t.Prompts {
			if index == first || index == last {
				prompts = append(prompts, clip(prompt, 600))
			} else {
				prompts = append(prompts, "")
			}
		}
	} else {
		if len(visible) > 1 {
			visible = []string{visible[0], visible[len(visible)-1]}
		}
		for _, prompt := range visible {
			prompts = append(prompts, clip(prompt, 600))
		}
		t.InternalPromptIndexes = nil
	}
	t.Prompts = prompts
	t.PromptAttachments = make([][]map[string]any, len(prompts))
	for index := range t.PromptAttachments {
		t.PromptAttachments[index] = []map[string]any{}
	}
	t.Timeline = []map[string]any{}
	if overview && preview {
		for _, item := range originalTimeline {
			selected := card != nil && str(item["id"]) == str(card["id"]) || reply != nil && str(item["id"]) == str(reply["id"])
			if !selected {
				continue
			}
			item["content"] = overviewTimelineText(item, originalTimeline, 1200)
			t.Timeline = append(t.Timeline, item)
		}
	} else if overview {
		// Catalog Overview keeps a bounded assistant/reasoning item so exact
		// historical execution previews still derive from the timeline rather
		// than a second aggregate body.
		if item := overviewItem(card, reply); item != nil {
			copy := cloneObject(item)
			copy["content"] = overviewTimelineText(item, originalTimeline, 600)
			t.Timeline = append(t.Timeline, copy)
		}
	} else if preview {
		// Thread manifests retain one bounded assistant reply per execution for
		// the history sidebar and execution summary. They never retain entity
		// references whose tables are compacted below.
		if item := latestAssistantItem(originalTimeline); item != nil {
			copy := cloneObject(item)
			copy["content"] = overviewTimelineText(item, originalTimeline, 600)
			t.Timeline = append(t.Timeline, copy)
		}
	}
	if preview {
		t.Error = clip(t.Error, 1200)
	} else {
		t.Error = ""
	}
	t.Notices = []map[string]any{}
	t.PlanExplanation = ""
	t.StatusLabel = clip(t.StatusLabel, 1200)
	if current {
		if len(t.Plan) > 32 {
			t.Plan = t.Plan[:32]
		}
		for _, step := range t.Plan {
			step["step"] = clip(str(step["step"]), 600)
		}
		if len(t.Activities) > 32 {
			t.Activities = t.Activities[len(t.Activities)-32:]
		}
		for index, activity := range t.Activities {
			projection := map[string]any{"id": activity["id"], "kind": activity["kind"], "label": clip(str(activity["label"]), 1200), "status": activity["status"]}
			if name := str(activity["toolName"]); name != "" {
				projection["toolName"] = name
			}
			if str(activity["kind"]) == "agent" && str(activity["label"]) == "Workflow" {
				if detail := workflowDetail(str(activity["detail"])); detail != "" {
					projection["detail"] = detail
				}
			}
			t.Activities[index] = projection
		}
		pending := []map[string]any{}
		for _, interaction := range t.Interactions {
			if str(interaction["status"]) == "pending" {
				pending = append(pending, compactInteraction(interaction))
			}
		}
		t.Interactions = pending
		if str(t.Foreground["kind"]) == "reasoning" {
			points := []rune(str(t.Foreground["text"]))
			if len(points) > 1200 {
				offset := number(t.Foreground["textOffset"])
				for _, r := range points[:len(points)-1200] {
					offset++
					if r > 0xffff {
						offset++
					}
				}
				t.Foreground["text"] = string(points[len(points)-1200:])
				t.Foreground["textOffset"] = offset
			}
		}
	} else {
		t.Plan = []map[string]any{}
		t.Activities = []map[string]any{}
		t.Interactions = []map[string]any{}
		t.Foreground = nil
	}
}
func overviewItem(card, reply map[string]any) map[string]any {
	if card != nil {
		return card
	}
	return reply
}

func latestAssistantItem(timeline []map[string]any) map[string]any {
	for index := len(timeline) - 1; index >= 0; index-- {
		item := timeline[index]
		if str(item["kind"]) == "assistant" && strings.TrimSpace(str(item["content"])) != "" {
			return item
		}
	}
	return nil
}

func overviewTimelineText(item map[string]any, original []map[string]any, limit int) string {
	var text strings.Builder
	remaining := limit
	if str(item["kind"]) == "assistant" && str(item["messageId"]) != "" {
		for _, segment := range original {
			if str(segment["kind"]) == "assistant" && str(segment["messageId"]) == str(item["messageId"]) {
				appendBoundedText(&text, str(segment["content"]), &remaining)
				if remaining == 0 {
					break
				}
			}
		}
	} else {
		appendBoundedText(&text, str(item["content"]), &remaining)
	}
	return clip(strings.TrimSpace(text.String()), limit)
}

func compactInteraction(interaction map[string]any) map[string]any {
	copy := cloneObject(interaction)
	if schema := copy["schema"]; schema != nil {
		// Pending action/schema data remains actionable. The display spelling is
		// also the native matcher's evidence for the public question.
		copy["schemaDisplay"] = displayJSON(schema)
	}
	if str(copy["kind"]) == "permission" {
		if input := obj(copy["input"]); input != nil {
			selected := map[string]any{}
			for _, key := range []string{"command", "file_path", "notebook_path", "path", "url", "pattern", "query", "prompt"} {
				if value, ok := input[key].(string); ok {
					selected[key] = clip(strings.TrimSpace(value), 1000)
				}
			}
			copy["input"] = selected
			copy["inputDisplay"] = displayJSON(selected)
		}
	}
	return copy
}
