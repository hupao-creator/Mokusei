package background

import (
	"context"
	"errors"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
)

type executionFailure struct {
	status         string
	nativeErrorSet bool
}

func (e *executionFailure) Error() string { return "Background execution " + e.status }

// Diagnostics describe the failing boundary without retaining native error text,
// tool arguments, private conversation content or workspace paths.
func (r *Runner) diagnose(outcome, stage string, attempts int, started time.Time, err error) {
	if r.environment == nil {
		return
	}
	class := "operation"
	var execution *executionFailure
	fields := model.Object{"stage": stage}
	switch {
	case errors.Is(err, context.Canceled):
		class = "cancelled"
	case errors.Is(err, context.DeadlineExceeded):
		class = "timeout"
	case errors.As(err, &execution):
		class = "native-execution"
		fields["executionStatus"] = execution.status
		fields["nativeErrorPresent"] = execution.nativeErrorSet
	}
	fields["class"] = class
	if attempts >= 0 {
		fields["attempts"] = attempts
	}
	if !started.IsZero() {
		fields["durationMs"] = time.Since(started).Milliseconds()
	}
	level := "error"
	if outcome == "cancelled" {
		level = "info"
	}
	r.environment.Log(level, r.behavior.ID+"."+outcome, fields)
}
