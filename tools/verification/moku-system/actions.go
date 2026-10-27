package main

import (
	"bytes"
	"context"
	"fmt"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
)

type systemInvoke func(string, []any, any) error
type actionHost interface {
	Thread(string) (model.ThreadRecord, error)
	DeleteThread(context.Context, string) error
}

// Actions use the public API (or Runtime.DeleteThread, which has no public
// command) and compare against the previous observed state. No expected mutation
// is implemented by editing SQLite or native transcripts.
func exerciseActions(ctx context.Context, invoke systemInvoke, host actionHost, mock *provider, state model.AppState, actions []string) (model.AppState, error) {
	for index, action := range actions {
		started := time.Now()
		deadline, _ := ctx.Deadline()
		fmt.Printf("ACTION action[%d]=%s startedAt=%s remaining=%s\n", index, action, started.UTC().Format(time.RFC3339Nano), time.Until(deadline))
		before := state
		switch action {
		case "followup", "fork", "interrupt", "delete", "clear", "delete-active", "clear-active", "recreate":
			next, err := exerciseLifecycle(ctx, invoke, host, mock, state, action, index)
			fmt.Printf("ACTION action[%d]=%s elapsed=%s error=%v\n", index, action, time.Since(started), err)
			if err != nil {
				return state, fmt.Errorf("action[%d]=%s: %w", index, action, err)
			}
			state = next
			continue
		}
		children := []model.ThreadRecord{}
		for _, t := range before.Threads {
			if !t.Moku {
				durable, err := host.Thread(t.ID)
				if err != nil {
					return state, err
				}
				children = append(children, durable)
			}
		}
		if len(children) == 0 {
			return state, fmt.Errorf("action %s has no source task", action)
		}
		switch action {
		case "read":
			for _, child := range children {
				var answer string
				if err := invoke("thread:read", []any{object{"threadId": child.ID, "question": "What is the exact SYSTEM_CHAIN_CHILD result?"}}, &answer); err != nil {
					return state, err
				}
				if answer != "SYSTEM_CHILD_DONE" {
					return state, fmt.Errorf("source read returned %q", answer)
				}
			}
		case "archive", "unarchive":
			archived := action == "archive"
			for _, child := range children {
				if err := invoke("thread:set-archived", []any{child.ID, archived}, nil); err != nil {
					return state, err
				}
			}
			for _, report := range before.ApplicationThreads {
				if report.Ref.TypeID == "report.document" {
					if err := invoke("application:archive", []any{report.Ref, archived}, nil); err != nil {
						return state, err
					}
				}
			}
		case "settings":
			next := before.Settings
			prompt := fmt.Sprintf("SYSTEM_CONFIGURATION_%d", index)
			next.Moku.RoutingGuidance = &prompt
			var saved struct {
				Status           string
				SettingsRevision int64
			}
			request := object{"expectedSettingsRevision": before.SettingsRevision, "settings": next}
			if err := invoke("app:update-settings", []any{request}, &saved); err != nil {
				return state, err
			}
			if saved.Status != "saved" || saved.SettingsRevision != before.SettingsRevision+1 {
				return state, fmt.Errorf("settings CAS save mismatch: %+v", saved)
			}
			var stale struct {
				Status           string
				SettingsRevision int64
			}
			if err := invoke("app:update-settings", []any{request}, &stale); err != nil {
				return state, err
			}
			if stale.Status != "conflict" || stale.SettingsRevision != saved.SettingsRevision {
				return state, fmt.Errorf("stale settings write accepted: %+v", stale)
			}
		default:
			return state, fmt.Errorf("unsupported system action %q", action)
		}
		var next model.AppState
		if err := invoke("state:load", []any{}, &next); err != nil {
			return state, err
		}
		state = next
		if len(state.Threads) != len(before.Threads) || len(state.ApplicationThreads) != len(before.ApplicationThreads) {
			return state, fmt.Errorf("%s changed task/report cardinality", action)
		}
		for _, expected := range children {
			found := false
			for _, actual := range state.Threads {
				if expected.ID == actual.ID {
					found = true
					durable, err := host.Thread(actual.ID)
					if err != nil {
						return state, err
					}
					if !bytes.Equal(encoded(expected.Observation.LatestExecution), encoded(actual.Observation.LatestExecution)) || !bytes.Equal(expected.Settings, durable.Settings) || !bytes.Equal(expected.SessionState, durable.SessionState) {
						return state, fmt.Errorf("%s mutated source execution/settings/history %s", action, actual.ID)
					}
					if action == "archive" || action == "unarchive" {
						if (actual.Archived != nil && *actual.Archived) != (action == "archive") {
							return state, fmt.Errorf("%s not applied to task", action)
						}
					}
				}
			}
			if !found {
				return state, fmt.Errorf("%s lost source", action)
			}
		}
		for _, report := range state.ApplicationThreads {
			if report.Ref.TypeID == "report.document" && (action == "archive" || action == "unarchive") && report.Archived != (action == "archive") {
				return state, fmt.Errorf("%s not applied to Report", action)
			}
		}
		fmt.Printf("PASS action[%d]=%s: source execution/history/settings preserved elapsed=%s\n", index, action, time.Since(started))
	}
	return state, nil
}
