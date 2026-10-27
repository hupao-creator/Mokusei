package runtime

import (
	"context"
	"errors"
	"sort"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/core/store"
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
func (r *Runtime) SendMokuDelivery(ctx context.Context, deliveryID, id string, input model.AgentInput, injection *plugin.Injection, entries []plugin.ContextEntry) (plugin.SessionSendResult, error) {
	attempt := func() error {
		r.mokuDeliveryMu.Lock()
		defer r.mokuDeliveryMu.Unlock()
		_, err := r.config.Store.Update(ctx, func(tx *store.Tx) error {
			var delivery plugin.MokuDelivery
			found, err := tx.Get(mokuDeliveryPrefix+deliveryID, &delivery)
			if err != nil {
				return err
			}
			if !found || delivery.Uncertain {
				return errors.New("Moku delivery missing or admission uncertain; reconciliation required")
			}
			if r.mokuDeliveryEpoch == "" {
				r.mokuDeliveryEpoch, err = newID()
				if err != nil {
					return err
				}
			}
			delivery.AttemptEpoch = r.mokuDeliveryEpoch
			delivery.Uncertain = true
			return tx.Put(mokuDeliveryPrefix+deliveryID, delivery)
		})
		return err
	}
	ctx = context.WithValue(ctx, mokuDeliveryAttemptKey{}, attempt)
	return r.SendMokuThread(ctx, id, input, injection, entries, func(plugin.SessionSendResult) error {
		_, err := r.config.Store.Update(context.WithoutCancel(ctx), func(tx *store.Tx) error { return tx.Delete(mokuDeliveryPrefix + deliveryID) })
		return err
	})
}

func queueMokuDelivery(tx *store.Tx, thread model.ThreadRecord) error {
	execution := thread.Observation.LatestExecution
	id := thread.ID + ":" + execution.ExecutionID + ":" + execution.Status
	// Keep only public notification fields, not opaque native state or settings.
	thread = model.ThreadRecord{
		SessionRecord: model.SessionRecord{ID: thread.ID, HarnessID: thread.HarnessID, Cwd: thread.Cwd, UpdatedAt: thread.UpdatedAt, Observation: thread.Observation, Worktree: thread.Worktree, Revision: thread.Revision},
		Title:         thread.Title, Tags: thread.Tags,
	}
	return tx.Put(mokuDeliveryPrefix+id, plugin.MokuDelivery{ID: id, Thread: thread})
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
