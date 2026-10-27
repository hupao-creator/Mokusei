package applicationhost

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"sync"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

func (h *Host) Start(ctx context.Context, start plugin.RuntimeStartContext) (err error) {
	h.mu.Lock()
	if h.running {
		h.mu.Unlock()
		return errors.New("application host already started")
	}
	lifetime, cancel := context.WithCancel(ctx)
	h.generationCtx = lifetime
	h.generationCancel = cancel
	h.startDone = make(chan struct{})
	done := h.startDone
	h.running = true
	h.stopping = false
	h.participants = nil
	h.mu.Unlock()
	var finish sync.Once
	defer func() {
		finish.Do(func() { close(done) })
		if err != nil {
			_ = h.Stop(context.Background())
		}
	}()
	for _, id := range sortedKeys(h.agents) {
		agent := h.agents[id]
		if agent.definition.InstancePolicy != plugin.GlobalInstance || !h.enabled(agent.owner) {
			continue
		}
		if err = lifetime.Err(); err != nil {
			return err
		}
		owner := plugin.BackgroundAgentRef{PluginID: agent.owner, AgentID: id, Binding: plugin.ScopeBinding{Kind: plugin.GlobalScope}}
		if e := h.startAgent(lifetime, start, owner, agent.definition); e != nil {
			return e
		}
	}
	if err = h.startScopeAgents(lifetime, start); err != nil {
		return err
	}
	return lifetime.Err()
}

func (h *Host) startAgent(ctx context.Context, start plugin.RuntimeStartContext, owner plugin.BackgroundAgentRef, definition plugin.BackgroundAgentDefinition) error {
	var capabilities plugin.CapabilityAccess
	if h.config.BackgroundCapabilities != nil {
		capabilities = h.config.BackgroundCapabilities(owner, definition.ExecutionSettingsID)
	} else if len(definition.Requires) > 0 {
		return errors.New("background capability binder is required")
	}
	participant, err := definition.Create(plugin.BackgroundAgentContext{Owner: owner, Capabilities: restrictCapabilities(capabilities, definition.Requires, "runtime"), Domain: domainClient{host: h, owner: owner}, Settings: settingsReader{host: h, owner: owner.PluginID}})
	if err != nil {
		return err
	}
	if participant == nil {
		return errors.New("nil background participant")
	}
	h.mu.Lock()
	h.participants = append(h.participants, participant)
	h.mu.Unlock()
	if err := participant.Start(ctx, start); err != nil {
		return err
	}
	h.mu.Lock()
	h.instances[owner.AgentID] = owner
	h.mu.Unlock()
	return nil
}

// RefreshScopeAgents instantiates agents for scopes discovered after startup.
// Existing scope agents are left untouched. New agents inherit the host
// generation lifetime so a transient caller context cannot stop them.
func (h *Host) RefreshScopeAgents(ctx context.Context) error {
	h.mu.Lock()
	running := h.running && !h.stopping
	lifetime := h.generationCtx
	h.mu.Unlock()
	if !running || lifetime == nil {
		return nil
	}
	return h.startScopeAgents(lifetime, plugin.RuntimeStartContext{Reason: "scope-refresh"})
}

// BackgroundInstances returns the identities admitted in this host generation.
func (h *Host) BackgroundInstances() []plugin.BackgroundAgentRef {
	h.mu.Lock()
	defer h.mu.Unlock()
	result := []plugin.BackgroundAgentRef{}
	for _, id := range sortedKeys(h.instances) {
		result = append(result, h.instances[id])
	}
	return result
}
func (h *Host) startScopeAgents(ctx context.Context, start plugin.RuntimeStartContext) error {
	if h.config.DirectoryScopes == nil {
		for _, agent := range h.agents {
			if agent.definition.InstancePolicy == plugin.PerDirectoryScope && h.enabled(agent.owner) {
				return errors.New("directory scope catalog is required")
			}
		}
		return nil
	}
	scopes, err := h.config.DirectoryScopes()
	if err != nil {
		return err
	}
	// Validate the complete catalog before starting any of its instances.
	seen := map[string]bool{}
	for _, scope := range scopes {
		if err := scope.Validate(); err != nil {
			return err
		}
		if seen[scope.ID] {
			return errors.New("duplicate directory scope identity")
		}
		seen[scope.ID] = true
	}
	h.scopeMu.Lock()
	defer h.scopeMu.Unlock()
	h.mu.Lock()
	stopping := h.stopping
	h.mu.Unlock()
	if stopping {
		return nil
	}
	var failures []error
	for _, id := range sortedKeys(h.agents) {
		agent := h.agents[id]
		if agent.definition.InstancePolicy != plugin.PerDirectoryScope || !h.enabled(agent.owner) {
			continue
		}
		for _, scope := range scopes {
			suffix := "inbox"
			if scope.ID != "inbox" {
				sum := sha256.Sum256([]byte(scope.ID))
				suffix = hex.EncodeToString(sum[:8])
			}
			owner := plugin.BackgroundAgentRef{PluginID: agent.owner, AgentID: id + "." + suffix, Binding: plugin.ScopeBinding{Kind: plugin.DirectoryScopeKind, Scope: scope.ID}, ScopeLabel: scope.Label}
			h.mu.Lock()
			existing, exists := h.instances[owner.AgentID]
			h.mu.Unlock()
			if exists {
				if existing.PluginID != owner.PluginID || existing.Binding != owner.Binding {
					return fmt.Errorf("background instance identity collision: %s", owner.AgentID)
				}
				continue
			}
			if err := ctx.Err(); err != nil {
				return err
			}
			if err := h.startAgent(ctx, start, owner, agent.definition); err != nil {
				failures = append(failures, fmt.Errorf("start scope agent %s: %w", owner.AgentID, err))
			}
		}
	}
	return errors.Join(failures...)
}
func (h *Host) Stop(ctx context.Context) error {
	h.stopMu.Lock()
	defer h.stopMu.Unlock()
	h.mu.Lock()
	h.stopping = true
	if h.generationCancel != nil {
		h.generationCancel()
	}
	done := h.startDone
	h.mu.Unlock()
	if done != nil {
		select {
		case <-done:
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	// Wait out any in-flight scope-agent refresh so its participant is included
	// in the snapshot below rather than started after Stop returns.
	h.scopeMu.Lock()
	h.scopeMu.Unlock()
	h.mu.Lock()
	participants := append([]plugin.RuntimeParticipant{}, h.participants...)
	h.mu.Unlock()
	var wg sync.WaitGroup
	failures := make(chan error, len(participants))
	for _, participant := range participants {
		wg.Add(1)
		go func(p plugin.RuntimeParticipant) {
			defer wg.Done()
			if err := p.Stop(ctx); err != nil {
				failures <- err
			}
		}(participant)
	}
	wg.Wait()
	h.operations.Wait()
	close(failures)
	var errs []error
	for err := range failures {
		errs = append(errs, err)
	}
	if len(errs) == 0 {
		h.mu.Lock()
		h.running = false
		h.participants = nil
		h.instances = map[string]plugin.BackgroundAgentRef{}
		h.startDone = nil
		h.generationCancel = nil
		h.generationCtx = nil
		h.mu.Unlock()
	}
	return errors.Join(errs...)
}

type settingsReader struct {
	host  *Host
	owner string
}

func (r settingsReader) Read(id string) (plugin.SettingsSnapshot, error) {
	definition, ok := r.host.settings[id]
	if !ok || definition.OwnerPluginID != r.owner {
		return plugin.SettingsSnapshot{}, fmt.Errorf("settings unavailable: %s", id)
	}
	snapshot := r.host.config.Store.Snapshot()
	var settings model.Settings
	var revision int64
	if _, err := snapshot.Get("settings", &settings); err != nil {
		return plugin.SettingsSnapshot{}, err
	}
	if _, err := snapshot.Get("settings-revision", &revision); err != nil {
		return plugin.SettingsSnapshot{}, err
	}
	for _, entry := range settings.PluginSettings {
		if entry.ID == id {
			return plugin.SettingsSnapshot{SettingsRevision: revision, Value: model.CloneRaw(entry.Value)}, nil
		}
	}
	return plugin.SettingsSnapshot{}, fmt.Errorf("missing registered settings: %s", id)
}
func (r settingsReader) Subscribe(ctx context.Context, id string, listener func(plugin.SettingsSnapshot)) (func(), error) {
	if listener == nil {
		return nil, errors.New("nil settings listener")
	}
	initial, err := r.Read(id)
	if err != nil {
		return nil, err
	}
	changes, unsubscribe := r.host.config.Store.Subscribe()
	lifetime, cancel := context.WithCancel(ctx)
	done := make(chan struct{})
	var once sync.Once
	stop := func() { once.Do(func() { cancel(); unsubscribe() }) }
	go func() {
		defer close(done)
		defer stop()
		last := initial.SettingsRevision
		for {
			select {
			case _, ok := <-changes:
				if !ok {
					return
				}
				current, err := r.Read(id)
				if err != nil {
					return
				}
				if current.SettingsRevision != last {
					last = current.SettingsRevision
					listener(current)
				}
			case <-lifetime.Done():
				return
			}
		}
	}()
	return stop, nil
}
