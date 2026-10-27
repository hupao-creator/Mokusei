package codex

import (
	"encoding/json"
	"strings"
)

func (sessionStateAdapter) SearchText(raw json.RawMessage) (string, error) {
	state, err := stDecodeRaw(raw)
	if err != nil {
		return "", err
	}
	parts := []string{}
	for _, value := range stArray(state["turns"]) {
		turn := stMap(value)
		if stString(turn["status"]) != "completed" {
			continue
		}
		for _, item := range stArray(turn["messages"]) {
			message := stMap(item)
			if message["internal"] != true {
				parts = append(parts, stString(message["content"]))
			}
		}
		parts = append(parts, stString(turn["answer"]))
	}
	return strings.Join(parts, "\n"), nil
}
