package opencode

import (
	"encoding/json"
	"strconv"
	"strings"

	"github.com/hupao-creator/Mokusei/internal/core/model"
)

// readingMessageText and readingMessageThinking read the ordered parts that are
// valid in both the current canonical schema and the single-source schema. The
// aggregate Message text/thinking fields are not a second source of truth.
func readingMessageText(message *Message) string {
	if message.Role != "assistant" || len(message.Parts) == 0 {
		return message.Text
	}
	var text strings.Builder
	for _, part := range message.Parts {
		if part.Type == "text" {
			text.WriteString(part.Text)
		}
	}
	return text.String()
}

func readingMessageThinking(message *Message) string {
	var text strings.Builder
	for _, part := range message.Parts {
		if part.Type == "reasoning" {
			text.WriteString(part.Text)
		}
	}
	return text.String()
}

// rendererAgentReading is the count-only Agent reading contract. It retains
// visible replies, public follow-ups, independent failures, pending
// interactions and ordered execution-summary facts. Tool payloads, reasoning
// bodies and initial/internal inputs never enter this projection.
func rendererAgentReading(state *State, scope model.RendererScope) (json.RawMessage, error) {
	history := scope.Key == "opencode-fork-history"
	primary := state.NativeSessionID
	if history && state.ForkSource != nil && state.ForkSource.SessionID != "" {
		primary = state.ForkSource.SessionID
	}
	targetID := ""
	if len(scope.Target) > 0 {
		var target map[string]any
		if json.Unmarshal(scope.Target, &target) == nil {
			targetID = str(target["messageId"])
		}
	}

	executions := make([]*model.PublicExecution, 0)
	if !history {
		for _, execution := range state.Executions {
			if execution.ExecutionID == scope.Key {
				executions = append(executions, execution)
			}
		}
	}
	active := false
	for _, execution := range executions {
		if rendererLive(execution.Status) {
			active = true
		}
	}
	messages := make([]*Message, 0)
	for _, message := range state.Messages {
		if (history && !message.Inherited) || (!history && message.Inherited || message.ExecutionID != scope.Key) {
			continue
		}
		messages = append(messages, message)
	}
	finalID := ""
	if !active {
		for i := len(messages) - 1; i >= 0; i-- {
			message := messages[i]
			if message.Role == "assistant" && message.Status != "streaming" && message.Status != "failed" && !message.IsError && rendererTrim(readingMessageText(message)) != "" {
				finalID = message.ID
				break
			}
		}
	}

	nonempty := []Object{}
	projected := make([]*Message, 0, len(messages))
	for _, message := range messages {
		child := message.NativeSessionID != "" && primary != "" && message.NativeSessionID != primary
		switch message.Role {
		case "user":
			if child || !message.FollowUp || message.Presentation == "internal" {
				continue
			}
			copy := *message
			copy.Arguments, copy.Result, copy.Todos = nil, nil, nil
			copy.Parts = nil
			if copy.Presentation == "" {
				copy.Presentation = "ordinary"
			}
			projected = append(projected, &copy)
		case "tool":
			copy := *message
			copy.Text = ""
			copy.Arguments, copy.Result, copy.Todos = nil, nil, nil
			copy.Annotations, copy.Attachments = nil, nil
			copy.Parts = nil
			projected = append(projected, &copy)
		case "assistant":
			failed := message.IsError || message.Status == "failed"
			visible := failed || message.ID == targetID
			if child {
				// A child session is execution work. Only its independent failure
				// or an explicitly targeted reply leaves the collapsed disclosure.
			} else if active {
				visible = visible || message.Status != "streaming" && rendererTrim(readingMessageText(message)) != ""
			} else {
				visible = visible || message.ID == finalID
			}
			copy := *message
			copy.Arguments, copy.Result, copy.Todos = nil, nil, nil
			copy.Annotations, copy.Attachments = nil, nil
			copy.Text = ""
			if rendererNativeNonempty(readingMessageThinking(message)) {
				nonempty = append(nonempty, Object{"id": message.ID, "field": "thinking"})
			}
			if !visible {
				copy.Text = ""
			}
			parts := make([]Part, 0, len(message.Parts))
			for _, part := range message.Parts {
				switch part.Type {
				case "text":
					if !visible || !rendererNativeNonempty(part.Text) {
						continue
					}
					parts = append(parts, Part{Type: "text", Ordinal: part.Ordinal, Text: part.Text})
				case "reasoning":
					if rendererNativeNonempty(part.Text) {
						nonempty = append(nonempty, Object{"id": message.ID, "field": "parts:reasoning:" + strconv.Itoa(part.Ordinal)})
					}
					parts = append(parts, Part{Type: "reasoning", Ordinal: part.Ordinal})
				}
			}
			if visible && len(message.Parts) == 0 && rendererNativeNonempty(message.Text) {
				parts = append(parts, Part{Type: "text", Text: message.Text})
			}
			copy.Parts = parts
			copy.Text = ""
			projected = append(projected, &copy)
		}
	}

	executionBodies := make([]*model.PublicExecution, 0, len(executions))
	for _, execution := range executions {
		value := *execution
		if history {
			value.Interactions = nil
		}
		executionBodies = append(executionBodies, &value)
	}
	interactions := make([]*Interaction, 0)
	if !history {
		for _, interaction := range state.Interactions {
			if interaction.ExecutionID != scope.Key || interaction.Status != "pending" {
				continue
			}
			copy := *interaction
			copy.Metadata = nil
			interactions = append(interactions, &copy)
		}
	}
	out := &State{
		Version: 1, NativeSessionID: state.NativeSessionID,
		Messages: projected, Executions: executionBodies, Interactions: interactions,
	}
	if history && state.ForkSource != nil {
		out.ForkSource = &ForkSource{SessionID: state.ForkSource.SessionID, MessageID: state.ForkSource.MessageID, Transcript: Object{}}
	}
	if !history {
		for _, execution := range executions {
			if state.LatestExecutionID != nil && execution.ExecutionID == *state.LatestExecutionID {
				id := execution.ExecutionID
				out.LatestExecutionID = &id
			}
		}
	}
	if author, exists := state.ExecutionAuthors[scope.Key]; exists {
		out.ExecutionAuthors = map[string]Object{scope.Key: author}
	}
	for _, sample := range state.AuxiliaryUsage {
		if sample.ExecutionID == scope.Key {
			out.AuxiliaryUsage = append(out.AuxiliaryUsage, sample)
		}
	}
	return json.Marshal(Object{"kind": "deferred-execution", "state": out, "nonempty": nonempty})
}
