package pi

import (
	"context"
	"fmt"
	"sync"

	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

type Completion struct {
	RunID        int64  `json:"runId"`
	Status       string `json:"status"`
	Text         string `json:"text"`
	FinishReason string `json:"finishReason"`
	Error        string `json:"error,omitempty"`
	Usage        *Usage `json:"usage,omitempty"`
}

type CompletionPolicy struct {
	DisallowTools         bool
	DisallowNotifications bool
}

type runResult struct {
	completion Completion
	err        error
}

// A run can contain multiple assistant turns and steering inputs. The final
// assistant is an outcome only after agent_settled, never after agent_end.
type nativeRun struct {
	id        int64
	policy    *CompletionPolicy
	assistant *Event
	once      sync.Once
	completed chan runResult
	steering  *plugin.PromptSteering
}

func (r *nativeRun) fail(err error) {
	r.steering.End()
	r.once.Do(func() { r.completed <- runResult{err: err} })
}

func (r *nativeRun) accept(event Event) Event {
	if event.Type == "assistant" && event.Phase == "end" {
		copy := event
		r.assistant = &copy
	}
	if r.policy != nil {
		switch {
		case event.Type == "interaction", event.Type == "notification" && r.policy.DisallowNotifications:
			r.fail(fmt.Errorf("Pi completion requested unsupported user interaction"))
		case event.Type == "tool" && event.Phase == "start" && r.policy.DisallowTools:
			r.fail(fmt.Errorf("Pi completion attempted to call a tool"))
		case event.Type == "extension-error":
			r.fail(fmt.Errorf("Pi completion extension failed: %s", event.Error))
		}
	}
	if event.Type != "settled" {
		return event
	}
	completion := Completion{RunID: r.id, Status: "completed", FinishReason: "other"}
	if r.assistant != nil {
		completion.Text = r.assistant.Text
		completion.Error = r.assistant.Error
		completion.Usage = r.assistant.Usage
		switch r.assistant.StopReason {
		case "error":
			completion.Status = "failed"
		case "aborted":
			completion.Status = "interrupted"
		case "stop", "length":
			completion.FinishReason = r.assistant.StopReason
		}
	}
	return Event{Type: "settled", Completion: &completion}
}

func (r *nativeRun) complete(completion Completion) {
	r.steering.End()
	r.once.Do(func() { r.completed <- runResult{completion: completion} })
}

type Session struct {
	Version      string
	rpc          *rpcTransport
	mu           sync.Mutex
	decoder      eventDecoder
	failure      error
	nextRun      int64
	run          *nativeRun
	pending      *steerReservation
	nextListener int64
	listeners    map[int64]func(Event)
	failures     map[int64]func(error)
	queue        []sessionDelivery
	wake         chan struct{}
	closed       chan struct{}
	dispatched   chan struct{}
	closeOnce    sync.Once
}

type sessionDelivery struct {
	event     Event
	err       error
	listeners []func(Event)
	failures  []func(error)
	fence     chan struct{}
}

func StartSession(ctx context.Context, options ProcessOptions) (*Session, error) {
	rpc, err := startRPC(ctx, options)
	if err != nil {
		return nil, err
	}
	s := &Session{Version: rpc.version, rpc: rpc, listeners: map[int64]func(Event){}, failures: map[int64]func(error){}, wake: make(chan struct{}, 1), closed: make(chan struct{}), dispatched: make(chan struct{})}
	go s.dispatch()
	rpc.onFailure(s.fail)
	rpc.subscribe(s.receive)
	return s, nil
}

func (s *Session) fail(err error) {
	s.mu.Lock()
	if s.failure != nil {
		s.mu.Unlock()
		return
	}
	s.failure = err
	if pending := s.pending; pending != nil && pending.resolved && pending.settled != nil {
		// Once acceptance or rejection is known, a process exit must not
		// replace a native terminal because acknowledgement/rollback is slow.
		pending.run.complete(*pending.settled.Completion)
		s.enqueueEventLocked(*pending.settled)
		pending.settled = nil
	}
	if s.run != nil {
		s.run.fail(err)
	}
	if s.pending != nil {
		s.pending.run.fail(err)
	}
	listeners := make([]func(error), 0, len(s.failures))
	for _, listener := range s.failures {
		listeners = append(listeners, listener)
	}
	s.queue = append(s.queue, sessionDelivery{err: err, failures: listeners})
	s.mu.Unlock()
	s.signalDispatch()
}

func (s *Session) receive(frame map[string]any) {
	s.mu.Lock()
	if s.failure != nil {
		s.mu.Unlock()
		return
	}
	native, err := s.decoder.decode(frame)
	if err != nil {
		s.mu.Unlock()
		s.fail(err)
		go func() { _ = s.rpc.Close() }()
		return
	}
	if native == nil {
		s.mu.Unlock()
		return
	}
	event := *native
	if s.run != nil {
		event = s.run.accept(event)
	} else if event.Type == "settled" {
		// A notification without an admitted input cannot settle a future run.
		s.mu.Unlock()
		return
	}
	if event.Type == "settled" {
		run := s.run
		s.run = nil
		if s.pending != nil && s.pending.run == run {
			// A retained ordinary input still owns this execution. The native
			// reply decides whether this is its final outcome or the preceding
			// run's outcome before prompt(steer) started a continuation.
			s.pending.settled = &event
			s.mu.Unlock()
			return
		}
		run.complete(*event.Completion)
	}
	s.enqueueEventLocked(event)
	s.mu.Unlock()
	s.signalDispatch()
}

func (s *Session) enqueueEventLocked(event Event) {
	listeners := make([]func(Event), 0, len(s.listeners))
	for _, listener := range s.listeners {
		listeners = append(listeners, listener)
	}
	if len(listeners) > 0 {
		s.queue = append(s.queue, sessionDelivery{event: event, listeners: listeners})
	}
}

func (s *Session) signalDispatch() {
	select {
	case s.wake <- struct{}{}:
	default:
	}
}

// Only user callbacks are queued. Native decoding and run settlement happen in
// wire order, while a subscriber remains free to synchronously query State.
func (s *Session) dispatch() {
	defer close(s.dispatched)
	for {
		s.mu.Lock()
		if len(s.queue) == 0 {
			s.mu.Unlock()
			select {
			case <-s.wake:
				continue
			case <-s.closed:
				return
			}
		}
		delivery := s.queue[0]
		s.queue[0] = sessionDelivery{}
		s.queue = s.queue[1:]
		s.mu.Unlock()
		if delivery.fence != nil {
			close(delivery.fence)
			continue
		}
		if delivery.err != nil {
			for _, listener := range delivery.failures {
				safelyNotify(listener, delivery.err)
			}
			return
		}
		for _, listener := range delivery.listeners {
			safelyNotify(listener, delivery.event)
		}
	}
}

// FlushEvents waits for consumer callbacks queued before this call. Invoke it
// from command handlers, never from a subscription callback. In particular a
// rejected steering input must flush its native echo before rolling back state.
func (s *Session) FlushEvents(ctx context.Context) error {
	s.mu.Lock()
	if s.failure != nil {
		err := s.failure
		s.mu.Unlock()
		// Failure is queued after the already-read events. Drain those callbacks
		// before a command handler decides whether a rejected input was echoed.
		select {
		case <-s.dispatched:
			return err
		case <-ctx.Done():
			return ctx.Err()
		case <-s.closed:
			return err
		}
	}
	fence := make(chan struct{})
	s.queue = append(s.queue, sessionDelivery{fence: fence})
	s.mu.Unlock()
	s.signalDispatch()
	select {
	case <-fence:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	case <-s.closed:
		s.mu.Lock()
		err := s.failure
		s.mu.Unlock()
		return err
	}
}

func (s *Session) State(ctx context.Context) (NativeState, error) {
	response, err := s.rpc.request(ctx, map[string]any{"type": "get_state"})
	if err != nil {
		return NativeState{}, err
	}
	return decodeNativeState(response)
}

func (s *Session) Clone(ctx context.Context) error {
	response, err := s.rpc.request(ctx, map[string]any{"type": "clone"})
	if err != nil {
		return err
	}
	if value, exists := response["cancelled"]; exists {
		cancelled, ok := value.(bool)
		if !ok {
			return fmt.Errorf("invalid Pi clone response")
		}
		if cancelled {
			return fmt.Errorf("Pi cancelled the native clone")
		}
	}
	return nil
}

func (s *Session) Commands(ctx context.Context) ([]Command, error) {
	response, err := s.rpc.request(ctx, map[string]any{"type": "get_commands"})
	if err != nil {
		return nil, err
	}
	return decodeCommands(response)
}

func (s *Session) Models(ctx context.Context) ([]Model, error) {
	response, err := s.rpc.request(ctx, map[string]any{"type": "get_available_models"})
	if err != nil {
		return nil, err
	}
	return decodeModels(response)
}

func (s *Session) ThinkingLevels(ctx context.Context) ([]string, error) {
	response, err := s.rpc.request(ctx, map[string]any{"type": "get_available_thinking_levels"})
	if err != nil {
		return nil, err
	}
	return piStrings(response["levels"], "thinking levels")
}

func (s *Session) begin(policy *CompletionPolicy) (*nativeRun, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.failure != nil {
		return nil, s.failure
	}
	if s.pending != nil {
		return nil, fmt.Errorf("Pi native input admission is pending")
	}
	if s.run != nil {
		return nil, fmt.Errorf("Pi native session already has an active run")
	}
	s.nextRun++
	s.run = &nativeRun{id: s.nextRun, policy: policy, completed: make(chan runResult, 1)}
	return s.run, nil
}

// A steerReservation binds input before Thread retention, under the same lock that
// consumes native settlement. Settlement after this boundary waits for the
// input's reply and durable acknowledgement; settlement before it is retryable.
type steerReservation struct {
	session  *Session
	run      *nativeRun
	settled  *Event
	resolved bool
	accepted bool
	err      error
}

func (s *Session) reserveSteer(expected *nativeRun) (*steerReservation, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.failure != nil {
		return nil, s.failure
	}
	if s.pending != nil {
		return nil, fmt.Errorf("Pi native input admission is pending")
	}
	if s.run == nil || expected != nil && s.run != expected {
		return nil, plugin.ErrExecutionEnded
	}
	pending := &steerReservation{session: s, run: s.run}
	s.pending = pending
	return pending, nil
}

func (p *steerReservation) observe(result rpcResult) {
	s := p.session
	s.mu.Lock()
	if s.pending != p || s.failure != nil {
		s.mu.Unlock()
		return
	}
	if result.err != nil {
		p.resolved = true
		p.err = result.err
		s.mu.Unlock()
		return
	}
	var protocolErr error
	switch result.message["disposition"] {
	case "handled":
		p.resolved = true
		p.err = fmt.Errorf("Pi consumed this input in an extension without starting or queuing it as an agent task. Check Pi input extensions and resend the task")
	case "queued":
		p.resolved = true
		p.accepted = true
	case "started":
		if p.settled == nil {
			protocolErr = fmt.Errorf("Pi started a continuation without settling its previous run")
			break
		}
		// Pi reports started before the new run's events on the same wire.
		// Continue the already-reserved execution; its old physical run no
		// longer supplies the terminal result for this accepted input.
		p.accepted = true
		p.resolved = true
		p.settled = nil
		p.run.assistant = nil
		s.run = p.run
	default:
		protocolErr = fmt.Errorf("Pi prompt response has no valid admission disposition")
	}
	if protocolErr != nil {
		p.err = protocolErr
	}
	s.mu.Unlock()
	if protocolErr != nil {
		s.fail(protocolErr)
		go func() { _ = s.rpc.Close() }()
	}
}

func (p *steerReservation) submit(ctx context.Context, input PromptInput) (bool, error) {
	command := map[string]any{"type": "prompt", "message": input.Message, "streamingBehavior": "steer"}
	if len(input.Images) > 0 {
		command["images"] = input.Images
	}
	_, written, err := p.session.rpc.requestObserved(ctx, command, p.observe)
	s := p.session
	s.mu.Lock()
	accepted, resolved := p.accepted, p.resolved
	if p.err != nil {
		err = p.err
	}
	if err == nil && (!resolved || !accepted) {
		err = s.failure
		if err == nil {
			err = fmt.Errorf("Pi did not confirm reserved input acceptance")
		}
	}
	s.mu.Unlock()
	if err != nil && written && !resolved {
		// A written prompt may start a native continuation. Without its reply
		// there is no safe way to release the old terminal or authorize replay.
		s.fail(err)
		go func() { _ = s.rpc.Close() }()
	}
	return accepted, err
}

func (p *steerReservation) release() {
	s := p.session
	s.mu.Lock()
	if s.pending == p {
		s.pending = nil
		if p.settled != nil && s.failure == nil {
			p.run.complete(*p.settled.Completion)
			s.enqueueEventLocked(*p.settled)
		}
	}
	s.mu.Unlock()
	s.signalDispatch()
}

func (s *Session) submitInitial(ctx context.Context, run *nativeRun, input PromptInput) error {
	command := map[string]any{"type": "prompt", "message": input.Message}
	if len(input.Images) > 0 {
		command["images"] = input.Images
	}
	response, err := s.rpc.request(ctx, command)
	if err == nil && response["disposition"] == "handled" {
		// Extensions may consume an input without starting agent work.
		err = fmt.Errorf("Pi consumed this input in an extension without starting or queuing it as an agent task. Check Pi input extensions and resend the task")
	}
	if err != nil {
		s.mu.Lock()
		run.fail(err)
		if s.run == run {
			s.run = nil
		}
		s.mu.Unlock()
	}
	return err
}

// Prompt resolves on input acceptance. Subscribe to settled for completion.
func (s *Session) Prompt(ctx context.Context, input PromptInput) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if input.Steer {
		pending, err := s.reserveSteer(nil)
		if err != nil {
			return err
		}
		defer pending.release()
		_, err = pending.submit(ctx, input)
		return err
	}
	run, err := s.begin(nil)
	if err != nil {
		return err
	}
	return s.submitInitial(ctx, run, input)
}

// Complete submits an isolated prompt and waits for that run's own successful
// native settlement. It never reuses a previously observed agent_settled event.
func (s *Session) Complete(ctx context.Context, input PromptInput, policy CompletionPolicy) (Completion, error) {
	return s.CompleteSteerable(ctx, input, policy, nil)
}
func (s *Session) CompleteSteerable(ctx context.Context, input PromptInput, policy CompletionPolicy, steering *plugin.PromptSteering) (Completion, error) {
	defer steering.Drain()
	if err := ctx.Err(); err != nil {
		return Completion{}, err
	}
	run, err := s.begin(&policy)
	if err != nil {
		return Completion{}, err
	}
	s.mu.Lock()
	run.steering = steering
	s.mu.Unlock()
	input.Steer = false
	if err := s.submitInitial(ctx, run, input); err != nil {
		return Completion{}, err
	}
	steering.Bind(func(ctx context.Context, text string) error {
		pending, err := s.reserveSteer(run)
		if err == plugin.ErrExecutionEnded {
			return plugin.ErrPromptSettled
		}
		if err != nil {
			return err
		}
		defer pending.release()
		_, err = pending.submit(ctx, PromptInput{Message: text, Steer: true})
		return err
	})
	var result runResult
	select {
	case <-ctx.Done():
		err := fmt.Errorf("Pi completion cancelled: %w", ctx.Err())
		run.fail(err)
		return Completion{}, err
	case result = <-run.completed:
	}
	if err := ctx.Err(); err != nil {
		return Completion{}, err
	}
	if result.err != nil {
		return Completion{}, result.err
	}
	if result.completion.Status != "completed" {
		message := result.completion.Error
		if message == "" {
			message = "Pi completion failed or was interrupted"
		}
		return Completion{}, fmt.Errorf("%s", message)
	}
	return result.completion, nil
}

func (s *Session) Respond(ctx context.Context, id string, answer InteractionAnswer) error {
	message := map[string]any{"type": "extension_ui_response", "id": id}
	if answer.Confirmed != nil {
		message["confirmed"] = *answer.Confirmed
	}
	if answer.Cancelled {
		message["cancelled"] = true
	}
	if answer.Value != nil {
		message["value"] = *answer.Value
	}
	return s.rpc.write(ctx, message)
}

func (s *Session) Subscribe(listener func(Event)) func() {
	s.mu.Lock()
	s.nextListener++
	id := s.nextListener
	if s.failure == nil {
		s.listeners[id] = listener
	}
	s.mu.Unlock()
	return func() {
		s.mu.Lock()
		delete(s.listeners, id)
		s.mu.Unlock()
	}
}

func (s *Session) OnFailure(listener func(error)) func() {
	s.mu.Lock()
	s.nextListener++
	id := s.nextListener
	err := s.failure
	if err == nil {
		s.failures[id] = listener
	}
	s.mu.Unlock()
	if err != nil {
		safelyNotify(listener, err)
	}
	return func() {
		s.mu.Lock()
		delete(s.failures, id)
		s.mu.Unlock()
	}
}

// Close stops native work and joins its process/readers. It deliberately does
// not join dispatch: a subscriber may close the Session from its own callback.
func (s *Session) Close() error {
	s.mu.Lock()
	if s.failure == nil {
		s.failure = fmt.Errorf("Pi native session disposed")
	}
	if s.run != nil {
		s.run.fail(s.failure)
		s.run = nil
	}
	if s.pending != nil {
		s.pending.run.fail(s.failure)
		s.pending = nil
	}
	s.listeners = map[int64]func(Event){}
	s.failures = map[int64]func(error){}
	s.queue = nil
	s.mu.Unlock()
	s.closeOnce.Do(func() { close(s.closed) })
	return s.rpc.Close()
}
