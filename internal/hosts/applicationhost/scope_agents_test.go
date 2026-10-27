package applicationhost

import (
	"context"
	"path/filepath"
	"sync"
	"testing"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/core/store"
)

type scopeTestParticipant struct{}

func (*scopeTestParticipant) Start(context.Context, plugin.RuntimeStartContext) error { return nil }
func (*scopeTestParticipant) Stop(context.Context) error                              { return nil }

type scopeTestApplication struct {
	mu      sync.Mutex
	started []string
}

func (*scopeTestApplication) Manifest() plugin.ApplicationManifest {
	return plugin.ApplicationManifest{ID: "scope", DisplayName: "Scope", APIVersion: 1,
		Contributes: plugin.Contributions{BackgroundAgents: []string{"scope.agent"}}}
}
func (a *scopeTestApplication) Register(registry plugin.Registry) error {
	return registry.BackgroundAgent(plugin.BackgroundAgentDefinition{
		ID: "scope.agent", InstancePolicy: plugin.PerDirectoryScope,
		Create: func(ctx plugin.BackgroundAgentContext) (plugin.RuntimeParticipant, error) {
			a.mu.Lock()
			a.started = append(a.started, ctx.Owner.Binding.Scope)
			a.mu.Unlock()
			return &scopeTestParticipant{}, nil
		},
	})
}
func (a *scopeTestApplication) scopes() []string {
	a.mu.Lock()
	defer a.mu.Unlock()
	return append([]string{}, a.started...)
}

func TestHostInstantiatesScopeTemplatesLazilyEnoughForNewScopes(t *testing.T) {
	ctx := context.Background()
	db, err := store.Open(filepath.Join(t.TempDir(), "state.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if _, err := db.Update(ctx, func(tx *store.Tx) error { return tx.Put("settings", model.Settings{}) }); err != nil {
		t.Fatal(err)
	}
	application := &scopeTestApplication{}
	var specs []plugin.DirectoryScope
	var mu sync.Mutex
	host, err := New(ctx, Config{Store: db, Applications: []plugin.Application{application},
		DirectoryScopes: func() ([]plugin.DirectoryScope, error) {
			mu.Lock()
			defer mu.Unlock()
			return append([]plugin.DirectoryScope{}, specs...), nil
		}})
	if err != nil {
		t.Fatal(err)
	}
	mu.Lock()
	specs = []plugin.DirectoryScope{{ID: "/workspace/one", Label: "One"}}
	mu.Unlock()
	if err := host.Start(ctx, plugin.RuntimeStartContext{Reason: "test"}); err != nil {
		t.Fatal(err)
	}
	if got := application.scopes(); len(got) != 1 || got[0] != "/workspace/one" {
		t.Fatalf("started scopes = %v", got)
	}
	mu.Lock()
	specs = append(specs, plugin.DirectoryScope{ID: "/workspace/two", Label: "Two"})
	mu.Unlock()
	if err := host.RefreshScopeAgents(ctx); err != nil {
		t.Fatal(err)
	}
	if got := application.scopes(); len(got) != 2 || got[1] != "/workspace/two" {
		t.Fatalf("refreshed scopes = %v", got)
	}
	// A repeated refresh must not duplicate an existing scope agent.
	if err := host.RefreshScopeAgents(ctx); err != nil {
		t.Fatal(err)
	}
	if got := application.scopes(); len(got) != 2 {
		t.Fatalf("duplicate scope agents: %v", got)
	}
	if err := host.Stop(ctx); err != nil {
		t.Fatal(err)
	}
	// A fresh generation must create its scope agents again instead of reusing
	// the previous generation's bookkeeping.
	if err := host.Start(ctx, plugin.RuntimeStartContext{Reason: "test-restart"}); err != nil {
		t.Fatal(err)
	}
	if got := application.scopes(); len(got) != 4 || got[2] != "/workspace/one" || got[3] != "/workspace/two" {
		t.Fatalf("restarted scopes = %v", got)
	}
	if err := host.Stop(ctx); err != nil {
		t.Fatal(err)
	}
}
