package threadsearch

import (
	"context"
	"sync"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/core/store"
)

type Config struct {
	Revision uint64 `json:"revision"`
	Epoch    uint64 `json:"epoch"`
	Pipeline string `json:"pipeline"`
}

func defaultConfig() Config { return Config{Pipeline: indexVersion} }

type Status struct {
	Config           Config `json:"config"`
	Working          bool   `json:"working"`
	Eligible         int    `json:"eligible"`
	Indexed          int    `json:"indexed"`
	PendingDocuments int    `json:"pendingDocuments"`
	Truncated        int    `json:"truncated"`
	Reason           string `json:"reason,omitempty"`
}
type Options struct {
	Trace   func(plugin.SearchDiagnostic)
	Store   *store.Store
	Sources func(store.Snapshot, bool) ([]Source, error)
	// SourceChanges projects only owner keys that differ between immutable
	// snapshots. A zero previous snapshot requests initial enumeration.
	SourceChanges func(current, previous store.Snapshot, includeContent bool) ([]Source, error)
	WatchInterval time.Duration
	RetryMin      time.Duration
	RetryMax      time.Duration
}
type Manager struct {
	options                 Options
	ctx                     context.Context
	cancel                  context.CancelFunc
	control                 sync.Mutex
	buildMu                 sync.Mutex
	mu                      sync.Mutex
	paused, closed, working bool
	workerCancel            context.CancelFunc
	workerDone              chan struct{}
	requestCtx              context.Context
	requestCancel           context.CancelFunc
	reason                  string
	retryAttempts           int
	retryAfter              time.Time
	retrieval               retrievalCache
	watcherDone             chan struct{}
	maintenanceWake         chan struct{}
	sourceSnapshot          store.Snapshot
	sourceGeneration        uint64
	builtGeneration         uint64
}

func readConfig(snapshot store.Snapshot) (Config, error) {
	c := defaultConfig()
	_, err := snapshot.Get(configKey, &c)
	return c, err
}
func New(ctx context.Context, options Options) (*Manager, error) {
	// Only derived search records migrate. Source records and on-disk assets
	// remain untouched; retired configuration fields are deliberately ignored.
	if _, err := options.Store.Update(ctx, func(tx *store.Tx) error {
		var old Config
		exists, err := tx.Get(configKey, &old)
		if err != nil {
			return err
		}
		if exists && old.Pipeline == indexVersion {
			return nil
		}
		if err := ClearHistory(tx); err != nil {
			return err
		}
		if err := tx.Delete("search-usage"); err != nil {
			return err
		}
		c, err := readConfig(tx.Snapshot())
		if err != nil {
			return err
		}
		c.Pipeline = indexVersion
		return tx.Put(configKey, c)
	}); err != nil {
		return nil, err
	}
	life, cancel := context.WithCancel(ctx)
	if options.WatchInterval <= 0 {
		options.WatchInterval = 2 * time.Second
	}
	if options.RetryMin <= 0 {
		options.RetryMin = 5 * time.Second
	}
	if options.RetryMax < options.RetryMin {
		options.RetryMax = max(5*time.Minute, options.RetryMin)
	}
	m := &Manager{options: options, ctx: life, cancel: cancel, watcherDone: make(chan struct{}), maintenanceWake: make(chan struct{}, 1)}
	m.requestCtx, m.requestCancel = context.WithCancel(life)
	go m.watch()
	return m, nil
}
func (m *Manager) Status(ctx context.Context) (Status, error) {
	snapshot := m.options.Store.Snapshot()
	c, err := readConfig(snapshot)
	if err != nil {
		return Status{}, err
	}
	sources, err := m.options.Sources(snapshot, false)
	if err != nil {
		return Status{}, err
	}
	m.mu.Lock()
	s := Status{Config: c, Working: m.working, Reason: m.reason, Eligible: len(sources)}
	m.mu.Unlock()
	for _, source := range sources {
		if err := ctx.Err(); err != nil {
			return Status{}, err
		}
		stamp, err := readStamp(snapshot, source)
		if err != nil {
			return Status{}, err
		}
		if currentStamp(snapshot, source, stamp) {
			s.Indexed++
			if stamp.Truncated {
				s.Truncated++
			}
		} else {
			s.PendingDocuments++
		}
	}
	return s, nil
}
func (m *Manager) launch() bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.closed || m.paused || m.working {
		return false
	}
	ctx, cancel := context.WithCancel(m.requestCtx)
	m.working = true
	m.workerCancel = cancel
	m.workerDone = make(chan struct{})
	done := m.workerDone
	go func() {
		defer close(done)
		defer cancel()
		err := m.build(ctx)
		m.mu.Lock()
		defer m.mu.Unlock()
		m.working = false
		if err != nil && ctx.Err() == nil {
			m.retryLocked(plugin.SearchFailure(err))
		} else if err == nil {
			m.reason = ""
			m.retryAttempts = 0
			m.retryAfter = time.Time{}
		}
	}()
	return true
}

// Invalidate covers source registrations, which can change without a store
// commit. Normal owner changes use the immutable snapshot diff instead.
func (m *Manager) Invalidate() {
	m.mu.Lock()
	m.sourceGeneration++
	m.mu.Unlock()
	m.wakeMaintenance()
}
func (m *Manager) wakeMaintenance() {
	select {
	case m.maintenanceWake <- struct{}{}:
	default:
	}
}
func (m *Manager) stopWorker() {
	m.mu.Lock()
	cancel, done := m.workerCancel, m.workerDone
	m.mu.Unlock()
	if cancel != nil {
		cancel()
	}
	if done != nil {
		<-done
	}
}
func (m *Manager) Pause() error {
	m.control.Lock()
	defer m.control.Unlock()
	m.mu.Lock()
	m.paused = true
	m.requestCancel()
	m.mu.Unlock()
	m.stopWorker()
	m.retrieval.clear()
	return nil
}
func (m *Manager) Resume() {
	m.control.Lock()
	defer m.control.Unlock()
	m.mu.Lock()
	defer m.mu.Unlock()
	if !m.closed && m.paused {
		m.requestCtx, m.requestCancel = context.WithCancel(m.ctx)
		m.paused = false
		m.reason = ""
		m.retryAttempts = 0
		m.retryAfter = time.Time{}
		m.wakeMaintenance()
	}
}
func (m *Manager) Close() error {
	err := m.Pause()
	m.mu.Lock()
	m.closed = true
	m.cancel()
	m.mu.Unlock()
	<-m.watcherDone
	return err
}
func (m *Manager) build(ctx context.Context) (err error) {
	m.buildMu.Lock()
	defer m.buildMu.Unlock()
	snapshot := m.options.Store.Snapshot()
	c, err := readConfig(snapshot)
	if err != nil {
		return err
	}
	m.mu.Lock()
	previous, generation := m.sourceSnapshot, m.sourceGeneration
	builtGeneration := m.builtGeneration
	m.mu.Unlock()
	configHash, _ := snapshot.RecordHash(configKey)
	previousConfigHash, _ := previous.RecordHash(configKey)
	if generation != builtGeneration || configHash != previousConfigHash {
		previous = store.Snapshot{}
	}
	var sources []Source
	if m.options.SourceChanges != nil {
		sources, err = m.options.SourceChanges(snapshot, previous, true)
	} else if snapshot.Revision() != previous.Revision() {
		sources, err = m.options.Sources(snapshot, true)
	}
	if err != nil {
		return err
	}
	pending := make([]Source, 0, len(sources))
	for _, source := range sources {
		if err := ctx.Err(); err != nil {
			return err
		}
		if source.Busy {
			continue
		}
		stamp, err := readStamp(snapshot, source)
		if err != nil {
			return err
		}
		if !currentStamp(snapshot, source, stamp) {
			pending = append(pending, source)
		}
	}
	if len(pending) > 0 {
		ctx, id := plugin.SearchOperation(ctx)
		started := time.Now()
		event := plugin.SearchDiagnostic{Event: "search.index.completed", OperationID: id, Epoch: c.Epoch}
		m.trace(plugin.SearchDiagnostic{Event: "search.index.started", OperationID: id})
		defer func() {
			event.DurationMS = plugin.SearchDuration(started)
			event.Outcome = "completed"
			if err != nil {
				event.Outcome = "failed"
				event.Reason = plugin.SearchFailure(err)
			}
			m.trace(event)
		}()
		for _, source := range pending {
			if err := ctx.Err(); err != nil {
				return err
			}
			document, err := prepareSource(source)
			if err != nil {
				return err
			}
			if err := persist(ctx, m.options.Store, c, source, document); err != nil {
				return err
			}
			event.DocumentCount++
		}
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	// A busy owner is deliberately acknowledged here: its next committed source
	// change will make it eligible again. Only extraction failures retain retry
	// work, so one busy thread cannot poll the entire index forever.
	m.mu.Lock()
	m.sourceSnapshot = snapshot
	m.builtGeneration = generation
	m.mu.Unlock()
	return nil
}
func (m *Manager) trace(event plugin.SearchDiagnostic) {
	if m.options.Trace != nil {
		m.options.Trace(event)
	}
}
