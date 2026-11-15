package pi

import (
	"strings"

	"github.com/hupao-creator/Mokusei/internal/core/model"
)

// readingMessages keeps only content the count-only Agent page renders.
// Follow-ups, visible replies, failures and summary presence facts remain in
// native order; tool output, reasoning bodies and initial/internal input do not.
func readingMessages(messages []MessageState, executions []model.PublicExecution, targetID string) ([]MessageState, []model.Object) {
	active := false
	for _, execution := range executions {
		if !execution.Terminal() {
			active = true
		}
	}
	finalID := ""
	if !active {
		for index := len(messages) - 1; index >= 0; index-- {
			row := messages[index]
			if row.Role == "assistant" && row.Status != "streaming" && row.Status != "failed" && !row.IsError && strings.TrimSpace(row.Text) != "" {
				finalID = row.ID
				break
			}
		}
	}
	result := make([]MessageState, 0, len(messages))
	nonempty := []model.Object{}
	for _, row := range messages {
		switch row.Role {
		case "user":
			if !row.FollowUp || row.Presentation == "internal" {
				continue
			}
			if row.Presentation == "" {
				row.Presentation = "ordinary"
			}
			result = append(result, row)
		case "tool":
			result = append(result, MessageState{
				ID: row.ID, ExecutionID: row.ExecutionID, Role: "tool", Text: "",
				ToolCallID: row.ToolCallID, ToolName: row.ToolName, IsError: row.IsError,
			})
		case "assistant":
			failed := row.IsError || row.Status == "failed"
			visible := failed || row.ID == targetID
			if active {
				visible = visible || row.Status != "streaming" && strings.TrimSpace(row.Text) != ""
			} else {
				visible = visible || row.ID == finalID
			}
			if strings.TrimSpace(row.Thinking) != "" {
				nonempty = append(nonempty, model.Object{"id": row.ID, "field": "thinking"})
			}
			if !visible && strings.TrimSpace(row.Thinking) == "" {
				continue
			}
			projected := row
			projected.Thinking = ""
			projected.Usage = nil
			projected.Todos = nil
			projected.Annotations = nil
			if !visible {
				projected.Text = ""
			}
			result = append(result, projected)
		}
	}
	return result, nonempty
}
