package claude

import (
	"encoding/json"
	"strings"

	"github.com/hupao-creator/Mokusei/internal/core/model"
)

// agentReadingRenderer keeps only what the count-only Agent page displays.
// Reply, error, follow-up and interaction identities stay in native order;
// tool/reasoning bodies are represented by presence facts for summary counts.
func agentReadingRenderer(s *State, scope model.RendererScope) (json.RawMessage, error) {
	var target map[string]any
	if len(scope.Target) > 0 {
		_ = json.Unmarshal(scope.Target, &target)
	}
	presence := []map[string]string{}
	s.PendingFork = nil
	s.GoalPromptPending = false
	s.NativeNotifications = []map[string]any{}
	compactRuntime(s)

	if scope.Key == "fork-history" && s.ForkHistory != nil {
		sourceSessionID := s.ForkHistory["sourceSessionId"]
		checkpointID := s.ForkHistory["checkpointId"]
		s.Turns = []*Turn{}
		items := arr(s.ForkHistory["items"])
		trimmed := make([]any, 0, len(items))
		segmentFinal := map[int]int{}
		segment := 0
		for index, value := range items {
			item := obj(value)
			if str(item["kind"]) == "user-message" {
				segment++
			}
			if str(item["kind"]) == "assistant" && str(item["status"]) == "complete" && strings.TrimSpace(str(item["content"])) != "" {
				segmentFinal[segment] = index
			}
		}
		segment = 0
		for index, value := range items {
			item := obj(value)
			switch str(item["kind"]) {
			case "user-message":
				segment++
				item["content"] = ""
				item["attachments"] = []any{}
			case "assistant":
				failed := str(item["status"]) == "failed"
				targeted := target != nil && str(target["messageId"]) == str(item["messageId"])
				if !failed && !targeted && segmentFinal[segment] != index {
					continue
				}
			case "reasoning":
				if strings.TrimSpace(str(item["content"])) != "" {
					presence = append(presence, map[string]string{"id": str(item["id"]), "field": "content"})
				}
				item["content"] = ""
			case "activity":
				hideReadingActivity(obj(item["activity"]), str(item["id"]), &presence)
			case "interaction":
				continue
			case "notice":
				notice := obj(item["notice"])
				if str(notice["level"]) != "error" {
					continue
				}
			case "plan", "usage", "diff":
				continue
			}
			trimmed = append(trimmed, item)
		}
		s.ForkHistory = map[string]any{"sourceSessionId": sourceSessionID, "items": trimmed}
		if checkpointID != nil {
			s.ForkHistory["checkpointId"] = checkpointID
		}
		return json.Marshal(map[string]any{"kind": "deferred-execution", "state": s, "nonempty": presence})
	}

	selected := []*Turn{}
	for _, turn := range s.Turns {
		if turn.ExecutionID == scope.Key {
			selected = append(selected, turn)
		}
	}
	s.Turns = selected
	s.ForkHistory = nil
	for _, turn := range selected {
		trimReadingTurn(turn, target, &presence)
	}
	return json.Marshal(map[string]any{"kind": "deferred-execution", "state": s, "nonempty": presence})
}

func trimReadingTurn(turn *Turn, target map[string]any, presence *[]map[string]string) {
	active := turn.Status == "running"
	finalID := ""
	for i := len(turn.Timeline) - 1; i >= 0; i-- {
		item := turn.Timeline[i]
		if str(item["kind"]) == "assistant" && str(item["status"]) != "streaming" && str(item["status"]) != "failed" && strings.TrimSpace(str(item["content"])) != "" {
			finalID = str(item["id"])
			break
		}
	}
	targetMessageID := ""
	if target != nil {
		targetMessageID = str(target["messageId"])
	}

	followUps := map[int]bool{}
	for index := range turn.Prompts {
		internal := intContains(turn.InternalPromptIndexes, index)
		if index > 0 && !internal {
			followUps[index] = true
		} else {
			turn.Prompts[index] = ""
			turn.PromptAttachments[index] = []map[string]any{}
		}
	}
	timeline := []map[string]any{}
	for _, item := range turn.Timeline {
		switch str(item["kind"]) {
		case "user-message":
			if !followUps[int(number(item["promptIndex"]))] {
				continue
			}
		case "assistant":
			failed := str(item["status"]) == "failed"
			targeted := targetMessageID != "" && str(item["messageId"]) == targetMessageID
			visible := failed || targeted
			if active {
				visible = visible || str(item["status"]) != "streaming" && strings.TrimSpace(str(item["content"])) != ""
			} else {
				visible = visible || str(item["id"]) == finalID
			}
			if !visible {
				continue
			}
		case "reasoning":
			if strings.TrimSpace(str(item["content"])) != "" {
				*presence = append(*presence, map[string]string{"id": str(item["id"]), "field": "content"})
			}
			item["content"] = ""
		case "activity":
			hideReadingActivity(obj(item["activity"]), str(item["id"]), presence)
		case "interaction":
			interaction := obj(item["interaction"])
			if str(interaction["status"]) != "pending" {
				continue
			}
		case "notice":
			notice := obj(item["notice"])
			if str(notice["level"]) != "error" {
				continue
			}
		case "plan", "usage", "diff":
			continue
		}
		timeline = append(timeline, item)
	}
	turn.Timeline = timeline

	activities := []map[string]any{}
	for _, activity := range turn.Activities {
		hideReadingActivity(activity, str(activity["id"]), presence)
		activities = append(activities, activity)
	}
	turn.Activities = activities

	interactions := []map[string]any{}
	for _, interaction := range turn.Interactions {
		if str(interaction["status"]) == "pending" {
			for _, field := range []string{"input", "schema"} {
				if value, exists := interaction[field]; exists {
					interaction[field+"Display"] = displayJSON(value)
				}
			}
			interactions = append(interactions, interaction)
		}
	}
	turn.Interactions = interactions

	notices := []map[string]any{}
	for _, notice := range turn.Notices {
		if str(notice["level"]) == "error" {
			notices = append(notices, notice)
		}
	}
	turn.Notices = notices

	turn.Text = ""
	turn.Reasoning = ""
	turn.Foreground = nil
	turn.Plan = []map[string]any{}
	turn.PlanExplanation = ""
	turn.Diff = ""
	turn.LastAssistantMessage = nil
}

func hideReadingActivity(activity map[string]any, presenceID string, presence *[]map[string]string) {
	if strings.TrimSpace(str(activity["detail"])) != "" {
		*presence = append(*presence, map[string]string{"id": presenceID, "field": "detail"})
	}
	delete(activity, "detail")
	delete(activity, "parentId")
	delete(activity, "taskId")
	activity["label"] = ""
}
