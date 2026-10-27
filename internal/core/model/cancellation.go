package model

// CancellationRequest fences both the pre-execution input admission and the
// resulting execution. The host creates a fresh identity for every successor.
type CancellationRequest struct {
	ThreadID               string `json:"threadId"`
	ExpectedCancellationID string `json:"expectedCancellationId"`
}

type CancellationResult struct {
	Status string `json:"status"`
}
