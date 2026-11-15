package opencode

import (
	"encoding/json"
	"strconv"
	"strings"

	"github.com/hupao-creator/Mokusei/internal/core/model"
)

func (StateAdapter) ProjectDetail(raw json.RawMessage, request model.DetailRequest) (model.DetailProjection, error) {
	state, err := DecodeState(raw)
	if err != nil {
		return model.DetailProjection{}, err
	}
	source := newRendererSource(raw)
	projection := model.DetailProjection{ExecutionID: request.ExecutionID, Items: []model.DetailItem{}}
	selected := make(map[string]bool, len(request.Items))
	for _, id := range request.Items {
		selected[id] = true
	}
	executionExists := false
	for _, execution := range state.Executions {
		if execution.ExecutionID == request.ExecutionID {
			executionExists = true
			break
		}
	}
	if !executionExists && request.ExecutionID != "opencode-fork-history" {
		return projection, nil
	}
	messages := make([]*Message, 0)
	for _, message := range state.Messages {
		if request.ExecutionID == "opencode-fork-history" {
			if message.Inherited {
				messages = append(messages, message)
			}
		} else if !message.Inherited && message.ExecutionID == request.ExecutionID {
			messages = append(messages, message)
		}
	}
	seen := map[string]bool{}
	// A child-session row is a disclosure at its first native message position.
	// Expanding it in place keeps the flat detail order equal to the Reader's
	// traversal, including when top-level work surrounds that child session.
	openCodeWalkDetails(messages, source, openCodePrimarySession(state, request.ExecutionID), selected,
		func(id string, force bool, build openCodeDetailBuilder) bool {
			if seen[id] || (!force && !selected[id]) {
				return false
			}
			seen[id] = true
			projection.Items = append(projection.Items, build("", false))
			return false
		})
	for _, id := range []string{request.ExecutionID + ":error", request.ExecutionID + ":interrupted"} {
		if !selected[id] || seen[id] {
			continue
		}
		for _, execution := range state.Executions {
			if execution.ExecutionID != request.ExecutionID {
				continue
			}
			item := model.DetailItem{ID: id, Kind: "error", Status: execution.Status}
			if id == request.ExecutionID+":error" && execution.Error != nil {
				item.Bodies = append(item.Bodies, detailBodyValue("detail", model.DetailBodyText, *execution.Error, false))
			}
			if id == request.ExecutionID+":interrupted" {
				item.Kind, item.Label = "notice", "interrupted"
			}
			seen[id] = true
			projection.Items = append(projection.Items, item)
			break
		}
	}
	return projection, nil
}

func (StateAdapter) ReadDetailBody(raw json.RawMessage, request model.DetailBodyRequest) (model.DetailBody, error) {
	state, err := DecodeState(raw)
	if err != nil {
		return model.DetailBody{}, err
	}
	source := newRendererSource(raw)
	executionExists := false
	for _, execution := range state.Executions {
		if execution.ExecutionID == request.ExecutionID {
			executionExists = true
			break
		}
	}
	if !executionExists && request.ExecutionID != "opencode-fork-history" {
		return model.DetailBody{}, model.NewError("DETAIL_NOT_FOUND", "This reader detail is no longer available")
	}
	messages := make([]*Message, 0)
	for _, message := range state.Messages {
		if request.ExecutionID == "opencode-fork-history" {
			if message.Inherited {
				messages = append(messages, message)
			}
		} else if !message.Inherited && message.ExecutionID == request.ExecutionID {
			messages = append(messages, message)
		}
	}
	var body model.DetailBody
	var bodyErr error
	var matched bool
	openCodeWalkDetails(messages, source, openCodePrimarySession(state, request.ExecutionID), nil,
		func(id string, _ bool, build openCodeDetailBuilder) bool {
			if id != request.ItemID {
				return false
			}
			body, bodyErr = detailBody(build(request.Slot, true), request.Slot)
			matched = true
			return true
		})
	if matched {
		return body, bodyErr
	}
	for _, suffix := range []string{":error", ":interrupted"} {
		if request.ItemID != request.ExecutionID+suffix {
			continue
		}
		for _, execution := range state.Executions {
			if execution.ExecutionID != request.ExecutionID {
				continue
			}
			item := model.DetailItem{ID: request.ItemID, Kind: "error", Status: execution.Status}
			if suffix == ":error" && execution.Error != nil {
				item.Bodies = append(item.Bodies, detailBodyValue("detail", model.DetailBodyText, *execution.Error, true))
			}
			if suffix == ":interrupted" {
				item.Kind, item.Label = "notice", "interrupted"
			}
			return detailBody(item, request.Slot)
		}
	}
	return model.DetailBody{}, model.NewError("DETAIL_NOT_FOUND", "This reader detail is no longer available")
}

// A child-session row names the exact native session under its parent
// execution. The Reader groups by that pair, independently of message order.
func openCodeChildSessionID(executionID, native string) string {
	encoded, _ := json.Marshal([]string{executionID, native})
	return "opencode-child-session:" + string(encoded)
}

// openCodePrimarySession mirrors the Reader's root session, including forks
// whose inherited messages belong to the recorded native source.
func openCodePrimarySession(state *State, executionID string) string {
	if executionID == "opencode-fork-history" && state.ForkSource != nil && state.ForkSource.SessionID != "" {
		return state.ForkSource.SessionID
	}
	return state.NativeSessionID
}

type openCodeDetailBuilder func(slot string, includeText bool) model.DetailItem

// Tool messages are rendered at their assistant part position when one exists,
// mirroring the native row order; orphan tools stay in message order. A child
// session expands at its first native message position, so the flat directory
// order matches the Reader's nested traversal. Walking never formats a body;
// the visitor builds only the rows it needs.
func openCodeWalkDetails(messages []*Message, source rendererSource, primary string, selected map[string]bool,
	visit func(id string, force bool, build openCodeDetailBuilder) bool) bool {
	tools := make(map[string]*Message)
	for _, message := range messages {
		if message.Role == "tool" {
			tools[message.ID] = message
		}
	}
	placed := make(map[string]bool)
	appendTool := func(message *Message) bool {
		if message == nil || placed[message.ID] {
			return false
		}
		placed[message.ID] = true
		return visit(message.ID, false, func(slot string, includeText bool) model.DetailItem {
			return openCodeToolDetail(message, source, slot, includeText)
		})
	}
	placedSessions := map[string]bool{}
	for _, message := range messages {
		if native := message.NativeSessionID; native != "" && primary != "" && native != primary {
			if placedSessions[native] {
				continue
			}
			placedSessions[native] = true
			if selected != nil && !selected[openCodeChildSessionID(message.ExecutionID, native)] {
				continue
			}
			child := make([]*Message, 0)
			for _, candidate := range messages {
				if candidate.NativeSessionID == native {
					child = append(child, candidate)
				}
			}
			// A selected child-session row expands every message in that exact
			// native session; nested child sessions keep their own row decision.
			if openCodeWalkDetails(child, source, native, nil, func(id string, _ bool, build openCodeDetailBuilder) bool {
				return visit(id, true, build)
			}) {
				return true
			}
			continue
		}
		if message.Role == "tool" {
			if appendTool(message) {
				return true
			}
			continue
		}
		if message.Role == "user" {
			if visit(message.ID, false, func(_ string, includeText bool) model.DetailItem {
				return openCodeUserDetail(message, includeText)
			}) {
				return true
			}
			continue
		}
		if message.Role != "assistant" {
			continue
		}
		for _, part := range message.Parts {
			if part.Type == "tool" {
				if appendTool(tools[message.ID+":tool:"+part.ToolCallID]) {
					return true
				}
				continue
			}
			if (part.Type != "text" && part.Type != "reasoning") || strings.TrimSpace(part.Text) == "" {
				continue
			}
			part := part
			if visit(openCodePartRowID(message, part), false, func(_ string, includeText bool) model.DetailItem {
				return openCodePartDetail(message, part, includeText)
			}) {
				return true
			}
		}
	}
	return false
}

func openCodeUserDetail(message *Message, includeText bool) model.DetailItem {
	item := model.DetailItem{ID: message.ID, Kind: "message", Status: message.Status}
	if strings.TrimSpace(message.Text) != "" {
		item.Bodies = append(item.Bodies, detailBodyValue("content", model.DetailBodyMarkdown, message.Text, includeText))
	}
	return item
}

func openCodePartDetail(message *Message, part Part, includeText bool) model.DetailItem {
	item := model.DetailItem{ID: openCodePartRowID(message, part), Status: message.Status}
	if part.Type == "reasoning" {
		item.Kind = "reasoning"
	} else {
		item.Kind = "message"
	}
	item.Bodies = append(item.Bodies, detailBodyValue("content", model.DetailBodyMarkdown, part.Text, includeText))
	return item
}

func openCodePartRowID(message *Message, part Part) string {
	return message.ID + ":" + part.Type + ":" + strconv.Itoa(part.Ordinal)
}

func openCodeToolArgumentsPresent(message *Message, source rendererSource) bool {
	return source.field("messages", message.ID, "arguments") != nil || message.Arguments != nil
}

func openCodeToolResultPresent(message *Message, source rendererSource) bool {
	return source.field("messages", message.ID, "result") != nil || message.Result != nil ||
		strings.TrimSpace(message.Text) != "" || source.field("messages", message.ID, "toolError") != nil
}

// Tool display formatting can materialize a very large sibling payload. The
// directory records the slot but defers both the text and its length; the first
// body page is authoritative for the exact length.
func openCodeToolDetail(message *Message, source rendererSource, slot string, includeText bool) model.DetailItem {
	item := model.DetailItem{ID: message.ID, Kind: "activity", Label: clip(message.ToolName, 1200), Status: message.Status, ToolName: message.ToolName}
	arguments := openCodeToolArgumentsPresent(message, source)
	result := openCodeToolResultPresent(message, source)
	if slot == "" {
		if arguments {
			item.Bodies = append(item.Bodies, model.DetailBody{Slot: "arguments", Format: model.DetailBodyText})
		}
		if result {
			item.Bodies = append(item.Bodies, model.DetailBody{Slot: "result", Format: model.DetailBodyText})
		}
		return item
	}
	switch slot {
	case "arguments":
		if arguments {
			item.Bodies = append(item.Bodies, detailBodyValue("arguments", model.DetailBodyText,
				rendererToolDisplay(source.field("messages", message.ID, "arguments"), message.Arguments), includeText))
		}
	case "result":
		if result {
			item.Bodies = append(item.Bodies, detailBodyValue("result", model.DetailBodyText,
				openCodeToolResultText(message, source), includeText))
		}
	}
	return item
}

func openCodeToolResultText(message *Message, source rendererSource) string {
	result := strings.TrimSpace(message.Text)
	if result == "" {
		result = contentText(message.Result)
	}
	if result == "" {
		if raw := source.field("messages", message.ID, "result"); raw != nil || message.Result != nil {
			result = rendererToolDisplay(raw, message.Result)
		}
	}
	if rawError := source.field("messages", message.ID, "toolError"); rawError != nil {
		var nativeError any
		if json.Unmarshal(rawError, &nativeError) == nil {
			result = strings.TrimSpace(result + "\n" + nativeFailure(nativeError))
		}
	}
	return result
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
