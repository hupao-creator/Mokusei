package main

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"sync/atomic"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	core "github.com/hupao-creator/Mokusei/internal/core/runtime"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/hosts/contexthost"
)

func runtimeReplay() {
	ctx := context.Background()
	dir, err := os.MkdirTemp("", "oa-context-runtime-")
	must(err)
	defer os.RemoveAll(dir)
	db, err := store.Open(filepath.Join(dir, "state.sqlite"))
	must(err)
	defer db.Close()
	var created, closed atomic.Int64
	d := definition("fixture.evidence", "evaluation", "facts")
	d.Create = func() (plugin.MokuContextService, error) {
		created.Add(1)
		return &contextService{collect: func(context.Context, plugin.MokuContextInput) (string, error) { return "facts", nil }, close: func() error { closed.Add(1); return nil }}, nil
	}
	open := func() (*core.Runtime, *contexthost.Host) {
		var settings model.Settings
		_, err := db.Snapshot().Get("settings", &settings)
		must(err)
		h, err := contexthost.New(contexthost.Config{Plugins: []plugin.ContextPlugin{contextModule{id: "fixture", definitions: []plugin.MokuContextDefinition{d}}}, PluginEnabled: settings.PluginEnabled})
		must(err)
		value, present := settings.PluginEnabled["context:fixture"]
		r, err := core.New(ctx, core.Config{Store: db, DataDir: dir, DefaultCwd: dir, Harnesses: map[string]plugin.Harness{}, Contexts: h, Plugins: []model.RuntimePlugin{{Key: "context:fixture", Enabled: !present || value}}})
		must(err)
		must(h.Start(ctx, plugin.RuntimeStartContext{}))
		return r, h
	}
	r, h := open()
	settings, revision, err := r.Settings()
	must(err)
	settings.PluginEnabled = map[string]bool{"context:fixture": false}
	saved, err := r.UpdateSettings(ctx, revision, settings)
	must(err)
	check(saved.Status == "saved", "Context preference save")
	state, err := r.Snapshot()
	must(err)
	check(state.Plugins[0].Enabled && !state.Settings.PluginEnabled["context:fixture"], "pending versus active preference")
	must(r.ClearHistory(ctx))
	entries, err := h.CollectMokuContexts(ctx, "before-send", nil)
	must(err)
	check(len(entries) == 1 && created.Load() == 2 && closed.Load() == 1, "history reset restarts Context without applying pending preference")
	must(r.Close(ctx))
	check(closed.Load() == 2, "runtime shutdown owns Context stop")
	r, h = open()
	state, err = r.Snapshot()
	must(err)
	check(!state.Plugins[0].Enabled, "service restart applies saved disable")
	entries, err = h.CollectMokuContexts(ctx, "before-send", nil)
	must(err)
	check(len(entries) == 0 && created.Load() == 2, "disabled Context acquires nothing")
	settings, revision, err = r.Settings()
	must(err)
	settings.PluginEnabled = map[string]bool{"extension:fixture": true}
	_, err = r.UpdateSettings(ctx, revision, settings)
	check(err != nil, "old extension identity rejected")
	settings.PluginEnabled = map[string]bool{"context:fixture": true}
	_, err = r.UpdateSettings(ctx, revision, settings)
	must(err)
	must(r.Close(ctx))
	r, h = open()
	entries, err = h.CollectMokuContexts(ctx, "before-send", nil)
	must(err)
	check(len(entries) == 1 && created.Load() == 3, "restart re-enables Context")
	must(r.Close(ctx))
	check(closed.Load() == 3, "all Context generations drained")
	fmt.Println("PASS runtime Context settings/catalog, pending versus active state, history reset, shutdown and restart enablement")
}
