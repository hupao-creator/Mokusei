package transport

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"github.com/hupao-creator/Mokusei/internal/core/model"
)

func detailScopeTarget(thread, kind, key, item, slot string) map[string]any {
	scope := map[string]any{"kind": kind, "key": key, "items": []any{item}}
	if slot != "" {
		scope["slot"] = slot
	}
	return map[string]any{"threadId": thread, "scope": scope}
}

func TestContentSubscriptionPreservesNULDetailIdentities(t *testing.T) {
	item := "\x00pi:thinking:row"
	for name, scope := range map[string]map[string]any{
		"detail": {"kind": "detail", "key": "execution", "items": []any{item}},
		"body":   {"kind": "body", "key": "execution", "items": []any{item}, "slot": "thinking"},
	} {
		t.Run(name, func(t *testing.T) {
			raw, err := json.Marshal(map[string]any{"clientId": "client", "subscriptionId": "row",
				"target": map[string]any{"threadId": "thread", "scope": scope}})
			if err != nil {
				t.Fatal(err)
			}
			_, _, target, err := parseContentSubscription(raw)
			if err != nil {
				t.Fatal(err)
			}
			if target == nil || len(target.Scope.Items) != 1 || target.Scope.Items[0] != item {
				t.Fatalf("%s scope = %+v", name, target)
			}
		})
	}
}

func TestContentSubscriptionBoundsDetailIdentityUnits(t *testing.T) {
	atLimit := "\x00pi:thinking:" + strings.Repeat("a", model.MaximumContentIdentityUnits-len("\x00pi:thinking:"))
	raw, err := json.Marshal(map[string]any{"clientId": "client", "subscriptionId": "row",
		"target": detailScopeTarget("thread", "detail", "execution", atLimit, "")})
	if err != nil {
		t.Fatal(err)
	}
	if _, _, _, err := parseContentSubscription(raw); err != nil {
		t.Fatalf("identity at the bound was rejected: %v", err)
	}
	raw, err = json.Marshal(map[string]any{"clientId": "client", "subscriptionId": "row",
		"target": detailScopeTarget("thread", "detail", "execution", atLimit+"x", "")})
	if err != nil {
		t.Fatal(err)
	}
	if _, _, _, err := parseContentSubscription(raw); err == nil {
		t.Fatal("identity beyond the bound was accepted")
	}
}

func TestContentCapacityCountsLongLivedDetailBodies(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	server := &contentServer{
		clients: map[string]map[string]*contentSubscription{"client": {}},
		client:  func(string) *eventStream { return newEventStream("test") },
		wake:    make(chan struct{}, 1),
		ctx:     ctx,
	}
	update := func(id string, target map[string]any) error {
		raw, err := json.Marshal(map[string]any{"clientId": "client", "subscriptionId": id, "target": target})
		if err != nil {
			t.Fatal(err)
		}
		return server.update(raw)
	}
	for index := 0; index < 28; index++ {
		if err := update("turn-"+string(rune('a'+index)), map[string]any{
			"threadId": "thread", "scope": map[string]any{"kind": "turn", "key": "execution"},
		}); err != nil {
			t.Fatal(err)
		}
	}
	// Four detail bodies stay open across the following 28 admissions. They
	// represent the long-lived 24 MiB page leases that must retain their slots.
	for index := 0; index < 4; index++ {
		if err := update("body-"+string(rune('a'+index)), detailScopeTarget("thread", "body", "execution", "row", "detail")); err != nil {
			t.Fatal(err)
		}
	}
	if len(server.clients["client"]) != 32 {
		t.Fatalf("admitted subscriptions = %d", len(server.clients["client"]))
	}
	err := update("overflow", detailScopeTarget("thread", "detail", "execution", "row", ""))
	var failure *model.Error
	if !errors.As(err, &failure) || failure.Code != "CAPACITY_EXHAUSTED" {
		t.Fatalf("overflow error = %v", err)
	}
	// A replacement at an existing identity does not consume another slot.
	if err := update("body-a", detailScopeTarget("thread", "body", "execution", "row", "detail")); err != nil {
		t.Fatalf("replacing an admitted body failed: %v", err)
	}
}
