package applicationhost

import (
	"fmt"
	"slices"
	"strings"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/core/store"
)

type recordIndex struct {
	records  store.RecordSnapshot
	byRecord map[string][]string
	byKey    map[string]map[string]struct{}
}

func (r *recordReader) Count(collection string) (int, error) {
	if _, err := r.collection(collection); err != nil {
		return 0, err
	}
	if err := r.access(recordKey(collection, "")); err != nil {
		return 0, err
	}
	return r.current().Count(recordKey(collection, "")), nil
}

func (r *recordReader) LookupIDs(collection, indexID, key string) ([]string, error) {
	definition, err := r.collection(collection)
	if err != nil {
		return nil, err
	}
	if err = r.access(recordKey(collection, "")); err != nil {
		return nil, err
	}
	var index *plugin.RecordIndex
	for i := range definition.Indexes {
		if definition.Indexes[i].ID == indexID {
			index = &definition.Indexes[i]
			break
		}
	}
	if index == nil {
		return nil, fmt.Errorf("unknown collection index: %s/%s", collection, indexID)
	}
	snapshot := r.current()
	h := r.host
	h.indexMu.Lock()
	defer h.indexMu.Unlock()
	if h.indexes == nil {
		h.indexes = map[string]*recordIndex{}
	}
	identity := collection + ":" + indexID
	cache := h.indexes[identity]
	if cache == nil {
		cache = &recordIndex{byRecord: map[string][]string{}, byKey: map[string]map[string]struct{}{}}
	}
	// Stage derivations before mutating the cache: a failed projector must not
	// leave a half-applied index paired with its previous snapshot.
	changed := map[string][]string{}
	prefix := recordKey(collection, "")
	records := snapshot.RecordPrefix(prefix)
	for _, recordKey := range records.ChangedKeys(cache.records) {
		id := strings.TrimPrefix(recordKey, prefix)
		var record model.VersionedRecord
		found, err := snapshot.Get(recordKey, &record)
		if err != nil {
			return nil, err
		}
		var keys []string
		if found {
			keys, err = index.Keys(record.Value)
			if err != nil {
				return nil, err
			}
			keys = slices.Clone(keys)
			slices.Sort(keys)
			keys = slices.Compact(keys)
		}
		changed[id] = keys
	}
	for id, keys := range changed {
		for _, old := range cache.byRecord[id] {
			delete(cache.byKey[old], id)
			if len(cache.byKey[old]) == 0 {
				delete(cache.byKey, old)
			}
		}
		delete(cache.byRecord, id)
		if len(keys) > 0 {
			cache.byRecord[id] = keys
		}
		for _, value := range keys {
			if cache.byKey[value] == nil {
				cache.byKey[value] = map[string]struct{}{}
			}
			cache.byKey[value][id] = struct{}{}
		}
	}
	cache.records = records
	h.indexes[identity] = cache
	ids := make([]string, 0, len(cache.byKey[key]))
	for id := range cache.byKey[key] {
		ids = append(ids, id)
	}
	slices.Sort(ids)
	return ids, nil
}
