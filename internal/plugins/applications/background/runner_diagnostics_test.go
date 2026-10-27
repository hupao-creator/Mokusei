package background

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

func TestRunnerDiagnosticsPreserveRetryAndShutdownSemantics(t *testing.T) {
	for _, tc := range []struct {
		name, status, class string
		attempts            int
		shutdown, timeout   bool
	}{
		{name: "failed", status: "failed", class: "native-execution", attempts: 1},
		{name: "interrupted", status: "interrupted", class: "native-execution", attempts: 1},
		{name: "waiting", status: "waiting-for-user", class: "native-execution", attempts: 1},
		{name: "exhausted", status: "failed", class: "native-execution", attempts: maxAttempts},
		{name: "timeout", class: "timeout", attempts: 1, timeout: true},
		{name: "shutdown", class: "operation", attempts: 1, shutdown: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			ctx, cancel := context.WithCancel(t.Context())
			defer cancel()
			consumer := &diagnosticConsumer{work: plugin.LifecycleWork{ID: "batch", EventIDs: []string{"event"}, ExecutionID: "execution", Attempts: tc.attempts}}
			nativeError := "private-native-error-canary"
			observation := model.PublicObservation{LatestExecution: &model.PublicExecution{ExecutionID: "execution", Status: "running"}}
			h := &diagnosticHandle{observation: observation}
			sessions := &diagnosticSessions{observation: observation, settlement: func() (model.PublicObservation, error) {
				if tc.shutdown {
					cancel()
					return model.PublicObservation{}, errors.New(nativeError)
				}
				if tc.timeout {
					return model.PublicObservation{}, context.DeadlineExceeded
				}
				return model.PublicObservation{LatestExecution: &model.PublicExecution{ExecutionID: "execution", Status: tc.status, Error: &nativeError}}, nil
			}}
			environment := &diagnosticEnvironment{}
			r := &Runner{behavior: Behavior{ID: "tag.agent"}, consumer: consumer, sessions: sessions, environment: environment, handle: h, initialized: true}
			before := time.Now()
			if err := r.process(ctx); err != nil {
				t.Fatal(err)
			}
			if len(environment.entries) != 1 {
				t.Fatalf("diagnostics = %d", len(environment.entries))
			}
			entry := environment.entries[0]
			outcome, level := "failed", "error"
			if tc.shutdown {
				outcome, level = "cancelled", "info"
			}
			if entry.event != "tag.agent."+outcome || entry.level != level {
				t.Fatalf("wrong outcome: %+v", entry)
			}
			if entry.fields["stage"] != "settlement" || entry.fields["attempts"] != tc.attempts || entry.fields["class"] != tc.class {
				t.Fatalf("missing attempt context: %+v", entry.fields)
			}
			if duration, ok := entry.fields["durationMs"].(int64); !ok || duration < 0 {
				t.Fatalf("invalid duration: %+v", entry.fields)
			}
			if tc.status != "" && (entry.fields["executionStatus"] != tc.status || entry.fields["nativeErrorPresent"] != true) {
				t.Fatalf("missing native outcome: %+v", entry.fields)
			}
			rawFields, _ := json.Marshal(entry.fields)
			if strings.Contains(string(rawFields), nativeError) {
				t.Fatal("native error leaked")
			}
			if tc.shutdown {
				if consumer.updates != 0 || consumer.settled != "" || consumer.work.Attempts != tc.attempts {
					t.Fatal("shutdown changed durable work")
				}
			} else if tc.attempts == maxAttempts {
				if consumer.updates != 0 || consumer.settled != "failed" {
					t.Fatal("exhausted work did not settle as failed")
				}
			} else if consumer.updates != 1 || consumer.work.Attempts != tc.attempts+1 || consumer.work.NextAttemptAt < before.Add(19*time.Second).UnixMilli() || consumer.settled != "" {
				t.Fatalf("retry policy changed: %+v", consumer)
			}
		})
	}
}

type diagnosticEntry struct {
	level, event string
	fields       model.Object
}
type diagnosticEnvironment struct {
	plugin.BackgroundEnvironmentCapability
	entries []diagnosticEntry
}

func (e *diagnosticEnvironment) Log(level, event string, fields model.Object) {
	e.entries = append(e.entries, diagnosticEntry{level, event, fields})
}

type diagnosticConsumer struct {
	runnerTestConsumer
	work    plugin.LifecycleWork
	updates int
	settled string
}

func (c *diagnosticConsumer) Work() *plugin.LifecycleWork { copy := c.work; return &copy }
func (c *diagnosticConsumer) Read(plugin.LifecycleHistoryQuery) (plugin.Page[plugin.LifecycleHistoryEntry], error) {
	return plugin.Page[plugin.LifecycleHistoryEntry]{}, nil
}
func (c *diagnosticConsumer) Update(_ context.Context, u plugin.LifecycleWorkUpdate) error {
	c.updates++
	c.work = plugin.LifecycleWork{ID: u.ID, EventIDs: u.EventIDs, ExecutionID: u.ExecutionID, Attempts: u.Attempts, NextAttemptAt: u.NextAttemptAt}
	return nil
}
func (c *diagnosticConsumer) Settle(_ context.Context, _ string, outcome string) error {
	c.settled = outcome
	return nil
}

type diagnosticHandle struct {
	runnerTestHandle
	observation model.PublicObservation
}

func (h *diagnosticHandle) Observation() model.PublicObservation     { return h.observation }
func (h *diagnosticHandle) Interrupt(context.Context, *string) error { return nil }

type diagnosticSessions struct {
	plugin.BackgroundSessionsCapability
	observation model.PublicObservation
	reads       int
	settlement  func() (model.PublicObservation, error)
}

func (s *diagnosticSessions) Read(string) (*plugin.PrivateSessionSnapshot, error) {
	s.reads++
	observation := s.observation
	if s.reads >= 3 {
		var err error
		observation, err = s.settlement()
		if err != nil {
			return nil, err
		}
	}
	return &plugin.PrivateSessionSnapshot{Record: model.SessionRecord{Observation: observation}}, nil
}
