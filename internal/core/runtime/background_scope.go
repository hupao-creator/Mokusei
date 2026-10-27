package runtime

import (
	"context"
	"errors"

	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

// Every declared branch is intersected with instance authority. In particular,
// a foreign explicit scope matches nothing rather than being rewritten to ours.
type scopedLifecycle struct {
	base  *lifecycleCapability
	owner plugin.BackgroundAgentRef
}

func (s scopedLifecycle) restrict(scope plugin.LifecycleScope) plugin.LifecycleScope {
	result := plugin.LifecycleScope{}
	for _, filter := range cloneLifecycleScope(scope) {
		if s.owner.Binding.Kind == plugin.DirectoryScopeKind {
			if filter.Scope != "" && filter.Scope != s.owner.Binding.Scope {
				continue
			}
			filter.Scope = s.owner.Binding.Scope
		}
		result = append(result, filter)
	}
	return result
}
func (s scopedLifecycle) Register(def plugin.LifecycleConsumerDefinition) (plugin.LifecycleConsumer, error) {
	if err := s.owner.Binding.Validate(); err != nil {
		return nil, err
	}
	def.ID = s.owner.AgentID + "." + def.ID
	if def.History == nil {
		def.History = def.Filter
	}
	def.Filter = s.restrict(def.Filter)
	def.History = s.restrict(def.History)
	consumer, err := s.base.Register(def)
	if err != nil {
		return nil, err
	}
	return boundConsumer{LifecycleConsumer: consumer, owner: s.owner}, nil
}
func (s scopedLifecycle) Subscribe(ctx context.Context, scope plugin.LifecycleScope, listener func(plugin.LifecycleEvent)) (func(), error) {
	if err := s.owner.Binding.Validate(); err != nil {
		return nil, err
	}
	return s.base.Subscribe(ctx, s.restrict(scope), listener)
}

type boundConsumer struct {
	plugin.LifecycleConsumer
	owner plugin.BackgroundAgentRef
}

func (c boundConsumer) ServiceDraining() bool {
	state, ok := c.LifecycleConsumer.(interface{ ServiceDraining() bool })
	return ok && state.ServiceDraining()
}

func (c boundConsumer) Subscribe(ctx context.Context, listener func(plugin.LifecycleNotification), observe *plugin.PrivateSessionRef) (func(), error) {
	if observe != nil && (observe.Owner.PluginID != c.owner.PluginID || observe.Owner.AgentID != c.owner.AgentID || observe.Owner.Binding != c.owner.Binding) {
		return nil, errors.New("cannot observe another background instance's session")
	}
	if observe != nil {
		copy := *observe
		observe = &copy
	}
	return c.LifecycleConsumer.Subscribe(ctx, listener, observe)
}
