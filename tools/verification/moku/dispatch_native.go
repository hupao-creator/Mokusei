package main

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/services/moku"
)

// Capture both sides of the real create_thread binding. The controlled target
// records admission or returns an error; the Coordinator writes every audit.
func nativeDispatchRecords() ([]model.ThreadRecord, error) {
	w := newOrchestratorWorld()
	config := w.config()
	create := config.CreateThread
	var records []model.ThreadRecord
	fail := false
	config.CreateThread = func(ctx context.Context, request moku.CreateThreadRequest) (moku.CreatedThread, error) {
		records = append(records, w.mokuRecord())
		if fail {
			return moku.CreatedThread{}, errors.New("Fixture target unavailable")
		}
		return create(ctx, request)
	}
	c, err := moku.New(config)
	if err != nil {
		return nil, err
	}
	mokuReplayMust(c.Start(mokuReplayContext(), plugin.RuntimeStartContext{Reason: "manual"}))
	defer stopOrchestrator(c)
	mokuReplayMust(c.Submit(mokuReplayContext(), orchestratorInput("dispatch native replay")))
	prompt := "  输入内容，不是任务标题。\n" + strings.Repeat("保留原始输入 👩🏽‍💻\n", 80)
	arguments := string(mokuReplayRaw(map[string]any{"worktree": false, "harnessId": "mock",
		"prompt": prompt, "options": map[string]string{"model": "mock-model"}}))
	_, err = w.call("create_thread", arguments)
	if err != nil {
		return nil, err
	}
	records = append(records, w.mokuRecord())
	fail = true
	_, err = w.call("create_thread", arguments)
	if err == nil {
		return nil, fmt.Errorf("dispatch fixture accepted failing target")
	}
	records = append(records, w.mokuRecord())
	return records, nil
}
