package claude

import (
	"encoding/json"
	"strconv"
	"strings"

	"github.com/hupao-creator/Mokusei/internal/core/model"
)

func (StateAdapter) ProjectDetail(raw json.RawMessage, request model.DetailRequest) (model.DetailProjection, error) {
	state, err := ParseState(raw)
	if err != nil {
		return model.DetailProjection{}, err
	}
	projection := model.DetailProjection{ExecutionID: request.ExecutionID, Items: []model.DetailItem{}}
	selected := make(map[string]bool, len(request.Items))
	for _, id := range request.Items {
		selected[id] = true
	}
	var timeline []map[string]any
	var turn *Turn
	if request.ExecutionID == "fork-history" {
		if state.ForkHistory != nil {
			for _, value := range arr(state.ForkHistory["items"]) {
				timeline = append(timeline, obj(value))
			}
		}
	} else {
		turn = state.Find(request.ExecutionID)
		if turn != nil {
			timeline = turn.Timeline
		}
	}
	include := make([]bool, len(timeline))
	for index, item := range timeline {
		if !selected[str(item["id"])] {
			continue
		}
		include[index] = true
		if str(item["kind"]) == "activity" {
			for previous := index - 1; previous >= 0 && str(timeline[previous]["kind"]) == "activity"; previous-- {
				include[previous] = true
			}
			for next := index + 1; next < len(timeline) && str(timeline[next]["kind"]) == "activity"; next++ {
				include[next] = true
			}
		}
	}
	seen := map[string]bool{}
	seenActivity := map[string]bool{}
	for index, item := range timeline {
		if !include[index] {
			continue
		}
		if str(item["kind"]) == "activity" {
			activityID := claudeActivityID(item, turn)
			if seenActivity[activityID] {
				continue
			}
			seenActivity[activityID] = true
		}
		if detail, ok := claudeDetailItem(item, turn, false); ok && !seen[detail.ID] {
			seen[detail.ID] = true
			projection.Items = append(projection.Items, detail)
		}
	}
	if turn != nil {
		for _, id := range request.Items {
			if seen[id] {
				continue
			}
			for _, detail := range claudeSyntheticDetails(turn, id, false) {
				if !seen[detail.ID] {
					seen[detail.ID] = true
					projection.Items = append(projection.Items, detail)
				}
			}
		}
	}
	return projection, nil
}

func (StateAdapter) ReadDetailBody(raw json.RawMessage, request model.DetailBodyRequest) (model.DetailBody, error) {
	state, err := ParseState(raw)
	if err != nil {
		return model.DetailBody{}, err
	}
	if request.ExecutionID == "fork-history" {
		if state.ForkHistory != nil {
			for _, value := range arr(state.ForkHistory["items"]) {
				item := obj(value)
				if str(item["id"]) != request.ItemID {
					continue
				}
				return claudeDetailBody(item, nil, request.Slot, true)
			}
		}
	} else if turn := state.Find(request.ExecutionID); turn != nil {
		for _, item := range turn.Timeline {
			if str(item["id"]) != request.ItemID {
				continue
			}
			return claudeDetailBody(item, turn, request.Slot, true)
		}
		for _, detail := range claudeSyntheticDetails(turn, request.ItemID, true) {
			for _, body := range detail.Bodies {
				if body.Slot == request.Slot {
					return body, nil
				}
			}
		}
	}
	return model.DetailBody{}, model.NewError("DETAIL_NOT_FOUND", "This reader detail is no longer available")
}

func claudeDetailBody(item map[string]any, turn *Turn, slot string, includeText bool) (model.DetailBody, error) {
	detail, ok := claudeDetailItem(item, turn, includeText)
	if !ok {
		return model.DetailBody{}, model.NewError("DETAIL_NOT_FOUND", "This reader detail is no longer available")
	}
	for _, body := range detail.Bodies {
		if body.Slot == slot {
			return body, nil
		}
	}
	return model.DetailBody{}, model.NewError("DETAIL_NOT_FOUND", "This reader detail is no longer available")
}

func claudeCanonicalActivity(turn *Turn, activity map[string]any) map[string]any {
	if turn == nil {
		return activity
	}
	id := str(activity["id"])
	if id == "" {
		return activity
	}
	for _, candidate := range turn.Activities {
		if str(candidate["id"]) == id {
			return candidate
		}
	}
	return activity
}

func claudeActivityID(item map[string]any, turn *Turn) string {
	activity := claudeCanonicalActivity(turn, obj(item["activity"]))
	if id := str(activity["id"]); id != "" {
		return id
	}
	return str(item["id"])
}

func claudeDetailItem(item map[string]any, turn *Turn, includeText bool) (model.DetailItem, bool) {
	id, kind := str(item["id"]), str(item["kind"])
	result := model.DetailItem{ID: id, Kind: kind, Status: str(item["status"])}
	switch kind {
	case "reasoning":
		result.Kind = "reasoning"
		result.Bodies = claudeBody(result.Bodies, "content", model.DetailBodyMarkdown, str(item["content"]), includeText)
	case "assistant":
		result.Kind = "message"
		result.Bodies = claudeBody(result.Bodies, "content", model.DetailBodyMarkdown, str(item["content"]), includeText)
	case "user-message":
		result.Kind = "message"
		text := str(item["content"])
		if text == "" && turn != nil {
			index := int(number(item["promptIndex"]))
			if index >= 0 && index < len(turn.Prompts) {
				text = turn.Prompts[index]
			}
		}
		result.Bodies = claudeBody(result.Bodies, "content", model.DetailBodyMarkdown, text, includeText)
	case "activity":
		activity := claudeCanonicalActivity(turn, obj(item["activity"]))
		result.Kind = "activity"
		result.Label = clip(str(activity["label"]), 1200)
		result.Status = str(activity["status"])
		result.ToolName = str(activity["toolName"])
		result.Bodies = claudeBody(result.Bodies, "detail", model.DetailBodyText, str(activity["detail"]), includeText)
	case "interaction":
		interaction := obj(item["interaction"])
		result.Kind = "interaction"
		result.Label = clip(str(interaction["title"]), 1200)
		result.Status = str(interaction["status"])
		result.Bodies = claudeBody(result.Bodies, "detail", model.DetailBodyText, str(interaction["description"]), includeText)
	case "notice":
		notice := obj(item["notice"])
		result.Kind = "notice"
		result.Status = str(notice["level"])
		result.Bodies = claudeBody(result.Bodies, "detail", model.DetailBodyText, str(notice["message"]), includeText)
	case "review":
		result.Kind = "review"
		result.Bodies = claudeBody(result.Bodies, "detail", model.DetailBodyMarkdown, str(item["content"]), includeText)
	case "error":
		result.Kind = "error"
		result.Bodies = claudeBody(result.Bodies, "detail", model.DetailBodyText, str(item["message"]), includeText)
	case "context-compaction":
		result.Kind = "context"
	default:
		return model.DetailItem{}, false
	}
	return result, true
}

func claudeSyntheticDetails(turn *Turn, id string, includeText bool) []model.DetailItem {
	prefix := turn.ExecutionID + ":unreferenced:"
	if !strings.HasPrefix(id, prefix) {
		return nil
	}
	suffix := strings.TrimPrefix(id, prefix)
	item := model.DetailItem{ID: id}
	switch {
	case suffix == "reasoning":
		item.Kind, item.Bodies = "reasoning", claudeBody(item.Bodies, "content", model.DetailBodyMarkdown, turn.Reasoning, includeText)
	case suffix == "assistant":
		item.Kind, item.Bodies = "message", claudeBody(item.Bodies, "content", model.DetailBodyMarkdown, turn.Text, includeText)
	case suffix == "error":
		item.Kind, item.Bodies = "error", claudeBody(item.Bodies, "detail", model.DetailBodyText, turn.Error, includeText)
	case suffix == "review":
		item.Kind, item.Bodies = "review", claudeBody(item.Bodies, "detail", model.DetailBodyMarkdown, turn.Review, includeText)
	case suffix == "context-compaction":
		item.Kind = "context"
	case suffix == "activities":
		return claudeUnreferencedActivities(turn, prefix, includeText)
	case strings.HasPrefix(suffix, "prompt:"):
		index, err := strconv.Atoi(strings.TrimPrefix(suffix, "prompt:"))
		if err != nil || index < 0 || index >= len(turn.Prompts) {
			return nil
		}
		item.Kind, item.Bodies = "message", claudeBody(item.Bodies, "content", model.DetailBodyMarkdown, turn.Prompts[index], includeText)
	case strings.HasPrefix(suffix, "activity:"):
		activityID := strings.TrimPrefix(suffix, "activity:")
		for _, activity := range turn.Activities {
			if str(activity["id"]) != activityID {
				continue
			}
			item.Kind = "activity"
			item.Label = clip(str(activity["label"]), 1200)
			item.Status = str(activity["status"])
			item.ToolName = str(activity["toolName"])
			item.Bodies = claudeBody(item.Bodies, "detail", model.DetailBodyText, str(activity["detail"]), includeText)
			return []model.DetailItem{item}
		}
		return nil
	case strings.HasPrefix(suffix, "interaction:"):
		interactionID := strings.TrimPrefix(suffix, "interaction:")
		for _, interaction := range turn.Interactions {
			if str(interaction["id"]) != interactionID {
				continue
			}
			item.Kind, item.Label, item.Status = "interaction", clip(str(interaction["title"]), 1200), str(interaction["status"])
			item.Bodies = claudeBody(item.Bodies, "detail", model.DetailBodyText, str(interaction["description"]), includeText)
			return []model.DetailItem{item}
		}
		return nil
	case strings.HasPrefix(suffix, "notice:"):
		noticeID := strings.TrimPrefix(suffix, "notice:")
		for _, notice := range turn.Notices {
			if str(notice["id"]) != noticeID {
				continue
			}
			item.Kind, item.Status = "notice", str(notice["level"])
			item.Bodies = claudeBody(item.Bodies, "detail", model.DetailBodyText, str(notice["message"]), includeText)
			return []model.DetailItem{item}
		}
		return nil
	default:
		return nil
	}
	return []model.DetailItem{item}
}

func claudeUnreferencedActivities(turn *Turn, prefix string, includeText bool) []model.DetailItem {
	referenced := map[string]bool{}
	for _, item := range turn.Timeline {
		if str(item["kind"]) == "activity" {
			referenced[claudeActivityID(item, turn)] = true
		}
	}
	result := []model.DetailItem{}
	for _, activity := range turn.Activities {
		id := str(activity["id"])
		if id == "" || referenced[id] {
			continue
		}
		result = append(result, model.DetailItem{ID: prefix + "activity:" + id, Kind: "activity",
			Label: clip(str(activity["label"]), 1200), Status: str(activity["status"]), ToolName: str(activity["toolName"]),
			Bodies: claudeBody(nil, "detail", model.DetailBodyText, str(activity["detail"]), includeText)})
	}
	return result
}

func claudeBody(bodies []model.DetailBody, slot, format, text string, includeText bool) []model.DetailBody {
	if strings.TrimSpace(text) == "" {
		return bodies
	}
	body := model.DetailBody{Slot: slot, Format: format, Length: len(text)}
	if includeText {
		body.Text = text
	}
	return append(bodies, body)
}
