package tag

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"unicode/utf16"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/plugins/applications/background"
	appvalue "github.com/hupao-creator/Mokusei/internal/plugins/applications/value"
)

func statusbarTool(lifetime context.Context, read func(context.Context) (plugin.TagStatusbar, error)) plugin.ToolBinding {
	return background.Tool(lifetime, "read_statusbar", "Read the complete current pool: stable-ID tags, all unarchived Threads (ID and title only), assignments and unassigned IDs. Use its revision for writes.", model.Object{}, nil,
		func(ctx context.Context, _ model.Object, _ string) (any, error) { return read(ctx) })
}

func mutationTools(lifetime context.Context, execute func(context.Context, plugin.TagMutation, string) (any, error)) []plugin.ToolBinding {
	text := func(limit int) model.Object {
		return model.Object{"type": "string", "minLength": 1, "maxLength": limit}
	}
	revision, id, name, emoji := text(64), text(128), text(32), text(64)
	assignments := model.Object{"type": "array", "minItems": 1, "maxItems": 100, "items": model.Object{"type": "object", "additionalProperties": false, "properties": model.Object{"threadId": id, "tagId": id}, "required": []string{"threadId", "tagId"}}}
	definitions := []struct {
		name, kind, description string
		properties              model.Object
		required                []string
	}{
		{"create_tag", "create", "Create one tag with a plain name and separate emoji, within the five-tag capacity. Duplicate names reuse the existing tag.", model.Object{"name": name, "emoji": emoji}, []string{"name", "emoji"}},
		{"update_tag", "update", "Change a tag's name and/or emoji while preserving its stable ID and active assignments.", model.Object{"tagId": id, "name": name, "emoji": emoji}, []string{"tagId"}},
		{"delete_tag", "delete", "Delete an empty tag. First move any active members to another tag using assign_threads.", model.Object{"tagId": id}, []string{"tagId"}},
		{"assign_threads", "assign", "Atomically move each listed unarchived Thread to exactly one existing tag in this pool. Any invalid entry rejects the entire batch.", model.Object{"assignments": assignments}, []string{"assignments"}},
	}
	tools := make([]plugin.ToolBinding, 0, len(definitions))
	for _, definition := range definitions {
		definition.properties["expectedRevision"] = revision
		tools = append(tools, background.Tool(lifetime, definition.name, definition.description+" Supply the latest statusbar revision. Returns status=applied or conflict plus the complete fresh statusbar; on conflict reconsider without assuming the mutation occurred.", definition.properties, append(definition.required, "expectedRevision"), func(ctx context.Context, args model.Object, callID string) (any, error) {
			var input struct {
				ExpectedRevision string                       `json:"expectedRevision"`
				TagID            string                       `json:"tagId,omitempty"`
				Name             *string                      `json:"name,omitempty"`
				Emoji            *string                      `json:"emoji,omitempty"`
				Assignments      []plugin.TagStatusAssignment `json:"assignments,omitempty"`
			}
			raw, err := json.Marshal(args)
			if err != nil {
				return nil, err
			}
			if err := appvalue.Decode(raw, &input); err != nil {
				return nil, plugin.CallerError(err)
			}
			validText := func(value string, limit int) bool {
				return strings.TrimSpace(value) != "" && !strings.ContainsRune(value, 0) && len(utf16.Encode([]rune(value))) <= limit
			}
			valid := validText(input.ExpectedRevision, 64)
			if input.Name != nil {
				valid = valid && validText(*input.Name, 32)
			}
			if input.Emoji != nil {
				valid = valid && validText(*input.Emoji, 64)
			}
			switch definition.kind {
			case "create":
				valid = valid && input.Name != nil && input.Emoji != nil
			case "update":
				valid = valid && validText(input.TagID, 128) && (input.Name != nil || input.Emoji != nil)
			case "delete":
				valid = valid && validText(input.TagID, 128)
			case "assign":
				valid = valid && len(input.Assignments) > 0 && len(input.Assignments) <= 100
				for _, entry := range input.Assignments {
					valid = valid && validText(entry.ThreadID, 128) && validText(entry.TagID, 128)
				}
			}
			if !valid {
				return nil, plugin.CallerError(errors.New("invalid tag mutation arguments"))
			}
			return execute(ctx, plugin.TagMutation{Kind: definition.kind, ExpectedRevision: input.ExpectedRevision, TagID: input.TagID, Name: input.Name, Emoji: input.Emoji, Assignments: input.Assignments}, callID)
		}))
	}
	return tools
}
