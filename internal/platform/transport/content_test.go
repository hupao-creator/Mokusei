package transport

import (
	"bytes"
	"context"
	"encoding/json"
	"strings"
	"sync"
	"testing"
)

type scriptedContentHost struct {
	Host
	mu       sync.Mutex
	revision int64
	value    json.RawMessage
}

func (h *scriptedContentHost) ReadThreadContent(_ context.Context, _ string, _ ContentScope, known *int64) (*ContentSnapshot, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if known != nil && *known == h.revision {
		return nil, nil
	}
	return &ContentSnapshot{Revision: h.revision, Value: bytes.Clone(h.value)}, nil
}
func (h *scriptedContentHost) set(value json.RawMessage) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.revision++
	h.value = bytes.Clone(value)
}

type wireContentEvent struct {
	Type  string `json:"type"`
	Event struct {
		Type           string           `json:"type"`
		SubscriptionID string           `json:"subscriptionId"`
		Revision       int64            `json:"revision"`
		BaseRevision   int64            `json:"baseRevision"`
		Value          json.RawMessage  `json:"value"`
		Patch          []map[string]any `json:"patch"`
		Message        string           `json:"message"`
	} `json:"event"`
}

type contentPublishFixture struct {
	host   *scriptedContentHost
	server *contentServer
	stream *eventStream
	sub    *contentSubscription
}

func newContentPublishFixture(t *testing.T, value any) *contentPublishFixture {
	t.Helper()
	raw, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	host := &scriptedContentHost{revision: 1, value: raw}
	stream := newEventStream("test-epoch")
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	sub := &contentSubscription{ctx: ctx, cancel: cancel, id: "row", target: contentTarget{ThreadID: "thread", Scope: ContentScope{Kind: "turn", Key: "turn"}}}
	server := &contentServer{host: host, clients: map[string]map[string]*contentSubscription{"client": {"row": sub}}, client: func(string) *eventStream { return stream }}
	return &contentPublishFixture{host: host, server: server, stream: stream, sub: sub}
}
func (f *contentPublishFixture) set(t *testing.T, value any) {
	t.Helper()
	raw, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	f.host.set(raw)
}
func (f *contentPublishFixture) publish(t *testing.T) wireContentEvent {
	t.Helper()
	f.server.publishOne("client", f.sub)
	body, done := f.stream.pop()
	if done || len(body) == 0 {
		t.Fatal("content publication emitted no event")
	}
	var event wireContentEvent
	if err := json.Unmarshal(body, &event); err != nil {
		t.Fatal(err)
	}
	return event
}
func (f *contentPublishFixture) requireNoEvent(t *testing.T) {
	t.Helper()
	f.server.publishOne("client", f.sub)
	if body, _ := f.stream.pop(); len(body) != 0 {
		t.Fatalf("content publication emitted an unexpected event: %s", body)
	}
}

func TestPublishDenseUpdateFallsBackToSnapshotAndResumesPatch(t *testing.T) {
	fixture := newContentPublishFixture(t, denseDeltaValues(5000, 0))
	first := fixture.publish(t)
	if first.Event.Type != "snapshot" || first.Event.Revision != 1 {
		t.Fatalf("initial content was not a snapshot: %+v", first.Event)
	}
	fixture.set(t, denseDeltaValues(5000, 1))
	second := fixture.publish(t)
	if second.Event.Type != "snapshot" || second.Event.Revision != 2 {
		t.Fatalf("dense update did not use a snapshot: %+v", second.Event)
	}
	var values []any
	if err := json.Unmarshal(second.Event.Value, &values); err != nil || len(values) != 5000 || values[0].(float64) != 1 {
		t.Fatalf("dense snapshot value is wrong: %v", err)
	}
	fixture.set(t, append([]any{2}, denseDeltaValues(4999, 1)...))
	third := fixture.publish(t)
	if third.Event.Type != "patch" || third.Event.BaseRevision != 2 || third.Event.Revision != 3 || len(third.Event.Patch) != 1 {
		t.Fatalf("small patch after fallback did not continue the revision chain: %+v", third.Event)
	}
	if fixture.sub.revision != 3 || !fixture.sub.hasValue {
		t.Fatalf("subscription did not retain its wire baseline: %+v", fixture.sub)
	}
}

func TestPublishFallsBackWhenPatchIsLargerThanSnapshot(t *testing.T) {
	before := map[string]any{"payload": strings.Repeat("x", 1024)}
	after := map[string]any{"payload": before["payload"]}
	for index := 0; index < 40; index++ {
		key := string(rune('a' + index%26))
		if index >= 26 {
			key += string(rune('a' + index/26))
		}
		before[key] = 0
		after[key] = 1
	}
	fixture := newContentPublishFixture(t, before)
	first := fixture.publish(t)
	if first.Event.Type != "snapshot" || first.Event.Revision != 1 {
		t.Fatalf("initial content was not a snapshot: %+v", first.Event)
	}
	fixture.set(t, after)
	second := fixture.publish(t)
	if second.Event.Type != "snapshot" || second.Event.Revision != 2 {
		t.Fatalf("larger patch did not fall back to snapshot: %+v", second.Event)
	}
	after["a"] = 2
	fixture.set(t, after)
	third := fixture.publish(t)
	if third.Event.Type != "patch" || third.Event.BaseRevision != 2 || third.Event.Revision != 3 {
		t.Fatalf("small patch after snapshot fallback broke revisions: %+v", third.Event)
	}
}

func TestPublishNoOpDoesNotAdvanceWireRevision(t *testing.T) {
	value := map[string]any{"rows": []any{map[string]any{"text": "same"}}}
	fixture := newContentPublishFixture(t, value)
	if first := fixture.publish(t); first.Event.Type != "snapshot" || first.Event.Revision != 1 {
		t.Fatalf("initial content was not a snapshot: %+v", first.Event)
	}
	// A new source revision with semantically identical content must advance
	// freshness without emitting a patch or snapshot.
	fixture.set(t, value)
	fixture.requireNoEvent(t)
	if fixture.sub.revision != 1 || !fixture.sub.hasValueDigest {
		t.Fatalf("semantic no-op changed wire state or digest: %+v", fixture.sub)
	}
}

func TestPublishFallbackStillHonorsQueueBackpressure(t *testing.T) {
	before := map[string]any{}
	after := map[string]any{}
	for _, key := range []string{"a", "b", "c", "d", "e", "f", "g", "h"} {
		before[key] = 0
		after[key] = 1
	}
	fixture := newContentPublishFixture(t, before)
	if first := fixture.publish(t); first.Event.Type != "snapshot" {
		t.Fatalf("initial content was not a snapshot: %+v", first.Event)
	}
	fixture.stream.mu.Lock()
	fixture.stream.bytes = contentWriteLimit - 1
	fixture.stream.mu.Unlock()
	fixture.set(t, after)
	fixture.server.publishOne("client", fixture.sub)
	body, done := fixture.stream.pop()
	if done || len(body) == 0 {
		t.Fatal("queue backpressure did not deliver a content error")
	}
	var event wireContentEvent
	if err := json.Unmarshal(body, &event); err != nil {
		t.Fatal(err)
	}
	if event.Event.Type != "error" || event.Event.Message != "对话内容加载暂时繁忙，请重试。" {
		t.Fatalf("snapshot fallback bypassed queue backpressure: %+v", event.Event)
	}
	if fixture.server.clients["client"]["row"] != nil {
		t.Fatal("backpressured subscription was not retired")
	}
}

func TestPublishRejectsSnapshotWhoseWireEnvelopeExceedsLimit(t *testing.T) {
	raw := json.RawMessage(`"` + strings.Repeat("x", contentWriteLimit-2) + `"`)
	if len(raw) != contentWriteLimit {
		t.Fatalf("fixture raw size=%d", len(raw))
	}
	fixture := newContentPublishFixture(t, raw)
	fixture.server.publishOne("client", fixture.sub)
	body, done := fixture.stream.pop()
	if done || len(body) == 0 {
		t.Fatal("oversized wire snapshot did not deliver a content error")
	}
	var event wireContentEvent
	if err := json.Unmarshal(body, &event); err != nil {
		t.Fatal(err)
	}
	if event.Event.Type != "error" || event.Event.Message != "This conversation turn exceeds the content transport limit" {
		t.Fatalf("wire envelope limit was not enforced: %+v", event.Event)
	}
	if fixture.server.clients["client"]["row"] != nil {
		t.Fatal("oversized subscription was not retired")
	}
}
