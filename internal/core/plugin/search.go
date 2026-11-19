package plugin

import "encoding/json"

// SearchPassage preserves the exact public text and its owning execution.
// Empty execution IDs mean no execution locator is available.
type SearchPassage struct {
	ExecutionID string `json:"executionId,omitempty"`
	Text        string `json:"text"`
	// Unavailable preserves passage order without disclosing an input whose
	// visibility was not retained. Retrieval must report this coverage gap.
	Unavailable bool `json:"unavailable,omitempty"`
}

// SearchPassageAdapter extracts public completed-execution messages for Agent grep.
// It excludes internal inputs, reasoning, tool payloads and unfinished executions,
// without joining unrelated messages or inventing native-history coverage.
type SearchPassageAdapter interface {
	SearchPassages(json.RawMessage) ([]SearchPassage, error)
}
