package main

// These fixtures exercise the real Moku coordinator and SQLite runtime through
// public voice commands. SDP, media events and Harness callbacks are controlled
// records: this command never opens a microphone, socket to a model service, or
// installed external Harness.
import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	runtimepkg "github.com/hupao-creator/Mokusei/internal/core/runtime"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/services/moku"
)

const voiceReplayRequestID = "11111111-1111-4111-8111-111111111111"
const voiceReplayInputID = "22222222-2222-4222-8222-222222222222"
const voiceReplayRejectedInputID = "33333333-3333-4333-8333-333333333333"

type voiceReplayFactory struct {
	mu             sync.Mutex
	serial         int
	nativeCalls    int
	relayCalls     int
	sessions       []*voiceReplaySession
	nativeError    error
	nativeGate     func(context.Context) error
	canonicalError error
	stopRelease    <-chan struct{}
	stopError      error
}

func (f *voiceReplayFactory) newSession(ctx context.Context) *voiceReplaySession {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.serial++
	session := &voiceReplaySession{id: fmt.Sprintf("00000000-0000-4000-8000-%012d", f.serial), lifetime: ctx, closeHandlers: map[int]func(){}, eventHandlers: map[int]func(plugin.VoiceEvent){}, delegates: map[int]func(plugin.VoiceDelegation){}, requests: map[int]func(context.Context, plugin.VoiceDelegation, string) error{}, speeches: make(chan plugin.VoiceSpeech, 16), stopStarted: make(chan struct{}), stopRelease: f.stopRelease, stopError: f.stopError}
	f.sessions = append(f.sessions, session)
	return session
}
func (f *voiceReplayFactory) PrepareVoice(ctx context.Context, _ string) (plugin.VoiceSession, error) {
	f.mu.Lock()
	f.relayCalls++
	f.mu.Unlock()
	return f.newSession(ctx), nil
}
func (f *voiceReplayFactory) prepareNative(ctx context.Context, open plugin.OpenContext, entries []plugin.ContextEntry) (plugin.VoiceSession, error) {
	f.mu.Lock()
	f.nativeCalls++
	failure, gate := f.nativeError, f.nativeGate
	f.mu.Unlock()
	if gate != nil {
		if err := gate(ctx); err != nil {
			return nil, err
		}
	}
	if failure != nil {
		return nil, failure
	}
	session := f.newSession(ctx)
	session.open = open
	session.preparedEntries = append([]plugin.ContextEntry{}, entries...)
	return session, nil
}
func (f *voiceReplayFactory) last() *voiceReplaySession {
	f.mu.Lock()
	defer f.mu.Unlock()
	mokuReplayCheck(len(f.sessions) > 0, "voice fixture never prepared")
	return f.sessions[len(f.sessions)-1]
}

type voiceReplayHarness struct {
	*replayNativeHarness
	id      string
	factory *voiceReplayFactory
}

func (h *voiceReplayHarness) Descriptor() plugin.HarnessDescriptor {
	descriptor := h.replayNativeHarness.Descriptor()
	descriptor.ID = h.id
	descriptor.DisplayName = "Controlled voice Harness"
	return descriptor
}
func (h *voiceReplayHarness) Open(ctx context.Context, open plugin.OpenContext) (plugin.Handle, error) {
	handle, err := h.replayNativeHarness.Open(ctx, open)
	if err != nil {
		return nil, err
	}
	return &voiceReplayHandle{Handle: handle, open: open, factory: h.factory}, nil
}

type voiceReplayHandle struct {
	plugin.Handle
	open    plugin.OpenContext
	factory *voiceReplayFactory
}

func (h *voiceReplayHandle) PrepareNativeVoice(ctx context.Context, entries []plugin.ContextEntry) (plugin.VoiceSession, error) {
	return h.factory.prepareNative(ctx, h.open, entries)
}

type voiceReplaySystem struct {
	r           *runtimepkg.Runtime
	c           *moku.Coordinator
	db          *store.Store
	h           *replayNativeHarness
	factory     *voiceReplayFactory
	once        sync.Once
	closeErr    error
	ownershipMu sync.Mutex
	ownership   map[string]string
}

func startVoiceReplay(root, id string, factory *voiceReplayFactory) *voiceReplaySystem {
	db, err := store.Open(filepath.Join(root, "state.sqlite"))
	mokuReplayMust(err)
	base := &replayNativeHarness{db: db, nativeModel: "voice-model", wake: make(chan struct{}, 128)}
	harness := &voiceReplayHarness{replayNativeHarness: base, id: id, factory: factory}
	harnesses := map[string]plugin.Harness{id: harness}
	r, err := runtimepkg.New(mokuReplayContext(), runtimepkg.Config{Store: db, Harnesses: harnesses, DataDir: root, DefaultCwd: root})
	mokuReplayMust(err)
	base.r = r
	configuration := newReplayConfiguration(root, r, base)
	configuration.Harnesses = harnesses
	configuration.Voice = factory
	configuration.PrepareNativeVoice = r.PrepareMokuVoice
	configuration.CanonicalizeInput = func(ctx context.Context, input model.AgentInput) (model.AgentInput, error) {
		factory.mu.Lock()
		failure := factory.canonicalError
		factory.mu.Unlock()
		if failure != nil {
			return input, failure
		}
		return input, ctx.Err()
	}
	c, err := moku.New(configuration)
	mokuReplayMust(err)
	r.SetMoku(c)
	mokuReplayMust(c.Start(mokuReplayContext(), plugin.RuntimeStartContext{Reason: "fixture"}))
	return &voiceReplaySystem{r: r, c: c, db: db, h: base, factory: factory, ownership: map[string]string{}}
}
func (s *voiceReplaySystem) record() model.ThreadRecord {
	records, err := s.r.Threads()
	mokuReplayMust(err)
	for _, record := range records {
		if record.Moku {
			return record
		}
	}
	panic("voice fixture Moku absent")
}
func (s *voiceReplaySystem) close() error {
	s.once.Do(func() {
		ctx, cancel := context.WithTimeout(context.WithoutCancel(mokuReplayContext()), 5*time.Second)
		defer cancel()
		s.closeErr = errors.Join(s.r.Close(ctx), s.db.Close())
	})
	return s.closeErr
}
func (s *voiceReplaySystem) command(channel string, value any) (any, error) {
	if fields, ok := value.(map[string]any); ok {
		if sessionID, ok := fields["sessionId"].(string); ok {
			s.ownershipMu.Lock()
			owner := s.ownership[sessionID]
			s.ownershipMu.Unlock()
			if owner == "" {
				owner = sessionID
			}
			fields["ownershipId"] = owner
		}
	}
	return s.r.Invoke(mokuReplayContext(), channel, []json.RawMessage{mokuReplayRaw(value)})
}
func (s *voiceReplaySystem) prepare(requestID string) (*voiceReplaySession, error) {
	value, err := s.command("moku:voice", map[string]any{"action": "prepare", "requestId": requestID})
	if err != nil {
		return nil, err
	}
	session := s.factory.last()
	object, ok := value.(map[string]any)
	mokuReplayCheck(ok && object["sessionId"] == session.ID() && object["ownershipId"] == requestID, "voice prepare identity mismatch")
	s.ownershipMu.Lock()
	s.ownership[session.ID()] = requestID
	s.ownershipMu.Unlock()
	return session, nil
}
func (s *voiceReplaySystem) complete(summary string) {
	record := s.record()
	mokuReplayCheck(record.Observation.LatestExecution != nil, "completion without native execution")
	observation := record.Observation
	finished := time.Now().UnixMilli()
	observation.LatestExecution.Status = "completed"
	observation.LatestExecution.FinishedAt = &finished
	observation.LatestExecution.Summary = &summary
	s.h.mu.Lock()
	handles := append([]*replayNativeHandle{}, s.h.handles...)
	s.h.mu.Unlock()
	mokuReplayCheck(len(handles) > 0, "native handle absent")
	mokuReplayMust(handles[len(handles)-1].open.SessionState.Commit(mokuReplayContext(), mokuReplayRaw(observation)))
}

type voiceReplaySession struct {
	mu                     sync.Mutex
	id                     string
	lifetime               context.Context
	open                   plugin.OpenContext
	closed                 bool
	generation             int64
	sequence               int64
	nextHandler            int
	closeHandlers          map[int]func()
	eventHandlers          map[int]func(plugin.VoiceEvent)
	delegates              map[int]func(plugin.VoiceDelegation)
	requests               map[int]func(context.Context, plugin.VoiceDelegation, string) error
	events                 []plugin.VoiceEvent
	rejected               []string
	preparedEntries        []plugin.ContextEntry
	synchronized           []plugin.ContextEntry
	syncCount              int
	forceGenerationAdvance bool
	speeches               chan plugin.VoiceSpeech
	stopOnce               sync.Once
	stopStarted            chan struct{}
	stopRelease            <-chan struct{}
	stopError              error
}

func (s *voiceReplaySession) ID() string   { return s.id }
func (s *voiceReplaySession) Closed() bool { s.mu.Lock(); defer s.mu.Unlock(); return s.closed }
func (s *voiceReplaySession) InputGeneration() int64 {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.generation
}
func (s *voiceReplaySession) OnClose(handler func()) func() {
	s.mu.Lock()
	s.nextHandler++
	id := s.nextHandler
	s.closeHandlers[id] = handler
	closed := s.closed
	s.mu.Unlock()
	if closed {
		handler()
	}
	return func() { s.mu.Lock(); delete(s.closeHandlers, id); s.mu.Unlock() }
}
func (s *voiceReplaySession) OnEvent(handler func(plugin.VoiceEvent)) func() {
	s.mu.Lock()
	s.nextHandler++
	id := s.nextHandler
	s.eventHandlers[id] = handler
	s.mu.Unlock()
	return func() { s.mu.Lock(); delete(s.eventHandlers, id); s.mu.Unlock() }
}
func (s *voiceReplaySession) OnDelegation(handler func(plugin.VoiceDelegation)) func() {
	s.mu.Lock()
	s.nextHandler++
	id := s.nextHandler
	s.delegates[id] = handler
	s.mu.Unlock()
	return func() { s.mu.Lock(); delete(s.delegates, id); s.mu.Unlock() }
}
func (s *voiceReplaySession) OnRequest(handler func(context.Context, plugin.VoiceDelegation, string) error) func() {
	s.mu.Lock()
	s.nextHandler++
	id := s.nextHandler
	s.requests[id] = handler
	s.mu.Unlock()
	return func() { s.mu.Lock(); delete(s.requests, id); s.mu.Unlock() }
}
func (s *voiceReplaySession) Start(ctx context.Context, offer string) (string, error) {
	if err := ctx.Err(); err != nil {
		return "", err
	}
	if offer != "fixture-offer" {
		return "", errors.New("unexpected SDP fixture")
	}
	return "fixture-answer", nil
}
func (s *voiceReplaySession) Poll(after int64) ([]plugin.VoiceEvent, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	events := []plugin.VoiceEvent{}
	for _, event := range s.events {
		if event.Sequence > after {
			events = append(events, event)
		}
	}
	return events, nil
}
func (s *voiceReplaySession) Heartbeat() {}
func (s *voiceReplaySession) FenceInput(id string) {
	s.mu.Lock()
	s.generation++
	generation := s.generation
	s.sequence++
	event := plugin.VoiceEvent{Type: "input", InputID: id, Generation: &generation, Sequence: s.sequence}
	s.events = append(s.events, event)
	handlers := make([]func(plugin.VoiceEvent), 0, len(s.eventHandlers))
	for _, handler := range s.eventHandlers {
		handlers = append(handlers, handler)
	}
	advance := s.forceGenerationAdvance
	s.mu.Unlock()
	for _, handler := range handlers {
		handler(event)
	}
	if advance {
		s.mu.Lock()
		s.generation++
		s.mu.Unlock()
	}
}
func (s *voiceReplaySession) RejectInput(id string) {
	s.mu.Lock()
	s.rejected = append(s.rejected, id)
	s.mu.Unlock()
}
func (s *voiceReplaySession) Speak(ctx context.Context, speech plugin.VoiceSpeech) error {
	select {
	case s.speeches <- speech:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}
func (s *voiceReplaySession) closeMedia() {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return
	}
	s.closed = true
	handlers := make([]func(), 0, len(s.closeHandlers))
	for _, handler := range s.closeHandlers {
		handlers = append(handlers, handler)
	}
	s.mu.Unlock()
	for _, handler := range handlers {
		handler()
	}
}
func (s *voiceReplaySession) Stop(ctx context.Context) error {
	s.stopOnce.Do(func() { close(s.stopStarted) })
	s.closeMedia()
	if s.stopRelease != nil {
		select {
		case <-s.stopRelease:
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	return s.stopError
}
func (s *voiceReplaySession) SyncContext(ctx context.Context, entries []plugin.ContextEntry) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	s.mu.Lock()
	s.syncCount++
	s.synchronized = append([]plugin.ContextEntry{}, entries...)
	s.mu.Unlock()
	return nil
}
func (s *voiceReplaySession) request(ctx context.Context, request plugin.VoiceDelegation, executionID string) error {
	s.mu.Lock()
	handlers := make([]func(context.Context, plugin.VoiceDelegation, string) error, 0, len(s.requests))
	for _, handler := range s.requests {
		handlers = append(handlers, handler)
	}
	s.mu.Unlock()
	if len(handlers) == 0 {
		return errors.New("native voice request callback missing")
	}
	for _, handler := range handlers {
		if err := handler(ctx, request, executionID); err != nil {
			return err
		}
	}
	return nil
}
func (s *voiceReplaySession) admitNative(ctx context.Context, request plugin.VoiceDelegation) (string, error) {
	if s.open.ExecutionAdmission == nil {
		return "", errors.New("native voice admission missing")
	}
	executionID, err := s.open.ExecutionAdmission.Accept(ctx, func(id string) (json.RawMessage, error) {
		return json.Marshal(model.PublicObservation{LatestExecution: &model.PublicExecution{ExecutionID: id, Status: "running", StartedAt: time.Now().UnixMilli()}})
	})
	if err != nil {
		return "", err
	}
	return executionID, s.request(ctx, request, executionID)
}
func (s *voiceReplaySession) delegate(request plugin.VoiceDelegation) {
	s.mu.Lock()
	handlers := make([]func(plugin.VoiceDelegation), 0, len(s.delegates))
	for _, handler := range s.delegates {
		handlers = append(handlers, handler)
	}
	s.mu.Unlock()
	mokuReplayCheck(len(handlers) > 0, "relay delegation callback missing")
	for _, handler := range handlers {
		handler(request)
	}
}
func voiceReplayWaitSpeech(session *voiceReplaySession) plugin.VoiceSpeech {
	select {
	case speech := <-session.speeches:
		return speech
	case <-time.After(8 * time.Second):
		panic("voice terminal speech not delivered")
	}
}
func voiceReplayWait(label string, signal <-chan struct{}) {
	select {
	case <-signal:
	case <-time.After(8 * time.Second):
		panic("voice replay timeout: " + label)
	}
}
func voiceReplayHasMessage(record model.ThreadRecord, text string) bool {
	for _, raw := range record.Transcript {
		var item map[string]any
		mokuReplayMust(json.Unmarshal(raw, &item))
		if item["type"] == "message" && item["role"] == "user" && item["content"] == text {
			return true
		}
	}
	return false
}

func runVoiceReplay() (err error) {
	defer func() {
		if failure := recover(); failure != nil {
			err = fmt.Errorf("voice replay: %v", failure)
		}
	}()
	root, err := os.MkdirTemp("", "mokusei-moku-voice-replay-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(root)
	factory := &voiceReplayFactory{}
	system := startVoiceReplay(filepath.Join(root, "native"), "codex", factory)
	defer func() { _ = system.close() }()
	session, err := system.prepare(voiceReplayRequestID)
	mokuReplayMust(err)
	mokuReplayCheck(session.lifetime.Err() == nil, "prepared voice lifetime ended with command")
	answer, err := system.command("moku:voice", map[string]any{"action": "start", "sessionId": session.ID(), "sdp": "fixture-offer"})
	mokuReplayMust(err)
	mokuReplayCheck(answer.(map[string]any)["sdp"] == "fixture-answer", "voice SDP response lost")
	owner := system.record().ID
	request := plugin.VoiceDelegation{ID: "native-voice-fixture", Text: "native spoken task", Generation: 0}
	executionID, err := session.admitNative(mokuReplayContext(), request)
	mokuReplayMust(err)
	session.mu.Lock()
	synchronized := session.syncCount
	entries := append([]plugin.ContextEntry{}, session.synchronized...)
	session.mu.Unlock()
	mokuReplayCheck(synchronized == 1 && len(entries) > 0, "native voice admitted before context synchronization")
	mokuReplayCheck(voiceReplayHasMessage(system.record(), request.Text), "native voice user input not durable")
	mokuReplayCheck(session.request(mokuReplayContext(), plugin.VoiceDelegation{ID: "wrong-execution", Text: "must be rejected"}, "different-execution") != nil, "voice accepted wrong execution identity")
	system.complete("fixed native reply")
	speech := voiceReplayWaitSpeech(session)
	mokuReplayCheck(speech.Text == "fixed native reply" && speech.Generation == 0 && speech.DeliveryID == session.ID()+":"+request.ID, "native voice terminal result attribution changed")
	mokuReplayCheck(speech.DelegationID == request.ID, fmt.Sprintf("native voice terminal speech lost request identity: got %q, want %q", speech.DelegationID, request.ID))

	session.mu.Lock()
	session.forceGenerationAdvance = true
	session.mu.Unlock()
	typed := mokuReplayText("typed voice-fenced task")
	typed.VoiceInput = &struct {
		SessionID   string `json:"sessionId"`
		OwnershipID string `json:"ownershipId"`
		InputID     string `json:"inputId"`
	}{session.ID(), voiceReplayRequestID, voiceReplayInputID}
	mokuReplayMust(system.c.Submit(mokuReplayContext(), typed))
	system.h.awaitTools(1)
	system.complete("typed result")
	speech = voiceReplayWaitSpeech(session)
	mokuReplayCheck(speech.Generation == 1 && session.InputGeneration() == 2, "typed result used newer spoken generation instead of exact fence event")
	factory.mu.Lock()
	factory.canonicalError = errors.New("injected attachment canonicalization failure")
	factory.mu.Unlock()
	rejected := mokuReplayText("rejected before native admission")
	rejected.VoiceInput = &struct {
		SessionID   string `json:"sessionId"`
		OwnershipID string `json:"ownershipId"`
		InputID     string `json:"inputId"`
	}{session.ID(), voiceReplayRequestID, voiceReplayRejectedInputID}
	mokuReplayCheck(system.c.Submit(mokuReplayContext(), rejected) != nil, "attachment failure accepted")
	session.mu.Lock()
	rejections := append([]string{}, session.rejected...)
	session.mu.Unlock()
	mokuReplayCheck(len(rejections) == 1 && rejections[0] == voiceReplayRejectedInputID, "pre-admission failure did not reject typed voice fence")
	factory.mu.Lock()
	factory.canonicalError = nil
	factory.mu.Unlock()
	fmt.Println("PASS voice: native durable admission/context sync, SDP, owner/execution fences, typed generation and pre-admission rejection")

	stopRelease := make(chan struct{})
	session.mu.Lock()
	session.stopRelease = stopRelease
	session.mu.Unlock()
	session.closeMedia()
	voiceReplayWait("automatic teardown started", session.stopStarted)
	stopped := make(chan error, 1)
	go func() {
		_, err := system.command("moku:voice", map[string]any{"action": "stop", "sessionId": session.ID()})
		stopped <- err
	}()
	mokuReplayRemainsBlocked("voice stop joins automatic teardown", stopped)
	polled, err := system.command("moku:voice-events", map[string]any{"action": "poll", "sessionId": session.ID(), "after": 0})
	mokuReplayMust(err)
	mokuReplayCheck(len(polled.(map[string]any)["events"].([]plugin.VoiceEvent)) == 1, "retired voice events unavailable")
	close(stopRelease)
	mokuReplayWaitError("voice teardown join", stopped)
	replacement, err := system.prepare(voiceReplayRejectedInputID)
	mokuReplayMust(err)
	mokuReplayCheck(replacement.ID() != session.ID(), "new voice reused retired media identity")
	_, err = system.command("moku:voice", map[string]any{"action": "stop", "sessionId": replacement.ID()})
	mokuReplayMust(err)
	mokuReplayMust(system.c.Clear(mokuReplayContext()))
	mokuReplayCheck(system.record().ID != owner, "voice owner clear failed")
	mokuReplayCheck(session.request(mokuReplayContext(), plugin.VoiceDelegation{ID: "late-owner", Text: "stale owner must not write"}, executionID) != nil, "retired native callback wrote to replacement owner")
	factory.mu.Lock()
	factory.nativeError = errors.New("injected native preparation failure")
	factory.mu.Unlock()
	_, err = system.prepare(voiceReplayRequestID)
	mokuReplayCheck(err != nil, "native preparation failure disappeared")
	factory.mu.Lock()
	relayCalls := factory.relayCalls
	factory.nativeError = nil
	factory.mu.Unlock()
	mokuReplayCheck(relayCalls == 0, "Codex native failure fell back to relay")

	prepareEntered := make(chan struct{})
	factory.mu.Lock()
	factory.nativeGate = func(ctx context.Context) error { close(prepareEntered); <-ctx.Done(); return ctx.Err() }
	factory.mu.Unlock()
	preparing := make(chan error, 1)
	go func() { _, err := system.prepare(voiceReplayRequestID); preparing <- err }()
	voiceReplayWait("blocked native prepare", prepareEntered)
	_, err = system.command("moku:voice", map[string]any{"action": "stop", "sessionId": voiceReplayRequestID})
	mokuReplayMust(err)
	select {
	case err = <-preparing:
		mokuReplayCheck(err != nil, "stopped preparation succeeded")
	case <-time.After(8 * time.Second):
		return errors.New("stop-before-session-ID failed to release prepare")
	}
	factory.mu.Lock()
	factory.nativeGate = nil
	factory.mu.Unlock()
	for _, invalid := range []map[string]any{{"action": "poll", "sessionId": session.ID(), "after": 1.5}, {"action": "poll", "sessionId": session.ID(), "after": float64(9007199254740992)}} {
		_, err = system.command("moku:voice-events", invalid)
		var protocol *model.Error
		mokuReplayCheck(errors.As(err, &protocol) && protocol.Code == "INVALID_REQUEST", "invalid poll boundary accepted")
	}
	_, err = system.command("moku:voice-events", map[string]any{"action": "prepare", "requestId": voiceReplayRequestID})
	mokuReplayCheck(err != nil, "voice-events accepted write action")
	mokuReplayMust(system.close())
	fmt.Println("PASS voice: teardown joins, retired polling, no native fallback, owner replacement, stop-before-ID and strict command routing")

	relayFactory := &voiceReplayFactory{}
	relay := startVoiceReplay(filepath.Join(root, "relay"), "mock", relayFactory)
	defer func() { _ = relay.close() }()
	media, err := relay.prepare(voiceReplayRequestID)
	mokuReplayMust(err)
	mokuReplayCheck(media.lifetime.Err() == nil, "relay lifetime canceled after prepare")
	admissionEntered, admissionRelease := make(chan struct{}), make(chan struct{})
	relay.h.mu.Lock()
	relay.h.gateAdmission = func(ctx context.Context) error {
		close(admissionEntered)
		select {
		case <-admissionRelease:
			return nil
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	relay.h.mu.Unlock()
	media.delegate(plugin.VoiceDelegation{ID: "relay-request", Text: "relay task survives media stop", Context: "fixed prior transcript", Generation: 0})
	voiceReplayWait("relay native admission fence", admissionEntered)
	_, err = relay.command("moku:voice", map[string]any{"action": "stop", "sessionId": media.ID()})
	mokuReplayMust(err)
	close(admissionRelease)
	relay.h.awaitTools(1)
	mokuReplayCheck(voiceReplayHasMessage(relay.record(), "relay task survives media stop"), "closing media canceled already-admitted Moku work")
	relayFactory.mu.Lock()
	nativeCalls, relayCalls := relayFactory.nativeCalls, relayFactory.relayCalls
	relayFactory.mu.Unlock()
	mokuReplayCheck(nativeCalls == 0 && relayCalls == 1, "non-Codex target selected wrong voice path")
	mokuReplayMust(relay.close())
	fmt.Println("PASS voice: non-Codex relay uses durable media lifetime and target work survives media shutdown")

	brokenFactory := &voiceReplayFactory{stopError: errors.New("injected voice cleanup failure")}
	broken := startVoiceReplay(filepath.Join(root, "cleanup"), "codex", brokenFactory)
	defer func() { _ = broken.close() }()
	brokenMedia, err := broken.prepare(voiceReplayRequestID)
	mokuReplayMust(err)
	_, err = broken.command("moku:voice", map[string]any{"action": "stop", "sessionId": brokenMedia.ID()})
	mokuReplayCheck(err != nil && strings.Contains(err.Error(), "injected voice cleanup failure"), "voice cleanup failure was hidden")
	_, err = broken.prepare(voiceReplayRejectedInputID)
	mokuReplayCheck(err != nil && strings.Contains(err.Error(), "injected voice cleanup failure"), "replacement ignored unreleased media cleanup failure")
	fmt.Println("PASS voice: cleanup failures remain visible and prevent unsafe replacement")
	if err := runDeviceVoiceReplay(root); err != nil {
		return err
	}
	return runPublicVoiceReplay(root)
}

// These commands retain the authenticated context through the actual coordinator,
// rather than selecting an owner from client-submitted device fields.
func runDeviceVoiceReplay(root string) error {
	factory := &voiceReplayFactory{}
	s := startVoiceReplay(filepath.Join(root, "devices"), "codex", factory)
	defer func() { _ = s.close() }()
	invoke := func(device, channel string, fields map[string]any) (any, error) {
		return s.r.Invoke(model.WithClientDevice(mokuReplayContext(), device), channel, []json.RawMessage{mokuReplayRaw(fields)})
	}
	a, err := invoke("ipad-a", "moku:voice", map[string]any{"action": "prepare", "requestId": voiceReplayRequestID})
	mokuReplayMust(err)
	aSession := a.(map[string]any)["sessionId"].(string)
	first := factory.last()
	busy, err := invoke("ipad-b", "moku:voice", map[string]any{"action": "prepare", "requestId": voiceReplayInputID})
	mokuReplayMust(err)
	occupied := busy.(map[string]any)["occupiedOwner"].(map[string]string)
	mokuReplayCheck(occupied["deviceId"] == "ipad-a" && occupied["ownershipId"] == voiceReplayRequestID && !first.Closed(), "second device implicitly replaced voice")
	for _, action := range []string{"poll", "heartbeat", "start"} {
		fields := map[string]any{"action": action, "sessionId": aSession, "ownershipId": voiceReplayRequestID}
		channel := "moku:voice-events"
		if action == "poll" {
			fields["after"] = 0
		}
		if action == "start" {
			fields["sdp"] = "fixture-offer"
			channel = "moku:voice"
		}
		_, err = invoke("ipad-b", channel, fields)
		mokuReplayCheck(err != nil, "other device controlled voice through "+action)
	}
	_, err = invoke("ipad-b", "moku:voice", map[string]any{"action": "stop", "sessionId": aSession, "ownershipId": voiceReplayRequestID})
	mokuReplayMust(err)
	mokuReplayCheck(!first.Closed(), "other device stopped active voice")
	b, err := invoke("ipad-b", "moku:voice", map[string]any{"action": "prepare", "requestId": voiceReplayInputID, "takeover": voiceReplayRequestID})
	mokuReplayMust(err)
	bSession := b.(map[string]any)["sessionId"].(string)
	second := factory.last()
	mokuReplayCheck(first.Closed() && second != first && !second.Closed(), "explicit takeover did not retire old media")
	_, err = invoke("ipad-a", "moku:voice", map[string]any{"action": "stop", "sessionId": bSession, "ownershipId": voiceReplayRequestID})
	mokuReplayMust(err)
	mokuReplayCheck(!second.Closed(), "stale generation stopped successor")
	_, err = invoke("ipad-a", "moku:voice-events", map[string]any{"action": "heartbeat", "sessionId": bSession, "ownershipId": voiceReplayRequestID})
	mokuReplayCheck(err != nil, "stale generation renewed successor")
	_, err = invoke("ipad-b", "moku:voice-events", map[string]any{"action": "heartbeat", "sessionId": bSession, "ownershipId": voiceReplayInputID})
	mokuReplayMust(err)
	_, err = invoke("ipad-a", "moku:voice", map[string]any{"action": "prepare", "requestId": voiceReplayRejectedInputID, "takeover": voiceReplayRequestID})
	mokuReplayCheck(err != nil && !second.Closed(), "stale takeover replaced current owner")
	mokuReplayMust(s.r.RevokeDeviceMedia(mokuReplayContext(), "ipad-a"))
	mokuReplayCheck(!second.Closed(), "revocation stopped unrelated device")
	mokuReplayMust(s.r.RevokeDeviceMedia(mokuReplayContext(), "ipad-b"))
	mokuReplayCheck(second.Closed() && !s.r.ServiceVoiceActive(), "revocation retained media or host power lease")
	fmt.Println("PASS voice: authenticated device ownership, occupied response, explicit generation-fenced takeover/start/poll/heartbeat/stop and scoped revocation")
	return nil
}
