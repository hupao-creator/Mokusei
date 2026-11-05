package plugin

import (
	"encoding/json"
	"strings"
)

// SearchTextAdapter opts a Harness into keyword text indexing. It extracts
// public message text from completed turns inside its own schema. Running,
// waiting, failed, interrupted and unknown executions are excluded, along with
// attachment fields, raw
// tool parameters, reasoning and internal-only fields. Unknown adapters remain
// metadata-only; public text can contain user-visible file references.
type SearchTextAdapter interface {
	SearchText(json.RawMessage) (string, error)
}

// SearchPassage preserves the exact public text and its owning execution.
// Empty execution IDs mean no execution locator is available.
type SearchPassage struct {
	ExecutionID string `json:"executionId,omitempty"`
	Text        string `json:"text"`
	// Unavailable preserves passage order without disclosing an input whose
	// visibility was not retained. Retrieval must report this coverage gap.
	Unavailable bool `json:"unavailable,omitempty"`
}

// SearchPassageAdapter uses the same disclosure boundary as SearchTextAdapter,
// without joining unrelated messages or inventing native-history coverage.
type SearchPassageAdapter interface {
	SearchPassages(json.RawMessage) ([]SearchPassage, error)
}

func JoinSearchPassages(passages []SearchPassage) string {
	parts := make([]string, len(passages))
	for i, passage := range passages {
		parts[i] = passage.Text
	}
	return strings.Join(parts, "\n")
}
