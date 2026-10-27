package store

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"slices"
	"sort"
	"strings"
)

const (
	eventPrefix   = "event:"
	workPrefix    = "lifecycle-work:"
	outcomePrefix = "lifecycle-outcome:"
)

type Subject struct {
	Kind   string `json:"kind"`
	ID     string `json:"id"`
	TypeID string `json:"typeId"`
}
type Event struct {
	ID                       string          `json:"id"`
	CreatedAt                int64           `json:"createdAt"`
	Type                     string          `json:"type"`
	Subject                  Subject         `json:"subject"`
	Scope                    string          `json:"scope,omitempty"`
	Source                   string          `json:"source"`
	Data                     json.RawMessage `json:"data"`
	IntroducedInteractionIDs []string        `json:"introducedInteractionIds,omitempty"`
}
type Work struct {
	ID            string                     `json:"id"`
	EventIDs      []string                   `json:"eventIds"`
	Attempts      int64                      `json:"attempts"`
	NextAttemptAt int64                      `json:"nextAttemptAt"`
	ExecutionID   string                     `json:"executionId,omitempty"`
	Receipts      map[string]json.RawMessage `json:"receipts"`
}
type Receipt struct {
	ConsumerID string `json:"consumerId"`
	BatchID    string `json:"batchId"`
	Key        string `json:"key"`
}
type Outcome string

const (
	Processed Outcome = "processed"
	Failed    Outcome = "failed"
)

type Filter struct {
	Sources               []string
	ExcludeSources        []string
	Types                 []string
	ExcludeTypes          []string
	SubjectKinds          []string
	SubjectTypeIDs        []string
	ExcludeSubjectTypeIDs []string
	SubjectIDs            []string
	// Scope restricts matching to events tagged with the same tag scope. Empty
	// means no scope restriction.
	Scope string
}
type PendingQuery struct {
	Filters      []Filter // OR across filters; empty means every event
	ExcludeIDs   []string
	ExcludeTypes []string
	Limit        int // zero means unlimited
}
type HistoryEntry struct {
	Event
	Outcomes map[string]Outcome `json:"outcomes"`
}

var consumerIDPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`)
var eventTypes = []string{"entity.created", "entity.updated", "entity.deleted", "thread.input-accepted", "thread.inventory", "thread.archived", "thread.restored", "thread.classification-changed", "execution.running", "execution.waiting-for-user", "execution.completed", "execution.failed", "execution.interrupted", "background.started", "background.finished", "settings.changed"}

func validIdentifier(id string) bool {
	return len(id) > 0 && len(id) <= 128 && !strings.ContainsRune(id, 0)
}
func validConsumerID(id string) bool { return consumerIDPattern.MatchString(id) }
func validTimestamp(v int64) bool    { return v >= 0 && v <= 9007199254740991 }

func validateEvent(event Event) error {
	if !validIdentifier(event.ID) || !validTimestamp(event.CreatedAt) || !slices.Contains(eventTypes, event.Type) ||
		!slices.Contains([]string{"thread", "session", "settings", "state"}, event.Subject.Kind) || !validIdentifier(event.Subject.ID) ||
		!validConsumerID(event.Subject.TypeID) || !validConsumerID(event.Source) || !json.Valid(event.Data) {
		return errors.New("invalid lifecycle event")
	}
	if len(event.IntroducedInteractionIDs) > 0 && event.Type != "execution.waiting-for-user" {
		return errors.New("interaction IDs require a waiting-for-user event")
	}
	seen := map[string]bool{}
	for _, id := range event.IntroducedInteractionIDs {
		if !validIdentifier(id) || seen[id] {
			return errors.New("invalid introduced interaction IDs")
		}
		seen[id] = true
	}
	return nil
}

// AppendEvent is append-only. The same event ID cannot be used for a different
// fact. Call it in the same Update as the business state which produced it.
func (t *Tx) AppendEvent(event Event) error {
	if err := validateEvent(event); err != nil {
		return err
	}
	key := eventPrefix + event.ID
	if t.Has(key) {
		return fmt.Errorf("lifecycle event already exists: %s", event.ID)
	}
	return t.Put(key, event)
}
func (s Snapshot) Work(consumerID string) (Work, bool, error) {
	var work Work
	if !validConsumerID(consumerID) {
		return work, false, errors.New("invalid lifecycle consumer ID")
	}
	ok, err := s.Get(workPrefix+consumerID, &work)
	return work, ok, err
}
func (t *Tx) Work(consumerID string) (Work, bool, error) {
	if !t.active {
		return Work{}, false, ErrExpired
	}
	var work Work
	if !validConsumerID(consumerID) {
		return work, false, errors.New("invalid lifecycle consumer ID")
	}
	ok, err := t.Get(workPrefix+consumerID, &work)
	return work, ok, err
}

// SetWork creates or updates a fenced consumer batch. expectedBatchID must be
// empty to begin work, or equal the active ID to update it. Updates merge event
// IDs and retain durable receipts; callers cannot replace receipts themselves.
func (t *Tx) SetWork(consumerID, expectedBatchID string, work Work) error {
	if len(work.EventIDs) == 0 {
		return errors.New("lifecycle work requires at least one event")
	}
	current, exists, err := t.Work(consumerID)
	if err != nil {
		return err
	}
	if (!exists && expectedBatchID != "") || (exists && current.ID != expectedBatchID) {
		return fmt.Errorf("lifecycle batch replaced: %s", consumerID)
	}
	if exists && work.ID != current.ID {
		return errors.New("lifecycle batch ID cannot change during update")
	}
	merged := append([]string{}, current.EventIDs...)
	for _, id := range work.EventIDs {
		if !slices.Contains(merged, id) {
			merged = append(merged, id)
		}
	}
	// Validate duplicate IDs in the request rather than silently normalize them.
	seen := map[string]bool{}
	for _, id := range work.EventIDs {
		if seen[id] {
			return errors.New("duplicate lifecycle event ID")
		}
		seen[id] = true
	}
	work.EventIDs = merged
	work.Receipts = current.Receipts
	if work.Receipts == nil {
		work.Receipts = make(map[string]json.RawMessage)
	}
	if err = validateWork(t.Has, consumerID, work); err != nil {
		return err
	}
	return t.Put(workPrefix+consumerID, work)
}

// SettleWork removes the active batch and writes an outcome for every event in
// the same transaction, retaining acknowledgement history after batch cleanup.
func (t *Tx) SettleWork(consumerID, batchID string, outcome Outcome) error {
	work, err := t.requireWork(consumerID, batchID)
	if err != nil {
		return err
	}
	if outcome != Processed && outcome != Failed {
		return errors.New("invalid lifecycle outcome")
	}
	for _, id := range work.EventIDs {
		if err = t.Put(outcomePrefix+consumerID+":"+id, outcome); err != nil {
			return err
		}
	}
	return t.Delete(workPrefix + consumerID)
}
func (t *Tx) requireWork(consumerID, batchID string) (Work, error) {
	if !validIdentifier(batchID) {
		return Work{}, errors.New("invalid lifecycle batch ID")
	}
	work, exists, err := t.Work(consumerID)
	if err != nil {
		return Work{}, err
	}
	if !exists || work.ID != batchID {
		return Work{}, fmt.Errorf("lifecycle batch replaced: %s", consumerID)
	}
	return work, nil
}
func (t *Tx) ReadReceipt(receipt Receipt) (json.RawMessage, bool, error) {
	if !validIdentifier(receipt.Key) {
		return nil, false, errors.New("invalid lifecycle receipt key")
	}
	work, err := t.requireWork(receipt.ConsumerID, receipt.BatchID)
	if err != nil {
		return nil, false, err
	}
	value, exists := work.Receipts[receipt.Key]
	return bytes.Clone(value), exists, nil
}
func (t *Tx) RecordReceipt(receipt Receipt, result any) error {
	_, exists, err := t.ReadReceipt(receipt)
	if err != nil || exists {
		return err
	}
	raw, err := json.Marshal(result)
	if err != nil {
		return fmt.Errorf("encode lifecycle receipt: %w", err)
	}
	work, err := t.requireWork(receipt.ConsumerID, receipt.BatchID)
	if err != nil {
		return err
	}
	work.Receipts[receipt.Key] = raw
	return t.Put(workPrefix+receipt.ConsumerID, work)
}

// ApplyReceipt deduplicates a business operation against the active batch and
// stores its result atomically with its writes. Failed effects do not leave
// changes behind even if their caller handles the returned error.
func (t *Tx) ApplyReceipt(receipt Receipt, effect func(*Tx) (any, error)) (json.RawMessage, error) {
	previous, exists, err := t.ReadReceipt(receipt)
	if err != nil || exists {
		return previous, err
	}
	if effect == nil {
		return nil, errors.New("nil lifecycle effect")
	}
	child := newTx(t.snapshot())
	defer func() { child.active = false }()
	result, err := effect(child)
	if err != nil {
		return nil, err
	}
	if err = child.RecordReceipt(receipt, result); err != nil {
		return nil, err
	}
	for key, value := range child.writes {
		if value == nil {
			err = t.Delete(key)
		} else {
			err = t.PutRaw(key, value.body)
		}
		if err != nil {
			return nil, err
		}
	}
	for kind, ids := range child.orders {
		if err = t.SetOrder(kind, ids); err != nil {
			return nil, err
		}
	}
	raw, _, err := t.ReadReceipt(receipt)
	return raw, err
}

func (s Snapshot) Pending(consumerID string, query PendingQuery) ([]Event, error) {
	if !validConsumerID(consumerID) || query.Limit < 0 {
		return nil, errors.New("invalid lifecycle pending query")
	}
	events, err := s.Events()
	if err != nil {
		return nil, err
	}
	result := []Event{}
	for _, event := range events {
		if s.Has(outcomePrefix+consumerID+":"+event.ID) || slices.Contains(query.ExcludeIDs, event.ID) || slices.Contains(query.ExcludeTypes, event.Type) || !matchesFilters(event, query.Filters) {
			continue
		}
		result = append(result, event)
		if query.Limit > 0 && len(result) >= query.Limit {
			break
		}
	}
	return result, nil
}
func (s Snapshot) Events() ([]Event, error) {
	events := []Event{}
	for _, key := range s.Keys(eventPrefix) {
		var event Event
		if _, err := s.Get(key, &event); err != nil {
			return nil, err
		}
		events = append(events, event)
	}
	sort.Slice(events, func(i, j int) bool {
		if events[i].CreatedAt == events[j].CreatedAt {
			return events[i].ID < events[j].ID
		}
		return events[i].CreatedAt < events[j].CreatedAt
	})
	return events, nil
}
func (s Snapshot) History(filters []Filter, offset, limit int) ([]HistoryEntry, bool, error) {
	if offset < 0 || limit < 1 || limit > 1000 {
		return nil, false, errors.New("invalid lifecycle history page")
	}
	events, err := s.Events()
	if err != nil {
		return nil, false, err
	}
	matched := []Event{}
	for _, event := range events {
		if matchesFilters(event, filters) {
			matched = append(matched, event)
		}
	}
	if offset >= len(matched) {
		return []HistoryEntry{}, false, nil
	}
	end := min(offset+limit, len(matched))
	entries := make([]HistoryEntry, 0, end-offset)
	outcomes := map[string]map[string]Outcome{}
	for _, key := range s.Keys(outcomePrefix) {
		consumer, id, ok := strings.Cut(strings.TrimPrefix(key, outcomePrefix), ":")
		if !ok {
			return nil, false, ErrInvalidState
		}
		var outcome Outcome
		if _, err := s.Get(key, &outcome); err != nil {
			return nil, false, err
		}
		if outcomes[id] == nil {
			outcomes[id] = map[string]Outcome{}
		}
		outcomes[id][consumer] = outcome
	}
	for _, event := range matched[offset:end] {
		values := outcomes[event.ID]
		if values == nil {
			values = map[string]Outcome{}
		}
		entries = append(entries, HistoryEntry{event, values})
	}
	return entries, end < len(matched), nil
}
func matchesFilters(event Event, filters []Filter) bool {
	if len(filters) == 0 {
		return true
	}
	for _, filter := range filters {
		if (filter.Sources == nil || slices.Contains(filter.Sources, event.Source)) && !slices.Contains(filter.ExcludeSources, event.Source) &&
			(filter.Types == nil || slices.Contains(filter.Types, event.Type)) && !slices.Contains(filter.ExcludeTypes, event.Type) &&
			(filter.SubjectKinds == nil || slices.Contains(filter.SubjectKinds, event.Subject.Kind)) &&
			(filter.SubjectTypeIDs == nil || slices.Contains(filter.SubjectTypeIDs, event.Subject.TypeID)) && !slices.Contains(filter.ExcludeSubjectTypeIDs, event.Subject.TypeID) &&
			(filter.SubjectIDs == nil || slices.Contains(filter.SubjectIDs, event.Subject.ID)) &&
			(filter.Scope == "" || filter.Scope == event.Scope) {
			return true
		}
	}
	return false
}

func validateWork(has func(string) bool, consumer string, work Work) error {
	if !validConsumerID(consumer) || !validIdentifier(work.ID) || len(work.EventIDs) == 0 || !validTimestamp(work.Attempts) || !validTimestamp(work.NextAttemptAt) ||
		(work.ExecutionID != "" && !validIdentifier(work.ExecutionID)) || work.Receipts == nil {
		return errors.New("invalid lifecycle work")
	}
	seen := map[string]bool{}
	for _, id := range work.EventIDs {
		if !has(eventPrefix+id) || seen[id] || has(outcomePrefix+consumer+":"+id) {
			return errors.New("lifecycle event unavailable to consumer")
		}
		seen[id] = true
	}
	for key, raw := range work.Receipts {
		if !validIdentifier(key) || !json.Valid(raw) {
			return errors.New("invalid lifecycle receipt")
		}
	}
	return nil
}
func validateLifecycle(snapshot Snapshot) error {
	for _, prefix := range []string{eventPrefix, outcomePrefix, workPrefix} {
		for _, key := range snapshot.Keys(prefix) {
			if err := validateLifecycleRecord(snapshot, key); err != nil {
				return err
			}
		}
	}
	return nil
}

func validateLifecycleRecord(snapshot Snapshot, key string) error {
	switch {
	case strings.HasPrefix(key, eventPrefix):
		var event Event
		if _, err := snapshot.Get(key, &event); err != nil {
			return err
		}
		if key != eventPrefix+event.ID {
			return errors.New("lifecycle event key mismatch")
		}
		if err := validateEvent(event); err != nil {
			return err
		}
	case strings.HasPrefix(key, outcomePrefix):
		consumer, id, ok := strings.Cut(strings.TrimPrefix(key, outcomePrefix), ":")
		if !ok || !validConsumerID(consumer) || !snapshot.Has(eventPrefix+id) {
			return errors.New("invalid lifecycle outcome identity")
		}
		var outcome Outcome
		if _, err := snapshot.Get(key, &outcome); err != nil {
			return err
		}
		if outcome != Processed && outcome != Failed {
			return errors.New("invalid lifecycle outcome")
		}
	case strings.HasPrefix(key, workPrefix):
		var work Work
		if _, err := snapshot.Get(key, &work); err != nil {
			return err
		}
		if err := validateWork(snapshot.Has, strings.TrimPrefix(key, workPrefix), work); err != nil {
			return err
		}
	}
	return nil
}
func validateLifecycleChanges(tx *Tx, next Snapshot) error {
	deletedEvent := false
	for key, value := range tx.writes {
		if strings.HasPrefix(key, eventPrefix) {
			if value != nil && tx.base.Has(key) {
				return errors.New("lifecycle events are immutable")
			}
			deletedEvent = deletedEvent || value == nil
		}
	}
	// The committed baseline is validated at open and on each prior commit.
	// Deleting an event can invalidate unchanged work or outcomes, so retain
	// the full reference check for that uncommon path.
	if deletedEvent {
		return validateLifecycle(next)
	}
	for key, value := range tx.writes {
		if value != nil {
			if err := validateLifecycleRecord(next, key); err != nil {
				return err
			}
			if strings.HasPrefix(key, outcomePrefix) {
				// An acknowledgement can also invalidate an unchanged active
				// batch for this consumer. Settlement removes that batch in
				// the same transaction, so inspect the final staged view.
				consumer, _, _ := strings.Cut(strings.TrimPrefix(key, outcomePrefix), ":")
				workKey := workPrefix + consumer
				if next.Has(workKey) {
					if err := validateLifecycleRecord(next, workKey); err != nil {
						return err
					}
				}
			}
		}
	}
	return nil
}
