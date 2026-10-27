package tag

import (
	"context"
	"encoding/json"
	"errors"
	"strings"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/plugins/applications/background"
	appvalue "github.com/hupao-creator/Mokusei/internal/plugins/applications/value"
)

func mutationTools(lifetime context.Context, execute func(context.Context, plugin.SemanticTagOperation, string) (any, error)) []plugin.ToolBinding {
	assignment := background.Tool(lifetime, "set_thread_tags", "Replace the semantic tag for one or more classification-eligible ordinary Agent Threads, including archived threads. Each assignment carries exactly one tag name from this scope's pool. The whole batch is validated and committed atomically; an invalid entry applies nothing. Directory tags and other scopes are preserved.", model.Object{"assignments": model.Object{"type": "array", "minItems": 1, "maxItems": 100, "items": model.Object{"type": "object", "additionalProperties": false, "properties": model.Object{"thread": background.ThreadProperty, "tags": model.Object{"type": "array", "items": model.Object{"type": "string", "minLength": 1, "maxLength": 32}, "minItems": 1, "maxItems": 1}}, "required": []string{"thread", "tags"}}}}, []string{"assignments"}, func(callCtx context.Context, args model.Object, callID string) (any, error) {
		var input struct {
			Assignments []plugin.SemanticTagAssignment `json:"assignments"`
		}
		if err := decodeToolArguments(args, &input); err != nil {
			return nil, err
		}
		if len(input.Assignments) == 0 {
			return nil, errors.New("Expected tag assignments")
		}
		if len(input.Assignments) > 100 {
			return nil, errors.New("Too many assignments")
		}
		for _, entry := range input.Assignments {
			if len(entry.Tags) != 1 {
				return nil, errors.New("Each thread must have exactly one tag")
			}
		}
		return execute(callCtx, plugin.SemanticTagOperation{Kind: "assign-many", Assignments: input.Assignments}, callID)
	})
	create := background.Tool(lifetime, "create_tags", "Create up to five semantic tags. Supply a plain text name and one corresponding complete emoji per tag. Existing names are returned unchanged. Invalid emoji falls back to a tag icon. The final pool cannot exceed five tags.", model.Object{"tags": model.Object{"type": "array", "items": model.Object{"type": "object", "additionalProperties": false, "properties": model.Object{"name": model.Object{"type": "string", "minLength": 1, "maxLength": 32}, "emoji": model.Object{"type": "string", "minLength": 1, "maxLength": 64}}, "required": []string{"name", "emoji"}}, "minItems": 1, "maxItems": 5}, "description": model.Object{"type": "string", "maxLength": 120}}, []string{"tags"}, func(callCtx context.Context, args model.Object, callID string) (any, error) {
		var input struct {
			Tags        []plugin.SemanticTagInput `json:"tags"`
			Description *string                   `json:"description,omitempty"`
		}
		if err := decodeToolArguments(args, &input); err != nil {
			return nil, err
		}
		if len(input.Tags) == 0 {
			return nil, errors.New("Expected tag names and emojis")
		}
		return execute(callCtx, plugin.SemanticTagOperation{Kind: "create-many", Definitions: input.Tags, Description: input.Description}, callID)
	})
	rename := background.Tool(lifetime, "rename_tag", "Rename a tag in this scope and rewrite every affected thread assignment in the same transaction. The emoji is preserved unless an optional emoji is supplied. The old name becomes available for reuse. A target that already exists is rejected; use merge_tags instead.", model.Object{"name": model.Object{"type": "string", "minLength": 1, "maxLength": 32}, "newName": model.Object{"type": "string", "minLength": 1, "maxLength": 32}, "emoji": model.Object{"type": "string", "minLength": 1, "maxLength": 64}, "description": model.Object{"type": "string", "maxLength": 120}}, []string{"name", "newName"}, func(callCtx context.Context, args model.Object, callID string) (any, error) {
		var input struct {
			Name        string  `json:"name"`
			NewName     string  `json:"newName"`
			Emoji       *string `json:"emoji,omitempty"`
			Description *string `json:"description,omitempty"`
		}
		if err := decodeToolArguments(args, &input); err != nil {
			return nil, err
		}
		if strings.TrimSpace(input.Name) == "" {
			return nil, errors.New("Missing name")
		}
		if strings.TrimSpace(input.NewName) == "" {
			return nil, errors.New("Missing newName")
		}
		return execute(callCtx, plugin.SemanticTagOperation{Kind: "update", Name: input.Name, NewName: input.NewName, Emoji: input.Emoji, Description: input.Description}, callID)
	})
	merge := background.Tool(lifetime, "merge_tags", "Merge one or more source tags into a target tag and move all affected threads in the same transaction. Supply the corresponding emoji for the target, which may be an existing tag or a new name. The final pool must remain at or below five tags.", model.Object{"names": model.Object{"type": "array", "items": model.Object{"type": "string", "minLength": 1, "maxLength": 32}, "minItems": 1, "maxItems": 100}, "target": model.Object{"type": "string", "minLength": 1, "maxLength": 32}, "emoji": model.Object{"type": "string", "minLength": 1, "maxLength": 64}, "description": model.Object{"type": "string", "maxLength": 120}}, []string{"names", "target", "emoji"}, func(callCtx context.Context, args model.Object, callID string) (any, error) {
		var input struct {
			Names       []string `json:"names"`
			Target      string   `json:"target"`
			Emoji       string   `json:"emoji"`
			Description *string  `json:"description,omitempty"`
		}
		if err := decodeToolArguments(args, &input); err != nil {
			return nil, err
		}
		if len(input.Names) == 0 {
			return nil, errors.New("Expected tag names")
		}
		if strings.TrimSpace(input.Target) == "" {
			return nil, errors.New("Missing target")
		}
		if strings.TrimSpace(input.Emoji) == "" {
			return nil, errors.New("Missing emoji")
		}
		return execute(callCtx, plugin.SemanticTagOperation{Kind: "merge", Names: input.Names, Target: input.Target, Emoji: &input.Emoji, Description: input.Description}, callID)
	})
	deleteTag := background.Tool(lifetime, "delete_tag", "Delete an unused tag from this scope's pool. A tag that still has threads is rejected; merge it into another tag instead. The deleted name becomes available for reuse.", model.Object{"name": model.Object{"type": "string", "minLength": 1, "maxLength": 32}}, []string{"name"}, func(callCtx context.Context, args model.Object, callID string) (any, error) {
		name, err := background.String(args, "name")
		if err != nil {
			return nil, err
		}
		return execute(callCtx, plugin.SemanticTagOperation{Kind: "delete", Name: name}, callID)
	})
	return []plugin.ToolBinding{assignment, create, rename, merge, deleteTag}
}

func decodeToolArguments(args model.Object, out any) error {
	raw, err := json.Marshal(args)
	if err != nil {
		return err
	}
	return appvalue.Decode(raw, out)
}
