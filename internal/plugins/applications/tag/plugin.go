package tag

import (
	"context"
	_ "embed"
	"encoding/json"
	"fmt"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/plugins/applications/background"
)

//go:embed instructions.txt
var instructions string

const overviewRequest = "Read current overview context with read_overview_context and combine it with current task evidence to make reasonable filter selections when useful; keeping the current selection is valid. No connected overview is normal, so continue classification if none is available."

type Plugin struct{}

func New() *Plugin { return &Plugin{} }
func (*Plugin) Manifest() plugin.ApplicationManifest {
	return plugin.ApplicationManifest{ID: "tag", DisplayName: "Tag", APIVersion: 1, Contributes: plugin.Contributions{BackgroundAgents: []string{"tag.agent"}, ThreadTypes: []string{}, Settings: []string{"tag.settings"}, Collections: []string{}, Queries: []string{}, Commands: []string{}}}
}
func (*Plugin) Register(registry plugin.Registry) error {
	if err := background.RegisterSettings(registry, "tag", "tag.settings"); err != nil {
		return err
	}
	return registry.BackgroundAgent(plugin.BackgroundAgentDefinition{ID: "tag.agent", ExecutionSettingsID: "tag.settings", InstancePolicy: plugin.PerDirectoryScope, Requires: []plugin.CapabilityKey{plugin.BackgroundConfigurationCapabilityKey, plugin.BackgroundEnvironmentCapabilityKey, plugin.BackgroundSessionsCapabilityKey, plugin.LifecycleCapabilityKey, plugin.OverviewControlCapabilityKey, plugin.SemanticTagsReadCapabilityKey, plugin.SemanticTagsWriteCapabilityKey}, Create: newAgent})
}
func newAgent(ctx plugin.BackgroundAgentContext) (plugin.RuntimeParticipant, error) {
	environment, err := plugin.Require[plugin.BackgroundEnvironmentCapability](ctx.Capabilities, plugin.BackgroundEnvironmentCapabilityKey)
	if err != nil {
		return nil, err
	}
	reads, err := plugin.Require[plugin.SemanticTagsReadCapability](ctx.Capabilities, plugin.SemanticTagsReadCapabilityKey)
	if err != nil {
		return nil, err
	}
	writes, err := plugin.Require[plugin.SemanticTagsWriteCapability](ctx.Capabilities, plugin.SemanticTagsWriteCapabilityKey)
	if err != nil {
		return nil, err
	}
	overview, err := plugin.Require[plugin.OverviewControl](ctx.Capabilities, plugin.OverviewControlCapabilityKey)
	if err != nil {
		return nil, err
	}
	scopeLabel := ctx.Owner.ScopeLabel
	if scopeLabel == "" {
		scopeLabel = "Inbox"
	}
	agentID := ctx.Owner.AgentID
	if agentID == "" {
		agentID = "tag.agent"
	}
	var runner *background.Runner
	runner, err = background.NewRunner(ctx, background.Behavior{ID: agentID, Consumer: plugin.LifecycleConsumerDefinition{ID: "events", Replay: "new", Filter: plugin.LifecycleScope{{Sources: []string{"application", "user"}, SubjectKinds: []string{"thread"}, SubjectTypeIDs: []string{"agent"}, Types: []string{"thread.input-accepted", "execution.completed", "execution.failed", "execution.interrupted"}}, {Sources: []string{agentID}, SubjectKinds: []string{"thread"}, SubjectTypeIDs: []string{"agent"}, Types: []string{"thread.inventory"}}}}, Instructions: []string{instructions}, Initialize: writes.EnsureInventory, LazyInitialize: true, IdleDispose: true,
		Message: func(callCtx context.Context, request background.BatchRequest) (model.AgentInput, error) {
			locale, err := environment.OutputLocale(callCtx)
			if err != nil {
				return model.AgentInput{}, err
			}
			pool, err := reads.CaptureList(callCtx)
			if err != nil {
				return model.AgentInput{}, err
			}
			language := background.LanguageInstructions(locale, func(name string) string {
				return fmt.Sprintf("Write semantic tag names in %s. Generate a corresponding emoji separately for each tag; never prefix the name with emoji. Prefer concise, consistent names and reuse relevant names in the injected tagPool snapshot or overview context. Assign labels only to the specified thread. Derived directory tags are outside your authority.", name)
			})
			instruction := fmt.Sprintf("You manage the five-slot semantic tag pool for scope %q. Review every classification-eligible thread in this batch and give each exactly one tag from the current pool. Reuse an existing tag whenever it fits; create a tag only when the pool has a free slot and no existing tag fits.", scopeLabel)
			if request.Steering {
				instruction = fmt.Sprintf("You manage the five-slot semantic tag pool for scope %q. Incorporate these additional events into your current batch now. Revisit earlier tag decisions when new evidence changes a thread’s subject, and finish all earlier unfinished reviews.", scopeLabel)
			}
			data, err := json.Marshal(model.Object{"scope": scopeLabel, "tagPool": pool, "capacity": max(0, 5-len(pool)), "events": background.EventEvidence(request.Events)})
			if err != nil {
				return model.AgentInput{}, err
			}
			return background.Input(fmt.Sprintf("%s %s Use the supplied batch metadata, current tagPool snapshot, and available overview context. Leave existing tags unchanged when this evidence does not establish a useful subject. A thread never has more than one semantic tag. %s Batch: %s\n%s", instruction, language, overviewRequest, request.BatchID, data)), nil
		},
		Tools: func(lifetime context.Context) []plugin.ToolBinding {
			execute := func(callCtx context.Context, operation plugin.SemanticTagOperation, callID string) (any, error) {
				options, err := runner.WriteOptions(callCtx, callID)
				if err != nil {
					return nil, err
				}
				return writes.Execute(callCtx, operation, plugin.BackgroundWriteOptions{RequestID: options.RequestID, Batch: *options.Batch})
			}
			selection := NewOverviewSelection(overview, lifetime, ctx.Owner.Binding.Scope)
			return append(mutationTools(lifetime, execute), selection.Bindings()...)
		},
	})
	return runner, err
}
