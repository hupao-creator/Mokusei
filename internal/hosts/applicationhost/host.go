// Package applicationhost composes application contributions and executes their
// pure domain transactions at the store's single durable publication boundary.
package applicationhost

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"slices"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/core/store"
)

type Config struct {
	Store                  *store.Store
	Applications           []plugin.Application
	PluginEnabled          map[string]bool
	Enabled                func(pluginID string) bool
	RuntimeCapabilities    func(pluginID string) plugin.CapabilityAccess
	BackgroundCapabilities func(plugin.BackgroundAgentRef, string) plugin.CapabilityAccess
	SnapshotCapabilities   func(store.Snapshot, func(string, int64) (plugin.MutationScope, error)) plugin.CapabilityAccess
	// DirectoryScopes supplies workspace identities only. The host owns agent
	// enumeration and stable instance identities for registered definitions.
	DirectoryScopes func() ([]plugin.DirectoryScope, error)
	// Initializes a real empty native session after resolving current user settings.
	InitializeSession func(context.Context, model.ThreadRef, plugin.ConversationConfiguration) (model.SessionRecord, error)
	// Projects durable native state for a catalog without leaking complete history.
	ProjectSession func(context.Context, model.SessionRecord) (model.SessionRecord, error)
	// User archive propagation must check the referenced execution is still latest.
	ArchiveExecutions func(*store.Tx, []model.ExecutionRef, bool) error
	Now               func() time.Time
}
type Host struct {
	config           Config
	manifests        map[string]plugin.ApplicationManifest
	collections      map[string]plugin.CollectionDefinition
	settings         map[string]plugin.SettingsDefinition
	queries          map[string]plugin.QueryDefinition
	external         map[string]plugin.ExternalQueryDefinition
	commands         map[string]plugin.CommandDefinition
	threadTypes      map[string]plugin.ThreadTypeDefinition
	agents           map[string]ownedAgent
	mu               sync.Mutex
	stopMu           sync.Mutex
	running          bool
	stopping         bool
	generationCtx    context.Context
	generationCancel context.CancelFunc
	startDone        chan struct{}
	participants     []plugin.RuntimeParticipant
	instances        map[string]plugin.BackgroundAgentRef
	scopeMu          sync.Mutex
	operations       sync.WaitGroup
}
type ownedAgent struct {
	owner      string
	definition plugin.BackgroundAgentDefinition
}

// BackgroundSettingsBindings exposes immutable registration facts so the host
// can capture agent-specific settings changes in the same settings transaction.
func (h *Host) BackgroundSettingsBindings() map[string]string {
	result := map[string]string{}
	for id, entry := range h.agents {
		if entry.definition.ExecutionSettingsID != "" {
			result[id] = entry.definition.ExecutionSettingsID
		}
	}
	return result
}

func (h *Host) BackgroundSettingsWorkspace(settingsID string) (string, string, bool) {
	for id, entry := range h.agents {
		if entry.definition.ExecutionSettingsID == settingsID {
			return entry.owner, id, true
		}
	}
	return "", "", false
}

var contributionID = regexp.MustCompile(`^[a-z][a-z0-9_.-]*$`)
var recordControl = regexp.MustCompile(`[\x00-\x1f]`)
var pluginID = regexp.MustCompile(`^[a-z][a-z0-9-]*$`)

func New(ctx context.Context, config Config) (*Host, error) {
	if config.Store == nil {
		return nil, errors.New("application store is required")
	}
	if config.Now == nil {
		config.Now = time.Now
	}
	h := &Host{config: config, manifests: map[string]plugin.ApplicationManifest{}, collections: map[string]plugin.CollectionDefinition{}, settings: map[string]plugin.SettingsDefinition{}, queries: map[string]plugin.QueryDefinition{}, external: map[string]plugin.ExternalQueryDefinition{}, commands: map[string]plugin.CommandDefinition{}, threadTypes: map[string]plugin.ThreadTypeDefinition{}, agents: map[string]ownedAgent{}, instances: map[string]plugin.BackgroundAgentRef{}}
	for _, application := range config.Applications {
		if application == nil {
			return nil, errors.New("nil application module")
		}
		manifest := detachedManifest(application.Manifest())
		if !pluginID.MatchString(manifest.ID) || manifest.DisplayName == "" || manifest.APIVersion != 1 {
			return nil, fmt.Errorf("invalid application manifest %q", manifest.ID)
		}
		if _, exists := h.manifests[manifest.ID]; exists {
			return nil, fmt.Errorf("duplicate application %s", manifest.ID)
		}
		h.manifests[manifest.ID] = manifest
		registration := &registry{host: h, owner: manifest.ID}
		err := application.Register(registration)
		registration.close()
		if err != nil {
			return nil, err
		}
	}
	if err := h.validateRegistry(); err != nil {
		return nil, err
	}
	if err := h.initializeSettings(ctx); err != nil {
		return nil, err
	}
	return h, nil
}
func (h *Host) begin() error {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.stopping {
		return errors.New("application host is stopping")
	}
	h.operations.Add(1)
	return nil
}
func (h *Host) enabled(id string) bool {
	if h.manifests[id].BuiltIn {
		return true
	}
	if h.config.Enabled != nil {
		return h.config.Enabled(id)
	}
	value, present := h.config.PluginEnabled["extension:"+id]
	return !present || value
}
func (h *Host) application(id string) error {
	if _, ok := h.manifests[id]; !ok {
		return fmt.Errorf("unknown application: %s", id)
	}
	if !h.enabled(id) {
		return fmt.Errorf("application is disabled: %s", id)
	}
	return nil
}
func (h *Host) Manifests() []plugin.ApplicationManifest {
	ids := sortedKeys(h.manifests)
	out := make([]plugin.ApplicationManifest, 0, len(ids))
	for _, id := range ids {
		out = append(out, detachedManifest(h.manifests[id]))
	}
	return out
}
func detachedManifest(manifest plugin.ApplicationManifest) plugin.ApplicationManifest {
	manifest.Contributes.BackgroundAgents = slices.Clone(manifest.Contributes.BackgroundAgents)
	manifest.Contributes.ThreadTypes = slices.Clone(manifest.Contributes.ThreadTypes)
	manifest.Contributes.Settings = slices.Clone(manifest.Contributes.Settings)
	manifest.Contributes.Collections = slices.Clone(manifest.Contributes.Collections)
	manifest.Contributes.Queries = slices.Clone(manifest.Contributes.Queries)
	manifest.Contributes.Commands = slices.Clone(manifest.Contributes.Commands)
	return manifest
}
func sortedKeys[T any](values map[string]T) []string {
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}
func validRecordID(id string) bool {
	return len(id) > 0 && model.UTF16Length(id) <= 128 && !recordControl.MatchString(id)
}
func recordKey(collection, id string) string { return "application:" + collection + ":" + id }
func collectionKey(collection string) string { return "application-collection:" + collection }
func orderKey(collection string) string      { return "application:" + collection }
func (h *Host) typeForCollection(collection string) (plugin.ThreadTypeDefinition, bool) {
	for _, definition := range h.threadTypes {
		if definition.CollectionID == collection {
			return definition, true
		}
	}
	return plugin.ThreadTypeDefinition{}, false
}

func readCollectionRevision(snap store.Snapshot, collection string) (int64, error) {
	var revision int64
	_, err := snap.Get(collectionKey(collection), &revision)
	return revision, err
}

type deniedCapabilities struct{}

func (deniedCapabilities) Require(key plugin.CapabilityKey) (any, error) {
	return nil, fmt.Errorf("capability unavailable: %s", key.ID)
}

type restrictedCapabilities struct {
	base    plugin.CapabilityAccess
	allowed map[plugin.CapabilityKey]bool
	phase   string
}

func (c restrictedCapabilities) Require(key plugin.CapabilityKey) (any, error) {
	if !c.allowed[key] || key.Phase != c.phase {
		return nil, fmt.Errorf("undeclared capability %s", key.ID)
	}
	return c.base.Require(key)
}
func restrictCapabilities(base plugin.CapabilityAccess, keys []plugin.CapabilityKey, phase string) plugin.CapabilityAccess {
	if base == nil {
		base = deniedCapabilities{}
	}
	allowed := map[plugin.CapabilityKey]bool{}
	for _, key := range keys {
		allowed[key] = true
	}
	return restrictedCapabilities{base: base, allowed: allowed, phase: phase}
}
func (h *Host) runtimeCapabilities(owner string, requires []plugin.CapabilityKey) plugin.CapabilityAccess {
	var base plugin.CapabilityAccess
	if h.config.RuntimeCapabilities != nil {
		base = h.config.RuntimeCapabilities(owner)
	}
	return restrictCapabilities(base, requires, "runtime")
}
func (h *Host) snapshotCapabilities(snap store.Snapshot, requires []plugin.CapabilityKey, issue func(string, int64) (plugin.MutationScope, error)) plugin.CapabilityAccess {
	var base plugin.CapabilityAccess
	if h.config.SnapshotCapabilities != nil {
		base = h.config.SnapshotCapabilities(snap, issue)
	}
	return restrictCapabilities(base, requires, "snapshot")
}

// ValidateSettings performs runtime checks outside the transaction. The caller
// must still compare settingsRevision when committing the complete draft.
func (h *Host) ValidateSettings(ctx context.Context, settings model.Settings) (model.Settings, error) {
	seen := map[string]bool{}
	for i, entry := range settings.PluginSettings {
		definition, ok := h.settings[entry.ID]
		if !ok {
			return settings, fmt.Errorf("unknown application settings %s", entry.ID)
		}
		if seen[entry.ID] {
			return settings, errors.New("duplicate application settings")
		}
		seen[entry.ID] = true
		if entry.SchemaVersion != definition.Contract.SchemaVersion {
			return settings, fmt.Errorf("incompatible settings schema %s", entry.ID)
		}
		value, err := definition.Contract.Validate(entry.Value)
		if err != nil {
			return settings, err
		}
		if definition.Validate != nil {
			value, err = definition.Validate(ctx, value, h.runtimeCapabilities(definition.OwnerPluginID, definition.Requires))
			if err != nil {
				return settings, err
			}
			value, err = definition.Contract.Validate(value)
			if err != nil {
				return settings, err
			}
		}
		settings.PluginSettings[i].Value = value
	}
	for id := range h.settings {
		if !seen[id] {
			return settings, fmt.Errorf("missing application settings %s", id)
		}
	}
	return settings, nil
}
func (h *Host) initializeSettings(ctx context.Context) error {
	_, err := h.config.Store.Update(ctx, func(tx *store.Tx) error {
		// Receipts are owned by a plugin or one of its background agents. A
		// removed owner can never replay them; disabled registered owners can.
		for _, key := range tx.Keys("application-command-receipt:") {
			source, _, _ := strings.Cut(strings.TrimPrefix(key, "application-command-receipt:"), ":")
			_, registered := h.manifests[source]
			for id, agent := range h.agents {
				if source == id || (agent.definition.InstancePolicy == plugin.PerDirectoryScope && strings.HasPrefix(source, id+".")) {
					registered = true
					break
				}
			}
			if !registered {
				if err := tx.Delete(key); err != nil {
					return err
				}
			}
		}
		var applied struct {
			Settings         model.Settings `json:"settings"`
			SettingsRevision int64          `json:"settingsRevision"`
		}
		if exists, err := tx.Get("moku-applied-settings", &applied); err != nil {
			return err
		} else if exists {
			if retained, changed := h.retainRegisteredSettings(applied.Settings.PluginSettings); changed {
				applied.Settings.PluginSettings = retained
				if err := tx.Put("moku-applied-settings", applied); err != nil {
					return err
				}
			}
		}
		var settings model.Settings
		exists, err := tx.Get("settings", &settings)
		if err != nil {
			return err
		}
		if !exists {
			return errors.New("runtime settings must exist before application host")
		}
		known := map[string]bool{}
		retained, changed := h.retainRegisteredSettings(settings.PluginSettings)
		settings.PluginSettings = retained
		for _, entry := range settings.PluginSettings {
			known[entry.ID] = true
		}
		for _, id := range sortedKeys(h.settings) {
			if known[id] {
				continue
			}
			d := h.settings[id]
			value, err := d.Contract.Validate(d.Defaults)
			if err != nil {
				return err
			}
			settings.PluginSettings = append(settings.PluginSettings, model.PluginSettings{ID: id, SchemaVersion: d.Contract.SchemaVersion, Value: value})
			changed = true
		}
		if !changed {
			return nil
		}
		return tx.Put("settings", settings)
	})
	return err
}

func (h *Host) retainRegisteredSettings(entries []model.PluginSettings) ([]model.PluginSettings, bool) {
	retained := make([]model.PluginSettings, 0, len(entries))
	for _, entry := range entries {
		if _, registered := h.settings[entry.ID]; registered {
			retained = append(retained, entry)
		}
	}
	return retained, len(retained) != len(entries)
}
