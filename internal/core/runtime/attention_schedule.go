package runtime

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/services/threadattention"
)

type attentionCapability struct{ r *Runtime }
type attentionClock struct {
	NextFallback    int64
	Visible         int
	PendingCrossing bool
	Sequence        uint64
}

// Record crossings in the membership transaction. Store notifications may
// coalesce a drop below twenty and a later rise into a single wake.
func attentionChanged(tx *store.Tx, before, after bool) error {
	var clock attentionClock
	if _, err := tx.Get("attention-clock", &clock); err != nil {
		return err
	}
	clock.Sequence++
	if clock.NextFallback != 0 && before != after {
		previous := clock.Visible
		if after {
			clock.Visible++
		} else {
			clock.Visible = max(0, clock.Visible-1)
		}
		clock.PendingCrossing = clock.PendingCrossing || threadattention.CrossedThreshold(previous, clock.Visible)
	}
	return tx.Put("attention-clock", clock)
}

func attentionEligible(t model.ThreadRecord) bool {
	if !searchVisible(t) || t.MokuHistory {
		return false
	}
	e := t.Observation.LatestExecution
	return e == nil || (e.Status != "failed" && !(e.Status == "interrupted" && t.MokuInterruptedExecutionID == e.ExecutionID))
}

// Store notifications cover new candidates and first reads; the timer covers
// deadlines even when the workspace is completely idle.
func (c attentionCapability) Schedule(ctx context.Context) error {
	updates, unsubscribe := c.r.config.Store.Subscribe()
	defer unsubscribe()
	for ctx.Err() == nil {
		before := c.r.config.Store.Snapshot()
		clockHash, _ := before.RecordHash("attention-clock")
		settingsHash, _ := before.RecordHash("settings")
		next, err := c.scheduleAt(ctx, time.Now().UnixMilli())
		if err != nil {
			return err
		}
		timer := time.NewTimer(max(time.Millisecond, time.Until(time.UnixMilli(next))))
	wait:
		for {
			select {
			case <-ctx.Done():
				timer.Stop()
				return ctx.Err()
			case _, open := <-updates:
				if !open {
					timer.Stop()
					return nil
				}
				snap := c.r.config.Store.Snapshot()
				clock, _ := snap.RecordHash("attention-clock")
				settings, _ := snap.RecordHash("settings")
				if clock != clockHash || settings != settingsHash {
					timer.Stop()
					break wait
				}
			case <-timer.C:
				break wait
			}
		}
	}
	return ctx.Err()
}

func (c attentionCapability) scheduleAt(ctx context.Context, now int64) (int64, error) {
	next := now + threadattention.FallbackInterval.Milliseconds()
	_, err := c.r.config.Store.Update(ctx, func(tx *store.Tx) error {
		var clock attentionClock
		_, err := tx.Get("attention-clock", &clock)
		if err != nil {
			return err
		}
		if err := requireBackgroundExecution(tx.Snapshot(), "attention.settings"); err != nil {
			return nil
		}
		threads, err := c.r.cachedThreads(tx.Snapshot())
		if err != nil {
			return err
		}
		candidates := make([]model.ThreadRecord, 0, len(threads))
		for _, t := range threads {
			if attentionEligible(t) && !tx.Has(attentionHiddenPrefix+t.ID) {
				candidates = append(candidates, t)
			}
		}
		daily := clock.NextFallback != 0 && clock.NextFallback <= now
		all := clock.PendingCrossing || daily || threadattention.CrossedThreshold(clock.Visible, len(candidates))
		clock.PendingCrossing = false
		if clock.NextFallback == 0 || daily {
			clock.NextFallback = next
		}
		next = clock.NextFallback
		clock.Visible = len(candidates)
		for _, candidate := range candidates {
			id := candidate.ID
			var s threadattention.Thread
			if _, err := tx.Get(attentionPrefix+id, &s); err != nil {
				return err
			}
			if s.LatestExecution == "" && candidate.Observation.LatestExecution != nil {
				if err := trackAttentionExecution(tx, id, &candidate); err != nil {
					return err
				}
				if _, err := tx.Get(attentionPrefix+id, &s); err != nil {
					return err
				}
			}
			due := s.ReadWakeDue(now)
			if due {
				s.ReadWakeDelivered = true
				if err := tx.Put(attentionPrefix+id, s); err != nil {
					return err
				}
			}
			if !s.ReadWakeDelivered && s.FirstReadAt > 0 {
				next = min(next, s.FirstReadAt+threadattention.ReadDelay.Milliseconds())
			}
			if all || due {
				if err := c.r.appendEvent(tx, "attention.evaluate", store.Subject{Kind: "thread", TypeID: "agent", ID: id}, "attention.agent", map[string]any{"generation": s.Generation}, nil); err != nil {
					return err
				}
			}
		}
		return tx.Put("attention-clock", clock)
	})
	return next, err
}

func (c attentionCapability) Pending(ctx context.Context, events []plugin.LifecycleEvent) ([]plugin.LifecycleEvent, error) {
	return c.pending(ctx, c.r.config.Store.Snapshot(), events)
}
func (c attentionCapability) pending(ctx context.Context, snap store.Snapshot, events []plugin.LifecycleEvent) ([]plugin.LifecycleEvent, error) {
	rows := []plugin.LifecycleEvent{}
	seen := map[string]bool{}
	for _, e := range events {
		id := e.Subject.ID
		if seen[id] {
			continue
		}
		var s threadattention.Thread
		if _, err := snap.Get(attentionPrefix+id, &s); err != nil {
			return nil, err
		}
		var gen struct{ Generation uint64 }
		if err := json.Unmarshal(e.Data, &gen); err != nil {
			return nil, err
		}
		if s.Generation != gen.Generation || s.Hidden || !snap.Has("thread:"+id) {
			continue
		}
		t, err := c.r.cachedThread(ctx, snap, id)
		if err != nil {
			return nil, err
		}
		if !attentionEligible(t) {
			continue
		}
		seen[id] = true
		rows = append(rows, e)
	}
	return rows, nil
}

func (c attentionCapability) Evidence(ctx context.Context, events []plugin.LifecycleEvent) ([]model.Object, error) {
	snap := c.r.config.Store.Snapshot()
	pending, err := c.pending(ctx, snap, events)
	if err != nil {
		return nil, err
	}
	rows := make([]model.Object, 0, len(pending))
	for _, e := range pending {
		id := e.Subject.ID
		var s threadattention.Thread
		if _, err := snap.Get(attentionPrefix+id, &s); err != nil {
			return nil, err
		}
		t, err := c.r.cachedThread(ctx, snap, id)
		if err != nil {
			return nil, err
		}
		lengths := []int64{}
		var first, last, total int64
		for _, v := range s.Visits {
			if first == 0 || v.OpenedAt < first {
				first = v.OpenedAt
			}
			last = max(last, v.OpenedAt)
			total += v.ForegroundMillis
			lengths = append(lengths, v.ForegroundMillis)
		}
		var chars any
		if h := c.r.config.Harnesses[t.HarnessID]; h != nil {
			if a, ok := h.SessionState().(plugin.ThreadReadingLength); ok {
				count, err := a.ReadableCharacters(t.SessionState)
				if err != nil {
					return nil, err
				}
				chars = count
			}
		}
		lastCompleted := s.LastCompletedAt
		if latest := t.Observation.LatestExecution; latest != nil && latest.Status == "completed" && latest.FinishedAt != nil {
			lastCompleted = max(lastCompleted, *latest.FinishedAt)
		}
		rows = append(rows, model.Object{
			"threadId": id, "observedAt": time.Now().UnixMilli(), "revision": s.Revision,
			"opens": len(s.Visits), "firstOpenedAt": first, "lastOpenedAt": last, "foregroundMillis": total,
			"visitDurations": lengths, "readableCharacters": chars, "lastCompletedAt": lastCompleted,
		})
	}
	return rows, nil
}

func (c attentionCapability) Hide(ctx context.Context, id string, revision uint64, options plugin.BackgroundWriteOptions) (json.RawMessage, error) {
	var result json.RawMessage
	_, err := c.r.config.Store.Update(ctx, func(tx *store.Tx) error {
		if err := requireBackgroundExecution(tx.Snapshot(), "attention.settings"); err != nil {
			return err
		}
		var err error
		result, err = tx.ApplyReceipt(store.Receipt{ConsumerID: options.Batch.ConsumerID, BatchID: options.Batch.BatchID, Key: options.Batch.InvocationID}, func(tx *store.Tx) (any, error) {
			work, _, err := tx.Work(options.Batch.ConsumerID)
			if err != nil {
				return nil, err
			}
			var s threadattention.Thread
			if _, err := tx.Get(attentionPrefix+id, &s); err != nil {
				return nil, err
			}
			authorized, current := false, false
			for _, eid := range work.EventIDs {
				var e store.Event
				if _, err := tx.Get("event:"+eid, &e); err != nil {
					return nil, err
				}
				var gen struct{ Generation uint64 }
				if e.Type != "attention.evaluate" || e.Subject.ID != id {
					continue
				}
				authorized = true
				if err := json.Unmarshal(e.Data, &gen); err != nil {
					return nil, err
				}
				if gen.Generation == s.Generation {
					current = true
					break
				}
			}
			if !authorized {
				return nil, plugin.CallerError(errors.New("thread was not evaluated in this batch"))
			}
			if !current {
				return false, nil
			}
			var t model.ThreadRecord
			ok, err := tx.Get("thread:"+id, &t)
			if err != nil {
				return nil, err
			}
			if !ok || !attentionEligible(t) || !s.Hide(revision) {
				return false, nil
			}
			if err := tx.Put(attentionPrefix+id, s); err != nil {
				return nil, err
			}
			if err := attentionChanged(tx, true, false); err != nil {
				return nil, err
			}
			return true, tx.Put(attentionHiddenPrefix+id, true)
		})
		return err
	})
	return result, err
}
