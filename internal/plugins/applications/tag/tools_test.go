package tag

import (
	"context"
	"encoding/json"
	"reflect"
	"testing"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

func TestMutationToolsRejectMalformedArgumentsBeforeWriteAdmission(t *testing.T) {
	for _, test := range []struct {
		name, tool, arguments string
	}{
		{"create null description", "create_tags", `{"tags":[{"name":"Backend","emoji":"🔧"}],"description":null}`},
		{"create numeric description", "create_tags", `{"tags":[{"name":"Backend","emoji":"🔧"}],"description":7}`},
		{"create unknown nested field", "create_tags", `{"tags":[{"name":"Backend","emoji":"🔧","scope":"other"}]}`},
		{"create missing emoji", "create_tags", `{"tags":[{"name":"Backend"}]}`},
		{"create null emoji", "create_tags", `{"tags":[{"name":"Backend","emoji":null}]}`},
		{"rename null description", "rename_tag", `{"name":"Backend","newName":"Services","description":null}`},
		{"rename numeric description", "rename_tag", `{"name":"Backend","newName":"Services","description":7}`},
		{"rename null emoji", "rename_tag", `{"name":"Backend","newName":"Services","emoji":null}`},
		{"rename numeric emoji", "rename_tag", `{"name":"Backend","newName":"Services","emoji":7}`},
		{"merge null description", "merge_tags", `{"names":["Backend"],"target":"Services","emoji":"🔧","description":null}`},
		{"merge numeric description", "merge_tags", `{"names":["Backend"],"target":"Services","emoji":"🔧","description":7}`},
		{"merge null name", "merge_tags", `{"names":[null],"target":"Services","emoji":"🔧"}`},
		{"assignment unknown nested field", "set_thread_tags", `{"assignments":[{"thread":{"threadId":"thread","typeId":"agent"},"tags":["Backend"],"scope":"other"}]}`},
		{"assignment unknown thread field", "set_thread_tags", `{"assignments":[{"thread":{"threadId":"thread","typeId":"agent","scope":"other"},"tags":["Backend"]}]}`},
		{"assignment null tag", "set_thread_tags", `{"assignments":[{"thread":{"threadId":"thread","typeId":"agent"},"tags":[null]}]}`},
		{"assignment missing type", "set_thread_tags", `{"assignments":[{"thread":{"threadId":"thread"},"tags":["Backend"]}]}`},
	} {
		t.Run(test.name, func(t *testing.T) {
			writes := 0
			tools := mutationTools(t.Context(), func(context.Context, plugin.SemanticTagOperation, string) (any, error) {
				writes++
				return model.Object{"status": "applied"}, nil
			})
			for _, tool := range tools {
				if tool.Name != test.tool {
					continue
				}
				if _, err := tool.Execute(t.Context(), plugin.ToolCall{CallID: "malformed", Arguments: json.RawMessage(test.arguments)}); err == nil {
					t.Fatal("malformed arguments were accepted")
				}
				if writes != 0 {
					t.Fatal("malformed arguments reached the write executor")
				}
				return
			}
			t.Fatalf("missing production tool %s", test.tool)
		})
	}
}

func TestMutationToolsPreserveTypedOperationsAndOptionalValues(t *testing.T) {
	for _, test := range []struct {
		name, tool, arguments string
		want                  plugin.SemanticTagOperation
	}{
		{
			name: "create omitted description", tool: "create_tags",
			arguments: `{"tags":[{"name":"Backend","emoji":"🔧"}]}`,
			want:      plugin.SemanticTagOperation{Kind: "create-many", Definitions: []plugin.SemanticTagInput{{Name: "Backend", Emoji: "🔧"}}},
		},
		{
			name: "create empty description", tool: "create_tags",
			arguments: `{"tags":[{"name":"Backend","emoji":"🔧"}],"description":""}`,
			want:      plugin.SemanticTagOperation{Kind: "create-many", Definitions: []plugin.SemanticTagInput{{Name: "Backend", Emoji: "🔧"}}, Description: stringPointer("")},
		},
		{
			name: "rename omitted decoration", tool: "rename_tag",
			arguments: `{"name":"Backend","newName":"Services"}`,
			want:      plugin.SemanticTagOperation{Kind: "update", Name: "Backend", NewName: "Services"},
		},
		{
			name: "rename explicit decoration", tool: "rename_tag",
			arguments: `{"name":"Backend","newName":"Services","emoji":"⚙️","description":""}`,
			want:      plugin.SemanticTagOperation{Kind: "update", Name: "Backend", NewName: "Services", Emoji: stringPointer("⚙️"), Description: stringPointer("")},
		},
		{
			name: "merge omitted description", tool: "merge_tags",
			arguments: `{"names":["Backend"],"target":"Services","emoji":"🔧"}`,
			want:      plugin.SemanticTagOperation{Kind: "merge", Names: []string{"Backend"}, Target: "Services", Emoji: stringPointer("🔧")},
		},
		{
			name: "merge explicit description", tool: "merge_tags",
			arguments: `{"names":["Backend"],"target":"Services","emoji":"🔧","description":"Service work"}`,
			want:      plugin.SemanticTagOperation{Kind: "merge", Names: []string{"Backend"}, Target: "Services", Emoji: stringPointer("🔧"), Description: stringPointer("Service work")},
		},
		{
			name: "assignment", tool: "set_thread_tags",
			arguments: `{"assignments":[{"thread":{"threadId":"thread","typeId":"agent"},"tags":["Backend"]}]}`,
			want:      plugin.SemanticTagOperation{Kind: "assign-many", Assignments: []plugin.SemanticTagAssignment{{Thread: model.ThreadRef{ThreadID: "thread", TypeID: "agent"}, Tags: []string{"Backend"}}}},
		},
		{
			name: "delete", tool: "delete_tag", arguments: `{"name":"Backend"}`,
			want: plugin.SemanticTagOperation{Kind: "delete", Name: "Backend"},
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			var operations []plugin.SemanticTagOperation
			tools := mutationTools(t.Context(), func(_ context.Context, operation plugin.SemanticTagOperation, callID string) (any, error) {
				if callID != "stable-call" {
					t.Fatalf("write identity changed to %q", callID)
				}
				operations = append(operations, operation)
				return model.Object{"status": "applied"}, nil
			})
			for _, tool := range tools {
				if tool.Name != test.tool {
					continue
				}
				if _, err := tool.Execute(t.Context(), plugin.ToolCall{CallID: "stable-call", Arguments: json.RawMessage(test.arguments)}); err != nil {
					t.Fatal(err)
				}
				if !reflect.DeepEqual(operations, []plugin.SemanticTagOperation{test.want}) {
					t.Fatalf("write operations = %#v; want %#v", operations, test.want)
				}
				return
			}
			t.Fatalf("missing production tool %s", test.tool)
		})
	}
}
