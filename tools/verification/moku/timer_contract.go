package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

// Production Coordinator -> SQLite -> catalog. The optional fixture is consumed
// by the Swift queue with a fake player; neither side opens a window or audio.
func runTimerRuntimeReplay() error {
	root, err := os.MkdirTemp("", "mokusei-timer-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(root)
	h := &replayNativeHarness{nativeModel: "first-model", wake: make(chan struct{}, 128)}
	s := startReplaySystem(root, h)
	defer s.close()
	mokuReplayMust(s.c.Submit(mokuReplayContext(), mokuReplayText("timer contract")))
	h.awaitTools(1)
	h.mu.Lock()
	handle := h.handles[len(h.handles)-1]
	h.mu.Unlock()
	bindings := map[string]plugin.ToolBinding{}
	for _, binding := range handle.open.Injection.Tools.Bindings {
		bindings[binding.Name] = binding
	}
	snapshot := func() model.ThreadRecord {
		state, err := s.r.Snapshot()
		mokuReplayMust(err)
		for _, thread := range state.Threads {
			if thread.Moku {
				return thread
			}
		}
		panic("Moku missing from timer catalog")
	}
	records := []model.ThreadRecord{snapshot()}
	for _, name := range []string{"timer", "timer", "talk"} {
		result, err := bindings[name].Execute(mokuReplayContext(), plugin.ToolCall{Arguments: mokuReplayRaw(map[string]string{"text": "  已完成\nready 🙂  "})})
		mokuReplayMust(err)
		mokuReplayCheck(string(result) == `{"ok":true}`, "timer/talk did not return immediate success")
		records = append(records, snapshot())
	}
	_, err = bindings["timer"].Execute(mokuReplayContext(), plugin.ToolCall{Arguments: mokuReplayRaw(map[string]string{"text": "\u0085"})})
	mokuReplayCheck(err != nil, "timer accepted whitespace-only text")
	records = append(records, snapshot())
	// Advance the public execution before another catalog publication. Accepted
	// timers must survive the same catch-up boundary used by real successors.
	id := s.record().ID
	mokuReplayMust(s.r.UpdateThread(mokuReplayContext(), id, func(record *model.ThreadRecord) error {
		record.Transcript = append(record.Transcript, mokuReplayRaw(map[string]any{
			"type": "message", "id": "successor-message", "executionId": "successor", "role": "user", "content": "continue"}))
		return nil
	}))
	records = append(records, snapshot())
	count := 0
	for _, raw := range records[len(records)-1].Transcript {
		var item map[string]any
		mokuReplayMust(json.Unmarshal(raw, &item))
		if item["name"] == "timer" {
			count++
		}
	}
	mokuReplayCheck(count == 2, "successor catalog lost completed timers or retained rejection")
	if path := os.Getenv("MOKU_TIMER_NATIVE_FIXTURE"); path != "" {
		mokuReplayMust(os.MkdirAll(filepath.Dir(path), 0o700))
		mokuReplayMust(os.WriteFile(path, mokuReplayRaw(records), 0o600))
	}
	fmt.Println("PASS timer returns after committed audit, preserves exact text, and survives successor catalog publication")
	return nil
}
