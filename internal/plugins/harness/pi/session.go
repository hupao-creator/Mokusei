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
	r.steering.End()
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
	r.once.Do(func() { r.completed <- runResult{completion: completion} })
	return Event{Type: "settled", Completion: &completion}
}

type Session struct {
	Version      string
	rpc          *rpcTransport
	mu           sync.Mutex
	decoder      eventDecoder
	failure      error
	nextRun      int64
	run          *nativeRun
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
	if s.run != nil {
		s.run.fail(err)
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
		s.run = nil
	}
	listeners := make([]func(Event), 0, len(s.listeners))
	for _, listener := range s.listeners {
		listeners = append(listeners, listener)
	}
	if len(listeners) > 0 {
		s.queue = append(s.queue, sessionDelivery{event: event, listeners: listeners})
	}
	s.mu.Unlock()
	s.signalDispatch()
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

func (s *Session) begin(steer bool, policy *CompletionPolicy) (*nativeRun, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.failure != nil {
		return nil, false, s.failure
	}
	if s.run != nil {
		if !steer {
			return nil, false, fmt.Errorf("Pi native session already has an active run")
		}
		return s.run, false, nil
	}
	s.nextRun++
	s.run = &nativeRun{id: s.nextRun, policy: policy, completed: make(chan runResult, 1)}
	return s.run, true, nil
}

func (s *Session) submit(ctx context.Context, run *nativeRun, input PromptInput, startsRun bool) error {
	command := map[string]any{"type": "prompt", "message": input.Message}
	if len(input.Images) > 0 {
		command["images"] = input.Images
	}
	if input.Steer {
		command["streamingBehavior"] = "steer"
	}
	response, err := s.rpc.request(ctx, command)
	if err == nil && response["disposition"] == "handled" {
		// Pi 0.99 extensions may consume an input without starting work. A
		// consumed steer rejects only that submission, keeping its run alive.
		err = fmt.Errorf("Pi consumed this input in an extension without starting or queuing it as an agent task. Check Pi input extensions and resend the task")
	}
	if err != nil && startsRun {
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
	run, startsRun, err := s.begin(input.Steer, nil)
	if err != nil {
		return err
	}
	return s.submit(ctx, run, input, startsRun)
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
	run, _, err := s.begin(false, &policy)
	if err != nil {
		return Completion{}, err
	}
	s.mu.Lock()
	run.steering = steering
	s.mu.Unlock()
	input.Steer = false
	if err := s.submit(ctx, run, input, true); err != nil {
		return Completion{}, err
	}
	steering.Bind(func(ctx context.Context, text string) error {
		s.mu.Lock()
		current := s.run == run
		s.mu.Unlock()
		if !current {
			return plugin.ErrPromptSettled
		}
		// Never use begin(true): a settled run must not allocate another run.
		return s.submit(ctx, run, PromptInput{Message: text, Steer: true}, false)
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

func (s *Session) Close() error {
	s.mu.Lock()
	if s.failure == nil {
		s.failure = fmt.Errorf("Pi native session disposed")
	}
	if s.run != nil {
		s.run.fail(s.failure)
		s.run = nil
	}
	s.listeners = map[int64]func(Event){}
	s.failures = map[int64]func(error){}
	s.queue = nil
	s.mu.Unlock()
	s.closeOnce.Do(func() { close(s.closed) })
	return s.rpc.Close()
}
