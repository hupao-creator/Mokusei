package codex

import (
	"encoding/json"

	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

func (a sessionStateAdapter) SearchText(raw json.RawMessage) (string, error) {
	passages, err := a.SearchPassages(raw)
	return plugin.JoinSearchPassages(passages), err
}

func (sessionStateAdapter) SearchPassages(raw json.RawMessage) ([]plugin.SearchPassage, error) {
	state, err := stDecodeRaw(raw)
	if err != nil {
		return nil, err
	}
	parts := []plugin.SearchPassage{}
	for _, value := range stArray(state["turns"]) {
		turn := stMap(value)
		if stString(turn["status"]) != "completed" {
			continue
		}
		for _, item := range stArray(turn["messages"]) {
			message := stMap(item)
			if message["internal"] != true {
				parts = append(parts, plugin.SearchPassage{ExecutionID: stString(turn["executionId"]), Text: stString(message["content"])})
			}
		}
		parts = append(parts, plugin.SearchPassage{ExecutionID: stString(turn["executionId"]), Text: stString(turn["answer"])})
	}
	return parts, nil
}
