package plugin

import "encoding/json"

// SearchTextAdapter opts a Harness into keyword text indexing. It extracts
// public message text from completed turns inside its own schema. Running,
// waiting, failed, interrupted and unknown executions are excluded, along with
// attachment fields, raw
// tool parameters, reasoning and internal-only fields. Unknown adapters remain
// metadata-only; public text can contain user-visible file references.
type SearchTextAdapter interface {
	SearchText(json.RawMessage) (string, error)
}
