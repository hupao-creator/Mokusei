package codex

import (
	"encoding/json"
	"strings"

	"github.com/hupao-creator/Mokusei/internal/core/model"
)

func codexExecutionID(id string) string { return strings.TrimPrefix(id, "turn:") }

// Timeline rows are the stable reader identities. A tool group row expands to
// its contiguous native activity block so selecting one tool never serializes
// sibling tools outside that block.
func (sessionStateAdapter) ProjectDetail(raw json.RawMessage, request model.DetailRequest) (model.DetailProjection, error) {
	state, err := stDecodeRaw(raw)
	if err != nil {
		return model.DetailProjection{}, err
	}
	executionID := codexExecutionID(request.ExecutionID)
	turn := stFindTurn(stArray(state["turns"]), executionID)
	if turn == nil {
		turn = stFindTurn(stArray(state["forkHistory"]), executionID)
	}
	projection := model.DetailProjection{ExecutionID: request.ExecutionID, Items: []model.DetailItem{}}
	if turn == nil {
		return projection, nil
	}
	selected := make(map[string]bool, len(request.Items))
	for _, id := range request.Items {
		selected[id] = true
	}
	timeline := stArray(turn["timeline"])
	include := make([]bool, len(timeline))
	for index, value := range timeline {
		item := stMap(value)
		if !selected[stString(item["id"])] {
			continue
		}
		include[index] = true
		if item["kind"] == "activity" {
			for previous := index - 1; previous >= 0 && stMap(timeline[previous])["kind"] == "activity"; previous-- {
				include[previous] = true
			}
			for next := index + 1; next < len(timeline) && stMap(timeline[next])["kind"] == "activity"; next++ {
				include[next] = true
			}
		}
	}
	seen := map[string]bool{}
	seenActivity := map[string]bool{}
	for index, value := range timeline {
		if !include[index] {
			continue
		}
		item := stMap(value)
		if stString(item["kind"]) == "activity" {
			activityID := stString(item["activityId"])
			if seenActivity[activityID] {
				continue
			}
			seenActivity[activityID] = true
		}
		if detail, ok := codexDetailItem(turn, item, false); ok && !seen[detail.ID] {
			seen[detail.ID] = true
			projection.Items = append(projection.Items, detail)
		}
	}
	for _, id := range request.Items {
		if seen[id] {
			continue
		}
		for _, detail := range codexSyntheticDetails(turn, executionID, id, false) {
			if !seen[detail.ID] {
				seen[detail.ID] = true
				projection.Items = append(projection.Items, detail)
			}
		}
	}
	return projection, nil
}

func (sessionStateAdapter) ReadDetailBody(raw json.RawMessage, request model.DetailBodyRequest) (model.DetailBody, error) {
	state, err := stDecodeRaw(raw)
	if err != nil {
		return model.DetailBody{}, err
	}
	executionID := codexExecutionID(request.ExecutionID)
	turn := stFindTurn(stArray(state["turns"]), executionID)
	if turn == nil {
		turn = stFindTurn(stArray(state["forkHistory"]), executionID)
	}
	if turn == nil {
		return model.DetailBody{}, model.NewError("DETAIL_NOT_FOUND", "This reader detail is no longer available")
	}
	for _, value := range stArray(turn["timeline"]) {
		item := stMap(value)
		if stString(item["id"]) != request.ItemID {
			continue
		}
		detail, ok := codexDetailItem(turn, item, true)
		if !ok {
			break
		}
		for _, body := range detail.Bodies {
			if body.Slot == request.Slot {
				return body, nil
			}
		}
	}
	for _, detail := range codexSyntheticDetails(turn, executionID, request.ItemID, true) {
		for _, body := range detail.Bodies {
			if body.Slot == request.Slot {
				return body, nil
			}
		}
	}
	return model.DetailBody{}, model.NewError("DETAIL_NOT_FOUND", "This reader detail is no longer available")
}

func codexDetailItem(turn Map, item Map, includeText bool) (model.DetailItem, bool) {
	id := stString(item["id"])
	kind := stString(item["kind"])
	result := model.DetailItem{ID: id, Kind: kind, Status: stString(item["status"])}
	switch kind {
	case "reasoning":
		result.Kind = "reasoning"
		result.Bodies = codexBody(result.Bodies, "content", "", model.DetailBodyMarkdown, stString(item["content"]), includeText)
	case "assistant":
		result.Kind = "message"
		result.Bodies = codexBody(result.Bodies, "content", "", model.DetailBodyMarkdown, stString(item["content"]), includeText)
	case "user-message":
		result.Kind = "message"
		messageID := stString(item["messageId"])
		for _, value := range stArray(turn["messages"]) {
			message := stMap(value)
			if stString(message["id"]) == messageID {
				result.Bodies = codexBody(result.Bodies, "content", "", model.DetailBodyMarkdown, stString(message["content"]), includeText)
				break
			}
		}
	case "activity":
		activity := codexCanonicalActivity(turn, stString(item["activityId"]))
		if activity == nil {
			return model.DetailItem{}, false
		}
		result.Kind = "activity"
		result.Label = stHead(stString(activity["label"]), 1200)
		result.Status = stString(activity["status"])
		result.ToolName = stString(activity["toolName"])
		result.Bodies = codexBody(result.Bodies, "detail", "", model.DetailBodyText, stString(activity["detail"]), includeText)
	case "error":
		result.Kind = "error"
		result.Bodies = codexBody(result.Bodies, "detail", "", model.DetailBodyText, stString(turn["error"]), includeText)
	case "notice":
		result.Kind = "notice"
		noticeID := stString(item["noticeId"])
		for _, value := range stArray(turn["notices"]) {
			notice := stMap(value)
			if stString(notice["id"]) == noticeID {
				result.Bodies = codexBody(result.Bodies, "detail", "", model.DetailBodyText, stString(notice["message"]), includeText)
				break
			}
		}
	case "review":
		result.Kind = "review"
		result.Bodies = codexBody(result.Bodies, "detail", "", model.DetailBodyMarkdown, stString(turn["review"]), includeText)
	case "context-compaction":
		result.Kind = "context"
	case "interaction":
		result.Kind = "interaction"
	default:
		return model.DetailItem{}, false
	}
	if result.Kind == "" {
		return model.DetailItem{}, false
	}
	return result, true
}

func codexCanonicalActivity(turn Map, activityID string) Map {
	for _, value := range stArray(turn["activities"]) {
		activity := stMap(value)
		if stString(activity["id"]) == activityID {
			return activity
		}
	}
	return nil
}

func codexSyntheticDetails(turn Map, executionID, id string, includeText bool) []model.DetailItem {
	prefix := executionID + ":"
	item := model.DetailItem{ID: id}
	switch {
	case strings.HasPrefix(id, prefix+"activity:"):
		activityID := strings.TrimPrefix(id, prefix+"activity:")
		activity := codexCanonicalActivity(turn, activityID)
		if activity == nil {
			return nil
		}
		item.Kind = "activity"
		item.Label = stHead(stString(activity["label"]), 1200)
		item.Status = stString(activity["status"])
		item.ToolName = stString(activity["toolName"])
		item.Bodies = codexBody(item.Bodies, "detail", "", model.DetailBodyText, stString(activity["detail"]), includeText)
		return []model.DetailItem{item}
	case strings.HasPrefix(id, prefix+"notice:"):
		noticeID := strings.TrimPrefix(id, prefix+"notice:")
		for _, value := range stArray(turn["notices"]) {
			notice := stMap(value)
			if stString(notice["id"]) != noticeID {
				continue
			}
			item.Kind = "notice"
			item.Bodies = codexBody(item.Bodies, "detail", "", model.DetailBodyText, stString(notice["message"]), includeText)
			return []model.DetailItem{item}
		}
	case id == prefix+"error":
		item.Kind = "error"
		item.Bodies = codexBody(item.Bodies, "detail", "", model.DetailBodyText, stString(turn["error"]), includeText)
		return []model.DetailItem{item}
	}
	return nil
}

func codexBody(bodies []model.DetailBody, slot, label, format, text string, includeText bool) []model.DetailBody {
	if strings.TrimSpace(text) == "" {
		return bodies
	}
	body := model.DetailBody{Slot: slot, Label: label, Format: format, Length: len(text)}
	if includeText {
		body.Text = text
	}
	return append(bodies, body)
}
