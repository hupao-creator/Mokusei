package plugin

import (
	"context"
	"encoding/json"
)

// Embeddings are a separate capability from generative Harness protocols.
// Local model resources are resolved and owned by the runtime.
const LocalEmbeddingSpace = "google/embeddinggemma-2/bfcd298762cc34d0357ece5ebdd31791a3a374d8/q8_0/llama.cpp-b11748/mean-768/v1"

type EmbeddingProvider interface {
	Model() string
	Available(context.Context) bool
	Embed(context.Context, string, int) ([]float32, error)
}

type EmbeddingError struct {
	Code string
}

func (e *EmbeddingError) Error() string { return "Embedding service unavailable: " + e.Code }

// SearchTextAdapter opts a Harness into consented text indexing. It extracts
// public message text from completed turns inside its own schema. Running,
// waiting, failed, interrupted and unknown executions are excluded, along with
// attachment fields, raw
// tool parameters, reasoning and internal-only fields. Unknown adapters remain
// metadata-only; public text can contain user-visible file references.
type SearchTextAdapter interface {
	SearchText(json.RawMessage) (string, error)
}

// ManagedEmbeddings owns a local inference process and explicit model downloads.
// Download is independent of permission to index the user's history.
type ManagedEmbeddings interface {
	EmbeddingProvider
	SetupStatus() EmbeddingSetupStatus
	Download(context.Context) error
	Remove() error
	CancelDownload()
	Release() error
	Close() error
}
type EmbeddingSetupStatus struct {
	Supported       bool   `json:"supported"`
	Ready           bool   `json:"ready"`
	Loaded          bool   `json:"loaded"`
	Downloading     bool   `json:"downloading"`
	DownloadedBytes int64  `json:"downloadedBytes"`
	TotalBytes      int64  `json:"totalBytes"`
	Reason          string `json:"reason,omitempty"`
}
