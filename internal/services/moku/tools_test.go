package moku

import (
	"errors"
	"strings"
	"testing"

	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

// A caller-correctable invocation error plus an internal recording failure is a
// Harness fault: the bridge must not turn the whole call into a 4xx.
func TestToolInvocationFailureKeepsRecordFailuresInternal(t *testing.T) {
	caller := plugin.CallerError(errors.New(`create_thread options.model "missing" is unavailable`))
	record := errors.New("Moku transcript is unavailable")
	failure := toolInvocationFailure(caller, record)
	if failure == nil {
		t.Fatal("joined failure was dropped")
	}
	var marked *plugin.ToolCallError
	if errors.As(failure, &marked) {
		t.Fatalf("caller mark survived an internal record failure: %v", failure)
	}
	for _, want := range []string{"options.model", "Moku transcript is unavailable"} {
		if !strings.Contains(failure.Error(), want) {
			t.Fatalf("joined failure dropped %q: %s", want, failure)
		}
	}
}

func TestToolInvocationFailurePreservesCallerMarkAlone(t *testing.T) {
	caller := plugin.CallerError(errors.New("invalid create_thread arguments"))
	var marked *plugin.ToolCallError
	if !errors.As(toolInvocationFailure(caller, nil), &marked) {
		t.Fatal("caller-correctable invocation error lost its mark")
	}
	if got := toolInvocationFailure(nil, caller); !errors.Is(got, caller) {
		t.Fatalf("record-only failure was rewritten: %v", got)
	}
}

func TestToolInvocationFailureKeepsInternalErrorsInternal(t *testing.T) {
	internal := errors.New("Moku configuration persistence unavailable")
	failure := toolInvocationFailure(internal, nil)
	if failure != internal {
		t.Fatalf("internal invocation error was rewritten: %v", failure)
	}
	var marked *plugin.ToolCallError
	if errors.As(failure, &marked) {
		t.Fatalf("internal invocation error gained a caller mark: %v", failure)
	}
	if toolInvocationFailure(nil, nil) != nil {
		t.Fatal("successful invocation produced a failure")
	}
}
