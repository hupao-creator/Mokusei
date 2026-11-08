package main

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/services/moku"
)

func replayOrchestratorCommitOrder() {
	for _, terminalObserved := range []bool{true, false} {
		replayDelayedMokuCommit(terminalObserved)
	}
	fmt.Println("PASS reordered Moku commits preserve successor tools and still settle older terminal audits")
}

func replayDelayedMokuCommit(terminalObserved bool) {
	w := newOrchestratorWorld()
	config := w.config()
	var diagnostic func(string)
	config.SubscribeDiagnostics = func(listener func(string)) func() {
		diagnostic = listener
		return func() {}
	}
	var gate sync.Mutex
	armed := false
	entered, release := make(chan struct{}), make(chan struct{})
	var releaseOnce sync.Once
	releaseCallback := func() { releaseOnce.Do(func() { close(release) }) }
	subscribe := config.SubscribeCommitted
	config.SubscribeCommitted = func(listener func(model.ThreadRecord)) func() {
		return subscribe(func(record model.ThreadRecord) {
			gate.Lock()
			wait := armed && record.Moku && record.Observation.LatestExecution != nil && record.Observation.LatestExecution.Terminal()
			if wait {
				armed = false
			}
			gate.Unlock()
			if wait {
				// The fixture has already committed the snapshot. Hold only its
				// subscriber delivery, as Runtime's post-transaction notify can.
				close(entered)
				<-release
			}
			listener(record)
		})
	}
	c, err := moku.New(config)
	mokuReplayMust(err)
	mokuReplayMust(c.Start(mokuReplayContext(), plugin.RuntimeStartContext{Reason: "manual"}))
	defer stopOrchestrator(c)
	defer releaseCallback()
	mokuReplayMust(c.Submit(mokuReplayContext(), orchestratorInput("first execution before delayed callback")))
	first := w.mokuRecord()
	raw, err := w.call("create_thread", `{"worktree":false,"prompt":"read target","harnessId":"mock","options":{"model":"mock-model"}}`)
	mokuReplayMust(err)
	var child struct {
		ThreadID string `json:"threadId"`
	}
	mokuReplayMust(json.Unmarshal(raw, &child))
	barrier := func(label string) {
		diagnostic(label)
		w.wait(label, func() bool {
			for _, raw := range w.mokuRecord().Transcript {
				if strings.Contains(string(raw), label) {
					return true
				}
			}
			return false
		})
	}
	if terminalObserved {
		mokuReplayMust(w.terminal(mokuReplayContext(), first.ID, "completed"))
		// Drain the first terminal event before delaying its metadata copy.
		// Otherwise a concurrent audit commit could repair a wrongly erased
		// successor scope before the next tool invocation observes the defect.
		barrier("first terminal settlement drained")
	} else {
		addTerminalQueueAudit(w, first.ID, first.Observation.LatestExecution.ExecutionID)
	}
	gate.Lock()
	armed = true
	gate.Unlock()
	delayed := make(chan error, 1)
	go func() {
		if !terminalObserved {
			delayed <- w.terminal(mokuReplayContext(), first.ID, "completed")
			return
		}
		delayed <- w.update(mokuReplayContext(), first.ID, func(record *model.ThreadRecord) error {
			now := time.Now().UnixMilli()
			record.Note = &model.ThreadNote{ID: "00000000-0000-4000-8000-000000000001", Revision: 1, ReadingRevision: 1, Text: "Exposed note", UpdatedAt: now,
				LastExposure: &model.NoteExposure{Revision: 1, Text: "Exposed note", Signal: model.NoteExposureSignal, RecordedAt: now}}
			return nil
		})
	}()
	mokuReplayAwait("old terminal snapshot committed before notification", entered)
	mokuReplayMust(c.Submit(mokuReplayContext(), orchestratorInput("successor before old notification")))
	second := w.mokuRecord()
	mokuReplayCheck(second.Observation.LatestExecution.ExecutionID != first.Observation.LatestExecution.ExecutionID, "fixture did not admit a successor")

	readEntered, readRelease := make(chan struct{}), make(chan struct{})
	var releaseReadOnce sync.Once
	releaseRead := func() { releaseReadOnce.Do(func() { close(readRelease) }) }
	defer releaseRead()
	w.mu.Lock()
	w.threadRead = func(ctx context.Context, _, _ string) (string, error) {
		close(readEntered)
		select {
		case <-ctx.Done():
			return "", ctx.Err()
		case <-readRelease:
			return "successor read completed", ctx.Err()
		}
	}
	w.mu.Unlock()
	readDone := make(chan error, 1)
	go func() {
		_, err := w.call("read_thread", fmt.Sprintf(`{"threadId":%q,"question":"keep this successor read alive"}`, child.ThreadID))
		readDone <- err
	}()
	mokuReplayAwait("successor tool started before old notification", readEntered)
	releaseCallback()
	mokuReplayWaitError("delayed old notification", delayed)
	if !terminalObserved {
		barrier("delayed terminal settlement drained")
		assertTerminalQueueAuditSettled(w, first.ID)
	}
	// A future tool checks scope ownership before writing a fresh audit snapshot;
	// the in-flight read also must retain its original, uncancelled context.
	_, err = w.call("talk", `{"text":"The successor still owns its tools."}`)
	mokuReplayMust(err)
	releaseRead()
	mokuReplayWaitError("successor tool after old notification", readDone)
	mokuReplayCheck(w.mokuRecord().Observation.LatestExecution.ExecutionID == second.Observation.LatestExecution.ExecutionID, "old callback changed the successor execution")
	if !terminalObserved {
		assertTerminalQueueAuditSettled(w, first.ID)
	}
}
