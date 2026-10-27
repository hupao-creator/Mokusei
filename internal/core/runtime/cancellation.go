package runtime

import (
	"context"
	"errors"
	"sync"

	"github.com/hupao-creator/Mokusei/internal/core/model"
)

// This gate is separate from the command queue: a stop must be able to cancel
// native opening and unacknowledged input without waiting behind that input.
// No native call runs with the gate held, because adapters can call Accept from
// their own event locks. The cancelling flag fences new admissions until native
// interruption has returned.
type threadCancellation struct {
	mu           sync.Mutex
	users        int // protected by Runtime.mu, includes waiters and outstanding claims
	id           string
	executionID  string
	cancelling   bool
	closedTarget string
	claims       map[*sendClaim]struct{}
}
type sendClaim struct {
	runtime  *Runtime
	threadID string
	cancel   context.CancelFunc
	ctx      context.Context
	admitted bool
}
type sendClaimKey struct{}

func (s *threadCancellation) pending() bool {
	for claim := range s.claims {
		if !claim.admitted && claim.ctx.Err() == nil {
			return true
		}
	}
	return false
}

func (r *Runtime) markInputAdmitted(ctx context.Context) error {
	claim, ok := ctx.Value(sendClaimKey{}).(*sendClaim)
	if !ok || claim.runtime != r {
		return errors.New("input admission claim is missing")
	}
	state, releaseState := r.cancellationState(claim.threadID)
	defer releaseState()
	state.mu.Lock()
	defer state.mu.Unlock()
	if err := ctx.Err(); err != nil {
		return err
	}
	if state.cancelling {
		return context.Canceled
	}
	claim.admitted = true
	return r.updateSessionThread(ctx, claim.threadID, func(t *model.ThreadRecord) error {
		t.PendingInput = state.pending()
		return nil
	})
}

func (r *Runtime) claimSend(ctx context.Context, id string) (context.Context, context.CancelFunc, error) {
	if current, ok := ctx.Value(sendClaimKey{}).(*sendClaim); ok && current.runtime == r && current.threadID == id {
		return ctx, func() {}, ctx.Err()
	}
	state, releaseState := r.cancellationState(id)
	keepState := false
	defer func() {
		if !keepState {
			releaseState()
		}
	}()
	state.mu.Lock()
	defer state.mu.Unlock()
	if err := ctx.Err(); err != nil {
		return nil, nil, err
	}
	if state.cancelling {
		return nil, nil, model.NewError("EXECUTION_CANCELLING", "The observed execution is being stopped")
	}
	thread, err := r.sessionThread(id)
	if err != nil {
		return nil, nil, err
	}
	active := thread.Observation.LatestExecution != nil && !thread.Observation.LatestExecution.Terminal()
	if state.id == "" {
		state.id = thread.CancellationID
	}
	if len(state.claims) == 0 && !active && thread.Observation.BackgroundWork == nil || state.id == "" || state.closedTarget == state.id {
		state.id, err = newID()
		if err != nil {
			return nil, nil, err
		}
		state.executionID = ""
	} else if active {
		state.executionID = thread.Observation.LatestExecution.ExecutionID
	}
	ctx, cancel := context.WithCancel(ctx)
	claim := &sendClaim{runtime: r, threadID: id, cancel: cancel, ctx: ctx}
	r.mu.Lock()
	if r.closed || r.resetting || r.deleting[id] {
		r.mu.Unlock()
		cancel()
		return nil, nil, errors.New("thread input admission is unavailable")
	}
	if r.sendClaims[id] == nil {
		r.sendClaims[id] = map[*sendClaim]struct{}{}
	}
	r.sendClaims[id][claim] = struct{}{}
	r.mu.Unlock()
	state.claims[claim] = struct{}{}
	err = r.updateSessionThread(ctx, id, func(t *model.ThreadRecord) error {
		t.CancellationID, t.PendingInput = state.id, true
		return nil
	})
	release := func() {
		defer releaseState()
		state.mu.Lock()
		defer state.mu.Unlock()
		delete(state.claims, claim)
		r.mu.Lock()
		delete(r.sendClaims[id], claim)
		if len(r.sendClaims[id]) == 0 {
			delete(r.sendClaims, id)
		}
		r.mu.Unlock()
		cancel()
		if !state.pending() {
			// The accepted task outlives its caller; only the transient input
			// marker is cleared, never the execution or cancellation identity.
			_ = r.updateSessionThread(context.WithoutCancel(ctx), id, func(t *model.ThreadRecord) error {
				t.PendingInput = false
				return nil
			})
		}
	}
	if err != nil {
		delete(state.claims, claim)
		r.mu.Lock()
		delete(r.sendClaims[id], claim)
		if len(r.sendClaims[id]) == 0 {
			delete(r.sendClaims, id)
		}
		r.mu.Unlock()
		cancel()
		return nil, nil, err
	}
	keepState = true
	var once sync.Once
	return context.WithValue(ctx, sendClaimKey{}, claim), func() { once.Do(release) }, nil
}

// ClaimThreadInput exposes cancellable admission before Moku canonicalization,
// settings resolution or native opening. Its context must reach SendMokuThread.
func (r *Runtime) ClaimThreadInput(ctx context.Context, id string) (context.Context, context.CancelFunc, error) {
	return r.claimSend(ctx, id)
}

// InterruptThreadTarget is the only public cancellation capability. A stale
// client can never stop the task that happens to occupy the thread later.
func (r *Runtime) InterruptThreadTarget(ctx context.Context, id, expected string) (model.CancellationResult, error) {
	if expected == "" {
		return model.CancellationResult{}, errors.New("cancellation identity is required")
	}
	if err := r.begin(); err != nil {
		return model.CancellationResult{}, err
	}
	defer r.operations.Done()
	state, releaseState := r.cancellationState(id)
	defer releaseState()
	state.mu.Lock()
	thread, err := r.Thread(id)
	if err != nil {
		state.mu.Unlock()
		return model.CancellationResult{}, err
	}
	active := thread.Observation.LatestExecution != nil && !thread.Observation.LatestExecution.Terminal()
	if thread.CancellationID != expected || !active && !thread.PendingInput && thread.Observation.BackgroundWork == nil || state.cancelling {
		state.mu.Unlock()
		return model.CancellationResult{Status: "stale"}, nil
	}
	state.cancelling = true
	state.closedTarget = expected
	for claim := range state.claims {
		claim.cancel()
	}
	r.mu.Lock()
	owner := r.handles[id]
	r.mu.Unlock()
	state.mu.Unlock()
	defer func() { state.mu.Lock(); state.cancelling = false; state.mu.Unlock() }()
	if owner == nil && (active || thread.Observation.BackgroundWork != nil) {
		lock := r.threadLock(id)
		lock.Lock()
		thread, err = r.Thread(id)
		if err == nil && thread.CancellationID == expected {
			owner, err = r.openThread(ctx, thread, nil)
		}
		lock.Unlock()
	}
	if err == nil && owner != nil {
		err = owner.interrupt(ctx)
	}
	if err != nil {
		return model.CancellationResult{}, err
	}
	return model.CancellationResult{Status: "cancelled"}, nil
}
