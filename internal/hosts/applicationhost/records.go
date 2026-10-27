package applicationhost

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"strings"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/services/threadsearch"
)

type recordReader struct {
	host              *Host
	owner             string
	snapshot          store.Snapshot
	tx                *store.Tx
	issued            map[uint64]plugin.MutationScope
	readKeys          map[string]bool
	allowed           map[string]plugin.MutationScope // nil outside reduce
	readOnly          bool
	changes           map[string]recordChange
	committedAt       int64
	commandID         string
	source            string
	allowSessionWrite bool
}
type recordChange struct {
	collection string
	id         string
	before     *model.VersionedRecord
	after      *model.VersionedRecord
}

func newReader(host *Host, owner string, snapshot store.Snapshot) *recordReader {
	return &recordReader{host: host, owner: owner, snapshot: snapshot, issued: map[uint64]plugin.MutationScope{}, readKeys: map[string]bool{}}
}
func (r *recordReader) current() store.Snapshot {
	if r.tx != nil {
		return r.tx.Snapshot()
	}
	return r.snapshot
}
func (r *recordReader) collection(id string) (plugin.CollectionDefinition, error) {
	d, ok := r.host.collections[id]
	if !ok || d.OwnerPluginID != r.owner {
		return d, fmt.Errorf("collection unavailable: %s", id)
	}
	return d, nil
}
func (r *recordReader) covered(key string) bool {
	if r.allowed == nil {
		return true
	}
	if _, ok := r.allowed[key]; ok {
		return true
	}
	for scope := range r.allowed {
		if strings.HasSuffix(scope, ":") && strings.HasPrefix(key, scope) {
			return true
		}
	}
	return false
}
func (r *recordReader) access(key string) error {
	if !r.covered(key) {
		return fmt.Errorf("unplanned record access: %s", key)
	}
	r.readKeys[key] = true
	return nil
}
func (r *recordReader) IssueScope(key string, revision int64) (plugin.MutationScope, error) {
	if key == "" || revision < 0 {
		return plugin.MutationScope{}, errors.New("invalid mutation scope")
	}
	if err := r.access(key); err != nil {
		return plugin.MutationScope{}, err
	}
	if r.allowed != nil {
		if scope, ok := r.allowed[key]; ok {
			return scope, nil
		}
		for prefix, scope := range r.allowed {
			if strings.HasSuffix(prefix, ":") && strings.HasPrefix(key, prefix) {
				return scope, nil
			}
		}
	}
	scope := plugin.NewMutationScope(key, "", revision)
	r.issued[scope.Token()] = scope
	return scope, nil
}
func (r *recordReader) Get(collection, id string) (*model.VersionedRecord, error) {
	if _, err := r.collection(collection); err != nil {
		return nil, err
	}
	if !validRecordID(id) {
		return nil, errors.New("invalid record ID")
	}
	key := recordKey(collection, id)
	if err := r.access(key); err != nil {
		return nil, err
	}
	var record model.VersionedRecord
	exists, err := r.current().Get(key, &record)
	if err != nil || !exists {
		return nil, err
	}
	return &record, nil
}
func (r *recordReader) List(collection string) ([]model.VersionedRecord, error) {
	if _, err := r.collection(collection); err != nil {
		return nil, err
	}
	if err := r.access(recordKey(collection, "")); err != nil {
		return nil, err
	}
	snap := r.current()
	ids := snap.Order(orderKey(collection))
	seen := make(map[string]bool, len(ids))
	for _, id := range ids {
		seen[id] = true
	}
	for _, key := range snap.Keys(recordKey(collection, "")) {
		id := strings.TrimPrefix(key, recordKey(collection, ""))
		if !seen[id] {
			ids = append(ids, id)
			seen[id] = true
		}
	}
	result := make([]model.VersionedRecord, 0, len(ids))
	for _, id := range ids {
		var record model.VersionedRecord
		ok, err := snap.Get(recordKey(collection, id), &record)
		if err != nil {
			return nil, err
		}
		if ok {
			result = append(result, record)
		}
	}
	return result, nil
}
func (r *recordReader) Scope(collection, id string) (plugin.MutationScope, error) {
	if _, err := r.collection(collection); err != nil {
		return plugin.MutationScope{}, err
	}
	var revision int64
	if id == "" {
		var err error
		revision, err = readCollectionRevision(r.current(), collection)
		if err != nil {
			return plugin.MutationScope{}, err
		}
	} else {
		record, err := r.Get(collection, id)
		if err != nil {
			return plugin.MutationScope{}, err
		}
		if record != nil {
			revision = record.Revision
		}
	}
	return r.IssueScope(recordKey(collection, id), revision)
}
func (r *recordReader) Put(collection, id string, value json.RawMessage, options plugin.RecordWriteOptions) (model.VersionedRecord, error) {
	var result model.VersionedRecord
	if r.tx == nil || r.readOnly {
		return result, errors.New("record writes require a transaction")
	}
	d, err := r.collection(collection)
	if err != nil {
		return result, err
	}
	value, err = d.Contract.Validate(value)
	if err != nil {
		return result, err
	}
	previous, err := r.Get(collection, id)
	if err != nil {
		return result, err
	}
	if options.ExpectedRevision == nil {
		if previous != nil {
			return result, errors.New("record already exists")
		}
	} else if previous == nil || previous.Revision != *options.ExpectedRevision {
		return result, errors.New("record revision conflict")
	}
	if definition, ok := r.host.typeForCollection(collection); ok && definition.Conversation != nil && !r.allowSessionWrite {
		proposed := model.ApplicationThreadRecord{VersionedRecord: model.VersionedRecord{ID: id, Value: value}, Ref: model.ThreadRef{ThreadID: id, TypeID: definition.ID}}
		after, e := definition.Conversation.ReadSession(proposed)
		if e != nil {
			return result, e
		}
		var before *model.SessionRecord
		if previous != nil {
			before, e = definition.Conversation.ReadSession(model.ApplicationThreadRecord{VersionedRecord: *previous, Ref: proposed.Ref})
			if e != nil {
				return result, e
			}
		}
		beforeRaw, e := json.Marshal(before)
		if e != nil {
			return result, e
		}
		afterRaw, e := json.Marshal(after)
		if e != nil {
			return result, e
		}
		if !bytes.Equal(beforeRaw, afterRaw) {
			return result, errors.New("business commands cannot change native conversation state")
		}
	}
	result = model.VersionedRecord{ID: id, Revision: 1, CreatedAt: r.committedAt, UpdatedAt: r.committedAt, Value: value}
	if previous != nil {
		result.Revision = previous.Revision + 1
		result.CreatedAt = previous.CreatedAt
		if !options.TouchUpdatedAt {
			result.UpdatedAt = previous.UpdatedAt
		}
	}
	if result.Revision > model.MaximumSafeInteger {
		return result, errors.New("record revision exhausted")
	}
	if err = r.tx.Put(recordKey(collection, id), result); err != nil {
		return result, err
	}
	if definition, ok := r.host.typeForCollection(collection); ok && definition.Archive != nil && definition.Archive.Archived(model.ApplicationThreadRecord{VersionedRecord: result, Ref: model.ThreadRef{ThreadID: id, TypeID: definition.ID}}) {
		if err = threadsearch.DeleteOwner(r.tx, recordKey(collection, id)); err != nil {
			return result, err
		}
	}
	if previous == nil {
		ids := r.tx.Order(orderKey(collection))
		ids = append(ids, id)
		if err = r.tx.SetOrder(orderKey(collection), ids); err != nil {
			return result, err
		}
	}
	if err = r.bumpCollection(collection); err != nil {
		return result, err
	}
	r.changed(collection, id, previous, &result)
	return result, nil
}
func (r *recordReader) Delete(collection, id string, expectedRevision int64) error {
	if r.tx == nil || r.readOnly {
		return errors.New("record writes require a transaction")
	}
	previous, err := r.Get(collection, id)
	if err != nil {
		return err
	}
	if previous == nil || previous.Revision != expectedRevision {
		return errors.New("record revision conflict")
	}
	if err = threadsearch.DeleteOwner(r.tx, recordKey(collection, id)); err != nil {
		return err
	}
	if err = r.tx.Delete(recordKey(collection, id)); err != nil {
		return err
	}
	ids := r.tx.Order(orderKey(collection))
	ids = slices.DeleteFunc(ids, func(candidate string) bool { return candidate == id })
	if err = r.tx.SetOrder(orderKey(collection), ids); err != nil {
		return err
	}
	if err = r.bumpCollection(collection); err != nil {
		return err
	}
	r.changed(collection, id, previous, nil)
	return nil
}
func (r *recordReader) bumpCollection(collection string) error {
	var revision int64
	_, err := r.tx.Get(collectionKey(collection), &revision)
	if err != nil {
		return err
	}
	if revision >= model.MaximumSafeInteger {
		return errors.New("collection revision exhausted")
	}
	return r.tx.Put(collectionKey(collection), revision+1)
}
func (r *recordReader) changed(collection, id string, before, after *model.VersionedRecord) {
	if r.changes == nil {
		r.changes = map[string]recordChange{}
	}
	key := recordKey(collection, id)
	if prior, exists := r.changes[key]; exists {
		before = prior.before
	}
	r.changes[key] = recordChange{collection: collection, id: id, before: before, after: after}
}
func (r *recordReader) flushEvents() error {
	for _, key := range sortedKeys(r.changes) {
		change := r.changes[key]
		if change.before == nil && change.after == nil {
			continue
		}
		eventType := "entity.updated"
		if change.before == nil {
			eventType = "entity.created"
		}
		if change.after == nil {
			eventType = "entity.deleted"
		}
		typeID := change.collection
		subjectKind := "thread"
		if definition, ok := r.host.typeForCollection(change.collection); ok {
			typeID = definition.ID
		}
		data, err := json.Marshal(model.Object{"collectionId": change.collection, "recordId": change.id})
		if err != nil {
			return err
		}
		event := store.Event{ID: stableID(r.commandID, "event:"+key+":"+eventType), CreatedAt: r.committedAt, Type: eventType, Subject: store.Subject{Kind: subjectKind, ID: change.id, TypeID: typeID}, Source: r.source, Data: data}
		if err = r.tx.AppendEvent(event); err != nil {
			return err
		}
	}
	return nil
}
