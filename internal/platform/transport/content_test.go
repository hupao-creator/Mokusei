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
	} {
		if _, _, _, err := parseContentSubscription(valid(map[string]any{"threadId": "thread", "scope": scope})); err == nil {
			t.Fatalf("accepted invalid scope %+v", scope)
		}
	}
}
