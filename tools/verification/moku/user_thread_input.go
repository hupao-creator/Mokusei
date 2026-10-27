package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	runtimepkg "github.com/hupao-creator/Mokusei/internal/core/runtime"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/services/attachments"
)

const userThreadEventPrefix = "Mokusei user direct-to-thread event:\n"

func (h *replayNativeHarness) userNotifications() []replayNativeInput {
	h.mu.Lock()
	defer h.mu.Unlock()
	var result []replayNativeInput
	for _, sent := range h.inputs {
		if sent.input.Presentation == "internal" && strings.HasPrefix(sent.input.Parts[0].Text, userThreadEventPrefix) {
			result = append(result, sent)
		}
	}
	return result
}

func (h *replayNativeHarness) awaitUserNotifications(count int) []replayNativeInput {
	timer := time.NewTimer(8 * time.Second)
	defer timer.Stop()
	for {
		if sent := h.userNotifications(); len(sent) >= count {
			return sent
		}
		select {
		case <-h.wake:
		case <-timer.C:
			panic("timed out waiting for user input in Moku's native handle")
		}
	}
}

func userInputEvents(s *replaySystem) []store.Event {
	events, err := s.db.Snapshot().Events()
	mokuReplayMust(err)
	var result []store.Event
	for _, event := range events {
		if event.Type == "thread.input-accepted" && event.Source == "user" {
			result = append(result, event)
		}
	}
	return result
}

func awaitUserInputThreadStatus(s *replaySystem, id, status string) {
	changes, unsubscribe := s.db.Subscribe()
	defer unsubscribe()
	timer := time.NewTimer(8 * time.Second)
	defer timer.Stop()
	for {
		thread, err := s.r.Thread(id)
		mokuReplayMust(err)
		if thread.Observation.LatestExecution.Status == status {
			return
		}
		select {
		case <-changes:
		case <-timer.C:
			panic("timed out waiting for thread " + status)
		}
	}
}

func runUserThreadInputReplay() error {
	root, err := os.MkdirTemp("", "mokusei-user-thread-input-")
	mokuReplayMust(err)
	defer os.RemoveAll(root)
	h := &replayNativeHarness{nativeModel: "first-model", wake: make(chan struct{}, 128), doubleAdmission: true}
	s := startReplaySystem(root, h)
	closed := false
	defer func() {
		if !closed {
			s.close()
		}
	}()
	ctx := mokuReplayContext()
	mokuReplayMust(s.c.Submit(ctx, mokuReplayText("initialize isolated Moku")))
	h.awaitTools(1)
	created, err := s.r.CreateThread(ctx, runtimepkg.CreateThreadRequest{HarnessID: "mock", Input: mokuReplayText("isolated child").Input, Cwd: root})
	mokuReplayMust(err)
	id := created.Record.ID
	invoke := func(ctx context.Context, target string, input model.AgentInput) (plugin.SessionSendResult, error) {
		result, err := s.r.Invoke(ctx, "thread:follow-up", []json.RawMessage{mokuReplayRaw(map[string]any{"threadId": target, "input": input})})
		if err != nil {
			return plugin.SessionSendResult{}, err
		}
		return result.(plugin.SessionSendResult), nil
	}

	// A public send stays silent until native admission. The original child
	// instruction must arrive unchanged; the notification only goes to Moku.
	entered, release := make(chan struct{}), make(chan struct{})
	h.mu.Lock()
	h.beforeThreadSend = func(ctx context.Context) error {
		close(entered)
		select {
		case <-release:
			return nil
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	h.mu.Unlock()
	text := "只在这个 child 修改；不要合并 main，也不要重复派发。"
	done := make(chan error, 1)
	go func() { _, err := invoke(ctx, id, mokuReplayText(text).Input); done <- err }()
	mokuReplayAwait("child native send", entered)
	mokuReplayRemainsBlocked("direct thread admission", done)
	mokuReplayCheck(len(userInputEvents(s)) == 0 && len(h.userNotifications()) == 0, "notification before admission")
	close(release)
	mokuReplayWaitError("direct thread admission", done)
	h.mu.Lock()
	h.beforeThreadSend = nil
	h.mu.Unlock()
	sent := h.awaitUserNotifications(1)[0]
	mokuReplayCheck(sent.threadID == s.record().ID, "notification did not reach Moku native handle")
	line := strings.SplitN(strings.TrimPrefix(sent.input.Parts[0].Text, userThreadEventPrefix), "\n", 2)[0]
	var notification struct {
		Event  plugin.LifecycleEvent `json:"event"`
		Thread struct {
			ID    string `json:"threadId"`
			Title string `json:"title"`
		} `json:"thread"`
	}
	mokuReplayMust(json.Unmarshal([]byte(line), &notification))
	var accepted model.UserThreadInput
	mokuReplayMust(json.Unmarshal(notification.Event.Data, &accepted))
	mokuReplayCheck(notification.Event.ID == userInputEvents(s)[0].ID && notification.Event.Source == "user" && notification.Event.Subject.ID == id, "event identity or source lost")
	mokuReplayCheck(notification.Thread.ID == id && notification.Thread.Title == created.Record.Title, "target thread context lost")
	mokuReplayCheck(accepted.Parts[0].Text == text && accepted.ExecutionID == created.Execution.ExecutionID && !accepted.StartedNewExecution, "running follow-up content or receipt lost")
	mokuReplayCheck(strings.Contains(sent.input.Parts[0].Text, "Respect the user's direct instructions") && strings.Contains(sent.input.Parts[0].Text, "Do not resend"), "missing coordination authority instructions")
	h.mu.Lock()
	childReceived := false
	for _, input := range h.inputs {
		if input.threadID == id && input.input.Parts[0].Text == text {
			childReceived = input.input.Presentation != "internal"
		}
	}
	h.mu.Unlock()
	mokuReplayCheck(childReceived, "direct child instruction was changed or redirected")

	// Browser annotations and attachment-only inputs use the exact same public
	// command. Verify canonical attachment metadata, not client-supplied paths.
	path := filepath.Join(root, "notes.txt")
	mokuReplayMust(os.WriteFile(path, []byte("isolated attachment"), 0600))
	staged, err := s.r.Invoke(ctx, "moku:stage-attachments", []json.RawMessage{mokuReplayRaw([]attachments.Import{{Source: "path", Path: path}})})
	mokuReplayMust(err)
	file := staged.([]model.Attachment)[0]
	annotationID := "12345678-1234-4234-8234-123456789abc"
	annotation := json.RawMessage(`[{"id":"` + annotationID + `","comment":"修改此处","url":"https://example.com/","title":"Fixture","kind":"region","rect":{"x":0,"y":0,"width":10,"height":10},"viewport":{"width":100,"height":100,"scrollX":0,"scrollY":0}}]`)
	_, err = invoke(ctx, id, model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "批注：修改此处", AnnotationID: annotationID}, {Kind: "local-file", File: &model.InputFile{ID: file.ID}}}, Annotations: annotation})
	mokuReplayMust(err)
	annotationNotification := h.awaitUserNotifications(2)[1]
	line = strings.SplitN(strings.TrimPrefix(annotationNotification.input.Parts[0].Text, userThreadEventPrefix), "\n", 2)[0]
	mokuReplayMust(json.Unmarshal([]byte(line), &notification))
	events := userInputEvents(s)
	var annotated model.UserThreadInput
	mokuReplayMust(json.Unmarshal(notification.Event.Data, &annotated))
	canonicalPath, err := filepath.EvalSymlinks(file.Path)
	mokuReplayMust(err)
	var gotAnnotations, wantAnnotations any
	mokuReplayMust(json.Unmarshal(annotated.Annotations, &gotAnnotations))
	mokuReplayMust(json.Unmarshal(annotation, &wantAnnotations))
	mokuReplayCheck(annotated.Parts[1].File.ID == file.ID && annotated.Parts[1].File.Name == file.Name && annotated.Parts[1].File.Path == canonicalPath && reflect.DeepEqual(gotAnnotations, wantAnnotations), "attachment or browser annotation context lost before native Moku")
	h.awaitTools(3)
	mokuReplayMust(s.r.UpdateThread(ctx, s.record().ID, func(record *model.ThreadRecord) error {
		o := record.Observation
		now := time.Now().UnixMilli()
		o.LatestExecution.Status, o.LatestExecution.FinishedAt = "completed", &now
		record.SessionState = mokuReplayRaw(o)
		return nil
	}))
	_, err = invoke(ctx, id, model.AgentInput{Parts: []model.AgentInputPart{{Kind: "local-file", File: &model.InputFile{ID: file.ID}}}})
	mokuReplayMust(err)
	resumed := h.awaitUserNotifications(3)[2]
	mokuReplayCheck(resumed.executionID != sent.executionID, "user event did not resume idle Moku")

	// Fresh executions, as well as steering, notify. Ordinary Moku/tool sends
	// remain application-sourced and never generate user notifications.
	mokuReplayMust(s.r.UpdateThread(ctx, id, func(record *model.ThreadRecord) error {
		o := record.Observation
		now := time.Now().UnixMilli()
		o.LatestExecution.Status, o.LatestExecution.FinishedAt = "completed", &now
		record.SessionState = mokuReplayRaw(o)
		return nil
	}))
	newSend, err := invoke(ctx, id, mokuReplayText("new execution").Input)
	mokuReplayMust(err)
	h.awaitUserNotifications(4)
	mokuReplayMust(json.Unmarshal(userInputEvents(s)[3].Data, &accepted))
	mokuReplayCheck(newSend.StartedNewExecution && accepted.StartedNewExecution && accepted.ExecutionID == newSend.ExecutionID && accepted.ExecutionID != created.Execution.ExecutionID, "new execution identity lost")
	_, err = s.r.SendThread(ctx, id, mokuReplayText("Moku tool follow-up").Input)
	mokuReplayMust(err)

	// Invalid, archived, cancelled and native-rejected sends cannot record user
	// success. Rejecting a follow-up must not end the child's existing work.
	_, err = invoke(ctx, id, mokuReplayText(" ").Input)
	mokuReplayCheck(err != nil, "empty input accepted")
	_, err = invoke(ctx, s.record().ID, mokuReplayText("wrong target").Input)
	mokuReplayCheck(err != nil, "Moku accepted as direct child target")
	_, err = invoke(ctx, id, model.AgentInput{Parts: []model.AgentInputPart{{Kind: "local-file", File: &model.InputFile{ID: annotationID}}}})
	mokuReplayCheck(err != nil, "unavailable attachment accepted")
	cancelled, cancel := context.WithCancel(ctx)
	cancel()
	_, err = invoke(cancelled, id, mokuReplayText("cancelled").Input)
	mokuReplayCheck(err != nil, "cancelled input accepted")
	mokuReplayMust(s.r.SetArchived(ctx, id, true))
	_, err = invoke(ctx, id, mokuReplayText("archived").Input)
	mokuReplayCheck(err != nil, "archived input accepted")
	mokuReplayMust(s.r.SetArchived(ctx, id, false))
	// Cancellation after entering the native boundary also stays silent.
	entered = make(chan struct{})
	h.mu.Lock()
	h.beforeThreadSend = func(ctx context.Context) error {
		close(entered)
		<-ctx.Done()
		return ctx.Err()
	}
	h.mu.Unlock()
	pending, cancelPending := context.WithCancel(ctx)
	go func() { _, err := invoke(pending, id, mokuReplayText("cancel during admission").Input); done <- err }()
	mokuReplayAwait("cancellable child admission", entered)
	cancelPending()
	select {
	case err := <-done:
		mokuReplayCheck(err != nil, "cancelled native admission reported success")
	case <-ctx.Done():
		panic(ctx.Err())
	}
	awaitUserInputThreadStatus(s, id, "running")
	h.mu.Lock()
	h.beforeThreadSend = func(context.Context) error { return errors.New("fixture rejects admission") }
	h.mu.Unlock()
	_, err = invoke(ctx, id, mokuReplayText("native rejection").Input)
	mokuReplayCheck(err != nil, "native rejection reported success")
	mokuReplayCheck(len(userInputEvents(s)) == 4, "failed or application-origin sends emitted user success")
	h.mu.Lock()
	h.beforeThreadSend = nil
	h.mu.Unlock()

	// Large Unicode input has a bounded, explicitly truncated notification,
	// while SQLite retains the entire admitted message.
	large := strings.Repeat("界🙂", 30000)
	continued, err := invoke(ctx, id, mokuReplayText(large).Input)
	mokuReplayMust(err)
	mokuReplayCheck(!continued.StartedNewExecution && continued.ExecutionID == newSend.ExecutionID, "rejected or cancelled follow-up ended the original child execution")
	all := h.awaitUserNotifications(5)
	preview := all[4].input.Parts[0].Text
	mokuReplayCheck(utf8.ValidString(preview) && len(preview) < 150000 && strings.Contains(preview, `"truncated":true`), "large notification not bounded or explicit")
	events = userInputEvents(s)
	mokuReplayMust(json.Unmarshal(events[4].Data, &accepted))
	mokuReplayCheck(accepted.Parts[0].Text == large, "durable input was truncated")
	ids := map[string]bool{}
	for _, event := range events {
		mokuReplayCheck(!ids[event.ID], "duplicate event ID")
		ids[event.ID] = true
	}
	// Extra commits and repeated native Admitted callbacks do not replay input.
	for range 3 {
		mokuReplayMust(s.r.UpdateThread(ctx, id, func(record *model.ThreadRecord) error { return nil }))
	}
	time.Sleep(80 * time.Millisecond)
	mokuReplayCheck(len(h.userNotifications()) == 5 && len(userInputEvents(s)) == 5, "duplicate revision, callback or notification loop")
	h.awaitTools(6)
	s.close()
	closed = true

	// Reopening the same isolated SQLite profile must not replay historical
	// accepted messages into a new Moku execution.
	reopenedHarness := &replayNativeHarness{nativeModel: "first-model", wake: make(chan struct{}, 128)}
	reopened := startReplaySystem(root, reopenedHarness)
	defer reopened.close()
	mokuReplayMust(reopened.c.Submit(ctx, mokuReplayText("after restart")))
	reopenedHarness.awaitTools(1)
	time.Sleep(80 * time.Millisecond)
	mokuReplayCheck(len(reopenedHarness.userNotifications()) == 0 && len(userInputEvents(reopened)) == 5, "restart replayed historical direct inputs")
	fmt.Println("PASS public sidecard sends reach native Moku with content, origin, receipts and attachment/annotation context; failures, duplicate admission, loops and restart replay fenced")
	return nil
}
