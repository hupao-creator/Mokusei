package pi

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"strings"

	"github.com/hupao-creator/Mokusei/internal/core/model"
)

// Native Pi identities reject NUL, so these NUL-prefixed namespaces cannot
// collide with a real message id such as "foo:thinking". The transport bounds
// every selected identity to 256 UTF-16 units, so an overlong native id uses a
// namespaced digest instead of the raw value. The Swift full reader derives the
// same identities from the same message ids.
const (
	piMessagePrefix  = "\x00pi:message:"
	piThinkingPrefix = "\x00pi:thinking:"
)

func piDigest(id string) string {
	sum := sha256.Sum256([]byte(id))
	return hex.EncodeToString(sum[:])
}

func piMessageRowID(id string) string {
	if utf16Length(id) <= model.MaximumContentIdentityUnits {
		return id
	}
	return piMessagePrefix + piDigest(id)
}

func piThinkingID(messageID string) string {
	identity := piThinkingPrefix + messageID
	if utf16Length(identity) <= model.MaximumContentIdentityUnits {
		return identity
	}
	return piThinkingPrefix + piDigest(messageID)
}

func (stateAdapter) ProjectDetail(raw json.RawMessage, request model.DetailRequest) (model.DetailProjection, error) {
	state, err := decodeState(raw)
	if err != nil {
		return model.DetailProjection{}, err
	}
	projection := model.DetailProjection{ExecutionID: request.ExecutionID, Items: []model.DetailItem{}}
	selected := make(map[string]bool, len(request.Items))
	for _, id := range request.Items {
		selected[id] = true
	}
	for _, row := range state.Messages {
		if row.ExecutionID != request.ExecutionID {
			continue
		}
		if selected[piThinkingID(row.ID)] {
			if item, ok := piThinkingDetail(row, false); ok {
				projection.Items = append(projection.Items, item)
			}
		}
		if selected[piMessageRowID(row.ID)] {
			item := piMessageDetail(row, false)
			item.ID = piMessageRowID(row.ID)
			projection.Items = append(projection.Items, item)
		}
	}
	return projection, nil
}

func (stateAdapter) ReadDetailBody(raw json.RawMessage, request model.DetailBodyRequest) (model.DetailBody, error) {
	state, err := decodeState(raw)
	if err != nil {
		return model.DetailBody{}, err
	}
	thinking := strings.HasPrefix(request.ItemID, piThinkingPrefix)
	for _, row := range state.Messages {
		if row.ExecutionID != request.ExecutionID {
			continue
		}
		if thinking {
			if piThinkingID(row.ID) != request.ItemID {
				continue
			}
			item, ok := piThinkingDetail(row, true)
			if !ok {
				break
			}
			return detailBody(item, request.Slot)
		}
		if piMessageRowID(row.ID) != request.ItemID {
			continue
		}
		return detailBody(piMessageDetail(row, true), request.Slot)
	}
	return model.DetailBody{}, model.NewError("DETAIL_NOT_FOUND", "This reader detail is no longer available")
}

func piMessageDetail(row MessageState, includeText bool) model.DetailItem {
	kind, format := "message", model.DetailBodyMarkdown
	if row.Role == "tool" {
		kind, format = "activity", model.DetailBodyText
	}
	item := model.DetailItem{ID: row.ID, Kind: kind, Status: row.Status, ToolName: row.ToolName}
	if strings.TrimSpace(row.Text) != "" {
		item.Bodies = append(item.Bodies, detailBodyValue("text", format, row.Text, includeText))
	}
	return item
}

func piThinkingDetail(row MessageState, includeText bool) (model.DetailItem, bool) {
	if row.Role != "assistant" || strings.TrimSpace(row.Thinking) == "" {
		return model.DetailItem{}, false
	}
	return model.DetailItem{ID: piThinkingID(row.ID), Kind: "reasoning", Status: row.Status,
		Bodies: []model.DetailBody{detailBodyValue("thinking", model.DetailBodyMarkdown, row.Thinking, includeText)}}, true
}

func detailBodyValue(slot, format, text string, includeText bool) model.DetailBody {
	body := model.DetailBody{Slot: slot, Format: format, Length: len(text)}
	if includeText {
		body.Text = text
	}
	return body
}

func detailBody(item model.DetailItem, slot string) (model.DetailBody, error) {
	for _, body := range item.Bodies {
		if body.Slot == slot {
			return body, nil
		}
	}
	return model.DetailBody{}, model.NewError("DETAIL_NOT_FOUND", "This reader detail is no longer available")
}
