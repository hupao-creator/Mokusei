package applicationhost

import (
	"errors"

	"github.com/hupao-creator/Mokusei/internal/core/store"
)

// ClearHistory joins the runtime's history-reset transaction after this host has
// stopped and drained. Settings-retention collections and saved settings remain.
func (h *Host) ClearHistory(tx *store.Tx) error {
	h.mu.Lock()
	running := h.running
	h.mu.Unlock()
	if running {
		return errors.New("application participants must stop before clearing history")
	}
	for _, collection := range sortedKeys(h.collections) {
		if h.collections[collection].Retention != "history" {
			continue
		}
		for _, key := range tx.Keys(recordKey(collection, "")) {
			if err := tx.Delete(key); err != nil {
				return err
			}
		}
		if err := tx.Delete(collectionKey(collection)); err != nil {
			return err
		}
		if err := tx.SetOrder(orderKey(collection), nil); err != nil {
			return err
		}
	}
	for _, key := range tx.Keys("application-command-receipt:") {
		if err := tx.Delete(key); err != nil {
			return err
		}
	}
	return nil
}
