package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

// Exercise the actual catalog boundary, not the full stored transcript used by
// the coordinator. Swift consumes these same snapshots in its optional interop test.
func verifyDispatchStatusSnapshots(s *replaySystem, create, send plugin.ToolBinding, target string) {
	snapshot := func() model.ThreadRecord {
		state, err := s.r.Snapshot()
		mokuReplayMust(err)
		for _, thread := range state.Threads {
			if thread.Moku {
				return thread
			}
		}
		panic("snapshot omitted Moku")
	}
	type outcome struct {
		CompletedAt *int64 `json:"completedAt"`
		IsError     bool   `json:"isError"`
		Arguments   struct {
			Target map[string]map[string]any `json:"target"`
		} `json:"arguments"`
		Result struct {
			OK       bool   `json:"ok"`
			ThreadID string `json:"threadId"`
			Error    string `json:"error"`
		} `json:"result"`
	}
	latest := func(thread model.ThreadRecord) outcome {
		var completed outcome
		mokuReplayMust(json.Unmarshal(thread.Transcript[len(thread.Transcript)-1], &completed))
		return completed
	}
	success := snapshot()
	completed := latest(success)
	mokuReplayCheck(completed.CompletedAt != nil && !completed.IsError && completed.Result.OK && completed.Result.ThreadID != "",
		"runtime snapshot lost successful dispatch acknowledgement")
	mokuReplayCheck(len(completed.Arguments.Target) == 1 && completed.Arguments.Target["mock"]["model"] == "first-model",
		"runtime snapshot lost the selected dispatch target")
	_, err := send.Execute(mokuReplayContext(), plugin.ToolCall{Arguments: mokuReplayRaw(map[string]string{"threadId": target, "prompt": "follow up"})})
	mokuReplayMust(err)
	followup := snapshot()
	completed = latest(followup)
	mokuReplayCheck(completed.CompletedAt != nil && !completed.IsError && completed.Result.OK && completed.Result.ThreadID == target,
		"runtime snapshot lost successful follow-up acknowledgement")
	// A validation rejection is also a real binding result and must remain failed
	// with its reason intact after the same projection.
	_, err = create.Execute(mokuReplayContext(), plugin.ToolCall{Arguments: json.RawMessage(`{"prompt":"rejected","target":{"mock":{"model":"first-model"}}}`)})
	mokuReplayCheck(err != nil && strings.Contains(err.Error(), "worktree"), "expected missing-worktree rejection")
	failure := snapshot()
	completed = latest(failure)
	mokuReplayCheck(completed.CompletedAt != nil && completed.IsError && strings.Contains(completed.Result.Error, "worktree"),
		"runtime snapshot lost rejected dispatch reason")
	// Rejected calls still carry caller-controlled native data. Exercise the real
	// binding, persisted audit and catalog projection before Swift reads the fixture.
	longModel, extra := strings.Repeat("界", 300), strings.Repeat("x", 32*1024)
	_, err = create.Execute(mokuReplayContext(), plugin.ToolCall{Arguments: mokuReplayRaw(map[string]any{
		"prompt": "rejected native options", "worktree": false,
		"target": map[string]any{"mock": map[string]any{
			"model": longModel, "provider": "fixture-provider", "ignored": extra,
			"thinking": map[string]any{"mode": "effort", "effort": "high", "ignored": "not a display field"},
		}},
	})})
	mokuReplayCheck(err != nil, "fixture unexpectedly accepted unsupported native options")
	bounded := snapshot()
	completed = latest(bounded)
	options := completed.Arguments.Target["mock"]
	thinking, _ := options["thinking"].(map[string]any)
	mokuReplayCheck(completed.IsError && len(completed.Arguments.Target) == 1 && len(options) == 3 &&
		options["model"] == strings.Repeat("界", 256) && options["provider"] == "fixture-provider" &&
		len(thinking) == 2 && thinking["mode"] == "effort" && thinking["effort"] == "high",
		"runtime snapshot lost bounded target display fields or forwarded other native options")
	stored, err := s.r.Thread(bounded.ID)
	mokuReplayMust(err)
	original := latest(stored).Arguments.Target["mock"]
	mokuReplayCheck(original["model"] == longModel && original["ignored"] == extra,
		"catalog projection changed the full stored dispatch request")
	if path := os.Getenv("MOKU_STATUS_NATIVE_FIXTURE"); path != "" {
		mokuReplayMust(os.MkdirAll(filepath.Dir(path), 0o700))
		mokuReplayMust(os.WriteFile(path, mokuReplayRaw([]model.ThreadRecord{success, followup, failure, bounded}), 0o600))
	}
	fmt.Println("PASS real runtime snapshot preserves dispatch acknowledgement, rejection reason and bounded target display fields without changing the stored request")
}
