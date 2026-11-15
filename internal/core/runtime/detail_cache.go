package runtime

import (
	"unicode/utf8"
)

type detailBodyKey struct {
	ThreadID    string
	ContentID   string
	ExecutionID string
	ItemID      string
	Slot        string
}

type detailBodyEntry struct {
	text    string
	version string
	length  int
}

const (
	detailCacheEntries  = 64
	detailCacheMaxBytes = 96 << 20
)

func detailCacheKey(threadID, contentID, executionID, itemID, slot string) detailBodyKey {
	return detailBodyKey{ThreadID: threadID, ContentID: contentID, ExecutionID: executionID, ItemID: itemID, Slot: slot}
}

func (r *Runtime) cachedDetailBody(key detailBodyKey) (detailBodyEntry, bool) {
	r.detailMu.Lock()
	defer r.detailMu.Unlock()
	entry, ok := r.detailCache[key]
	if !ok {
		return detailBodyEntry{}, false
	}
	for index, current := range r.detailOrder {
		if current == key {
			r.detailOrder = append(r.detailOrder[:index], r.detailOrder[index+1:]...)
			break
		}
	}
	r.detailOrder = append(r.detailOrder, key)
	return entry, true
}

func (r *Runtime) retainDetailBody(key detailBodyKey, entry detailBodyEntry) {
	if entry.length == 0 {
		return
	}
	r.detailMu.Lock()
	defer r.detailMu.Unlock()
	if previous, exists := r.detailCache[key]; exists {
		r.detailBytes -= int64(previous.length)
		for index, current := range r.detailOrder {
			if current != key {
				continue
			}
			r.detailOrder = append(r.detailOrder[:index], r.detailOrder[index+1:]...)
			break
		}
	}
	r.detailCache[key] = entry
	r.detailOrder = append(r.detailOrder, key)
	r.detailBytes += int64(entry.length)
	for len(r.detailCache) > detailCacheEntries || r.detailBytes > detailCacheMaxBytes {
		if len(r.detailOrder) == 0 {
			break
		}
		oldest := r.detailOrder[0]
		r.detailOrder = r.detailOrder[1:]
		if removed, ok := r.detailCache[oldest]; ok {
			delete(r.detailCache, oldest)
			r.detailBytes -= int64(removed.length)
		}
	}
}

func (r *Runtime) clearDetailCache() {
	r.detailMu.Lock()
	r.detailCache = map[detailBodyKey]detailBodyEntry{}
	r.detailOrder = nil
	r.detailBytes = 0
	r.detailMu.Unlock()
}

func (r *Runtime) dropThreadDetailCache(threadID string) {
	r.detailMu.Lock()
	defer r.detailMu.Unlock()
	for key := range r.detailCache {
		if key.ThreadID != threadID {
			continue
		}
		r.detailBytes -= int64(r.detailCache[key].length)
		delete(r.detailCache, key)
	}
	order := r.detailOrder[:0]
	for _, key := range r.detailOrder {
		if key.ThreadID != threadID {
			order = append(order, key)
		}
	}
	r.detailOrder = order
}

func detailBodyTextValid(text string) bool { return utf8.ValidString(text) }
