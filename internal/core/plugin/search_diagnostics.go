package plugin

import (
	"context"
	"crypto/rand"
	"errors"
	"time"
)

// SearchDiagnostic is a closed metadata vocabulary. It carries no query text,
// source identity, file path, vectors, credentials or free-form errors.
type SearchDiagnostic struct {
	Event         string  `json:"event"`
	OperationID   string  `json:"operationId,omitempty"`
	Kind          string  `json:"kind,omitempty"`
	Outcome       string  `json:"outcome,omitempty"`
	Reason        string  `json:"reason,omitempty"`
	Mode          string  `json:"mode,omitempty"`
	DurationMS    float64 `json:"durationMs"`
	QueueMS       float64 `json:"queueMs,omitempty"`
	RateWaitMS    float64 `json:"rateWaitMs,omitempty"`
	Cache         string  `json:"cache,omitempty"`
	Epoch         uint64  `json:"epoch,omitempty"`
	ScopeCount    int     `json:"scopeCount,omitempty"`
	DocumentCount int     `json:"documentCount,omitempty"`
	ChunkCount    int     `json:"chunkCount,omitempty"`
	RequestCount  int     `json:"requestCount,omitempty"`
	ReusedChunks  int     `json:"reusedChunks,omitempty"`
	HitCount      int     `json:"hitCount,omitempty"`
	SemanticCount int     `json:"semanticCount,omitempty"`
	TopScore      float64 `json:"topScore,omitempty"`
	BestCosine    float64 `json:"bestCosine,omitempty"`
	InputBytes    int     `json:"inputBytes,omitempty"`
	ColdStart     bool    `json:"coldStart,omitempty"`
}

type searchOperationKey struct{}

// SearchOperation keeps query/index and inference events in the same operation.
func SearchOperation(ctx context.Context) (context.Context, string) {
	if id, ok := ctx.Value(searchOperationKey{}).(string); ok {
		return ctx, id
	}
	id := rand.Text()
	return context.WithValue(ctx, searchOperationKey{}, id), id
}

func SearchDuration(start time.Time) float64 {
	return float64(time.Since(start)) / float64(time.Millisecond)
}

// SearchFailure never forwards arbitrary native errors into diagnostics.
func SearchFailure(err error) string {
	if errors.Is(err, context.Canceled) {
		return "cancelled"
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return "timeout"
	}
	var embedding *EmbeddingError
	if errors.As(err, &embedding) {
		switch embedding.Code {
		case "local-unavailable", "cleanup", "unsupported", "model-missing", "input-limit", "response", "batch-limit":
			return embedding.Code
		}
	}
	return "internal"
}
