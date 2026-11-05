package main

import (
	"context"
	"encoding/json"
	"fmt"
	"path/filepath"
	"strings"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	core "github.com/hupao-creator/Mokusei/internal/core/runtime"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/hosts/applicationhost"
	"github.com/hupao-creator/Mokusei/internal/plugins/applications/attention"
)

func verifyAttentionAgent(ctx context.Context, dir string) {
	db, err := store.Open(filepath.Join(dir, "attention.sqlite"))
	must(err)
	harness := &reportScopeHarness{}
	r, err := core.New(ctx, core.Config{Store: db, Harnesses: map[string]plugin.Harness{"fixture": harness}, DataDir: dir, DefaultCwd: dir})
	must(err)
	defer func() { must(r.Close(ctx)); must(db.Close()) }()
	app, err := applicationhost.New(ctx, applicationhost.Config{Store: db, Applications: []plugin.Application{attention.New()}, RuntimeCapabilities: r.RuntimeCapabilities, BackgroundCapabilities: r.BackgroundCapabilities, SnapshotCapabilities: r.SnapshotCapabilities})
	must(err)
	r.SetApplications(app)
	must(app.Start(ctx, plugin.RuntimeStartContext{Reason: "startup"}))
	for i := 0; i < 20; i++ {
		_, err := r.CreateThread(ctx, core.CreateThreadRequest{HarnessID: "fixture", Input: model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "private-fixture-body"}}}})
		must(err)
	}
	var h *handle
	var facts []struct {
		ThreadID string
		Revision int
	}
	waitFor(func() bool {
		h = harness.latest("attention.agent")
		if h == nil {
			return false
		}
		var s state
		if json.Unmarshal(h.open.SessionState.Read(), &s) != nil || len(s.Messages) == 0 {
			return false
		}
		message := s.Messages[len(s.Messages)-1]
		_, rest, ok := strings.Cut(message, "): ")
		if !ok {
			return false
		}
		if strings.Contains(message, "private-fixture-body") {
			panic("attention exposed native source")
		}
		return json.Unmarshal([]byte(rest), &facts) == nil && len(facts) > 0
	})
	target := facts[0]
	val, err := reportTool(ctx, h, "hide_thread", "hide-selected", model.Object{"threadId": target.ThreadID, "revision": target.Revision})
	must(err)
	if string(val) != "true" {
		panic("attention hide rejected: " + string(val))
	}
	finishReportFixture(ctx, h, "completed")
	waitFor(func() bool {
		s, err := r.Snapshot()
		must(err)
		count := 0
		for _, t := range s.Threads {
			if t.AttentionHidden {
				count++
				if t.ID != target.ThreadID {
					panic("hid an unselected thread")
				}
			}
		}
		return count == 1
	})
	_, err = r.Invoke(ctx, "thread:record-visit", []json.RawMessage{raw(model.Object{"threadId": target.ThreadID, "visitId": "31000000-0000-4000-8000-000000000001", "elapsed": 0, "foreground": true, "completedExecution": "", "alreadyVisible": false, "searchOpen": true})})
	must(err)
	waitFor(func() bool {
		s, err := r.Snapshot()
		must(err)
		for _, t := range s.Threads {
			if t.ID == target.ThreadID {
				return !t.AttentionHidden
			}
		}
		return false
	})
	fmt.Println("PASS attention threshold, private model evidence, receipt-bound hide and search recovery")
}
