package store

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"sort"
	"strings"
	"unicode/utf8"
)

type snapshotData struct {
	revision          uint64
	eventRevision     uint64
	lifecycleRevision uint64
	records           map[string]*storedRecord
	orders            map[string][]string
}

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
	record, ok := s.data.records[key]
	if !ok {
		return "", false
	}
	return record.hash, true
}

// RecordBytes is the immutable source size used for bounded compute admission.
func (s Snapshot) RecordBytes(key string) int64 {
	if s.data == nil || s.data.records[key] == nil {
		return 0
	}
	return int64(len(s.data.records[key].body))
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
	value, ok := s.data.records[key]
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
	value, ok := s.data.records[key]
	if !ok {
		return nil, false
	}
	return bytes.Clone(value.body), true
}
func (s Snapshot) Has(key string) bool {
	if s.data == nil {
		return false
	}
	_, ok := s.data.records[key]
	return ok
}
func (s Snapshot) Keys(prefix string) []string {
	keys := []string{}
	if s.data != nil {
		for key := range s.data.records {
			if strings.HasPrefix(key, prefix) {
				keys = append(keys, key)
			}
		}
	}
	sort.Strings(keys)
	return keys
}
func (s Snapshot) Order(kind string) []string {
	if s.data == nil {
		return []string{}
	}
	return append([]string{}, s.data.orders[kind]...)
}
func (s Snapshot) OrderKinds() []string {
	kinds := []string{}
	if s.data != nil {
		for kind := range s.data.orders {
			kinds = append(kinds, kind)
		}
	}
	sort.Strings(kinds)
	return kinds
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
	if old, ok := t.base.data.records[key]; ok && bytes.Equal(old.body, value) {
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

// Snapshot copies the transaction's maps; later writes cannot change that view.
func (t *Tx) Snapshot() Snapshot {
	if !t.active {
		return Snapshot{}
	}
	return t.snapshot()
}
func (t *Tx) snapshot() Snapshot {
	data := &snapshotData{revision: t.base.Revision(), eventRevision: t.base.EventRevision(), lifecycleRevision: t.base.LifecycleRevision(), records: make(map[string]*storedRecord, len(t.base.data.records)+len(t.writes)), orders: make(map[string][]string, len(t.base.data.orders)+len(t.orders))}
	for key, value := range t.base.data.records {
		data.records[key] = value
	}
	for key, value := range t.writes {
		if strings.HasPrefix(key, eventPrefix) {
			data.eventRevision = data.revision + 1
			data.lifecycleRevision = data.revision + 1
		} else if strings.HasPrefix(key, workPrefix) || strings.HasPrefix(key, outcomePrefix) {
			data.lifecycleRevision = data.revision + 1
		}
		if value == nil {
			delete(data.records, key)
		} else {
			data.records[key] = value
		}
	}
	for kind, ids := range t.base.data.orders {
		data.orders[kind] = ids
	}
	for kind, ids := range t.orders {
		if len(ids) == 0 {
			delete(data.orders, kind)
		} else {
			data.orders[kind] = ids
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
