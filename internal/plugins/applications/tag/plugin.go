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

type Plugin struct{}

func New() *Plugin { return &Plugin{} }
func (*Plugin) Manifest() plugin.ApplicationManifest {
	return plugin.ApplicationManifest{ID: "tag", DisplayName: "Tag", APIVersion: 1, Contributes: plugin.Contributions{BackgroundAgents: []string{"tag.agent"}, ThreadTypes: []string{}, Settings: []string{"tag.settings"}, Collections: []string{}, Queries: []string{}, Commands: []string{}}}
}
func (*Plugin) Register(registry plugin.Registry) error {
	if err := background.RegisterSettings(registry, "tag", "tag.settings"); err != nil {
		return err
	}
	return registry.BackgroundAgent(plugin.BackgroundAgentDefinition{ID: "tag.agent", ExecutionSettingsID: "tag.settings", InstancePolicy: plugin.PerDirectoryScope, Requires: []plugin.CapabilityKey{plugin.BackgroundConfigurationCapabilityKey, plugin.BackgroundEnvironmentCapabilityKey, plugin.BackgroundSessionsCapabilityKey, plugin.LifecycleCapabilityKey, plugin.SemanticTagsReadCapabilityKey, plugin.SemanticTagsWriteCapabilityKey}, Create: newAgent})
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
	scopeLabel := ctx.Owner.ScopeLabel
	if scopeLabel == "" {
		scopeLabel = "Inbox"
	}
	agentID := ctx.Owner.AgentID
	if agentID == "" {
		agentID = "tag.agent"
	}
	var runner *background.Runner
	runner, err = background.NewRunner(ctx, background.Behavior{SessionKey: "title-classification", SettingsID: "tag.settings", ID: agentID, Consumer: plugin.LifecycleConsumerDefinition{ID: "events", Replay: "pending", Filter: plugin.LifecycleScope{{Sources: []string{"application", "user"}, SubjectKinds: []string{"thread"}, SubjectTypeIDs: []string{"agent"}, Types: []string{"thread.input-accepted", "thread.title-changed", "thread.restored"}}, {Sources: []string{agentID}, SubjectKinds: []string{"thread"}, SubjectTypeIDs: []string{"agent"}, Types: []string{"thread.inventory"}}}}, Instructions: []string{instructions}, Initialize: writes.EnsureInventory, LazyInitialize: true, IdleDispose: true,
		Message: func(callCtx context.Context, request background.BatchRequest) (model.AgentInput, error) {
			locale, err := environment.OutputLocale(callCtx)
			if err != nil {
				return model.AgentInput{}, err
			}
			status, err := reads.CaptureStatusbar(callCtx)
			if err != nil {
				return model.AgentInput{}, err
			}
			language := background.LanguageInstructions(locale, func(name string) string {
				return fmt.Sprintf("Write concise tag names in %s and generate a separate emoji for each tag.", name)
			})
			data, err := json.Marshal(status)
			if err != nil {
				return model.AgentInput{}, err
			}
			instruction := "Review every Thread in this statusbar, fill every unassigned Thread, and adjust classifications or reorganize the pool when current titles justify it."
			if request.Steering {
				instruction = "This statusbar supersedes the previous snapshot. Reconsider all current Threads and finish any incomplete classification or reorganization."
			}
			return background.Input(fmt.Sprintf("You manage the five-slot tag pool for %q. %s %s Batch: %s\nStatusbar: %s", scopeLabel, instruction, language, request.BatchID, data)), nil
		},
		Tools: func(lifetime context.Context) []plugin.ToolBinding {
			execute := func(callCtx context.Context, operation plugin.TagMutation, callID string) (any, error) {
				options, err := runner.WriteOptions(callCtx, callID)
				if err != nil {
					return nil, err
				}
				return writes.Mutate(callCtx, operation, plugin.BackgroundWriteOptions{RequestID: options.RequestID, Batch: *options.Batch})
			}
			return append(mutationTools(lifetime, execute), statusbarTool(lifetime, reads.CaptureStatusbar))
		},
	})
	return runner, err
}
