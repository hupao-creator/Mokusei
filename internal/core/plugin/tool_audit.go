package plugin

import "encoding/json"

type ToolRetryContext struct {
	ConsumerID       string `json:"consumerId,omitempty"`
	BatchID          string `json:"batchId,omitempty"`
	Attempt          int    `json:"attempt,omitempty"`
	BatchExecutionID string `json:"batchExecutionId,omitempty"`
}

// ToolInvocation is an internal diagnostic handoff. Payloads must only reach a
// private, bounded, redacting sink; never the ordinary service logger or UI.
type ToolInvocation struct {
	Version            int          `json:"version"`
	Event              string       `json:"event"`
	InvocationID       string       `json:"invocationId"`
	SessionID          string       `json:"sessionId"`
	ExecutionID        string       `json:"executionId"`
	ExecutionStatus    string       `json:"executionStatusAtEntry"`
	RetryContextStatus string       `json:"retryContextStatus"`
	HarnessID          string       `json:"harnessId"`
	Agent              string       `json:"agent"`
	AgentID            string       `json:"agentId"`
	Scope              ScopeBinding `json:"scope"`
	Tool               string       `json:"tool"`
	CallID             string       `json:"callId"`
	CallIDKind         string       `json:"callIdKind"`
	CallIDTruncated    bool         `json:"callIdTruncated"`
	ToolRetryContext
	StartedAt         string          `json:"startedAt"`
	FinishedAt        string          `json:"finishedAt,omitempty"`
	DurationMS        float64         `json:"durationMs"`
	HandlerDurationMS float64         `json:"handlerDurationMs"`
	ErrorCode         string          `json:"errorCode,omitempty"`
	Outcome           string          `json:"outcome"`
	OutcomeBasis      string          `json:"outcomeBasis"`
	Coverage          string          `json:"coverage"`
	Missing           []string        `json:"missing,omitempty"`
	StartRecorded     bool            `json:"startRecorded"`
	Input             json.RawMessage `json:"-"`
	Output            json.RawMessage `json:"-"`
	Error             error           `json:"-"`
}
