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
		Result      struct {
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
	_, err := send.Execute(mokuReplayContext(), plugin.ToolCall{Arguments: mokuReplayRaw(map[string]string{"threadId": target, "prompt": "follow up"})})
	mokuReplayMust(err)
	followup := snapshot()
	completed = latest(followup)
	mokuReplayCheck(completed.CompletedAt != nil && !completed.IsError && completed.Result.OK && completed.Result.ThreadID == target,
		"runtime snapshot lost successful follow-up acknowledgement")
	// A validation rejection is also a real binding result and must remain failed
	// with its reason intact after the same projection.
	_, err = create.Execute(mokuReplayContext(), plugin.ToolCall{Arguments: json.RawMessage(`{"prompt":"rejected","harnessId":"mock","options":{"model":"first-model"}}`)})
	mokuReplayCheck(err != nil && strings.Contains(err.Error(), "worktree"), "expected missing-worktree rejection")
	failure := snapshot()
	completed = latest(failure)
	mokuReplayCheck(completed.CompletedAt != nil && completed.IsError && strings.Contains(completed.Result.Error, "worktree"),
		"runtime snapshot lost rejected dispatch reason")
	if path := os.Getenv("MOKU_STATUS_NATIVE_FIXTURE"); path != "" {
		mokuReplayMust(os.MkdirAll(filepath.Dir(path), 0o700))
		mokuReplayMust(os.WriteFile(path, mokuReplayRaw([]model.ThreadRecord{success, followup, failure}), 0o600))
	}
	fmt.Println("PASS real runtime snapshot preserves successful dispatch acknowledgement and genuine rejection reason")
}
