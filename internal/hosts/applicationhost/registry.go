package applicationhost

import (
	"errors"
	"fmt"
	"slices"
	"sync"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

type registry struct {
	host   *Host
	owner  string
	mu     sync.Mutex
	closed bool
}

func (r *registry) close() {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.closed = true
}

func (r *registry) identity(id, owner string) error {
	if r.closed {
		return errors.New("application registration is closed")
	}
	if owner != r.owner || !contributionID.MatchString(id) || len(id) <= len(owner) || id[:len(owner)+1] != owner+"." {
		return fmt.Errorf("contribution %q is outside plugin %s", id, r.owner)
	}
	return nil
}
func validateContract(c plugin.ValueContract) error {
	if c.ID == "" || c.SchemaVersion < 1 || c.Parse == nil {
		return fmt.Errorf("invalid value contract %q", c.ID)
	}
	return nil
}
func detachedContract(contract plugin.ValueContract) plugin.ValueContract {
	contract.JSONSchema = model.CloneRaw(contract.JSONSchema)
	return contract
}
func detachedOperation(operation plugin.Operation) plugin.Operation {
	operation.Input = detachedContract(operation.Input)
	operation.Output = detachedContract(operation.Output)
	return operation
}
func (r *registry) Collection(d plugin.CollectionDefinition) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if err := r.identity(d.ID, d.OwnerPluginID); err != nil {
		return err
	}
	if err := validateContract(d.Contract); err != nil {
		return err
	}
	if d.Retention != "history" && d.Retention != "settings" {
		return errors.New("invalid collection retention")
	}
	if _, ok := r.host.collections[d.ID]; ok {
		return errors.New("duplicate collection")
	}
	d.Contract = detachedContract(d.Contract)
	r.host.collections[d.ID] = d
	return nil
}
func (r *registry) Settings(d plugin.SettingsDefinition) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if err := r.identity(d.ID, d.OwnerPluginID); err != nil {
		return err
	}
	if err := validateContract(d.Contract); err != nil {
		return err
	}
	if _, err := d.Contract.Validate(d.Defaults); err != nil {
		return err
	}
	if _, ok := r.host.settings[d.ID]; ok {
		return errors.New("duplicate settings")
	}
	d.Contract = detachedContract(d.Contract)
	d.Defaults = model.CloneRaw(d.Defaults)
	d.Requires = slices.Clone(d.Requires)
	r.host.settings[d.ID] = d
	return nil
}
func (r *registry) operation(d plugin.Operation) error {
	if err := r.identity(d.ID, d.OwnerPluginID); err != nil {
		return err
	}
	if err := validateContract(d.Input); err != nil {
		return err
	}
	return validateContract(d.Output)
}
func (r *registry) Query(d plugin.QueryDefinition) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if err := r.operation(d.Operation); err != nil {
		return err
	}
	if d.Read == nil {
		return errors.New("query reader missing")
	}
	if _, ok := r.host.queries[d.ID]; ok {
		return errors.New("duplicate query")
	}
	if _, ok := r.host.external[d.ID]; ok {
		return errors.New("duplicate query")
	}
	d.Operation = detachedOperation(d.Operation)
	d.Requires = slices.Clone(d.Requires)
	r.host.queries[d.ID] = d
	return nil
}
func (r *registry) ExternalQuery(d plugin.ExternalQueryDefinition) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if err := r.operation(d.Operation); err != nil {
		return err
	}
	if d.Read == nil {
		return errors.New("external query reader missing")
	}
	if _, ok := r.host.queries[d.ID]; ok {
		return errors.New("duplicate query")
	}
	if _, ok := r.host.external[d.ID]; ok {
		return errors.New("duplicate query")
	}
	d.Operation = detachedOperation(d.Operation)
	d.Requires = slices.Clone(d.Requires)
	d.SnapshotRequires = slices.Clone(d.SnapshotRequires)
	r.host.external[d.ID] = d
	return nil
}
func (r *registry) Command(d plugin.CommandDefinition) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if err := r.operation(d.Operation); err != nil {
		return err
	}
	if d.Plan == nil || d.Reduce == nil {
		return errors.New("command planner/reducer missing")
	}
	if !slices.Contains([]string{"deny", "batch-required", "allow-unbatched"}, d.Audience.Background) {
		return errors.New("invalid command audience")
	}
	if _, ok := r.host.commands[d.ID]; ok {
		return errors.New("duplicate command")
	}
	d.Operation = detachedOperation(d.Operation)
	d.Requires = slices.Clone(d.Requires)
	r.host.commands[d.ID] = d
	return nil
}
func (r *registry) ThreadType(d plugin.ThreadTypeDefinition) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if err := r.identity(d.ID, d.OwnerPluginID); err != nil {
		return err
	}
	if err := validateContract(d.Contract); err != nil {
		return err
	}
	if d.Project == nil || d.DisplayName == "" {
		return errors.New("invalid thread type")
	}
	if _, ok := r.host.threadTypes[d.ID]; ok {
		return errors.New("duplicate thread type")
	}
	d.Contract = detachedContract(d.Contract)
	r.host.threadTypes[d.ID] = d
	return nil
}
func (r *registry) BackgroundAgent(d plugin.BackgroundAgentDefinition) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if err := r.identity(d.ID, r.owner); err != nil {
		return err
	}
	if d.InstancePolicy != plugin.GlobalInstance && d.InstancePolicy != plugin.PerDirectoryScope {
		return errors.New("background agent requires an explicit instance policy")
	}
	if d.Create == nil {
		return errors.New("background agent factory missing")
	}
	if _, ok := r.host.agents[d.ID]; ok {
		return errors.New("duplicate background agent")
	}
	d.Requires = slices.Clone(d.Requires)
	r.host.agents[d.ID] = ownedAgent{r.owner, d}
	return nil
}
func (h *Host) validateRegistry() error {
	for _, owner := range sortedKeys(h.manifests) {
		manifest := h.manifests[owner]
		actual := plugin.Contributions{}
		for id, d := range h.collections {
			if d.OwnerPluginID == owner {
				actual.Collections = append(actual.Collections, id)
			}
		}
		for id, d := range h.settings {
			if d.OwnerPluginID == owner {
				actual.Settings = append(actual.Settings, id)
			}
		}
		for id, d := range h.queries {
			if d.OwnerPluginID == owner {
				actual.Queries = append(actual.Queries, id)
			}
		}
		for id, d := range h.external {
			if d.OwnerPluginID == owner {
				actual.Queries = append(actual.Queries, id)
			}
		}
		for id, d := range h.commands {
			if d.OwnerPluginID == owner {
				actual.Commands = append(actual.Commands, id)
			}
		}
		for id, d := range h.threadTypes {
			if d.OwnerPluginID == owner {
				actual.ThreadTypes = append(actual.ThreadTypes, id)
			}
		}
		for id, d := range h.agents {
			if d.owner == owner {
				actual.BackgroundAgents = append(actual.BackgroundAgents, id)
			}
		}
		pairs := [][2][]string{{manifest.Contributes.Collections, actual.Collections}, {manifest.Contributes.Settings, actual.Settings}, {manifest.Contributes.Queries, actual.Queries}, {manifest.Contributes.Commands, actual.Commands}, {manifest.Contributes.ThreadTypes, actual.ThreadTypes}, {manifest.Contributes.BackgroundAgents, actual.BackgroundAgents}}
		all := map[string]bool{}
		for _, pair := range pairs {
			for _, id := range pair[0] {
				if all[id] {
					return fmt.Errorf("duplicate contribution %s", id)
				}
				all[id] = true
			}
			left := slices.Clone(pair[0])
			right := slices.Clone(pair[1])
			slices.Sort(left)
			slices.Sort(right)
			if !slices.Equal(left, right) {
				return fmt.Errorf("application %s manifest contributions do not match registration", owner)
			}
		}
	}
	collectionsUsed := map[string]bool{}
	for _, definition := range h.threadTypes {
		if collectionsUsed[definition.CollectionID] {
			return fmt.Errorf("collection %s has multiple thread types", definition.CollectionID)
		}
		collectionsUsed[definition.CollectionID] = true
		collection, ok := h.collections[definition.CollectionID]
		if !ok || collection.OwnerPluginID != definition.OwnerPluginID {
			return fmt.Errorf("thread type %s has invalid collection", definition.ID)
		}
		if definition.Classification != nil && definition.Tags == nil {
			return fmt.Errorf("thread type %s classification requires tags", definition.ID)
		}
	}
	for _, agent := range h.agents {
		if id := agent.definition.ExecutionSettingsID; id != "" {
			definition, ok := h.settings[id]
			if !ok || definition.OwnerPluginID != agent.owner {
				return fmt.Errorf("background agent %s has invalid settings", agent.definition.ID)
			}
		}
	}
	return nil
}
