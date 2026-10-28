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
	core "github.com/hupao-creator/Mokusei/internal/core/runtime"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/services/moku"
)

// Hold the existing native/context boundary, never an implementation hook, so
// the real coordinator and Runtime decide whether this input needs a successor.
type settingsAdmissionGate struct {
	mu       sync.Mutex
	armed    bool
	boundary string
	entered  chan struct{}
	release  chan struct{}
	result   error
}

func (g *settingsAdmissionGate) pause(ctx context.Context, boundary string) (bool, error) {
	g.mu.Lock()
	claimed := g.armed && g.boundary == boundary
	if claimed {
		g.armed = false
	}
	g.mu.Unlock()
	if !claimed {
		return false, nil
	}
	close(g.entered)
	select {
	case <-g.release:
		return true, g.result
	case <-ctx.Done():
		return true, ctx.Err()
	}
}

type settingsAdmissionHarness struct {
	*replayNativeHarness
	gate *settingsAdmissionGate
}

func (h settingsAdmissionHarness) Open(ctx context.Context, open plugin.OpenContext) (plugin.Handle, error) {
	handle, err := h.replayNativeHarness.Open(ctx, open)
	if err != nil {
		return nil, err
	}
	return settingsAdmissionHandle{Handle: handle, open: open, gate: h.gate}, nil
}

type settingsAdmissionHandle struct {
	plugin.Handle
	open plugin.OpenContext
	gate *settingsAdmissionGate
}

func (h settingsAdmissionHandle) Send(ctx context.Context, request plugin.SendRequest) error {
	if h.open.Injection != nil {
		if claimed, err := h.gate.pause(ctx, "native"); claimed {
			return err
		}
	}
	return h.Handle.Send(ctx, request)
}

func runAdmissionSettingsChangeReplay() error {
	root, err := os.MkdirTemp("", "mokusei-settings-admission-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(root)
	for _, path := range []string{"typed", "terminal-event", "outbox"} {
		for _, boundary := range []string{"context", "native"} {
			for _, background := range []bool{false, true} {
				replayAdmissionSettingsChange(filepath.Join(root, fmt.Sprintf("%s-%s-background-%t", path, boundary, background)), path, boundary, false, background)
			}
		}
	}
	replayAdmissionSettingsChange(filepath.Join(root, "uncertain-outbox"), "outbox", "native", true, false)
	fmt.Println("PASS settings at successor admission: typed, terminal-event and durable outbox inputs refresh after terminal races, retain admitted configuration during native background work, and adopt pending settings once it drains; exact native non-consumption permits retry and uncertain delivery never replays")
	return nil
}

func replayAdmissionSettingsChange(root, path, boundary string, uncertain, background bool) {
	gate := &settingsAdmissionGate{boundary: boundary, entered: make(chan struct{}), release: make(chan struct{})}
	if boundary == "native" {
		gate.result = plugin.ErrExecutionEnded
	}
	if uncertain {
		gate.result = errors.Join(plugin.ErrExecutionEnded, errors.New("fixture outcome is uncertain"))
	}
	var releaseOnce sync.Once
	release := func() { releaseOnce.Do(func() { close(gate.release) }) }
	defer release()
	db, err := store.Open(filepath.Join(root, "state.sqlite"))
	mokuReplayMust(err)
	base := &replayNativeHarness{db: db, nativeModel: "first-model", wake: make(chan struct{}, 128)}
	harnesses := map[string]plugin.Harness{"mock": settingsAdmissionHarness{replayNativeHarness: base, gate: gate}}
	r, err := core.New(mokuReplayContext(), core.Config{Store: db, Harnesses: harnesses, DataDir: root, DefaultCwd: root})
	mokuReplayMust(err)
	base.r = r
	configuration := newReplayConfiguration(root, r, base)
	configuration.Harnesses = harnesses
	configuration.CollectContext = func(ctx context.Context, phase string, settings model.Settings) ([]plugin.ContextEntry, error) {
		if phase != "before-send" {
			return nil, nil
		}
		if _, err := gate.pause(ctx, "context"); err != nil {
			return nil, err
		}
		guidance := "first context"
		if settings.Moku.RoutingGuidance != nil {
			guidance = *settings.Moku.RoutingGuidance
		}
		return []plugin.ContextEntry{{ID: "settings-admission-context", Content: guidance}}, nil
	}
	if path == "outbox" {
		configuration.PendingDeliveries = r.PendingMokuDeliveries
		configuration.SendDelivery = r.SendMokuDelivery
	}
	c, err := moku.New(configuration)
	mokuReplayMust(err)
	r.SetMoku(c)
	mokuReplayMust(c.Start(mokuReplayContext(), plugin.RuntimeStartContext{Reason: "fixture"}))
	system := &replaySystem{r: r, c: c, db: db, h: base, root: root}
	defer system.close()
	defer release()
	mokuReplayMust(c.Submit(mokuReplayContext(), mokuReplayText("initial active execution")))
	base.awaitTools(1)
	first := system.record()
	var child model.ThreadRecord
	if path != "typed" {
		created, createErr := r.CreateThread(mokuReplayContext(), core.CreateThreadRequest{HarnessID: "mock", Input: mokuReplayText("child completion source").Input, Cwd: root, Settings: json.RawMessage(`{"model":"first-model"}`)})
		mokuReplayMust(createErr)
		child = created.Record
	}
	settings, revision, err := r.Settings()
	mokuReplayMust(err)
	base.mu.Lock()
	base.nativeModel = "updated-model"
	base.mu.Unlock()
	settings.Moku.ExecutionHarnesses["mock"] = json.RawMessage(`{"useDefaultThreadSettings":false,"threadSettings":{"model":"updated-model"}}`)
	settings.Moku.RoutingGuidance = mokuReplayString("updated routing policy")
	saved, err := r.UpdateSettings(mokuReplayContext(), revision, settings)
	mokuReplayMust(err)
	mokuReplayCheck(saved.Status == "saved", "settings race fixture failed to save")
	gate.mu.Lock()
	gate.armed = true
	gate.mu.Unlock()
	done := make(chan error, 1)
	if path == "typed" {
		go func() { done <- c.Submit(mokuReplayContext(), mokuReplayText("follow-up crossing execution boundary")) }()
	} else {
		base.mu.Lock()
		handles := append([]*replayNativeHandle{}, base.handles...)
		base.mu.Unlock()
		for _, handle := range handles {
			if handle.open.ThreadID != child.ID {
				continue
			}
			observation := handle.open.ReadThread().Observation
			finished := time.Now().UnixMilli()
			observation.LatestExecution.Status = "completed"
			observation.LatestExecution.FinishedAt = &finished
			mokuReplayMust(handle.open.SessionState.Commit(mokuReplayContext(), mokuReplayRaw(observation)))
		}
	}
	mokuReplayAwait(path+" "+boundary+" admission boundary", gate.entered)
	// This commits through the old native handle while the input has not yet
	// been retained. The coordinator's earlier ensure observed a running turn.
	observation := first.Observation
	finished := time.Now().UnixMilli()
	observation.LatestExecution.Status = "completed"
	observation.LatestExecution.FinishedAt = &finished
	if background {
		observation.BackgroundWork = &model.PublicBackgroundWork{Status: "running"}
	}
	base.mu.Lock()
	firstHandle := base.handles[0]
	base.mu.Unlock()
	mokuReplayMust(firstHandle.open.SessionState.Commit(mokuReplayContext(), mokuReplayRaw(observation)))
	release()
	if uncertain {
		waitUncertainSettingsDelivery(base)
		pending, err := r.PendingMokuDeliveries()
		mokuReplayMust(err)
		mokuReplayCheck(len(pending) == 1 && pending[0].Uncertain, "uncertain settings-race delivery was released for replay")
		base.mu.Lock()
		count := base.toolCount
		base.mu.Unlock()
		mokuReplayCheck(count == 1, "uncertain input was replayed into a successor")
		return
	}
	if path == "typed" {
		mokuReplayWaitError("settings-race typed send", done)
	}
	base.awaitTools(2)
	second := system.record()
	applied, err := r.ReadMokuConfiguration()
	mokuReplayMust(err)
	mokuReplayCheck(second.Observation.LatestExecution.ExecutionID != first.Observation.LatestExecution.ExecutionID, "settings-race fixture did not start a successor")
	expectedModel, expectedContext := "updated-model", "updated routing policy"
	if background {
		expectedModel, expectedContext = "first-model", "first context"
		mokuReplayCheck(second.Observation.BackgroundWork != nil && applied.AppliedSettings.Moku.RoutingGuidance == nil, "successor changed configuration while native background work remained active")
	} else {
		mokuReplayCheck(applied.AppliedSettings.Moku.RoutingGuidance != nil && *applied.AppliedSettings.Moku.RoutingGuidance == "updated routing policy", "successor inherited stale routing guidance")
	}
	mokuReplayCheck(replaySettingsModel(second.Settings) == expectedModel, "successor used the wrong model for its native background boundary")
	base.mu.Lock()
	inputs := append([]replayNativeInput{}, base.inputs...)
	handles := append([]*replayNativeHandle{}, base.handles...)
	base.mu.Unlock()
	mokuInputs := 0
	for _, sent := range inputs {
		if sent.threadID != second.ID {
			continue
		}
		mokuInputs++
		if sent.executionID != second.Observation.LatestExecution.ExecutionID {
			continue
		}
		fresh := false
		for _, entry := range sent.context {
			fresh = fresh || entry.ID == "settings-admission-context" && entry.Content == expectedContext
		}
		mokuReplayCheck(fresh, "successor context does not match its admitted configuration")
	}
	mokuReplayCheck(mokuInputs == 2, "settings-race retry duplicated native input")
	var injection *plugin.Injection
	for _, handle := range handles {
		if handle.open.ThreadID == second.ID {
			injection = handle.open.Injection
		}
	}
	mokuReplayCheck(injection != nil && strings.Contains(strings.Join(injection.Instructions, "\n"), "updated routing policy") != background, "successor native instructions do not match its configuration boundary")
	if path == "typed" {
		messages := 0
		for _, raw := range second.Transcript {
			var item map[string]any
			mokuReplayMust(json.Unmarshal(raw, &item))
			if item["type"] == "message" && item["role"] == "user" && item["content"] == "follow-up crossing execution boundary" {
				messages++
			}
		}
		mokuReplayCheck(messages == 1, "settings-race retry duplicated user audit")
	}
	if path == "outbox" {
		pending, err := r.PendingMokuDeliveries()
		mokuReplayMust(err)
		mokuReplayCheck(len(pending) == 0, "confirmed successor did not consume outbox exactly once")
	}
	if background {
		// A terminal foreground execution can be followed without retiring its
		// native background owner; only after both drain may the profile change.
		observation := second.Observation
		finished := time.Now().UnixMilli()
		observation.LatestExecution.Status = "completed"
		observation.LatestExecution.FinishedAt = &finished
		observation.BackgroundWork = nil
		mokuReplayMust(firstHandle.open.SessionState.Commit(mokuReplayContext(), mokuReplayRaw(observation)))
		mokuReplayMust(c.Submit(mokuReplayContext(), mokuReplayText("new settings after background drain")))
		base.awaitTools(3)
		drained := system.record()
		applied, err := r.ReadMokuConfiguration()
		mokuReplayMust(err)
		mokuReplayCheck(drained.Observation.BackgroundWork == nil && replaySettingsModel(drained.Settings) == "updated-model" && applied.AppliedSettings.Moku.RoutingGuidance != nil && *applied.AppliedSettings.Moku.RoutingGuidance == "updated routing policy", "drained background owner prevented pending settings adoption")
	}
}

func waitUncertainSettingsDelivery(h *replayNativeHarness) {
	timer := time.NewTimer(8 * time.Second)
	defer timer.Stop()
	for {
		h.mu.Lock()
		failures := append([]string{}, h.errors...)
		h.mu.Unlock()
		for _, failure := range failures {
			if strings.HasPrefix(failure, "moku-delivery-uncertain:") {
				return
			}
		}
		select {
		case <-h.wake:
		case <-timer.C:
			panic("uncertain settings-race outbox was not withheld")
		}
	}
}
