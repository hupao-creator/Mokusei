package transport

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"strings"
	"sync"

	"github.com/hupao-creator/Mokusei/internal/core/model"
)

type contentTarget struct {
	ThreadID string       `json:"threadId"`
	Scope    ContentScope `json:"scope"`
}
type contentSubscription struct {
	ctx                    context.Context
	cancel                 context.CancelFunc
	id                     string
	target                 contentTarget
	sourceRevision         *int64
	revision               int64
	value                  any
	hasValue               bool
	valueDigest            [sha256.Size]byte
	hasValueDigest         bool
	working, queued, dirty bool
}
type contentServer struct {
	mu         sync.Mutex
	clients    map[string]map[string]*contentSubscription
	host       Host
	client     func(string) *eventStream
	wake       chan struct{}
	ctx        context.Context
	cancel     context.CancelFunc
	closed     bool
	ready      []contentJob
	done       chan struct{}
	writeLimit int
}

func newContentServer(ctx context.Context, host Host, client func(string) *eventStream) *contentServer {
	ctx, cancel := context.WithCancel(ctx)
	content := &contentServer{clients: make(map[string]map[string]*contentSubscription), host: host, client: client, wake: make(chan struct{}, 1), done: make(chan struct{}), ctx: ctx, cancel: cancel, writeLimit: contentWriteLimit}
	go content.run()
	return content
}
func (c *contentServer) contentLimit() int {
	if c.writeLimit > 0 {
		return c.writeLimit
	}
	return contentWriteLimit
}
func (c *contentServer) connect(clientID string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if !c.closed {
		c.clients[clientID] = make(map[string]*contentSubscription)
	}
}
func (c *contentServer) disconnect(clientID string) {
	c.mu.Lock()
	for _, subscription := range c.clients[clientID] {
		subscription.cancel()
		c.removeQueuedLocked(subscription)
	}
	delete(c.clients, clientID)
	c.mu.Unlock()
}
func (c *contentServer) close() {
	c.mu.Lock()
	c.closed = true
	for _, subscriptions := range c.clients {
		for _, subscription := range subscriptions {
			subscription.cancel()
		}
	}
	c.clients = make(map[string]map[string]*contentSubscription)
	c.ready = nil
	c.mu.Unlock()
	c.cancel()
}
func (c *contentServer) publish() {
	c.mu.Lock()
	if !c.closed {
		for clientID, subs := range c.clients {
			for _, sub := range subs {
				c.dirtyLocked(clientID, sub)
			}
		}
	}
	c.mu.Unlock()
	c.signal()
}
func validContentIdentity(value string) bool {
	return strings.TrimSpace(value) != "" && utf16Length(value) <= 256
}
func parseContentSubscription(raw []byte) (string, string, *contentTarget, error) {
	fail := func() (string, string, *contentTarget, error) {
		return "", "", nil, model.NewError("INVALID_REQUEST", "Invalid thread content subscription")
	}
	var body map[string]json.RawMessage
	if json.Unmarshal(raw, &body) != nil || body == nil {
		return fail()
	}
	var clientID, subscriptionID string
	if json.Unmarshal(body["clientId"], &clientID) != nil || json.Unmarshal(body["subscriptionId"], &subscriptionID) != nil || !validContentIdentity(clientID) || !validContentIdentity(subscriptionID) {
		return fail()
	}
	targetRaw, exists := body["target"]
	if !exists {
		return fail()
	}
	if model.IsNull(targetRaw) {
		return clientID, subscriptionID, nil, nil
	}
	var target contentTarget
	if json.Unmarshal(targetRaw, &target) != nil || !validContentIdentity(target.ThreadID) {
		return fail()
	}
	switch target.Scope.Kind {
	case "thread":
		target.Scope.Key = ""
	case "turn", "execution":
		if !validContentIdentity(target.Scope.Key) {
			return fail()
		}
	default:
		return fail()
	}
	return clientID, subscriptionID, &target, nil
}
func (c *contentServer) update(raw []byte) error {
	clientID, id, target, err := parseContentSubscription(raw)
	if err != nil {
		return err
	}
	client := c.client(clientID)
	if client == nil {
		return model.NewError("CONTENT_UNAVAILABLE", "Thread content stream is no longer connected")
	}
	c.mu.Lock()
	subscriptions, exists := c.clients[clientID]
	if !exists || c.closed {
		c.mu.Unlock()
		return model.NewError("CONTENT_UNAVAILABLE", "Thread content stream is no longer connected")
	}
	if target == nil {
		if previous := subscriptions[id]; previous != nil {
			previous.cancel()
			c.removeQueuedLocked(previous)
		}
		delete(subscriptions, id)
		client.cancelContent(id)
		c.mu.Unlock()
		return nil
	}
	if subscriptions[id] == nil && len(subscriptions) >= 32 {
		c.mu.Unlock()
		return model.NewError("CAPACITY_EXHAUSTED", "Too many open thread content resources")
	}
	// Cancel and replace atomically relative to publication so a former revision
	// cannot be enqueued after the new subscription's first snapshot.
	client.cancelContent(id)
	if previous := subscriptions[id]; previous != nil {
		previous.cancel()
		c.removeQueuedLocked(previous)
	}
	subscriptionContext, cancel := context.WithCancel(c.ctx)
	subscriptions[id] = &contentSubscription{id: id, target: *target, ctx: subscriptionContext, cancel: cancel}
	c.dirtyLocked(clientID, subscriptions[id])
	c.mu.Unlock()
	c.signal()
	return nil
}
func (c *contentServer) publishOne(clientID string, subscription *contentSubscription) {
	defer func() {
		if recover() != nil {
			c.fail(clientID, subscription, model.NewError("CONTENT_UNAVAILABLE", "Thread content presentation failed"))
		}
	}()
	if subscription.ctx.Err() != nil {
		return
	}
	snapshot, err := c.read(subscription)
	if err != nil {
		c.fail(clientID, subscription, err)
		return
	}
	if snapshot == nil || subscription.ctx.Err() != nil {
		return
	}
	limit := c.contentLimit()
	if len(snapshot.Value) > limit {
		c.fail(clientID, subscription, model.NewError("CONTENT_TOO_LARGE", "This conversation turn exceeds the content transport limit"))
		return
	}
	// Arm the digest only after a semantic no-op, and disarm it on visible
	// changes. Continuously changing streams do not pay for hashing, while
	// repeated hidden-detail updates avoid decoding/diffing. No second raw
	// payload is retained.
	var digest [sha256.Size]byte
	if subscription.hasValueDigest {
		digest = sha256.Sum256(snapshot.Value)
	}
	if subscription.hasValueDigest && subscription.valueDigest == digest {
		c.mu.Lock()
		if !c.closed && c.clients[clientID][subscription.id] == subscription {
			sourceRevision := snapshot.Revision
			subscription.sourceRevision = &sourceRevision
		}
		c.mu.Unlock()
		return
	}
	value, err := model.Decode(snapshot.Value)
	if err != nil {
		c.fail(clientID, subscription, model.NewError("INVALID_RESPONSE", "Thread content is not valid JSON"))
		return
	}
	revision := subscription.revision + 1
	snapshotEvent := map[string]any{"type": "snapshot", "subscriptionId": subscription.id, "revision": revision, "value": value}
	var client *eventStream
	var encoded []byte
	if subscription.hasValue {
		delta := CreateBoundedJSONDelta(subscription.value, value, DeltaBudget{MaxOperations: maxDeltaOperations, MaxBytes: min(limit, len(snapshot.Value))})
		if delta.Complete && len(delta.Operations) == 0 {
			if !subscription.hasValueDigest {
				digest = sha256.Sum256(snapshot.Value)
			}
			c.mu.Lock()
			if !c.closed && c.clients[clientID][subscription.id] == subscription {
				sourceRevision := snapshot.Revision
				subscription.sourceRevision = &sourceRevision
				subscription.valueDigest = digest
				subscription.hasValueDigest = true
			}
			c.mu.Unlock()
			return
		}
		if subscription.ctx.Err() != nil {
			return
		}
		client = c.client(clientID)
		if client == nil {
			return
		}
		var encodedPatch []byte
		if delta.Complete {
			patchEvent := map[string]any{"type": "patch", "subscriptionId": subscription.id, "baseRevision": subscription.revision, "revision": revision, "patch": delta.Operations}
			encodedPatch, err = client.encodeContent(patchEvent)
			if err != nil {
				c.fail(clientID, subscription, err)
				return
			}
		}
		// A bounded patch that already exceeds the frame cannot be selected,
		// but a patch that fits remains usable even when a fresh snapshot of the
		// same value would not. A conservative minimum snapshot size lets a
		// clearly smaller patch skip the full snapshot encoding; otherwise both
		// complete wire events are compared exactly.
		if len(encodedPatch) > 0 && len(encodedPatch) <= limit {
			minSnapshot, err := minContentSnapshotBytes(client, snapshotEvent, value)
			if err != nil {
				c.fail(clientID, subscription, err)
				return
			}
			if len(encodedPatch) < minSnapshot {
				encoded = encodedPatch
			} else {
				encodedSnapshot, err := client.encodeContent(snapshotEvent)
				if err != nil {
					c.fail(clientID, subscription, err)
					return
				}
				if len(encodedSnapshot) > limit || len(encodedPatch) < len(encodedSnapshot) {
					encoded = encodedPatch
				} else {
					encoded = encodedSnapshot
				}
			}
		} else {
			encodedSnapshot, err := client.encodeContent(snapshotEvent)
			if err != nil {
				c.fail(clientID, subscription, err)
				return
			}
			if len(encodedSnapshot) > limit {
				c.fail(clientID, subscription, model.NewError("CONTENT_TOO_LARGE", "This conversation turn exceeds the content transport limit"))
				return
			}
			encoded = encodedSnapshot
		}
	} else {
		if subscription.ctx.Err() != nil {
			return
		}
		client = c.client(clientID)
		if client == nil {
			return
		}
		encoded, err = client.encodeContent(snapshotEvent)
		if err != nil {
			c.fail(clientID, subscription, err)
			return
		}
		if len(encoded) > limit {
			c.fail(clientID, subscription, model.NewError("CONTENT_TOO_LARGE", "This conversation turn exceeds the content transport limit"))
			return
		}
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed || c.clients[clientID][subscription.id] != subscription {
		return
	}
	sourceRevision := snapshot.Revision
	subscription.sourceRevision = &sourceRevision
	if err = client.enqueue(encoded, subscription.id); err != nil {
		delete(c.clients[clientID], subscription.id)
		subscription.cancel()
		client.cancelContent(subscription.id)
		client.deliverContentError(subscription.id, err.Error())
		return
	}
	subscription.revision = revision
	subscription.value = value
	subscription.hasValue = true
	subscription.hasValueDigest = false
}
func (c *contentServer) fail(clientID string, subscription *contentSubscription, cause error) {
	client := c.client(clientID)
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed || c.clients[clientID][subscription.id] != subscription {
		return
	}
	delete(c.clients[clientID], subscription.id)
	subscription.cancel()
	if client == nil {
		return
	}
	client.cancelContent(subscription.id)
	client.deliverContentError(subscription.id, cause.Error())
}

// minJSONValueBytes is a conservative lower bound for encoding one decoded
// model value. It walks the value without allocating an encoded copy, so a
// clearly smaller patch can skip building a full snapshot merely to compare
// sizes. JSON escaping only grows strings and object keys, never shrinks below
// their UTF-8 length plus delimiters.
func minJSONValueBytes(value any) int {
	switch typed := value.(type) {
	case nil:
		return 4
	case bool:
		if typed {
			return 4
		}
		return 5
	case string:
		return 2 + len(typed)
	case json.Number:
		return len(typed)
	case []any:
		total := 2
		for index, item := range typed {
			if index > 0 {
				total++
			}
			total += minJSONValueBytes(item)
		}
		return total
	case map[string]any:
		total := 2
		first := true
		for key, item := range typed {
			if !first {
				total++
			}
			first = false
			total += 2 + len(key) + 1 + minJSONValueBytes(item)
		}
		return total
	default:
		// Production values come from model.Decode, so this fallback only
		// covers fixture-specific numeric or named types. An exact encoded
		// length is still a valid (if not tight) lower bound.
		encoded, err := json.Marshal(value)
		if err != nil {
			return 0
		}
		return len(encoded)
	}
}
func minContentSnapshotBytes(client *eventStream, snapshotEvent map[string]any, value any) (int, error) {
	probe := make(map[string]any, len(snapshotEvent))
	for key, item := range snapshotEvent {
		probe[key] = item
	}
	probe["value"] = json.RawMessage("0")
	encoded, err := client.encodeContent(probe)
	if err != nil {
		return 0, err
	}
	return len(encoded) - 1 + minJSONValueBytes(value), nil
}

func (c *contentServer) read(subscription *contentSubscription) (snapshot *ContentSnapshot, err error) {
	defer func() {
		if recover() != nil {
			snapshot = nil
			err = model.NewError("CONTENT_UNAVAILABLE", "Thread content presentation failed")
		}
	}()
	return c.host.ReadThreadContent(subscription.ctx, subscription.target.ThreadID, subscription.target.Scope, subscription.sourceRevision)
}
