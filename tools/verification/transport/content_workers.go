package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"sync"
	"time"

	"github.com/hupao-creator/Mokusei/internal/platform/profile"
	"github.com/hupao-creator/Mokusei/internal/platform/transport"
)

type contentBarrier struct {
	started, release, cancelled, finished chan struct{}
	openOnce, cancelOnce                  sync.Once
}

func newContentBarrier() *contentBarrier {
	return &contentBarrier{started: make(chan struct{}, 8), release: make(chan struct{}), cancelled: make(chan struct{}), finished: make(chan struct{}, 8)}
}
func (b *contentBarrier) open() { b.openOnce.Do(func() { close(b.release) }) }

type workerHost struct {
	*mockHost
	workersMu      sync.Mutex
	barriers       map[string]*contentBarrier
	active, peak   int
	byID, peakByID map[string]int
}

func newWorkerHost() *workerHost {
	return &workerHost{mockHost: newMockHost(), barriers: map[string]*contentBarrier{}, byID: map[string]int{}, peakByID: map[string]int{}}
}
func (h *workerHost) hold(id string) *contentBarrier {
	h.workersMu.Lock()
	defer h.workersMu.Unlock()
	b := newContentBarrier()
	h.barriers[id] = b
	return b
}
func (h *workerHost) releaseWorkers() {
	h.workersMu.Lock()
	defer h.workersMu.Unlock()
	for _, b := range h.barriers {
		b.open()
	}
}
func (h *workerHost) ReadThreadContent(ctx context.Context, id string, scope transport.ContentScope, known *int64) (*transport.ContentSnapshot, error) {
	h.mu.Lock()
	revision, text := h.contentRev, h.contentText
	h.mu.Unlock()
	if known != nil && *known == revision {
		return nil, nil
	}
	h.workersMu.Lock()
	b := h.barriers[id]
	h.active++
	h.peak = max(h.peak, h.active)
	h.byID[id]++
	h.peakByID[id] = max(h.peakByID[id], h.byID[id])
	h.workersMu.Unlock()
	defer func() {
		h.workersMu.Lock()
		h.active--
		h.byID[id]--
		h.workersMu.Unlock()
		if b != nil {
			b.finished <- struct{}{}
		}
	}()
	if b != nil {
		b.started <- struct{}{}
		stop := context.AfterFunc(ctx, func() { b.cancelOnce.Do(func() { close(b.cancelled) }) })
		defer stop()
		<-b.release // Deliberately return success after cancellation.
	}
	if id == "oversized" {
		return &transport.ContentSnapshot{Revision: revision, Value: make(json.RawMessage, transport.MaxResponseBytes+1)}, nil
	}
	value, err := json.Marshal(map[string]any{"thread": id, "text": text})
	return &transport.ContentSnapshot{Revision: revision, Value: value}, err
}
func subscribeWorker(ctx context.Context, api *apiClient, stream *eventConnection, id string, target any) {
	api.request(ctx, "POST", "/thread-content/subscription", map[string]any{"clientId": stream.id, "subscriptionId": id, "target": target}, nil).requireStatus(200)
}
func workerEvent(ctx context.Context, api *apiClient, stream *eventConnection) map[string]any {
	for {
		outer := stream.next(ctx)
		if outer["type"] == "mutation" {
			continue
		}
		check(outer["type"] == "thread-content" && outer["epoch"] == api.connection.Epoch, "invalid worker event envelope")
		return outer["event"].(map[string]any)
	}
}
func workerSnapshot(ctx context.Context, api *apiClient, stream *eventConnection, id, target string) map[string]any {
	event := workerEvent(ctx, api, stream)
	check(event["subscriptionId"] == id && event["type"] == "snapshot" && event["revision"] == float64(1), fmt.Sprintf("unexpected worker snapshot: %v", event))
	value := event["value"].(map[string]any)
	check(value["thread"] == target, "late content from former target escaped")
	return value
}
func verifyContentWorkers(ctx context.Context, directory string) {
	p, err := profile.Resolve(profile.Options{DataDir: filepath.Join(directory, "content-workers"), HomeDir: directory})
	must(err)
	must(profile.Prepare(p))
	host := newWorkerHost()
	server, err := transport.Start(transport.Options{Profile: p, Epoch: "content-workers", Host: host})
	must(err)
	defer func() {
		host.releaseWorkers()
		cleanup, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		must(server.Close(cleanup))
		must(server.Finish(cleanup))
	}()
	api := newAPI(server.Connection)
	defer api.close()
	stream := api.events(ctx)
	defer stream.close()
	slow := host.hold("slow")
	subscribeWorker(ctx, api, stream, "slow", contentTarget("slow", "thread", ""))
	await(ctx, slow.started, "slow worker did not start")
	subscribeWorker(ctx, api, stream, "fast", contentTarget("fast", "thread", ""))
	workerSnapshot(ctx, api, stream, "fast", "fast")
	across := api.events(ctx)
	subscribeWorker(ctx, api, across, "other-client", contentTarget("other-client", "thread", ""))
	workerSnapshot(ctx, api, across, "other-client", "other-client")
	across.close()
	slow.open()
	workerSnapshot(ctx, api, stream, "slow", "slow")
	subscribeWorker(ctx, api, stream, "slow", nil)
	subscribeWorker(ctx, api, stream, "fast", nil)
	host.mutate("worker-0")
	burst := host.hold("burst")
	subscribeWorker(ctx, api, stream, "burst", contentTarget("burst", "thread", ""))
	await(ctx, burst.started, "burst did not start")
	for i := 1; i <= 5; i++ {
		host.mutate(fmt.Sprint("worker-", i))
	}
	burst.open()
	initial := workerSnapshot(ctx, api, stream, "burst", "burst")
	value := initial["text"].(string)
	revision := float64(1)
	for value != "worker-5" {
		event := workerEvent(ctx, api, stream)
		check(event["subscriptionId"] == "burst" && event["type"] == "patch" && event["baseRevision"] == revision && event["revision"] == revision+1, "worker patch chain broke")
		revision++
		for _, raw := range event["patch"].([]any) {
			op := raw.(map[string]any)
			path := op["path"].([]any)
			check(len(path) == 1 && path[0] == "text", "unexpected fixture delta")
			if op["op"] == "replace" {
				value = op["value"].(string)
			} else {
				check(op["op"] == "text", "unexpected delta operation")
				index, deleted := int(op["index"].(float64)), int(op["deleteCount"].(float64))
				value = value[:index] + op["text"].(string) + value[index+deleted:]
			}
		}
	}
	host.workersMu.Lock()
	single := host.peakByID["burst"]
	host.workersMu.Unlock()
	check(single == 1, "same subscription ran concurrently")
	subscribeWorker(ctx, api, stream, "burst", nil)
	old := host.hold("late-old")
	subscribeWorker(ctx, api, stream, "replace", contentTarget("late-old", "thread", ""))
	await(ctx, old.started, "late old read did not start")
	subscribeWorker(ctx, api, stream, "replace", contentTarget("new-target", "thread", ""))
	await(ctx, old.cancelled, "replace did not cancel old reader")
	workerSnapshot(ctx, api, stream, "replace", "new-target")
	old.open()
	await(ctx, old.finished, "late old read did not finish")
	host.mutate("worker-6")
	event := workerEvent(ctx, api, stream)
	check(event["subscriptionId"] == "replace" && event["type"] == "patch" && event["baseRevision"] == float64(1), "late success replaced current subscription baseline")
	subscribeWorker(ctx, api, stream, "replace", nil)
	gone := host.hold("unsubscribed")
	subscribeWorker(ctx, api, stream, "gone", contentTarget("unsubscribed", "thread", ""))
	await(ctx, gone.started, "unsubscribe fixture did not start")
	subscribeWorker(ctx, api, stream, "gone", nil)
	await(ctx, gone.cancelled, "unsubscribe did not cancel")
	gone.open()
	await(ctx, gone.finished, "unsubscribed read did not end")
	subscribeWorker(ctx, api, stream, "barrier", contentTarget("barrier", "thread", ""))
	workerSnapshot(ctx, api, stream, "barrier", "barrier")
	subscribeWorker(ctx, api, stream, "barrier", nil)
	other := api.events(ctx)
	disconnected := host.hold("disconnected")
	subscribeWorker(ctx, api, other, "gone", contentTarget("disconnected", "thread", ""))
	await(ctx, disconnected.started, "disconnect fixture did not start")
	other.close()
	await(ctx, disconnected.cancelled, "disconnect did not cancel")
	disconnected.open()
	await(ctx, disconnected.finished, "disconnected read did not end")
	subscribeWorker(ctx, api, stream, "large", contentTarget("oversized", "thread", ""))
	event = workerEvent(ctx, api, stream)
	check(event["type"] == "error" && event["subscriptionId"] == "large" && event["message"] == "This conversation turn exceeds the content transport limit", "oversized raw content was decoded or leaked")
	// Reserve both raw-resource slots. A third pending resource must wait.
	holds := []*contentBarrier{host.hold("slot-0"), host.hold("slot-1"), host.hold("slot-2")}
	for i := 0; i < 2; i++ {
		id := fmt.Sprint("slot-", i)
		subscribeWorker(ctx, api, stream, id, contentTarget(id, "thread", ""))
		await(ctx, holds[i].started, "content slot did not start")
	}
	subscribeWorker(ctx, api, stream, "slot-2", contentTarget("slot-2", "thread", ""))
	select {
	case <-holds[2].started:
		panic("content worker count/maximum raw-byte slots exceeded")
	case <-time.After(30 * time.Millisecond):
	}
	holds[0].open()
	await(ctx, holds[2].started, "queued content did not proceed after slot release")
	for _, hold := range holds {
		hold.open()
	}
	for i := 0; i < 3; i++ {
		event = workerEvent(ctx, api, stream)
		check(event["type"] == "snapshot", "unexpected capacity snapshot")
	}
	for i := 0; i < 3; i++ {
		subscribeWorker(ctx, api, stream, fmt.Sprint("slot-", i), nil)
	}
	host.workersMu.Lock()
	peak := host.peak
	host.workersMu.Unlock()
	check(peak == 2, "content workers were not globally bounded to two")
	closing := host.hold("closing")
	subscribeWorker(ctx, api, stream, "closing", contentTarget("closing", "thread", ""))
	await(ctx, closing.started, "shutdown fixture did not start")
	server.Revoke()
	await(ctx, closing.cancelled, "shutdown did not cancel worker")
	timeout, cancel := context.WithTimeout(ctx, 30*time.Millisecond)
	err = server.Drain(timeout)
	cancel()
	check(errors.Is(err, context.DeadlineExceeded), "Drain failed to join running worker")
	timeout, cancel = context.WithTimeout(ctx, 30*time.Millisecond)
	err = server.Close(timeout)
	cancel()
	check(errors.Is(err, context.DeadlineExceeded), "Close failed to join running worker")
	closing.open()
	must(server.Drain(ctx))
	must(server.Close(ctx))
	host.workersMu.Lock()
	active := host.active
	host.workersMu.Unlock()
	check(active == 0, "shutdown returned with active content work")
	fmt.Println("PASS parallel content, same-key ordering/coalescing, late-success cancellation, disconnect, raw size/slot bounds and repeatable shutdown joins")
}
