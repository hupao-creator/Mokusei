package transport

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
)

type contentLimitHost struct {
	Host
	value    json.RawMessage
	revision int64
}

func (h *contentLimitHost) ReadThreadContent(context.Context, string, ContentScope, *int64) (*ContentSnapshot, error) {
	h.revision++
	return &ContentSnapshot{Revision: h.revision, Value: h.value}, nil
}

func TestContentTransportLimitBoundary(t *testing.T) {
	for _, test := range []struct {
		name      string
		size      int
		wantError bool
	}{
		{"bounded", contentWriteLimit - 4096, false},
		{"oversized", contentWriteLimit + 1, true},
	} {
		t.Run(test.name, func(t *testing.T) {
			raw, err := json.Marshal(map[string]any{"text": strings.Repeat("x", test.size)})
			if err != nil {
				t.Fatal(err)
			}
			if test.wantError == (len(raw) <= contentWriteLimit) {
				t.Fatalf("fixture does not exercise the intended boundary: %d bytes", len(raw))
			}
			host := &contentLimitHost{value: raw}
			stream := newEventStream("test")
			subscriptionContext, cancel := context.WithCancel(context.Background())
			defer cancel()
			subscription := &contentSubscription{
				ctx:    subscriptionContext,
				cancel: cancel,
				id:     "row",
				target: contentTarget{ThreadID: "thread", Scope: ContentScope{Kind: "thread"}},
			}
			server := &contentServer{
				host:    host,
				clients: map[string]map[string]*contentSubscription{"client": {"row": subscription}},
				client:  func(string) *eventStream { return stream },
			}
			server.publishOne("client", subscription)
			body, done := stream.pop()
			if done || len(body) == 0 {
				t.Fatal("content publication produced no event")
			}
			var event struct {
				Type  string `json:"type"`
				Event struct {
					Type    string `json:"type"`
					Message string `json:"message"`
				} `json:"event"`
			}
			if err = json.Unmarshal(body, &event); err != nil {
				t.Fatal(err)
			}
			if test.wantError {
				if event.Type != "thread-content" || event.Event.Type != "error" ||
					!strings.Contains(event.Event.Message, "content transport limit") {
					t.Fatalf("oversized content produced %#v", event)
				}
				if _, exists := server.clients["client"]["row"]; exists {
					t.Fatal("oversized content retained its subscription")
				}
				return
			}
			if event.Type != "thread-content" || event.Event.Type != "snapshot" {
				t.Fatalf("bounded content produced %#v", event)
			}
			if _, exists := server.clients["client"]["row"]; !exists {
				t.Fatal("bounded content lost its subscription")
			}
		})
	}
}
