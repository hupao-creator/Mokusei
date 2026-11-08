package runtime

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"sync"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/core/store"
)

type lifecycleCapability struct {
	runtime   *Runtime
	mu        sync.Mutex
	consumers map[string]*lifecycleConsumer
}
type lifecycleConsumer struct {
	cap           *lifecycleCapability
	definition    plugin.LifecycleConsumerDefinition
	excluded      map[string]bool
	pendingReader *store.PendingReader
}

func (l *lifecycleCapability) Register(def plugin.LifecycleConsumerDefinition) (plugin.LifecycleConsumer, error) {
	def.Filter = cloneLifecycleScope(def.Filter)
	def.History = cloneLifecycleScope(def.History)
	if err := identifier(def.ID); err != nil {
		return nil, err
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.consumers[def.ID] != nil {
		return nil, fmt.Errorf("lifecycle consumer already registered: %s", def.ID)
	}
	c := &lifecycleConsumer{cap: l, definition: def, excluded: map[string]bool{}}
	if def.History == nil {
		c.definition.History = def.Filter
	}
	if def.Replay != "" && def.Replay != "pending" && def.Replay != "new" {
		return nil, errors.New("invalid lifecycle replay mode")
	}
	if def.Replay == "new" {
		snapshot := l.runtime.config.Store.Snapshot()
		work, exists, err := snapshot.Work(def.ID)
		if err != nil {
			return nil, err
		}
		ids, err := snapshot.EventIDs(append(storeFilters(c.definition.Filter), storeFilters(c.definition.History)...))
		if err != nil {
			return nil, err
		}
		for _, id := range ids {
			if !exists || !contains(work.EventIDs, id) {
				c.excluded[id] = true
			}
		}
	}
	excluded := make([]string, 0, len(c.excluded))
	for id := range c.excluded {
		excluded = append(excluded, id)
	}
	c.pendingReader = store.NewPendingReader(c.ID(), storeFilters(c.definition.Filter), excluded)
	l.consumers[def.ID] = c
	return c, nil
}
func (l *lifecycleCapability) Subscribe(ctx context.Context, scope plugin.LifecycleScope, listener func(plugin.LifecycleEvent)) (func(), error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	snapshot := l.runtime.config.Store.Snapshot()
	filters := storeFilters(scope)
	if len(scope) == 0 {
		filters = []store.Filter{{Types: []string{}}}
	}
	reader, err := store.NewEventReader(snapshot, filters)
	if err != nil {
		return nil, err
	}
	changes, unsubscribe := l.runtime.config.Store.SubscribeLifecycle("", filters, "")
	lifetime, cancel := context.WithCancel(ctx)
	var once sync.Once
	stop := func() { once.Do(func() { cancel(); unsubscribe() }) }
	go func() {
		defer stop()
		for {
			select {
			case <-lifetime.Done():
				return
			case _, ok := <-changes:
				if !ok {
					return
				}
				snapshot := l.runtime.config.Store.Snapshot()
				events, err := reader.Read(snapshot)
				if err != nil {
					l.runtime.log("lifecycle.subscribe", err)
					continue
				}
				for _, event := range events {
					safeLifecycleCallback(func() { listener(publicEvent(event)) }, l.runtime.log)
				}
			}
		}
	}()
	return stop, nil
}
func (c *lifecycleConsumer) ID() string { return c.definition.ID }

// Optional lifecycle control lets background runners pause new batches without
// altering their durable inboxes, attempts or event acknowledgements.
func (c *lifecycleConsumer) ServiceDraining() bool { return c.cap.runtime.serviceDrainPending() }
func (c *lifecycleConsumer) Work() *plugin.LifecycleWork {
	return c.work(c.cap.runtime.config.Store.Snapshot())
}
func (c *lifecycleConsumer) work(snapshot store.Snapshot) *plugin.LifecycleWork {
	work, exists, err := snapshot.Work(c.ID())
	if err != nil {
		c.cap.runtime.log("lifecycle.work", err)
	}
	if err != nil || !exists {
		return nil
	}
	return publicWork(work)
}
func (c *lifecycleConsumer) Pending(query plugin.PendingEventsQuery) ([]plugin.LifecycleEvent, error) {
	if query.Limit < 0 {
		return nil, errors.New("invalid pending limit")
	}
	return c.pending(c.cap.runtime.config.Store.Snapshot(), query)
}
func (c *lifecycleConsumer) pending(snapshot store.Snapshot, query plugin.PendingEventsQuery) ([]plugin.LifecycleEvent, error) {
	result := []plugin.LifecycleEvent{}
	if len(c.definition.Filter) == 0 {
		return result, nil
	}
	events, err := c.pendingReader.Read(snapshot, store.PendingQuery{ExcludeIDs: query.ExcludeIDs, ExcludeTypes: query.ExcludeTypes, Limit: query.Limit})
	if err != nil {
		return nil, err
	}
	for _, event := range events {
		result = append(result, publicEvent(event))
	}
	return result, nil
}
func (c *lifecycleConsumer) Read(query plugin.LifecycleHistoryQuery) (plugin.Page[plugin.LifecycleHistoryEntry], error) {
	offset := 0
	var err error
	if query.Cursor != "" {
		offset, err = strconv.Atoi(query.Cursor)
	}
	if err != nil || offset < 0 || query.Limit < 1 || query.Limit > 1000 {
		return plugin.Page[plugin.LifecycleHistoryEntry]{}, errors.New("invalid lifecycle history page")
	}
	result := plugin.Page[plugin.LifecycleHistoryEntry]{Items: []plugin.LifecycleHistoryEntry{}}
	if len(c.definition.History) == 0 {
		return result, nil
	}
	snapshot := c.cap.runtime.config.Store.Snapshot()
	entries, more, err := snapshot.QueryHistory(store.HistoryQuery{Filters: storeFilters(c.definition.History), EventIDs: query.EventIDs, ExcludedIDs: c.excluded, Offset: offset, Limit: query.Limit})
	if err != nil {
		return result, err
	}
	for _, entry := range entries {
		outcomes := map[string]string{}
		for key, value := range entry.Outcomes {
			outcomes[key] = string(value)
		}
		result.Items = append(result.Items, plugin.LifecycleHistoryEntry{LifecycleEvent: publicEvent(entry.Event), Outcomes: outcomes})
	}
	if more {
		result.NextCursor = strconv.Itoa(offset + len(result.Items))
	}
	return result, nil
}

func (c *lifecycleConsumer) Begin(ctx context.Context, ids []string) (plugin.LifecycleWork, error) {
	release, err := c.cap.runtime.beginServiceAdmission(false)
	if err != nil {
		return plugin.LifecycleWork{}, err
	}
	defer release()
	id, err := newID()
	if err != nil {
		return plugin.LifecycleWork{}, err
	}
	work := store.Work{ID: id, EventIDs: append([]string{}, ids...), Receipts: map[string]json.RawMessage{}}
	_, err = c.cap.runtime.config.Store.Update(ctx, func(tx *store.Tx) error {
		if err := c.assertEvents(tx.Snapshot(), ids); err != nil {
			return err
		}
		return tx.SetWork(c.ID(), "", work)
	})
	if err != nil {
		return plugin.LifecycleWork{}, err
	}
	return *publicWork(work), nil
}
func (c *lifecycleConsumer) Update(ctx context.Context, value plugin.LifecycleWorkUpdate) error {
	_, err := c.cap.runtime.config.Store.Update(ctx, func(tx *store.Tx) error {
		if err := c.assertEvents(tx.Snapshot(), value.EventIDs); err != nil {
			return err
		}
		return tx.SetWork(c.ID(), value.ID, store.Work{ID: value.ID, EventIDs: value.EventIDs, Attempts: int64(value.Attempts), NextAttemptAt: value.NextAttemptAt, ExecutionID: value.ExecutionID, Receipts: map[string]json.RawMessage{}})
	})
	return err
}
func (c *lifecycleConsumer) Settle(ctx context.Context, id, outcome string) error {
	_, err := c.cap.runtime.config.Store.Update(ctx, func(tx *store.Tx) error { return tx.SettleWork(c.ID(), id, store.Outcome(outcome)) })
	return err
}
func (c *lifecycleConsumer) assertEvents(snapshot store.Snapshot, ids []string) error {
	pending, err := snapshot.Pending(c.ID(), store.PendingQuery{Filters: storeFilters(c.definition.Filter), EventIDs: ids})
	if err != nil {
		return err
	}
	allowed := map[string]bool{}
	if len(c.definition.Filter) > 0 {
		for _, e := range pending {
			if !c.excluded[e.ID] {
				allowed[e.ID] = true
			}
		}
	}
	for _, id := range ids {
		if !allowed[id] {
			return fmt.Errorf("lifecycle event unavailable: %s", id)
		}
	}
	return nil
}
func (c *lifecycleConsumer) Subscribe(ctx context.Context, listener func(plugin.LifecycleNotification), observe *plugin.PrivateSessionRef) (func(), error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	filters := storeFilters(c.definition.Filter)
	if len(c.definition.Filter) == 0 {
		filters = []store.Filter{{Types: []string{}}}
	}
	observedKey := ""
	if observe != nil {
		observedKey = privateSessionKey(observe.Owner, observe.SessionKey)
	}
	changes, unsubscribe := c.cap.runtime.config.Store.SubscribeLifecycle(c.ID(), filters, observedKey)
	lifetime, cancel := context.WithCancel(ctx)
	var once sync.Once
	stop := func() { once.Do(func() { cancel(); unsubscribe() }) }
	go func() {
		defer stop()
		var previous []byte
		var lifecycleRevision uint64
		var sessionHash string
		initialized := false
		publish := func() {
			snapshot := c.cap.runtime.config.Store.Snapshot()
			observedHash := ""
			if observe != nil {
				observedHash, _ = snapshot.RecordHash(privateSessionKey(observe.Owner, observe.SessionKey))
			}
			// Text and telemetry commits do not change lifecycle inboxes. Private
			// observations have a separate identity so their settlement still wakes
			// a runner even when no lifecycle fact was appended.
			if initialized && snapshot.LifecycleRevision() == lifecycleRevision && observedHash == sessionHash {
				return
			}
			pending, err := c.pending(snapshot, plugin.PendingEventsQuery{})
			if err != nil {
				c.cap.runtime.log("lifecycle.consumer", err)
				return
			}
			notification := plugin.LifecycleNotification{Pending: pending, Work: c.work(snapshot)}
			if observe != nil {
				var session plugin.PrivateSessionSnapshot
				ok, e := snapshot.Get(privateSessionKey(observe.Owner, observe.SessionKey), &session)
				if e == nil && ok && session.Ref.SessionID == observe.SessionID {
					notification.Observation = &session.Record.Observation
				}
			}
			raw, _ := json.Marshal(notification)
			lifecycleRevision = snapshot.LifecycleRevision()
			sessionHash = observedHash
			initialized = true
			if string(previous) == string(raw) {
				return
			}
			previous = raw
			safeLifecycleCallback(func() { listener(notification) }, c.cap.runtime.log)
		}
		publish()
		for {
			select {
			case <-lifetime.Done():
				return
			case _, ok := <-changes:
				if !ok {
					return
				}
				publish()
			}
		}
	}()
	return stop, nil
}
func safeLifecycleCallback(callback func(), log func(string, error)) {
	defer func() {
		if reason := recover(); reason != nil {
			log("lifecycle.listener", fmt.Errorf("listener panic: %v", reason))
		}
	}()
	callback()
}
func publicEvent(e store.Event) plugin.LifecycleEvent {
	return plugin.LifecycleEvent{ID: e.ID, CreatedAt: e.CreatedAt, Type: e.Type, Subject: plugin.LifecycleSubject{Kind: e.Subject.Kind, ID: e.Subject.ID, TypeID: e.Subject.TypeID}, Scope: e.Scope, Source: e.Source, Data: model.CloneRaw(e.Data), IntroducedInteractionIDs: append([]string{}, e.IntroducedInteractionIDs...)}
}
func publicWork(w store.Work) *plugin.LifecycleWork {
	return &plugin.LifecycleWork{ID: w.ID, EventIDs: append([]string{}, w.EventIDs...), Attempts: int(w.Attempts), NextAttemptAt: w.NextAttemptAt, ExecutionID: w.ExecutionID, Receipts: w.Receipts}
}
func storeFilters(scope plugin.LifecycleScope) []store.Filter {
	result := make([]store.Filter, 0, len(scope))
	for _, f := range scope {
		result = append(result, store.Filter{Sources: f.Sources, ExcludeSources: f.ExcludeSources, Types: f.Types, ExcludeTypes: f.ExcludeTypes, SubjectKinds: f.SubjectKinds, SubjectTypeIDs: f.SubjectTypeIDs, ExcludeSubjectTypeIDs: f.ExcludeSubjectTypeIDs, SubjectIDs: f.SubjectIDs, Scope: f.Scope})
	}
	return result
}

func cloneLifecycleScope(scope plugin.LifecycleScope) plugin.LifecycleScope {
	if scope == nil {
		return nil
	}
	copy := make(plugin.LifecycleScope, len(scope))
	for i, f := range scope {
		copy[i] = plugin.LifecycleFilter{Sources: cloneStrings(f.Sources), ExcludeSources: cloneStrings(f.ExcludeSources), Types: cloneStrings(f.Types), ExcludeTypes: cloneStrings(f.ExcludeTypes), SubjectKinds: cloneStrings(f.SubjectKinds), SubjectTypeIDs: cloneStrings(f.SubjectTypeIDs), ExcludeSubjectTypeIDs: cloneStrings(f.ExcludeSubjectTypeIDs), SubjectIDs: cloneStrings(f.SubjectIDs), Scope: f.Scope}
	}
	return copy
}
func cloneStrings(values []string) []string {
	if values == nil {
		return nil
	}
	return append([]string{}, values...)
}
