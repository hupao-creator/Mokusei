package pi

import (
	"encoding/json"
	"errors"
	"strings"
)

// Public message IDs are local to Mokusei. Match the complete ordered native
// assistant sequence before using a JSONL prefix, rather than guessing from a
// timestamp or choosing the first occurrence of a repeated reply. Native tree
// branches or missing history that cannot be proven equivalent fail closed.
func forkExecution(state State, id string) (State, error) {
	failure := errors.New("Pi native checkpoint for this execution is unavailable")
	executionIndex := -1
	for i, execution := range state.Executions {
		if execution.ExecutionID == id && execution.Terminal() {
			executionIndex = i
			break
		}
	}
	if executionIndex < 0 {
		return state, failure
	}
	assistants := []MessageState{}
	target := -1
	messageEnd := -1
	for i, message := range state.Messages {
		if message.ExecutionID == id {
			messageEnd = i
		}
		if message.Role == "assistant" {
			assistants = append(assistants, message)
			if message.ExecutionID == id {
				target = len(assistants) - 1
			}
		}
	}
	if target < 0 || state.Messages[messageEnd].Role != "assistant" {
		return state, failure
	}
	lines := strings.Split(strings.TrimSpace(state.NativeSessionJSONL), "\n")
	nativeIndex, boundary := 0, -1
	lastID := ""
	for i, line := range lines {
		var entry struct {
			Type     string  `json:"type"`
			ID       string  `json:"id"`
			ParentID *string `json:"parentId"`
			Message  struct {
				Role    string `json:"role"`
				Content any    `json:"content"`
			} `json:"message"`
		}
		if err := json.Unmarshal([]byte(line), &entry); err != nil {
			return state, failure
		}
		if entry.Type == "session" {
			continue
		}
		if entry.ID == "" || entry.ParentID == nil && lastID != "" || entry.ParentID != nil && *entry.ParentID != lastID {
			return state, failure
		}
		lastID = entry.ID
		if entry.Type != "message" || entry.Message.Role != "assistant" {
			continue
		}
		text, err := piContent(entry.Message.Content, "text")
		if err != nil || nativeIndex >= len(assistants) || text != assistants[nativeIndex].Text {
			return state, failure
		}
		if nativeIndex == target {
			boundary = i
		}
		nativeIndex++
	}
	if nativeIndex != len(assistants) || boundary < 0 {
		return state, failure
	}
	state.NativeSessionJSONL = strings.Join(lines[:boundary+1], "\n") + "\n"
	state.Messages = state.Messages[:messageEnd+1]
	state.Executions = state.Executions[:executionIndex+1]
	state.Foregrounds = nil
	// Metadata/usage maps must not carry a later execution into the new branch.
	for key := range state.ExecutionAuthors {
		retained := false
		for _, execution := range state.Executions {
			if execution.ExecutionID == key {
				retained = true
				break
			}
		}
		if !retained {
			delete(state.ExecutionAuthors, key)
		}
	}
	return state, nil
}
