package report

import (
	"context"
	_ "embed"
	"encoding/json"
	"errors"
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
	return plugin.ApplicationManifest{ID: "report", DisplayName: "Report", APIVersion: 1, Contributes: plugin.Contributions{BackgroundAgents: []string{"report.agent"}, ThreadTypes: []string{ThreadTypeID}, Settings: []string{SettingsID}, Collections: []string{CollectionID}, Queries: []string{"report.read", "report.list", "report.html"}, Commands: []string{"report.create", "report.update"}}}
}
func (*Plugin) Register(registry plugin.Registry) error {
	if err := background.RegisterSettings(registry, "report", SettingsID); err != nil {
		return err
	}
	if err := RegisterDomain(registry); err != nil {
		return err
	}
	return registry.BackgroundAgent(plugin.BackgroundAgentDefinition{ID: "report.agent", ExecutionSettingsID: SettingsID, InstancePolicy: plugin.PerDirectoryScope, Requires: []plugin.CapabilityKey{plugin.BackgroundConfigurationCapabilityKey, plugin.BackgroundEnvironmentCapabilityKey, plugin.BackgroundSessionsCapabilityKey, plugin.LifecycleCapabilityKey, plugin.OrdinaryTaskReadCapabilityKey}, Create: newAgent})
}
func newAgent(ctx plugin.BackgroundAgentContext) (plugin.RuntimeParticipant, error) {
	if _, err := reportScope(ctx.Owner); err != nil {
		return nil, err
	}

	environment, err := plugin.Require[plugin.BackgroundEnvironmentCapability](ctx.Capabilities, plugin.BackgroundEnvironmentCapabilityKey)
	if err != nil {
		return nil, err
	}
	tasks, err := plugin.Require[plugin.OrdinaryTaskReadCapability](ctx.Capabilities, plugin.OrdinaryTaskReadCapabilityKey)
	if err != nil {
		return nil, err
	}
	var runner *background.Runner
	runner, err = background.NewRunner(ctx, background.Behavior{ID: ctx.Owner.AgentID, LazyInitialize: true, IdleDispose: true, Consumer: plugin.LifecycleConsumerDefinition{ID: "events", Filter: plugin.LifecycleScope{{Sources: []string{"application"}, SubjectKinds: []string{"thread"}, SubjectTypeIDs: []string{"agent"}, Types: []string{"execution.completed"}}}}, Instructions: []string{instructions}, Message: func(callCtx context.Context, request background.BatchRequest) (model.AgentInput, error) {
		locale, err := environment.OutputLocale(callCtx)
		if err != nil {
			return model.AgentInput{}, err
		}
		language := background.LanguageInstructions(locale, func(name string) string {
			return fmt.Sprintf("Write report titles and all reader-facing HTML text in %s, including headings, prose, diagram and chart labels, captions, controls, tooltips, and accessibility text. Set the HTML document's lang attribute to %s. Apply this to reports you create or update, without starting a bulk translation of existing reports.", name, locale)
		})
		instruction := "Review this lifecycle batch and decide what reports need work."
		if request.Steering {
			instruction = "Incorporate these additional lifecycle events into your current batch now. Revisit earlier reporting decisions using the new evidence, and continue all unfinished report work."
		}
		events, err := json.Marshal(background.EventMetadata(request.Events))
		if err != nil {
			return model.AgentInput{}, err
		}
		return background.Input(fmt.Sprintf("You maintain reports only for scope %q (%s). Never read or aggregate evidence or reports from another scope. %s %s Read full event data and relevant context as needed. Batch: %s\n%s", ctx.Owner.ScopeLabel, ctx.Owner.Binding.Scope, instruction, language, request.BatchID, events)), nil
	}, Tools: func(lifetime context.Context) []plugin.ToolBinding {
		return append(background.EvidenceTools(lifetime, tasks, runner), reportTools(lifetime, ctx.Domain, runner)...)
	}})
	return runner, err
}
func reportTools(lifetime context.Context, domain plugin.DomainClient, runner *background.Runner) []plugin.ToolBinding {
	id := model.Object{"type": "string", "minLength": 1, "maxLength": MaxIdentifierLength}
	title := model.Object{"type": "string", "minLength": 1, "maxLength": MaxTitleLength, "pattern": "\\S", "description": "Write the report title in the current application output language supplied with the lifecycle batch."}
	html := model.Object{"type": "string", "minLength": 1, "maxLength": MaxHTMLCharacters, "pattern": "\\S", "description": "Report HTML document. Follow the current system instructions for content and presentation."}
	related := model.Object{"type": "array", "maxItems": MaxRelatedThreads, "description": "Optional explicit completed Execution references. A historical completed Execution remains eligible even after a newer Execution starts. One Execution per Thread.", "items": model.Object{"type": "object", "properties": model.Object{"threadId": id, "executionId": id}, "required": []string{"threadId", "executionId"}, "additionalProperties": false}}
	write := func(operation string) background.ToolHandler {
		return func(ctx context.Context, args model.Object, callID string) (any, error) {
			input := model.Object{}
			for key, value := range args {
				input[key] = value
			}
			if raw, ok := args["relatedExecutions"]; ok {
				references, err := toolReferences(raw)
				if err != nil {
					return nil, err
				}
				input["relatedExecutions"] = references
			} else if operation == "create" {
				input["relatedExecutions"] = []model.ExecutionRef{}
			}
			encoded, err := json.Marshal(input)
			if err != nil {
				return nil, err
			}
			options, err := runner.WriteOptions(ctx, callID)
			if err != nil {
				return nil, err
			}
			return domain.Execute(ctx, "report."+operation, encoded, options)
		}
	}
	return []plugin.ToolBinding{
		background.Tool(lifetime, "create_report", "Create a persistent read-only Report Thread.", model.Object{"title": title, "html": html, "relatedExecutions": related}, []string{"title", "html"}, write("create")),
		background.JSONPage(lifetime, "list_reports", "List Report Thread summaries. Offset and limit paginate the JSON text.", model.Object{}, nil, func(ctx context.Context, _ model.Object, _ string) (any, error) {
			raw, err := domain.Query(ctx, "report.list", json.RawMessage(`{"limit":10000,"includeArchived":true}`))
			if err != nil {
				return nil, err
			}
			var page Page
			if err = model.Unmarshal(raw, &page); err != nil {
				return nil, err
			}
			return model.Object{"reports": page.Items}, nil
		}),
		background.JSONPage(lifetime, "read_report", "Read one complete Report Thread. Offset and limit paginate the JSON text.", model.Object{"reportId": id}, []string{"reportId"}, func(ctx context.Context, args model.Object, _ string) (any, error) {
			id, err := background.String(args, "reportId")
			if err != nil {
				return nil, err
			}
			input, _ := json.Marshal(IdentityInput{id})
			raw, err := domain.Query(ctx, "report.read", input)
			if err != nil {
				return nil, err
			}
			if model.IsNull(raw) {
				return nil, nil
			}
			value, err := model.DecodeObject(raw)
			if err != nil {
				return nil, err
			}
			var report contentOutput
			if err = model.Unmarshal(raw, &report); err != nil {
				return nil, err
			}
			refs := []model.Object{}
			for _, ref := range report.RelatedExecutions {
				refs = append(refs, model.Object{"threadId": ref.Thread.ThreadID, "executionId": ref.ExecutionID})
			}
			value["relatedExecutions"] = refs
			return value, nil
		}),
		background.Tool(lifetime, "update_report", "Replace supplied Report Thread fields.", model.Object{"reportId": id, "title": title, "html": html, "relatedExecutions": related}, []string{"reportId"}, write("update")),
	}
}
func toolReferences(value any) ([]model.ExecutionRef, error) {
	raw, err := json.Marshal(value)
	if err != nil {
		return nil, err
	}
	var refs []struct {
		ThreadID    string `json:"threadId"`
		ExecutionID string `json:"executionId"`
	}
	if err = model.Unmarshal(raw, &refs); err != nil || refs == nil {
		return nil, errors.New("报告 relatedExecutions 必须是关联数组")
	}
	if len(refs) > MaxRelatedThreads {
		return nil, fmt.Errorf("报告 relatedExecutions 不能超过 %d 项", MaxRelatedThreads)
	}
	result := []model.ExecutionRef{}
	seen := map[string]string{}
	for _, ref := range refs {
		if !validID(ref.ThreadID) || !validID(ref.ExecutionID) {
			return nil, errors.New("报告关联含无效的 Thread 或 Execution ID")
		}
		if previous, ok := seen[ref.ThreadID]; ok {
			if previous != ref.ExecutionID {
				return nil, errors.New("同一报告对同一 Thread 只能关联一个 Execution")
			}
			continue
		}
		seen[ref.ThreadID] = ref.ExecutionID
		result = append(result, model.ExecutionRef{Thread: model.ThreadRef{ThreadID: ref.ThreadID, TypeID: "agent"}, ExecutionID: ref.ExecutionID})
	}
	return result, nil
}
