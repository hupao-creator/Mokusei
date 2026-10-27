package moku

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

func TestTerminalDeliveryRetryAndUncertainReconciliation(t *testing.T) {
	terminal := model.ThreadRecord{SessionRecord: model.SessionRecord{ID: "child", Observation: model.PublicObservation{LatestExecution: &model.PublicExecution{ExecutionID: "done", Status: "completed"}}}}
	host := model.ThreadRecord{SessionRecord: model.SessionRecord{ID: "moku", Observation: model.PublicObservation{LatestExecution: &model.PublicExecution{ExecutionID: "running", Status: "running"}}}, Moku: true}
	pending := []plugin.MokuDelivery{{ID: "delivery", Thread: terminal}}
	offline := true
	sends := 0
	reports := []string{}
	c := &Coordinator{id: "moku", applied: &SessionConfiguration{}, injection: &plugin.Injection{}, config: Configuration{
		Settings: func() (model.Settings, int64, error) {
			if offline {
				return model.Settings{}, 0, errors.New("settings offline")
			}
			return model.Settings{}, 0, nil
		},
		Threads:           func() ([]model.ThreadRecord, error) { return []model.ThreadRecord{host, terminal}, nil },
		Thread:            func(string) (model.ThreadRecord, error) { return host, nil },
		PendingDeliveries: func() ([]plugin.MokuDelivery, error) { return pending, nil },
		SendDelivery: func(_ context.Context, id, owner string, input model.AgentInput, _ *plugin.Injection, _ []plugin.ContextEntry) (SendResult, error) {
			sends++
			if id != "delivery" || owner != "moku" || input.Presentation != "internal" || !strings.Contains(input.Parts[0].Text, "completed") {
				t.Errorf("wrong terminal delivery: %+v", input)
			}
			pending = nil
			return SendResult{ExecutionID: "accepted"}, nil
		},
		ReportFailure: func(_ string, err error) { reports = append(reports, err.Error()) },
	}}
	reported := map[string]string{}
	c.drainDeliveries(t.Context(), reported)
	c.drainDeliveries(t.Context(), reported)
	if sends != 0 || len(pending) != 1 || len(reports) != 1 {
		t.Fatalf("pre-admission failure dropped or spammed: sends=%d pending=%d reports=%v", sends, len(pending), reports)
	}
	offline = false
	c.drainDeliveries(t.Context(), reported)
	c.drainDeliveries(t.Context(), reported)
	if sends != 1 || len(pending) != 0 {
		t.Fatal("retry or receipt deduplication failed")
	}
	pending = []plugin.MokuDelivery{{ID: "uncertain", Thread: terminal, Uncertain: true}}
	c.drainDeliveries(t.Context(), reported)
	c.drainDeliveries(t.Context(), reported)
	if sends != 1 || len(reports) != 2 || !strings.Contains(reports[1], "moku:resolve-delivery") {
		t.Fatalf("uncertain replayed or lacks recovery: %v", reports)
	}
}
