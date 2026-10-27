package threadsearch

import (
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

// Called with mu held. Retry is bounded exponential backoff, independent of
// catalog event volume; a stream of mutations cannot create a download storm.
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
	c, err := readConfig(m.options.Store.Snapshot())
	if err != nil {
		m.mu.Lock()
		m.retryLocked(reason(err))
		m.mu.Unlock()
		return true
	}
	if !c.Enabled || !c.AutoUpdate || c.IndexPaused {
		return false
	}
	if m.options.Provider == nil {
		return dirty
	}
	if !m.options.Provider.Available(m.ctx) {
		local, ok := m.options.Provider.(plugin.ManagedEmbeddings)
		if !ok {
			return dirty
		}
		// Serialize just setup/launch with pause, removal and reconfiguration.
		// Source extraction below stays outside control so Pause can cancel
		// promptly even while a plugin is producing its search projection.
		m.control.Lock()
		defer m.control.Unlock()
		latest, err := readConfig(m.options.Store.Snapshot())
		if err != nil || latest.Epoch != c.Epoch || !latest.Enabled || !latest.AutoUpdate || latest.IndexPaused || !m.canMaintain() {
			return true
		}
		setup := local.SetupStatus()
		if !setup.Supported {
			return true
		}
		m.mu.Lock()
		if setup.Downloading {
			m.autoDownload = true
			m.mu.Unlock()
			return true
		}
		if m.autoDownload {
			m.autoDownload = false
			m.retryLocked("download-failed")
			m.mu.Unlock()
			return true
		}
		m.mu.Unlock()
		if err := local.Download(m.ctx); err != nil {
			m.mu.Lock()
			m.retryLocked(reason(err))
			m.mu.Unlock()
		} else {
			m.mu.Lock()
			m.autoDownload = true
			m.reason = ""
			m.mu.Unlock()
		}
		return true
	}
	m.mu.Lock()
	if m.autoDownload {
		m.autoDownload = false
		m.retryAttempts = 0
		m.retryAfter = time.Time{}
		m.reason = ""
		dirty = true
	}
	m.mu.Unlock()
	if !dirty {
		return false
	}
	status, readyPending, err := m.status(m.ctx)
	if err != nil {
		m.mu.Lock()
		m.retryLocked(reason(err))
		m.mu.Unlock()
		return true
	}
	if readyPending == 0 {
		// Busy owners remain pending until completion, without starting a
		// worker that would only extract and then discard their histories.
		return status.PendingDocuments != 0
	}
	m.control.Lock()
	defer m.control.Unlock()
	latest, err := readConfig(m.options.Store.Snapshot())
	if err == nil && latest.Revision == c.Revision && latest.Epoch == c.Epoch && latest.Enabled && latest.AutoUpdate && !latest.IndexPaused && m.canMaintain() {
		m.launch()
	}
	// Remain dirty through a failed evaluation or a 200-chunk batch boundary.
	// Only a complete status can quiesce maintenance, not the launch itself.
	return true
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
		case <-ticker.C:
			// Also observe asynchronous setup completion/failure when no store
			// mutation occurred, and repair missing assets after an idle period.
			dirty = m.automaticStep(dirty)
		}
	}
}
