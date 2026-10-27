package transport

import (
	"context"
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
	working, queued, dirty bool
}
type contentServer struct {
	mu      sync.Mutex
	clients map[string]map[string]*contentSubscription
	host    Host
	client  func(string) *eventStream
	wake    chan struct{}
	ctx     context.Context
	cancel  context.CancelFunc
	closed  bool
	ready   []contentJob
	done    chan struct{}
}

func newContentServer(ctx context.Context, host Host, client func(string) *eventStream) *contentServer {
	ctx, cancel := context.WithCancel(ctx)
	content := &contentServer{clients: make(map[string]map[string]*contentSubscription), host: host, client: client, wake: make(chan struct{}, 1), done: make(chan struct{}), ctx: ctx, cancel: cancel}
	go content.run()
	return content
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
	if len(snapshot.Value) > contentWriteLimit {
		c.fail(clientID, subscription, model.NewError("CONTENT_TOO_LARGE", "This conversation turn exceeds the content transport limit"))
		return
	}
	value, err := model.Decode(snapshot.Value)
	if err != nil {
		c.fail(clientID, subscription, model.NewError("INVALID_RESPONSE", "Thread content is not valid JSON"))
		return
	}
	revision := subscription.revision + 1
	event := map[string]any{"type": "snapshot", "subscriptionId": subscription.id, "revision": revision, "value": value}
	var patch []map[string]any
	if subscription.hasValue {
		patch = CreateJSONDelta(subscription.value, value)
		event = map[string]any{"type": "patch", "subscriptionId": subscription.id, "baseRevision": subscription.revision, "revision": revision, "patch": patch}
	}
	if subscription.ctx.Err() != nil {
		return
	}
	client := c.client(clientID)
	if client == nil {
		return
	}
	encoded, err := client.encodeContent(event)
	if err != nil {
		c.fail(clientID, subscription, err)
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed || c.clients[clientID][subscription.id] != subscription {
		return
	}
	sourceRevision := snapshot.Revision
	subscription.sourceRevision = &sourceRevision
	if subscription.hasValue && len(patch) == 0 {
		return
	}
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

func (c *contentServer) read(subscription *contentSubscription) (snapshot *ContentSnapshot, err error) {
	defer func() {
		if recover() != nil {
			snapshot = nil
			err = model.NewError("CONTENT_UNAVAILABLE", "Thread content presentation failed")
		}
	}()
	return c.host.ReadThreadContent(subscription.ctx, subscription.target.ThreadID, subscription.target.Scope, subscription.sourceRevision)
}
