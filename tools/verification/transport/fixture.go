package main

import (
	"context"
	"encoding/json"
	"sync"

	"github.com/hupao-creator/Mokusei/internal/platform/transport"
)

type gate struct {
	started chan struct{}
	release chan struct{}
	once    sync.Once
}

func newGate() *gate {
	return &gate{started: make(chan struct{}, 32), release: make(chan struct{})}
}

func (g *gate) open() { g.once.Do(func() { close(g.release) }) }

func (g *gate) wait(ctx context.Context) error {
	g.started <- struct{}{}
	select {
	case <-g.release:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

type mockHost struct {
	mu            sync.Mutex
	mutation      func(json.RawMessage)
	counts        map[string]int
	gates         map[string]*gate
	contentText   string
	contentRev    int64
	staleStarted  chan struct{}
	staleCanceled chan struct{}
}

func newMockHost() *mockHost {
	return &mockHost{
		counts: make(map[string]int), gates: map[string]*gate{"capacity": newGate(), "duplicate": newGate(), "lost": newGate()},
		contentText: "hello 😀", contentRev: 1, staleStarted: make(chan struct{}, 4), staleCanceled: make(chan struct{}, 4),
	}
}

func (h *mockHost) releaseAll() {
	for _, gate := range h.gates {
		gate.open()
	}
}

func (*mockHost) HasChannel(channel string) bool {
	return channel == "application:command" || channel == "state:load"
}

func (h *mockHost) Invoke(ctx context.Context, channel string, args []json.RawMessage) (any, error) {
	var mode string
	if len(args) > 0 {
		_ = json.Unmarshal(args[0], &mode)
	}
	h.mu.Lock()
	h.counts[mode]++
	count := h.counts[mode]
	gate := h.gates[mode]
	h.mu.Unlock()
	if gate != nil {
		if err := gate.wait(ctx); err != nil {
			return nil, err
		}
	}
	return map[string]any{"mode": mode, "count": count, "channel": channel, "commandId": transport.CommandID(ctx)}, nil
}

func (h *mockHost) SubscribeMutations(callback func(json.RawMessage)) func() {
	h.mu.Lock()
	h.mutation = callback
	h.mu.Unlock()
	return func() {
		h.mu.Lock()
		h.mutation = nil
		h.mu.Unlock()
	}
}

func (h *mockHost) mutate(text string) {
	h.mu.Lock()
	h.contentText = text
	h.contentRev++
	callback := h.mutation
	h.mu.Unlock()
	if callback != nil {
		callback(json.RawMessage(`{"kind":"fixture-change"}`))
	}
}

func (h *mockHost) ReadThreadContent(ctx context.Context, id string, scope transport.ContentScope, known *int64) (*transport.ContentSnapshot, error) {
	if id == "projection-panic" {
		panic("fixed projection failure")
	}
	if id == "blocked-old-scope" {
		h.staleStarted <- struct{}{}
		<-ctx.Done()
		h.staleCanceled <- struct{}{}
		return nil, ctx.Err()
	}
	h.mu.Lock()
	revision, text := h.contentRev, h.contentText
	h.mu.Unlock()
	if known != nil && *known == revision {
		return nil, nil
	}
	value, err := json.Marshal(map[string]any{"thread": id, "scope": scope.Kind, "key": scope.Key, "text": text})
	if err != nil {
		return nil, err
	}
	return &transport.ContentSnapshot{Revision: revision, Value: value}, nil
}
