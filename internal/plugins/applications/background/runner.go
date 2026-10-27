package background

import (
	"context"
	"errors"
	"sync"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

const maxAttempts = 3
const runTimeout = 10 * time.Minute
const batchSize = 64

type BatchRequest struct {
	BatchID  string
	Events   []plugin.LifecycleEvent
	Steering bool
}
type BatchPlan struct {
	Events []plugin.LifecycleEvent
	Skip   bool
	Finish func(context.Context, string) error
}
type Behavior struct {
	ID           string
	Consumer     plugin.LifecycleConsumerDefinition
	Instructions []string
	Tools        func(context.Context) []plugin.ToolBinding
	Message      func(context.Context, BatchRequest) (model.AgentInput, error)
	Initialize   func(context.Context) error
	// LazyInitialize defers Initialize until the first pending event or work.
	// Scope agents use it so an idle scope does not inventory or open a model
	// session at startup.
	LazyInitialize bool
	// IdleDispose closes the native session after each settled batch. The
	// durable runner and its subscription stay alive and reopen on the next
	// event, so an idle scope does not retain a model process.
	IdleDispose     bool
	Prepare         func(context.Context, BatchRequest) (BatchPlan, error)
	AcceptsSteering func(plugin.LifecycleEvent) bool
}

// Runner serializes one durable inbox and private native session. Only admission
// joins new events to work; receipts and acknowledgment remain owned by the host.
type Runner struct {
	behavior      Behavior
	consumer      plugin.LifecycleConsumer
	sessions      plugin.BackgroundSessionsCapability
	configuration plugin.BackgroundConfigurationCapability
	environment   plugin.BackgroundEnvironmentCapability
	mu            sync.Mutex
	ctx           context.Context
	cancel        context.CancelFunc
	done          chan struct{}
	wake          chan struct{}
	unsubscribe   func()
	handle        plugin.PrivateSessionHandle
	handleCancel  context.CancelFunc
	cleanupError  error
	initialized   bool
}

func NewRunner(ctx plugin.BackgroundAgentContext, behavior Behavior) (*Runner, error) {
	sessions, err := plugin.Require[plugin.BackgroundSessionsCapability](ctx.Capabilities, plugin.BackgroundSessionsCapabilityKey)
	if err != nil {
		return nil, err
	}
	configuration, err := plugin.Require[plugin.BackgroundConfigurationCapability](ctx.Capabilities, plugin.BackgroundConfigurationCapabilityKey)
	if err != nil {
		return nil, err
	}
	lifecycle, err := plugin.Require[plugin.LifecycleCapability](ctx.Capabilities, plugin.LifecycleCapabilityKey)
	if err != nil {
		return nil, err
	}
	environment, err := plugin.Require[plugin.BackgroundEnvironmentCapability](ctx.Capabilities, plugin.BackgroundEnvironmentCapabilityKey)
	if err != nil {
		return nil, err
	}
	consumer, err := lifecycle.Register(behavior.Consumer)
	if err != nil {
		return nil, err
	}
	return &Runner{behavior: behavior, consumer: consumer, sessions: sessions, configuration: configuration, environment: environment, wake: make(chan struct{}, 1)}, nil
}
func (r *Runner) WriteOptions(ctx context.Context, invocationID string) (plugin.DomainCommandOptions, error) {
	if err := ctx.Err(); err != nil {
		return plugin.DomainCommandOptions{}, err
	}
	work := r.consumer.Work()
	if work == nil {
		return plugin.DomainCommandOptions{}, errors.New("No active background batch")
	}
	if invocationID == "" {
		invocationID = UUID()
	}
	return plugin.DomainCommandOptions{RequestID: invocationID, Batch: &plugin.BatchWriteContext{ConsumerID: r.consumer.ID(), BatchID: work.ID, InvocationID: invocationID}}, nil
}
func (r *Runner) ReadEvents(ctx context.Context, ids []string) ([]plugin.LifecycleHistoryEntry, error) {
	result := []plugin.LifecycleHistoryEntry{}
	cursor := ""
	for {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		page, err := r.consumer.Read(plugin.LifecycleHistoryQuery{PageRequest: plugin.PageRequest{Cursor: cursor, Limit: 1000}, EventIDs: ids})
		if err != nil {
			return nil, err
		}
		result = append(result, page.Items...)
		if page.NextCursor == "" {
			return result, nil
		}
		if page.NextCursor == cursor {
			return nil, errors.New("lifecycle history cursor did not advance")
		}
		cursor = page.NextCursor
	}
}
func (r *Runner) Start(ctx context.Context, _ plugin.RuntimeStartContext) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.cancel != nil {
		return nil
	}
	if r.cleanupError != nil {
		return r.cleanupError
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	lifetime, cancel := context.WithCancel(ctx)
	r.ctx = lifetime
	r.cancel = cancel
	r.done = make(chan struct{})
	r.initialized = false
	unsubscribe, err := r.consumer.Subscribe(lifetime, func(plugin.LifecycleNotification) { r.notify() }, nil)
	if err != nil {
		cancel()
		r.cancel = nil
		return err
	}
	r.unsubscribe = unsubscribe
	go r.loop(lifetime, r.done)
	r.notify()
	return nil
}
func (r *Runner) notify() {
	select {
	case r.wake <- struct{}{}:
	default:
	}
}
func (r *Runner) Stop(ctx context.Context) error {
	r.mu.Lock()
	cancel := r.cancel
	done := r.done
	handle := r.handle
	unsubscribe := r.unsubscribe
	cleanupError := r.cleanupError
	r.mu.Unlock()
	if cancel == nil {
		// A failed Close leaves the handle owned by this runner. Repeated stops
		// must not let the host discard that participant as successfully drained.
		return cleanupError
	}
	cancel()
	if unsubscribe != nil {
		unsubscribe()
	}
	// Interrupt before joining a send/open that may be waiting for native I/O.
	if handle != nil && busy(handle.Observation()) {
		cleanup, cancelCleanup := context.WithTimeout(context.WithoutCancel(ctx), 30*time.Second)
		if err := handle.Interrupt(cleanup, nil); err != nil {
			r.log("stop-interrupt", err)
		}
		cancelCleanup()
	}
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-done:
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	r.cancel = nil
	r.unsubscribe = nil
	return r.cleanupError
}
func (r *Runner) loop(ctx context.Context, done chan struct{}) {
	defer close(done)
	defer func() {
		if err := r.dispose(); err != nil {
			r.mu.Lock()
			r.cleanupError = errors.Join(r.cleanupError, err)
			r.mu.Unlock()
		}
	}()
	for {
		select {
		case <-ctx.Done():
			return
		case <-r.wake:
		}
		for ctx.Err() == nil {
			pending, err := r.consumer.Pending(plugin.PendingEventsQuery{Limit: 1})
			if err != nil {
				r.log("pending", err)
				if !wait(ctx, 30*time.Second) {
					return
				}
				continue
			}
			work := r.consumer.Work()
			if lifecycle, ok := r.consumer.(interface{ ServiceDraining() bool }); ok && lifecycle.ServiceDraining() {
				// A current native execution may finish and settle its batch. A
				// queued/new batch stays durable without consuming retry attempts.
				r.mu.Lock()
				handle := r.handle
				r.mu.Unlock()
				if work == nil || handle == nil || !busy(handle.Observation()) {
					if !wait(ctx, 500*time.Millisecond) {
						return
					}
					continue
				}
			}
			// A lazy agent stays uninitialized while idle by design; it must
			// still settle the loop instead of polling for work every tick.
			if work == nil && len(pending) == 0 && (r.initialized || r.behavior.LazyInitialize) {
				break
			}
			delay := 50 * time.Millisecond
			if work != nil {
				remaining := time.Until(time.UnixMilli(work.NextAttemptAt))
				if remaining > delay {
					delay = remaining
				}
			}
			if !wait(ctx, delay) {
				return
			}
			if err = r.process(ctx); err != nil {
				if ctx.Err() == nil {
					r.log("process", err)
				}
				if !wait(ctx, 30*time.Second) {
					return
				}
			}
		}
	}
}
func wait(ctx context.Context, duration time.Duration) bool {
	timer := time.NewTimer(duration)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-timer.C:
		return true
	}
}
func (r *Runner) process(shutdown context.Context) (returned error) {
	started := time.Now()
	stage := "initialize"
	batch := false
	defer func() {
		// Before admission there is no durable attempt count. The batch error
		// handler below owns diagnostics once work has been acquired.
		if returned != nil && !batch {
			outcome := "failed"
			if shutdown.Err() != nil {
				outcome = "cancelled"
			}
			r.diagnose(outcome, stage, -1, started, returned)
		}
	}()
	ctx, cancel := context.WithTimeout(shutdown, runTimeout)
	defer cancel()
	defer func() {
		if returned != nil || !r.behavior.IdleDispose {
			return
		}
		if err := r.dispose(); err != nil {
			returned = err
		}
	}()
	if !r.initialized {
		if r.behavior.LazyInitialize && r.consumer.Work() == nil {
			pending, err := r.consumer.Pending(plugin.PendingEventsQuery{Limit: 1})
			if err != nil {
				return err
			}
			if len(pending) == 0 {
				return nil
			}
		}
		if r.behavior.Initialize != nil {
			if err := r.behavior.Initialize(ctx); err != nil {
				return err
			}
		}
		r.initialized = true
	}
	work := r.consumer.Work()
	if work == nil {
		stage = "pending"
		events, err := r.consumer.Pending(plugin.PendingEventsQuery{Limit: batchSize})
		if err != nil {
			return err
		}
		if len(events) == 0 {
			return r.settleStale(ctx)
		}
		ids := []string{}
		for _, event := range events {
			ids = append(ids, event.ID)
		}
		stage = "begin"
		created, err := r.consumer.Begin(ctx, ids)
		if err != nil {
			var failure *model.Error
			if errors.As(err, &failure) && failure.Code == "SERVICE_DRAINING" {
				return nil
			}
			return err
		}
		work = &created
	}
	counted := false
	batch = true
	var plan BatchPlan
	finish := func(outcome string) error {
		stage = "finish"
		current := r.consumer.Work()
		if current == nil || current.ID != work.ID {
			return errors.New("Background batch replaced")
		}
		if plan.Finish != nil {
			if err := plan.Finish(ctx, outcome); err != nil {
				return err
			}
		}
		return r.consumer.Settle(ctx, work.ID, outcome)
	}
	defer func() {
		if returned == nil {
			return
		}
		var failure *model.Error
		if errors.As(returned, &failure) && failure.Code == "SERVICE_DRAINING" {
			// Drain can win after the loop's preflight. Preserve the admitted
			// inbox and roll back only this unstarted attempt; no work failed.
			if counted {
				work.Attempts--
				returned = r.updateWork(shutdown, work)
			} else {
				returned = nil
			}
			return
		}
		if shutdown.Err() != nil {
			r.diagnose("cancelled", stage, work.Attempts, started, returned)
			returned = nil
			return
		}
		r.diagnose("failed", stage, work.Attempts, started, returned)
		r.mu.Lock()
		handle := r.handle
		r.mu.Unlock()
		if handle != nil {
			cleanup, cleanupCancel := context.WithTimeout(shutdown, 30*time.Second)
			if err := handle.Interrupt(cleanup, nil); err != nil {
				r.log("cleanup-interrupt", err)
			}
			cleanupCancel()
			if err := r.dispose(); err != nil {
				returned = errors.Join(returned, err)
				return
			}
		}
		current := r.consumer.Work()
		if current == nil || current.ID != work.ID {
			returned = nil
			return
		}
		if !counted && current.Attempts >= maxAttempts {
			returned = finish("failed")
			return
		}
		attempts := current.Attempts
		if !counted {
			attempts++
		}
		exponent := attempts
		if exponent > 5 {
			exponent = 5
		}
		returned = r.consumer.Update(shutdown, plugin.LifecycleWorkUpdate{ID: current.ID, EventIDs: current.EventIDs, Attempts: attempts, NextAttemptAt: time.Now().Add(5 * time.Second * time.Duration(1<<exponent)).UnixMilli(), ExecutionID: current.ExecutionID})
	}()
	stage = "read-events"
	entries, err := r.ReadEvents(ctx, work.EventIDs)
	if err != nil {
		return err
	}
	events := []plugin.LifecycleEvent{}
	for _, entry := range entries {
		events = append(events, entry.LifecycleEvent)
	}
	if r.behavior.Prepare != nil {
		stage = "prepare"
		plan, err = r.behavior.Prepare(ctx, BatchRequest{BatchID: work.ID, Events: events})
		if err != nil {
			return err
		}
	}
	if plan.Skip && work.ExecutionID == "" {
		return finish("processed")
	}
	stage = "read-session"
	session, err := r.sessions.Read("primary")
	if err != nil {
		return err
	}
	var observation model.PublicObservation
	if session != nil {
		observation = session.Record.Observation
	}
	execution := observation.LatestExecution
	if work.ExecutionID != "" && execution != nil && execution.ExecutionID == work.ExecutionID && execution.Status == "completed" && observation.BackgroundWork == nil {
		return finish("processed")
	}
	recovering := work.ExecutionID != "" && execution != nil && execution.ExecutionID == work.ExecutionID && busy(observation)
	if !recovering {
		if work.Attempts >= maxAttempts {
			return finish("failed")
		}
		work.Attempts++
		stage = "update-work"
		if err = r.updateWork(ctx, work); err != nil {
			return err
		}
		counted = true
	}
	stage = "open-session"
	handle, err := r.ensureInstance(ctx)
	if err != nil {
		return err
	}
	observation = handle.Observation()
	execution = observation.LatestExecution
	if work.ExecutionID != "" && execution != nil && execution.ExecutionID == work.ExecutionID && (execution.Status == "completed" || busy(observation)) {
		stage = "settlement"
		if err = r.waitForSettlement(ctx, handle, work.ExecutionID); err != nil {
			return err
		}
		return finish("processed")
	}
	if busy(observation) {
		stage = "interrupt"
		if err = handle.Interrupt(ctx, nil); err != nil {
			return err
		}
	}
	if !counted {
		if work.Attempts >= maxAttempts {
			return finish("failed")
		}
		work.Attempts++
		stage = "update-work"
		if err = r.updateWork(ctx, work); err != nil {
			return err
		}
		counted = true
	}
	if plan.Events != nil {
		events = plan.Events
	}
	stage = "send"
	admission, err := r.sendEvents(ctx, handle, work.ID, events, false)
	if err != nil {
		return err
	}
	stage = "settlement"
	if err = r.waitForSettlement(ctx, handle, admission.ExecutionID); err != nil {
		return err
	}
	return finish("processed")
}
func (r *Runner) updateWork(ctx context.Context, work *plugin.LifecycleWork) error {
	return r.consumer.Update(ctx, plugin.LifecycleWorkUpdate{ID: work.ID, EventIDs: work.EventIDs, Attempts: work.Attempts, NextAttemptAt: work.NextAttemptAt, ExecutionID: work.ExecutionID})
}
func busy(observation model.PublicObservation) bool {
	return observation.BackgroundWork != nil || (observation.LatestExecution != nil && (observation.LatestExecution.Status == "running" || observation.LatestExecution.Status == "waiting-for-user"))
}
func (r *Runner) settleStale(ctx context.Context) error {
	session, err := r.sessions.Read("primary")
	if err != nil {
		return err
	}
	if session == nil || !busy(session.Record.Observation) {
		return nil
	}
	handle, err := r.ensureInstance(ctx)
	if err != nil {
		return err
	}
	if busy(handle.Observation()) {
		if err = handle.Interrupt(ctx, nil); err != nil {
			r.log("stale-interrupt", err)
		}
		if busy(handle.Observation()) {
			return r.dispose()
		}
	}
	return nil
}
func (r *Runner) ensureInstance(ctx context.Context) (plugin.PrivateSessionHandle, error) {
	session, err := r.sessions.Read("primary")
	if err != nil {
		return nil, err
	}
	work := r.consumer.Work()
	var observation model.PublicObservation
	if session != nil {
		observation = session.Record.Observation
	}
	retained := work != nil && work.ExecutionID != "" && observation.LatestExecution != nil && work.ExecutionID == observation.LatestExecution.ExecutionID
	orphan := work == nil && busy(observation)
	if session == nil || (!retained && !orphan) {
		configuration, err := r.configuration.Resolve(ctx, "primary")
		if err != nil {
			return nil, err
		}
		if session == nil || session.ConfigurationKey != configuration.ConfigurationKey {
			r.mu.Lock()
			handle := r.handle
			r.mu.Unlock()
			if handle != nil && busy(handle.Observation()) {
				return handle, nil
			}
			if err = r.dispose(); err != nil {
				return nil, err
			}
			configured, err := r.sessions.Configure(ctx, plugin.ConfigureSessionRequest{SessionKey: "primary", ExpectedRevision: configuration.SessionRevision, Configuration: configuration})
			if err != nil {
				return nil, err
			}
			session = &configured
		}
	}
	r.mu.Lock()
	handle := r.handle
	lifetime := r.ctx
	r.mu.Unlock()
	if handle != nil {
		return handle, nil
	}
	opening, cancel := context.WithCancel(lifetime)
	stop := context.AfterFunc(ctx, cancel)
	bindings := r.behavior.Tools(opening)
	handle, err = r.sessions.Open(opening, plugin.OpenSessionRequest{SessionKey: "primary", Injection: plugin.Injection{Instructions: r.behavior.Instructions, Tools: &plugin.ToolInjection{Mode: "exclusive", Bindings: bindings}}})
	stop()
	if err != nil {
		cancel()
		return nil, err
	}
	// Adopt even a late handle before checking cancellation. A failed Close must
	// remain owned and report a cleanup failure instead of disappearing here.
	r.mu.Lock()
	r.handle = handle
	r.handleCancel = cancel
	r.mu.Unlock()
	if err = ctx.Err(); err == nil {
		err = lifetime.Err()
	}
	if err != nil {
		closeErr := r.dispose()
		return nil, errors.Join(err, closeErr)
	}
	return handle, nil
}
func (r *Runner) dispose() error {
	r.mu.Lock()
	handle := r.handle
	cancel := r.handleCancel
	r.mu.Unlock()
	if handle == nil {
		return nil
	}
	if cancel != nil {
		cancel()
	}
	if err := handle.Close(); err != nil {
		r.mu.Lock()
		r.cleanupError = errors.Join(r.cleanupError, err)
		stop := r.cancel
		r.mu.Unlock()
		if stop != nil {
			stop()
		}
		return err
	}
	r.mu.Lock()
	if r.handle == handle {
		r.handle = nil
		r.handleCancel = nil
	}
	r.mu.Unlock()
	return nil
}
func (r *Runner) sendEvents(ctx context.Context, handle plugin.PrivateSessionHandle, batchID string, events []plugin.LifecycleEvent, steering bool) (plugin.SessionSendResult, error) {
	input, err := r.behavior.Message(ctx, BatchRequest{BatchID: batchID, Events: events, Steering: steering})
	if err != nil {
		return plugin.SessionSendResult{}, err
	}
	if err = ctx.Err(); err != nil {
		return plugin.SessionSendResult{}, err
	}
	return handle.Send(ctx, input, nil, func(admission plugin.SessionSendResult) error {
		work := r.consumer.Work()
		if work == nil || work.ID != batchID {
			return errors.New("Background batch replaced")
		}
		seen := map[string]bool{}
		for _, id := range work.EventIDs {
			seen[id] = true
		}
		for _, event := range events {
			if !seen[event.ID] {
				seen[event.ID] = true
				work.EventIDs = append(work.EventIDs, event.ID)
			}
		}
		work.ExecutionID = admission.ExecutionID
		return r.updateWork(ctx, work)
	})
}
func (r *Runner) waitForSettlement(ctx context.Context, handle plugin.PrivateSessionHandle, executionID string) error {
	wake := make(chan struct{}, 1)
	ref := handle.Ref()
	unsubscribe, err := r.consumer.Subscribe(ctx, func(plugin.LifecycleNotification) {
		select {
		case wake <- struct{}{}:
		default:
		}
	}, &ref)
	if err != nil {
		return err
	}
	defer unsubscribe()
	for {
		if err = ctx.Err(); err != nil {
			return err
		}
		work := r.consumer.Work()
		if work == nil || work.ExecutionID != executionID {
			return errors.New("Background batch replaced")
		}
		session, err := r.sessions.Read("primary")
		if err != nil {
			return err
		}
		if session == nil || session.Record.Observation.LatestExecution == nil {
			return errors.New("Background session unavailable")
		}
		observation := session.Record.Observation
		execution := observation.LatestExecution
		if execution.ExecutionID != executionID {
			return errors.New("Background execution replaced")
		}
		if execution.Status == "failed" || execution.Status == "interrupted" || execution.Status == "waiting-for-user" {
			return &executionFailure{status: execution.Status, nativeErrorSet: execution.Error != nil && *execution.Error != ""}
		}
		if execution.Status == "running" {
			events, err := r.consumer.Pending(plugin.PendingEventsQuery{ExcludeIDs: work.EventIDs, ExcludeTypes: []string{"settings.changed"}, Limit: batchSize})
			if err != nil {
				return err
			}
			eligible := []plugin.LifecycleEvent{}
			for _, event := range events {
				if r.behavior.AcceptsSteering == nil || r.behavior.AcceptsSteering(event) {
					eligible = append(eligible, event)
				}
			}
			if len(eligible) > 0 {
				admission, err := r.sendEvents(ctx, handle, work.ID, eligible, true)
				if err != nil {
					return err
				}
				executionID = admission.ExecutionID
				continue
			}
		}
		if execution.Status == "completed" && observation.BackgroundWork == nil {
			return nil
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-wake:
		}
	}
}
func (r *Runner) log(stage string, err error) {
	outcome := "failed"
	r.mu.Lock()
	stopping := r.ctx != nil && r.ctx.Err() != nil
	r.mu.Unlock()
	if stopping && errors.Is(err, context.Canceled) {
		outcome = "cancelled"
	}
	r.diagnose(outcome, stage, -1, time.Time{}, err)
}
