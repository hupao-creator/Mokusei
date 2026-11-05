package attention

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/plugins/applications/background"
)

type Plugin struct{}

func New() *Plugin { return &Plugin{} }
func (*Plugin) Manifest() plugin.ApplicationManifest {
	return plugin.ApplicationManifest{
		ID: "attention", DisplayName: "Attention", APIVersion: 1,
		Contributes: plugin.Contributions{Settings: []string{"attention.settings"}, BackgroundAgents: []string{"attention.agent"}},
	}
}

func (*Plugin) Register(reg plugin.Registry) error {
	if err := background.RegisterSettings(reg, "attention", "attention.settings"); err != nil {
		return err
	}
	return reg.BackgroundAgent(plugin.BackgroundAgentDefinition{
		ID: "attention.agent", ExecutionSettingsID: "attention.settings", InstancePolicy: plugin.GlobalInstance,
		Requires: []plugin.CapabilityKey{plugin.AttentionCapabilityKey, plugin.LifecycleCapabilityKey,
			plugin.BackgroundConfigurationCapabilityKey, plugin.BackgroundEnvironmentCapabilityKey, plugin.BackgroundSessionsCapabilityKey},
		Create: newAgent,
	})
}

type participant struct {
	*background.Runner
	attention plugin.AttentionCapability
	cancel    context.CancelFunc
	done      chan error
}

func (p *participant) Start(ctx context.Context, start plugin.RuntimeStartContext) error {
	if err := p.Runner.Start(ctx, start); err != nil {
		return err
	}
	lifetime, cancel := context.WithCancel(ctx)
	p.cancel = cancel
	p.done = make(chan error, 1)
	go func() { p.done <- p.attention.Schedule(lifetime) }()
	return nil
}

func (p *participant) Stop(ctx context.Context) error {
	var err error
	if p.cancel != nil {
		p.cancel()
		select {
		case err = <-p.done:
			p.cancel = nil
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	if errors.Is(err, context.Canceled) {
		err = nil
	}
	return errors.Join(err, p.Runner.Stop(ctx))
}

func newAgent(ctx plugin.BackgroundAgentContext) (plugin.RuntimeParticipant, error) {
	attention, err := plugin.Require[plugin.AttentionCapability](ctx.Capabilities, plugin.AttentionCapabilityKey)
	if err != nil {
		return nil, err
	}
	var runner *background.Runner
	runner, err = background.NewRunner(ctx, background.Behavior{
		ID: "attention.agent", SettingsID: "attention.settings", LazyInitialize: true, IdleDispose: true,
		Consumer:     plugin.LifecycleConsumerDefinition{ID: "evaluate", Replay: "pending", Filter: plugin.LifecycleScope{{Types: []string{"attention.evaluate"}, Sources: []string{"attention.agent"}}}},
		Instructions: []string{"Help the user focus by hiding ordinary threads that no longer need their attention from Overview. Decide independently for each thread using its supplied observations. You may leave every thread visible."},
		Prepare: func(ctx context.Context, req background.BatchRequest) (background.BatchPlan, error) {
			pending, err := attention.Pending(ctx, req.Events)
			return background.BatchPlan{Events: pending, Skip: len(pending) == 0}, err
		},
		Message: func(ctx context.Context, req background.BatchRequest) (model.AgentInput, error) {
			facts, err := attention.Evidence(ctx, req.Events)
			if err != nil {
				return model.AgentInput{}, err
			}
			raw, err := json.Marshal(facts)
			if err != nil {
				return model.AgentInput{}, err
			}
			return background.Input("Thread observations (timestamps and durations in milliseconds): " + string(raw)), nil
		},
		Tools: func(lifetime context.Context) []plugin.ToolBinding {
			return []plugin.ToolBinding{background.Tool(lifetime, "hide_thread", "Hide this thread from ordinary Overview browsing.", model.Object{"threadId": model.Object{"type": "string"}, "revision": model.Object{"type": "integer"}}, []string{"threadId", "revision"}, func(ctx context.Context, args model.Object, call string) (any, error) {
				id, err := background.String(args, "threadId")
				if err != nil {
					return nil, err
				}
				rev, err := background.Integer(args, "revision", -1)
				if err != nil || rev < 0 {
					return nil, plugin.CallerError(fmt.Errorf("invalid revision"))
				}
				opts, err := runner.WriteOptions(ctx, call)
				if err != nil {
					return nil, err
				}
				return attention.Hide(ctx, id, uint64(rev), plugin.BackgroundWriteOptions{RequestID: opts.RequestID, Batch: *opts.Batch})
			})}
		}})
	if err != nil {
		return nil, err
	}
	return &participant{Runner: runner, attention: attention}, nil
}
