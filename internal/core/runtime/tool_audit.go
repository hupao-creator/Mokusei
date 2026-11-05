package runtime

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

// Wrap the copied injection once per native owner. Capturing identities at entry
// keeps concurrent callbacks and late completion tied to their original run.
func (r *Runtime) auditToolInjection(thread model.ThreadRecord, injection *plugin.Injection) *plugin.Injection {
	if r.config.ToolTrace == nil || injection == nil || injection.Tools == nil {
		return injection
	}
	identity := plugin.ToolInvocation{Version: 1, SessionID: thread.ID, HarnessID: thread.HarnessID,
		Agent: "moku", AgentID: "moku", Scope: plugin.ScopeBinding{Kind: plugin.GlobalScope},
		Coverage: "injected-callback-only", CallIDKind: "native-tool-call"}
	if !thread.Moku {
		snapshot := r.config.Store.Snapshot()
		var key string
		var session plugin.PrivateSessionSnapshot
		found, err := snapshot.Get("private-session-index:"+thread.ID, &key)
		if err != nil || !found {
			return injection
		}
		found, err = snapshot.Get(key, &session)
		if err != nil || !found || (session.Ref.Owner.PluginID != "tag" && session.Ref.Owner.PluginID != "report") {
			return injection
		}
		identity.Agent = session.Ref.Owner.PluginID
		identity.AgentID = session.Ref.Owner.AgentID
		identity.Scope = session.Ref.Owner.Binding
	}
	if thread.HarnessID == "claude" {
		identity.CallIDKind = "mcp-request" // Claude does not forward its tool-use ID.
	}
	copy := *injection
	tools := *injection.Tools
	tools.Bindings = append([]plugin.ToolBinding(nil), tools.Bindings...)
	copy.Tools = &tools
	for i, binding := range tools.Bindings {
		tools.Bindings[i].Execute = func(ctx context.Context, call plugin.ToolCall) (result json.RawMessage, err error) {
			id, idErr := newID()
			if idErr != nil {
				r.logToolAuditFailure("tool-audit.identity-failed", "tool invocation identity unavailable; callback coverage lost")
				return binding.Execute(ctx, call)
			}
			started := time.Now()
			event := identity
			event.InvocationID, event.CallID, event.Tool = id, call.CallID, binding.Name
			event.CallIDTruncated = call.CallIDTruncated
			event.Missing = []string{"nativeSessionId", "retryOfInvocationId"}
			event.StartedAt = started.UTC().Format(time.RFC3339Nano)
			event.Event, event.Outcome, event.OutcomeBasis = "tool.started", "incomplete", "callback-entered"
			if current, readErr := r.sessionThread(thread.ID); readErr == nil && current.Observation.LatestExecution != nil {
				event.ExecutionID = current.Observation.LatestExecution.ExecutionID
				event.ExecutionStatus = current.Observation.LatestExecution.Status
			}
			if event.ExecutionID == "" {
				event.Missing = append(event.Missing, "executionId")
			}
			if call.CallID == "" {
				event.Missing = append(event.Missing, "callId")
			}
			contextFailed := false
			if tools.AuditContext != nil {
				func() {
					defer func() {
						if recover() != nil {
							contextFailed = true
							r.logToolAuditFailure("tool-audit.context-failed", "tool retry metadata unavailable; callback will continue")
						}
					}()
					event.ToolRetryContext = tools.AuditContext()
				}()
			}
			event.RetryContextStatus = "not-applicable"
			if event.Agent != "moku" && event.BatchID == "" {
				event.Missing = append(event.Missing, "batchId")
				event.RetryContextStatus = "missing"
			} else if event.Agent != "moku" {
				event.RetryContextStatus = "execution-matched"
				if event.BatchExecutionID == "" || event.ExecutionID == "" {
					event.RetryContextStatus = "execution-unconfirmed"
				} else if event.BatchExecutionID != event.ExecutionID {
					event.RetryContextStatus = "execution-mismatch"
				}
			}
			if contextFailed {
				event.RetryContextStatus = "capture-failed"
			}
			event.Input = call.Arguments
			event.StartRecorded = true
			event.StartRecorded = r.recordToolInvocation(event)
			event.Input = nil // Input belongs to start, output to finish; no duplicate bodies.
			handlerStarted := time.Now()
			returned := false
			defer func() {
				panicValue := recover()
				// Error classification and diagnostic callbacks are observational.
				// A panic there must not replace the handler's return or original panic.
				func() {
					defer func() {
						if recover() != nil {
							r.logToolAuditFailure("tool-audit.write-failed", "tool finish diagnostics panicked; coverage may be incomplete")
						}
					}()
					event.Event = "tool.finished"
					event.FinishedAt = time.Now().UTC().Format(time.RFC3339Nano)
					event.DurationMS = float64(time.Since(started)) / float64(time.Millisecond)
					event.HandlerDurationMS = float64(time.Since(handlerStarted)) / float64(time.Millisecond)
					event.Output, event.Error = result, err
					var domainError *model.Error
					if errors.As(err, &domainError) {
						event.ErrorCode = domainError.Code
					}
					event.Outcome, event.OutcomeBasis = toolAuditOutcome(result, err)
					if !returned {
						event.Outcome, event.OutcomeBasis = "unknown", "callback-unwound"
						if panicValue != nil {
							event.Outcome, event.OutcomeBasis = "failed", "panic"
							event.Error = errors.New("tool callback panicked; panic payload withheld")
						}
					}
					r.recordToolInvocation(event)
				}()
				// Each bridge retains ownership of panic recovery and its native response.
				if panicValue != nil {
					panic(panicValue)
				}
			}()
			call.InvocationID = id
			result, err = binding.Execute(ctx, call)
			returned = true
			return result, err
		}
	}
	return &copy
}

// Even the fallback sink is optional diagnostics, never a tool failure path.
func (r *Runtime) logToolAuditFailure(kind, message string) {
	defer func() { _ = recover() }()
	r.log(kind, errors.New(message))
}

func (r *Runtime) recordToolInvocation(event plugin.ToolInvocation) (recorded bool) {
	defer func() {
		if recover() != nil {
			r.logToolAuditFailure("tool-audit.write-failed", "private tool journal sink panicked; coverage may be incomplete")
			recorded = false
		}
	}()
	if err := r.config.ToolTrace(event); err != nil {
		// Never leak bodies or filesystem errors to the ordinary diagnostic channel.
		// Logging failure must not turn a successful side effect into a model retry.
		r.logToolAuditFailure("tool-audit.write-failed", "private tool journal write or retention failed; coverage may be incomplete")
		return false
	}
	return true
}

func toolAuditOutcome(result json.RawMessage, err error) (string, string) {
	if err != nil {
		switch {
		case errors.Is(err, context.DeadlineExceeded):
			return "failed", "deadline"
		case errors.Is(err, context.Canceled):
			return "cancelled", "context-cancelled"
		}
		var caller *plugin.ToolCallError
		if errors.As(err, &caller) {
			return "business_rejected", "caller-error"
		}
		return "failed", "unclassified-error"
	}
	if len(result) == 0 {
		return "unknown", "empty-result-bridge-dependent"
	}
	if !json.Valid(result) {
		return "failed", "invalid-result-json"
	}
	var envelope struct {
		OK *bool `json:"ok"`
	}
	if json.Unmarshal(result, &envelope) == nil && envelope.OK != nil && !*envelope.OK {
		return "business_rejected", "tool-ok-false"
	}
	return "succeeded", "callback-returned"
}
