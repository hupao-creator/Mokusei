package background

import (
	"context"
	"encoding/json"
	"errors"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

func EvidenceTools(lifetime context.Context, tasks plugin.OrdinaryTaskReadCapability, journal *Runner) []plugin.ToolBinding {
	props := model.Object{"threadId": model.Object{"type": "string"}}
	required := []string{"threadId"}
	reference := func(args model.Object) (model.ThreadRef, error) {
		id, err := String(args, "threadId")
		return model.ThreadRef{ThreadID: id, TypeID: "agent"}, err
	}
	return []plugin.ToolBinding{
		JSONPage(lifetime, "list_threads", "Read ordinary Agent Thread summaries, including archived threads. Offset/limit paginate JSON text.", model.Object{}, nil, func(ctx context.Context, _ model.Object, _ string) (any, error) {
			tasks, err := tasks.CaptureList(ctx, true)
			if err != nil {
				return nil, err
			}
			result := []model.Object{}
			for _, task := range tasks {
				result = append(result, taskSummary(task))
			}
			return result, nil
		}),
		Tool(lifetime, "get_thread_status", "Read an ordinary Agent Thread status, tags, and current execution.", props, required, func(ctx context.Context, args model.Object, _ string) (any, error) {
			ref, err := reference(args)
			if err != nil {
				return nil, err
			}
			task, err := tasks.Get(ctx, ref)
			if err != nil {
				return nil, err
			}
			if task == nil {
				return nil, errors.New("Thread evidence unavailable")
			}
			return taskSummary(*task), nil
		}),
		JSONPage(lifetime, "read_lifecycle_events", "Read the lifecycle journal available to this agent. Offset/limit paginate JSON text.", model.Object{"eventIds": model.Object{"type": "array", "items": model.Object{"type": "string"}, "maxItems": 256}}, nil, func(ctx context.Context, args model.Object, _ string) (any, error) {
			var ids []string
			if raw, ok := args["eventIds"]; ok {
				encoded, err := json.Marshal(raw)
				if err != nil {
					return nil, err
				}
				if err = json.Unmarshal(encoded, &ids); err != nil || ids == nil || len(ids) > 256 {
					return nil, errors.New("Invalid eventIds")
				}
			}
			return journal.ReadEvents(ctx, ids)
		}),
	}
}
func taskSummary(task plugin.OrdinaryTaskSnapshot) model.Object {
	return model.Object{"id": task.Ref.ThreadID, "title": task.Title, "harnessId": task.HarnessID, "cwd": task.Cwd, "executionCwd": task.ExecutionCwd, "archived": task.Archived, "observation": task.Observation, "tags": task.Tags.SemanticTags}
}
func Input(text string) model.AgentInput {
	return model.AgentInput{Presentation: "internal", Parts: []model.AgentInputPart{{Kind: "text", Text: text}}}
}
