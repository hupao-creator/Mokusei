package opencode

import (
	"encoding/json"

	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

func (a StateAdapter) SearchText(raw json.RawMessage) (string, error) {
	passages, err := a.SearchPassages(raw)
	return plugin.JoinSearchPassages(passages), err
}

func (StateAdapter) SearchPassages(raw json.RawMessage) ([]plugin.SearchPassage, error) {
	state, err := DecodeState(raw)
	if err != nil {
		return nil, err
	}
	parts := []plugin.SearchPassage{}
	completed := map[string]bool{}
	for _, execution := range state.Executions {
		if execution.Status == "completed" {
			completed[execution.ExecutionID] = true
		}
	}
	for _, message := range state.Messages {
		if completed[message.ExecutionID] && message.Presentation != "internal" && (message.Role == "user" || message.Role == "assistant") {
			if message.Role == "user" && message.Presentation != "ordinary" {
				parts = append(parts, plugin.SearchPassage{ExecutionID: message.ExecutionID, Unavailable: true})
				continue
			}
			parts = append(parts, plugin.SearchPassage{ExecutionID: message.ExecutionID, Text: message.Text})
		}
	}
	return parts, nil
}
