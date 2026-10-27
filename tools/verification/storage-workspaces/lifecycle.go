package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"

	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/platform/sqlite"
)

func replayLifecycleValidation(ctx context.Context, root string) {
	path := filepath.Join(root, "lifecycle.sqlite")
	db, err := store.Open(path)
	must(err)
	event := func(id string) store.Event {
		return store.Event{ID: id, CreatedAt: 1, Type: "entity.created", Subject: store.Subject{Kind: "thread", ID: "fixture", TypeID: "fixture"}, Source: "fixture", Data: json.RawMessage(`{}`)}
	}
	work := func(id string, events ...string) store.Work {
		return store.Work{ID: id, EventIDs: events, Receipts: map[string]json.RawMessage{}}
	}
	update := func(apply func(*store.Tx) error) store.Snapshot {
		snapshot, err := db.Update(ctx, apply)
		must(err)
		return snapshot
	}
	seed := update(func(tx *store.Tx) error {
		for _, id := range []string{"a", "b", "c"} {
			if err := tx.AppendEvent(event(id)); err != nil {
				return err
			}
		}
		if err := tx.SetWork("worker", "", work("batch", "a")); err != nil {
			return err
		}
		return tx.Put("lifecycle-outcome:observer:b", store.Processed)
	})
	check(seed.EventRevision() == seed.Revision() && seed.LifecycleRevision() == seed.Revision(), "event commit did not advance lifecycle markers")
	notifications, unsubscribe := db.Subscribe()
	defer unsubscribe()
	<-notifications
	unchanged := func(before store.Snapshot, label string) {
		after := db.Snapshot()
		check(after.Revision() == before.Revision() && after.EventRevision() == before.EventRevision() && after.LifecycleRevision() == before.LifecycleRevision(), label+" published revision markers")
		select {
		case <-notifications:
			panic(label + " published a notification")
		default:
		}
	}
	must(db.Flush(ctx))
	update(func(tx *store.Tx) error { return tx.Put("event:a", event("a")) })
	unchanged(seed, "no-op")
	unrelated := update(func(tx *store.Tx) error { return tx.Put("settings", map[string]bool{"fixture": true}) })
	check(unrelated.Revision() > seed.Revision() && unrelated.EventRevision() == seed.EventRevision() && unrelated.LifecycleRevision() == seed.LifecycleRevision(), "unrelated commit advanced lifecycle markers")
	workChanged := update(func(tx *store.Tx) error {
		current, exists, err := tx.Work("worker")
		if err != nil {
			return err
		}
		check(exists, "transaction lost committed work")
		current.Attempts++
		if err := tx.SetWork("worker", "batch", current); err != nil {
			return err
		}
		staged, _, err := tx.Work("worker")
		check(staged.Attempts == 1, "transaction work read ignored staged writes")
		staged.EventIDs[0] = "mutated"
		staged.Receipts["mutation"] = json.RawMessage(`true`)
		again, _, readErr := tx.Work("worker")
		check(again.EventIDs[0] == "a" && len(again.Receipts) == 0, "transaction work read returned aliased data")
		return errors.Join(err, readErr)
	})
	check(workChanged.EventRevision() == seed.EventRevision() && workChanged.LifecycleRevision() == workChanged.Revision(), "work commit changed the wrong lifecycle markers")
	outcomeChanged := update(func(tx *store.Tx) error { return tx.Put("lifecycle-outcome:observer:b", store.Failed) })
	check(outcomeChanged.EventRevision() == seed.EventRevision() && outcomeChanged.LifecycleRevision() == outcomeChanged.Revision(), "outcome commit changed the wrong lifecycle markers")
	<-notifications
	reject := func(label string, apply func(*store.Tx) error) {
		before := db.Snapshot()
		_, err := db.Update(ctx, func(tx *store.Tx) error {
			if err := tx.Put("rejected-marker", label); err != nil {
				return err
			}
			return apply(tx)
		})
		check(err != nil, label+" was accepted")
		check(!db.Snapshot().Has("rejected-marker"), label+" partially committed")
		unchanged(before, label)
	}
	for _, fixture := range []struct {
		name  string
		apply func(*store.Tx) error
	}{
		{"event identity", func(tx *store.Tx) error { return tx.Put("event:alias", event("different")) }},
		{"event fields", func(tx *store.Tx) error {
			invalid := event("invalid")
			invalid.Type = "unsupported"
			return tx.Put("event:invalid", invalid)
		}},
		{"event immutability", func(tx *store.Tx) error {
			changed := event("a")
			changed.CreatedAt++
			return tx.Put("event:a", changed)
		}},
		{"work consumer", func(tx *store.Tx) error { return tx.Put("lifecycle-work:bad/id", work("batch", "a")) }},
		{"work missing reference", func(tx *store.Tx) error { return tx.Put("lifecycle-work:worker", work("batch", "missing")) }},
		{"work acknowledged reference", func(tx *store.Tx) error { return tx.Put("lifecycle-work:observer", work("batch", "b")) }},
		{"outcome identity", func(tx *store.Tx) error { return tx.Put("lifecycle-outcome:invalid", store.Processed) }},
		{"outcome consumer", func(tx *store.Tx) error { return tx.Put("lifecycle-outcome:bad/id:b", store.Processed) }},
		{"outcome missing reference", func(tx *store.Tx) error { return tx.Put("lifecycle-outcome:observer:missing", store.Processed) }},
		{"outcome value", func(tx *store.Tx) error { return tx.Put("lifecycle-outcome:observer:b", "unsupported") }},
		{"outcome invalidates unchanged work", func(tx *store.Tx) error { return tx.Put("lifecycle-outcome:worker:a", store.Processed) }},
		{"delete event with unchanged work", func(tx *store.Tx) error { return tx.Delete("event:a") }},
		{"delete event with unchanged outcome", func(tx *store.Tx) error { return tx.Delete("event:b") }},
		{"callback rollback", func(tx *store.Tx) error {
			if err := tx.AppendEvent(event("rolled-back")); err != nil {
				return err
			}
			return errors.New("discard parent transaction")
		}},
		{"child transaction invalid event", func(tx *store.Tx) error {
			_, err := tx.ApplyReceipt(store.Receipt{ConsumerID: "worker", BatchID: "batch", Key: "invalid-child"}, func(child *store.Tx) (any, error) {
				return true, child.Put("event:child-alias", event("child-mismatch"))
			})
			return err
		}},
		{"child transaction event deletion", func(tx *store.Tx) error {
			_, err := tx.ApplyReceipt(store.Receipt{ConsumerID: "worker", BatchID: "batch", Key: "invalid-delete"}, func(child *store.Tx) (any, error) {
				return true, child.Delete("event:a")
			})
			return err
		}},
	} {
		reject(fixture.name, fixture.apply)
	}
	beforeChild := db.Snapshot()
	childCommitted := update(func(tx *store.Tx) error {
		if err := tx.AppendEvent(event("parent")); err != nil {
			return err
		}
		receipt := store.Receipt{ConsumerID: "worker", BatchID: "batch", Key: "effect"}
		calls := 0
		apply := func(child *store.Tx) (any, error) {
			calls++
			if err := child.SetWork("child", "", work("child-batch", "parent")); err != nil {
				return nil, err
			}
			return "result", child.AppendEvent(event("child"))
		}
		first, err := tx.ApplyReceipt(receipt, apply)
		if err != nil {
			return err
		}
		second, err := tx.ApplyReceipt(receipt, apply)
		if err != nil {
			return err
		}
		check(calls == 1 && string(first) == string(second) && tx.Has("event:child"), "child receipt did not atomically deduplicate its effect")
		_, err = tx.ApplyReceipt(store.Receipt{ConsumerID: "worker", BatchID: "batch", Key: "discard"}, func(child *store.Tx) (any, error) {
			if err := child.AppendEvent(event("discarded")); err != nil {
				return nil, err
			}
			return nil, errors.New("discard child effect")
		})
		check(err != nil && !tx.Has("event:discarded"), "failed child effect entered parent transaction")
		return nil
	})
	check(childCommitted.EventRevision() == childCommitted.Revision() && childCommitted.LifecycleRevision() == childCommitted.Revision(), "child changes did not advance one committed marker")
	check(!beforeChild.Has("event:child") && beforeChild.EventRevision() == seed.EventRevision(), "child changes mutated old snapshot")
	deleted := update(func(tx *store.Tx) error {
		if err := tx.Delete("lifecycle-outcome:observer:b"); err != nil {
			return err
		}
		return tx.Delete("event:b")
	})
	check(!deleted.Has("event:b") && deleted.EventRevision() == deleted.Revision() && deleted.LifecycleRevision() == deleted.Revision(), "event/outcome deletion did not publish markers")
	update(func(tx *store.Tx) error {
		if err := tx.Put("lifecycle-work:worker", work("batch", "c")); err != nil {
			return err
		}
		return tx.Delete("event:a")
	})
	settled := update(func(tx *store.Tx) error { return tx.SettleWork("worker", "batch", store.Processed) })
	check(!settled.Has("lifecycle-work:worker") && settled.Has("lifecycle-outcome:worker:c") && settled.EventRevision() < settled.LifecycleRevision(), "settlement lost atomic work/outcome or marker semantics")
	update(func(tx *store.Tx) error {
		if err := tx.AppendEvent(event("new")); err != nil {
			return err
		}
		if err := tx.SetWork("new-worker", "", work("new-batch", "new")); err != nil {
			return err
		}
		return tx.Put("lifecycle-outcome:new-observer:new", store.Processed)
	})
	<-notifications
	for _, write := range []bool{false, true} {
		before := db.Snapshot()
		cancelled, cancel := context.WithCancel(ctx)
		_, err = db.Update(cancelled, func(tx *store.Tx) error {
			cancel()
			if write {
				return tx.AppendEvent(event("cancelled"))
			}
			return nil
		})
		cancel()
		check(errors.Is(err, context.Canceled), "cancelled callback lost cancellation")
		unchanged(before, "cancelled callback")
	}
	final := db.Snapshot()
	must(db.Close())
	db, err = store.Open(path)
	must(err)
	reopened := db.Snapshot()
	check(reopened.Revision() == final.Revision() && reopened.EventRevision() == reopened.Revision() && reopened.LifecycleRevision() == reopened.Revision(), "reopen did not initialize lifecycle markers from durable revision")
	check(reopened.Has("event:child") && reopened.Has("lifecycle-outcome:worker:c") && !reopened.Has("event:discarded"), "reopen lost child or settlement durability")
	must(db.Close())
	// Opening remains a complete trust boundary even when the corrupt record was
	// never touched by an otherwise valid transaction in this process.
	native, err := sqlite.Open(path, false)
	must(err)
	must(native.Exec("INSERT INTO records(key,body) VALUES (?,?)", "lifecycle-outcome:observer:missing", []byte(`"processed"`)))
	must(native.Close())
	corrupt, err := store.Open(path)
	if err == nil {
		_ = corrupt.Close()
		panic("open accepted a dangling historical lifecycle reference")
	}
	fmt.Println("PASS incremental lifecycle validation, unchanged reverse references, parent/child receipts, no-op/cancellation publication, immutable change markers and full reopen validation")
}
