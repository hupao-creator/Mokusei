package transport

import (
	"encoding/json"
	"testing"

	"github.com/hupao-creator/Mokusei/internal/core/model"
)

func TestParseContentSubscriptionPreservesScope(t *testing.T) {
	client, id, target, err := parseContentSubscription([]byte(`{"clientId":"c","subscriptionId":"s","target":{"threadId":"thread","scope":{"kind":"turn","key":"execution"}}}`))
	if err != nil || client != "c" || id != "s" || target == nil || target.ThreadID != "thread" || target.Scope.Kind != "turn" || target.Scope.Key != "execution" {
		t.Fatalf("parsed subscription = %q %q %+v %v", client, id, target, err)
	}
	if _, _, _, err := parseContentSubscription([]byte(`{"clientId":"c","subscriptionId":"s","target":{"threadId":"thread","scope":{"kind":"turn"}}}`)); err == nil {
		t.Fatal("turn scope without a key was accepted")
	}
	_, _, target, err = parseContentSubscription([]byte(`{"clientId":"c","subscriptionId":"s","target":{"threadId":"thread","scope":{"kind":"thread","key":"ignored"}}}`))
	if err != nil || target == nil || target.Scope.Key != "" {
		t.Fatalf("thread scope did not normalize key: %+v %v", target, err)
	}
}

func TestContentSubscriptionCarriesAgentReadingPurposeAndTarget(t *testing.T) {
	target := map[string]any{"executionId": "execution", "messageId": "message"}
	raw, err := json.Marshal(map[string]any{
		"clientId": "client", "subscriptionId": "row",
		"target": map[string]any{"threadId": "thread", "scope": map[string]any{
			"kind": "turn", "key": "execution", "purpose": model.RendererPurposeAgentSummary, "target": target,
		}},
	})
	if err != nil {
		t.Fatal(err)
	}
	_, _, parsed, err := parseContentSubscription(raw)
	if err != nil {
		t.Fatal(err)
	}
	if parsed == nil || parsed.Scope.Purpose != model.RendererPurposeAgentSummary || string(parsed.Scope.Target) == "" {
		t.Fatalf("reading scope was not preserved: %#v", parsed)
	}
}

func TestContentSubscriptionRejectsUnsupportedReadingScope(t *testing.T) {
	for name, scope := range map[string]map[string]any{
		"purpose": {"kind": "turn", "key": "execution", "purpose": "unknown"},
		"target":  {"kind": "turn", "key": "execution", "purpose": model.RendererPurposeAgentSummary, "target": json.RawMessage(`"not an object"`)},
		"kind":    {"kind": "thread", "purpose": model.RendererPurposeAgentSummary},
		"detail":  {"kind": "turn", "key": "execution", "target": map[string]any{"messageId": "message"}},
	} {
		t.Run(name, func(t *testing.T) {
			raw, err := json.Marshal(map[string]any{
				"clientId": "client", "subscriptionId": "row",
				"target": map[string]any{"threadId": "thread", "scope": scope},
			})
			if err != nil {
				t.Fatal(err)
			}
			if _, _, _, err := parseContentSubscription(raw); err == nil {
				t.Fatalf("invalid %s reading scope was accepted", name)
			}
		})
	}
}
