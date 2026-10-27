package main

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
)

func verifyHistoryDrain() {
	for _, mode := range []string{"history-drain", "history-fail", "history-residual", "history-cancelled"} {
		fixtureMode := mode
		if mode == "history-cancelled" {
			fixtureMode = "history-drain"
		}
		r, h, cleanup := setup(fixtureMode)
		c, err := create(r)
		must(err)
		n := receive(h.opened)
		var s state
		must(json.Unmarshal(n.open.SessionState.Read(), &s))
		s.Observation.BackgroundWork = &model.PublicBackgroundWork{Status: "running"}
		must(n.open.SessionState.Commit(context.Background(), raw(s)))
		oldSettings, revision, err := r.Settings()
		must(err)
		ctx, cancel := context.WithCancel(context.Background())
		done := make(chan error, 1)
		go func() { done <- r.ClearHistory(ctx) }()
		if fixtureMode == "history-drain" {
			receive(n.closeEntered)
			// The persistent history remains readable throughout native cleanup.
			current, err := r.Thread(c.Record.ID)
			must(err)
			assert(current.Observation.BackgroundWork != nil, "history disappeared before native cleanup completed")
			_, err = create(r)
			assert(err != nil, "history drain admitted competing native work")
			select {
			case <-done:
				panic("clear returned before native cleanup joined")
			case <-time.After(50 * time.Millisecond):
			}
			if mode == "history-cancelled" {
				cancel()
			}
			close(n.closeRelease)
		}
		err = receive(done)
		cancel()
		if mode == "history-drain" {
			must(err)
			_, err = r.Thread(c.Record.ID)
			assert(err != nil, "drained clear retained old history")
		} else {
			assert(err != nil, "unconfirmed/cancelled clear reported success")
			_, readErr := r.Thread(c.Record.ID)
			must(readErr)
			if mode == "history-fail" {
				assert(strings.Contains(err.Error(), "fixture native stop refused"), "cleanup cause missing")
			}
			if mode == "history-residual" {
				assert(strings.Contains(err.Error(), "history was kept"), "residual native work error unclear")
			}
			_, err = create(r)
			assert(err != nil, "failed drain installed competing owner")
		}
		settings, afterRevision, err := r.Settings()
		must(err)
		assert(string(raw(settings)) == string(raw(oldSettings)) && revision == afterRevision, "history reset modified settings")
		err = n.open.SessionState.Commit(context.Background(), n.open.SessionState.Read())
		assert(err != nil, "retired history owner retained write authority")
		cleanup()
		fmt.Println("history cleanup/atomicity", mode+": passed")
	}
}
