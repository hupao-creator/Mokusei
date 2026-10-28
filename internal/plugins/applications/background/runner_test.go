package background

import (
	"context"
	"errors"
	"sync/atomic"
	"testing"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

func TestRunnerStopRetainsFailedHandleCleanup(t *testing.T) {
	closeFailure := errors.New("native session did not close")
	handle := &runnerTestHandle{closeError: closeFailure}
	sessions := runnerTestSessions{handle: handle}
	runner := &Runner{
		behavior: Behavior{LazyInitialize: true, Tools: func(context.Context) []plugin.ToolBinding { return nil }},
		consumer: runnerTestConsumer{}, sessions: sessions, configuration: sessions,
		wake: make(chan struct{}, 1),
	}
	if err := runner.Start(t.Context(), plugin.RuntimeStartContext{}); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = runner.Stop(context.Background()) })
	if _, err := runner.ensureInstance(t.Context()); err != nil {
		t.Fatal(err)
	}
	for attempt := 0; attempt < 2; attempt++ {
		if err := runner.Stop(t.Context()); !errors.Is(err, closeFailure) {
			t.Fatalf("stop %d lost native cleanup failure: %v", attempt+1, err)
		}
	}
	if handle.closes.Load() != 1 {
		t.Fatalf("native close calls = %d", handle.closes.Load())
	}
	if err := runner.Start(t.Context(), plugin.RuntimeStartContext{}); !errors.Is(err, closeFailure) {
		t.Fatalf("restart lost native cleanup failure: %v", err)
	}
}

type runnerTestConsumer struct{}

func (runnerTestConsumer) ID() string                  { return "test.events" }
func (runnerTestConsumer) Work() *plugin.LifecycleWork { return nil }
func (runnerTestConsumer) Pending(plugin.PendingEventsQuery) ([]plugin.LifecycleEvent, error) {
	return nil, nil
}
func (runnerTestConsumer) Subscribe(context.Context, func(plugin.LifecycleNotification), *plugin.PrivateSessionRef) (func(), error) {
	return func() {}, nil
}
func (runnerTestConsumer) Read(plugin.LifecycleHistoryQuery) (plugin.Page[plugin.LifecycleHistoryEntry], error) {
	panic("idle runner must not read history")
}
func (runnerTestConsumer) Begin(context.Context, []string) (plugin.LifecycleWork, error) {
	panic("idle runner must not begin work")
}
func (runnerTestConsumer) Update(context.Context, plugin.LifecycleWorkUpdate) error {
	panic("idle runner must not update work")
}
func (runnerTestConsumer) Settle(context.Context, string, string) error {
	panic("idle runner must not settle work")
}

type runnerTestSessions struct{ handle *runnerTestHandle }

func (runnerTestSessions) Read(string) (*plugin.PrivateSessionSnapshot, error) {
	return &plugin.PrivateSessionSnapshot{ConfigurationKey: "current"}, nil
}
func (runnerTestSessions) Resolve(context.Context, string) (plugin.ResolvedBackgroundConfiguration, error) {
	return plugin.ResolvedBackgroundConfiguration{ConfigurationKey: "current"}, nil
}
func (s runnerTestSessions) Configure(_ context.Context, request plugin.ConfigureSessionRequest) (plugin.PrivateSessionSnapshot, error) {
	if request.Configuration.ConfigurationKey != "current" {
		panic("current session must not be replaced")
	}
	current, err := s.Read(request.SessionKey)
	return *current, err
}
func (s runnerTestSessions) Open(context.Context, plugin.OpenSessionRequest) (plugin.PrivateSessionHandle, error) {
	return s.handle, nil
}

type runnerTestHandle struct {
	closeError error
	closes     atomic.Int32
}

func (*runnerTestHandle) Ref() plugin.PrivateSessionRef { return plugin.PrivateSessionRef{} }
func (*runnerTestHandle) Observation() model.PublicObservation {
	return model.PublicObservation{}
}
func (*runnerTestHandle) Send(context.Context, model.AgentInput, []plugin.ContextEntry, plugin.SessionSendAdmitted) (plugin.SessionSendResult, error) {
	panic("idle runner must not send")
}
func (*runnerTestHandle) Interrupt(context.Context, *string) error {
	panic("idle runner must not interrupt")
}
func (h *runnerTestHandle) Close() error {
	h.closes.Add(1)
	return h.closeError
}
