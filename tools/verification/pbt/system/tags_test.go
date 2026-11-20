package system_test

import (
	"context"
	"encoding/json"
	"fmt"
	"path/filepath"
	"strings"

	"github.com/hupao-creator/Chief/internal/core/plugin"
)

// The model peer discovers stable IDs and CAS revisions only from actual scoped
// tool results. Global fixture identities are used solely for rejection probes.
func (p *provider) tagPlan(ctx context.Context, input any, prefix string) (string, string, object, error) {
	initial := prefix + "_tag_status"
	if !hasResult(input, initial) {
		return "read_statusbar", initial, object{}, nil
	}
	var status plugin.TagStatusbar
	for _, raw := range list(input) {
		item := record(raw)
		id := text(item["call_id"])
		if item["type"] != "function_call_output" || !strings.HasPrefix(id, prefix+"_tag_") {
			continue
		}
		value, err := resultJSON(input, id)
		if err != nil {
			return "", "", nil, err
		}
		result := record(value)
		if nested := result["statusbar"]; nested != nil {
			if result["status"] != "applied" && result["status"] != "conflict" {
				return "", "", nil, fmt.Errorf("invalid Tag mutation status: %v", result)
			}
			value = nested
		}
		if err := json.Unmarshal(encoded(value), &status); err != nil {
			return "", "", nil, err
		}
	}
	if status.Revision == "" || status.Capacity != 5 || status.Pool == "" {
		return "", "", nil, fmt.Errorf("missing authoritative Tag statusbar")
	}
	name := "Verified"
	if len(p.workspaces) > 1 {
		name += "_" + filepath.Base(status.Pool)
	}
	tagID := ""
	for _, tag := range status.Tags {
		if tag.Name == name {
			tagID = tag.ID
		}
	}
	version := prefix + "_tag_" + status.Revision
	if tagID == "" {
		return "create_tag", version + "_create", object{"name": name, "emoji": "✅", "expectedRevision": status.Revision}, nil
	}
	if len(p.workspaces) > 1 && len(status.Threads) > 0 {
		probe := prefix + "_foreign_assign"
		own := status.Threads[0].ID
		if !hasResult(input, probe) {
			foreign, err := p.foreignThread(ctx, own)
			if err != nil {
				return "", "", nil, err
			}
			return "assign_threads", probe, object{"expectedRevision": status.Revision, "assignments": []any{object{"threadId": foreign, "tagId": tagID}}}, nil
		}
		if err := expectToolError(input, probe); err != nil {
			return "", "", nil, err
		}
		p.markScopeProof("tag-write", own)
	}
	assigned := map[string]string{}
	for _, item := range status.Assignments {
		assigned[item.ThreadID] = item.TagID
	}
	assignments := []any{}
	for _, thread := range status.Threads {
		if assigned[thread.ID] != tagID {
			assignments = append(assignments, object{"threadId": thread.ID, "tagId": tagID})
		}
	}
	if len(assignments) > 0 {
		return "assign_threads", version + "_assign", object{"expectedRevision": status.Revision, "assignments": assignments}, nil
	}
	verified := version + "_verified"
	if !hasResult(input, verified) {
		return "read_statusbar", verified, object{}, nil
	}
	return "", "", nil, nil
}
