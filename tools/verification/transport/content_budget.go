package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"path/filepath"
	"reflect"
	"sync"
	"time"

	"github.com/hupao-creator/Mokusei/internal/platform/profile"
	"github.com/hupao-creator/Mokusei/internal/platform/transport"
)

type contentBudgetHost struct {
	mu       sync.Mutex
	revision int64
	value    json.RawMessage
	mutation func(json.RawMessage)
}

func (h *contentBudgetHost) HasChannel(string) bool { return false }
func (h *contentBudgetHost) Invoke(context.Context, string, []json.RawMessage) (any, error) {
	return nil, nil
}
func (h *contentBudgetHost) SubscribeMutations(callback func(json.RawMessage)) func() {
	h.mu.Lock()
	h.mutation = callback
	h.mu.Unlock()
	return func() {
		h.mu.Lock()
		h.mutation = nil
		h.mu.Unlock()
	}
}
func (h *contentBudgetHost) ReadThreadContent(_ context.Context, _ string, _ transport.ContentScope, known *int64) (*transport.ContentSnapshot, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if known != nil && *known == h.revision {
		return nil, nil
	}
	return &transport.ContentSnapshot{Revision: h.revision, Value: bytes.Clone(h.value)}, nil
}
func (h *contentBudgetHost) set(value json.RawMessage) {
	h.mu.Lock()
	h.revision++
	h.value = bytes.Clone(value)
	callback := h.mutation
	h.mu.Unlock()
	if callback != nil {
		callback(json.RawMessage(`{"kind":"fixture-change"}`))
	}
}

type contentBudgetCapture struct {
	Events []json.RawMessage
	Source json.RawMessage
}

func denseArrayJSON(count int, fill, first byte) json.RawMessage {
	raw := make([]byte, 0, count*2+3)
	raw = append(raw, '[')
	for index := 0; index < count; index++ {
		if index > 0 {
			raw = append(raw, ',')
		}
		if index == 0 && first != 0 {
			raw = append(raw, first)
		} else {
			raw = append(raw, fill)
		}
	}
	raw = append(raw, ']')
	return raw
}

func nextThreadContent(ctx context.Context, stream *eventConnection) (json.RawMessage, map[string]any) {
	for {
		raw := stream.nextRaw(ctx)
		var outer map[string]any
		must(json.Unmarshal(raw, &outer))
		if outer["type"] != "thread-content" {
			continue
		}
		event, ok := outer["event"].(map[string]any)
		check(ok, "thread content event is not an object")
		return json.RawMessage(bytes.Clone(raw)), event
	}
}

// captureContentBudgetEvents runs the real HTTP publisher through a dense
// replacement snapshot and a following small patch. The raw NDJSON envelopes
// are retained so the native client can consume the exact Go-produced wire.
func captureContentBudgetEvents(ctx context.Context, directory string) contentBudgetCapture {
	// The production operation budget stops refinement before this array can
	// produce a complete patch. The smaller fixture keeps the HTTP replay quick
	// under race instrumentation; the publisher unit test keeps the issue's
	// million-element frame boundary.
	const count = 10_000
	p, err := profile.Resolve(profile.Options{DataDir: filepath.Join(directory, "content-budget"), HomeDir: directory})
	must(err)
	must(profile.Prepare(p))
	host := &contentBudgetHost{revision: 1, value: denseArrayJSON(count, '0', 0)}
	server, err := transport.Start(transport.Options{Profile: p, Epoch: "content-budget", Host: host})
	must(err)
	defer func() {
		cleanup, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		must(server.Close(cleanup))
		must(server.Finish(cleanup))
	}()
	api := newAPI(server.Connection)
	defer api.close()
	stream := api.events(ctx)
	defer stream.close()

	subscribeWorker(ctx, api, stream, "wire", contentTarget("dense-array", "turn", "turn"))
	firstRaw, first := nextThreadContent(ctx, stream)
	check(first["type"] == "snapshot" && first["revision"] == float64(1), fmt.Sprintf("unexpected initial array snapshot: %v", first["type"]))
	initial := first["value"].([]any)
	check(len(initial) == count && initial[0] == float64(0) && initial[count-1] == float64(0), "initial array fixture is incomplete")

	host.set(denseArrayJSON(count, '1', 0))
	secondRaw, second := nextThreadContent(ctx, stream)
	check(second["type"] == "snapshot" && second["revision"] == float64(2), fmt.Sprintf("dense update did not fall back to snapshot: %v revision=%v", second["type"], second["revision"]))
	dense := second["value"].([]any)
	check(len(dense) == count && dense[0] == float64(1) && dense[count-1] == float64(1), "dense fallback snapshot is not the source value")

	host.set(denseArrayJSON(count, '1', '2'))
	thirdRaw, third := nextThreadContent(ctx, stream)
	check(third["type"] == "patch" && third["baseRevision"] == float64(2) && third["revision"] == float64(3), fmt.Sprintf("small patch after fallback broke its revision chain: %v", third))
	operations := third["patch"].([]any)
	check(len(operations) == 1, fmt.Sprintf("small array edit produced %d operations", len(operations)))
	operation := operations[0].(map[string]any)
	path, ok := operation["path"].([]any)
	check(ok && len(path) == 1 && path[0] == float64(0) && operation["op"] == "replace" && operation["value"] == float64(2), fmt.Sprintf("unexpected array patch: %v", operation))
	dense[0] = operation["value"]
	host.mu.Lock()
	source := bytes.Clone(host.value)
	host.mu.Unlock()
	var expected []any
	must(json.Unmarshal(source, &expected))
	check(reflect.DeepEqual(dense, expected), "client-side array value diverged from the source")
	subscribeWorker(ctx, api, stream, "wire", nil)
	return contentBudgetCapture{Events: []json.RawMessage{firstRaw, secondRaw, thirdRaw}, Source: source}
}

func verifyContentBudget(ctx context.Context, directory string) {
	capture := captureContentBudgetEvents(ctx, directory)
	check(len(capture.Events) == 3, "dense fallback replay did not produce three content events")
	fmt.Println("PASS dense array content falls back to snapshot, then resumes a small patch without dropping its subscription")
}
