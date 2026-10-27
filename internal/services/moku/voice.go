package moku

import (
	"context"
	"encoding/json"
	"errors"
	"math"
	"regexp"
	"sync"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

type voiceDelivery struct {
	owner        string
	session      plugin.VoiceSession
	deliveryID   string
	delegationID string
	generation   int64 // protected by voiceController.mu after admission
	lease        *mokuVoiceLease
}

type mokuVoicePreparation struct {
	id     string
	device string
	ctx    context.Context
	cancel context.CancelFunc
}

type mokuVoiceLease struct {
	session               plugin.VoiceSession
	id                    string
	requestID             string
	device                string
	owner                 string
	ctx                   context.Context
	cancel                context.CancelFunc
	unsubscribeClose      func()
	unsubscribeDelegation func()
	unsubscribeContext    func() bool
}

type mokuVoiceTeardown struct {
	done chan struct{}
	err  error
}

type voiceController struct {
	c                *Coordinator
	mu               sync.Mutex
	commands         chan struct{}
	admissions       chan struct{}
	preparation      *mokuVoicePreparation
	active           *mokuVoiceLease
	retired          plugin.VoiceSession
	retiredID        string
	retiredDevice    string
	retiredOwnership string
	deliveries       map[string]*voiceDelivery
	teardowns        map[*mokuVoiceLease]*mokuVoiceTeardown
}

func newVoiceController(c *Coordinator) *voiceController {
	v := &voiceController{c: c, commands: make(chan struct{}, 1), admissions: make(chan struct{}, 1), deliveries: make(map[string]*voiceDelivery), teardowns: make(map[*mokuVoiceLease]*mokuVoiceTeardown)}
	v.commands <- struct{}{}
	v.admissions <- struct{}{}
	return v
}

type mokuVoiceCommand struct {
	Action      string
	RequestID   string
	SessionID   string
	OwnershipID string
	Takeover    string
	SDP         string
	After       int64
}

var mokuVoiceUUID = regexp.MustCompile(`^([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}|00000000-0000-0000-0000-000000000000|ffffffff-ffff-ffff-ffff-ffffffffffff)$`)

func parseMokuVoiceCommand(raw json.RawMessage) (mokuVoiceCommand, error) {
	var value map[string]json.RawMessage
	invalid := model.NewError("INVALID_REQUEST", "Invalid voice command")
	if json.Unmarshal(raw, &value) != nil || value == nil {
		return mokuVoiceCommand{}, invalid
	}
	var result mokuVoiceCommand
	if json.Unmarshal(value["action"], &result.Action) != nil {
		return result, invalid
	}
	keys := []string{"action", "sessionId"}
	switch result.Action {
	case "prepare":
		keys = []string{"action", "requestId"}
		if raw, exists := value["takeover"]; exists {
			keys = append(keys, "takeover")
			if json.Unmarshal(raw, &result.Takeover) != nil || !mokuVoiceUUID.MatchString(result.Takeover) {
				return result, invalid
			}
		}
		if json.Unmarshal(value["requestId"], &result.RequestID) != nil || !mokuVoiceUUID.MatchString(result.RequestID) {
			return result, invalid
		}
	case "start", "poll", "stop", "heartbeat":
		keys = append(keys, "ownershipId")
		if json.Unmarshal(value["ownershipId"], &result.OwnershipID) != nil || !mokuVoiceUUID.MatchString(result.OwnershipID) {
			return result, invalid
		}
		if json.Unmarshal(value["sessionId"], &result.SessionID) != nil || !mokuVoiceUUID.MatchString(result.SessionID) {
			return result, invalid
		}
		if result.Action == "start" {
			keys = append(keys, "sdp")
			if json.Unmarshal(value["sdp"], &result.SDP) != nil || result.SDP == "" || voiceUTF16Length(result.SDP) > 128000 {
				return result, invalid
			}
		}
		if result.Action == "poll" {
			keys = append(keys, "after")
			var after *float64
			if json.Unmarshal(value["after"], &after) != nil || after == nil || *after < 0 || *after > 9007199254740991 || math.Trunc(*after) != *after {
				return result, invalid
			}
			result.After = int64(*after)
		}
	default:
		return result, invalid
	}
	if len(value) != len(keys) {
		return result, invalid
	}
	for _, key := range keys {
		if _, exists := value[key]; !exists {
			return result, invalid
		}
	}
	return result, nil
}

func voiceUTF16Length(value string) int {
	count := 0
	for _, char := range value {
		count++
		if char > 0xffff {
			count++
		}
	}
	return count
}

func (v *voiceController) command(ctx context.Context, raw json.RawMessage) (any, error) {
	device := model.ClientDeviceID(ctx)
	request, err := parseMokuVoiceCommand(raw)
	if err != nil {
		return nil, err
	}
	ctx, finish, err := v.c.begin(ctx)
	if err != nil {
		return nil, err
	}
	defer finish()
	if request.Action == "poll" {
		v.mu.Lock()
		retired, retiredID, retiredDevice, retiredOwnership := v.retired, v.retiredID, v.retiredDevice, v.retiredOwnership
		v.mu.Unlock()
		var session plugin.VoiceSession
		if retired != nil && retiredID == request.SessionID && retiredDevice == device && retiredOwnership == request.OwnershipID {
			session = retired
		} else {
			lease, err := v.required(request.SessionID, request.OwnershipID, device)
			if err != nil {
				return nil, err
			}
			session = lease.session
		}
		events, err := session.Poll(request.After)
		if err != nil {
			return nil, err
		}
		if events == nil {
			events = []plugin.VoiceEvent{}
		}
		return map[string]any{"events": events}, nil
	}
	var preparation *mokuVoicePreparation
	var detachPrepare func() bool
	installed := false
	if request.Action == "prepare" {
		// A prepared relay retains this service-owned context after the command
		// returns. The per-command tracking context is detached on installation.
		v.c.mu.Lock()
		service := v.c.ctx
		v.c.mu.Unlock()
		prepareCtx, cancel := context.WithCancel(service)
		preparation = &mokuVoicePreparation{id: request.RequestID, device: device, ctx: prepareCtx, cancel: cancel}
		detachPrepare = context.AfterFunc(ctx, cancel)
		v.mu.Lock()
		var occupiedID, occupiedDevice string
		if v.preparation != nil {
			occupiedID, occupiedDevice = v.preparation.id, v.preparation.device
		} else if v.active != nil {
			occupiedID, occupiedDevice = v.active.requestID, v.active.device
		}
		if occupiedID != "" && request.Takeover == "" {
			v.mu.Unlock()
			detachPrepare()
			cancel()
			return map[string]any{"occupiedOwner": map[string]string{"deviceId": occupiedDevice, "ownershipId": occupiedID}}, nil
		}
		if request.Takeover != "" && request.Takeover != occupiedID {
			v.mu.Unlock()
			detachPrepare()
			cancel()
			return nil, model.NewError("VOICE_OWNERSHIP_CHANGED", "语音所有权已经变化，请重新查看后接管")
		}
		previous := v.preparation
		v.preparation = preparation
		v.mu.Unlock()
		if previous != nil {
			previous.cancel()
		}
		defer func() {
			detachPrepare()
			if !installed {
				preparation.cancel()
			}
			v.mu.Lock()
			if v.preparation == preparation {
				v.preparation = nil
			}
			v.mu.Unlock()
		}()
	}
	if request.Action == "stop" {
		// Cancellation precedes the command queue: callers can stop a slow
		// preparation before receiving its eventual native session identity.
		v.mu.Lock()
		if v.preparation != nil && v.preparation.id == request.SessionID && v.preparation.id == request.OwnershipID && v.preparation.device == device {
			v.preparation.cancel()
		}
		if v.active != nil && v.active.device == device && v.active.requestID == request.OwnershipID && (v.active.id == request.SessionID || v.active.requestID == request.SessionID) {
			v.active.cancel()
		}
		v.mu.Unlock()
	}
	if err := takeVoiceQueue(ctx, v.commands); err != nil {
		return nil, err
	}
	defer func() { v.commands <- struct{}{} }()
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if preparation != nil {
		if err := preparation.ctx.Err(); err != nil {
			return nil, err
		}
		if err := v.stop(ctx); err != nil {
			return nil, err
		}
		if err := v.c.queue.Lock(preparation.ctx); err != nil {
			return nil, err
		}
		defer v.c.queue.Unlock()
		var lease *mokuVoiceLease
		err := v.c.admitSettings(preparation.ctx, func(admissionCtx context.Context) error {
			var prepareErr error
			lease, prepareErr = v.prepareSession(admissionCtx, preparation)
			return prepareErr
		})
		if err != nil {
			return nil, err
		}
		// Detach before finish() cancels the command context, otherwise a relay
		// would be torn down immediately after a successful prepare response.
		detachPrepare()
		if err := preparation.ctx.Err(); err != nil {
			_ = v.stop(context.WithoutCancel(ctx))
			return nil, err
		}
		installed = true
		return map[string]any{"sessionId": lease.id, "ownershipId": lease.requestID}, nil
	}
	if request.Action == "stop" {
		v.mu.Lock()
		matches := v.active != nil && v.active.device == device && v.active.requestID == request.OwnershipID && (v.active.id == request.SessionID || v.active.requestID == request.SessionID)
		v.mu.Unlock()
		if matches {
			if err := v.stop(ctx); err != nil {
				return nil, err
			}
		} else if err := v.waitTeardowns(ctx); err != nil {
			return nil, err
		}
		return map[string]any{}, nil
	}
	lease, err := v.required(request.SessionID, request.OwnershipID, device)
	if err != nil {
		return nil, err
	}
	if request.Action == "heartbeat" {
		lease.session.Heartbeat()
		return map[string]any{}, nil
	}
	startCtx, cancel := voiceLeaseContext(ctx, lease)
	defer cancel()
	sdp, err := lease.session.Start(startCtx, request.SDP)
	if err != nil {
		return nil, err
	}
	return map[string]any{"sdp": sdp}, nil
}

func (v *voiceController) prepareSession(ctx context.Context, preparation *mokuVoicePreparation) (*mokuVoiceLease, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	record, err := v.c.ensure(ctx)
	if err != nil {
		return nil, err
	}
	var session plugin.VoiceSession
	if record.HarnessID == "codex" {
		if v.c.config.PrepareNativeVoice == nil {
			return nil, errors.New("此 Codex 会话未提供原生语音接入；不会使用转发层")
		}
		entries, err := v.c.sendContext(ctx, model.AgentInput{}, nil)
		if err != nil {
			return nil, err
		}
		session, err = v.c.config.PrepareNativeVoice(ctx, record.ID, entries)
	} else {
		if v.c.config.Voice == nil {
			return nil, errors.New("当前未启用 Codex 语音能力")
		}
		session, err = v.c.config.Voice.PrepareVoice(ctx, "")
	}
	if err != nil {
		return nil, err
	}
	if session == nil {
		return nil, errors.New("Voice preparation returned no session")
	}
	current, ownerErr := v.c.current()
	if ctx.Err() != nil || ownerErr != nil || current.ID != record.ID {
		stopErr := session.Stop(context.WithoutCancel(ctx))
		return nil, errors.Join(errors.New("Voice preparation owner retired"), stopErr)
	}
	lease := &mokuVoiceLease{session: session, id: session.ID(), requestID: preparation.id, device: preparation.device, owner: record.ID, ctx: preparation.ctx, cancel: preparation.cancel}
	if err := v.attach(lease); err != nil {
		return nil, errors.Join(err, v.stop(context.WithoutCancel(ctx)))
	}
	return lease, nil
}

func takeVoiceQueue(ctx context.Context, queue chan struct{}) error {
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-queue:
		if err := ctx.Err(); err != nil {
			queue <- struct{}{}
			return err
		}
		return nil
	}
}

func voiceLeaseContext(ctx context.Context, lease *mokuVoiceLease) (context.Context, func()) {
	linked, cancel := context.WithCancel(ctx)
	detach := context.AfterFunc(lease.ctx, cancel)
	if lease.ctx.Err() != nil {
		cancel()
	}
	return linked, func() { detach(); cancel() }
}

func (v *voiceController) required(id, ownershipID, device string) (*mokuVoiceLease, error) {
	v.mu.Lock()
	lease := v.active
	v.mu.Unlock()
	current, err := v.c.current()
	if err != nil || lease == nil || lease.id != id || lease.requestID != ownershipID || lease.device != device || lease.owner != current.ID {
		return nil, errors.New("Voice owner 已失效")
	}
	v.mu.Lock()
	active := v.active == lease
	v.mu.Unlock()
	if !active {
		return nil, errors.New("Voice owner 已失效")
	}
	return lease, nil
}

func (v *voiceController) owns(owner string) bool {
	v.mu.Lock()
	lease := v.active
	v.mu.Unlock()
	if lease == nil || lease.owner != owner || lease.ctx.Err() != nil || lease.session.Closed() {
		return false
	}
	v.mu.Lock()
	defer v.mu.Unlock()
	return v.active == lease
}

func (v *voiceController) attach(lease *mokuVoiceLease) error {
	v.mu.Lock()
	v.active = lease
	v.mu.Unlock()
	detachContext := context.AfterFunc(lease.ctx, func() { v.retire(lease) })
	v.mu.Lock()
	if v.active == lease {
		lease.unsubscribeContext = detachContext
		detachContext = nil
	}
	v.mu.Unlock()
	if detachContext != nil {
		detachContext()
	}
	if source, ok := lease.session.(plugin.VoiceRequestSource); ok {
		// Native admission already belongs to the target if media ends before
		// this callback. Keep it registered on the retired session and validate
		// the durable owner/execution inside the transcript transaction instead.
		source.OnRequest(func(ctx context.Context, request plugin.VoiceDelegation, executionID string) error {
			return v.nativeRequest(ctx, lease, request, executionID)
		})
	}
	unsubscribeDelegation := lease.session.OnDelegation(func(request plugin.VoiceDelegation) {
		v.c.launch(func(ctx context.Context) { v.delegate(ctx, lease, request) })
	})
	v.mu.Lock()
	if v.active == lease {
		lease.unsubscribeDelegation = unsubscribeDelegation
		unsubscribeDelegation = nil
	}
	v.mu.Unlock()
	if unsubscribeDelegation != nil {
		unsubscribeDelegation()
	}
	// Registration may synchronously invoke OnClose for an already closed
	// session. No controller lock is held across plugin callbacks.
	unsubscribeClose := lease.session.OnClose(func() { v.retire(lease) })
	v.mu.Lock()
	if v.active == lease {
		lease.unsubscribeClose = unsubscribeClose
		unsubscribeClose = nil
	}
	v.mu.Unlock()
	if unsubscribeClose != nil {
		unsubscribeClose()
	}
	if lease.session.Closed() {
		v.retire(lease)
		return errors.New("Voice closed during preparation")
	}
	return nil
}

func (v *voiceController) nativeRequest(ctx context.Context, lease *mokuVoiceLease, request plugin.VoiceDelegation, executionID string) error {
	ctx, finish, err := v.c.begin(context.WithoutCancel(ctx))
	if err != nil {
		return err
	}
	defer finish()
	current, err := v.c.current()
	if err != nil || current.ID != lease.owner {
		return errors.New("语音所属 Moku 已更换")
	}
	if executionID == "" || current.Observation.LatestExecution == nil || current.Observation.LatestExecution.ExecutionID != executionID {
		return errors.New("语音请求所属执行已失效")
	}
	v.mu.Lock()
	if v.active == lease {
		v.deliveries[executionID] = &voiceDelivery{owner: lease.owner, session: lease.session, deliveryID: lease.id + ":" + request.ID, delegationID: request.ID, generation: request.Generation, lease: lease}
	}
	v.mu.Unlock()
	// Validate native identity in the same transaction that appends the user
	// message, so a late callback cannot write to a replaced Moku or execution.
	return v.c.config.UpdateThread(context.WithoutCancel(ctx), lease.owner, func(record *model.ThreadRecord) error {
		if !record.Moku || record.ID != lease.owner || record.Observation.LatestExecution == nil || record.Observation.LatestExecution.ExecutionID != executionID {
			return errors.New("语音请求所属执行已失效")
		}
		created := max(time.Now().UnixMilli(), record.UpdatedAt)
		for _, raw := range record.Transcript {
			var existing map[string]any
			if json.Unmarshal(raw, &existing) != nil {
				return errors.New("invalid Moku transcript")
			}
			if existing["id"] == request.ID {
				return errors.New("duplicate Moku transcript ID")
			}
			if at, ok := existing["createdAt"].(float64); ok {
				created = max(created, int64(at))
			}
		}
		message := userMessage(voiceTextInput(request.Text), request.ID, created)
		raw, err := json.Marshal(message)
		if err != nil {
			return err
		}
		record.Transcript = append(record.Transcript, raw)
		return nil
	})
}

func (v *voiceController) delegate(ctx context.Context, lease *mokuVoiceLease, request plugin.VoiceDelegation) {
	// Media owns queued requests only until target admission begins. Link that
	// wait to the lease, then keep the original service context for admitted work.
	waitCtx, finishWait := voiceLeaseContext(ctx, lease)
	err := takeVoiceQueue(waitCtx, v.admissions)
	finishWait()
	if err != nil {
		return
	}
	defer func() { v.admissions <- struct{}{} }()
	v.mu.Lock()
	active := v.active == lease && lease.ctx.Err() == nil
	v.mu.Unlock()
	if !active || lease.session.Closed() {
		return
	}
	current, err := v.c.current()
	if err != nil || current.ID != lease.owner {
		return
	}
	// Once this admission begins it belongs to Moku, independently of media
	// cancellation. Only the eventual spoken delivery uses the media lifetime.
	delivery := &voiceDelivery{owner: lease.owner, session: lease.session, deliveryID: lease.id + ":" + request.ID, delegationID: request.ID, generation: request.Generation, lease: lease}
	err = v.c.submit(ctx, SubmitRequest{Input: voiceTextInput(request.Text)}, delivery, request.Context)
	if err == nil {
		return
	}
	v.c.report("voice-admission", err)
	if lease.session.Closed() {
		return
	}
	speechCtx, cancel := voiceLeaseContext(ctx, lease)
	defer cancel()
	v.c.report("voice-speech", lease.session.Speak(speechCtx, plugin.VoiceSpeech{DeliveryID: delivery.deliveryID + ":failed", DelegationID: request.ID, Generation: request.Generation, Text: "Moku 未能接受这个请求：" + err.Error()}))
}

func (v *voiceController) retire(lease *mokuVoiceLease) {
	v.mu.Lock()
	if v.active != lease {
		v.mu.Unlock()
		return
	}
	v.active = nil
	v.retired, v.retiredID = lease.session, lease.id
	v.retiredDevice, v.retiredOwnership = lease.device, lease.requestID
	v.deliveries = make(map[string]*voiceDelivery)
	teardown := &mokuVoiceTeardown{done: make(chan struct{})}
	v.teardowns[lease] = teardown
	unsubscribeClose, unsubscribeDelegation := lease.unsubscribeClose, lease.unsubscribeDelegation
	unsubscribeContext := lease.unsubscribeContext
	lease.unsubscribeClose, lease.unsubscribeDelegation = nil, nil
	lease.unsubscribeContext = nil
	v.mu.Unlock()
	if unsubscribeContext != nil {
		unsubscribeContext()
	}
	lease.cancel()
	if unsubscribeClose != nil {
		unsubscribeClose()
	}
	if unsubscribeDelegation != nil {
		unsubscribeDelegation()
	}
	// Codex invokes OnClose synchronously from stopOnce. Join cleanup on another
	// goroutine so retirement never recursively enters Stop or blocks the native
	// notification dispatcher needed to receive the remote closed event.
	go func() {
		err := lease.session.Stop(context.Background())
		v.mu.Lock()
		teardown.err = err
		if err == nil {
			delete(v.teardowns, lease)
		}
		close(teardown.done)
		v.mu.Unlock()
	}()
}

// stop does not wait on the command or admission queue. Coordinator.ensure and
// Clear call it while holding the Moku queue; a prepare may be waiting on that
// same queue. Service shutdown cancels preparation through its parent context.
func (v *voiceController) stop(ctx context.Context) error {
	v.mu.Lock()
	lease := v.active
	v.mu.Unlock()
	if lease != nil {
		v.retire(lease)
	}
	return v.waitTeardowns(ctx)
}

func (v *voiceController) waitTeardowns(ctx context.Context) error {
	v.mu.Lock()
	pending := make([]*mokuVoiceTeardown, 0, len(v.teardowns))
	for _, teardown := range v.teardowns {
		pending = append(pending, teardown)
	}
	v.mu.Unlock()
	var failures []error
	for _, teardown := range pending {
		select {
		case <-ctx.Done():
			return errors.Join(append(failures, ctx.Err())...)
		case <-teardown.done:
			if teardown.err != nil {
				failures = append(failures, teardown.err)
			}
		}
	}
	return errors.Join(failures...)
}

func (v *voiceController) admitted(executionID string, delivery *voiceDelivery) {
	if delivery == nil || executionID == "" {
		return
	}
	current, err := v.c.current()
	if err != nil || current.ID != delivery.owner {
		return
	}
	v.mu.Lock()
	defer v.mu.Unlock()
	if v.active != nil && v.active == delivery.lease {
		v.deliveries[executionID] = delivery
	}
}

func (v *voiceController) fenceSubmit(ctx context.Context, request SubmitRequest) (*voiceDelivery, func(), func(), error) {
	noop := func() {}
	if request.VoiceInput == nil {
		return nil, noop, noop, nil
	}
	input := *request.VoiceInput
	if !mokuVoiceUUID.MatchString(input.SessionID) || !mokuVoiceUUID.MatchString(input.InputID) || !mokuVoiceUUID.MatchString(input.OwnershipID) {
		return nil, noop, noop, model.NewError("INVALID_REQUEST", "Invalid voice input fence")
	}
	lease, err := v.required(input.SessionID, input.OwnershipID, model.ClientDeviceID(ctx))
	if err != nil {
		// Typed submission remains an ordinary Moku request when its old media
		// owner is gone. It cannot fence or speak through a replacement session.
		return nil, noop, noop, nil
	}
	delivery := &voiceDelivery{owner: lease.owner, session: lease.session, deliveryID: input.InputID, generation: lease.session.InputGeneration(), lease: lease}
	fence := func() {
		current, err := v.c.current()
		if err != nil || current.ID != lease.owner {
			return
		}
		v.mu.Lock()
		active := v.active == lease
		v.mu.Unlock()
		if !active {
			return
		}
		// Capture the event emitted by this exact fence. A later native input
		// may advance InputGeneration concurrently after FenceInput returns.
		generations := make(chan int64, 1)
		unsubscribe := lease.session.OnEvent(func(event plugin.VoiceEvent) {
			if event.Type == "input" && event.InputID == input.InputID && event.Generation != nil {
				select {
				case generations <- *event.Generation:
				default:
				}
			}
		})
		generation := lease.session.InputGeneration() + 1
		lease.session.FenceInput(input.InputID)
		unsubscribe()
		select {
		case generation = <-generations:
		default:
			// A future session implementation without synchronous input events
			// gets a conservative generation, never a newer request's authority.
		}
		v.mu.Lock()
		delivery.generation = generation
		v.mu.Unlock()
	}
	reject := func() { lease.session.RejectInput(input.InputID) }
	return delivery, fence, reject, nil
}

func (v *voiceController) deliver(record model.ThreadRecord) {
	execution := record.Observation.LatestExecution
	if execution == nil || !execution.Terminal() {
		return
	}
	v.mu.Lock()
	delivery := v.deliveries[execution.ExecutionID]
	delete(v.deliveries, execution.ExecutionID)
	if delivery == nil || delivery.owner != record.ID || delivery.lease != v.active {
		v.mu.Unlock()
		return
	}
	lease := delivery.lease
	speech := plugin.VoiceSpeech{DeliveryID: delivery.deliveryID, DelegationID: delivery.delegationID, Generation: delivery.generation}
	v.mu.Unlock()
	current, err := v.c.current()
	if err != nil || current.ID != record.ID {
		return
	}
	switch execution.Status {
	case "completed":
		if v.c.config.CompletedReply != nil {
			speech.Text, _ = v.c.config.CompletedReply(record.ID, execution.ExecutionID)
		} else if execution.Summary != nil {
			speech.Text = *execution.Summary
		}
	case "interrupted":
		speech.Text = "Moku 的任务已中断，已有文字结果仍保留。"
	default:
		speech.Text = "Moku 的任务失败了，请查看任务中的错误信息。"
	}
	if speech.Text == "" {
		return
	}
	v.c.launch(func(ctx context.Context) {
		linked, cancel := voiceLeaseContext(ctx, lease)
		defer cancel()
		v.c.report("voice-speech", lease.session.Speak(linked, speech))
	})
}

// syncContext is called by the host's native ExecutionAdmission before its
// durable admission. OnRequest is too late: it observes an admitted execution.
func (v *voiceController) syncContext(ctx context.Context, owner string) error {
	v.mu.Lock()
	lease := v.active
	v.mu.Unlock()
	if lease == nil {
		return nil
	}
	syncer, ok := lease.session.(plugin.VoiceContextSync)
	if !ok {
		return nil
	}
	ctx, finish, err := v.c.begin(ctx)
	if err != nil {
		return err
	}
	defer finish()
	if err := takeVoiceQueue(ctx, v.admissions); err != nil {
		return err
	}
	defer func() { v.admissions <- struct{}{} }()
	current, err := v.c.current()
	if err != nil || current.ID != owner || lease.owner != owner {
		return errors.New("Moku native owner replaced")
	}
	v.mu.Lock()
	active := v.active == lease
	v.mu.Unlock()
	if !active {
		return errors.New("Voice owner 已失效")
	}
	linked, cancel := voiceLeaseContext(ctx, lease)
	defer cancel()
	entries, err := v.c.sendContext(linked, model.AgentInput{}, nil)
	if err != nil {
		return err
	}
	return syncer.SyncContext(linked, entries)
}

func voiceTextInput(text string) model.AgentInput {
	return model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: text}}}
}
