package claude

import (
	"encoding/json"
	"slices"
	"strings"
)

func (StateAdapter) SearchText(raw json.RawMessage) (string, error) {
	state, err := ParseState(raw)
	if err != nil {
		return "", err
	}
	parts := []string{}
	for _, turn := range state.Turns {
		if turn.Status != "completed" {
			continue
		}
		for index, prompt := range turn.Prompts {
			if !slices.Contains(turn.InternalPromptIndexes, index) {
				parts = append(parts, prompt)
			}
		}
		parts = append(parts, turn.Text)
	}
	return strings.Join(parts, "\n"), nil
}
