package model

// CancellationRequest fences both the pre-execution input admission and the
// resulting execution. The host creates a fresh identity for every successor.
type CancellationRequest struct {
	ThreadID               string `json:"threadId"`
	ExpectedCancellationID string `json:"expectedCancellationId"`
}

type CancellationStatus string

const (
	CancellationCancelled CancellationStatus = "cancelled"
	CancellationStale     CancellationStatus = "stale"
)

// CancellationResult describes the stop request. The execution's final
// status and interruption provenance belong to the Thread observation and record.
type CancellationResult struct {
	Status CancellationStatus `json:"status"`
}
