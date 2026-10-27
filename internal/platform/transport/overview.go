package transport

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math"
	"reflect"
	"slices"
	"sync"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
)

// Overview presentation facts belong to connected clients, never the persisted
// business state. Revisions are scoped to one renderer context.
type OverviewThread struct {
	ThreadID string `json:"threadId"`
	TypeID   string `json:"typeId"`
}

type OverviewFilter struct {
	Tag     string           `json:"tag"`
	Scope   string           `json:"scope,omitempty"`
	Kind    string           `json:"kind"`
	Aliases []string         `json:"aliases"`
	Count   float64          `json:"count"`
	Threads []OverviewThread `json:"threads"`
}

type OverviewAction struct {
	Kind   string          `json:"kind"`
	At     float64         `json:"at"`
	Tag    json.RawMessage `json:"tag,omitempty"` // absent, null, and a string are distinct
	View   *string         `json:"view,omitempty"`
	Thread *OverviewThread `json:"thread,omitempty"`
	Text   *string         `json:"text,omitempty"`
}

type OverviewContext struct {
	ContextID       string           `json:"contextId"`
	Revision        int64            `json:"revision"`
	OverviewVisible bool             `json:"overviewVisible"`
	Focused         bool             `json:"focused"`
	DocumentVisible bool             `json:"documentVisible"`
	MokuOpen        bool             `json:"mokuOpen"`
	SettingsOpen    bool             `json:"settingsOpen"`
	SelectedThread  *OverviewThread  `json:"selectedThread"`
	FollowUpThread  *OverviewThread  `json:"followUpThread"`
	View            string           `json:"view"`
	SelectedTag     *string          `json:"selectedTag"`
	SelectedScope   *string          `json:"selectedScope,omitempty"`
	Filters         []OverviewFilter `json:"filters"`
	RecentActions   []OverviewAction `json:"recentActions"`
}

type overviewWireContext OverviewContext

// JSON numbers such as 1.0 and 1e0 are valid integer revisions in the wire
// protocol. Decode through float64, matching the original JSON number model.
func (c *overviewWireContext) UnmarshalJSON(raw []byte) error {
	type plainContext OverviewContext
	decoded := struct {
		*plainContext
		Revision float64 `json:"revision"`
	}{plainContext: (*plainContext)(c)}
	if err := json.Unmarshal(raw, &decoded); err != nil {
		return err
	}
	if math.Trunc(decoded.Revision) != decoded.Revision || decoded.Revision < 0 || decoded.Revision > 9007199254740991 {
		return fmt.Errorf("invalid overview revision")
	}
	c.Revision = int64(decoded.Revision)
	return nil
}

type OverviewSnapshot struct {
	OverviewContext
	ClientID string `json:"clientId"`
}

type OverviewSelection struct {
	ClientID  string  `json:"clientId"`
	ContextID string  `json:"contextId"`
	Revision  int64   `json:"revision"`
	Scope     *string `json:"scope,omitempty"`
	Tag       *string `json:"tag"`
}

func ParseOverviewSelection(raw json.RawMessage) (OverviewSelection, error) {
	value, ok := overviewObject(raw, []string{"clientId", "contextId", "revision", "tag"}, []string{"scope"})
	if !ok || !overviewString(value["clientId"], 1, 256) || !overviewString(value["contextId"], 1, 256) ||
		!overviewNumber(value["revision"], true, 9007199254740991) ||
		(!overviewNull(value["scope"]) && value["scope"] != nil && !overviewString(value["scope"], 1, 4096)) ||
		(!overviewNull(value["tag"]) && !overviewString(value["tag"], 1, 4096)) {
		return OverviewSelection{}, model.NewError("INVALID_REQUEST", "Invalid overview selection")
	}
	var selection OverviewSelection
	var revision float64
	_ = json.Unmarshal(value["clientId"], &selection.ClientID)
	_ = json.Unmarshal(value["contextId"], &selection.ContextID)
	_ = json.Unmarshal(value["revision"], &revision)
	_ = json.Unmarshal(value["scope"], &selection.Scope)
	_ = json.Unmarshal(value["tag"], &selection.Tag)
	selection.Revision = int64(revision)
	return selection, nil
}

type OverviewRequest struct {
	OverviewSelection
	RequestID string `json:"requestId"`
	ExpiresAt int64  `json:"expiresAt"`
}

type OverviewResult struct {
	Status  string            `json:"status"`
	Context *OverviewSnapshot `json:"context"`
}

type overviewAcknowledgement struct {
	RequestID string              `json:"requestId"`
	Status    string              `json:"status"`
	Context   overviewWireContext `json:"context"`
}

type overviewClient struct {
	deliver func(any) error
	retired map[string]struct{}
	context *OverviewContext
	pending *overviewPending
}

type overviewPending struct {
	request     OverviewRequest
	context     context.Context
	claimed     bool
	timer       *time.Timer
	cancelWatch func() bool
	result      chan OverviewResult
}

type OverviewBroker struct {
	mu      sync.Mutex
	clients map[string]*overviewClient
	order   []string
	timeout time.Duration
	stopped bool
}

func NewOverviewBroker(timeout time.Duration) *OverviewBroker {
	return &OverviewBroker{clients: make(map[string]*overviewClient), timeout: timeout}
}

func (b *OverviewBroker) Connect(deliver func(any) error) (string, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.stopped {
		return "", model.NewError("SERVICE_STOPPING", "Overview control is stopped")
	}
	id, err := overviewUUID()
	if err != nil {
		return "", err
	}
	b.clients[id] = &overviewClient{deliver: deliver, retired: make(map[string]struct{})}
	b.order = append(b.order, id)
	return id, nil
}

func (b *OverviewBroker) Disconnect(clientID string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.disconnectLocked(clientID)
}

func (b *OverviewBroker) disconnectLocked(clientID string) {
	client := b.clients[clientID]
	if client == nil {
		return
	}
	delete(b.clients, clientID)
	b.order = slices.DeleteFunc(b.order, func(id string) bool { return id == clientID })
	client.context = nil
	b.finishLocked(clientID, client, client.pending, "unavailable")
}

func (b *OverviewBroker) Close() {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.stopped = true
	for clientID := range b.clients {
		b.disconnectLocked(clientID)
	}
}

func (b *OverviewBroker) ReadClients(ctx context.Context) (any, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	clients := make([]OverviewSnapshot, 0, len(b.clients))
	for _, id := range b.order {
		if snapshot := b.snapshotLocked(id); snapshot != nil {
			clients = append(clients, *snapshot)
		}
	}
	return clients, nil
}

// Execute keeps transient presentation commands outside the business command
// registry and its durable receipts.
func (b *OverviewBroker) Execute(path string, raw json.RawMessage) (any, error) {
	switch path {
	case "/overview/context":
		value, ok := overviewObject(raw, []string{"clientId", "context"}, nil)
		if !ok || !overviewString(value["clientId"], 1, 256) || !overviewNullableContext(value["context"]) {
			return nil, model.NewError("INVALID_REQUEST", "Invalid overview context update")
		}
		var update struct {
			ClientID string               `json:"clientId"`
			Context  *overviewWireContext `json:"context"`
		}
		if err := json.Unmarshal(raw, &update); err != nil {
			return nil, model.NewError("INVALID_REQUEST", "Invalid overview context update")
		}
		next := (*OverviewContext)(update.Context)
		overviewNormalizeContext(next)
		b.mu.Lock()
		defer b.mu.Unlock()
		client, err := b.requireClientLocked(update.ClientID)
		if err != nil {
			return nil, err
		}
		return nil, b.acceptContextLocked(update.ClientID, client, next)
	case "/overview/claim":
		value, ok := overviewObject(raw, []string{"clientId", "requestId"}, nil)
		if !ok || !overviewString(value["clientId"], 1, 256) || !overviewString(value["requestId"], 1, 256) {
			return nil, model.NewError("INVALID_REQUEST", "Invalid overview filter claim")
		}
		var claim struct {
			ClientID  string `json:"clientId"`
			RequestID string `json:"requestId"`
		}
		_ = json.Unmarshal(raw, &claim)
		b.mu.Lock()
		defer b.mu.Unlock()
		client := b.clients[claim.ClientID]
		if client == nil || client.pending == nil || client.pending.request.RequestID != claim.RequestID || client.pending.claimed {
			return false, nil
		}
		pending := client.pending
		if time.Now().UnixMilli() >= pending.request.ExpiresAt || pending.context.Err() != nil {
			b.finishLocked(claim.ClientID, client, pending, "unavailable")
			return false, nil
		}
		context := client.context
		request := pending.request
		if context == nil || context.ContextID != request.ContextID || context.Revision != request.Revision || !overviewSelectable(context, request.Tag, request.Scope) {
			b.finishLocked(claim.ClientID, client, pending, "stale")
			return false, nil
		}
		pending.claimed = true
		return true, nil
	case "/overview/ack":
		value, ok := overviewObject(raw, []string{"clientId", "acknowledgement"}, nil)
		if !ok || !overviewString(value["clientId"], 1, 256) || !overviewValidAcknowledgement(value["acknowledgement"]) {
			return nil, model.NewError("INVALID_REQUEST", "Invalid overview acknowledgement update")
		}
		var update struct {
			ClientID        string                  `json:"clientId"`
			Acknowledgement overviewAcknowledgement `json:"acknowledgement"`
		}
		if err := json.Unmarshal(raw, &update); err != nil {
			return nil, model.NewError("INVALID_REQUEST", "Invalid overview acknowledgement update")
		}
		overviewNormalizeContext((*OverviewContext)(&update.Acknowledgement.Context))
		b.mu.Lock()
		defer b.mu.Unlock()
		client, err := b.requireClientLocked(update.ClientID)
		if err != nil {
			return nil, err
		}
		pending := client.pending
		ack := update.Acknowledgement
		if pending == nil || ack.RequestID != pending.request.RequestID {
			return nil, nil
		}
		if pending.context.Err() != nil {
			b.finishLocked(update.ClientID, client, pending, "unavailable")
			return nil, nil
		}
		request, context := pending.request, (*OverviewContext)(&ack.Context)
		if client.context == nil || context.ContextID != request.ContextID || client.context.ContextID != request.ContextID ||
			context.Revision < request.Revision || context.Revision < client.context.Revision ||
			(context.Revision == client.context.Revision && !reflect.DeepEqual(context, client.context)) {
			b.finishLocked(update.ClientID, client, pending, "stale")
			return nil, nil
		}
		if (ack.Status == "applied" || ack.Status == "unchanged") &&
			(!pending.claimed || !overviewSameTag(context.SelectedTag, request.Tag) || !overviewSameScope(context.SelectedScope, request.Scope) ||
				!overviewSelectable(context, request.Tag, request.Scope) ||
				(ack.Status == "applied" && context.Revision <= request.Revision)) {
			return nil, model.NewError("INVALID_REQUEST", "Overview acknowledgement does not confirm the requested filter")
		}
		if err := b.acceptContextLocked(update.ClientID, client, context); err != nil {
			return nil, err
		}
		b.finishLocked(update.ClientID, client, pending, ack.Status)
		return nil, nil
	default:
		return nil, model.NewError("UNKNOWN_COMMAND", "Unknown overview command")
	}
}

func (b *OverviewBroker) SelectFilter(ctx context.Context, selection OverviewSelection) (OverviewResult, error) {
	if err := ctx.Err(); err != nil {
		return OverviewResult{}, err
	}
	if !overviewValidString(selection.ClientID, 1, 256) || !overviewValidString(selection.ContextID, 1, 256) ||
		selection.Revision < 0 || selection.Revision > 9007199254740991 ||
		(selection.Tag != nil && !overviewValidString(*selection.Tag, 1, 4096)) ||
		(selection.Scope != nil && !overviewValidString(*selection.Scope, 1, 4096)) {
		return OverviewResult{}, model.NewError("INVALID_REQUEST", "Invalid overview selection")
	}
	selection.Tag = overviewCloneString(selection.Tag)
	selection.Scope = overviewCloneString(selection.Scope)
	if selection.Tag == nil {
		selection.Scope = nil
	}
	b.mu.Lock()
	client := b.clients[selection.ClientID]
	if client == nil || client.context == nil {
		b.mu.Unlock()
		return OverviewResult{Status: "unavailable"}, nil
	}
	clientContext := client.context
	if clientContext.ContextID != selection.ContextID || clientContext.Revision != selection.Revision || !overviewSelectable(clientContext, selection.Tag, selection.Scope) {
		result := OverviewResult{Status: "stale", Context: b.snapshotLocked(selection.ClientID)}
		b.mu.Unlock()
		return result, nil
	}
	b.finishLocked(selection.ClientID, client, client.pending, "stale")
	id, err := overviewUUID()
	if err != nil {
		b.mu.Unlock()
		return OverviewResult{}, err
	}
	pending := &overviewPending{
		request: OverviewRequest{OverviewSelection: selection, RequestID: id, ExpiresAt: time.Now().Add(b.timeout).UnixMilli()},
		context: ctx,
		result:  make(chan OverviewResult, 1),
	}
	client.pending = pending
	pending.timer = time.AfterFunc(b.timeout, func() {
		b.mu.Lock()
		defer b.mu.Unlock()
		b.finishLocked(selection.ClientID, client, pending, "unavailable")
	})
	pending.cancelWatch = context.AfterFunc(ctx, func() {
		b.mu.Lock()
		defer b.mu.Unlock()
		b.finishLocked(selection.ClientID, client, pending, "unavailable")
	})
	b.mu.Unlock()
	if ctx.Err() != nil {
		b.mu.Lock()
		b.finishLocked(selection.ClientID, client, pending, "unavailable")
		b.mu.Unlock()
	} else if err := overviewDeliver(client.deliver, pending.request); err != nil {
		b.mu.Lock()
		b.finishLocked(selection.ClientID, client, pending, "unavailable")
		b.mu.Unlock()
	}
	select {
	case result := <-pending.result:
		return result, nil
	case <-ctx.Done():
		b.mu.Lock()
		b.finishLocked(selection.ClientID, client, pending, "unavailable")
		b.mu.Unlock()
		return <-pending.result, nil
	}
}

func (b *OverviewBroker) finishLocked(clientID string, client *overviewClient, pending *overviewPending, status string) {
	if pending == nil || client.pending != pending {
		return
	}
	client.pending = nil
	if pending.timer != nil {
		pending.timer.Stop()
	}
	if pending.cancelWatch != nil {
		pending.cancelWatch()
	}
	if pending.context.Err() != nil {
		status = "unavailable"
	}
	pending.result <- OverviewResult{Status: status, Context: b.snapshotLocked(clientID)}
}

func (b *OverviewBroker) acceptContextLocked(clientID string, client *overviewClient, next *OverviewContext) error {
	previous := client.context
	if next != nil {
		if _, retired := client.retired[next.ContextID]; retired {
			return model.NewError("STALE_CONTEXT", "Overview renderer context has been revoked")
		}
	}
	if next != nil && previous != nil && next.ContextID == previous.ContextID {
		if next.Revision < previous.Revision || (next.Revision == previous.Revision && !reflect.DeepEqual(next, previous)) {
			return model.NewError("STALE_CONTEXT", "Overview revision must increase when context changes")
		}
	} else if previous != nil {
		if len(client.retired) >= 128 {
			return model.NewError("CAPACITY_EXHAUSTED", "Reconnect the overview client before creating more contexts")
		}
		client.retired[previous.ContextID] = struct{}{}
	}
	client.context = next
	if next == nil || (previous != nil && previous.ContextID != next.ContextID) {
		b.finishLocked(clientID, client, client.pending, "unavailable")
	}
	return nil
}

func (b *OverviewBroker) requireClientLocked(clientID string) (*overviewClient, error) {
	client := b.clients[clientID]
	if client == nil {
		return nil, model.NewError("OVERVIEW_UNAVAILABLE", "Overview stream is no longer connected")
	}
	return client, nil
}

func (b *OverviewBroker) snapshotLocked(clientID string) *OverviewSnapshot {
	client := b.clients[clientID]
	if client == nil || client.context == nil {
		return nil
	}
	// All state was validated at entry; a JSON copy preserves optional fields and
	// isolates callers from mutable slices and pointers owned by the live client.
	raw, _ := json.Marshal(client.context)
	var copied OverviewContext
	_ = json.Unmarshal(raw, &copied)
	return &OverviewSnapshot{OverviewContext: copied, ClientID: clientID}
}

func overviewSelectable(context *OverviewContext, tag *string, scope *string) bool {
	if tag == nil {
		return true
	}
	for _, filter := range context.Filters {
		if filter.Tag != *tag {
			continue
		}
		if scope == nil || filter.Scope == *scope {
			return true
		}
	}
	return false
}

func overviewSameTag(left, right *string) bool {
	return left == nil && right == nil || left != nil && right != nil && *left == *right
}

// overviewSameScope treats an unscoped request as legacy and accepts any
// reported selection scope. A scoped request must be acknowledged with the
// same scope so a same-named tag in another scope cannot satisfy it.
func overviewSameScope(selected, requested *string) bool {
	return requested == nil || selected != nil && *selected == *requested
}

func overviewCloneString(value *string) *string {
	if value == nil {
		return nil
	}
	copy := *value
	return &copy
}

func overviewDeliver(deliver func(any) error, request OverviewRequest) (err error) {
	defer func() {
		if recovered := recover(); recovered != nil {
			err = fmt.Errorf("overview delivery failed: %v", recovered)
		}
	}()
	// The receiver may modify the request. It must not mutate the pending claim.
	request.Tag = overviewCloneString(request.Tag)
	return deliver(request)
}

func overviewUUID() (string, error) {
	var value [16]byte
	if _, err := rand.Read(value[:]); err != nil {
		return "", err
	}
	value[6] = value[6]&0x0f | 0x40
	value[8] = value[8]&0x3f | 0x80
	var encoded [36]byte
	hex.Encode(encoded[0:8], value[0:4])
	encoded[8] = '-'
	hex.Encode(encoded[9:13], value[4:6])
	encoded[13] = '-'
	hex.Encode(encoded[14:18], value[6:8])
	encoded[18] = '-'
	hex.Encode(encoded[19:23], value[8:10])
	encoded[23] = '-'
	hex.Encode(encoded[24:36], value[10:16])
	return string(encoded[:]), nil
}

func overviewObject(raw json.RawMessage, required, optional []string) (map[string]json.RawMessage, bool) {
	var object map[string]json.RawMessage
	if json.Unmarshal(raw, &object) != nil || object == nil {
		return nil, false
	}
	for _, key := range required {
		if _, exists := object[key]; !exists {
			return nil, false
		}
	}
	for key := range object {
		if !slices.Contains(required, key) && !slices.Contains(optional, key) {
			return nil, false
		}
	}
	return object, true
}

func overviewNull(raw json.RawMessage) bool {
	return bytes.Equal(bytes.TrimSpace(raw), []byte("null"))
}

func overviewString(raw json.RawMessage, min, max int) bool {
	var value string
	return !overviewNull(raw) && json.Unmarshal(raw, &value) == nil && overviewValidString(value, min, max)
}

func overviewValidString(value string, min, max int) bool {
	length := 0
	for _, character := range value {
		length++
		if character > 0xffff {
			length++
		}
	}
	return length >= min && length <= max
}

func overviewEnum(raw json.RawMessage, options ...string) bool {
	var value string
	return !overviewNull(raw) && json.Unmarshal(raw, &value) == nil && slices.Contains(options, value)
}

func overviewNumber(raw json.RawMessage, integer bool, max float64) bool {
	var value float64
	if overviewNull(raw) || json.Unmarshal(raw, &value) != nil || math.IsInf(value, 0) || math.IsNaN(value) || value < 0 || value > max {
		return false
	}
	return !integer || math.Trunc(value) == value
}

func overviewBoolean(raw json.RawMessage) bool {
	var value bool
	return !overviewNull(raw) && json.Unmarshal(raw, &value) == nil
}

func overviewArray(raw json.RawMessage, max int, validate func(json.RawMessage) bool) bool {
	var items []json.RawMessage
	if overviewNull(raw) || json.Unmarshal(raw, &items) != nil || items == nil || len(items) > max {
		return false
	}
	for _, item := range items {
		if !validate(item) {
			return false
		}
	}
	return true
}

func overviewValidThread(raw json.RawMessage) bool {
	value, ok := overviewObject(raw, []string{"threadId", "typeId"}, nil)
	return ok && overviewString(value["threadId"], 1, 256) && overviewString(value["typeId"], 1, 256)
}

func overviewValidAction(raw json.RawMessage) bool {
	value, ok := overviewObject(raw, []string{"kind", "at"}, []string{"tag", "view", "thread", "text"})
	if !ok || !overviewEnum(value["kind"], "filter", "view", "open-thread", "moku-input", "thread-input") || !overviewNumber(value["at"], false, math.MaxFloat64) {
		return false
	}
	if tag, exists := value["tag"]; exists && !overviewNull(tag) && !overviewString(tag, 1, 4096) {
		return false
	}
	if view, exists := value["view"]; exists && !overviewEnum(view, "default", "archived") {
		return false
	}
	if thread, exists := value["thread"]; exists && !overviewValidThread(thread) {
		return false
	}
	if text, exists := value["text"]; exists && !overviewString(text, 0, 16000) {
		return false
	}
	return true
}

func overviewValidContext(raw json.RawMessage) bool {
	value, ok := overviewObject(raw, []string{
		"contextId", "revision", "overviewVisible", "focused", "documentVisible", "mokuOpen", "settingsOpen",
		"selectedThread", "followUpThread", "view", "selectedTag", "filters", "recentActions",
	}, []string{"selectedScope"})
	if !ok || !overviewString(value["contextId"], 1, 256) || !overviewNumber(value["revision"], true, 9007199254740991) ||
		!overviewEnum(value["view"], "default", "archived") {
		return false
	}
	for _, key := range []string{"overviewVisible", "focused", "documentVisible", "mokuOpen", "settingsOpen"} {
		if !overviewBoolean(value[key]) {
			return false
		}
	}
	for _, key := range []string{"selectedThread", "followUpThread"} {
		if !overviewNull(value[key]) && !overviewValidThread(value[key]) {
			return false
		}
	}
	if !overviewNull(value["selectedTag"]) && !overviewString(value["selectedTag"], 1, 4096) {
		return false
	}
	if !overviewNull(value["selectedScope"]) && value["selectedScope"] != nil && !overviewString(value["selectedScope"], 1, 4096) {
		return false
	}
	seen := make(map[string]struct{})
	if !overviewArray(value["filters"], 2048, func(raw json.RawMessage) bool {
		filter, valid := overviewObject(raw, []string{"tag", "kind", "aliases", "count", "threads"}, []string{"scope"})
		if !valid || !overviewString(filter["tag"], 1, 4096) || !overviewEnum(filter["kind"], "directory", "semantic") ||
			(!overviewNull(filter["scope"]) && filter["scope"] != nil && !overviewString(filter["scope"], 1, 4096)) ||
			!overviewNumber(filter["count"], true, 9007199254740991) ||
			!overviewArray(filter["aliases"], 2048, func(raw json.RawMessage) bool { return overviewString(raw, 1, 4096) }) ||
			!overviewArray(filter["threads"], 20000, overviewValidThread) {
			return false
		}
		var tag, scope string
		_ = json.Unmarshal(filter["tag"], &tag)
		_ = json.Unmarshal(filter["scope"], &scope)
		// Selection is addressed by (scope, tag); a directory and a semantic
		// filter with the same pair would be ambiguous.
		key := scope + "\x00" + tag
		if _, duplicate := seen[key]; duplicate {
			return false
		}
		seen[key] = struct{}{}
		return true
	}) {
		return false
	}
	return overviewArray(value["recentActions"], 32, overviewValidAction)
}

func overviewNullableContext(raw json.RawMessage) bool {
	return overviewNull(raw) || overviewValidContext(raw)
}

func overviewValidAcknowledgement(raw json.RawMessage) bool {
	value, ok := overviewObject(raw, []string{"requestId", "status", "context"}, nil)
	return ok && overviewString(value["requestId"], 1, 256) &&
		overviewEnum(value["status"], "applied", "unchanged", "stale", "unavailable") && overviewValidContext(value["context"])
}

func overviewNormalizeContext(context *OverviewContext) {
	if context == nil {
		return
	}
	for i := range context.RecentActions {
		action := &context.RecentActions[i]
		if action.Tag == nil {
			continue
		}
		var value *string
		_ = json.Unmarshal(action.Tag, &value)
		action.Tag, _ = json.Marshal(value)
	}
}
