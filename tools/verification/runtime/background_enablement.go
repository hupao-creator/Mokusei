package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
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

// Capture only the host-bound client; the production application and runner
// still own registration, tools, session lifecycle and command implementation.
type enablementApplication struct {
	plugin.Application
	capture func(plugin.BackgroundAgentContext)
}

func (a enablementApplication) Register(registry plugin.Registry) error {
	return a.Application.Register(enablementRegistry{Registry: registry, capture: a.capture})
}

type enablementRegistry struct {
	plugin.Registry
	capture func(plugin.BackgroundAgentContext)
}

func (r enablementRegistry) BackgroundAgent(def plugin.BackgroundAgentDefinition) error {
	create := def.Create
	def.Create = func(ctx plugin.BackgroundAgentContext) (plugin.RuntimeParticipant, error) {
		r.capture(ctx)
		return create(ctx)
	}
	return r.Registry.BackgroundAgent(def)
}
func expectBackgroundDisabled(err error) {
	var failure *model.Error
	if !errors.As(err, &failure) || failure.Code != "BACKGROUND_AGENT_DISABLED" {
		panic(fmt.Sprintf("missing disabled admission fence: %v", err))
	}
}

// Real settings CAS, production participants, tools and SQLite recovery share
// one controlled Harness. The disabled roles remain registered for reading.
func verifyBackgroundEnablement(ctx context.Context) {
	for _, independent := range []bool{false, true} {
		verifyBackgroundEnablementCase(ctx, independent)
	}
	fmt.Println("PASS independent Tag/Report switches: defaults, validation, active cancellation, native/write fences, repeated pause refunds, data/receipt retention, disabled startup and durable resume")
}

func verifyBackgroundEnablementCase(ctx context.Context, independent bool) {
	root, err := os.MkdirTemp("", "mokusei-background-enablement-")
	must(err)
	defer os.RemoveAll(root)
	var db *store.Store
	var r *core.Runtime
	var app *applicationhost.Host
	var h *backgroundSettingsHarness
	var reportClients sync.Map
	open := func() {
		var err error
		db, err = store.Open(filepath.Join(root, "state.sqlite"))
		must(err)
		h = &backgroundSettingsHarness{sends: make(chan backgroundSettingsSend, 32)}
		r, err = core.New(ctx, core.Config{Store: db, Harnesses: map[string]plugin.Harness{"fixture": h}, DataDir: root, DefaultCwd: root, ExtraCapabilities: map[string]any{plugin.OverviewControlCapabilityKey.ID: backgroundSettingsOverview{}}})
		must(err)
		app, err = applicationhost.New(ctx, applicationhost.Config{Store: db, Applications: []plugin.Application{tag.New(), enablementApplication{Application: report.New(), capture: func(ctx plugin.BackgroundAgentContext) { reportClients.Store(ctx.Owner.AgentID, ctx.Domain) }}}, RuntimeCapabilities: r.RuntimeCapabilities, BackgroundCapabilities: r.BackgroundCapabilities, SnapshotCapabilities: r.SnapshotCapabilities, DirectoryScopes: r.DirectoryScopes})
		must(err)
		r.SetApplications(app)
	}
	open()
	defer func() { must(r.Close(ctx)); must(db.Close()) }()
	_, err = r.EnsureExecutionSettings(ctx, "fixture", "")
	must(err)
	save := func(change func(*model.Settings)) {
		settings, revision, err := r.Settings()
		must(err)
		change(&settings)
		result, err := r.UpdateSettings(ctx, revision, settings)
		must(err)
		if result.Status != "saved" {
			panic("enablement save conflicted")
		}
	}
	set := func(settings *model.Settings, role string, enabled bool) {
		for i, entry := range settings.PluginSettings {
			if entry.ID == role+".settings" {
				var value model.Object
				must(json.Unmarshal(entry.Value, &value))
				value["enabled"] = enabled
				settings.PluginSettings[i].Value = raw(value)
				return
			}
		}
		panic("missing enablement settings")
	}
	for _, role := range []string{"tag", "report"} {
		settings, _, err := r.Settings()
		must(err)
		must(plugin.RequireBackgroundExecution(settings, role+".settings"))
		// Invalid external values must not alter either saved settings or revision.
		for _, invalid := range []any{nil, "false", 0} {
			settings, revision, err := r.Settings()
			must(err)
			for i, entry := range settings.PluginSettings {
				if entry.ID == role+".settings" {
					settings.PluginSettings[i].Value = raw(model.Object{"mode": "inherit", "enabled": invalid})
				}
			}
			if _, err := r.UpdateSettings(ctx, revision, settings); err == nil {
				panic("invalid enabled value admitted")
			}
			_, after, err := r.Settings()
			must(err)
			if after != revision {
				panic("invalid enabled value changed revision")
			}
		}
	}
	if independent {
		save(func(settings *model.Settings) {
			for i, entry := range settings.PluginSettings {
				settings.PluginSettings[i].Value = raw(model.Object{"mode": "override", "harnessPreference": "fixture", "harnesses": model.Object{"fixture": model.Object{"model": entry.ID}}})
			}
		})
	}
	save(func(settings *model.Settings) { set(settings, "tag", false); set(settings, "report", false) })
	must(app.Start(ctx, plugin.RuntimeStartContext{Reason: "startup"}))
	trigger := func() model.ThreadRecord {
		created, err := r.CreateThread(ctx, core.CreateThreadRequest{HarnessID: "fixture", Cwd: root, Input: model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "switch evidence"}}}})
		must(err)
		finishReportFixture(ctx, h.latest(created.Record.ID), "completed")
		return created.Record
	}
	source := trigger()
	noSend := func() {
		select {
		case sent := <-h.sends:
			panic("disabled role sent work: " + sent.handle.open.ReadThread().Cwd)
		case <-time.After(120 * time.Millisecond):
		}
	}
	noSend()
	await := func(role string) backgroundSettingsSend {
		select {
		case sent := <-h.sends:
			if filepath.Base(filepath.Dir(sent.handle.open.ReadThread().Cwd)) != role {
				panic("wrong role admitted while its peer is disabled")
			}
			return sent
		case <-time.After(4 * time.Second):
			panic("enabled role did not resume: " + role)
		}
	}
	owner := func(role string) plugin.BackgroundAgentRef {
		for _, candidate := range app.BackgroundInstances() {
			if candidate.PluginID == role && candidate.Binding.Scope == directorytag.Scope(root) {
				return candidate
			}
		}
		panic("missing enablement owner")
	}
	settle := func(sent backgroundSettingsSend, role string) {
		finishReportFixture(ctx, sent.handle, "completed")
		id := owner(role).AgentID
		// Recovery can retain an admitted batch plus later queued events. Drain
		// every real send rather than treating the first batch as the whole inbox.
		deadline := time.NewTimer(4 * time.Second)
		defer deadline.Stop()
		tick := time.NewTicker(time.Millisecond)
		defer tick.Stop()
		for {
			_, exists, err := db.Snapshot().Work(id + ".events")
			must(err)
			sent.handle.mu.Lock()
			closed := sent.handle.closed
			sent.handle.mu.Unlock()
			if !exists && closed {
				return
			}
			select {
			case next := <-h.sends:
				if filepath.Base(filepath.Dir(next.handle.open.ReadThread().Cwd)) != role {
					panic("peer admitted during inbox drain")
				}
				finishReportFixture(ctx, next.handle, "completed")
				sent = next
			case <-tick.C:
			case <-deadline.C:
				panic("background inbox did not settle: " + role)
			}
		}
	}
	save(func(settings *model.Settings) { set(settings, "tag", true) })
	tagged := await("tag")
	_, err = reportTool(ctx, tagged.handle, "create_tags", "keep-tag", model.Object{"tags": []any{model.Object{"name": "Keep", "emoji": "🏷️"}}})
	must(err)
	_, err = reportTool(ctx, tagged.handle, "set_thread_tags", "keep-assignment", model.Object{"assignments": []any{model.Object{"thread": model.Object{"threadId": source.ID, "typeId": "agent"}, "tags": []string{"Keep"}}}})
	must(err)
	settle(tagged, "tag")
	save(func(settings *model.Settings) { set(settings, "tag", false); set(settings, "report", true) })
	reported := await("report")
	_, err = reportTool(ctx, reported.handle, "create_report", "keep-report", model.Object{"emoji": "📊", "shortDescription": "Report introduction", "title": "Kept report", "html": "<p>Kept content</p>", "coverHTML": "<div>Kept report</div>"})
	must(err)
	settle(reported, "report")
	// Alternate active pauses more times than the failure retry budget, retaining
	// batch identity, event IDs and receipts and keeping the other role idle.
	for _, role := range []string{"report", "tag"} {
		save(func(settings *model.Settings) {
			set(settings, "tag", role == "tag")
			set(settings, "report", role == "report")
		})
		trigger()
		current := await(role)
		id := owner(role).AgentID
		tool := map[string]string{"tag": "create_tags", "report": "create_report"}[role]
		args := model.Object{"tags": []any{model.Object{"name": "Keep", "emoji": "🏷️"}}}
		if role == "report" {
			args = model.Object{"emoji": "📊", "shortDescription": "Report introduction", "title": "Receipt report", "html": "<p>Once only</p>", "coverHTML": "<div>Receipt report</div>"}
		}
		receipt, err := reportTool(ctx, current.handle, tool, "retained-receipt", args)
		must(err)
		original, exists, err := db.Snapshot().Work(id + ".events")
		must(err)
		if !exists {
			panic("missing active batch")
		}
		caps := r.BackgroundCapabilities(owner(role), role+".settings")
		sessions, err := plugin.Require[plugin.BackgroundSessionsCapability](caps, plugin.BackgroundSessionsCapabilityKey)
		must(err)
		configuration, err := plugin.Require[plugin.BackgroundConfigurationCapability](caps, plugin.BackgroundConfigurationCapabilityKey)
		must(err)
		// Keep a facade so Send is tested independently of cancellation at the tool.
		facade, err := sessions.Open(ctx, plugin.OpenSessionRequest{SessionKey: "primary", Injection: *current.handle.open.Injection})
		must(err)
		for n := 0; n < 4; n++ {
			save(func(settings *model.Settings) { set(settings, role, false) })
			if _, err := configuration.Resolve(ctx, "primary"); err == nil {
				panic("disabled configuration resolved")
			}
			if _, err := sessions.Open(ctx, plugin.OpenSessionRequest{SessionKey: "primary"}); err == nil {
				panic("disabled session opened")
			}
			if _, err := facade.Send(ctx, model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "late send"}}}, nil, nil); err == nil {
				panic("disabled facade sent")
			}
			if _, err := current.handle.open.ExecutionAdmission.Accept(ctx, func(string) (json.RawMessage, error) { panic("disabled native admission reached projection") }); err == nil {
				panic("disabled native start admitted")
			}
			if role == "report" {
				client, ok := reportClients.Load(id)
				if !ok {
					panic("missing bound domain")
				}
				_, err := client.(plugin.DomainClient).Execute(ctx, "report.create", raw(model.Object{"emoji": "📊", "shortDescription": "Report introduction", "title": "Late report", "html": "<p>Blocked</p>", "coverHTML": "<div>Blocked report</div>", "relatedExecutions": []model.ExecutionRef{}}), plugin.DomainCommandOptions{RequestID: fmt.Sprint("late-domain-", n), Batch: &plugin.BatchWriteContext{ConsumerID: id + ".events", BatchID: original.ID, InvocationID: fmt.Sprint("late-domain-", n)}})
				expectBackgroundDisabled(err)
			}
			if role == "tag" {
				writes, err := plugin.Require[plugin.SemanticTagsWriteCapability](caps, plugin.SemanticTagsWriteCapabilityKey)
				must(err)
				if _, err := writes.Execute(ctx, plugin.SemanticTagOperation{Kind: "create", Name: "Late", Emoji: stringPointer("🏷️")}, plugin.BackgroundWriteOptions{RequestID: fmt.Sprint("late-", n)}); err == nil {
					panic("disabled tag write committed")
				}
			}
			if _, err := reportTool(ctx, current.handle, tool, fmt.Sprint("late-tool-", n), args); err == nil {
				panic("retired tool retained authority")
			}
			waitFor(func() bool { current.handle.mu.Lock(); defer current.handle.mu.Unlock(); return current.handle.closed })
			paused, exists, err := db.Snapshot().Work(id + ".events")
			must(err)
			if !exists || paused.ID != original.ID || paused.Attempts != 0 || len(paused.EventIDs) < len(original.EventIDs) || len(paused.Receipts) != len(original.Receipts) {
				panic(fmt.Sprintf("pause lost durable work/refund: %+v", paused))
			}
			noSend()
			save(func(settings *model.Settings) { set(settings, role, true) })
			current = await(role)
			replayed, err := reportTool(ctx, current.handle, tool, "retained-receipt", args)
			must(err)
			if string(replayed) != string(receipt) {
				panic("pause replaced committed receipt")
			}
		}
		previous := current
		save(func(settings *model.Settings) { set(settings, role, false) })
		save(func(settings *model.Settings) { set(settings, role, true) })
		current = await(role)
		previous.handle.mu.Lock()
		closed := previous.handle.closed
		previous.handle.mu.Unlock()
		if !closed || current.handle == previous.handle {
			panic("quick off/on reused revoked native owner")
		}
		settle(current, role)
	}
	// Disable before discovery returns: cancellation must release native discovery
	// without opening a model, consuming retries or delaying future enablement.
	entered, cancelled := make(chan struct{}), make(chan struct{})
	h.gateMu.Lock()
	h.gate = func(ctx context.Context) error { close(entered); <-ctx.Done(); close(cancelled); return ctx.Err() }
	h.gateMu.Unlock()
	trigger()
	select {
	case <-entered:
	case <-time.After(3 * time.Second):
		panic("discovery not entered")
	}
	save(func(settings *model.Settings) { set(settings, "tag", false) })
	select {
	case <-cancelled:
	case <-time.After(3 * time.Second):
		panic("disabled discovery not cancelled")
	}
	noSend()
	// Queued input while both roles are disabled must survive a new runtime owner.
	trigger()
	savedBefore, _, err := r.Settings()
	must(err)
	must(r.Close(ctx))
	must(db.Close())
	open()
	must(app.Start(ctx, plugin.RuntimeStartContext{Reason: "recovery"}))
	savedAfter, _, err := r.Settings()
	must(err)
	if string(raw(savedBefore.PluginSettings)) != string(raw(savedAfter.PluginSettings)) {
		panic("restart changed disabled profiles")
	}
	noSend()
	for _, role := range []string{"tag", "report"} {
		save(func(settings *model.Settings) {
			set(settings, "tag", role == "tag")
			set(settings, "report", role == "report")
		})
		sent := await(role)
		settle(sent, role)
	}
	tags, err := plugin.Require[plugin.SemanticTagsReadCapability](r.BackgroundCapabilities(owner("tag"), "tag.settings"), plugin.SemanticTagsReadCapabilityKey)
	must(err)
	pool, err := tags.CaptureList(ctx)
	must(err)
	thread, err := r.Thread(source.ID)
	must(err)
	if len(pool) != 1 || pool[0].Name != "Keep" || len(thread.Tags) != 1 || thread.Tags[0] != "Keep" {
		panic("toggle/restart deleted semantic data")
	}
	save(func(settings *model.Settings) { set(settings, "tag", false); set(settings, "report", false) })
	documents, err := app.Catalog(ctx)
	must(err)
	if len(documents) != 2 {
		panic("toggle/restart deleted report documents")
	}
	for _, document := range documents {
		_, err := app.Query(ctx, plugin.OperationRequest{PluginID: "report", OperationID: "report.html", Input: raw(report.IdentityInput{ReportID: document.ID})})
		must(err)
	}
	noSend()
}
