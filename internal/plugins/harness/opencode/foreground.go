package opencode

import (
	"fmt"
	"math"
	"strings"

	"github.com/hupao-creator/Mokusei/internal/core/model"
)

const reasoningSourcePoints = 32 * 1024

type foregroundCandidate struct {
	executionID string
	segmentID   string
	body        Object
}

// foregroundForEvent runs before the timeline reducer so a full-value ended
// event contributes only the suffix not already received through stream deltas.
func (state *State) foregroundForEvent(event Event, owner string) *foregroundCandidate {
	data := event.Data
	messageID, sessionID := str(data["assistantMessageID"]), str(data["sessionID"])
	if messageID == "" || sessionID == "" {
		return nil
	}
	assistant := state.message("assistant", messageID, sessionID)
	if assistant != nil {
		messageID, owner = assistant.ID, assistant.ExecutionID
	}
	if owner == "" {
		return nil
	}
	if strings.HasPrefix(event.Type, "session.text.") || strings.HasPrefix(event.Type, "session.reasoning.") {
		ordinal, ok := data["ordinal"].(float64)
		if !ok {
			switch value := data["ordinal"].(type) {
			case int:
				ordinal, ok = float64(value), true
			case int64:
				ordinal, ok = float64(value), true
			}
		}
		if !ok || math.IsNaN(ordinal) || math.IsInf(ordinal, 0) || ordinal < 0 || ordinal > 9007199254740991 || math.Trunc(ordinal) != ordinal {
			return nil
		}
		kind := "text"
		if strings.HasPrefix(event.Type, "session.reasoning.") {
			kind = "reasoning"
		}
		var content string
		switch {
		case strings.HasSuffix(event.Type, ".delta"):
			content, ok = data["delta"].(string)
		case strings.HasSuffix(event.Type, ".ended"):
			content, ok = data["text"].(string)
			if ok && assistant != nil {
				for _, part := range assistant.Parts {
					if part.Type == kind && part.Ordinal == int(ordinal) && strings.HasPrefix(content, part.Text) {
						content = strings.TrimPrefix(content, part.Text)
						break
					}
				}
			}
		default:
			return nil
		}
		content = strings.ReplaceAll(content, "\x00", "")
		if !ok || content == "" {
			return nil
		}
		body := Object{"kind": "assistant-text"}
		if kind == "reasoning" {
			body = Object{"kind": "reasoning", "text": content}
		}
		return &foregroundCandidate{owner, fmt.Sprintf("%s:%s:%d", messageID, kind, int(ordinal)), body}
	}
	if event.Type != "session.tool.input.started" && event.Type != "session.tool.called" {
		return nil
	}
	toolID := str(data["id"])
	if toolID == "" {
		return nil
	}
	callID := messageID + ":tool:" + toolID
	toolName := str(data["name"])
	if toolName == "" {
		if tool := state.message("tool", callID, sessionID); tool != nil {
			toolName = tool.ToolName
		}
	}
	toolName = clip(toolName, 64)
	if strings.TrimSpace(toolName) == "" {
		return nil
	}
	return &foregroundCandidate{owner, callID, Object{"kind": "tool-call", "callId": callID, "toolName": toolName}}
}

// acceptForeground stores one semantic activity per execution. Sequence changes
// only at segment/call boundaries; reasoning deltas update a bounded UTF-16
// positioned window, matching the native renderer's durable activity contract.
func (state *State) acceptForeground(candidate *foregroundCandidate) *model.HarnessActivity {
	if candidate == nil {
		return nil
	}
	active := false
	for _, execution := range state.Executions {
		if execution.ExecutionID == candidate.executionID && (execution.Status == "running" || execution.Status == "waiting-for-user") {
			active = true
			break
		}
	}
	if !active {
		return nil
	}
	index := -1
	var previous Object
	previousSegment := ""
	for i, entry := range state.Foregrounds {
		if entry["executionId"] == candidate.executionID {
			index = i
			previous = object(entry["foreground"])
			previousSegment = str(entry["segmentId"])
			break
		}
	}
	next := clone(candidate.body)
	continues := previous != nil && previous["kind"] == next["kind"] && previousSegment == candidate.segmentID
	sequence := int64(number(previous["sequence"])) + 1
	if continues && (next["kind"] != "tool-call" || previous["callId"] == next["callId"]) {
		sequence = int64(number(previous["sequence"]))
	}
	if sequence < 1 {
		sequence = 1
	}
	if next["kind"] == "reasoning" {
		source := str(next["text"])
		offset := int64(0)
		if continues {
			source = str(previous["text"]) + source
			offset = int64(number(previous["textOffset"]))
		}
		points := []rune(source)
		if len(points) > reasoningSourcePoints {
			for _, point := range points[:len(points)-reasoningSourcePoints] {
				offset++
				if point > 0xffff {
					offset++
				}
			}
			source = string(points[len(points)-reasoningSourcePoints:])
		}
		next["text"] = source
		if offset > 0 {
			next["textOffset"] = offset
		}
	}
	next["sequence"] = sequence
	entry := Object{"executionId": candidate.executionID, "foreground": next, "segmentId": candidate.segmentID}
	if index < 0 {
		state.Foregrounds = append(state.Foregrounds, entry)
	} else {
		state.Foregrounds[index] = entry
	}
	return &model.HarnessActivity{ExecutionID: candidate.executionID, Sequence: sequence, Kind: str(next["kind"]), Text: str(next["text"]), TextOffset: int64(number(next["textOffset"])), CallID: str(next["callId"]), ToolName: str(next["toolName"])}
}
