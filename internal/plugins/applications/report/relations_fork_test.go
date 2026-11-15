package report

import (
	"errors"
	"testing"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

type relationRecords struct{}

func (relationRecords) Get(string, string) (*model.VersionedRecord, error) { return nil, nil }
func (relationRecords) List(string) ([]model.VersionedRecord, error)       { return nil, nil }
func (relationRecords) Count(string) (int, error)                          { return 0, nil }
func (relationRecords) LookupIDs(string, string, string) ([]string, error) {
	return []string{"report"}, nil
}
func (relationRecords) Scope(string, string) (plugin.MutationScope, error) {
	return plugin.MutationScope{}, nil
}

type relationAccess struct {
	tasks plugin.OrdinaryTaskSnapshotCapability
}

func (a relationAccess) Require(key plugin.CapabilityKey) (any, error) {
	if key == plugin.OrdinaryTaskSnapshotCapabilityKey {
		return a.tasks, nil
	}
	return nil, errors.New("unexpected capability")
}

type relationTasks struct {
	execution model.PublicExecution
}

func (relationTasks) Scope(model.ThreadRef) (plugin.MutationScope, error) {
	return plugin.MutationScope{}, nil
}
func (t relationTasks) Get(model.ThreadRef) (*plugin.OrdinaryTaskSnapshot, error) {
	return &plugin.OrdinaryTaskSnapshot{Scope: "inbox", Ref: model.ThreadRef{ThreadID: "thread", TypeID: "agent"},
		Title: "Forked", HarnessID: "codex", Cwd: "/fixture", ExecutionCwd: "/fixture",
		Observation: model.PublicObservation{LatestExecution: &model.PublicExecution{ExecutionID: "successor", Status: "running", StartedAt: 10}}}, nil
}
func (t relationTasks) ResolveExecution(ref model.ExecutionRef) (*model.PublicExecution, error) {
	if ref.Thread.ThreadID != "thread" || ref.ExecutionID != t.execution.ExecutionID {
		return nil, nil
	}
	execution := t.execution
	return &execution, nil
}

func TestRelationsResolveCitedForkExecutionTiming(t *testing.T) {
	finished := int64(9)
	execution := model.PublicExecution{ExecutionID: "inherited", Status: "completed", StartedAt: 5, FinishedAt: &finished}
	context := plugin.ReadContext{Records: relationRecords{}, Capabilities: relationAccess{tasks: relationTasks{execution: execution}}}
	value := Data{Scope: "inbox", RelatedExecutions: []model.ExecutionRef{{
		Thread: model.ThreadRef{ThreadID: "thread", TypeID: "agent"}, ExecutionID: "inherited",
	}}}
	relations, err := relatedExecutions(model.VersionedRecord{ID: "report", Revision: 3}, value, context)
	if err != nil {
		t.Fatal(err)
	}
	if len(relations.Items) != 1 {
		t.Fatalf("relations = %+v", relations)
	}
	item := relations.Items[0]
	if item.Unavailable != "" || item.Execution == nil {
		t.Fatalf("cited fork execution marked unavailable: %+v", item)
	}
	if item.Execution.ExecutionID != "inherited" || item.Execution.FinishedAt == nil || *item.Execution.FinishedAt != finished {
		t.Fatalf("cited fork timing lost: %+v", item.Execution)
	}
	if item.Thread == nil || item.Thread.CurrentExecution == nil || item.Thread.CurrentExecution.ExecutionID != "successor" {
		t.Fatalf("current Thread facts were replaced by the cited execution: %+v", item.Thread)
	}
}
