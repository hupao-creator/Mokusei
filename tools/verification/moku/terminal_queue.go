package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/services/moku"
)

func runTerminalQueueReplay() error {
	for _, outbox := range []bool{false, true} {
		replayTerminalDeliveryPath(outbox)
	}
	replayStopDrainsMokuSettlement()
	fmt.Println("PASS terminal notifications use outbox or fallback once; Moku settlement drains after outbound queue cancellation")
	return nil
}

func replayTerminalDeliveryPath(outbox bool) {
	w := newOrchestratorWorld()
	child := model.ThreadRecord{SessionRecord: model.SessionRecord{
		ID: "terminal-child", HarnessID: "mock", Cwd: "/fixture/terminal-child",
		Observation: model.PublicObservation{LatestExecution: &model.PublicExecution{ExecutionID: "child-execution", Status: "running"}},
	}, Title: "Terminal notification fixture", Tags: []string{}}
	w.records[child.ID] = child
	config := w.config()
	var diagnostic func(string)
	config.SubscribeDiagnostics = func(listener func(string)) func() {
		diagnostic = listener
		return func() {}
	}
	var outboxMu sync.Mutex
	var pending []plugin.MokuDelivery
	deliveryCalls := 0
	release := make(chan struct{})
	var releaseOnce sync.Once
	releaseOutbox := func() { releaseOnce.Do(func() { close(release) }) }
	defer releaseOutbox()
	if outbox {
		config.PendingDeliveries = func() ([]plugin.MokuDelivery, error) {
			// The first drain cannot race fixture construction. Later polls see
			// the receipt already removed by successful native admission.
			<-release
			outboxMu.Lock()
			defer outboxMu.Unlock()
			return orchestratorCopyJSON(pending), nil
		}
		config.SendDelivery = func(ctx context.Context, deliveryID, owner string, input model.AgentInput, injection *plugin.Injection, entries []plugin.ContextEntry) (plugin.SessionSendResult, error) {
			if deliveryID != "terminal-delivery" {
				return plugin.SessionSendResult{}, errors.New("unexpected terminal delivery identity")
			}
			return w.sendSession(ctx, owner, input, injection, entries, func(plugin.SessionSendResult) error {
				outboxMu.Lock()
				defer outboxMu.Unlock()
				deliveryCalls++
				pending = nil
				return nil
			})
		}
	}
	c, err := moku.New(config)
	mokuReplayMust(err)
	mokuReplayMust(c.Start(mokuReplayContext(), plugin.RuntimeStartContext{Reason: "manual"}))
	defer stopOrchestrator(c)
	// A failed assertion must release the drain before Stop tries to join it.
	defer releaseOutbox()
	mokuReplayMust(c.Submit(mokuReplayContext(), orchestratorInput("initialize terminal notification fixture")))
	mokuReplayMust(w.terminal(mokuReplayContext(), child.ID, "completed"))
	if outbox {
		completed, readErr := w.thread(child.ID)
		mokuReplayMust(readErr)
		outboxMu.Lock()
		pending = []plugin.MokuDelivery{{ID: "terminal-delivery", Thread: completed}}
		outboxMu.Unlock()
		releaseOutbox()
	}
	w.wait("ordinary terminal notification", func() bool {
		w.mu.Lock()
		defer w.mu.Unlock()
		for _, sent := range w.sends {
			if sent.orchestratorInput.Presentation == "internal" && strings.Contains(sent.orchestratorInput.Parts[0].Text, "Mokusei Agent Thread terminal event:") {
				return true
			}
		}
		return false
	})
	for i := 0; i < 4; i++ {
		mokuReplayMust(w.update(mokuReplayContext(), child.ID, func(record *model.ThreadRecord) error {
			record.Title += "."
			return nil
		}))
	}
	// The diagnostic is queued after the metadata commits. Waiting for its
	// audit row proves those callbacks were processed before Stop can cancel
	// an incorrectly duplicated outbound notification.
	diagnostic("terminal queue metadata barrier")
	w.wait("terminal metadata queue barrier", func() bool {
		for _, raw := range w.mokuRecord().Transcript {
			if strings.Contains(string(raw), "terminal queue metadata barrier") {
				return true
			}
		}
		return false
	})
	owner := w.mokuRecord()
	addTerminalQueueAudit(w, owner.ID, owner.Observation.LatestExecution.ExecutionID)
	mokuReplayMust(w.terminal(mokuReplayContext(), owner.ID, "completed"))
	stopOrchestrator(c)
	assertTerminalQueueAuditSettled(w, owner.ID)
	w.mu.Lock()
	terminalSends := 0
	for _, sent := range w.sends {
		if sent.orchestratorInput.Presentation == "internal" && strings.Contains(sent.orchestratorInput.Parts[0].Text, "Mokusei Agent Thread terminal event:") {
			terminalSends++
		}
	}
	w.mu.Unlock()
	mokuReplayCheck(terminalSends == 1, fmt.Sprintf("outbox=%v: ordinary terminal notification count=%d, want 1", outbox, terminalSends))
	outboxMu.Lock()
	calls, remaining := deliveryCalls, len(pending)
	outboxMu.Unlock()
	if outbox {
		mokuReplayCheck(calls == 1 && remaining == 0, "outbox admission did not consume its single terminal fact")
	} else {
		mokuReplayCheck(calls == 0, "fallback unexpectedly used durable delivery")
	}
}

func replayStopDrainsMokuSettlement() {
	w := newOrchestratorWorld()
	w.records["queued-child"] = model.ThreadRecord{SessionRecord: model.SessionRecord{ID: "queued-child", HarnessID: "mock"}, Title: "Queued input fixture"}
	config := w.config()
	var userInput func(plugin.LifecycleEvent)
	config.SubscribeUserThreadInputs = func(_ context.Context, listener func(plugin.LifecycleEvent)) (func(), error) {
		userInput = listener
		return func() {}, nil
	}
	c, err := moku.New(config)
	mokuReplayMust(err)
	mokuReplayMust(c.Start(mokuReplayContext(), plugin.RuntimeStartContext{Reason: "manual"}))
	defer stopOrchestrator(c)
	mokuReplayMust(c.Submit(mokuReplayContext(), orchestratorInput("initialize queued settlement")))
	owner := w.mokuRecord()
	addTerminalQueueAudit(w, owner.ID, owner.Observation.LatestExecution.ExecutionID)
	entered := make(chan struct{})
	w.mu.Lock()
	w.beforeSend = func(ctx context.Context) error {
		close(entered)
		<-ctx.Done()
		return ctx.Err()
	}
	w.mu.Unlock()
	done := make(chan error, 1)
	go func() { done <- c.Submit(mokuReplayContext(), orchestratorInput("hold admission until Stop")) }()
	mokuReplayAwait("native queue owner before Stop", entered)
	userInput(plugin.LifecycleEvent{ID: "queued-user-input", Type: "thread.input-accepted", Source: "user", Subject: plugin.LifecycleSubject{Kind: "thread", ID: "queued-child", TypeID: "agent"}, Data: json.RawMessage(`{"parts":[{"kind":"text","text":"already admitted to child"}]}`)})
	// Both events are enqueued before Stop. An outbound waiter may cancel, but
	// the later local audit settlement still owns durable cleanup work.
	mokuReplayMust(w.terminal(mokuReplayContext(), owner.ID, "completed"))
	stopOrchestrator(c)
	select {
	case err = <-done:
		mokuReplayCheck(errors.Is(err, context.Canceled), "Stop changed blocked owner cancellation result")
	case <-time.After(time.Second):
		panic("Stop left native admission owner running")
	}
	assertTerminalQueueAuditSettled(w, owner.ID)
}

func addTerminalQueueAudit(w *orchestratorWorld, owner, execution string) {
	mokuReplayMust(w.update(mokuReplayContext(), owner, func(record *model.ThreadRecord) error {
		record.Transcript = append(record.Transcript,
			mokuReplayRaw(map[string]any{"type": "tool-operation", "id": "queue-pending-tool", "executionId": execution, "callId": "queue-call", "name": "read_thread", "arguments": map[string]any{"threadId": "queued-child", "question": "review result"}, "createdAt": time.Now().UnixMilli()}),
			mokuReplayRaw(map[string]any{"type": "message", "id": "queue-streaming-assistant", "executionId": execution, "role": "assistant", "status": "streaming", "content": "Pending final response", "createdAt": time.Now().UnixMilli()}))
		return nil
	}))
}

func assertTerminalQueueAuditSettled(w *orchestratorWorld, owner string) {
	record, err := w.thread(owner)
	mokuReplayMust(err)
	toolSettled, messageSettled := false, false
	for _, raw := range record.Transcript {
		var item map[string]any
		mokuReplayMust(json.Unmarshal(raw, &item))
		if item["id"] == "queue-pending-tool" {
			toolSettled = item["completedAt"] != nil && item["isError"] == true
		}
		if item["id"] == "queue-streaming-assistant" {
			messageSettled = item["status"] == "complete"
		}
	}
	mokuReplayCheck(toolSettled && messageSettled, "Moku terminal audit was skipped while draining the event queue")
}
