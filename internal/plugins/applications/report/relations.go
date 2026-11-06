package report

import (
	"encoding/json"
	"fmt"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

// The host plans the whole collection and runs reducers in its single writer.
// Checking here covers concurrent creates/updates, including archived documents,
// without a second ownership index that could drift from retained report data.
func validateBindings(rows []model.VersionedRecord, reportID string, previous, next []model.ExecutionRef) error {
	retained := map[model.ExecutionRef]bool{}
	for _, ref := range previous {
		retained[ref] = true
	}
	wanted := map[string]bool{}
	for _, ref := range next {
		// Existing ambiguous bindings may be retained unchanged or removed. Never
		// silently choose a winner or prevent editing the preserved report body.
		if !retained[ref] {
			wanted[ref.Thread.ThreadID] = true
		}
	}
	if len(wanted) == 0 {
		return nil
	}
	for _, row := range rows {
		if row.ID == reportID {
			continue
		}
		value, err := ParseData(row.Value)
		if err != nil {
			return err
		}
		for _, ref := range value.RelatedExecutions {
			if wanted[ref.Thread.ThreadID] {
				return model.NewError("SUPER_THREAD_BINDING_CONFLICT", fmt.Sprintf("Thread %s 已绑定 Super Thread %s。请更新原 Super Thread，或先从原报告解除关联后再绑定；原有报告和执行记录均已保留。 / This Thread already belongs to Super Thread %s. Update that Super Thread, or unlink it there before rebinding. Existing reports and executions are preserved.", ref.Thread.ThreadID, row.ID, row.ID))
			}
		}
	}
	return nil
}

// ExecutionFacts deliberately excludes interaction forms and opaque histories.
// Current execution facts never fill a missing referenced execution.
type ExecutionFacts struct {
	ExecutionID string  `json:"executionId"`
	Status      string  `json:"status"`
	StartedAt   int64   `json:"startedAt"`
	FinishedAt  *int64  `json:"finishedAt,omitempty"`
	Summary     *string `json:"summary,omitempty"`
}

func executionFacts(value *model.PublicExecution, includeSummary bool) *ExecutionFacts {
	if value == nil {
		return nil
	}
	facts := &ExecutionFacts{ExecutionID: value.ExecutionID, Status: value.Status, StartedAt: value.StartedAt, FinishedAt: value.FinishedAt}
	if includeSummary && value.Summary != nil {
		text := []rune(*value.Summary)
		if len(text) > 2000 {
			text = append(text[:2000], []rune("… [truncated]")...)
		}
		summary := string(text)
		facts.Summary = &summary
	}
	return facts
}

type RelatedThread struct {
	Title             string          `json:"title"`
	HarnessID         string          `json:"harnessId"`
	Cwd               string          `json:"cwd"`
	ExecutionCwd      string          `json:"executionCwd"`
	Archived          bool            `json:"archived"`
	CurrentExecution  *ExecutionFacts `json:"currentExecution"`
	BackgroundRunning bool            `json:"backgroundRunning"`
}

type RelatedExecution struct {
	Reference    model.ExecutionRef `json:"reference"`
	Thread       *RelatedThread     `json:"thread"`
	Execution    *ExecutionFacts    `json:"execution"`
	Unavailable  string             `json:"unavailable"`
	BindingCount int                `json:"bindingCount"`
}

type Relations struct {
	ReportID string             `json:"reportId"`
	Revision int64              `json:"revision"`
	Items    []RelatedExecution `json:"items"`
}

// Both the reader and Moku use this snapshot query, so legacy conflicts, missing
// sources and exact-execution identity have a single interpretation.
func relatedExecutions(record model.VersionedRecord, value Data, context plugin.ReadContext) (Relations, error) {
	result := Relations{ReportID: record.ID, Revision: record.Revision, Items: []RelatedExecution{}}
	tasks, err := plugin.Require[plugin.OrdinaryTaskSnapshotCapability](context.Capabilities, plugin.OrdinaryTaskSnapshotCapabilityKey)
	if err != nil {
		return result, err
	}
	rows, err := context.Records.List(CollectionID)
	if err != nil {
		return result, err
	}
	counts := map[string]int{}
	for _, ref := range value.RelatedExecutions {
		counts[ref.Thread.ThreadID] = 0
	}
	for _, row := range rows {
		data, err := ParseData(row.Value)
		if err != nil {
			return result, err
		}
		for _, ref := range data.RelatedExecutions {
			if _, wanted := counts[ref.Thread.ThreadID]; wanted {
				counts[ref.Thread.ThreadID]++
			}
		}
	}
	for _, ref := range value.RelatedExecutions {
		item := RelatedExecution{Reference: ref, BindingCount: counts[ref.Thread.ThreadID]}
		task, err := tasks.Get(ref.Thread)
		if err != nil {
			return result, err
		}
		switch {
		case task == nil:
			item.Unavailable = "thread-missing"
		case task.Scope != value.Scope:
			item.Unavailable = "outside-scope"
		default:
			item.Thread = &RelatedThread{Title: task.Title, HarnessID: task.HarnessID, Cwd: task.Cwd, ExecutionCwd: task.ExecutionCwd, Archived: task.Archived,
				CurrentExecution: executionFacts(task.Observation.LatestExecution, false), BackgroundRunning: task.Observation.BackgroundWork != nil}
			execution, err := tasks.ResolveExecution(ref)
			if err != nil {
				return result, err
			}
			if execution == nil || execution.ExecutionID != ref.ExecutionID {
				item.Unavailable = "execution-missing"
			} else {
				item.Execution = executionFacts(execution, true)
			}
		}
		result.Items = append(result.Items, item)
	}
	return result, nil
}

func registerContextQueries(registry plugin.Registry) error {
	for _, id := range []string{"report.relations", "report.context"} {
		if err := registry.Query(plugin.QueryDefinition{
			Operation: operation(id, identityContract(id+".input"), typedContract[model.Object](id+".output", nil, nil)),
			Audience:  plugin.QueryAudience{User: true}, Requires: []plugin.CapabilityKey{plugin.OrdinaryTaskSnapshotCapabilityKey},
			Read: func(raw json.RawMessage, context plugin.ReadContext) (json.RawMessage, error) {
				var input IdentityInput
				if err := model.Unmarshal(raw, &input); err != nil {
					return nil, err
				}
				record, value, err := requireRecord(input.ReportID, context.Records)
				if err != nil {
					return nil, err
				}
				relations, err := relatedExecutions(record, value, context)
				if err != nil {
					return nil, err
				}
				if id == "report.relations" {
					return json.Marshal(relations)
				}
				return json.Marshal(model.Object{"source": "super-thread", "reportId": record.ID, "revision": record.Revision,
					"title": value.Title, "scope": value.Scope, "html": value.HTML, "contentRevision": value.ContentRevision, "relations": relations.Items})
			},
		}); err != nil {
			return err
		}
	}
	return nil
}
