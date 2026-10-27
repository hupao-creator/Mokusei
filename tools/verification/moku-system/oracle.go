package main

import (
	"encoding/json"
	"fmt"
	"github.com/hupao-creator/Mokusei/internal/core/model"
	"path/filepath"
	"slices"
)

func verifyFanout(state model.AppState, workspaces []string) error {
	children := map[string]model.ThreadRecord{}
	for _, thread := range state.Threads {
		if !thread.Moku {
			children[thread.ID] = thread
		}
	}
	count := max(1, len(workspaces))
	if len(children) != count {
		return fmt.Errorf("expected %d child executions, found %d", count, len(children))
	}
	reports := []model.ApplicationThread{}
	for _, a := range state.ApplicationThreads {
		if a.Ref.TypeID == "report.document" {
			reports = append(reports, a)
		}
	}
	if len(reports) != count {
		return fmt.Errorf("expected %d Reports, found %d", count, len(reports))
	}
	linked := map[string]bool{}
	scopes := map[string]bool{}
	for _, report := range reports {
		var view struct {
			Related []model.ExecutionRef `json:"relatedExecutions"`
			Preview string               `json:"previewText"`
		}
		if err := json.Unmarshal(report.View, &view); err != nil {
			return err
		}
		if len(view.Related) != 1 {
			return fmt.Errorf("unexpected references: %+v", view.Related)
		}
		child, ok := children[view.Related[0].Thread.ThreadID]
		if !ok || child.Observation.LatestExecution == nil || view.Related[0].ExecutionID != child.Observation.LatestExecution.ExecutionID || linked[child.ID] {
			return fmt.Errorf("Report linked wrong/duplicate task execution: %+v", view.Related)
		}
		linked[child.ID] = true
		tagName := "Verified"
		if len(workspaces) > 0 {
			tagName += "_" + filepath.Base(child.Cwd)
		}
		if !slices.Contains(child.Tags, tagName) || !slices.Equal(report.Tags.SemanticTags, []string{tagName}) || report.Tags.TagEmojis[tagName] != "✅" {
			return fmt.Errorf("Report/Tag projection diverged: child=%v report=%+v", child.Tags, report.Tags)
		}
		expected := "inbox"
		if len(workspaces) > 0 {
			expected = child.Cwd
			if !slices.Contains(workspaces, expected) {
				return fmt.Errorf("task escaped planned workspace %q", expected)
			}
		}
		if report.Scope != expected || scopes[expected] {
			return fmt.Errorf("scope isolation failed: report=%q expected=%q", report.Scope, expected)
		}
		scopes[expected] = true
		if view.Preview != "SYSTEM_CHILD_DONE" {
			return fmt.Errorf("Report content mismatch: %q", view.Preview)
		}
	}
	return nil
}
