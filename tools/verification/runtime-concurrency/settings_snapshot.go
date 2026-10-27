package main

import (
	"context"
	"encoding/json"
	"fmt"
	"sync"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	core "github.com/hupao-creator/Mokusei/internal/core/runtime"
)

type snapshotSettings struct {
	settings
	calls chan chan json.RawMessage
}

func (s snapshotSettings) SnapshotExecution(ctx context.Context, request plugin.SettingsRequest, initial bool) (json.RawMessage, error) {
	if !initial {
		return request.Settings, ctx.Err()
	}
	reply := make(chan json.RawMessage, 1)
	select {
	case s.calls <- reply:
	case <-ctx.Done():
		return nil, ctx.Err()
	}
	select {
	case value := <-reply:
		return value, nil
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

type namedHarness struct {
	plugin.Harness
	id string
}

type snapshotApplications struct{ core.Applications }

func (snapshotApplications) Catalog(context.Context) ([]model.ApplicationThread, error) {
	return nil, nil
}

func (snapshotApplications) BackgroundSettingsWorkspace(owner string) (string, string, bool) {
	return "report", "agent", owner == "report.settings"
}

func (h namedHarness) Descriptor() plugin.HarnessDescriptor {
	descriptor := h.Harness.Descriptor()
	descriptor.ID = h.id
	return descriptor
}

// An initialized presentation does no native I/O. Observe its lock wait through
// the cancellation boundary so the save interleaving needs no scheduling sleeps.
type waitingContext struct {
	context.Context
	waiting chan struct{}
	once    sync.Once
}

func (c *waitingContext) Done() <-chan struct{} {
	c.once.Do(func() { close(c.waiting) })
	return c.Context.Done()
}

func settingsPresentation(r *core.Runtime, ctx context.Context, owner, harnessID string) <-chan map[string]any {
	result := make(chan map[string]any, 1)
	go func() {
		request := model.Object{"scope": "global", "harnessId": harnessID, "executionOwner": "moku"}
		if owner != "moku" {
			delete(request, "executionOwner")
			request["applicationSettings"] = owner
		}
		value, err := r.SettingsPresentation(ctx, raw(request))
		must(err)
		result <- value.(map[string]any)
	}()
	return result
}

func verifySettingsSnapshotConvergence() {
	for _, mode := range []string{"moku", "inherit", "override"} {
		func() {
			r, h, cleanup := setup("normal", namedHarness{Harness: &harness{}, id: "other"})
			defer cleanup()
			owner := "moku"
			if mode != "moku" {
				owner = "report.settings"
				r.SetApplications(snapshotApplications{})
				current, revision, err := r.Settings()
				must(err)
				current.PluginSettings = []model.PluginSettings{{ID: owner, SchemaVersion: 1,
					Value: raw(model.Object{"mode": "inherit"})}}
				seeded, err := r.UpdateSettings(context.Background(), revision, current)
				must(err)
				assert(seeded.Status == "saved", "seed execution binding")
				if mode == "override" {
					// Use a second Harness as the initialized selection, leaving the
					// requested fixture profile missing until its presentation.
					current = seeded.Settings
					current.PluginSettings[0].Value = raw(model.Object{"mode": mode, "harnessPreference": "other", "harnesses": model.Object{}})
					seeded, err = r.UpdateSettings(context.Background(), seeded.SettingsRevision, current)
					must(err)
					assert(seeded.Status == "saved", "seed independent execution binding")
				}
			}
			calls := make(chan chan json.RawMessage, 2)
			h.settingsAPI = snapshotSettings{calls: calls}
			first := settingsPresentation(r, context.Background(), owner, "fixture")
			firstReply := receive(calls)
			second := settingsPresentation(r, context.Background(), owner, "fixture")
			secondReply := receive(calls)
			profile := raw(model.Object{"model": "gpt-6.1-sol", "effort": "medium"})
			firstReply <- profile
			assert(receive(first)["executionSnapshotError"] == nil, "first initialization failed")
			current, revision, err := r.Settings()
			must(err)
			// A delayed native reply may differ; the published profile is authority.
			secondReply <- raw(model.Object{"model": "obsolete native default"})
			assert(receive(second)["executionSnapshotError"] == nil, "concurrent initialization showed a false snapshot conflict")
			assert(receive(settingsPresentation(r, context.Background(), owner, "fixture"))["executionSnapshotError"] == nil, "initialized read failed")
			latest, latestRevision, err := r.Settings()
			must(err)
			assert(latestRevision == revision && string(raw(latest)) == string(raw(current)), "late initializer rewrote the authoritative profile or consumed a revision")
		}()
	}
	func() {
		calls := make(chan chan json.RawMessage, 2)
		extra := namedHarness{Harness: &harness{settingsAPI: snapshotSettings{calls: calls}}, id: "other"}
		r, h, cleanup := setup("normal", extra)
		defer cleanup()
		h.settingsAPI = snapshotSettings{calls: calls}
		first := settingsPresentation(r, context.Background(), "moku", "fixture")
		firstReply := receive(calls)
		second := settingsPresentation(r, context.Background(), "moku", "other")
		secondReply := receive(calls)
		firstReply <- raw(model.Object{"model": "first"})
		assert(receive(first)["executionSnapshotError"] == nil, "first Harness initialization failed")
		secondReply <- raw(model.Object{"model": "second"})
		assert(receive(second)["executionSnapshotError"] == nil, "sibling Harness initialization conflicted")
		latest, _, err := r.Settings()
		must(err)
		assert(latest.Moku.HostHarnessPreference == "fixture" && len(latest.Moku.ExecutionHarnesses) == 2, "late capture replaced selected Harness or lost a sibling profile")
	}()
	func() {
		r, h, cleanup := setup("normal")
		defer cleanup()
		calls := make(chan chan json.RawMessage, 1)
		h.settingsAPI = snapshotSettings{calls: calls}
		presentation := settingsPresentation(r, context.Background(), "moku", "fixture")
		reply := receive(calls)
		current, revision, err := r.Settings()
		must(err)
		current.Moku.HostHarnessPreference = "fixture"
		current.Moku.ExecutionHarnesses["fixture"] = raw(model.Object{"model": "user choice", "effort": "medium"})
		saved, err := r.UpdateSettings(context.Background(), revision, current)
		must(err)
		assert(saved.Status == "saved", "save newer execution choice")
		reply <- raw(model.Object{"model": "obsolete native default"})
		assert(receive(presentation)["executionSnapshotError"] == nil, "late initializer rejected a newer complete user choice")
		latest, revision, err := r.Settings()
		must(err)
		assert(revision == saved.SettingsRevision && string(raw(latest)) == string(raw(saved.Settings)), "late initialization overwrote user choice")
	}()
	func() {
		r, _, cleanup := setup("normal")
		defer cleanup()
		_, err := r.EnsureExecutionSettings(context.Background(), "fixture", "")
		must(err)
		var presentation <-chan map[string]any
		must(r.WithConfigurationAdmission(context.Background(), func(admission context.Context) error {
			ctx := &waitingContext{Context: context.Background(), waiting: make(chan struct{})}
			presentation = settingsPresentation(r, ctx, "moku", "fixture")
			receive(ctx.waiting)
			current, revision, err := r.Settings()
			must(err)
			current.Harnesses["fixture"] = raw(model.Object{"model": "new ordinary default"})
			saved, err := r.UpdateSettings(admission, revision, current)
			must(err)
			assert(saved.Status == "saved", "save while initialized presentation waits")
			return nil
		}))
		assert(receive(presentation)["executionSnapshotError"] == nil, "read with no native discovery showed a snapshot conflict")
	}()
	func() {
		extra := namedHarness{Harness: &harness{}, id: "other"}
		r, h, cleanup := setup("normal", extra)
		defer cleanup()
		calls := make(chan chan json.RawMessage, 1)
		h.settingsAPI = snapshotSettings{calls: calls}
		presentation := settingsPresentation(r, context.Background(), "moku", "fixture")
		reply := receive(calls)
		current, revision, err := r.Settings()
		must(err)
		current.Harnesses["other"] = raw(model.Object{"model": "unrelated default"})
		saved, err := r.UpdateSettings(context.Background(), revision, current)
		must(err)
		assert(saved.Status == "saved", "save unrelated native source")
		reply <- raw(model.Object{"model": "captured"})
		assert(receive(presentation)["executionSnapshotError"] == nil, "unrelated Harness default invalidated snapshot")
		latest, revision, err := r.Settings()
		must(err)
		assert(revision == saved.SettingsRevision+1 && string(latest.Harnesses["other"]) == string(saved.Settings.Harnesses["other"]), "capture lost unrelated source edit")
	}()
	fmt.Println("PASS native settings snapshot convergence across Moku/inherited/independent owners, newer user choice, initialized reads and unrelated Harness saves")
}
