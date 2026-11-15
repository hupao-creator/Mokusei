package transport

import (
	"encoding/json"
	"testing"

	"github.com/hupao-creator/Mokusei/internal/core/model"
)

func TestContentSubscriptionScopes(t *testing.T) {
	valid := func(target map[string]any) []byte {
		raw, err := json.Marshal(map[string]any{"clientId": "client", "subscriptionId": "subscription", "target": target})
		if err != nil {
			t.Fatal(err)
		}
		return raw
	}
	t.Run("directory pagination", func(t *testing.T) {
		_, _, target, err := parseContentSubscription(valid(map[string]any{
			"threadId": "thread", "scope": map[string]any{"kind": "directory", "offset": 40, "limit": 20},
		}))
		if err != nil {
			t.Fatal(err)
		}
		if target == nil || target.Scope.Kind != "directory" || target.Scope.Offset != 40 || target.Scope.Limit != 20 {
			t.Fatalf("directory scope = %+v", target)
		}
		_, _, target, err = parseContentSubscription(valid(map[string]any{
			"threadId": "thread", "scope": map[string]any{"kind": "directory"},
		}))
		if err != nil {
			t.Fatal(err)
		}
		if target.Scope.Limit != model.DefaultExecutionDirectoryLimit {
			t.Fatalf("directory default limit = %d", target.Scope.Limit)
		}
	})
	t.Run("detail and body", func(t *testing.T) {
		_, _, target, err := parseContentSubscription(valid(map[string]any{
			"threadId": "thread", "scope": map[string]any{"kind": "detail", "key": "execution", "items": []any{"row-1", "row-2"}},
		}))
		if err != nil || target == nil || len(target.Scope.Items) != 2 {
			t.Fatalf("detail scope = %+v %v", target, err)
		}
		_, _, target, err = parseContentSubscription(valid(map[string]any{
			"threadId": "thread", "scope": map[string]any{"kind": "body", "key": "execution", "items": []any{"row"}, "slot": "detail"},
		}))
		if err != nil || target == nil || target.Scope.Slot != "detail" {
			t.Fatalf("body scope = %+v %v", target, err)
		}
	})
	t.Run("preview key", func(t *testing.T) {
		_, _, target, err := parseContentSubscription(valid(map[string]any{
			"threadId": "thread", "scope": map[string]any{"kind": "preview", "key": "execution"},
		}))
		if err != nil {
			t.Fatal(err)
		}
		if target == nil || target.Scope.Kind != "preview" || target.Scope.Key != "execution" {
			t.Fatalf("preview scope = %+v", target)
		}
	})
	for _, scope := range []map[string]any{
		{"kind": "directory", "offset": -1},
		{"kind": "directory", "limit": model.MaximumExecutionDirectoryLimit + 1},
		{"kind": "preview"},
		{"kind": "unknown"},
		{"kind": "detail", "key": "execution", "items": []any{"row"}, "offset": 1},
		{"kind": "detail", "key": "execution", "items": []any{"row"}, "purpose": model.RendererPurposeAgentSummary},
		{"kind": "body", "key": "execution", "items": []any{"row"}, "slot": "detail", "limit": 10},
		{"kind": "body", "key": "execution", "items": []any{"row"}, "slot": "detail", "target": map[string]any{"messageId": "row"}},
		{"kind": "directory", "items": []any{"row"}},
		{"kind": "directory", "cursor": "d1:abc:0"},
		{"kind": "preview", "key": "execution", "slot": "detail"},
		{"kind": "preview", "key": "execution", "items": []any{"row"}},
	} {
		if _, _, _, err := parseContentSubscription(valid(map[string]any{"threadId": "thread", "scope": scope})); err == nil {
			t.Fatalf("accepted invalid scope %+v", scope)
		}
	}
}
