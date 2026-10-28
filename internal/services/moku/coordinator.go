package moku

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"reflect"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

type executionScope struct {
	threadID string
	ctx      context.Context
	cancel   context.CancelFunc
}
type userAdmission struct {
	ctx      context.Context
	cancel   context.CancelFunc
	entered  bool
	delivery *voiceDelivery
}
type coordinatorEvent struct {
	record     *model.ThreadRecord
	diagnostic string
	userInput  *plugin.LifecycleEvent
	lifetime   context.Context
}
type Coordinator struct {
	readClipboardText      clipboardReader
	lifecycleMu            sync.Mutex
	config                 Configuration
	mu                     sync.Mutex
	queue                  admissionQueue
	running                bool
	stopping               bool
	ctx                    context.Context
	cancel                 context.CancelFunc
	generation             uint64
	id                     string
	applied                *SessionConfiguration
	description            *ThreadCreationDescription
	injection              *plugin.Injection
	cleanupFailure         error
	admissions             map[*userAdmission]bool
	scopes                 map[string]executionScope
	observed               map[string]string
	events                 []coordinatorEvent
	eventWake              chan struct{}
	workers                sync.WaitGroup
	unsubscribe            func()
	unsubscribeDiagnostics func()
	unsubscribeUserInputs  func()
	refreshWake            chan struct{}
	runContext             []plugin.ContextEntry
	runContextGeneration   uint64
	voice                  *voiceController
}

func New(config Configuration) (*Coordinator, error) {
	if config.Settings == nil || config.Threads == nil || config.Thread == nil || config.UpdateThread == nil || config.EnsureSession == nil || config.ReplaceSession == nil || config.OpenSession == nil || config.CloseSession == nil || config.SendSession == nil || config.SubscribeCommitted == nil {
		return nil, errors.New("Moku requires complete durable session capabilities")
	}
	if config.Workspace == "" {
		return nil, errors.New("Moku requires an isolated runtime workspace")
	}
	c := &Coordinator{config: config, admissions: make(map[*userAdmission]bool), scopes: make(map[string]executionScope), observed: make(map[string]string)}
	c.voice = newVoiceController(c)
	return c, nil
}
func (c *Coordinator) Start(ctx context.Context, start plugin.RuntimeStartContext) error {
	c.lifecycleMu.Lock()
	defer c.lifecycleMu.Unlock()
	if err := ctx.Err(); err != nil {
		return err
	}
	c.mu.Lock()
	if c.running {
		c.mu.Unlock()
		return nil
	}
	if c.stopping || c.cleanupFailure != nil {
		c.mu.Unlock()
		return errors.New("Moku cleanup must finish before restarting")
	}
	c.ctx, c.cancel = context.WithCancel(ctx)
	c.running = true
	c.generation++
	c.eventWake = make(chan struct{}, 1)
	c.refreshWake = make(chan struct{}, 1)
	c.events = nil
	c.id = ""
	c.observed = make(map[string]string)
	c.applied = nil
	c.injection = nil
	c.description = nil
	c.runContext = nil
	c.runContextGeneration = c.generation
	c.mu.Unlock()
	records, err := c.config.Threads()
	if err != nil {
		c.mu.Lock()
		c.running = false
		c.cancel()
		c.mu.Unlock()
		return err
	}

	var shellConfiguration *SessionConfiguration
	foundMoku := false
	for _, record := range records {
		if record.Moku {
			foundMoku = true
			break
		}
	}
	if !foundMoku {
		settings, revision, loadErr := c.config.Settings()
		if loadErr == nil {
			host := ""
			ids := c.harnessOrder()
			for _, id := range ids {
				h := c.config.Harnesses[id]
				if h.Descriptor().ThreadCapabilities.CanHostMoku() && (c.config.HarnessEnabled == nil || c.config.HarnessEnabled(id)) {
					host = id
					break
				}
			}
			if host == "" && len(ids) > 0 {
				host = ids[0]
			}
			if host == "" {
				loadErr = errors.New("No registered Harness")
			} else {
				configuration := SessionConfiguration{Unapplied: true, HarnessID: host, Settings: json.RawMessage(`{}`), AppliedSettings: settings, SettingsRevision: revision, Cwd: c.config.Workspace}
				shell, createErr := c.config.EnsureSession(ctx, configuration)
				loadErr = createErr
				if createErr == nil {
					records = append(records, shell)
					shellConfiguration = &configuration
				}
			}
		}
		if loadErr != nil {
			c.mu.Lock()
			c.running = false
			c.cancel()
			c.mu.Unlock()
			return loadErr
		}
	}
	for _, record := range records {
		if record.Moku {
			if err = c.settleStaleTranscript(ctx, record); err != nil {
				c.mu.Lock()
				c.running = false
				c.cancel()
				c.mu.Unlock()
				return err
			}
		}
	}
	c.mu.Lock()
	c.applied = shellConfiguration
	for _, record := range records {
		if record.MokuHistory {
			continue
		}
		if record.Moku {
			c.id = record.ID
		} else if c.config.PendingDeliveries != nil && c.config.SendDelivery != nil {
			continue
		}
		if e := record.Observation.LatestExecution; e != nil && e.Terminal() {
			c.observed[record.ID] = e.ExecutionID + ":" + e.Status
		}
	}
	c.mu.Unlock()
	if c.config.SubscribeUserThreadInputs != nil {
		lifetime := c.ctx
		c.unsubscribeUserInputs, err = c.config.SubscribeUserThreadInputs(lifetime, func(event plugin.LifecycleEvent) {
			c.enqueueEvent(coordinatorEvent{userInput: &event, lifetime: lifetime})
		})
		if err != nil {
			c.mu.Lock()
			c.running = false
			c.cancel()
			c.mu.Unlock()
			return err
		}
	}
	c.unsubscribe = c.config.SubscribeCommitted(c.committed)
	if c.config.SubscribeDiagnostics != nil {
		c.unsubscribeDiagnostics = c.config.SubscribeDiagnostics(func(message string) { c.enqueueEvent(coordinatorEvent{diagnostic: message}) })
	}
	c.launch(func(ctx context.Context) { c.eventsLoop(ctx) })
	if c.config.PendingDeliveries != nil && c.config.SendDelivery != nil {
		c.launch(c.deliveryLoop)
	}
	c.launch(func(ctx context.Context) { c.refreshLoop(ctx) })
	if start.Reason == "startup" {
		c.launch(func(ctx context.Context) {
			if err := c.queue.Lock(ctx); err != nil {
				return
			}
			defer c.queue.Unlock()
			// Startup recovery has no user input to admit. Let discovery run
			// outside the admission gate; Runtime fences the resulting settings
			// before configuring a session. A concurrent edit wins that race.
			if _, err := c.ensurePrepared(ctx); err != nil {
				var conflict *model.Error
				if ctx.Err() == nil && !(errors.As(err, &conflict) && conflict.Code == "REVISION_CONFLICT") {
					c.report("moku-recovery", err)
				}
			}
		})
	}
	return nil
}
func (c *Coordinator) Stop(ctx context.Context) error {
	c.lifecycleMu.Lock()
	defer c.lifecycleMu.Unlock()
	c.mu.Lock()
	if !c.running && !c.stopping {
		err := c.cleanupFailure
		c.mu.Unlock()
		return err
	}
	c.running = false
	c.stopping = true
	if c.cancel != nil {
		c.cancel()
	}
	for admission := range c.admissions {
		admission.cancel()
	}
	for _, scope := range c.scopes {
		scope.cancel()
	}
	c.scopes = make(map[string]executionScope)
	c.mu.Unlock()
	if c.unsubscribe != nil {
		c.unsubscribe()
		c.unsubscribe = nil
	}
	if c.unsubscribeDiagnostics != nil {
		c.unsubscribeDiagnostics()
		c.unsubscribeDiagnostics = nil
	}
	if c.unsubscribeUserInputs != nil {
		c.unsubscribeUserInputs()
		c.unsubscribeUserInputs = nil
	}
	c.voice.mu.Lock()
	c.voice.discardReconfigurationLocked()
	c.voice.mu.Unlock()
	voiceErr := c.voice.stop(ctx)
	done := make(chan struct{})
	go func() { c.workers.Wait(); close(done) }()
	select {
	case <-ctx.Done():
		return errors.Join(voiceErr, ctx.Err())
	case <-done:
	}
	if err := c.queue.Lock(ctx); err != nil {
		return errors.Join(voiceErr, err)
	}
	defer c.queue.Unlock()
	c.mu.Lock()
	id := c.id
	c.mu.Unlock()
	var closeErr error
	if id != "" {
		closeErr = c.config.CloseSession(ctx, id)
	}
	c.mu.Lock()
	c.injection = nil
	c.description = nil
	c.stopping = false
	c.cleanupFailure = errors.Join(c.cleanupFailure, closeErr)
	c.mu.Unlock()
	return errors.Join(voiceErr, closeErr)
}
func (c *Coordinator) launch(run func(context.Context)) bool {
	c.mu.Lock()
	if !c.running || c.ctx.Err() != nil {
		c.mu.Unlock()
		return false
	}
	ctx := c.ctx
	c.workers.Add(1)
	c.mu.Unlock()
	go func() { defer c.workers.Done(); run(ctx) }()
	return true
}
func (c *Coordinator) begin(ctx context.Context) (context.Context, func(), error) {
	if err := ctx.Err(); err != nil {
		return nil, nil, err
	}
	c.mu.Lock()
	if !c.running || c.cleanupFailure != nil || c.ctx.Err() != nil {
		c.mu.Unlock()
		return nil, nil, errors.New("Moku participant is not running")
	}
	service := c.ctx
	c.workers.Add(1)
	c.mu.Unlock()
	linked, cancel := context.WithCancel(ctx)
	stop := context.AfterFunc(service, cancel)
	if service.Err() != nil {
		cancel()
	}
	return linked, func() { stop(); cancel(); c.workers.Done() }, nil
}
func (c *Coordinator) Invoke(ctx context.Context, channel string, args []json.RawMessage) (any, error) {
	switch channel {
	case "moku:submit":
		if len(args) != 1 {
			return nil, errors.New("moku:submit expects one request")
		}
		var request SubmitRequest
		if err := model.Unmarshal(args[0], &request); err != nil {
			return nil, err
		}
		return nil, c.Submit(ctx, request)
	case "moku:clear":
		if len(args) != 0 {
			return nil, errors.New("moku:clear takes no arguments")
		}
		return nil, c.Clear(ctx)
	case "moku:cancel":
		if len(args) != 1 {
			return nil, errors.New("moku:cancel expects the observed cancellation identity")
		}
		var request model.CancellationRequest
		if err := model.Unmarshal(args[0], &request); err != nil {
			return nil, err
		}
		return c.CancelTarget(ctx, request)
	case "moku:stage-attachments":
		if len(args) != 1 || c.config.StageAttachments == nil {
			return nil, errors.New("Moku attachment staging unavailable")
		}
		return c.config.StageAttachments(ctx, args[0])
	case "moku:voice", "moku:voice-events":
		if len(args) != 1 {
			return nil, errors.New("voice expects one request")
		}
		var action struct {
			Action string `json:"action"`
		}
		if json.Unmarshal(args[0], &action) != nil {
			return nil, errors.New("Invalid voice request")
		}
		if (channel == "moku:voice-events") != (action.Action == "poll" || action.Action == "heartbeat") {
			return nil, errors.New("Voice command action does not match channel")
		}
		return c.voice.command(ctx, args[0])
	default:
		return nil, model.NewError("UNKNOWN_COMMAND", "Unknown Moku command")
	}
}
func (c *Coordinator) current() (model.ThreadRecord, error) {
	c.mu.Lock()
	id := c.id
	c.mu.Unlock()
	if id != "" {
		return c.config.Thread(id)
	}
	records, err := c.config.Threads()
	if err != nil {
		return model.ThreadRecord{}, err
	}
	for _, record := range records {
		if record.Moku {
			return record, nil
		}
	}
	return model.ThreadRecord{}, errors.New("Moku session is not initialized")
}
func (c *Coordinator) Submit(ctx context.Context, request SubmitRequest) error {
	return c.submit(ctx, request, nil, "")
}
func (c *Coordinator) submit(ctx context.Context, request SubmitRequest, delivery *voiceDelivery, voiceContext string) error {
	ctx, finish, err := c.begin(ctx)
	if err != nil {
		return err
	}
	defer finish()
	inputRaw, encodeErr := json.Marshal(request.Input)
	if encodeErr != nil {
		return encodeErr
	}
	validated, parseErr := model.ParsePublicAgentInput(inputRaw)
	if parseErr != nil {
		return parseErr
	}
	request.Input = validated
	if c.config.ClaimThreadInput != nil {
		record, readErr := c.current()
		if readErr != nil {
			return readErr
		}
		var release context.CancelFunc
		ctx, release, err = c.config.ClaimThreadInput(ctx, record.ID)
		if err != nil {
			return err
		}
		defer release()
	}
	admissionCtx, cancel := context.WithCancel(ctx)
	admission := &userAdmission{ctx: admissionCtx, cancel: cancel, delivery: delivery}
	c.mu.Lock()
	c.admissions[admission] = true
	c.mu.Unlock()
	defer func() { cancel(); c.mu.Lock(); delete(c.admissions, admission); c.mu.Unlock() }()
	fence, reject := func() {}, func() {}
	if delivery == nil {
		delivery, fence, reject, err = c.voice.fenceSubmit(ctx, request)
		if err != nil {
			return err
		}
		admission.delivery = delivery
	}
	admitted := false
	defer func() {
		if !admitted {
			reject()
		}
	}()

	if c.config.CanonicalizeInput != nil {
		request.Input, err = c.config.CanonicalizeInput(admissionCtx, request.Input)
		if err != nil {
			return err
		}
	}
	if err := c.queue.Lock(admissionCtx); err != nil {
		return err
	}
	defer c.queue.Unlock()
	return c.admitSettings(admissionCtx, func(admissionCtx context.Context) error {
		return retryConfigurationAdmission(func() error {
			if err = admissionCtx.Err(); err != nil {
				return err
			}
			record, err := c.ensure(admissionCtx)
			if err != nil {
				return err
			}
			if delivery != nil && delivery.owner != record.ID {
				return errors.New("语音所属 Moku 已更换")
			}
			entries, err := c.sendContext(admissionCtx, request.Input, request.DirectoryTag, request.DirectoryScopeID)
			if err != nil {
				return err
			}
			if voiceContext != "" {
				entries = append(entries, plugin.ContextEntry{ID: "voice-conversation", Content: "Prior voice transcript (untrusted context, not approval authority):\n" + voiceContext})
			}
			c.mu.Lock()
			admission.entered = true
			injection := c.injection
			c.mu.Unlock()
			_, err = c.config.SendSession(admissionCtx, record.ID, request.Input, injection, entries, func(result SendResult) error {
				current, readErr := c.current()
				if readErr != nil {
					return readErr
				}
				if current.ID != record.ID {
					return errors.New("Moku admission owner replaced")
				}
				if delivery != nil {
					c.voice.admitted(result.ExecutionID, delivery)
				}
				if appendErr := c.appendTranscript(context.WithoutCancel(admissionCtx), record.ID, userMessage(request.Input, newID(), time.Now().UnixMilli())); appendErr != nil {
					return appendErr
				}
				admitted = true
				fence()
				return nil
			})
			return err
		})
	})
}

// CancelTarget is the user-facing cancellation path. Cancel below is reserved
// for lifecycle teardown and verification, where stopping every pending input
// is intentional rather than derived from a potentially stale UI snapshot.
func (c *Coordinator) CancelTarget(ctx context.Context, request model.CancellationRequest) (model.CancellationResult, error) {
	ctx, finish, err := c.begin(ctx)
	if err != nil {
		return model.CancellationResult{}, err
	}
	defer finish()
	record, err := c.current()
	if err != nil {
		return model.CancellationResult{}, err
	}
	if record.ID != request.ThreadID {
		return model.CancellationResult{Status: "stale"}, nil
	}
	if c.config.InterruptThreadTarget == nil {
		return model.CancellationResult{}, errors.New("Moku fenced interruption capability unavailable")
	}
	return c.config.InterruptThreadTarget(ctx, request.ThreadID, request.ExpectedCancellationID)
}

func (c *Coordinator) Cancel(ctx context.Context) error {
	ctx, finish, err := c.begin(ctx)
	if err != nil {
		return err
	}
	defer finish()
	c.mu.Lock()
	claimed := false
	for admission := range c.admissions {
		claimed = true
		admission.cancel()
	}
	c.mu.Unlock()
	record, err := c.current()
	if err != nil {
		if claimed {
			return nil
		}
		return err
	}
	execution := record.Observation.LatestExecution
	if (execution == nil || execution.Terminal()) && claimed {
		return nil
	}
	if execution == nil || execution.Terminal() {
		return errors.New("Moku 当前没有 active Execution")
	}
	if c.config.InterruptThread == nil {
		return errors.New("Moku interruption capability unavailable")
	}
	return c.config.InterruptThread(ctx, record.ID)
}
func (c *Coordinator) Clear(ctx context.Context) error {
	ctx, finish, err := c.begin(ctx)
	if err != nil {
		return err
	}
	defer finish()
	c.mu.Lock()
	pending := len(c.admissions) > 0
	c.mu.Unlock()
	if pending {
		return errors.New("Moku 正在运行，停止后才能清空 session")
	}
	if err := c.queue.Lock(ctx); err != nil {
		return err
	}
	defer c.queue.Unlock()
	return c.admitSettings(ctx, func(ctx context.Context) error {
		record, err := c.current()
		if err != nil {
			return err
		}
		c.mu.Lock()
		pending = len(c.admissions) > 0
		c.mu.Unlock()
		if pending || live(record) {
			return errors.New("Moku 正在运行，停止后才能清空 session")
		}
		settings, revision, err := c.config.Settings()
		if err == nil && c.config.PrepareSettings != nil {
			settings, revision, err = c.config.PrepareSettings(ctx, record.HarnessID)
		}
		if err != nil {
			return err
		}
		configuration, err := c.resolveHost(ctx, settings, revision, record.HarnessID)
		if err != nil {
			return err
		}
		c.voice.mu.Lock()
		c.voice.discardReconfigurationLocked()
		c.voice.mu.Unlock()
		if err = c.voice.stop(ctx); err != nil {
			return err
		}
		replacement, err := c.config.ReplaceSession(ctx, record.ID, configuration)
		if err != nil {
			return err
		}
		c.installConfiguration(replacement.ID, configuration)
		return nil
	})
}
func (c *Coordinator) Respond(ctx context.Context, response model.RespondRequest) error {
	ctx, finish, err := c.begin(ctx)
	if err != nil {
		return err
	}
	defer finish()
	if err := c.queue.Lock(ctx); err != nil {
		return err
	}
	defer c.queue.Unlock()
	return c.admitSettings(ctx, func(ctx context.Context) error {
		record, err := c.ensure(ctx)
		if err != nil {
			return err
		}
		if c.config.RespondThread == nil {
			return errors.New("Moku interaction response unavailable")
		}
		return c.config.RespondThread(ctx, record.ID, response)
	})
}
func (c *Coordinator) admitSettings(ctx context.Context, operation func(context.Context) error) error {
	if c.config.WithSettingsAdmission != nil {
		return c.config.WithSettingsAdmission(ctx, operation)
	}
	return operation(ctx)
}
func (c *Coordinator) ensure(ctx context.Context) (record model.ThreadRecord, err error) {
	err = c.admitSettings(ctx, func(ctx context.Context) error { record, err = c.ensurePrepared(ctx); return err })
	return
}
func (c *Coordinator) ensurePrepared(ctx context.Context) (model.ThreadRecord, error) {
	if err := ctx.Err(); err != nil {
		return model.ThreadRecord{}, err
	}
	settings, revision, err := c.config.Settings()
	if err != nil {
		return model.ThreadRecord{}, err
	}
	current, currentErr := c.current()
	if (currentErr != nil || !live(current)) && c.config.PrepareSettings != nil {
		settings, revision, err = c.config.PrepareSettings(ctx, current.HarnessID)
		if err != nil {
			return current, err
		}
	}
	c.mu.Lock()
	applied := c.applied
	c.mu.Unlock()
	if currentErr != nil {
		configuration, err := c.resolveHost(ctx, settings, revision, "")
		if err != nil {
			return model.ThreadRecord{}, err
		}
		current, err = c.config.EnsureSession(ctx, configuration)
		if err != nil {
			return current, err
		}
		c.installConfiguration(current.ID, configuration)
		applied = &configuration
	} else if applied == nil {
		configuration := SessionConfiguration{HarnessID: current.HarnessID, Settings: current.Settings, AppliedSettings: settings, SettingsRevision: revision, Cwd: c.config.Workspace}
		if c.config.ReadSessionConfiguration != nil {
			stored, storedErr := c.config.ReadSessionConfiguration()
			if storedErr != nil {
				return current, storedErr
			}
			configuration = stored
		}
		c.installConfiguration(current.ID, configuration)
		applied = &configuration
	}
	if !live(current) && applied != nil && (applied.Unapplied || !sameMokuSettings(applied.AppliedSettings, settings)) {
		profileChanged := applied.Unapplied || !reflect.DeepEqual(applied.AppliedSettings.Moku.ExecutionHarnesses[current.HarnessID], settings.Moku.ExecutionHarnesses[current.HarnessID])
		resolveHost := applied.Unapplied || profileChanged || settings.Moku.HostHarnessPreference == "auto" || settings.Moku.HostHarnessPreference != applied.AppliedSettings.Moku.HostHarnessPreference
		configuration := SessionConfiguration{HarnessID: current.HarnessID, Settings: current.Settings, AppliedSettings: settings, SettingsRevision: revision, Cwd: current.Cwd}
		if resolveHost {
			resolved, resolveErr := c.resolveHost(ctx, settings, revision, current.HarnessID)
			if resolveErr != nil {
				return current, resolveErr
			}
			configuration = resolved
			if configuration.HarnessID == current.HarnessID && !profileChanged {
				configuration.Settings = current.Settings
			}
		}
		if configuration.HarnessID != current.HarnessID {
			if err = c.voice.stop(ctx); err != nil {
				return current, err
			}
			// A host-harness change keeps Moku's own milestone history. Only an
			// explicit history reset starts with no note.
			configuration.PreserveNote = true
			configuration.PreserveHistory = true
			current, err = c.config.ReplaceSession(ctx, current.ID, configuration)
			if err != nil {
				return current, err
			}
		} else {
			if c.config.ConfigureSession == nil {
				return current, errors.New("Moku configuration persistence unavailable")
			}
			for {
				c.voice.captureReplies(current.ID)
				err = c.config.ConfigureSession(ctx, current.ID, current.Revision, configuration)
				if err == nil {
					break
				}
				var conflict *model.Error
				if !errors.As(err, &conflict) || conflict.Code != "REVISION_CONFLICT" {
					return current, err
				}
				latest, readErr := c.config.Thread(current.ID)
				if readErr != nil || !latest.Moku || latest.ID != current.ID || latest.Revision == current.Revision {
					return current, err
				}
				current = latest
				if live(current) {
					return current, nil
				}
				if profileChanged {
					resolved, resolveErr := c.resolveHost(ctx, settings, revision, current.HarnessID)
					if resolveErr != nil {
						return current, resolveErr
					}
					configuration = resolved
				} else {
					configuration.Settings = current.Settings
				}
			}
			if err = c.voice.stopForConfiguration(ctx, current.ID); err != nil {
				return current, err
			}
			if err = c.config.CloseSession(ctx, current.ID); err != nil {
				c.mu.Lock()
				c.cleanupFailure = err
				c.mu.Unlock()
				return current, err
			}
			current, err = c.config.Thread(current.ID)
			if err != nil {
				return current, err
			}
		}
		c.installConfiguration(current.ID, configuration)
		applied = &configuration
	}
	c.mu.Lock()
	injection := c.injection
	previousDescription := c.description
	c.mu.Unlock()
	var prepared *ThreadCreationDescription
	if injection != nil && !live(current) && !c.voice.ownsNative(current.ID) {
		description, describeErr := c.describeTargets(ctx, applied.AppliedSettings)
		if describeErr != nil {
			var unavailable *targetRefreshUnavailable
			if ctx.Err() == nil && errors.As(describeErr, &unavailable) {
				c.report("moku-settings-refresh", describeErr)
				return c.config.Thread(current.ID)
			}
			return current, describeErr
		}
		if previousDescription != nil {
			for _, adopted := range previousDescription.TargetHarnessIDs {
				found := false
				for _, target := range description.TargetHarnessIDs {
					if target == adopted {
						found = true
					}
				}
				if !found {
					c.report("moku-settings-refresh", fmt.Errorf("已采用的 Moku Target Harness 暂时不可用: %s", adopted))
					return c.config.Thread(current.ID)
				}
			}
		}
		if !reflect.DeepEqual(previousDescription, &description) {
			c.voice.captureReplies(current.ID)
			if err = c.voice.stopForConfiguration(ctx, current.ID); err != nil {
				return current, err
			}
			if err = c.config.CloseSession(ctx, current.ID); err != nil {
				c.mu.Lock()
				c.cleanupFailure = err
				c.mu.Unlock()
				return current, err
			}
			c.installConfiguration(current.ID, *applied)
			prepared = &description
			injection = nil
		}
	}
	if injection == nil {
		description := ThreadCreationDescription{}
		var describeErr error
		if prepared != nil {
			description = *prepared
		} else {
			description, describeErr = c.describeTargets(ctx, applied.AppliedSettings)
		}
		if describeErr != nil {
			return current, describeErr
		}
		entries, collectErr := c.collectContext(ctx, "session-start", applied.AppliedSettings)
		if collectErr != nil {
			return current, collectErr
		}
		instructions := []string{DefaultSystemPrompt(), description.Instructions}
		if guidance := valueOrEmpty(applied.AppliedSettings.Moku.RoutingGuidance); guidance != "" {
			instructions = append(instructions, "Model routing guidance:\n"+guidance)
		}
		tools := c.tools(current.ID, description)
		injection = &plugin.Injection{Instructions: instructions, ContextEntries: entries, Tools: &plugin.ToolInjection{Mode: "exclusive", Bindings: tools}}
		if err = c.config.OpenSession(ctx, current.ID, injection); err != nil {
			return current, err
		}
		if c.config.SetNativeAdmission != nil {
			ownerID := current.ID
			if err = c.config.SetNativeAdmission(ownerID, func(ctx context.Context) error { return c.voice.syncContext(ctx, ownerID) }); err != nil {
				return current, errors.Join(err, c.config.CloseSession(context.WithoutCancel(ctx), ownerID))
			}
		}
		if err = ctx.Err(); err != nil {
			cleanupErr := c.config.CloseSession(context.WithoutCancel(ctx), current.ID)
			return current, errors.Join(err, cleanupErr)
		}
		c.mu.Lock()
		c.description = &description
		c.injection = injection
		c.mu.Unlock()
	}
	return c.config.Thread(current.ID)
}
func (c *Coordinator) installConfiguration(id string, configuration SessionConfiguration) {
	c.mu.Lock()
	for _, scope := range c.scopes {
		scope.cancel()
	}
	c.scopes = make(map[string]executionScope)
	c.id = id
	c.applied = &configuration
	c.injection = nil
	c.description = nil
	c.generation++
	c.runContext = nil
	c.runContextGeneration = c.generation
	wake := c.refreshWake
	c.mu.Unlock()
	if wake != nil {
		select {
		case wake <- struct{}{}:
		default:
		}
	}
}
func (c *Coordinator) resolveHost(ctx context.Context, settings model.Settings, revision int64, current string) (SessionConfiguration, error) {
	preference := settings.Moku.HostHarnessPreference
	candidates := []string{}
	if preference != "" && preference != "auto" {
		candidates = append(candidates, preference)
	} else {
		if current != "" {
			candidates = append(candidates, current)
		}
		ids := c.harnessOrder()
		for _, id := range ids {
			if id != current {
				candidates = append(candidates, id)
			}
		}
	}
	failures := []error{}
	for _, id := range candidates {
		h := c.config.Harnesses[id]
		if c.config.HarnessEnabled != nil && !c.config.HarnessEnabled(id) {
			failures = append(failures, fmt.Errorf("%s is disabled", id))
			continue
		}
		if h == nil || !h.Descriptor().ThreadCapabilities.CanHostMoku() {
			failures = append(failures, fmt.Errorf("%s cannot host Moku", id))
			continue
		}
		merged := mergedSettings(settings, id, true)
		if available, err := c.available(ctx, h, merged, "exclusive"); err != nil || !available.Available {
			if available.RequiresExplicitSelection && id == current {
				return SessionConfiguration{}, fmt.Errorf("当前 Moku Host 配置不可用（%s: %s）。请在设置中选择兼容的 Host 或模型。", id, available.Reason)
			}
			if err == nil {
				err = errors.New(available.Reason)
			}
			failures = append(failures, fmt.Errorf("%s: %w", id, err))
			continue
		}
		defaults, err := h.Settings().DefaultThread(merged)
		if err != nil {
			failures = append(failures, err)
			continue
		}
		request := plugin.ResolveSettingsRequest{Merged: defaults, Cwd: c.config.Workspace}
		if id == current {
			if record, readErr := c.current(); readErr == nil && record.HarnessID == id {
				request.Existing = record.Settings
				request.SessionState = record.SessionState
			}
		}
		resolved, err := h.Settings().ResolveThread(ctx, request)
		if err != nil {
			failures = append(failures, err)
			continue
		}
		return SessionConfiguration{HarnessID: id, Settings: resolved, AppliedSettings: settings, SettingsRevision: revision, Cwd: c.config.Workspace}, nil
	}
	return SessionConfiguration{}, errors.Join(append([]error{errors.New("Moku 没有可用的 Host Harness")}, failures...)...)
}
func (c *Coordinator) available(ctx context.Context, h plugin.Harness, settings json.RawMessage, modes ...string) (plugin.Availability, error) {
	mode := ""
	if len(modes) > 0 {
		mode = modes[0]
	}
	if probe, ok := h.(plugin.AvailabilityProbe); ok {
		return probe.Probe(ctx, plugin.SettingsRequest{Settings: settings, Cwd: c.config.Workspace}, mode)
	}
	installation, err := h.Detect(ctx, c.config.Workspace)
	return plugin.Availability{Available: installation.Status == "available" || installation.Status == "installed", Reason: installation.Message}, err
}
func mergedSettings(settings model.Settings, id string, execution bool) json.RawMessage {
	if execution {
		if value, exists := settings.Moku.ExecutionHarnesses[id]; exists {
			return model.CloneRaw(value)
		}
	}
	if value, exists := settings.Harnesses[id]; exists {
		return model.CloneRaw(value)
	}
	return json.RawMessage(`{}`)
}

func live(record model.ThreadRecord) bool {
	return record.Observation.BackgroundWork != nil || (record.Observation.LatestExecution != nil && !record.Observation.LatestExecution.Terminal())
}
func valueOrEmpty(value *string) string {
	if value == nil {
		return ""
	}
	return *value
}
func newID() string {
	var value [16]byte
	if _, err := rand.Read(value[:]); err != nil {
		panic(err)
	}
	return hex.EncodeToString(value[:])
}
func (c *Coordinator) report(kind string, err error) {
	defer func() { _ = recover() }()
	if err != nil && c.config.ReportFailure != nil {
		c.config.ReportFailure(kind, err)
	}
}
func textInput(value string) model.AgentInput {
	return model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: strings.TrimSpace(value)}}}
}

func sameMokuSettings(a, b model.Settings) bool {
	return reflect.DeepEqual(a.Harnesses, b.Harnesses) && reflect.DeepEqual(a.Moku.ExecutionHarnesses, b.Moku.ExecutionHarnesses) && a.Moku.HostHarnessPreference == b.Moku.HostHarnessPreference && reflect.DeepEqual(a.Moku.TargetHarnessIDs, b.Moku.TargetHarnessIDs) && reflect.DeepEqual(a.Moku.RoutingGuidance, b.Moku.RoutingGuidance)
}

func (c *Coordinator) harnessOrder() []string {
	ids := []string{}
	seen := map[string]bool{}
	for _, id := range []string{"pi", "codex", "claude", "opencode"} {
		if c.config.Harnesses[id] != nil {
			ids = append(ids, id)
			seen[id] = true
		}
	}
	extra := []string{}
	for id := range c.config.Harnesses {
		if !seen[id] {
			extra = append(extra, id)
		}
	}
	sort.Strings(extra)
	return append(ids, extra...)
}
