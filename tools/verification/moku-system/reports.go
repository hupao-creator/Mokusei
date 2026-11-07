package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"html"
	"strings"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/plugins/applications/report"
)

func resultPage(input any, id string, target any) error {
	value, err := resultJSON(input, id)
	if err != nil {
		return err
	}
	page := record(value)
	if page["nextOffset"] != nil {
		return fmt.Errorf("fixture requires a complete evidence page: %s", id)
	}
	return json.Unmarshal([]byte(text(page["text"])), target)
}

// Discover ownership through scoped tools and base an edit on the full read,
// never on a list-summary revision or a child ID shared by the test oracle.
func reportWritePlan(input any, prefix, threadID string, execution object) (tool, call string, args object, err error) {
	listID := prefix + "_reports"
	if !hasResult(input, listID) {
		return "list_reports", listID, object{"limit": 64000}, nil
	}
	var inventory struct {
		Reports []object `json:"reports"`
	}
	if err := resultPage(input, listID, &inventory); err != nil {
		return "", "", nil, err
	}
	var owner object
	for _, summary := range inventory.Reports {
		id := text(summary["id"])
		readID := prefix + "_report_" + strings.ReplaceAll(id, "-", "")
		if !hasResult(input, readID) {
			return "read_report", readID, object{"reportId": id, "limit": 64000}, nil
		}
		var full object
		if err := resultPage(input, readID, &full); err != nil {
			return "", "", nil, err
		}
		if full["id"] != id || text(full["html"]) == "" || full["revision"] == nil {
			return "", "", nil, fmt.Errorf("incomplete Report read: %v", full)
		}
		for _, raw := range list(full["relatedExecutions"]) {
			if record(raw)["threadId"] == threadID {
				if owner != nil || len(list(full["relatedExecutions"])) != 1 {
					return "", "", nil, fmt.Errorf("fixture Thread has ambiguous Report ownership: %s", threadID)
				}
				owner = full
			}
		}
	}
	writeID := prefix + "_report_write"
	if hasResult(input, writeID) {
		result, err := resultJSON(input, writeID)
		if err != nil {
			return "", "", nil, err
		}
		if text(record(result)["id"]) == "" || (owner != nil && record(result)["id"] != owner["id"]) {
			return "", "", nil, fmt.Errorf("Report write changed owner identity: %v", result)
		}
		return "", "", nil, nil
	}
	textEvidence := html.EscapeString(text(execution["summary"]))
	executionID := html.EscapeString(text(execution["executionId"]))
	args = object{"emoji": "📊", "shortDescription": "Summary of completed system chain work", "title": "System chain report", "html": "<html><body><p data-execution-id=\"" + executionID + "\">" + textEvidence + "</p></body></html>", "coverHTML": "<div data-execution-id=\"" + executionID + "\">" + textEvidence + "</div>", "relatedExecutions": []any{object{"threadId": threadID, "executionId": execution["executionId"]}}}
	if owner != nil {
		args["reportId"], args["expectedRevision"] = owner["id"], owner["revision"]
		return "update_report", writeID, args, nil
	}
	return "create_report", writeID, args, nil
}

func reportForThread(state model.AppState, threadID string) (model.ApplicationThread, report.View, error) {
	var owner model.ApplicationThread
	var ownerView report.View
	for _, candidate := range state.ApplicationThreads {
		if candidate.Ref.TypeID != "report.document" {
			continue
		}
		var view report.View
		if err := json.Unmarshal(candidate.View, &view); err != nil {
			return owner, ownerView, err
		}
		for _, reference := range view.RelatedExecutions {
			if reference.Thread.ThreadID == threadID {
				if owner.ID != "" || len(view.RelatedExecutions) != 1 {
					return owner, ownerView, fmt.Errorf("Thread has multiple Report owners or references: %s", threadID)
				}
				owner, ownerView = candidate, view
			}
		}
	}
	return owner, ownerView, nil
}

// Source deletion can update directory tags and record revisions. It must not
// rewrite the preserved document, its identity, or its execution references.
func unchangedReports(before, after model.AppState, except string) error {
	for _, previous := range before.ApplicationThreads {
		if previous.Ref.TypeID != "report.document" || previous.ID == except {
			continue
		}
		found := false
		for _, next := range after.ApplicationThreads {
			if next.Ref == previous.Ref {
				found = true
				if next.ID != previous.ID || !bytes.Equal(previous.View, next.View) {
					return fmt.Errorf("operation rewrote preserved Report evidence: %s", previous.ID)
				}
			}
		}
		if !found {
			return fmt.Errorf("operation lost preserved Report: %s", previous.ID)
		}
	}
	return nil
}
