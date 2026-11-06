package runtime

import (
	"context"
	"errors"
	"sort"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/services/directorytag"
)

const mokuDeliveryPrefix = "moku-delivery:"

type mokuDeliveryAttemptKey struct{}

// PendingMokuDeliveries includes uncertain attempts so operators can reconcile
// them. Delivered entries are removed only by the durable admission callback.
func (r *Runtime) PendingMokuDeliveries() ([]plugin.MokuDelivery, error) {
	snapshot := r.config.Store.Snapshot()
	result := []plugin.MokuDelivery{}
	for _, key := range snapshot.Keys(mokuDeliveryPrefix) {
		var delivery plugin.MokuDelivery
		if _, err := snapshot.Get(key, &delivery); err != nil {
			return nil, err
		}
		result = append(result, delivery)
	}
	sort.Slice(result, func(i, j int) bool {
		a, b := result[i], result[j]
		if a.Sequence != b.Sequence {
			return a.Sequence < b.Sequence
		}
		if a.Thread.UpdatedAt != b.Thread.UpdatedAt {
			return a.Thread.UpdatedAt < b.Thread.UpdatedAt
		}
		if a.Thread.Revision != b.Thread.Revision {
			return a.Thread.Revision < b.Thread.Revision
		}
		return a.ID < b.ID
	})
	return result, nil
}

type mokuDeliveryRequestKey struct{}
type mokuLazyAdmissionKey struct{}

type mokuDeliveryBatch struct {
	runtime    *Runtime
	deliveries []plugin.MokuDelivery
	epoch      string
}

func (r *Runtime) SendMokuDelivery(ctx context.Context, deliveryID, id string, input model.AgentInput, injection *plugin.Injection, entries []plugin.ContextEntry) (plugin.SessionSendResult, error) {
	ctx = context.WithValue(ctx, mokuDeliveryRequestKey{}, deliveryID)
	result, err := r.SendMokuThread(ctx, id, input, injection, entries, nil)
	if err == errMokuDeliveryUnavailable {
		return result, nil
	}
	return result, err
}

// Capture under the Moku thread lock. The attempt transaction rechecks every
// selected identity, so a stale poll cannot resend a notification already bundled
// with another input. Newly committed notifications remain for a later admission.
func (r *Runtime) prepareMokuDeliveries(ctx context.Context, entries []plugin.ContextEntry) (context.Context, []plugin.ContextEntry, *mokuDeliveryBatch, error) {
	pending, err := r.PendingMokuDeliveries()
	if err != nil {
		return ctx, entries, nil, err
	}
	requested, _ := ctx.Value(mokuDeliveryRequestKey{}).(string)
	found := requested == ""
	lazyRequest := false
	for _, delivery := range pending {
		if delivery.ID == requested {
			lazyRequest = delivery.Lazy
			break
		}
	}
	batch := &mokuDeliveryBatch{runtime: r}
	for _, delivery := range pending {
		if delivery.Uncertain {
			continue
		}
		if delivery.ID == requested {
			found = true
			if delivery.Lazy {
				ctx = context.WithValue(ctx, mokuLazyAdmissionKey{}, true)
			}
		} else if !delivery.Lazy || lazyRequest {
			continue
		} else {
			// System context remains distinct from the triggering user's input.
			entries = append(entries, plugin.ContextEntry{ID: "moku-notification:" + delivery.ID, Content: delivery.Notification})
		}
		batch.deliveries = append(batch.deliveries, delivery)
	}
	if !found {
		return ctx, entries, nil, errMokuDeliveryUnavailable
	}
	attemptContext := ctx
	ctx = context.WithValue(ctx, mokuDeliveryAttemptKey{}, func() error { return batch.attempt(attemptContext) })
	return ctx, entries, batch, nil
}

var errMokuDeliveryUnavailable = errors.New("Moku delivery already consumed or awaiting reconciliation")

func (b *mokuDeliveryBatch) attempt(ctx context.Context) error {
	if len(b.deliveries) == 0 {
		return nil
	}
	r := b.runtime
	r.mokuDeliveryMu.Lock()
	defer r.mokuDeliveryMu.Unlock()
	_, err := r.config.Store.Update(ctx, func(tx *store.Tx) error {
		if r.mokuDeliveryEpoch == "" {
			var err error
			r.mokuDeliveryEpoch, err = newID()
			if err != nil {
				return err
			}
		}
		for _, selected := range b.deliveries {
			var delivery plugin.MokuDelivery
			found, err := tx.Get(mokuDeliveryPrefix+selected.ID, &delivery)
			if err != nil {
				return err
			}
			if !found || delivery.Uncertain {
				return errMokuDeliveryUnavailable
			}
			delivery.AttemptEpoch, delivery.Uncertain = r.mokuDeliveryEpoch, true
			if err := tx.Put(mokuDeliveryPrefix+delivery.ID, delivery); err != nil {
				return err
			}
		}
		return nil
	})
	if err == nil {
		b.epoch = r.mokuDeliveryEpoch
	}
	return err
}

func (b *mokuDeliveryBatch) admitted(ctx context.Context) error {
	if len(b.deliveries) == 0 {
		return nil
	}
	_, err := b.runtime.config.Store.Update(context.WithoutCancel(ctx), func(tx *store.Tx) error {
		for _, delivery := range b.deliveries {
			if err := tx.Delete(mokuDeliveryPrefix + delivery.ID); err != nil {
				return err
			}
		}
		return nil
	})
	return err
}

func (b *mokuDeliveryBatch) releaseUnconsumed(ctx context.Context, cause error) error {
	// Only exact Core pre-consumption results synchronize with the completed
	// sender and prove replay safe. Cancellation can leave Send still running.
	_, rejected := cause.(*plugin.MokuAdmissionRejectedError)
	if !rejected && cause != plugin.ErrMokuConfigurationPending && cause != plugin.ErrMokuIdle {
		return cause
	}
	if b.epoch == "" {
		return cause
	}
	r := b.runtime
	r.mokuDeliveryMu.Lock()
	defer r.mokuDeliveryMu.Unlock()
	_, err := r.config.Store.Update(context.WithoutCancel(ctx), func(tx *store.Tx) error {
		for _, selected := range b.deliveries {
			var delivery plugin.MokuDelivery
			found, err := tx.Get(mokuDeliveryPrefix+selected.ID, &delivery)
			if err != nil {
				return err
			}
			// Deletion/reset can retire a notification while native Send ends.
			if !found {
				continue
			}
			if !delivery.Uncertain || delivery.AttemptEpoch != b.epoch {
				return errors.New("Moku delivery attempt changed before retry")
			}
			delivery.Uncertain, delivery.AttemptEpoch = false, ""
			if err := tx.Put(mokuDeliveryPrefix+delivery.ID, delivery); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		return errors.Join(cause, err)
	}
	return cause
}

func queueUserThreadInputNotification(tx *store.Tx, event store.Event) error {
	var thread model.ThreadRecord
	if _, err := tx.Get("thread:"+event.Subject.ID, &thread); err != nil {
		return err
	}
	workspace := map[string]any{}
	if thread.Cwd != "" {
		workspace["cwd"] = thread.Cwd
		workspace["directoryTag"] = directorytag.Name(thread.Cwd)
	}
	if thread.Worktree != nil {
		workspace["worktreeCwd"] = thread.Worktree.Cwd
	}
	public := map[string]any{"threadId": thread.ID, "title": thread.Title, "tags": thread.Tags, "harnessId": thread.HarnessID,
		"workspace": workspace, "updatedAt": thread.UpdatedAt, "observation": thread.Observation}
	input := plugin.MokuUserThreadInputNotification(plugin.LifecycleEvent{
		ID: event.ID, CreatedAt: event.CreatedAt, Type: event.Type,
		Subject: plugin.LifecycleSubject{Kind: event.Subject.Kind, ID: event.Subject.ID, TypeID: event.Subject.TypeID},
		Scope:   event.Scope, Source: event.Source, Data: event.Data,
	}, public)
	return queueLazyMokuNotification(tx, thread, event.ID, input.Parts[0].Text)
}

// The caller commits this alongside its originating fact. Notification contains
// only an internal system message; no input to the child is replayed to Moku.
func queueLazyMokuNotification(tx *store.Tx, thread model.ThreadRecord, eventID string, notification string) error {
	id := thread.ID + ":notification:" + eventID
	thread = model.ThreadRecord{SessionRecord: model.SessionRecord{ID: thread.ID, UpdatedAt: thread.UpdatedAt, Revision: thread.Revision}}
	return putMokuDelivery(tx, plugin.MokuDelivery{ID: id, Thread: thread, Lazy: true, Notification: notification})
}

func queueMokuDelivery(tx *store.Tx, thread model.ThreadRecord) error {
	execution := thread.Observation.LatestExecution
	id := thread.ID + ":" + execution.ExecutionID + ":" + execution.Status
	// Keep only public notification fields, not opaque native state or settings.
	thread = model.ThreadRecord{
		SessionRecord: model.SessionRecord{ID: thread.ID, HarnessID: thread.HarnessID, Cwd: thread.Cwd, UpdatedAt: thread.UpdatedAt, Observation: thread.Observation, Worktree: thread.Worktree, Revision: thread.Revision},
		Title:         thread.Title, Tags: thread.Tags,
	}
	return putMokuDelivery(tx, plugin.MokuDelivery{ID: id, Thread: thread})
}

// A monotonic transaction-owned sequence preserves admission order even when
// several facts share a millisecond or the child publishes no new revision.
func putMokuDelivery(tx *store.Tx, delivery plugin.MokuDelivery) error {
	if tx.Has(mokuDeliveryPrefix + delivery.ID) {
		return nil
	}
	var sequence int64
	if _, err := tx.Get("moku-delivery-sequence", &sequence); err != nil {
		return err
	}
	delivery.Sequence = sequence + 1
	if err := tx.Put("moku-delivery-sequence", delivery.Sequence); err != nil {
		return err
	}
	return tx.Put(mokuDeliveryPrefix+delivery.ID, delivery)
}

// ResolveMokuDelivery requires explicit operator reconciliation with the native
// conversation. Neither a transport error nor a missing local reply proves that
// the provider rejected the input.
func (r *Runtime) ResolveMokuDelivery(ctx context.Context, id, decision string) error {
	if id == "" || (decision != "retry-confirmed-unadmitted" && decision != "acknowledge-confirmed-admitted") {
		return errors.New("specify delivery id and a confirmed admission decision")
	}
	r.mokuDeliveryMu.Lock()
	defer r.mokuDeliveryMu.Unlock()
	_, err := r.config.Store.Update(ctx, func(tx *store.Tx) error {
		var delivery plugin.MokuDelivery
		found, err := tx.Get(mokuDeliveryPrefix+id, &delivery)
		if err != nil {
			return err
		}
		if !found || !delivery.Uncertain {
			return errors.New("delivery is not awaiting reconciliation")
		}
		if delivery.AttemptEpoch != "" && delivery.AttemptEpoch == r.mokuDeliveryEpoch {
			return errors.New("restart runtime before reconciling this process's uncertain native admission")
		}
		if err := r.appendEvent(tx, "entity.updated", store.Subject{Kind: "thread", ID: delivery.Thread.ID, TypeID: "agent"}, "user", map[string]string{"mokuDeliveryId": id, "admissionDecision": decision}, nil); err != nil {
			return err
		}
		if decision == "acknowledge-confirmed-admitted" {
			return tx.Delete(mokuDeliveryPrefix + id)
		}
		delivery.Uncertain = false
		return tx.Put(mokuDeliveryPrefix+id, delivery)
	})
	return err
}

// Native voice has its own admission instead of SendMokuThread. Accept owns this
// holder through its durable execution commit; syncing context alone is not an
// admission receipt. A failed/uncertain sync retains the same reconciliation fence.
type mokuNativeDeliveryKey struct{}
type mokuNativeDelivery struct{ batch *mokuDeliveryBatch }

func (r *Runtime) SyncMokuVoiceContext(ctx context.Context, syncer plugin.VoiceContextSync, entries []plugin.ContextEntry) error {
	holder, ok := ctx.Value(mokuNativeDeliveryKey{}).(*mokuNativeDelivery)
	if !ok {
		return errors.New("Moku voice context requires native admission ownership")
	}
	_, entries, batch, err := r.prepareMokuDeliveries(ctx, entries)
	if err != nil {
		return err
	}
	holder.batch = batch
	if err := batch.attempt(ctx); err != nil {
		return err
	}
	return syncer.SyncContext(ctx, entries)
}
