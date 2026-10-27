// This command uses fixed mock-native fixtures with real runtime persistence.
// It never connects to a model service or opens a user profile.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/core/store"
)

func runRuntimeReplay() error {
	root, e := os.MkdirTemp("", "mokusei-moku-sqlite-smoke-")
	mokuReplayMust(e)
	defer os.RemoveAll(root)
	h := &replayNativeHarness{nativeModel: "first-model", wake: make(chan struct{}, 128)}
	s := startReplaySystem(root, h)
	entered, release := make(chan struct{}), make(chan struct{})
	h.mu.Lock()
	h.gateAdmission = func(ctx context.Context) error {
		close(entered)
		select {
		case <-release:
			return nil
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	h.mu.Unlock()
	done := make(chan error, 1)
	go func() { done <- s.c.Submit(mokuReplayContext(), mokuReplayText("first durable input")) }()
	mokuReplayAwait("entered", entered)
	mokuReplayRemainsBlocked("Submit", done)
	h.mu.Lock()
	mokuReplayCheck(h.toolCount == 0, "tool dispatched before explicit admission completed")
	h.mu.Unlock()
	mokuReplayCheck(len(s.record().Transcript) == 0, "user transcript written before admitted callback")
	close(release)
	mokuReplayWaitError("initial submit", done)
	h.awaitTools(1)
	first := s.record()
	mokuReplayCheck(replaySettingsModel(first.Settings) == "first-model", "initial native snapshot")
	fmt.Println("PASS real SendMokuThread waits for explicit admission; SQLite transcript commits before native tool dispatch")
	h.mu.Lock()
	firstHandle := h.handles[len(h.handles)-1]
	h.mu.Unlock()
	var createTool, sendTool plugin.ToolBinding
	for _, binding := range firstHandle.open.Injection.Tools.Bindings {
		if binding.Name == "create_thread" {
			createTool = binding
		}
		if binding.Name == "send_to_thread" {
			sendTool = binding
		}
	}
	createdJSON, e := createTool.Execute(mokuReplayContext(), plugin.ToolCall{Arguments: mokuReplayRaw(map[string]any{"worktree": false, "prompt": "fixed delegated task", "harnessId": "mock", "options": map[string]string{"model": "first-model"}})})
	mokuReplayMust(e)
	var created struct {
		ThreadID  string `json:"threadId"`
		Workspace struct {
			Cwd string `json:"cwd"`
		} `json:"workspace"`
	}
	mokuReplayMust(json.Unmarshal(createdJSON, &created))
	delegated, e := s.r.Thread(created.ThreadID)
	mokuReplayMust(e)
	h.mu.Lock()
	resolvedCwd := h.resolvedCwds[len(h.resolvedCwds)-1]
	h.mu.Unlock()
	mokuReplayCheck(resolvedCwd == delegated.Cwd && delegated.Cwd == created.Workspace.Cwd && delegated.Cwd != first.Cwd, "create_thread resolved settings before allocating its actual workspace")
	directory, e := os.Stat(delegated.Cwd)
	mokuReplayMust(e)
	mokuReplayCheck(directory.IsDir() && strings.HasPrefix(delegated.Cwd, root+string(os.PathSeparator)), "delegated workspace escaped the isolated replay profile")
	fmt.Println("PASS real create_thread resolves native settings against its allocated temporary workspace")
	verifyDispatchStatusSnapshots(s, createTool, sendTool, created.ThreadID)
	// Save new native execution profile while a run is active; follow-up retains
	// the original native handle and applied settings until the next idle send.
	h.mu.Lock()
	h.nativeModel = "second-model"
	h.mu.Unlock()
	settings, revision, e := s.r.Settings()
	mokuReplayMust(e)
	settings.Moku.ExecutionHarnesses["mock"] = json.RawMessage(`{"useDefaultThreadSettings":false,"threadSettings":{"model":"second-model"}}`)
	settings.Moku.RoutingGuidance = mokuReplayString("second policy")
	saved, e := s.r.UpdateSettings(mokuReplayContext(), revision, settings)
	mokuReplayMust(e)
	mokuReplayCheck(saved.Status == "saved", "save second settings")
	mokuReplayMust(s.c.Submit(mokuReplayContext(), mokuReplayText("follow up stays on first")))
	h.awaitTools(2)
	still := s.record()
	mokuReplayCheck(still.Observation.LatestExecution.ExecutionID == first.Observation.LatestExecution.ExecutionID, "follow-up changed execution")
	mokuReplayCheck(replaySettingsModel(still.Settings) == "first-model", "running execution adopted new native settings")
	applied, e := s.r.ReadMokuConfiguration()
	mokuReplayMust(e)
	mokuReplayCheck(applied.AppliedSettings.Moku.RoutingGuidance == nil, "applied settings advanced while running")
	mokuReplayMust(s.c.Cancel(mokuReplayContext()))
	mokuReplayMust(s.c.Submit(mokuReplayContext(), mokuReplayText("idle adopts second")))
	h.awaitTools(3)
	second := s.record()
	mokuReplayCheck(second.ID == first.ID && replaySettingsModel(second.Settings) == "second-model", "idle failed same-thread generation adoption")
	applied, e = s.r.ReadMokuConfiguration()
	mokuReplayMust(e)
	mokuReplayCheck(applied.AppliedSettings.Moku.RoutingGuidance != nil && *applied.AppliedSettings.Moku.RoutingGuidance == "second policy", "new applied settings not persisted")
	fmt.Println("PASS running follow-ups retain old settings; idle admission adopts new native snapshot and applied configuration")
	// A competing settings save waits through both snapshot acquisition and the
	// explicit native admission callback, using the actual runtime lock/token.
	mokuReplayMust(s.c.Cancel(mokuReplayContext()))
	snapshotEntered, snapshotRelease := make(chan struct{}), make(chan struct{})
	admissionEntered, admissionRelease := make(chan struct{}), make(chan struct{})
	h.mu.Lock()
	h.nativeModel = "third-model"
	h.gateSnapshot = func(ctx context.Context) error {
		close(snapshotEntered)
		select {
		case <-snapshotRelease:
			return nil
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	h.gateAdmission = func(ctx context.Context) error {
		close(admissionEntered)
		select {
		case <-admissionRelease:
			return nil
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	h.mu.Unlock()
	go func() { done <- s.c.Submit(mokuReplayContext(), mokuReplayText("locked third snapshot")) }()
	mokuReplayAwait("snapshotEntered", snapshotEntered)
	saveDone := make(chan error, 1)
	go func() {
		saveDone <- s.r.WithConfigurationAdmission(mokuReplayContext(), func(ctx context.Context) error {
			cfg, rev, e := s.r.Settings()
			if e != nil {
				return e
			}
			cfg.Moku.RoutingGuidance = mokuReplayString("pending fourth policy")
			result, e := s.r.UpdateSettings(ctx, rev, cfg)
			if e == nil && result.Status != "saved" {
				return errors.New("unexpected settings conflict")
			}
			return e
		})
	}()
	mokuReplayRemainsBlocked("settings save during snapshot", saveDone)
	close(snapshotRelease)
	mokuReplayAwait("admissionEntered", admissionEntered)
	mokuReplayRemainsBlocked("settings save during native admission", saveDone)
	mokuReplayRemainsBlocked("Submit during admission callback", done)
	close(admissionRelease)
	mokuReplayWaitError("third submit", done)
	mokuReplayWaitError("serialized settings save", saveDone)
	h.awaitTools(4)
	third := s.record()
	mokuReplayCheck(replaySettingsModel(third.Settings) == "third-model", "snapshot not accepted at admission")
	applied, e = s.r.ReadMokuConfiguration()
	mokuReplayMust(e)
	mokuReplayCheck(*applied.AppliedSettings.Moku.RoutingGuidance == "second policy", "concurrent settings leaked into applied admission")
	current, _, e := s.r.Settings()
	mokuReplayMust(e)
	mokuReplayCheck(*current.Moku.RoutingGuidance == "pending fourth policy", "serialized settings not saved")
	fmt.Println("PASS real configuration admission lock fences snapshot capture, native acknowledgment, and competing settings save")
	previousID := third.ID
	s.close()
	// Reopen actual SQLite file and fresh Runtime/Coordinator, retaining the
	// distinction between saved preferences and previously applied configuration.
	h2 := &replayNativeHarness{nativeModel: "third-model", wake: make(chan struct{}, 128)}
	reopened := startReplaySystem(root, h2)
	restored, e := reopened.r.ReadMokuConfiguration()
	mokuReplayMust(e)
	mokuReplayCheck(restored.AppliedSettings.Moku.RoutingGuidance != nil && *restored.AppliedSettings.Moku.RoutingGuidance == "second policy", "restart lost applied settings snapshot")
	r := reopened.record()
	mokuReplayCheck(r.ID == previousID && len(r.Transcript) >= 8, "restart lost durable transcript or session")
	global, _, e := reopened.r.Settings()
	mokuReplayMust(e)
	mokuReplayCheck(*global.Moku.RoutingGuidance == "pending fourth policy", "restart lost pending preferences")
	mokuReplayMust(reopened.c.Submit(mokuReplayContext(), mokuReplayText("after actual sqlite reopen")))
	h2.awaitTools(1)
	adopted, e := reopened.r.ReadMokuConfiguration()
	mokuReplayMust(e)
	mokuReplayCheck(*adopted.AppliedSettings.Moku.RoutingGuidance == "pending fourth policy", "restart idle admission did not apply pending preferences")
	mokuReplayCheck(reopened.record().ID == previousID, "restart changed same-harness identity")

	// History reset stops native background work before replacing the coordinator
	// generation; the fixture's Close publishes its drained background state.
	h2.mu.Lock()
	handle := h2.handles[len(h2.handles)-1]
	h2.mu.Unlock()
	var retiredTool plugin.ToolBinding
	for _, binding := range handle.open.Injection.Tools.Bindings {
		if binding.Name == "talk" {
			retiredTool = binding
		}
	}
	observation := reopened.record().Observation
	observation.BackgroundWork = &model.PublicBackgroundWork{Status: "running"}
	mokuReplayMust(handle.open.SessionState.Commit(mokuReplayContext(), mokuReplayRaw(observation)))
	mokuReplayMust(reopened.r.ClearHistory(mokuReplayContext()))
	reset := reopened.record()
	mokuReplayCheck(reset.ID != previousID && len(reset.Transcript) == 0 && reset.Observation.LatestExecution == nil, "history reset did not replace the old Moku history")
	resetConfiguration, e := reopened.r.ReadMokuConfiguration()
	mokuReplayMust(e)
	mokuReplayCheck(resetConfiguration.Unapplied, "history reset claimed old applied configuration")
	_, e = retiredTool.Execute(mokuReplayContext(), plugin.ToolCall{Arguments: mokuReplayRaw(map[string]string{"text": "retired history"})})
	mokuReplayCheck(e != nil, "old history tool retained mutation authority")
	mokuReplayMust(reopened.c.Submit(mokuReplayContext(), mokuReplayText("fresh history admission")))
	h2.awaitTools(2)
	reopened.close()
	fmt.Println("PASS SQLite reopen restores applied versus pending settings, user/tool audit, and stable Moku identity")
	fmt.Println("PASS real history reset drains live background work, replaces audit and execution ownership, and admits fresh work")
	return nil
}

func seedReplayRestartAudit(root, id string) {
	db, e := store.Open(filepath.Join(root, "state.sqlite"))
	mokuReplayMust(e)
	now := time.Now().UnixMilli()
	_, e = db.Update(mokuReplayContext(), func(tx *store.Tx) error {
		var r model.ThreadRecord
		ok, e := tx.Get("thread:"+id, &r)
		if e != nil {
			return e
		}
		if !ok {
			return errors.New("seed shell absent")
		}
		r.Observation = model.PublicObservation{LatestExecution: &model.PublicExecution{ExecutionID: "crash-execution", Status: "completed", StartedAt: now - 100, FinishedAt: &now}}
		r.SessionState = mokuReplayRaw(r.Observation)
		r.Transcript = []json.RawMessage{mokuReplayRaw(map[string]any{"type": "tool-operation", "id": "done-operation", "executionId": "crash-execution", "callId": "done-call", "name": "talk", "arguments": map[string]string{"text": "already done"}, "createdAt": now - 90, "completedAt": now - 80, "result": map[string]bool{"ok": true}}), mokuReplayRaw(map[string]any{"type": "tool-operation", "id": "pending-operation", "executionId": "crash-execution", "callId": "pending-call", "name": "read_thread", "arguments": map[string]string{"threadId": "old-thread", "question": "unfinished"}, "createdAt": now - 70}), mokuReplayRaw(map[string]any{"type": "message", "id": "streaming-message", "executionId": "crash-execution", "role": "assistant", "content": "partial", "status": "streaming", "statusLabel": "Thinking", "createdAt": now - 60})}
		r.Revision++
		return tx.Put("thread:"+id, r)
	})
	mokuReplayMust(e)
	mokuReplayMust(db.Close())
}
func assertReplayRestartAudit(r model.ThreadRecord) {
	mokuReplayCheck(len(r.Transcript) == 3, "restart audit changed cardinality")
	items := map[string]map[string]any{}
	for _, mokuReplayRaw := range r.Transcript {
		var item map[string]any
		mokuReplayMust(json.Unmarshal(mokuReplayRaw, &item))
		items[item["id"].(string)] = item
	}
	pending := items["pending-operation"]
	mokuReplayCheck(pending["completedAt"] != nil && pending["isError"] == true && strings.Contains(fmt.Sprint(pending["result"]), "restart"), "crash-pending tool did not settle at Start")
	streaming := items["streaming-message"]
	mokuReplayCheck(streaming["status"] == "cancelled" && streaming["statusLabel"] == nil && streaming["content"] == "partial", "crash-streaming assistant not cancelled cleanly")
	done := items["done-operation"]
	mokuReplayCheck(done["completedAt"] != nil && done["isError"] == nil && done["result"].(map[string]any)["ok"] == true, "restart changed completed audit")
	fmt.Println("PASS restart settles crash-pending tool and streaming assistant before native recovery, preserving completed audit")
}

func assertReplayShell(s *replaySystem) {
	state, e := s.r.Snapshot()
	mokuReplayMust(e)
	count := 0
	for _, r := range state.Threads {
		if r.Moku {
			count++
			mokuReplayCheck(r.ID != "" && r.Title == "Moku" && r.Observation.LatestExecution == nil, "empty Moku shell not readable")
		}
	}
	mokuReplayCheck(count == 1, "Start did not synchronously publish exactly one Moku")
}
func runShellReplay() error {
	root, e := os.MkdirTemp("", "mokusei-moku-shell-smoke-")
	mokuReplayMust(e)
	defer os.RemoveAll(root)
	// Manual start invokes no native acquisition, even when every acquisition
	// path would fail. Reopen this intentionally never-applied shell later.
	fresh := filepath.Join(root, "reopen")
	h := &replayNativeHarness{nativeModel: "first-model", wake: make(chan struct{}, 128), probeFn: func(context.Context) error { return errors.New("offline native probe") }, describeFn: func(context.Context) error { return errors.New("offline schema") }}
	started := time.Now()
	s := startReplaySystem(fresh, h)
	mokuReplayCheck(time.Since(started) < time.Second, "Start waited for native acquisition")
	assertReplayShell(s)
	h.mu.Lock()
	mokuReplayCheck(h.probeCalls == 0 && h.describeCalls == 0 && h.snapshots == 0 && len(h.opened) == 0, "manual startup performed synchronous native I/O")
	h.mu.Unlock()
	configuration, e := s.r.ReadMokuConfiguration()
	mokuReplayMust(e)
	mokuReplayCheck(configuration.Unapplied && !s.db.Snapshot().Has("moku-applied-settings"), "empty shell falsely claimed an applied native snapshot")
	shellID := s.record().ID
	mokuReplayCheck(s.c.Submit(mokuReplayContext(), mokuReplayText("cannot run offline")) != nil, "offline probe unexpectedly admitted execution")
	assertReplayShell(s)
	s.close()
	seedReplayRestartAudit(fresh, shellID)
	h2 := &replayNativeHarness{nativeModel: "recovered-model", wake: make(chan struct{}, 128)}
	reopened := startReplaySystem(fresh, h2)
	configuration, e = reopened.r.ReadMokuConfiguration()
	mokuReplayMust(e)
	mokuReplayCheck(configuration.Unapplied && reopened.record().ID == shellID, "unapplied marker lost across SQLite reopen")
	assertReplayRestartAudit(reopened.record())
	mokuReplayMust(reopened.c.Submit(mokuReplayContext(), mokuReplayText("first admission after empty-shell reopen")))
	h2.awaitTools(1)
	configuration, e = reopened.r.ReadMokuConfiguration()
	mokuReplayMust(e)
	mokuReplayCheck(!configuration.Unapplied && replaySettingsModel(reopened.record().Settings) == "recovered-model", "preexisting empty shell skipped native snapshot application")
	mokuReplayCheck(reopened.record().ID == shellID, "first admission replaced same-harness shell identity")
	fmt.Println("PASS Start exposes an unapplied Moku without native I/O; offline failure preserves shell; SQLite reopen applies first captured configuration")
	// Every new shell state published by configured replacement mokuReplayMust contain its
	// applied snapshot in that same store version, before any native open.
	mokuReplayMust(reopened.c.Cancel(mokuReplayContext()))
	beforeID := reopened.record().ID
	h2.mu.Lock()
	opens := len(h2.opened)
	h2.mu.Unlock()
	changes, unsub := reopened.db.Subscribe()
	watchDone := make(chan error, 1)
	watchCtx, cancel := context.WithCancel(mokuReplayContext())
	go func() {
		for {
			select {
			case _, ok := <-changes:
				if !ok {
					watchDone <- nil
					return
				}
				snapshot := reopened.db.Snapshot()
				for _, key := range snapshot.Keys("thread:") {
					var r model.ThreadRecord
					ok, e := snapshot.Get(key, &r)
					if e != nil {
						watchDone <- e
						return
					}
					if ok && r.Moku && r.ID != beforeID {
						if !snapshot.Has("moku-applied-settings") {
							watchDone <- errors.New("replacement published without applied snapshot")
							return
						}
						watchDone <- nil
						return
					}
				}
			case <-watchCtx.Done():
				watchDone <- watchCtx.Err()
				return
			}
		}
	}()
	mokuReplayMust(reopened.c.Clear(mokuReplayContext()))
	mokuReplayWaitError("atomic replacement publication", watchDone)
	cancel()
	unsub()
	replacement := reopened.record()
	mokuReplayCheck(replacement.ID != beforeID, "clear did not replace Moku")
	configuration, e = reopened.r.ReadMokuConfiguration()
	mokuReplayMust(e)
	mokuReplayCheck(!configuration.Unapplied && reopened.db.Snapshot().Has("moku-applied-settings"), "configured replacement lost applied snapshot")
	h2.mu.Lock()
	mokuReplayCheck(len(h2.opened) == opens, "clear opened native before explicit admission")
	h2.mu.Unlock()
	mokuReplayMust(reopened.c.Submit(mokuReplayContext(), mokuReplayText("after configured replacement")))
	h2.awaitTools(2)
	reopened.close()
	fmt.Println("PASS configured replacement atomically publishes applied settings and opens native only after that durable snapshot exists")
	// Startup recovery may run in the background, but neither blocked nor failed
	// native Probe/Describe can postpone shell delivery to the Swift consumer.
	for _, kind := range []string{"probe-block", "describe-block", "probe-fail", "describe-fail"} {
		dir := filepath.Join(root, kind)
		gateEntered := make(chan struct{})
		var once sync.Once
		operation := func(ctx context.Context) error {
			once.Do(func() { close(gateEntered) })
			if strings.HasSuffix(kind, "block") {
				<-ctx.Done()
				return ctx.Err()
			}
			return errors.New("injected " + kind)
		}
		hh := &replayNativeHarness{nativeModel: "background-model", wake: make(chan struct{}, 128)}
		if strings.HasPrefix(kind, "probe") {
			hh.probeFn = operation
		} else {
			hh.describeFn = operation
		}
		created := make(chan *replaySystem, 1)
		go func() { created <- startReplaySystem(dir, hh, "startup") }()
		var ss *replaySystem
		select {
		case ss = <-created:
		case <-time.After(time.Second):
			panic("Start blocked on " + kind)
		}
		assertReplayShell(ss)
		select {
		case <-gateEntered:
		case <-time.After(3 * time.Second):
			panic("startup recovery did not exercise " + kind)
		}
		assertReplayShell(ss)
		ss.close()
	}
	fmt.Println("PASS startup Probe/Describe failures and cancellation-aware blocks cannot delay the readable Moku shell")
	return nil
}
