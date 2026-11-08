package threadsearch

import (
	"time"
)

// Called with mu held. Retry is bounded exponential backoff, independent of
// catalog event volume; a stream of mutations cannot create an extraction storm.
func (m *Manager) retryLocked(code string) {
	m.reason = code
	m.retryAttempts++
	delay := m.options.RetryMin
	for n := 1; n < m.retryAttempts && delay < m.options.RetryMax; n++ {
		if delay > m.options.RetryMax/2 {
			delay = m.options.RetryMax
			break
		}
		delay *= 2
	}
	m.retryAfter = time.Now().Add(delay)
}

func (m *Manager) canMaintain() bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	return !m.closed && !m.paused && !m.working && !time.Now().Before(m.retryAfter)
}

func (m *Manager) automaticStep(dirty bool) bool {
	if !m.canMaintain() {
		return dirty
	}
	m.mu.Lock()
	retry := m.retryAttempts > 0
	m.mu.Unlock()
	if !dirty && !retry {
		return false
	}
	m.control.Lock()
	defer m.control.Unlock()
	if m.canMaintain() && m.launch() {
		return false
	}
	return dirty
}

func (m *Manager) watch() {
	defer close(m.watcherDone)
	changes, unsubscribe := m.options.Store.Subscribe()
	defer unsubscribe()
	ticker := time.NewTicker(m.options.WatchInterval)
	defer ticker.Stop()
	dirty := true
	for {
		select {
		case <-m.ctx.Done():
			return
		case _, ok := <-changes:
			if !ok {
				return
			}
			dirty = true
		case <-m.maintenanceWake:
			dirty = true
		case <-ticker.C:
			// Failures retry without a new write. Busy owners wait for their own
			// source change; automatic maintenance never asks for global Status.
			dirty = m.automaticStep(dirty)
		}
	}
}
