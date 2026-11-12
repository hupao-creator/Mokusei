package tag

import (
	"context"
	"encoding/json"
	"reflect"
	"testing"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

func stringPointer(value string) *string { return &value }

func TestMutationToolsRejectMalformedArgumentsBeforeWriteAdmission(t *testing.T) {
	for _, test := range []struct{ name, tool, arguments string }{
		{"missing revision", "create_tag", `{"name":"Backend","emoji":"🔧"}`},
		{"null revision", "create_tag", `{"expectedRevision":null,"name":"Backend","emoji":"🔧"}`},
		{"unknown field", "create_tag", `{"expectedRevision":"rev","name":"Backend","emoji":"🔧","description":"secret"}`},
		{"missing emoji", "create_tag", `{"expectedRevision":"rev","name":"Backend"}`},
		{"null emoji", "create_tag", `{"expectedRevision":"rev","name":"Backend","emoji":null}`},
		{"null name", "update_tag", `{"expectedRevision":"rev","tagId":"tag","name":null}`},
		{"numeric emoji", "update_tag", `{"expectedRevision":"rev","tagId":"tag","emoji":7}`},
		{"no change", "update_tag", `{"expectedRevision":"rev","tagId":"tag"}`},
		{"missing id", "delete_tag", `{"expectedRevision":"rev"}`},
		{"unknown nested field", "assign_threads", `{"expectedRevision":"rev","assignments":[{"threadId":"thread","tagId":"tag","scope":"other"}]}`},
		{"missing thread", "assign_threads", `{"expectedRevision":"rev","assignments":[{"tagId":"tag"}]}`},
		{"null tag", "assign_threads", `{"expectedRevision":"rev","assignments":[{"threadId":"thread","tagId":null}]}`},
		{"empty batch", "assign_threads", `{"expectedRevision":"rev","assignments":[]}`},
	} {
		t.Run(test.name, func(t *testing.T) {
			writes := 0
			tools := mutationTools(t.Context(), func(context.Context, plugin.TagMutation, string) (any, error) { writes++; return model.Object{}, nil })
			for _, tool := range tools {
				if tool.Name != test.tool {
					continue
				}
				if _, err := tool.Execute(t.Context(), plugin.ToolCall{Arguments: json.RawMessage(test.arguments)}); err == nil {
					t.Fatal("malformed arguments accepted")
				}
				if writes != 0 {
					t.Fatal("malformed arguments reached write admission")
				}
				return
			}
			t.Fatalf("missing tool %s", test.tool)
		})
	}
}

func TestMutationToolsPreserveTypedOperationsAndOptionalValues(t *testing.T) {
	for _, test := range []struct {
		tool, arguments string
		want            plugin.TagMutation
	}{
		{"create_tag", `{"expectedRevision":"rev","name":"Backend","emoji":"🔧"}`, plugin.TagMutation{Kind: "create", ExpectedRevision: "rev", Name: stringPointer("Backend"), Emoji: stringPointer("🔧")}},
		{"update_tag", `{"expectedRevision":"rev","tagId":"tag","name":"Services"}`, plugin.TagMutation{Kind: "update", ExpectedRevision: "rev", TagID: "tag", Name: stringPointer("Services")}},
		{"update_tag", `{"expectedRevision":"rev","tagId":"tag","emoji":"⚙️"}`, plugin.TagMutation{Kind: "update", ExpectedRevision: "rev", TagID: "tag", Emoji: stringPointer("⚙️")}},
		{"delete_tag", `{"expectedRevision":"rev","tagId":"tag"}`, plugin.TagMutation{Kind: "delete", ExpectedRevision: "rev", TagID: "tag"}},
		{"assign_threads", `{"expectedRevision":"rev","assignments":[{"threadId":"thread","tagId":"tag"}]}`, plugin.TagMutation{Kind: "assign", ExpectedRevision: "rev", Assignments: []plugin.TagStatusAssignment{{ThreadID: "thread", TagID: "tag"}}}},
	} {
		t.Run(test.tool+test.arguments, func(t *testing.T) {
			var operations []plugin.TagMutation
			tools := mutationTools(t.Context(), func(_ context.Context, op plugin.TagMutation, callID string) (any, error) {
				if callID != "stable-call" {
					t.Fatal("write identity changed")
				}
				operations = append(operations, op)
				return model.Object{}, nil
			})
			for _, tool := range tools {
				if tool.Name != test.tool {
					continue
				}
				if _, err := tool.Execute(t.Context(), plugin.ToolCall{CallID: "stable-call", Arguments: json.RawMessage(test.arguments)}); err != nil {
					t.Fatal(err)
				}
				break
			}
			if !reflect.DeepEqual(operations, []plugin.TagMutation{test.want}) {
				t.Fatalf("operations = %#v; want %#v", operations, test.want)
			}
		})
	}
}
