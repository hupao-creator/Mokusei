// Package composition wires the complete application inside the profile lease.
// Constructors allocate no native process or store; Initialize acquires them and
// Close joins them before daemon releases the single-writer ownership.
package composition

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	core "github.com/hupao-creator/Mokusei/internal/core/runtime"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/hosts/applicationhost"
	"github.com/hupao-creator/Mokusei/internal/hosts/contexthost"
	"github.com/hupao-creator/Mokusei/internal/platform/applicationprocess"
	"github.com/hupao-creator/Mokusei/internal/platform/environment"
	"github.com/hupao-creator/Mokusei/internal/platform/profile"
	"github.com/hupao-creator/Mokusei/internal/platform/transport"
	"github.com/hupao-creator/Mokusei/internal/plugins/applications/git"
	"github.com/hupao-creator/Mokusei/internal/plugins/applications/report"
	"github.com/hupao-creator/Mokusei/internal/plugins/applications/tag"
	"github.com/hupao-creator/Mokusei/internal/plugins/contexts/artificialanalysis"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/claude"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/codex"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/opencode"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/pi"
	"github.com/hupao-creator/Mokusei/internal/services/attachments"
	"github.com/hupao-creator/Mokusei/internal/services/localembedding"
	"github.com/hupao-creator/Mokusei/internal/services/moku"
	"github.com/hupao-creator/Mokusei/internal/services/workspaces"
)

type Options struct {
	Profile       profile.Profile
	Environment   map[string]string
	Headless      bool
	Log           func(string, error)
	SettingsTrace func(string, model.Object)
	SearchTrace   func(plugin.SearchDiagnostic)
	Overview      *transport.OverviewBroker
}
type Bootstrap struct {
	options           Options
	initOnce          sync.Once
	closeOnce         sync.Once
	initialized       chan struct{}
	initErr, closeErr error
	mu                sync.Mutex
	revoked           bool
	runtime           *core.Runtime
	store             *store.Store
	applications      *applicationhost.Host
	contexts          *contexthost.Host
	coordinator       *moku.Coordinator
	resolver          *environment.Resolver
	processes         *applicationprocess.Manager
	attachments       *attachments.Repository
	harnesses         map[string]plugin.Harness
	disabled          map[string]string
	enabled           map[string]bool
	ledgers           map[string]*moku.TelemetryLedger
	diagnostics       map[uint64]func(string)
	nextDiagnostic    uint64
	startupCancel     context.CancelFunc
}

func New(options Options) *Bootstrap {
	if options.Environment == nil {
		options.Environment = environment.Current()
	} else {
		copy := map[string]string{}
		for k, v := range options.Environment {
			copy[k] = v
		}
		options.Environment = copy
	}
	if options.Overview == nil {
		options.Overview = transport.NewOverviewBroker(10 * time.Second)
	}
	return &Bootstrap{options: options, initialized: make(chan struct{}), harnesses: map[string]plugin.Harness{}, disabled: map[string]string{}, enabled: map[string]bool{}, ledgers: map[string]*moku.TelemetryLedger{}, diagnostics: map[uint64]func(string){}}
}
func (b *Bootstrap) Initialize(ctx context.Context) (transport.Host, error) {
	b.initOnce.Do(func() {
		defer close(b.initialized)
		lifetime, cancel := context.WithCancel(ctx)
		b.mu.Lock()
		b.startupCancel = cancel
		if b.revoked {
			cancel()
		}
		b.mu.Unlock()
		b.initErr = b.open(lifetime)
	})
	<-b.initialized
	if b.initErr != nil {
		return nil, b.initErr
	}
	if err := b.running(ctx); err != nil {
		return nil, err
	}
	return b.runtime, nil
}
func (b *Bootstrap) running(ctx context.Context) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.revoked {
		return errors.New("runtime startup cancelled by shutdown")
	}
	return nil
}
func (b *Bootstrap) log(kind string, err error) {
	if err != nil && b.options.Log != nil {
		b.options.Log(kind, err)
	}
}

// Only semantic recovery notices enter Moku's transcript. Diagnostic logging
// itself never publishes, so reporting a failed listener cannot feed it again.
func (b *Bootstrap) publishDiagnostic(message string) {
	b.mu.Lock()
	listeners := make([]func(string), 0, len(b.diagnostics))
	for _, listener := range b.diagnostics {
		listeners = append(listeners, listener)
	}
	b.mu.Unlock()
	for _, listener := range listeners {
		func() {
			defer func() {
				if recovered := recover(); recovered != nil {
					b.log("diagnostic.listener", fmt.Errorf("listener failed: %v", recovered))
				}
			}()
			listener(message)
		}()
	}
}

func (b *Bootstrap) subscribeDiagnostics(listener func(string)) func() {
	b.mu.Lock()
	b.nextDiagnostic++
	id := b.nextDiagnostic
	b.diagnostics[id] = listener
	b.mu.Unlock()
	return func() { b.mu.Lock(); delete(b.diagnostics, id); b.mu.Unlock() }
}
func (b *Bootstrap) isEnabled(category, id string) bool {
	value, exists := b.enabled[category+":"+id]
	return !exists || value
}
func (b *Bootstrap) open(ctx context.Context) error {
	if err := b.running(ctx); err != nil {
		return err
	}
	data := b.options.Profile.DataDir
	workspace := b.options.Profile.WorkspaceRoot
	if data == "" || workspace == "" {
		return errors.New("composition requires resolved data and workspace profile paths")
	}
	stateRoot := filepath.Join(data, "mokusei-go-state-v1")
	mokuCwd := filepath.Join(workspace, "moku-workspace")
	temporary := filepath.Join(workspace, "tmp-workspaces")
	for _, path := range []string{stateRoot, mokuCwd, temporary, filepath.Join(workspace, "plugins")} {
		if err := os.MkdirAll(path, 0700); err != nil {
			return err
		}
	}
	defaultCwd, err := filepath.EvalSymlinks(workspace)
	if err != nil {
		return err
	}
	b.store, err = store.Open(filepath.Join(stateRoot, "state.sqlite"))
	if err != nil {
		return err
	}
	var persisted model.Settings
	if _, err = b.store.Snapshot().Get("settings", &persisted); err != nil {
		return err
	}
	for key, value := range persisted.PluginEnabled {
		b.enabled[key] = value
	}
	aaOptions := artificialanalysis.Options{Log: func(event string, fields map[string]any) {
		if b.options.Log != nil {
			b.options.Log("artificial-analysis."+event, artificialanalysis.DiagnosticSummary(fields))
		}
	}}
	if b.options.Headless {
		aaOptions.CacheRoot = filepath.Join(stateRoot, "model-evaluation")
	}
	applications := []plugin.Application{report.New(), tag.New(), git.New()}
	contextPlugins := []plugin.ContextPlugin{artificialanalysis.NewWithOptions(aaOptions)}
	b.contexts, err = contexthost.New(contexthost.Config{Plugins: contextPlugins, PluginEnabled: b.enabled})
	if err != nil {
		return err
	}
	var supplied map[string]string
	if b.options.Headless {
		supplied = b.options.Environment
	}
	b.resolver = environment.New(supplied)
	b.processes = applicationprocess.New(ctx, b.resolver)
	constructors := map[string]func(plugin.HostContext) plugin.Harness{
		"codex":    func(host plugin.HostContext) plugin.Harness { return codex.New(host) },
		"claude":   func(host plugin.HostContext) plugin.Harness { return claude.New(host) },
		"pi":       func(host plugin.HostContext) plugin.Harness { return pi.New(host) },
		"opencode": func(host plugin.HostContext) plugin.Harness { return opencode.New(host) },
	}
	ids := []string{"codex", "claude", "pi", "opencode"}
	for _, id := range ids {
		if !b.isEnabled("harness", id) {
			b.disabled[id] = "Harness plugin " + id + " is disabled."
		}
	}
	for _, id := range ids {
		ledger, err := moku.OpenTelemetryLedger(filepath.Join(stateRoot, "moku-telemetry-ledgers", id+".json"), moku.LedgerOptions{OnBackgroundPersistenceError: func(err error) { b.log("telemetry."+id, err) }})
		if err != nil {
			return err
		}
		b.ledgers[id] = ledger
	}
	for _, id := range ids {
		if err := b.running(ctx); err != nil {
			return err
		}
		host := plugin.HostContext{ResolveExecutable: b.resolver.ResolveExecutable, Environment: b.resolver.Environment, HarnessDataRoot: filepath.Join(stateRoot, "harnesses", id), TemporaryWorkspaceRoot: temporary}
		b.harnesses[id] = constructors[id](host)
	}
	catalog := []model.RuntimePlugin{}
	known := map[string]bool{}
	addPlugin := func(category, id string) {
		key := category + ":" + id
		known[key] = true
		catalog = append(catalog, model.RuntimePlugin{Key: key, Enabled: b.isEnabled(category, id), UnavailableReason: func() string {
			if category == "harness" {
				return b.disabled[id]
			}
			return ""
		}()})
	}
	for _, application := range applications {
		manifest := application.Manifest()
		if !manifest.BuiltIn {
			addPlugin("extension", manifest.ID)
		}
	}
	for _, module := range contextPlugins {
		manifest := module.Manifest()
		addPlugin("context", manifest.ID)
	}
	for _, id := range ids {
		addPlugin("harness", id)
	}
	// Sidecards remain native presentation plugins. Git is intentionally absent.
	addPlugin("sidecard", "conversation")
	addPlugin("sidecard", "iab")
	addPlugin("sidecard", "voice")
	for key := range persisted.PluginEnabled {
		if !known[key] {
			delete(b.enabled, key)
		}
	}
	if err := reconcilePluginPreferences(ctx, b.store, known); err != nil {
		return err
	}
	sort.Slice(catalog, func(i, j int) bool { return catalog[i].Key < catalog[j].Key })
	b.attachments = attachments.New(filepath.Join(stateRoot, "attachments"))
	manager := workspaces.New(workspaces.Paths{DefaultCwd: defaultCwd, MokuCwd: mokuCwd, TemporaryRoot: temporary, RegistryPath: filepath.Join(stateRoot, "managed-worktrees.json")})
	runtimeConfig := core.Config{Store: b.store, Harnesses: b.harnesses, DataDir: stateRoot, DefaultCwd: defaultCwd, Attachments: b.attachments, Contexts: b.contexts, Plugins: catalog, Log: b.log, Workspaces: manager, DisabledHarnesses: b.disabled, RefreshEnvironment: b.resolver.Refresh, ExtraCapabilities: map[string]any{plugin.OverviewControlCapabilityKey.ID: overviewControl{broker: b.options.Overview}}}
	runtimeConfig.Embeddings = localembedding.New(localembedding.Options{Directory: filepath.Join(stateRoot, "search-models"), Trace: b.options.SearchTrace})
	runtimeConfig.TelemetryLedger = b.ledger
	runtimeConfig.SettingsTrace = b.options.SettingsTrace
	runtimeConfig.SearchTrace = b.options.SearchTrace
	runtimeConfig.ProcessFactory = b.processes.ForCwd
	runtimeConfig.Diagnostic = b.publishDiagnostic
	runtimeConfig.OutputLocale = func(ctx context.Context) (string, error) { return readOutputLocale(ctx, b.options.Profile) }
	b.runtime, err = core.New(ctx, runtimeConfig)
	if err != nil {
		return err
	}
	b.applications, err = applicationhost.New(ctx, applicationhost.Config{Store: b.store, Applications: applications, PluginEnabled: b.enabled, RuntimeCapabilities: b.runtime.RuntimeCapabilities, BackgroundCapabilities: b.runtime.BackgroundCapabilities, SnapshotCapabilities: b.runtime.SnapshotCapabilities, DirectoryScopes: b.runtime.DirectoryScopes, InitializeSession: b.runtime.InitializeApplicationSession, ProjectSession: b.runtime.ProjectSession, ArchiveExecutions: b.runtime.ArchiveExecutions})
	if err != nil {
		return err
	}
	b.runtime.SetApplications(b.applications)
	err = b.runtime.RefreshApplicationDirectoryTags(ctx)
	if err != nil {
		return err
	}
	config := b.mokuConfiguration(mokuCwd, stateRoot)
	b.coordinator, err = moku.New(config)
	if err != nil {
		return err
	}
	b.runtime.SetMoku(b.coordinator)
	if err = b.running(ctx); err != nil {
		return err
	}
	if err = b.contexts.Start(ctx, plugin.RuntimeStartContext{Reason: "startup"}); err != nil {
		return err
	}
	err = b.applications.Start(ctx, plugin.RuntimeStartContext{Reason: "startup"})
	if err != nil {
		return err
	}
	b.runtime.StartRecovery()
	err = b.coordinator.Start(ctx, plugin.RuntimeStartContext{Reason: "startup"})
	if err != nil {
		return err
	}
	return b.running(ctx)
}
func (b *Bootstrap) Close(ctx context.Context) error {
	b.mu.Lock()
	b.revoked = true
	if b.startupCancel != nil {
		b.startupCancel()
	}
	b.mu.Unlock()
	b.options.Overview.Close()
	b.initOnce.Do(func() { b.initErr = context.Canceled; close(b.initialized) })
	b.closeOnce.Do(func() {
		<-b.initialized
		failures := []error{}
		if b.runtime != nil {
			failures = append(failures, b.runtime.Close(ctx))
		} else {
			if b.coordinator != nil {
				failures = append(failures, b.coordinator.Stop(ctx))
			}
			if b.contexts != nil {
				failures = append(failures, b.contexts.Stop(ctx))
			}
			if b.applications != nil {
				failures = append(failures, b.applications.Stop(ctx))
			}
		}
		b.mu.Lock()
		handles := make([]plugin.Harness, 0, len(b.harnesses))
		for _, h := range b.harnesses {
			handles = append(handles, h)
		}
		b.mu.Unlock()
		for _, h := range handles {
			if closer, ok := h.(plugin.Closer); ok {
				failures = append(failures, closer.Close())
			}
		}
		if b.resolver != nil {
			if b.processes != nil {
				failures = append(failures, b.processes.Close(ctx))
			}
			failures = append(failures, b.resolver.Close())
		}
		for _, ledger := range b.ledgers {
			failures = append(failures, ledger.Close(ctx))
		}
		if b.store != nil {
			failures = append(failures, b.store.Close())
		}
		b.closeErr = errors.Join(failures...)
	})
	return b.closeErr
}

func (b *Bootstrap) ledger(id string) plugin.TelemetryLedger {
	ledger := b.ledgers[id]
	if ledger == nil {
		return nil
	}
	return ledger
}
