package moku

// The caller holds mu. Removing a terminal delivery and claiming its queued
// speech happen under that same lock, so reconnect cannot observe a false idle
// interval between terminal settlement and the asynchronous Speak call.
func (v *voiceController) hasPendingSpeechLocked(owner string) bool {
	for _, delivery := range v.deliveries {
		if delivery.owner == owner && delivery.lease == v.active {
			return true
		}
	}
	for delivery := range v.pendingSpeeches {
		if delivery.owner == owner && delivery.lease == v.active {
			return true
		}
	}
	return false
}

// Preserve pending terminal speech before its native handle is closed. Native
// commits can hold the adapter's state mutex, so this must run at the idle
// configuration boundary, never synchronously from the committed callback.
// The narrow reply fence prevents deliver from removing a pending entry while
// it still needs that same handle; it does not block terminal audit settlement.
func (v *voiceController) captureReplies(owner string) {
	if v.c.config.CompletedReply == nil {
		return
	}
	v.replyMu.Lock()
	defer v.replyMu.Unlock()
	v.mu.Lock()
	pending := make(map[string]*voiceDelivery)
	for id, delivery := range v.deliveries {
		if delivery.owner == owner && delivery.lease == v.active && !delivery.hasReply {
			pending[id] = delivery
		}
	}
	v.mu.Unlock()
	for id, delivery := range pending {
		reply, ok := v.c.config.CompletedReply(owner, id)
		if !ok {
			continue
		}
		v.mu.Lock()
		if v.deliveries[id] == delivery && delivery.lease == v.active {
			delivery.reply, delivery.hasReply = reply, true
		}
		v.mu.Unlock()
	}
}
