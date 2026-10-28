package runtime

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/services/threadsearch"
)

func (r *Runtime) ForkThread(ctx context.Context, id string, request json.RawMessage) (string, error) {
	if err := r.begin(); err != nil {
		return "", err
	}
	defer r.operations.Done()
	ctx, cancelOperation := r.operationContext(ctx)
	defer cancelOperation()
	lock := r.threadLock(id)
	lock.Lock()
	defer lock.Unlock()
	if r.IsDeleting(id) {
		return "", errors.New("thread deletion is in progress")
	}
	r.mu.Lock()
	owner := r.handles[id]
	r.mu.Unlock()
	if owner != nil {
		owner.admissionMu.Lock()
		if err := owner.active(); err != nil {
			owner.admissionMu.Unlock()
			return "", err
		}
		owner.mu.Lock()
		busy := owner.forking || owner.activeSends != 0 || owner.admission != nil
		if !busy {
			owner.forking = true
		}
		owner.mu.Unlock()
		owner.admissionMu.Unlock()
		if busy {
			return "", errors.New("thread still has pending native work")
		}
		defer func() { owner.mu.Lock(); owner.forking = false; owner.mu.Unlock() }()
		stopOwner := context.AfterFunc(owner.ctx, cancelOperation)
		defer stopOwner()
	}
	source, err := r.Thread(id)
	if err != nil {
		return "", err
	}
	if source.Moku || source.MokuHistory {
		return "", errors.New("Moku thread cannot be forked")
	}
	if archived(&source) || source.Observation.BackgroundWork != nil {
		return "", errors.New("thread is not available for fork")
	}
	if e := source.Observation.LatestExecution; e != nil && !e.Terminal() {
		return "", errors.New("cannot fork an active execution")
	}
	if r.config.Workspaces != nil {
		if err := r.config.Workspaces.ValidateThread(ctx, source); err != nil {
			return "", err
		}
	}
	h, err := r.harness(ctx, source)
	if err != nil {
		return "", err
	}
	forker, ok := h.(plugin.Forker)
	if !ok {
		return "", errors.New("harness does not support forks")
	}
	derived, err := forker.Fork(ctx, plugin.ForkRequest{Source: source, Request: request})
	if err != nil {
		return "", err
	}
	id, err = newID()
	if err != nil {
		return "", err
	}
	next := source
	next.ID = id
	next.Revision = 0
	next.Worktree = nil
	next.CreatedAt = time.Now().UnixMilli()
	next.UpdatedAt = next.CreatedAt
	next.SessionState = derived.SessionState
	next.MetadataState = derived.MetadataState
	if len(derived.Settings) > 0 {
		next.Settings = derived.Settings
	}
	next.Observation, err = h.SessionState().Project(next.SessionState)
	if err != nil {
		return "", err
	}
	if err := validateObservation(next.Observation); err != nil {
		return "", err
	}
	if next.Observation.BackgroundWork != nil || (next.Observation.LatestExecution != nil && !next.Observation.LatestExecution.Terminal()) {
		return "", errors.New("fork must not introduce active native work")
	}
	if len(next.MetadataState) == 0 {
		next.MetadataState, err = h.Metadata().Fork(source.MetadataState, source.Title)
		if err != nil {
			return "", err
		}
	}
	next.Title, err = h.Metadata().Project(next.MetadataState)
	if err != nil {
		return "", err
	}
	zero := int64(0)
	next.MetadataRevision = &zero
	if r.config.Workspaces != nil {
		if err := r.config.Workspaces.ValidateThread(ctx, source); err != nil {
			return "", err
		}
	}
	if r.config.Attachments != nil {
		if err = r.config.Attachments.InheritOwners(ctx, source.ID, id); err != nil {
			return "", err
		}
	}
	_, err = r.config.Store.Update(ctx, func(tx *store.Tx) error {
		if r.IsDeleting(source.ID) {
			return errors.New("source thread deletion is in progress")
		}
		var current model.ThreadRecord
		ok, err := tx.Get("thread:"+source.ID, &current)
		if err != nil {
			return err
		}
		if !ok || current.Revision != source.Revision {
			return errors.New("source thread changed during fork")
		}
		if err = tx.Put("thread:"+id, next); err != nil {
			return err
		}
		if err = tx.SetOrder("threads", append(tx.Order("threads"), id)); err != nil {
			return err
		}
		if err = r.threadEvents(tx, nil, &next); err != nil {
			return err
		}
		return r.appendEvent(tx, "thread.inventory", store.Subject{Kind: "thread", TypeID: "agent", ID: id}, "application", map[string]any{}, nil)
	})
	if err != nil && r.config.Attachments != nil {
		r.log("fork.attachment.rollback", r.config.Attachments.ReleaseOwner(context.WithoutCancel(ctx), id))
	}
	return id, err
}
func (r *Runtime) SetArchived(ctx context.Context, id string, value bool) error {
	if err := r.begin(); err != nil {
		return err
	}
	defer r.operations.Done()
	ctx, cancelOperation := r.operationContext(ctx)
	defer cancelOperation()
	lock := r.threadLock(id)
	lock.Lock()
	defer lock.Unlock()
	if r.IsDeleting(id) {
		return errors.New("thread deletion is in progress")
	}
	if value {
		if err := r.endThreadVoice(ctx, id); err != nil {
			return err
		}
	}
	err := r.UpdateThread(ctx, id, func(t *model.ThreadRecord) error {
		if t.Moku {
			return errors.New("Moku thread cannot be archived")
		}
		if t.MokuHistory && !value {
			return errors.New("Moku history is read-only and cannot be unarchived")
		}
		t.Archived = &value
		return nil
	})
	if err == nil && value {
		return r.endThreadVoice(ctx, id)
	}
	return err
}

// Restore only durable owners requiring cleanup; opening never submits input.
// A Harness owns recovery semantics (including retirement of lost native work).
// Unknown/disabled Harnesses must fail closed rather than discard their records.
func (r *Runtime) restoreHistoryOwners(ctx context.Context) error {
	if err := r.begin(); err != nil {
		return err
	}
	defer r.operations.Done()
	snapshot := r.config.Store.Snapshot()
	threads, err := readThreads(snapshot)
	if err != nil {
		return err
	}
	for _, key := range snapshot.Keys("private-session:") {
		var session plugin.PrivateSessionSnapshot
		if _, err := snapshot.Get(key, &session); err != nil {
			return err
		}
		threads = append(threads, model.ThreadRecord{SessionRecord: session.Record})
	}
	for _, thread := range threads {
		if thread.Observation.BackgroundWork == nil {
			continue
		}
		r.mu.Lock()
		owned := r.handles[thread.ID] != nil
		r.mu.Unlock()
		if owned {
			continue
		}
		r.cancelSendClaims(thread.ID)
		lock := r.threadLock(thread.ID)
		lock.Lock()
		current, err := r.sessionThread(thread.ID)
		if err == nil && current.Observation.BackgroundWork != nil {
			_, err = r.openThread(ctx, current, nil)
		}
		lock.Unlock()
		if err != nil {
			return fmt.Errorf("history was kept: cannot recover native work for session %s: %w", thread.ID, err)
		}
	}
	return nil
}

func (r *Runtime) assertHistoryResettable() error {
	snapshot := r.config.Store.Snapshot()
	threads, err := readThreads(snapshot)
	if err != nil {
		return err
	}
	for _, thread := range threads {
		if thread.Observation.BackgroundWork != nil {
			return fmt.Errorf("history was kept: native background work has not stopped for thread %s", thread.ID)
		}
	}
	for _, key := range snapshot.Keys("private-session:") {
		var session plugin.PrivateSessionSnapshot
		if _, err := snapshot.Get(key, &session); err != nil {
			return err
		}
		if session.Record.Observation.BackgroundWork != nil {
			return fmt.Errorf("history was kept: native background work has not stopped for private session %s", session.Record.ID)
		}
	}
	return nil
}

// ClearHistory fences admission before draining every handle. A failed close
// leaves the generation fenced instead of installing competing native owners.
func (r *Runtime) ClearHistory(ctx context.Context) error {
	r.lifecycleMu.Lock()
	defer r.lifecycleMu.Unlock()
	if err := ctx.Err(); err != nil {
		return err
	}
	if err := r.restoreHistoryOwners(ctx); err != nil {
		return err
	}
	r.mu.Lock()
	if r.closed || r.resetting {
		r.mu.Unlock()
		return errors.New("runtime is unavailable")
	}
	r.resetting = true
	r.generationCancel()
	handles := make([]*threadHandle, 0, len(r.handles))
	for _, h := range r.handles {
		handles = append(handles, h)
	}
	r.mu.Unlock()
	var errs []error
	if r.search != nil {
		if err := r.search.Pause(); err != nil {
			errs = append(errs, err)
		}
	}
	if err := r.closeVoice(ctx); err != nil {
		errs = append(errs, err)
	}
	if coordinator, ok := r.config.Moku.(plugin.RuntimeParticipant); ok {
		if err := coordinator.Stop(ctx); err != nil {
			errs = append(errs, err)
		}
	}
	if r.config.Contexts != nil {
		if err := r.config.Contexts.Stop(ctx); err != nil {
			errs = append(errs, err)
		}
	}
	if participants, ok := r.config.Applications.(plugin.RuntimeParticipant); ok {
		if err := participants.Stop(ctx); err != nil {
			errs = append(errs, err)
		}
	}
	for _, h := range handles {
		if err := h.close(); err != nil {
			errs = append(errs, fmt.Errorf("history was kept: cannot stop native session %s: %w", h.id, err))
		}
	}
	r.operations.Wait()
	if len(errs) > 0 {
		return errors.Join(errs...)
	}
	// Native cleanup can publish background state after the initial preflight.
	// History cannot be replaced until every such durable owner is accounted for.
	if err := r.assertHistoryResettable(); err != nil {
		return err
	}
	threads, err := r.Threads()
	if err != nil {
		return err
	}
	// Persist an empty Moku shell in the same replacement transaction. Its
	// existence cannot depend on native discovery succeeding during restart.
	var moku model.ThreadRecord
	for _, thread := range threads {
		if thread.Moku {
			moku = thread
			break
		}
	}
	if moku.HarnessID == "" {
		for _, id := range r.harnessIDs() {
			if r.config.Harnesses[id].Descriptor().ThreadCapabilities.CanHostMoku() {
				moku.HarnessID = id
				break
			}
		}
	}
	if moku.HarnessID != "" {
		id, err := newID()
		if err != nil {
			return err
		}
		settings, cwd := model.CloneRaw(moku.Settings), moku.Cwd
		if len(settings) == 0 {
			settings = json.RawMessage(`{}`)
		}
		if cwd == "" {
			cwd = r.config.DefaultCwd
		}
		at := time.Now().UnixMilli()
		moku = model.ThreadRecord{SessionRecord: model.SessionRecord{ID: id, HarnessID: moku.HarnessID, SessionState: json.RawMessage("null"), Settings: settings, Cwd: cwd, CreatedAt: at, UpdatedAt: at}, Moku: true, Title: "Moku", Tags: []string{}, TagEmojis: map[string]string{}, Transcript: []json.RawMessage{}}
	}
	_, err = r.config.Store.Update(ctx, func(tx *store.Tx) error {
		if err := threadsearch.ClearHistory(tx); err != nil {
			return err
		}
		for _, prefix := range []string{mokuDeliveryPrefix, "directory-scope:", "thread:", "interaction-answer:", "telemetry:", "event:", "lifecycle-work:", "lifecycle-outcome:", "private-session:", "private-session-index:", "application-receipt:", "tag-receipt:", "semantic-tags:", "tag-redirects:", "tag-inventory-initialized:"} {
			for _, key := range tx.Keys(prefix) {
				if err := tx.Delete(key); err != nil {
					return err
				}
			}
		}
		if resetter, ok := r.config.Applications.(interface{ ClearHistory(*store.Tx) error }); ok {
			if err := resetter.ClearHistory(tx); err != nil {
				return err
			}
		}
		if err := tx.SetOrder("threads", nil); err != nil {
			return err
		}
		for _, key := range []string{"tag-redirects", "semantic-tags", "tag-inventory-initialized", "moku-applied-settings"} {
			if err := tx.Delete(key); err != nil {
				return err
			}
		}
		if moku.ID != "" {
			if err := tx.Put("thread:"+moku.ID, moku); err != nil {
				return err
			}
			if err := tx.SetOrder("threads", []string{moku.ID}); err != nil {
				return err
			}
			if err := r.threadEvents(tx, nil, &moku); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		return err
	}
	r.pruneCancellationStates()
	if err := r.clearVoice(ctx); err != nil {
		return err
	}
	if r.config.Attachments != nil {
		owners := []string{}
		if moku.ID != "" {
			owners = append(owners, moku.ID)
		}
		if err = r.config.Attachments.RetainOwners(ctx, owners); err != nil {
			r.log("history.attachments", err)
		}
	}
	if r.config.Workspaces != nil {
		if err := r.config.Workspaces.ClearOwned(ctx); err != nil {
			r.log("history.workspaces", err)
		}
	}
	r.lifecycle.mu.Lock()
	r.lifecycle.consumers = map[string]*lifecycleConsumer{}
	r.lifecycle.mu.Unlock()
	r.mu.Lock()
	r.generation++
	r.generationCtx, r.generationCancel = context.WithCancel(r.ctx)
	generationCtx := r.generationCtx
	r.handles = map[string]*threadHandle{}
	r.resetting = false
	r.mu.Unlock()
	if r.search != nil {
		r.search.Resume()
	}
	if r.config.Contexts != nil {
		if err := r.config.Contexts.Start(generationCtx, plugin.RuntimeStartContext{Reason: "history-reset"}); err != nil {
			// Moku must never resume before its Context services are ready.
			return err
		}
	}
	if coordinator, ok := r.config.Moku.(plugin.RuntimeParticipant); ok {
		if err := coordinator.Start(generationCtx, plugin.RuntimeStartContext{Reason: "history-reset"}); err != nil {
			errs = append(errs, err)
		}
	}
	if participants, ok := r.config.Applications.(plugin.RuntimeParticipant); ok {
		if err := participants.Start(generationCtx, plugin.RuntimeStartContext{Reason: "history-reset"}); err != nil {
			errs = append(errs, err)
		}
	}
	r.Publish()
	return errors.Join(errs...)
}
