// Package runtime owns the durable application state and native session lifecycle.
// Adapters receive bounded capabilities and never acquire database ownership.
package runtime

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	goruntime "runtime"
	"sort"
	"sync"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/platform/transport"
	"github.com/hupao-creator/Mokusei/internal/platform/workpool"
	"github.com/hupao-creator/Mokusei/internal/services/attachments"
	"github.com/hupao-creator/Mokusei/internal/services/threadsearch"
	"github.com/hupao-creator/Mokusei/internal/services/threadvoice"
	"github.com/hupao-creator/Mokusei/internal/services/workspaces"
)

type OperationRequest = plugin.OperationRequest
type Applications interface {
	Query(context.Context, OperationRequest) (any, error)
	Command(context.Context, OperationRequest) (any, error)
	Archive(context.Context, model.ThreadRef, bool) error
	InitializeConversation(context.Context, model.ThreadRef) error
	Catalog(context.Context) ([]model.ApplicationThread, error)
}
type Moku interface {
	Invoke(context.Context, string, []json.RawMessage) (any, error)
}
type AttachmentStore interface {
	Stage(context.Context, []attachments.Import) ([]model.Attachment, error)
	Preview(context.Context, string, string) (string, error)
	Discard(context.Context, []string) error
	RetainInput(context.Context, string, model.AgentInput) (model.AgentInput, error)
	InheritOwners(context.Context, string, string) error
	ReleaseOwner(context.Context, string) error
	RetainOwners(context.Context, []string) error
}
type Config struct {
	Embeddings         plugin.EmbeddingProvider
	Store              *store.Store
	Harnesses          map[string]plugin.Harness
	DataDir            string
	DefaultCwd         string
	Attachments        AttachmentStore
	Applications       Applications
	Contexts           plugin.RuntimeParticipant
	Moku               Moku
	Plugins            []model.RuntimePlugin
	Log                func(string, error)
	Diagnostic         func(string)
	SettingsTrace      func(string, model.Object)
	SearchTrace        func(plugin.SearchDiagnostic)
	ProcessFactory     func(string) plugin.ApplicationProcessCapability
	ExtraCapabilities  map[string]any
	Workspaces         *workspaces.Manager
	DisabledHarnesses  map[string]string
	RefreshEnvironment func(context.Context) error
	TelemetryLedger    func(string) plugin.TelemetryLedger
	OutputLocale       func(context.Context) (string, error)
}
type Runtime struct {
	mokuDeliveryMu      sync.Mutex
	mokuDeliveryEpoch   string
	serviceMu           sync.Mutex
	serviceDraining     bool
	serviceAdmissions   int
	mokuHarnessChanging bool
	threadCacheMu       sync.Mutex
	threadCacheRevision uint64
	projectionMu        sync.Mutex
	compute             *workpool.Pool
	threadCache         map[string]cachedThread
	overviewCache       map[string]cachedOverview
	search              *threadsearch.Manager
	voiceOnce           sync.Once
	voice               *threadvoice.Manager
	config              Config
	ctx                 context.Context
	cancel              context.CancelFunc
	generationCtx       context.Context
	generationCancel    context.CancelFunc
	lifecycleMu         sync.Mutex
	mu                  sync.Mutex
	configurationGate   chan struct{}
	closed              bool
	resetting           bool
	generation          uint64
	handles             map[string]*threadHandle
	locks               map[string]*threadCommandLock
	deleting            map[string]bool
	sendClaims          map[string]map[*sendClaim]struct{}
	cancellationStates  map[string]*threadCancellation
	operations          sync.WaitGroup
	closeOnce           sync.Once
	closeErr            error
	publishMu           sync.Mutex
	baseline            model.AppState
	listeners           map[uint64]func(json.RawMessage)
	threadListeners     map[uint64]func(model.ThreadRecord)
	nextListener        uint64
	stopStore           func()
	publisherDone       chan struct{}
	lifecycle           *lifecycleCapability
	pendingPublications []json.RawMessage
	delivering          bool
	pendingActivities   []model.RuntimeActivity
	publisherWake       chan struct{}
}

func New(ctx context.Context, config Config) (*Runtime, error) {
	if config.Store == nil {
		return nil, errors.New("runtime store is required")
	}
	if config.DataDir == "" {
		return nil, errors.New("runtime data directory is required")
	}
	if config.DefaultCwd == "" {
		config.DefaultCwd, _ = os.UserHomeDir()
	}
	cwd, err := filepath.Abs(config.DefaultCwd)
	if err != nil {
		return nil, err
	}
	config.DefaultCwd = cwd
	if err := os.MkdirAll(config.DataDir, 0700); err != nil {
		return nil, err
	}
	lifetime, cancel := context.WithCancel(ctx)
	r := &Runtime{config: config, ctx: lifetime, cancel: cancel, handles: map[string]*threadHandle{}, locks: map[string]*threadCommandLock{}, listeners: map[uint64]func(json.RawMessage){}, publisherDone: make(chan struct{})}
	r.configurationGate = make(chan struct{}, 1)
	r.lifecycle = &lifecycleCapability{runtime: r, consumers: map[string]*lifecycleConsumer{}}
	r.threadListeners = map[uint64]func(model.ThreadRecord){}
	r.deleting = map[string]bool{}
	r.sendClaims = map[string]map[*sendClaim]struct{}{}
	r.generationCtx, r.generationCancel = context.WithCancel(lifetime)
	r.publisherWake = make(chan struct{}, 1)
	_, err = config.Store.Update(ctx, func(tx *store.Tx) error {
		if !tx.Has("settings") {
			settings := model.DefaultSettings(r.harnessIDs())
			for id, h := range config.Harnesses {
				settings.Harnesses[id] = h.DefaultSettings()
			}
			if err := tx.Put("settings", settings); err != nil {
				return err
			}
			if err := tx.Put("settings-revision", int64(0)); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		cancel()
		return nil, err
	}
	err = r.settleStaleMokuTranscript(ctx)
	if err != nil {
		cancel()
		return nil, err
	}
	if config.Attachments != nil {
		threads, e := r.Threads()
		if e != nil {
			cancel()
			return nil, e
		}
		ids := make([]string, 0, len(threads))
		for _, t := range threads {
			ids = append(ids, t.ID)
		}
		for _, key := range config.Store.Snapshot().Keys("private-session:") {
			var session plugin.PrivateSessionSnapshot
			if ok, e := config.Store.Snapshot().Get(key, &session); e == nil && ok {
				ids = append(ids, session.Record.ID)
			}
		}
		if e := config.Attachments.RetainOwners(ctx, ids); e != nil {
			cancel()
			return nil, e
		}
	}
	if config.Workspaces != nil {
		threads, e := r.Threads()
		if e != nil {
			cancel()
			return nil, e
		}
		failures := config.Workspaces.RehydratePersistedOwners(ctx, threads)
		for _, failure := range failures {
			r.log("workspace.recovery", failure.Err)
		}
	}
	r.compute = workpool.New(lifetime, min(4, goruntime.GOMAXPROCS(0)), 8, 64*1024*1024)
	initialized := false
	defer func() {
		if !initialized {
			cancel()
			_ = r.compute.Close(context.Background())
		}
	}()
	r.search, err = threadsearch.New(lifetime, threadsearch.Options{Store: config.Store, Provider: config.Embeddings, Sources: r.searchSources, Trace: config.SearchTrace})
	if err != nil {
		cancel()
		return nil, err
	}
	r.baseline, err = r.project()
	if err != nil {
		r.search.Close()
		cancel()
		return nil, err
	}
	changes, unsubscribe := config.Store.Subscribe()
	r.stopStore = unsubscribe
	go func() {
		defer close(r.publisherDone)
		var timer *time.Timer
		var deadline <-chan time.Time
		defer func() {
			if timer != nil {
				timer.Stop()
			}
		}()
		schedule := func() {
			if timer == nil {
				timer = time.NewTimer(50 * time.Millisecond)
				deadline = timer.C
			}
		}
		for {
			select {
			case _, ok := <-changes:
				if !ok {
					return
				}
				schedule()
			case <-r.publisherWake:
				schedule()
			case <-deadline:
				timer = nil
				deadline = nil
				r.Publish()
			case <-lifetime.Done():
				return
			}
		}
	}()
	initialized = true
	return r, nil
}

func (r *Runtime) SetApplications(applications Applications) {
	r.mu.Lock()
	r.config.Applications = applications
	r.mu.Unlock()
	r.Publish()
}
func (r *Runtime) SetMoku(moku Moku) { r.mu.Lock(); r.config.Moku = moku; r.mu.Unlock() }
func (r *Runtime) Harnesses() map[string]plugin.Harness {
	result := map[string]plugin.Harness{}
	for id, h := range r.config.Harnesses {
		result[id] = h
	}
	return result
}
func (r *Runtime) harnessIDs() []string {
	ids := make([]string, 0, len(r.config.Harnesses))
	for id := range r.config.Harnesses {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	return ids
}
func (r *Runtime) operational() error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.closed {
		return errors.New("Mokusei runtime is shutting down")
	}
	if r.resetting {
		return errors.New("Mokusei history is being cleared")
	}
	return r.ctx.Err()
}
func (r *Runtime) begin() error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.closed || r.resetting {
		return errors.New("Mokusei runtime is unavailable")
	}
	if err := r.ctx.Err(); err != nil {
		return err
	}
	r.operations.Add(1)
	return nil
}
func (r *Runtime) log(kind string, err error) {
	if err != nil && r.config.Log != nil {
		r.config.Log(kind, err)
	}
}
func (r *Runtime) Settings() (model.Settings, int64, error) {
	var s model.Settings
	var rev int64
	snap := r.config.Store.Snapshot()
	_, err := snap.Get("settings", &s)
	if err != nil {
		return s, 0, err
	}
	_, err = snap.Get("settings-revision", &rev)
	return s, rev, err
}
func (r *Runtime) Threads() ([]model.ThreadRecord, error) {
	return readThreads(r.config.Store.Snapshot())
}
func readThreads(snap store.Snapshot) ([]model.ThreadRecord, error) {
	threads := []model.ThreadRecord{}
	seen := map[string]bool{}
	ids := snap.Order("threads")
	for _, id := range ids {
		seen[id] = true
	}
	for _, key := range snap.Keys("thread:") {
		id := key[len("thread:"):]
		if !seen[id] {
			seen[id] = true
			ids = append(ids, id)
		}
	}
	for _, id := range ids {
		if !seen[id] {
			continue
		}
		delete(seen, id)
		var t model.ThreadRecord
		ok, err := snap.Get("thread:"+id, &t)
		if err != nil {
			return nil, err
		}
		if ok {
			threads = append(threads, t)
		}
	}
	return threads, nil
}
func (r *Runtime) Thread(id string) (model.ThreadRecord, error) {
	var t model.ThreadRecord
	if err := identifier(id); err != nil {
		return t, err
	}
	ok, err := r.config.Store.Snapshot().Get("thread:"+id, &t)
	if err != nil {
		return t, err
	}
	if !ok {
		return t, fmt.Errorf("unknown thread: %s", id)
	}
	return t, nil
}
func (r *Runtime) UpdateThread(ctx context.Context, id string, update func(*model.ThreadRecord) error) error {
	var committed model.ThreadRecord
	_, err := r.config.Store.Update(ctx, func(tx *store.Tx) error {
		var t model.ThreadRecord
		ok, err := tx.Get("thread:"+id, &t)
		if err != nil {
			return err
		}
		if !ok {
			return fmt.Errorf("unknown thread: %s", id)
		}
		before := t
		if err := update(&t); err != nil {
			return err
		}
		if !same(before.Settings, t.Settings) {
			if before.SettingsRevision >= model.MaximumSafeInteger {
				return errors.New("thread settings revision exhausted")
			}
			t.SettingsRevision = before.SettingsRevision + 1
		}
		t.Revision++
		t.UpdatedAt = max(time.Now().UnixMilli(), t.UpdatedAt)
		if err := tx.Put("thread:"+id, t); err != nil {
			return err
		}
		committed = t
		return r.threadEvents(tx, &before, &t)
	})
	if err == nil {
		r.notifyThread(committed)
	}
	return err
}

func (r *Runtime) ReadThreadContent(ctx context.Context, id string, scope transport.ContentScope, known *int64) (*transport.ContentSnapshot, error) {
	if err := r.begin(); err != nil {
		return nil, err
	}
	defer r.operations.Done()
	ctx, cancel := r.operationContext(ctx)
	defer cancel()
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if err := identifier(id); err != nil {
		return nil, err
	}
	snapshot := r.config.Store.Snapshot()
	t, err := r.cachedThread(ctx, snapshot, id)
	if err != nil {
		return nil, err
	}
	if known != nil && *known == t.Revision {
		return nil, nil
	}
	h := r.config.Harnesses[t.HarnessID]
	if h == nil {
		return nil, fmt.Errorf("unknown thread harness: %s", t.HarnessID)
	}
	var value json.RawMessage
	err = r.computeTasks(ctx, []workpool.Task{{Bytes: snapshot.RecordBytes("thread:" + id), Run: func(ctx context.Context) error {
		var err error
		value, err = h.SessionState().ProjectRenderer(bytes.Clone(t.SessionState), model.RendererScope{Kind: scope.Kind, Key: scope.Key})
		return err
	}}})
	if err != nil {
		return nil, err
	}
	if err = ctx.Err(); err != nil {
		return nil, err
	}
	return &transport.ContentSnapshot{Revision: t.Revision, Value: value}, nil
}

func (r *Runtime) Close(ctx context.Context) error {
	r.closeOnce.Do(func() {
		r.lifecycleMu.Lock()
		defer r.lifecycleMu.Unlock()
		r.mu.Lock()
		r.closed = true
		r.generationCancel()
		handles := make([]*threadHandle, 0, len(r.handles))
		for _, h := range r.handles {
			handles = append(handles, h)
		}
		r.mu.Unlock()
		var errs []error
		if r.search != nil {
			if err := r.search.Close(); err != nil {
				errs = append(errs, err)
			}
			if local, ok := r.config.Embeddings.(plugin.ManagedEmbeddings); ok {
				if err := local.Close(); err != nil {
					errs = append(errs, err)
				}
			}
		}
		if err := r.closeVoice(ctx); err != nil {
			errs = append(errs, err)
		}
		if participant, ok := r.config.Moku.(plugin.RuntimeParticipant); ok {
			if err := participant.Stop(ctx); err != nil {
				errs = append(errs, err)
			}
		}
		if r.config.Contexts != nil {
			if err := r.config.Contexts.Stop(ctx); err != nil {
				errs = append(errs, err)
			}
		}
		if participant, ok := r.config.Applications.(plugin.RuntimeParticipant); ok {
			if err := participant.Stop(ctx); err != nil {
				errs = append(errs, err)
			}
		}
		r.cancel()
		for _, h := range handles {
			if err := h.close(); err != nil {
				errs = append(errs, err)
			}
			r.settleClosed(h)
		}
		r.operations.Wait()
		r.mu.Lock()
		r.generation++
		r.mu.Unlock()
		if r.stopStore != nil {
			r.stopStore()
		}
		<-r.publisherDone
		if r.compute != nil {
			if err := r.compute.Close(ctx); err != nil {
				errs = append(errs, err)
			}
		}
		if err := r.config.Store.Flush(ctx); err != nil {
			errs = append(errs, err)
		}
		r.closeErr = errors.Join(errs...)
	})
	return r.closeErr
}
func contains(values []string, value string) bool {
	for _, v := range values {
		if v == value {
			return true
		}
	}
	return false
}
