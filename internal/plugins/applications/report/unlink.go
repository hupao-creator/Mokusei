package report

import (
	"encoding/json"
	"errors"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

type UnlinkInput struct {
	ReportID         string `json:"reportId"`
	ThreadID         string `json:"threadId"`
	ExecutionID      string `json:"executionId"`
	ExpectedRevision int64  `json:"expectedRevision"`
}

// User authority is removal of one observed link only, never report rewriting,
// deleting a source execution, or silently moving ownership to another report.
func registerUnlink(registry plugin.Registry) error {
	input := typedContract[UnlinkInput]("report.unlink.input", []string{"reportId", "threadId", "executionId", "expectedRevision"}, func(input *UnlinkInput) error {
		if !validID(input.ReportID) || !validID(input.ThreadID) || !validID(input.ExecutionID) || input.ExpectedRevision < 0 || input.ExpectedRevision > model.MaximumSafeInteger {
			return errors.New("Invalid Super Thread unlink request")
		}
		return nil
	})
	return registry.Command(plugin.CommandDefinition{
		Operation: operation("report.unlink", input, summaryContract()), Audience: plugin.CommandAudience{User: true, Background: "deny"},
		Plan: func(_ json.RawMessage, context plugin.ReadContext) ([]plugin.MutationScope, error) {
			scope, err := context.Records.Scope(CollectionID, "")
			return []plugin.MutationScope{scope}, err
		},
		Reduce: func(raw json.RawMessage, context plugin.TransactionContext) (json.RawMessage, error) {
			var input UnlinkInput
			if err := model.Unmarshal(raw, &input); err != nil {
				return nil, err
			}
			record, value, err := requireRecord(input.ReportID, context.Records)
			if err != nil {
				return nil, err
			}
			index := -1
			for i, ref := range value.RelatedExecutions {
				if ref.Thread.ThreadID != input.ThreadID {
					continue
				}
				if ref.ExecutionID != input.ExecutionID || record.Revision != input.ExpectedRevision {
					return nil, model.NewError("SUPER_THREAD_LINK_CHANGED", "报告关联已更新，请查看当前记录后重试。 / The report link changed. Review the current record before retrying.")
				}
				index = i
			}
			if index < 0 {
				return json.Marshal(summarize(record, value))
			}
			value.RelatedExecutions = append(value.RelatedExecutions[:index], value.RelatedExecutions[index+1:]...)
			delete(value.TagSources, input.ThreadID)
			encoded, err := json.Marshal(value)
			if err != nil {
				return nil, err
			}
			saved, err := context.Records.Put(CollectionID, record.ID, encoded, plugin.RecordWriteOptions{ExpectedRevision: &record.Revision, TouchUpdatedAt: true})
			if err != nil {
				return nil, err
			}
			return json.Marshal(summarize(saved, value))
		},
	})
}
