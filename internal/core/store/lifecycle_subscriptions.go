package store

import (
	"strings"
	"sync"
)

// SubscribeLifecycle reports only commits that can change the selected event
// stream, this consumer's work/outcomes, or the exact observed private record.
// Filters have the same OR semantics as Pending. The initial revision and slow
// reader coalescing match Subscribe; delivery is still based on durable state.
func (s *Store) SubscribeLifecycle(consumerID string, filters []Filter, observedKey string) (<-chan uint64, func()) {
	keys := []string{}
	for _, key := range filterSelectionKeys(filters) {
		keys = append(keys, "event:"+key)
	}
	if consumerID != "" {
		keys = append(keys, "consumer:"+consumerID)
	}
	if observedKey != "" {
		keys = append(keys, "record:"+observedKey)
	}
	ch := make(chan uint64, 1)
	s.subscribersMu.Lock()
	select {
	case <-s.closed:
		close(ch)
	default:
		s.lifecycleSubscribers[ch] = keys
		for _, key := range keys {
			listeners := s.lifecycleRoutes[key]
			if listeners == nil {
				listeners = make(map[chan uint64]struct{})
				s.lifecycleRoutes[key] = listeners
			}
			listeners[ch] = struct{}{}
		}
		ch <- s.Snapshot().Revision()
	}
	s.subscribersMu.Unlock()
	var once sync.Once
	return ch, func() {
		once.Do(func() {
			s.subscribersMu.Lock()
			defer s.subscribersMu.Unlock()
			if keys, ok := s.lifecycleSubscribers[ch]; ok {
				for _, key := range keys {
					delete(s.lifecycleRoutes[key], ch)
					if len(s.lifecycleRoutes[key]) == 0 {
						delete(s.lifecycleRoutes, key)
					}
				}
				delete(s.lifecycleSubscribers, ch)
				close(ch)
			}
		})
	}
}

func notifyRevision(ch chan uint64, revision uint64) {
	select {
	case ch <- revision:
	default:
		select {
		case <-ch:
		default:
		}
		select {
		case ch <- revision:
		default:
		}
	}
}

func (s *Store) notifyLifecycle(tx *Tx, next Snapshot) {
	listeners := map[chan uint64]struct{}{}
	add := func(key string) {
		for ch := range s.lifecycleRoutes[key] {
			listeners[ch] = struct{}{}
		}
	}
	addEvent := func(snapshot Snapshot, id string) {
		if snapshot.data != nil {
			if entry, ok := indexGet(snapshot.data.lifecycle.events, id); ok {
				for _, key := range eventSelectionKeys(entry.event) {
					add("event:" + key)
				}
			}
		}
	}
	for key := range tx.writes {
		add("record:" + key)
		switch {
		case strings.HasPrefix(key, eventPrefix):
			id := strings.TrimPrefix(key, eventPrefix)
			addEvent(tx.base, id)
			addEvent(next, id)
		case strings.HasPrefix(key, workPrefix):
			add("consumer:" + strings.TrimPrefix(key, workPrefix))
		case strings.HasPrefix(key, outcomePrefix):
			consumer, _, _ := strings.Cut(strings.TrimPrefix(key, outcomePrefix), ":")
			add("consumer:" + consumer)
		}
	}
	for ch := range listeners {
		notifyRevision(ch, next.Revision())
	}
}
