package threadsearch

import (
	"context"
	"errors"
	"sync"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/core/store"
)

const automaticVersion = 1

func defaultConfig() Config {
	return Config{Pipeline: indexVersion, AutomaticVersion: automaticVersion, Enabled: true, IncludeContent: true, AutoUpdate: true, Scope: map[string]string{}}
}

type Config struct {
	AutomaticVersion int               `json:"automaticVersion"`
	Revision         uint64            `json:"revision"`
	Epoch            uint64            `json:"epoch"`
	Pipeline         string            `json:"pipeline"`
	IncludeContent   bool              `json:"includeContent"`
	AutoUpdate       bool              `json:"autoUpdate"`
	Enabled          bool              `json:"enabled"`
	IndexPaused      bool              `json:"indexPaused"`
	Scope            map[string]string `json:"scope,omitempty"`
}
type ConfigureRequest struct {
	ExpectedRevision uint64 `json:"expectedRevision"`
	IncludeContent   bool   `json:"includeContent"`
	AutoUpdate       bool   `json:"autoUpdate"`
}
type IndexRequest struct {
	Action           string `json:"action"`
	ExpectedRevision uint64 `json:"expectedRevision"`
	Consent          bool   `json:"consent"`
}
type Status struct {
	Config           Config                      `json:"config"`
	Model            string                      `json:"model"`
	Dimensions       int                         `json:"dimensions"`
	ModelAvailable   bool                        `json:"modelAvailable"`
	Setup            plugin.EmbeddingSetupStatus `json:"setup"`
	Working          bool                        `json:"working"`
	Eligible         int                         `json:"eligible"`
	Indexed          int                         `json:"indexed"`
	PendingChunks    int                         `json:"pendingChunks"`
	PendingDocuments int                         `json:"pendingDocuments"`
	Truncated        int                         `json:"truncated"`
	Reason           string                      `json:"reason,omitempty"`
}
type Options struct {
	Trace         func(plugin.SearchDiagnostic)
	Store         *store.Store
	Provider      plugin.EmbeddingProvider
	Sources       func(store.Snapshot, bool) ([]Source, error)
	Interval      time.Duration // minimum start spacing and post-inference background rest
	WatchInterval time.Duration
	RetryMin      time.Duration
	RetryMax      time.Duration
}
type Manager struct {
	options                 Options
	ctx                     context.Context
	cancel                  context.CancelFunc
	control                 sync.Mutex
	mu                      sync.Mutex
	paused, closed, working bool
	workerCancel            context.CancelFunc
	workerDone              chan struct{}
	requestCtx              context.Context
	requestCancel           context.CancelFunc
	reason                  string
	autoDownload            bool
	retryAttempts           int
	retryAfter              time.Time
	gate                    inferenceGate
	retrieval               retrievalCache
	lastRequest             time.Time // owned by gate
	cache                   map[string][]float32
	cacheOrder              []string
	watcherDone             chan struct{}
}

var ErrStale = errors.New("Search settings changed; reload before confirming")

func readConfig(snapshot store.Snapshot) (Config, error) {
	c := defaultConfig()
	_, err := snapshot.Get(configKey, &c)
	if c.Scope == nil {
		c.Scope = map[string]string{}
	}
	return c, err
}
func New(ctx context.Context, options Options) (*Manager, error) {
	// Migrate the former opt-in settings once. A changed vector space never
	// inherits old derived vectors; setup and indexing now follow app policy.
	if _, err := options.Store.Update(ctx, func(tx *store.Tx) error {
		var old Config
		exists, err := tx.Get(configKey, &old)
		if err != nil {
			return err
		}
		if exists && old.Pipeline == indexVersion && old.AutomaticVersion >= automaticVersion {
			return nil
		}
		if exists {
			for _, key := range tx.Keys(documentPrefix) {
				if err := tx.Delete(key); err != nil {
					return err
				}
			}
			if err := tx.Delete("search-usage"); err != nil {
				return err
			}
		}
		c := defaultConfig()
		if exists {
			c.Revision = old.Revision + 1
			c.Epoch = old.Epoch + 1
		}
		return tx.Put(configKey, c)
	}); err != nil {
		return nil, err
	}

	life, cancel := context.WithCancel(ctx)
	if options.Interval <= 0 {
		options.Interval = 100 * time.Millisecond
	}
	if options.WatchInterval <= 0 {
		options.WatchInterval = 2 * time.Second
	}
	if options.RetryMin <= 0 {
		options.RetryMin = 5 * time.Second
	}
	if options.RetryMax < options.RetryMin {
		options.RetryMax = 5 * time.Minute
		if options.RetryMax < options.RetryMin {
			options.RetryMax = options.RetryMin
		}
	}
	m := &Manager{options: options, ctx: life, cancel: cancel, cache: map[string][]float32{}, watcherDone: make(chan struct{})}
	m.requestCtx, m.requestCancel = context.WithCancel(life)
	go m.watch()
	return m, nil
}
func (m *Manager) sources(snapshot store.Snapshot, c Config) ([]Source, error) {
	if m.options.Sources == nil {
		return nil, nil
	}
	return m.options.Sources(snapshot, c.Enabled && c.IncludeContent)
}
func allowed(c Config, s Source) bool {
	return c.Enabled && (c.AutoUpdate || c.Scope[RefKey(s.Ref)] == s.Identity)
}
func (m *Manager) Status(ctx context.Context) (Status, error) {
	status, _, err := m.status(ctx)
	return status, err
}

func (m *Manager) status(ctx context.Context) (Status, int, error) {
	readyPending := 0
	snapshot := m.options.Store.Snapshot()
	c, err := readConfig(snapshot)
	if err != nil {
		return Status{}, 0, err
	}
	sources, err := m.sources(snapshot, c)
	if err != nil {
		return Status{}, 0, err
	}
	m.mu.Lock()
	s := Status{Config: c, Dimensions: Dimensions, Working: m.working, Reason: m.reason}
	m.mu.Unlock()
	s.Config.Scope = nil
	if m.options.Provider != nil {
		s.Model = m.options.Provider.Model()
		s.ModelAvailable = m.options.Provider.Available(ctx)
		if local, ok := m.options.Provider.(plugin.ManagedEmbeddings); ok {
			s.Setup = local.SetupStatus()
		}
	}
	s.Eligible = len(sources)
	for _, source := range sources {
		if !allowed(c, source) {
			continue
		}
		old := m.retrieval.document(ctx, snapshot, documentPrefix+RefKey(source.Ref))
		if currentDocument(source, old) && completeDocument(old) {
			s.Indexed++
			if old.Truncated {
				s.Truncated++
			}
			continue
		}
		s.PendingDocuments++
		if source.Busy {
			if s.Reason == "" && !s.Working {
				s.Reason = "waiting"
			}
			continue
		}
		readyPending++
		doc, err := prepareSource(source, old)
		if err != nil {
			return Status{}, 0, err
		}
		for _, chunk := range doc.Chunks {
			if !validVector(chunk.Vector) {
				s.PendingChunks++
			}
		}
		if doc.Truncated {
			s.Truncated++
		}
	}
	if s.Reason == "" {
		if !c.Enabled {
			s.Reason = "disabled"
		} else if c.IndexPaused {
			s.Reason = "paused"
		} else if !s.ModelAvailable {
			s.Reason = "model-missing"
		}
	}
	return s, readyPending, nil
}

// Configuration changes revoke indexing permission. Changed text scope purges
// vectors; automatic-update changes can reuse matching chunks after confirmation.
func (m *Manager) Configure(ctx context.Context, request ConfigureRequest) (Status, error) {
	m.control.Lock()
	defer m.control.Unlock()
	before, err := readConfig(m.options.Store.Snapshot())
	if err != nil {
		return Status{}, err
	}
	if before.Revision != request.ExpectedRevision {
		return Status{}, ErrStale
	}
	m.stopWorker()
	_, err = m.options.Store.Update(ctx, func(tx *store.Tx) error {
		c, err := readConfig(tx.Snapshot())
		if err != nil {
			return err
		}
		if c.Revision != request.ExpectedRevision {
			return ErrStale
		}
		c.Revision++
		c.Epoch++
		c.Enabled = false
		c.IndexPaused = false
		c.Scope = map[string]string{}
		sameEmbeddingScope := c.IncludeContent == request.IncludeContent
		c.IncludeContent = request.IncludeContent
		c.AutoUpdate = request.AutoUpdate
		if !sameEmbeddingScope {
			for _, key := range tx.Keys(documentPrefix) {
				if err := tx.Delete(key); err != nil {
					return err
				}
			}
		}
		return tx.Put(configKey, c)
	})
	if err != nil {
		return Status{}, err
	}
	m.mu.Lock()
	m.reason = ""
	m.cache = map[string][]float32{}
	m.cacheOrder = nil
	m.mu.Unlock()
	if err := m.resetQueries(); err != nil {
		return Status{}, err
	}
	return m.Status(ctx)
}
func (m *Manager) resetQueries() error {
	m.retrieval.clear()
	m.mu.Lock()
	m.requestCancel()
	m.requestCtx, m.requestCancel = context.WithCancel(m.ctx)
	m.mu.Unlock()
	if local, ok := m.options.Provider.(plugin.ManagedEmbeddings); ok {
		return local.Release()
	}
	return nil
}
func (m *Manager) Index(ctx context.Context, request IndexRequest) (Status, error) {
	m.control.Lock()
	defer m.control.Unlock()
	return m.index(ctx, request)
}

// RemoveModel keeps permission revocation and joined asset removal in one
// control operation. A second window cannot enable indexing between the two.
func (m *Manager) RemoveModel(ctx context.Context) (Status, error) {
	m.control.Lock()
	defer m.control.Unlock()
	local, ok := m.options.Provider.(plugin.ManagedEmbeddings)
	if !ok {
		return Status{}, errors.New("Local embedding engine is unavailable")
	}
	if _, err := m.index(ctx, IndexRequest{Action: "disable"}); err != nil {
		return Status{}, err
	}
	if err := local.Remove(); err != nil {
		return Status{}, err
	}
	return m.Status(ctx)
}

func (m *Manager) index(ctx context.Context, request IndexRequest) (Status, error) {
	if request.Action == "cancel" {
		m.stopWorker()
		if _, err := m.options.Store.Update(ctx, func(tx *store.Tx) error {
			c, err := readConfig(tx.Snapshot())
			if err != nil {
				return err
			}
			c.IndexPaused = true
			c.Revision++
			return tx.Put(configKey, c)
		}); err != nil {
			return Status{}, err
		}
		m.setReason("paused")
		return m.Status(ctx)
	}
	if request.Action == "disable" {
		m.stopWorker()
		_, err := m.options.Store.Update(ctx, disableIndex)
		if err != nil {
			return Status{}, err
		}
		m.mu.Lock()
		m.cache = map[string][]float32{}
		m.cacheOrder = nil
		m.reason = ""
		m.mu.Unlock()
		if err := m.resetQueries(); err != nil {
			return Status{}, err
		}
		return m.Status(ctx)
	}
	if request.Action != "start" || !request.Consent {
		return Status{}, errors.New("Explicit confirmation is required to build the local thread index")
	}
	m.mu.Lock()
	unavailable := m.paused || m.closed || m.working
	m.mu.Unlock()
	if unavailable {
		return m.Status(ctx)
	}
	c, err := readConfig(m.options.Store.Snapshot())
	if err != nil {
		return Status{}, err
	}
	if c.Revision != request.ExpectedRevision {
		return Status{}, ErrStale
	}
	if m.options.Provider == nil || !m.options.Provider.Available(ctx) {
		m.setReason("model-missing")
		return m.Status(ctx)
	}
	sources, err := m.sources(m.options.Store.Snapshot(), c)
	if err != nil {
		return Status{}, err
	}
	_, err = m.options.Store.Update(ctx, func(tx *store.Tx) error {
		latest, err := readConfig(tx.Snapshot())
		if err != nil {
			return err
		}
		if latest.Revision != request.ExpectedRevision {
			return ErrStale
		}
		latest.Revision++
		if !latest.Enabled {
			latest.Epoch++
		}
		latest.Enabled = true
		latest.IndexPaused = false
		for _, source := range sources {
			if tx.Has(source.Owner) {
				latest.Scope[RefKey(source.Ref)] = source.Identity
			}
		}
		return tx.Put(configKey, latest)
	})
	if err != nil {
		return Status{}, err
	}
	m.launch()
	return m.Status(ctx)
}
func (m *Manager) launch() {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.closed || m.paused || m.working {
		return
	}
	ctx, cancel := context.WithCancel(m.requestCtx)
	m.working = true
	m.reason = ""
	m.workerCancel = cancel
	m.workerDone = make(chan struct{})
	done := m.workerDone
	go func() {
		defer close(done)
		defer cancel()
		err := m.build(ctx)
		m.mu.Lock()
		m.working = false
		if err != nil && ctx.Err() == nil {
			if reason(err) == "batch-limit" {
				m.reason = ""
				m.retryAfter = time.Now().Add(m.options.WatchInterval)
			} else {
				m.retryLocked(reason(err))
			}
		} else if err == nil {
			m.reason = ""
			m.retryAttempts = 0
			m.retryAfter = time.Time{}
		}
		m.mu.Unlock()
	}()
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
	defer m.retrieval.clear()
	m.mu.Lock()
	m.paused = true
	m.requestCancel()
	m.cache = map[string][]float32{}
	m.cacheOrder = nil
	m.mu.Unlock()
	m.stopWorker()
	if local, ok := m.options.Provider.(plugin.ManagedEmbeddings); ok {
		local.CancelDownload()
		return local.Release()
	}
	return nil
}
func (m *Manager) Resume() {
	m.mu.Lock()
	defer m.mu.Unlock()
	if !m.closed {
		m.requestCtx, m.requestCancel = context.WithCancel(m.ctx)
		m.paused = false
		m.reason = ""
		m.autoDownload = false
		m.retryAttempts = 0
		m.retryAfter = time.Time{}
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
func (m *Manager) setReason(code string) { m.mu.Lock(); m.reason = code; m.mu.Unlock() }
func reason(err error) string {
	var service *plugin.EmbeddingError
	if errors.As(err, &service) {
		return service.Code
	}
	if errors.Is(err, context.Canceled) {
		return "cancelled"
	}
	return "local-unavailable"
}
func (m *Manager) request(ctx context.Context, c Config, text string, cacheKey string) (vector []float32, err error) {
	ctx, id := plugin.SearchOperation(ctx)
	started := time.Now()
	event := plugin.SearchDiagnostic{Event: "search.request.completed", OperationID: id, Kind: "index", Epoch: c.Epoch, Cache: "none"}
	if cacheKey != "" {
		event.Kind = "query"
		event.Cache = "miss"
	}
	defer func() {
		event.DurationMS = plugin.SearchDuration(started)
		if err != nil {
			event.Outcome = "failed"
			event.Reason = plugin.SearchFailure(err)
		} else {
			event.Outcome = "completed"
		}
		m.trace(event)
	}()
	gateAcquired := false
	defer func() {
		if !gateAcquired {
			event.QueueMS = plugin.SearchDuration(started)
		}
	}()
	if err := m.gate.acquire(ctx, cacheKey != ""); err != nil {
		return nil, err
	}
	gateAcquired = true
	event.QueueMS = plugin.SearchDuration(started)
	defer m.gate.release()
	if cacheKey != "" {
		m.mu.Lock()
		cached := m.cache[cacheKey]
		m.mu.Unlock()
		if cached != nil {
			event.Cache = "hit"
			return cached, nil
		}
	}
	if remaining := time.Until(m.lastRequest.Add(m.options.Interval)); remaining > 0 {
		rateStarted := time.Now()
		timer := time.NewTimer(remaining)
		defer timer.Stop()
		select {
		case <-timer.C:
		case <-ctx.Done():
			event.RateWaitMS = plugin.SearchDuration(rateStarted)
			return nil, ctx.Err()
		}
		event.RateWaitMS = plugin.SearchDuration(rateStarted)
	}
	live, err := readConfig(m.options.Store.Snapshot())
	if err != nil {
		return nil, err
	}
	if !live.Enabled || live.Epoch != c.Epoch {
		return nil, context.Canceled
	}
	m.lastRequest = time.Now()
	vector, err = m.options.Provider.Embed(ctx, text, Dimensions)
	if err != nil {
		return nil, err
	}
	if !validVector(vector) {
		return nil, &plugin.EmbeddingError{Code: "response"}
	}
	if cacheKey != "" && ctx.Err() == nil {
		live, _ := readConfig(m.options.Store.Snapshot())
		if live.Enabled && live.Epoch == c.Epoch {
			m.mu.Lock()
			if len(m.cacheOrder) >= 64 {
				delete(m.cache, m.cacheOrder[0])
				m.cacheOrder = m.cacheOrder[1:]
			}
			m.cache[cacheKey] = vector
			m.cacheOrder = append(m.cacheOrder, cacheKey)
			m.mu.Unlock()
		}
	}
	return vector, nil
}
func (m *Manager) build(ctx context.Context) (err error) {
	ctx, id := plugin.SearchOperation(ctx)
	started := time.Now()
	event := plugin.SearchDiagnostic{Event: "search.index.completed", OperationID: id}
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
	snapshot := m.options.Store.Snapshot()
	c, err := readConfig(snapshot)
	if err != nil {
		return err
	}
	if !c.Enabled || m.options.Provider == nil {
		return nil
	}
	sources, err := m.sources(snapshot, c)
	if err != nil {
		return err
	}
	event.Epoch = c.Epoch
	requests := 0
	for _, source := range sources {
		if !allowed(c, source) || source.Busy {
			continue
		}
		key := documentPrefix + RefKey(source.Ref)
		var old Document
		_, _ = snapshot.Get(key, &old)
		if currentDocument(source, old) && completeDocument(old) {
			event.ReusedChunks += len(old.Chunks)
			continue
		}
		document, err := prepareSource(source, old)
		if err != nil {
			return err
		}
		event.DocumentCount++
		event.ChunkCount += len(document.Chunks)
		dirty := document.SourceHash != old.SourceHash || document.Fingerprint != old.Fingerprint
		pending := 0
		flush := func() error {
			if !dirty {
				return nil
			}
			if err := persist(ctx, m.options.Store, c, source, document); err != nil {
				return err
			}
			dirty, pending = false, 0
			return nil
		}
		for i := range document.Chunks {
			if validVector(document.Chunks[i].Vector) {
				event.ReusedChunks++
				continue
			}
			if requests == 200 {
				if err := flush(); err != nil {
					return err
				}
				return &plugin.EmbeddingError{Code: "batch-limit"}
			}
			if ctx.Err() != nil {
				return ctx.Err()
			}
			// Check the immutable owner's bytes before sending each chunk too.
			live := m.options.Store.Snapshot()
			current, _ := live.RecordHash(source.Owner)
			now, _ := readConfig(live)
			if current != source.OwnerHash || now.Epoch != c.Epoch || !allowed(now, source) {
				break
			}
			vector, err := m.request(ctx, c, document.Chunks[i].prompt(), "")
			requests++
			event.RequestCount = requests
			if err != nil {
				if ctx.Err() == nil {
					if saveErr := flush(); saveErr != nil {
						return saveErr
					}
				}
				return err
			}
			document.Chunks[i].Vector = vector
			dirty = true
			pending++
			if pending == 8 {
				if err := flush(); err != nil {
					return err
				}
			}
			// Rest after compute, outside the gate, so long inference does not
			// turn the old start-rate limit into continuous background load.
			timer := time.NewTimer(m.options.Interval)
			select {
			case <-timer.C:
			case <-ctx.Done():
				timer.Stop()
				return ctx.Err()
			}
		}
		// Content changes can reuse every chunk; commit its new fingerprint too.
		if err := flush(); err != nil {
			return err
		}
	}
	return nil
}

func (m *Manager) trace(event plugin.SearchDiagnostic) {
	if m.options.Trace != nil {
		m.options.Trace(event)
	}
}
