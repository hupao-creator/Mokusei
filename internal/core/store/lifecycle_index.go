package store

import (
	"bytes"
	"encoding/json"
	"fmt"
	"slices"
	"strings"
	"sync"
)

type indexedEvent struct {
	event Event
	key   string
}

type indexedWork struct {
	EventIDs []string `json:"eventIds"`
}

type lifecycleIndex struct {
	events     *indexNode[*indexedEvent]
	selections *indexNode[*indexNode[*indexedEvent]]
	outcomes   *indexNode[*indexNode[Outcome]]
	work       *indexNode[*indexedWork]
	workEvents *indexNode[*indexNode[*indexedWork]]
	err        error
}

// Every fact enters the eight combinations of scope, type and source. Scoped
// readers and subscription routes can select their own stream before touching
// event bodies. The indexes retain pointers to one immutable decoded fact.
func eventSelectionKeys(event Event) []string {
	keys := make([]string, 0, 8)
	for _, scope := range []string{"", "s" + event.Scope} {
		for _, kind := range []string{"", event.Type} {
			for _, source := range []string{"", event.Source} {
				keys = append(keys, selectionKey(scope, kind, source))
			}
		}
	}
	return keys
}

func selectionKey(scope, kind, source string) string {
	// Scope is an opaque string; length-prefixing avoids delimiter collisions.
	return fmt.Sprintf("%d:%s%s:%s", len(scope), scope, kind, source)
}

func filterSelectionKeys(filters []Filter) []string {
	if len(filters) == 0 {
		return []string{selectionKey("", "", "")}
	}
	keys := []string{}
	seen := map[string]bool{}
	for _, filter := range filters {
		scope := ""
		if filter.Scope != "" {
			scope = "s" + filter.Scope
		}
		types, sources := filter.Types, filter.Sources
		if types == nil {
			types = []string{""}
		}
		if sources == nil {
			sources = []string{""}
		}
		for _, kind := range types {
			for _, source := range sources {
				key := selectionKey(scope, kind, source)
				if !seen[key] {
					keys = append(keys, key)
					seen[key] = true
				}
			}
		}
	}
	return keys
}

func (index *lifecycleIndex) update(key string, current *storedRecord) {
	switch {
	case strings.HasPrefix(key, eventPrefix):
		id := strings.TrimPrefix(key, eventPrefix)
		if old, ok := indexGet(index.events, id); ok {
			for _, selection := range eventSelectionKeys(old.event) {
				root, _ := indexGet(index.selections, selection)
				root = indexDelete(root, old.key)
				if root == nil {
					index.selections = indexDelete(index.selections, selection)
				} else {
					index.selections = indexSet(index.selections, selection, root)
				}
			}
			index.events = indexDelete(index.events, id)
		}
		if current == nil {
			return
		}
		var event Event
		if err := json.Unmarshal(current.body, &event); err != nil {
			index.err = err
			return
		}
		entry := &indexedEvent{event: event, key: fmt.Sprintf("%016d:%s", event.CreatedAt, event.ID)}
		index.events = indexSet(index.events, id, entry)
		for _, selection := range eventSelectionKeys(event) {
			root, _ := indexGet(index.selections, selection)
			index.selections = indexSet(index.selections, selection, indexSet(root, entry.key, entry))
		}
	case strings.HasPrefix(key, outcomePrefix):
		consumer, id, ok := strings.Cut(strings.TrimPrefix(key, outcomePrefix), ":")
		if !ok {
			index.err = ErrInvalidState
			return
		}
		root, _ := indexGet(index.outcomes, id)
		if current == nil {
			root = indexDelete(root, consumer)
		} else {
			var outcome Outcome
			if err := json.Unmarshal(current.body, &outcome); err != nil {
				index.err = err
				return
			}
			root = indexSet(root, consumer, outcome)
		}
		if root == nil {
			index.outcomes = indexDelete(index.outcomes, id)
		} else {
			index.outcomes = indexSet(index.outcomes, id, root)
		}
	case strings.HasPrefix(key, workPrefix):
		consumer := strings.TrimPrefix(key, workPrefix)
		if previous, ok := indexGet(index.work, consumer); ok {
			for _, id := range previous.EventIDs {
				root, _ := indexGet(index.workEvents, id)
				root = indexDelete(root, consumer)
				if root == nil {
					index.workEvents = indexDelete(index.workEvents, id)
				} else {
					index.workEvents = indexSet(index.workEvents, id, root)
				}
			}
			index.work = indexDelete(index.work, consumer)
		}
		if current == nil {
			return
		}
		var work indexedWork
		if err := json.Unmarshal(current.body, &work); err != nil {
			index.err = err
			return
		}
		index.work = indexSet(index.work, consumer, &work)
		for _, id := range work.EventIDs {
			root, _ := indexGet(index.workEvents, id)
			index.workEvents = indexSet(index.workEvents, id, indexSet(root, consumer, &work))
		}
	}
}

func copyEvent(event Event) Event {
	event.Data = bytes.Clone(event.Data)
	event.IntroducedInteractionIDs = slices.Clone(event.IntroducedInteractionIDs)
	return event
}

type eventCursor struct{ stack []*indexNode[*indexedEvent] }

func (cursor *eventCursor) next() *indexedEvent {
	for len(cursor.stack) > 0 {
		last := len(cursor.stack) - 1
		node := cursor.stack[last]
		cursor.stack = cursor.stack[:last]
		for i := len(node.children) - 1; i >= 0; i-- {
			cursor.stack = append(cursor.stack, node.children[i])
		}
		if node.value != nil {
			return node.value
		}
	}
	return nil
}

// visitEvents merges only the selected ordered streams and stops as soon as a
// caller has its page. Overlapping OR filters emit each fact once.
func (s Snapshot) visitEvents(filters []Filter, ids []string, visit func(*indexedEvent) bool) error {
	if s.data == nil {
		return nil
	}
	if s.data.lifecycle.err != nil {
		return s.data.lifecycle.err
	}
	if ids != nil {
		entries := make([]*indexedEvent, 0, len(ids))
		seen := map[string]bool{}
		for _, id := range ids {
			entry, ok := indexGet(s.data.lifecycle.events, id)
			if ok && !seen[id] && matchesFilters(entry.event, filters) {
				entries = append(entries, entry)
				seen[id] = true
			}
		}
		slices.SortFunc(entries, func(a, b *indexedEvent) int { return strings.Compare(a.key, b.key) })
		for _, entry := range entries {
			if !visit(entry) {
				break
			}
		}
		return nil
	}
	cursors := []eventCursor{}
	heads := []*indexedEvent{}
	for _, key := range filterSelectionKeys(filters) {
		if root, ok := indexGet(s.data.lifecycle.selections, key); ok {
			cursor := eventCursor{stack: []*indexNode[*indexedEvent]{root}}
			heads = append(heads, cursor.next())
			cursors = append(cursors, cursor)
		}
	}
	previous := ""
	for {
		selected := -1
		for i, head := range heads {
			if head != nil && (selected < 0 || head.key < heads[selected].key) {
				selected = i
			}
		}
		if selected < 0 {
			return nil
		}
		entry := heads[selected]
		heads[selected] = cursors[selected].next()
		if entry.key == previous {
			continue
		}
		previous = entry.key
		if matchesFilters(entry.event, filters) && !visit(entry) {
			return nil
		}
	}
}

func (s Snapshot) EventIDs(filters []Filter) ([]string, error) {
	ids := []string{}
	err := s.visitEvents(filters, nil, func(entry *indexedEvent) bool {
		ids = append(ids, entry.event.ID)
		return true
	})
	return ids, err
}

// NewEvents returns matching facts added since an immutable baseline. Event
// identity is append-only; removals and a coalesced remove/reinsert of the same
// identity do not manufacture a new fact for a live subscription.
func (s Snapshot) NewEvents(previous Snapshot, filters []Filter) ([]Event, error) {
	if s.data == nil {
		return []Event{}, nil
	}
	if s.data.lifecycle.err != nil {
		return nil, s.data.lifecycle.err
	}
	added := map[string]*indexedEvent{}
	for _, key := range filterSelectionKeys(filters) {
		var before *indexNode[*indexedEvent]
		if previous.data != nil {
			before, _ = indexGet(previous.data.lifecycle.selections, key)
		}
		after, _ := indexGet(s.data.lifecycle.selections, key)
		indexDiff(before, after, func(_ string, _, current *indexedEvent) bool {
			if current != nil && !previous.Has(eventPrefix+current.event.ID) && matchesFilters(current.event, filters) {
				added[current.event.ID] = current
			}
			return true
		})
	}
	entries := make([]*indexedEvent, 0, len(added))
	for _, entry := range added {
		entries = append(entries, entry)
	}
	slices.SortFunc(entries, func(a, b *indexedEvent) int { return strings.Compare(a.key, b.key) })
	events := make([]Event, 0, len(entries))
	for _, entry := range entries {
		events = append(events, copyEvent(entry.event))
	}
	return events, nil
}

// EventReader follows a live selection without retaining the complete baseline
// snapshot. Idle scoped readers keep only their selected event branches and
// seen identities, never old unrelated thread/session bodies.
type EventReader struct {
	mu      sync.Mutex
	filters []Filter
	keys    []string
	streams []*indexNode[*indexedEvent]
	seen    map[string]bool
}

func NewEventReader(snapshot Snapshot, filters []Filter) (*EventReader, error) {
	ids, err := snapshot.EventIDs(filters)
	if err != nil {
		return nil, err
	}
	reader := &EventReader{filters: cloneFilters(filters), keys: filterSelectionKeys(filters), seen: map[string]bool{}}
	reader.streams = make([]*indexNode[*indexedEvent], len(reader.keys))
	for _, id := range ids {
		reader.seen[id] = true
	}
	if snapshot.data != nil {
		for i, key := range reader.keys {
			reader.streams[i], _ = indexGet(snapshot.data.lifecycle.selections, key)
		}
	}
	return reader, nil
}

func (reader *EventReader) Read(snapshot Snapshot) ([]Event, error) {
	reader.mu.Lock()
	defer reader.mu.Unlock()
	if snapshot.data != nil && snapshot.data.lifecycle.err != nil {
		return nil, snapshot.data.lifecycle.err
	}
	added := []*indexedEvent{}
	for i, key := range reader.keys {
		var current *indexNode[*indexedEvent]
		if snapshot.data != nil {
			current, _ = indexGet(snapshot.data.lifecycle.selections, key)
		}
		indexDiff(reader.streams[i], current, func(_ string, _, entry *indexedEvent) bool {
			if entry != nil && !reader.seen[entry.event.ID] && matchesFilters(entry.event, reader.filters) {
				reader.seen[entry.event.ID] = true
				added = append(added, entry)
			}
			return true
		})
		reader.streams[i] = current
	}
	slices.SortFunc(added, func(a, b *indexedEvent) int { return strings.Compare(a.key, b.key) })
	events := make([]Event, 0, len(added))
	for _, entry := range added {
		events = append(events, copyEvent(entry.event))
	}
	return events, nil
}

// PendingReader retains one consumer's unacknowledged selection. Subsequent
// reads reconcile structural changes in its selected streams and own outcomes,
// so acknowledged history and other scopes do not become recurring work.
// Only selected event/outcome branches are retained between reads.
// It is safe to use concurrently and against older immutable snapshots.
type PendingReader struct {
	mu          sync.Mutex
	consumer    string
	filters     []Filter
	keys        []string
	excluded    map[string]bool
	streams     []*indexNode[*indexedEvent]
	outcomes    *indexNode[*storedRecord]
	pending     *indexNode[*indexedEvent]
	pendingByID *indexNode[*indexedEvent]
}

func NewPendingReader(consumer string, filters []Filter, excludedIDs []string) *PendingReader {
	reader := &PendingReader{consumer: consumer, filters: cloneFilters(filters), keys: filterSelectionKeys(filters), excluded: map[string]bool{}}
	reader.streams = make([]*indexNode[*indexedEvent], len(reader.keys))
	for _, id := range excludedIDs {
		reader.excluded[id] = true
	}
	return reader
}

func cloneFilters(filters []Filter) []Filter {
	result := slices.Clone(filters)
	for i := range result {
		result[i].Sources = slices.Clone(result[i].Sources)
		result[i].ExcludeSources = slices.Clone(result[i].ExcludeSources)
		result[i].Types = slices.Clone(result[i].Types)
		result[i].ExcludeTypes = slices.Clone(result[i].ExcludeTypes)
		result[i].SubjectKinds = slices.Clone(result[i].SubjectKinds)
		result[i].SubjectTypeIDs = slices.Clone(result[i].SubjectTypeIDs)
		result[i].ExcludeSubjectTypeIDs = slices.Clone(result[i].ExcludeSubjectTypeIDs)
		result[i].SubjectIDs = slices.Clone(result[i].SubjectIDs)
	}
	return result
}

func (reader *PendingReader) Read(snapshot Snapshot, query PendingQuery) ([]Event, error) {
	reader.mu.Lock()
	defer reader.mu.Unlock()
	if !validConsumerID(reader.consumer) || query.Limit < 0 {
		return nil, fmt.Errorf("invalid lifecycle pending query")
	}
	if snapshot.data != nil && snapshot.data.lifecycle.err != nil {
		return nil, snapshot.data.lifecycle.err
	}
	changed := map[string]bool{}
	for i, key := range reader.keys {
		before := reader.streams[i]
		var after *indexNode[*indexedEvent]
		if snapshot.data != nil {
			after, _ = indexGet(snapshot.data.lifecycle.selections, key)
		}
		indexDiff(before, after, func(_ string, old, current *indexedEvent) bool {
			if old != nil {
				changed[old.event.ID] = true
			}
			if current != nil {
				changed[current.event.ID] = true
			}
			return true
		})
		reader.streams[i] = after
	}
	prefix := outcomePrefix + reader.consumer + ":"
	var outcomes *indexNode[*storedRecord]
	if snapshot.data != nil {
		outcomes = indexPrefix(snapshot.data.records, prefix)
	}
	indexDiff(reader.outcomes, outcomes, func(key string, _, _ *storedRecord) bool {
		changed[strings.TrimPrefix(key, prefix)] = true
		return true
	})
	reader.outcomes = outcomes
	for id := range changed {
		if old, ok := indexGet(reader.pendingByID, id); ok {
			reader.pending = indexDelete(reader.pending, old.key)
			reader.pendingByID = indexDelete(reader.pendingByID, id)
		}
		if snapshot.data != nil && !reader.excluded[id] && !snapshot.Has(prefix+id) {
			if entry, ok := indexGet(snapshot.data.lifecycle.events, id); ok && matchesFilters(entry.event, reader.filters) {
				reader.pending = indexSet(reader.pending, entry.key, entry)
				reader.pendingByID = indexSet(reader.pendingByID, id, entry)
			}
		}
	}
	result := []Event{}
	indexWalk(reader.pending, func(_ string, entry *indexedEvent) bool {
		if !slices.Contains(query.ExcludeIDs, entry.event.ID) && !slices.Contains(query.ExcludeTypes, entry.event.Type) && matchesFilters(entry.event, query.Filters) && (query.EventIDs == nil || slices.Contains(query.EventIDs, entry.event.ID)) {
			result = append(result, copyEvent(entry.event))
		}
		return query.Limit == 0 || len(result) < query.Limit
	})
	return result, nil
}
