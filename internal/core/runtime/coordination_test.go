package runtime

import (
	"context"
	"fmt"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/store"
)

func coordinationRuntime(t *testing.T) *Runtime {
	t.Helper()
	dir := t.TempDir()
	db, err := store.Open(filepath.Join(dir, "state.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := db.Close(); err != nil {
			t.Error(err)
		}
	})
	r, err := New(context.Background(), Config{Store: db, DataDir: dir, DefaultCwd: dir})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := r.Close(context.Background()); err != nil {
			t.Error(err)
		}
	})
	return r
}
func coordinationThread(t *testing.T, r *Runtime, id string) {
	t.Helper()
	_, err := r.config.Store.Update(context.Background(), func(tx *store.Tx) error {
		return tx.Put("thread:"+id, model.ThreadRecord{SessionRecord: model.SessionRecord{ID: id, Cwd: r.config.DefaultCwd}})
	})
	if err != nil {
		t.Fatal(err)
	}
}
func assertCoordinationEmpty(t *testing.T, r *Runtime) {
	t.Helper()
	r.mu.Lock()
	defer r.mu.Unlock()
	if len(r.locks) != 0 || len(r.cancellationStates) != 0 || len(r.sendClaims) != 0 {
		t.Fatalf("retained coordination: locks=%d cancellations=%d claims=%d", len(r.locks), len(r.cancellationStates), len(r.sendClaims))
	}
}

func TestCommandLockWaiterPinsIdentity(t *testing.T) {
	r := &Runtime{}
	first := r.threadLock("thread")
	first.Lock()
	waiter := r.threadLock("thread") // pin before waiting, including scheduler delay
	first.Unlock()
	next := r.threadLock("thread")
	if waiter.lock != next.lock {
		t.Fatal("waiter and newcomer received competing mutexes")
	}
	waiter.Lock()
	waiter.Unlock()
	next.Lock()
	next.Unlock()
	if len(r.locks) != 0 {
		t.Fatal("last release retained command lock")
	}
}
func TestCommandLockConcurrentChurn(t *testing.T) {
	r := &Runtime{}
	var wg sync.WaitGroup
	var inside, overlaps atomic.Int32
	for worker := 0; worker < 32; worker++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < 100; i++ {
				lock := r.threadLock("same")
				lock.Lock()
				if inside.Add(1) != 1 {
					overlaps.Add(1)
				}
				inside.Add(-1)
				lock.Unlock()
				one := r.threadLock(fmt.Sprintf("transient-%d-%d", worker, i))
				one.Lock()
				one.Unlock()
			}
		}()
	}
	wg.Wait()
	if overlaps.Load() != 0 {
		t.Fatalf("concurrent critical sections: %d", overlaps.Load())
	}
	if len(r.locks) != 0 {
		t.Fatalf("retained %d locks", len(r.locks))
	}
}
func TestCoordinationDeleteChurn(t *testing.T) {
	r := coordinationRuntime(t)
	for i := 0; i < 100; i++ {
		id := fmt.Sprintf("thread-%d", i)
		coordinationThread(t, r, id)
		_, release, err := r.ClaimThreadInput(context.Background(), id)
		if err != nil {
			t.Fatal(err)
		}
		release()
		if err := r.DeleteThread(context.Background(), id); err != nil {
			t.Fatal(err)
		}
		assertCoordinationEmpty(t, r)
	}
}
func TestCancellationUnknownIDsDoNotAccumulate(t *testing.T) {
	r := coordinationRuntime(t)
	for i := 0; i < 100; i++ {
		id := fmt.Sprintf("missing-%d", i)
		if _, _, err := r.ClaimThreadInput(context.Background(), id); err == nil {
			t.Fatal("missing input accepted")
		}
		if _, err := r.InterruptThreadTarget(context.Background(), id, "target"); err == nil {
			t.Fatal("missing cancellation accepted")
		}
	}
	assertCoordinationEmpty(t, r)
}
func TestPendingClaimSurvivesDeletionUntilRelease(t *testing.T) {
	r := coordinationRuntime(t)
	coordinationThread(t, r, "pending")
	ctx, release, err := r.ClaimThreadInput(context.Background(), "pending")
	if err != nil {
		t.Fatal(err)
	}
	before, releaseBefore := r.cancellationState("pending")
	if err := r.DeleteThread(context.Background(), "pending"); err != nil {
		t.Fatal(err)
	}
	if ctx.Err() == nil {
		t.Fatal("delete did not cancel pending admission")
	}
	after, releaseAfter := r.cancellationState("pending")
	if after != before {
		t.Fatal("delete replaced a gate with outstanding users")
	}
	releaseAfter()
	releaseBefore()
	release()
	release()
	assertCoordinationEmpty(t, r)
}
func TestHistoryResetReclaimsCoordinationAfterPendingRelease(t *testing.T) {
	r := coordinationRuntime(t)
	for generation := 0; generation < 5; generation++ {
		coordinationThread(t, r, "pending")
		_, release, err := r.ClaimThreadInput(context.Background(), "pending")
		if err != nil {
			t.Fatal(err)
		}
		state, releaseState := r.cancellationState("pending")
		coordinationThread(t, r, "idle")
		_, releaseIdle := r.cancellationState("idle")
		releaseIdle()
		if err := r.ClearHistory(context.Background()); err != nil {
			t.Fatal(err)
		}
		r.mu.Lock()
		retained := r.cancellationStates["pending"] == state && len(r.cancellationStates) == 1
		r.mu.Unlock()
		if !retained {
			t.Fatal("history reset failed to retain only the outstanding gate")
		}
		releaseState()
		release()
		assertCoordinationEmpty(t, r)
	}
}

func TestCancellationLiveSessionIdentityRetained(t *testing.T) {
	r := coordinationRuntime(t)
	for _, private := range []bool{false, true} {
		id := fmt.Sprintf("live-%t", private)
		if private {
			_, err := r.config.Store.Update(context.Background(), func(tx *store.Tx) error {
				return tx.Put("private-session-index:"+id, "private-session:fixture")
			})
			if err != nil {
				t.Fatal(err)
			}
		} else {
			coordinationThread(t, r, id)
		}
		state, release := r.cancellationState(id)
		state.id, state.closedTarget = "cancelled-target", "cancelled-target"
		release()
		r.pruneCancellationStates()
		next, releaseNext := r.cancellationState(id)
		if state != next || next.closedTarget != "cancelled-target" {
			t.Fatal("live session lost cancellation fence")
		}
		releaseNext()
	}
}
