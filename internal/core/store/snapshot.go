package store

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"strings"
	"unicode/utf8"
)

type snapshotData struct {
	revision          uint64
	eventRevision     uint64
	lifecycleRevision uint64
	records           *indexNode[*storedRecord]
	orders            *indexNode[*storedOrder]
	lifecycle         lifecycleIndex
}

type storedOrder struct{ ids []string }

type storedRecord struct {
	body json.RawMessage
	hash string
}

func newStoredRecord(body json.RawMessage) *storedRecord {
	sum := sha256.Sum256(body)
	return &storedRecord{body: bytes.Clone(body), hash: hex.EncodeToString(sum[:])}
}

// RecordHash identifies the exact immutable record bytes without copying or
// hashing the history on every read. Missing records have no hash.
func (s Snapshot) RecordHash(key string) (string, bool) {
	if s.data == nil {
		return "", false
	}
	record, ok := indexGet(s.data.records, key)
	if !ok {
		return "", false
	}
	return record.hash, true
}

// RecordBytes is the immutable source size used for bounded compute admission.
func (s Snapshot) RecordBytes(key string) int64 {
	if s.data == nil {
		return 0
	}
	record, _ := indexGet(s.data.records, key)
	if record == nil {
		return 0
	}
	return int64(len(record.body))
}

// Snapshot is an immutable committed view. All returned slices are copies;
// decoding allocates values owned by the caller. Old snapshots remain valid.
type Snapshot struct{ data *snapshotData }

func (s Snapshot) Revision() uint64 {
	if s.data == nil {
		return 0
	}
	return s.data.revision
}

// EventRevision and LifecycleRevision are change markers within one open Store,
// not durable cursors. Reopening initializes both to the persisted revision.
// Work and outcomes change only LifecycleRevision; events change both markers.
func (s Snapshot) EventRevision() uint64 {
	if s.data == nil {
		return 0
	}
	return s.data.eventRevision
}
func (s Snapshot) LifecycleRevision() uint64 {
	if s.data == nil {
		return 0
	}
	return s.data.lifecycleRevision
}
func (s Snapshot) Get(key string, dst any) (bool, error) {
	if s.data == nil {
		return false, nil
	}
	value, ok := indexGet(s.data.records, key)
	if !ok {
		return false, nil
	}
	// A custom UnmarshalJSON implementation may retain or mutate its input.
	// Never hand it the backing bytes of an immutable snapshot.
	if err := json.Unmarshal(bytes.Clone(value.body), dst); err != nil {
		return true, fmt.Errorf("decode state %q: %w", key, err)
	}
	return true, nil
}
func (s Snapshot) Raw(key string) (json.RawMessage, bool) {
	if s.data == nil {
		return nil, false
	}
	value, ok := indexGet(s.data.records, key)
	if !ok {
		return nil, false
	}
	return bytes.Clone(value.body), true
}
func (s Snapshot) Has(key string) bool {
	if s.data == nil {
		return false
	}
	_, ok := indexGet(s.data.records, key)
	return ok
}
func (s Snapshot) Keys(prefix string) []string {
	keys := []string{}
	if s.data != nil {
		indexWalk(indexPrefix(s.data.records, prefix), func(key string, _ *storedRecord) bool {
			keys = append(keys, key)
			return true
		})
	}
	return keys
}

// Count returns the size of a prefix range without enumerating its records.
func (s Snapshot) Count(prefix string) int {
	if s.data != nil {
		if root := indexPrefix(s.data.records, prefix); root != nil {
			return root.count
		}
	}
	return 0
}

func (s Snapshot) Order(kind string) []string {
	if s.data != nil {
		if order, ok := indexGet(s.data.orders, kind); ok {
			return append([]string{}, order.ids...)
		}
	}
	return []string{}
}

// ChangedKeys returns exact byte changes, additions and removals in key order.
// Shared index branches are skipped, including across coalesced commits. A zero
// previous snapshot reports all current keys; no revision journal can expire.
func (s Snapshot) ChangedKeys(previous Snapshot, prefix string) []string {
	return s.RecordPrefix(prefix).ChangedKeys(previous.RecordPrefix(prefix))
}

// RecordSnapshot is an opaque change baseline for one record range. It retains
// only that index subtree, so an idle collection cache does not pin unrelated
// old thread or private-session bodies through a complete Snapshot.
type RecordSnapshot struct{ records *indexNode[*storedRecord] }

func (s Snapshot) RecordPrefix(prefix string) RecordSnapshot {
	if s.data == nil {
		return RecordSnapshot{}
	}
	return RecordSnapshot{records: indexPrefix(s.data.records, prefix)}
}

func (s RecordSnapshot) ChangedKeys(previous RecordSnapshot) []string {
	keys := []string{}
	s.changedRecords(previous, func(key string, _, _ *storedRecord) bool {
		keys = append(keys, key)
		return true
	})
	return keys
}

// PrefixEqual checks a collection without materializing its keys or values.
func (s Snapshot) PrefixEqual(previous Snapshot, prefix string) bool {
	return s.RecordPrefix(prefix).changedRecords(previous.RecordPrefix(prefix), func(string, *storedRecord, *storedRecord) bool { return false })
}

func (s RecordSnapshot) changedRecords(previous RecordSnapshot, visit func(string, *storedRecord, *storedRecord) bool) bool {
	return indexDiff(previous.records, s.records, func(key string, old, current *storedRecord) bool {
		if old != nil && current != nil && old.hash == current.hash {
			return true
		}
		return visit(key, old, current)
	})
}

func (s Snapshot) OrderChanged(previous Snapshot, kind string) bool {
	var before, after *storedOrder
	if previous.data != nil {
		before, _ = indexGet(previous.data.orders, kind)
	}
	if s.data != nil {
		after, _ = indexGet(s.data.orders, kind)
	}
	if before == after {
		return false
	}
	if before == nil || after == nil {
		return true
	}
	return !slices.Equal(before.ids, after.ids)
}

// Tx is valid only for the synchronous duration of its Update callback. Do not
// retain it or use it from another goroutine. All writes are owned JSON copies.
type Tx struct {
	base   Snapshot
	writes map[string]*storedRecord // nil means delete (JSON null is nonnil)
	orders map[string][]string
	active bool
}

func newTx(base Snapshot) *Tx {
	return &Tx{base: base, writes: make(map[string]*storedRecord), orders: make(map[string][]string), active: true}
}
func (t *Tx) Revision() uint64 { return t.base.Revision() }
func (t *Tx) Get(key string, dst any) (bool, error) {
	if !t.active {
		return false, ErrExpired
	}
	if raw, ok := t.writes[key]; ok {
		if raw == nil {
			return false, nil
		}
		return true, json.Unmarshal(bytes.Clone(raw.body), dst)
	}
	return t.base.Get(key, dst)
}
func (t *Tx) Raw(key string) (json.RawMessage, bool) {
	if !t.active {
		return nil, false
	}
	if raw, ok := t.writes[key]; ok {
		if raw == nil {
			return nil, false
		}
		return bytes.Clone(raw.body), true
	}
	return t.base.Raw(key)
}
func (t *Tx) RecordHash(key string) (string, bool) {
	if !t.active {
		return "", false
	}
	if record, ok := t.writes[key]; ok {
		if record == nil {
			return "", false
		}
		return record.hash, true
	}
	return t.base.RecordHash(key)
}
func (t *Tx) Has(key string) bool         { _, ok := t.RecordHash(key); return ok }
func (t *Tx) Keys(prefix string) []string { return t.Snapshot().Keys(prefix) }
func (t *Tx) Order(kind string) []string {
	if !t.active {
		return nil
	}
	if ids, ok := t.orders[kind]; ok {
		return append([]string{}, ids...)
	}
	return t.base.Order(kind)
}
func (t *Tx) Put(key string, value any) error {
	if !t.active {
		return ErrExpired
	}
	raw, err := json.Marshal(value)
	if err != nil {
		return fmt.Errorf("encode state %q: %w", key, err)
	}
	return t.PutRaw(key, raw)
}
func (t *Tx) PutRaw(key string, value json.RawMessage) error {
	if !t.active {
		return ErrExpired
	}
	if err := validKey(key); err != nil {
		return err
	}
	if len(value) > MaxRecordBytes {
		return fmt.Errorf("%w: %s", ErrRecordTooLarge, key)
	}
	if !utf8.Valid(value) || !json.Valid(value) {
		return fmt.Errorf("state %q is not UTF-8 JSON", key)
	}
	if old, ok := indexGet(t.base.data.records, key); ok && bytes.Equal(old.body, value) {
		delete(t.writes, key)
		return nil
	}
	t.writes[key] = newStoredRecord(value)
	return nil
}
func (t *Tx) Delete(key string) error {
	if !t.active {
		return ErrExpired
	}
	if err := validKey(key); err != nil {
		return err
	}
	if t.base.Has(key) {
		t.writes[key] = nil
	} else {
		delete(t.writes, key)
	}
	return nil
}
func (t *Tx) SetOrder(kind string, ids []string) error {
	if !t.active {
		return ErrExpired
	}
	if err := validKey(kind); err != nil {
		return err
	}
	seen := make(map[string]bool, len(ids))
	for _, id := range ids {
		if err := validKey(id); err != nil {
			return err
		}
		if seen[id] {
			return fmt.Errorf("duplicate %s order ID %q", kind, id)
		}
		seen[id] = true
	}
	if slices.Equal(ids, t.base.Order(kind)) {
		delete(t.orders, kind)
		return nil
	}
	t.orders[kind] = append([]string{}, ids...)
	return nil
}

// Snapshot copies changed index paths; later writes cannot change that view.
func (t *Tx) Snapshot() Snapshot {
	if !t.active {
		return Snapshot{}
	}
	return t.snapshot()
}
func (t *Tx) snapshot() Snapshot {
	data := &snapshotData{}
	if t.base.data != nil {
		*data = *t.base.data
	}
	for key, value := range t.writes {
		if strings.HasPrefix(key, eventPrefix) {
			data.eventRevision = data.revision + 1
			data.lifecycleRevision = data.revision + 1
		} else if strings.HasPrefix(key, workPrefix) || strings.HasPrefix(key, outcomePrefix) {
			data.lifecycleRevision = data.revision + 1
		}
		data.lifecycle.update(key, value)
		if value == nil {
			data.records = indexDelete(data.records, key)
		} else {
			data.records = indexSet(data.records, key, value)
		}
	}
	for kind, ids := range t.orders {
		if len(ids) == 0 {
			data.orders = indexDelete(data.orders, kind)
		} else {
			data.orders = indexSet(data.orders, kind, &storedOrder{ids: ids})
		}
	}
	return Snapshot{data}
}
func (t *Tx) changed() bool { return len(t.writes) > 0 || len(t.orders) > 0 }
func validKey(key string) error {
	if len(key) == 0 || len(key) > 1024 || strings.ContainsRune(key, 0) || !utf8.ValidString(key) {
		return errors.New("invalid state record key or order identity")
	}
	return nil
}
