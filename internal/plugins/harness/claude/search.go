package claude

import (
	"encoding/json"
	"slices"
	"unicode/utf8"

	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

func (a StateAdapter) SearchText(raw json.RawMessage) (string, error) {
	passages, err := a.SearchPassages(raw)
	return plugin.JoinSearchPassages(passages), err
}

func (StateAdapter) SearchPassages(raw json.RawMessage) ([]plugin.SearchPassage, error) {
	state, err := ParseState(raw)
	if err != nil {
		return nil, err
	}
	parts := []plugin.SearchPassage{}
	for _, turn := range state.Turns {
		if turn.Status != "completed" {
			continue
		}
		for index, prompt := range turn.Prompts {
			if !slices.Contains(turn.InternalPromptIndexes, index) {
				parts = append(parts, plugin.SearchPassage{ExecutionID: turn.ExecutionID, Text: prompt})
			}
		}
		parts = append(parts, plugin.SearchPassage{ExecutionID: turn.ExecutionID, Text: turn.Text})
	}
	return parts, nil
}

func (StateAdapter) ReadableCharacters(raw json.RawMessage) (int, error) {
	state, err := ParseState(raw)
	if err != nil {
		return 0, err
	}
	total := 0
	for _, t := range state.Turns {
		total += utf8.RuneCountInString(t.Text) + utf8.RuneCountInString(t.Error)
	}
	return total, nil
}
