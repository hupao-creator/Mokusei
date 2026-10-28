package main

import (
	"context"
	"encoding/json"
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
	"github.com/hupao-creator/Mokusei/internal/hosts/applicationhost"
	"github.com/hupao-creator/Mokusei/internal/plugins/applications/report"
	"github.com/hupao-creator/Mokusei/internal/plugins/applications/tag"
	"github.com/hupao-creator/Mokusei/internal/services/directorytag"
)

type backgroundSettingsHarness struct {
	reportScopeHarness
	gateMu          sync.Mutex
	gate            func(context.Context) error
	sends           chan backgroundSettingsSend
	settleOnOpen    bool
	coldSettlements int
}

type backgroundSettingsSend struct {
	handle    *handle
	execution string
	model     string
}

// There is no connected native UI in this replay; Tag still receives its
// declared Overview capability through the normal application host boundary.
type backgroundSettingsOverview struct{}

func (backgroundSettingsOverview) ReadClients(ctx context.Context) ([]plugin.OverviewClientSnapshot, error) {
	return []plugin.OverviewClientSnapshot{}, ctx.Err()
}
func (backgroundSettingsOverview) SelectFilter(context.Context, plugin.OverviewFilterSelection) (plugin.OverviewFilterResult, error) {
	return plugin.OverviewFilterResult{}, fmt.Errorf("no connected overview client")
}

func (h *backgroundSettingsHarness) DefaultSettings() json.RawMessage {
	return raw(model.Object{"model": "initial"})
}
func (h *backgroundSettingsHarness) Settings() plugin.HarnessSettings {
	return backgroundSettingsAPI{settings: settings{}, harness: h}
}
func (h *backgroundSettingsHarness) Open(ctx context.Context, open plugin.OpenContext) (plugin.Handle, error) {
	native, err := h.reportScopeHarness.Open(ctx, open)
	if err != nil {
		return nil, err
	}
	if strings.Contains(open.ReadThread().Cwd, string(filepath.Separator)+"plugins"+string(filepath.Separator)) {
		h.gateMu.Lock()
		settle := h.settleOnOpen
		h.settleOnOpen = false
		if settle {
			h.coldSettlements++
		}
		h.gateMu.Unlock()
		if settle {
			// Pi/Claude can settle persisted live work while opening, before
			// the runner receives its handle and checks the observation.
			finishReportFixture(ctx, native.(*handle), "interrupted")
		}
	}
	return &backgroundSettingsHandle{handle: native.(*handle), harness: h}, nil
}

type backgroundSettingsAPI struct {
	settings
	harness *backgroundSettingsHarness
}

func (s backgroundSettingsAPI) SnapshotExecution(ctx context.Context, request plugin.SettingsRequest, _ bool) (json.RawMessage, error) {
	return model.CloneRaw(request.Settings), ctx.Err()
}
func (s backgroundSettingsAPI) ResolveThread(ctx context.Context, request plugin.ResolveSettingsRequest) (json.RawMessage, error) {
	if strings.Contains(request.Cwd, string(filepath.Separator)+"plugins"+string(filepath.Separator)) {
		s.harness.gateMu.Lock()
		gate := s.harness.gate
		s.harness.gate = nil
		s.harness.gateMu.Unlock()
		if gate != nil {
			if err := gate(ctx); err != nil {
				return nil, err
			}
		}
	}
	return model.CloneRaw(request.Merged), ctx.Err()
}

type backgroundSettingsHandle struct {
	*handle
	harness *backgroundSettingsHarness
}

func (h *backgroundSettingsHandle) Send(ctx context.Context, request plugin.SendRequest) error {
	if err := h.handle.Send(ctx, request); err != nil {
		return err
	}
	record := h.open.ReadThread()
	if strings.Contains(record.Cwd, string(filepath.Separator)+"plugins"+string(filepath.Separator)) {
		var settings struct {
			Model string `json:"model"`
		}
		must(json.Unmarshal(record.Settings, &settings))
		h.harness.sends <- backgroundSettingsSend{h.handle, request.ExecutionID, settings.Model}
	}
	return nil
}

func (h *backgroundSettingsHandle) Close() error {
	if err := h.handle.Close(); err != nil {
		return err
	}
	// Real adapters flush their canonical native state during Close, advancing
	// the private session revision even after an execution already settled.
	encoded := h.open.SessionState.Read()
	if !model.IsNull(encoded) {
		var snapshot state
		if err := json.Unmarshal(encoded, &snapshot); err != nil {
			return err
		}
		snapshot.Observation.BackgroundWork = nil
		return h.open.SessionState.Commit(context.Background(), raw(snapshot))
	}
	return nil
}

func (h *backgroundSettingsHandle) Interrupt(ctx context.Context) error {
	var snapshot state
	if err := json.Unmarshal(h.open.SessionState.Read(), &snapshot); err != nil {
		return err
	}
	if execution := snapshot.Observation.LatestExecution; execution == nil || execution.Terminal() {
		// Claude's foreground interrupt does not stop background tasks when
		// there is no active turn. Close owns their final cleanup.
		return ctx.Err()
	}
	return h.handle.Interrupt(ctx)
}

func verifyBackgroundSettings(ctx context.Context) {
	for _, agent := range []string{"tag", "report"} {
		for _, independent := range []bool{false, true} {
			verifyBackgroundSettingsCase(ctx, agent, independent)
		}
	}
	fmt.Println("PASS production Tag/Report runners: configuration races do not spend batch retries; inheritance/override, admitted steering and next-batch settings remain isolated; cold orphan settlement and lingering background cleanup re-admit new-batch settings")
}

func verifyBackgroundSettingsCase(ctx context.Context, agent string, independent bool) {
	root, err := os.MkdirTemp("", "mokusei-background-settings-")
	must(err)
	defer os.RemoveAll(root)
	db, err := store.Open(filepath.Join(root, "state.sqlite"))
	must(err)
	h := &backgroundSettingsHarness{sends: make(chan backgroundSettingsSend, 16)}
	r, err := core.New(ctx, core.Config{Store: db, Harnesses: map[string]plugin.Harness{"fixture": h}, DataDir: root, DefaultCwd: root, ExtraCapabilities: map[string]any{plugin.OverviewControlCapabilityKey.ID: backgroundSettingsOverview{}}})
	must(err)
	defer func() { must(r.Close(ctx)); must(db.Close()) }()
	var application plugin.Application = tag.New()
	if agent == "report" {
		application = report.New()
	}
	app, err := applicationhost.New(ctx, applicationhost.Config{Store: db, Applications: []plugin.Application{application}, RuntimeCapabilities: r.RuntimeCapabilities, BackgroundCapabilities: r.BackgroundCapabilities, SnapshotCapabilities: r.SnapshotCapabilities, DirectoryScopes: r.DirectoryScopes})
	must(err)
	r.SetApplications(app)
	_, err = r.EnsureExecutionSettings(ctx, "fixture", "")
	must(err)
	save := func(change func(*model.Settings)) {
		value, revision, err := r.Settings()
		must(err)
		change(&value)
		result, err := r.UpdateSettings(ctx, revision, value)
		must(err)
		if result.Status != "saved" {
			panic("background replay settings save conflicted")
		}
	}
	setIndependent := func(value *model.Settings, modelID string) {
		for i, entry := range value.PluginSettings {
			if entry.ID == agent+".settings" {
				value.PluginSettings[i].Value = raw(model.Object{"mode": "override", "harnessPreference": "fixture", "harnesses": model.Object{"fixture": model.Object{"model": modelID}}})
				return
			}
		}
		panic("missing background settings")
	}
	initialModel := "initial"
	if independent {
		initialModel = "independent"
		save(func(value *model.Settings) { setIndependent(value, initialModel) })
	}
	entered, release := make(chan struct{}), make(chan struct{})
	h.gate = func(ctx context.Context) error {
		close(entered)
		select {
		case <-release:
			return nil
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	must(app.Start(ctx, plugin.RuntimeStartContext{Reason: "startup"}))
	trigger := func() {
		created, err := r.CreateThread(ctx, core.CreateThreadRequest{HarnessID: "fixture", Cwd: root, Input: model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "settings boundary evidence"}}}})
		must(err)
		if agent == "report" {
			finishReportFixture(ctx, h.latest(created.Record.ID), "completed")
		}
	}
	trigger()
	select {
	case <-entered:
	case <-time.After(3 * time.Second):
		panic("background configuration never reached native resolution")
	}
	// Routing guidance does not affect either background execution profile.
	// It must not turn a successful configuration discovery into a batch failure.
	save(func(value *model.Settings) {
		guidance := "unrelated Moku routing edit"
		value.Moku.RoutingGuidance = &guidance
	})
	close(release)
	var owner plugin.BackgroundAgentRef
	for _, candidate := range app.BackgroundInstances() {
		if candidate.Binding.Scope == directorytag.Scope(root) {
			owner = candidate
		}
	}
	if owner.AgentID == "" {
		panic("background replay scope owner missing")
	}
	awaitSend := func() backgroundSettingsSend {
		select {
		case sent := <-h.sends:
			return sent
		case <-time.After(3 * time.Second):
			work, _, err := db.Snapshot().Work(owner.AgentID + ".events")
			must(err)
			panic(fmt.Sprintf("%s independent=%v: settings race prevented admission; attempts=%d nextAttemptAt=%d", agent, independent, work.Attempts, work.NextAttemptAt))
		}
	}
	first := awaitSend()
	if first.model != initialModel {
		panic("background initial profile changed")
	}
	work, exists, err := db.Snapshot().Work(owner.AgentID + ".events")
	must(err)
	if !exists || work.Attempts != 1 || work.ExecutionID != first.execution {
		panic("configuration race consumed an execution attempt")
	}
	save(func(value *model.Settings) {
		value.Moku.ExecutionHarnesses["fixture"] = raw(model.Object{"model": "next"})
	})
	trigger()
	steered := awaitSend()
	if steered.execution != first.execution || steered.model != initialModel {
		panic("saved settings changed the admitted background batch")
	}
	finishReportFixture(ctx, first.handle, "completed")
	waitFor(func() bool {
		_, exists, err := db.Snapshot().Work(owner.AgentID + ".events")
		must(err)
		return !exists
	})
	trigger()
	next := awaitSend()
	want := "next"
	if independent {
		want = "independent"
	}
	if next.execution == first.execution || next.model != want {
		panic("background next batch did not preserve inheritance/override semantics")
	}
	finishReportFixture(ctx, next.handle, "completed")
	waitFor(func() bool {
		_, exists, err := db.Snapshot().Work(owner.AgentID + ".events")
		must(err)
		return !exists
	})
	// The captured key initially matches the existing idle session. Reuse
	// still needs to notice an actual profile edit that wins during discovery.
	reuseEntered, reuseRelease := make(chan struct{}), make(chan struct{})
	h.gateMu.Lock()
	h.gate = func(ctx context.Context) error {
		close(reuseEntered)
		select {
		case <-reuseRelease:
			return nil
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	h.gateMu.Unlock()
	trigger()
	select {
	case <-reuseEntered:
	case <-time.After(3 * time.Second):
		panic("reused background configuration never reached native resolution")
	}
	save(func(value *model.Settings) {
		if independent {
			setIndependent(value, "raced-profile")
		} else {
			value.Moku.ExecutionHarnesses["fixture"] = raw(model.Object{"model": "raced-profile"})
		}
	})
	close(reuseRelease)
	raced := awaitSend()
	if raced.model != "raced-profile" {
		panic("same-key background reuse bypassed a newer saved profile")
	}
	work, exists, err = db.Snapshot().Work(owner.AgentID + ".events")
	must(err)
	if !exists || work.Attempts != 1 {
		panic("profile discovery race consumed a background execution retry")
	}
	finishReportFixture(ctx, raced.handle, "completed")
	waitFor(func() bool {
		_, exists, err := db.Snapshot().Work(owner.AgentID + ".events")
		must(err)
		return !exists
	})
	if independent {
		save(func(value *model.Settings) { setIndependent(value, "independent-next") })
		trigger()
		updated := awaitSend()
		if updated.model != "independent-next" {
			panic("independent background edit did not reach the next batch")
		}
		finishReportFixture(ctx, updated.handle, "completed")
		waitFor(func() bool {
			_, exists, err := db.Snapshot().Work(owner.AgentID + ".events")
			must(err)
			return !exists
		})
	}
	last := h.latest(owner.AgentID)
	waitFor(func() bool { last.mu.Lock(); defer last.mu.Unlock(); return last.closed })
	capabilities := r.BackgroundCapabilities(owner, agent+".settings")
	sessions, err := plugin.Require[plugin.BackgroundSessionsCapability](capabilities, plugin.BackgroundSessionsCapabilityKey)
	must(err)
	orphan, err := sessions.Open(ctx, plugin.OpenSessionRequest{SessionKey: "primary", Injection: *last.open.Injection})
	must(err)
	_, err = orphan.Send(ctx, model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "unowned native continuation"}}}, nil, nil)
	must(err)
	orphanSend := awaitSend()
	save(func(value *model.Settings) {
		if independent {
			setIndependent(value, "after-orphan")
		} else {
			value.Moku.ExecutionHarnesses["fixture"] = raw(model.Object{"model": "after-orphan"})
		}
	})
	trigger()
	afterOrphan := awaitSend()
	if afterOrphan.execution == orphanSend.execution || afterOrphan.model != "after-orphan" {
		panic("new background batch did not clean up its orphan before adopting saved configuration")
	}
	work, exists, err = db.Snapshot().Work(owner.AgentID + ".events")
	must(err)
	if !exists || work.Attempts != 1 {
		panic("orphan cleanup consumed a background execution retry")
	}
	finishReportFixture(ctx, afterOrphan.handle, "completed")
	waitFor(func() bool {
		_, exists, err := db.Snapshot().Work(owner.AgentID + ".events")
		must(err)
		return !exists
	})

	// The process's initial read is idle. Introduce an unowned native execution
	// while Resolve is paused; Configure's source check causes ensure to read
	// the orphan, whose cold Open then settles it before returning a handle.
	last = h.latest(owner.AgentID)
	waitFor(func() bool { last.mu.Lock(); defer last.mu.Unlock(); return last.closed })
	coldEntered, coldRelease := make(chan struct{}), make(chan struct{})
	h.gateMu.Lock()
	h.gate = func(ctx context.Context) error {
		close(coldEntered)
		select {
		case <-coldRelease:
			return nil
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	h.gateMu.Unlock()
	trigger()
	select {
	case <-coldEntered:
	case <-time.After(3 * time.Second):
		panic("background cold-orphan preparation never reached resolution")
	}
	orphan, err = sessions.Open(ctx, plugin.OpenSessionRequest{SessionKey: "primary", Injection: *last.open.Injection})
	must(err)
	_, err = orphan.Send(ctx, model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "unowned cold continuation"}}}, nil, nil)
	must(err)
	orphanSend = awaitSend()
	must(orphan.Close())
	h.gateMu.Lock()
	h.settleOnOpen = true
	h.gateMu.Unlock()
	save(func(value *model.Settings) {
		if independent {
			setIndependent(value, "after-cold-orphan")
		} else {
			value.Moku.ExecutionHarnesses["fixture"] = raw(model.Object{"model": "after-cold-orphan"})
		}
	})
	close(coldRelease)
	afterCold := awaitSend()
	h.gateMu.Lock()
	coldSettlements := h.coldSettlements
	h.gateMu.Unlock()
	if coldSettlements != 1 || afterCold.execution == orphanSend.execution || afterCold.model != "after-cold-orphan" {
		panic("cold Open settled the orphan but the new batch kept its old configuration")
	}
	work, exists, err = db.Snapshot().Work(owner.AgentID + ".events")
	must(err)
	if !exists || work.Attempts != 1 {
		panic("cold-orphan reconfiguration consumed an execution retry")
	}
	finishReportFixture(ctx, afterCold.handle, "completed")
	waitFor(func() bool {
		_, exists, err := db.Snapshot().Work(owner.AgentID + ".events")
		must(err)
		return !exists
	})

	// A foreground interrupt may succeed while native background work remains
	// active. The new batch must close that owner and then use its saved profile.
	last = h.latest(owner.AgentID)
	waitFor(func() bool { last.mu.Lock(); defer last.mu.Unlock(); return last.closed })
	orphan, err = sessions.Open(ctx, plugin.OpenSessionRequest{SessionKey: "primary", Injection: *last.open.Injection})
	must(err)
	_, err = orphan.Send(ctx, model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "unowned background continuation"}}}, nil, nil)
	must(err)
	orphanSend = awaitSend()
	var backgroundState state
	must(json.Unmarshal(orphanSend.handle.open.SessionState.Read(), &backgroundState))
	backgroundState.Observation.BackgroundWork = &model.PublicBackgroundWork{Status: "running"}
	backgroundState.Observation.LatestExecution.Status = "completed"
	finished := time.Now().UnixMilli()
	backgroundState.Observation.LatestExecution.FinishedAt = &finished
	must(orphanSend.handle.open.SessionState.Commit(ctx, raw(backgroundState)))
	save(func(value *model.Settings) {
		if independent {
			setIndependent(value, "after-native-background")
		} else {
			value.Moku.ExecutionHarnesses["fixture"] = raw(model.Object{"model": "after-native-background"})
		}
	})
	trigger()
	afterBackground := awaitSend()
	orphanSend.handle.mu.Lock()
	orphanClosed := orphanSend.handle.closed
	orphanSend.handle.mu.Unlock()
	if !orphanClosed || afterBackground.execution == orphanSend.execution || afterBackground.model != "after-native-background" || afterBackground.handle.open.ReadThread().Observation.BackgroundWork != nil {
		panic("new batch did not drain native background work before reconfiguration")
	}
	work, exists, err = db.Snapshot().Work(owner.AgentID + ".events")
	must(err)
	if !exists || work.Attempts != 1 {
		panic("orphan background drain consumed an execution retry")
	}
	finishReportFixture(ctx, afterBackground.handle, "completed")
}
