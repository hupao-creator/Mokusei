package pi

import (
	"encoding/json"
	"strings"
)

func (stateAdapter) SearchText(raw json.RawMessage) (string, error) {
	state, err := decodeState(raw)
	if err != nil {
		return "", err
	}
	parts := []string{}
	completed := map[string]bool{}
	for _, execution := range state.Executions {
		if execution.Status == "completed" {
			completed[execution.ExecutionID] = true
		}
	}
	for _, message := range state.Messages {
		if completed[message.ExecutionID] && (message.Role == "user" || message.Role == "assistant") {
			parts = append(parts, message.Text)
		}
	}
	return strings.Join(parts, "\n"), nil
}
