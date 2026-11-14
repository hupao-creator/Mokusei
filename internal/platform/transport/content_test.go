package transport

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
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

func newContentPublishRawFixture(t *testing.T, raw json.RawMessage, writeLimit int) *contentPublishFixture {
	t.Helper()
	host := &scriptedContentHost{revision: 1, value: bytes.Clone(raw)}
	stream := newEventStream("test-epoch")
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	sub := &contentSubscription{ctx: ctx, cancel: cancel, id: "row", target: contentTarget{ThreadID: "thread", Scope: ContentScope{Kind: "turn", Key: "turn"}}}
	server := &contentServer{host: host, clients: map[string]map[string]*contentSubscription{"client": {"row": sub}}, client: func(string) *eventStream { return stream }, writeLimit: writeLimit}
	return &contentPublishFixture{host: host, server: server, stream: stream, sub: sub}
}
func newContentPublishFixture(t *testing.T, value any) *contentPublishFixture {
	t.Helper()
	raw, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return newContentPublishRawFixture(t, raw, 0)
}
func newContentPublishFixtureWithLimit(t *testing.T, value any, writeLimit int) *contentPublishFixture {
	t.Helper()
	raw, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return newContentPublishRawFixture(t, raw, writeLimit)
}
func (f *contentPublishFixture) set(t *testing.T, value any) {
	t.Helper()
	raw, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	f.host.set(raw)
}
func (f *contentPublishFixture) setRaw(t *testing.T, raw json.RawMessage) {
	t.Helper()
	f.host.set(bytes.Clone(raw))
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

func contentRows(count, payload int, status string) []any {
	body := strings.Repeat("x", payload)
	rows := make([]any, count)
	for index := range rows {
		rows[index] = map[string]any{"id": index, "status": status, "body": body}
	}
	return rows
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

func TestPublishLargeSnapshotWithManySmallOperationsUsesPatch(t *testing.T) {
	const rows = 5000
	before := contentRows(rows, 1024, "pending")
	after := contentRows(rows, 1024, "done")
	beforeRaw, err := json.Marshal(before)
	if err != nil {
		t.Fatal(err)
	}
	afterRaw, err := json.Marshal(after)
	if err != nil {
		t.Fatal(err)
	}
	delta := CreateBoundedJSONDelta(before, after, DeltaBudget{MaxOperations: maxDeltaOperations, MaxBytes: len(afterRaw)})
	if !delta.Complete || len(delta.Operations) != rows {
		t.Fatalf("row-status update did not complete: complete=%t operations=%d examined=%d", delta.Complete, len(delta.Operations), delta.Examined)
	}
	fixture := newContentPublishRawFixture(t, beforeRaw, 0)
	if first := fixture.publish(t); first.Event.Type != "snapshot" {
		t.Fatalf("initial content was not a snapshot: %+v", first.Event)
	}
	fixture.setRaw(t, afterRaw)
	second := fixture.publish(t)
	if second.Event.Type != "patch" || second.Event.Revision != 2 || second.Event.BaseRevision != 1 || len(second.Event.Patch) != rows {
		t.Fatalf("large snapshot with many small operations fell back unexpectedly: %+v", second.Event)
	}
	patchBytes, err := json.Marshal(second.Event.Patch)
	if err != nil {
		t.Fatal(err)
	}
	if len(patchBytes) >= len(afterRaw) {
		t.Fatalf("patch %d is not smaller than snapshot %d", len(patchBytes), len(afterRaw))
	}
}

func TestPublishFallsBackWhenCompletePatchIsLargerThanSnapshot(t *testing.T) {
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
	beforeRaw, err := json.MarshalIndent(before, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	afterRaw, err := json.MarshalIndent(after, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	// Insignificant whitespace is valid JSON but makes the raw projection
	// larger than the compact value. The delta budget must accept the complete
	// patch here so the representation comparison, not the raw byte cap,
	// decides the fallback.
	beforeRaw = append(beforeRaw, bytes.Repeat([]byte(" "), 4096)...)
	afterRaw = append(afterRaw, bytes.Repeat([]byte(" "), 4096)...)
	delta := CreateBoundedJSONDelta(before, after, DeltaBudget{MaxOperations: maxDeltaOperations, MaxBytes: len(afterRaw)})
	if !delta.Complete {
		t.Fatalf("pretty raw fixture did not reach the representation comparison: %+v", delta)
	}
	fixture := newContentPublishRawFixture(t, beforeRaw, 0)
	first := fixture.publish(t)
	if first.Event.Type != "snapshot" || first.Event.Revision != 1 {
		t.Fatalf("initial content was not a snapshot: %+v", first.Event)
	}
	fixture.setRaw(t, afterRaw)
	second := fixture.publish(t)
	if second.Event.Type != "snapshot" || second.Event.Revision != 2 {
		t.Fatalf("complete larger patch did not fall back to snapshot: %+v", second.Event)
	}
	after["a"] = 2
	afterRaw, err = json.MarshalIndent(after, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	fixture.setRaw(t, afterRaw)
	third := fixture.publish(t)
	if third.Event.Type != "patch" || third.Event.BaseRevision != 2 || third.Event.Revision != 3 {
		t.Fatalf("small patch after snapshot fallback broke revisions: %+v", third.Event)
	}
}

func TestPublishNoOpDigestFastPathDoesNotAdvanceWireRevision(t *testing.T) {
	value := map[string]any{"rows": []any{map[string]any{"text": "same"}}}
	pretty, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	fixture := newContentPublishFixture(t, value)
	if first := fixture.publish(t); first.Event.Type != "snapshot" || first.Event.Revision != 1 {
		t.Fatalf("initial content was not a snapshot: %+v", first.Event)
	}
	// A new source revision with semantically identical but re-encoded content
	// must arm the digest without emitting a patch or snapshot.
	fixture.setRaw(t, pretty)
	fixture.requireNoEvent(t)
	fixture.host.mu.Lock()
	sourceRevision := fixture.host.revision
	fixture.host.mu.Unlock()
	if fixture.sub.revision != 1 || !fixture.sub.hasValueDigest || fixture.sub.sourceRevision == nil || *fixture.sub.sourceRevision != sourceRevision {
		t.Fatalf("semantic no-op did not arm the digest or advance freshness: %+v", fixture.sub)
	}
	// The following identical raw revision takes the fixed-size digest path,
	// which must still advance freshness and emit nothing.
	fixture.setRaw(t, pretty)
	fixture.requireNoEvent(t)
	fixture.host.mu.Lock()
	sourceRevision = fixture.host.revision
	fixture.host.mu.Unlock()
	if fixture.sub.revision != 1 || fixture.sub.sourceRevision == nil || *fixture.sub.sourceRevision != sourceRevision {
		t.Fatalf("digest fast path did not advance freshness: %+v", fixture.sub)
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

func TestPublishUsesSnapshotWhenPatchWouldExceedSmallFrame(t *testing.T) {
	const limit = 1024
	before := map[string]any{}
	after := map[string]any{"a": 0, "b": 1}
	for index := 0; index < 40; index++ {
		before[fmt.Sprintf("k%02d", index)] = 0
	}
	full := CreateBoundedJSONDelta(before, after, DeltaBudget{MaxOperations: maxDeltaOperations, MaxBytes: 1 << 20})
	if !full.Complete {
		t.Fatalf("removal patch did not complete under a larger budget: %+v", full)
	}
	patchBytes, err := json.Marshal(full.Operations)
	if err != nil {
		t.Fatal(err)
	}
	if len(patchBytes) <= limit {
		t.Fatalf("removal patch %d did not exceed the small frame %d", len(patchBytes), limit)
	}
	delta := CreateBoundedJSONDelta(before, after, DeltaBudget{MaxOperations: maxDeltaOperations, MaxBytes: limit})
	if delta.Complete {
		t.Fatalf("removal patch unexpectedly fit the small frame: %+v", delta)
	}
	fixture := newContentPublishFixtureWithLimit(t, before, limit)
	if first := fixture.publish(t); first.Event.Type != "snapshot" || first.Event.Revision != 1 {
		t.Fatalf("initial content did not fit the small frame: %+v", first.Event)
	}
	fixture.set(t, after)
	second := fixture.publish(t)
	if second.Event.Type != "snapshot" || second.Event.Revision != 2 {
		t.Fatalf("patch-over-limit case did not fall back to a fitting snapshot: %+v", second.Event)
	}
	if fixture.server.clients["client"]["row"] == nil {
		t.Fatal("fitting snapshot fallback retired the subscription")
	}
}

func TestPublishRejectsWhenNeitherRepresentationFitsSmallFrame(t *testing.T) {
	const limit = 160
	before := map[string]any{"a": 0}
	after := map[string]any{"a": strings.Repeat("x", 100)}
	afterRaw, err := json.Marshal(after)
	if err != nil {
		t.Fatal(err)
	}
	if len(afterRaw) > limit {
		t.Fatalf("fixture raw %d exceeded the hard limit %d", len(afterRaw), limit)
	}
	fixture := newContentPublishFixtureWithLimit(t, before, limit)
	if first := fixture.publish(t); first.Event.Type != "snapshot" {
		t.Fatalf("initial content did not fit: %+v", first.Event)
	}
	fixture.set(t, after)
	fixture.server.publishOne("client", fixture.sub)
	body, done := fixture.stream.pop()
	if done || len(body) == 0 {
		t.Fatal("unfittable update did not deliver a content error")
	}
	var event wireContentEvent
	if err := json.Unmarshal(body, &event); err != nil {
		t.Fatal(err)
	}
	if event.Event.Type != "error" || event.Event.Message != "This conversation turn exceeds the content transport limit" {
		t.Fatalf("wire envelope limit was not enforced: %+v", event.Event)
	}
	if fixture.server.clients["client"]["row"] != nil {
		t.Fatal("unfittable subscription was not retired")
	}
}

func TestPublishRetainsRawProjectionHardLimitBeforeDiff(t *testing.T) {
	const limit = 64
	raw := json.RawMessage(`"` + strings.Repeat("x", 100) + `"`)
	fixture := newContentPublishRawFixture(t, raw, limit)
	fixture.server.publishOne("client", fixture.sub)
	body, done := fixture.stream.pop()
	if done || len(body) == 0 {
		t.Fatal("raw hard-limit rejection did not deliver a content error")
	}
	var event wireContentEvent
	if err := json.Unmarshal(body, &event); err != nil {
		t.Fatal(err)
	}
	if event.Event.Type != "error" || event.Event.Message != "This conversation turn exceeds the content transport limit" {
		t.Fatalf("raw hard limit was not enforced: %+v", event.Event)
	}
}
