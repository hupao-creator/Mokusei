package main

import (
	"context"
	"encoding/json"
	"fmt"
	"maps"
	"math/rand/v2"
	"path/filepath"
	"runtime"
	"slices"
	"strings"

	"github.com/hupao-creator/Mokusei/internal/core/store"
)

func replayLocalStoreChanges(ctx context.Context, root string) {
	db, err := store.Open(filepath.Join(root, "local-changes.sqlite"))
	must(err)
	defer func() { must(db.Close()) }()
	type retained struct {
		snapshot store.Snapshot
		values   map[string]int
	}
	values := map[string]int{}
	history := []retained{{db.Snapshot(), maps.Clone(values)}}
	random := rand.New(rand.NewPCG(19, 23))
	prefixes := []string{"a", "alpha", "alpine", "app:", "thread:", "线程:", "😀:", strings.Repeat("x", 1010)}
	for step := range 80 {
		snapshot, err := db.Update(ctx, func(tx *store.Tx) error {
			for range 8 {
				key := prefixes[random.IntN(len(prefixes))] + fmt.Sprintf("%d", random.IntN(20))
				if random.IntN(3) == 0 {
					delete(values, key)
					must(tx.Delete(key))
				} else {
					values[key] = step
					must(tx.Put(key, step))
				}
			}
			return nil
		})
		must(err)
		previous := history[random.IntN(len(history))]
		for _, prefix := range append([]string{"", "missing", "al", "线程"}, prefixes...) {
			keys, changes := []string{}, []string{}
			for key, value := range values {
				if strings.HasPrefix(key, prefix) {
					keys = append(keys, key)
					old, existed := previous.values[key]
					if !existed || old != value {
						changes = append(changes, key)
					}
				}
			}
			for key := range previous.values {
				if _, exists := values[key]; !exists && strings.HasPrefix(key, prefix) {
					changes = append(changes, key)
				}
			}
			slices.Sort(keys)
			slices.Sort(changes)
			check(slices.Equal(snapshot.Keys(prefix), keys) && snapshot.Count(prefix) == len(keys), "prefix keys/count lost a compressed branch")
			check(slices.Equal(snapshot.ChangedKeys(previous.snapshot, prefix), changes), "forward snapshot diff lost or invented a key")
			check(slices.Equal(previous.snapshot.ChangedKeys(snapshot, prefix), changes), "reverse snapshot diff lost or invented a key")
			check(snapshot.PrefixEqual(previous.snapshot, prefix) == (len(changes) == 0), "prefix equality disagreed with exact source changes")
		}
		for key, expected := range previous.values {
			var actual int
			exists, err := previous.snapshot.Get(key, &actual)
			must(err)
			check(exists && actual == expected, "later path copy mutated a retained snapshot")
		}
		if step%8 == 0 {
			history = append(history, retained{snapshot, maps.Clone(values)})
		}
	}
	base := db.Snapshot()
	var staged store.Snapshot
	final, err := db.Update(ctx, func(tx *store.Tx) error {
		must(tx.Put("staged", 1))
		must(tx.SetOrder("fixture", []string{"first", "second"}))
		staged = tx.Snapshot()
		must(tx.Put("staged", 2))
		return tx.SetOrder("fixture", []string{"second", "first"})
	})
	must(err)
	var stagedValue int
	_, err = staged.Get("staged", &stagedValue)
	must(err)
	check(stagedValue == 1 && slices.Equal(staged.Order("fixture"), []string{"first", "second"}), "staged snapshot aliased later transaction writes")
	check(final.OrderChanged(staged, "fixture") && staged.OrderChanged(base, "fixture") && !final.OrderChanged(base, "unrelated"), "order identity change tracking")
	measureSnapshot := func(count int) uint64 {
		db, err := store.Open(filepath.Join(root, fmt.Sprintf("snapshot-scale-%d.sqlite", count)))
		must(err)
		defer func() { must(db.Close()) }()
		_, err = db.Update(ctx, func(tx *store.Tx) error {
			for i := range count {
				must(tx.Put(fmt.Sprintf("unrelated:%08d", i), i))
			}
			return tx.Put("telemetry:active", 0)
		})
		must(err)
		var bytes uint64
		_, err = db.Update(ctx, func(tx *store.Tx) error {
			must(tx.Put("telemetry:active", 1))
			// Isolate snapshot allocation from SQLite, input encoding and initial
			// data loading. This executes the actual transaction snapshot path.
			var before, after runtime.MemStats
			runtime.ReadMemStats(&before)
			var last store.Snapshot
			for range 64 {
				last = tx.Snapshot()
			}
			runtime.ReadMemStats(&after)
			bytes = (after.TotalAlloc - before.TotalAlloc) / 64
			check(last.Count("") == count+1, "scaling probe lost records")
			return nil
		})
		must(err)
		return bytes
	}
	small, large := measureSnapshot(64), measureSnapshot(4096)
	check(large <= small*2+4096, fmt.Sprintf("one-key snapshot allocation grows with unrelated records: %d -> %d bytes", small, large))
	fmt.Printf("PASS persistent snapshots, prefix/delta/order identity, retained/staged views; one-key snapshot allocation 64/4096 unrelated records: %d/%d bytes\n", small, large)
}

func replayLocalLifecycleChanges(ctx context.Context, root string) {
	path := filepath.Join(root, "lifecycle-local-changes.sqlite")
	db, err := store.Open(path)
	must(err)
	update := func(apply func(*store.Tx) error) store.Snapshot {
		snapshot, err := db.Update(ctx, apply)
		must(err)
		return snapshot
	}
	event := func(id, scope, kind, source string, createdAt int64) store.Event {
		return store.Event{ID: id, CreatedAt: createdAt, Scope: scope, Type: kind, Source: source, Subject: store.Subject{Kind: "thread", TypeID: "agent", ID: "fixture"}, Data: json.RawMessage(`{"retained":true}`)}
	}
	filters := []store.Filter{{Scope: "local", Types: []string{"execution.completed"}, Sources: []string{"application"}}}
	seed := update(func(tx *store.Tx) error {
		for i := range 256 {
			id := fmt.Sprintf("old-%04d", i)
			must(tx.AppendEvent(event(id, "local", "execution.completed", "application", int64(i))))
			must(tx.Put("lifecycle-outcome:worker:"+id, store.Processed))
			must(tx.AppendEvent(event("foreign-"+id, "foreign", "execution.completed", "application", int64(i))))
		}
		return tx.AppendEvent(event("pending", "local", "execution.completed", "application", 500))
	})
	reader := store.NewPendingReader("worker", filters, nil)
	live, err := store.NewEventReader(seed, filters)
	must(err)
	read := func(snapshot store.Snapshot, expected ...string) {
		pending, err := reader.Read(snapshot, store.PendingQuery{})
		must(err)
		ids := []string{}
		for _, item := range pending {
			ids = append(ids, item.ID)
		}
		check(slices.Equal(ids, expected), fmt.Sprintf("consumer pending reconciliation: got %v want %v", ids, expected))
		if len(pending) > 0 {
			pending[0].Data[0] = '!'
		}
	}
	read(seed, "pending")
	local, stopLocal := db.SubscribeLifecycle("worker", filters, "private-session:observed")
	foreign, stopForeign := db.SubscribeLifecycle("other", []store.Filter{{Scope: "foreign"}}, "")
	<-local
	<-foreign
	quiet := func(ch <-chan uint64, label string) {
		select {
		case <-ch:
			panic("unrelated lifecycle subscription woke: " + label)
		default:
		}
	}
	notified := func(ch <-chan uint64, revision uint64) {
		select {
		case actual := <-ch:
			check(actual == revision, "lifecycle subscription lost latest commit")
		default:
			panic("relevant lifecycle subscription did not wake")
		}
	}
	outside := update(func(tx *store.Tx) error {
		must(tx.Put("telemetry:unrelated", 1))
		must(tx.Put("private-session:unrelated", 1))
		must(tx.AppendEvent(event("wrong-type", "local", "thread.input-accepted", "application", 501)))
		must(tx.AppendEvent(event("wrong-source", "local", "execution.completed", "user", 501)))
		must(tx.AppendEvent(event("foreign-new", "foreign", "execution.completed", "application", 501)))
		return tx.Put("lifecycle-outcome:other:foreign-new", store.Processed)
	})
	quiet(local, "scope, source, type, other consumer and other private session")
	notified(foreign, outside.Revision())
	read(outside, "pending")
	added := update(func(tx *store.Tx) error {
		return tx.AppendEvent(event("added", "local", "execution.completed", "application", 500))
	})
	notified(local, added.Revision())
	quiet(foreign, "other scope")
	read(added, "added", "pending")
	newEvents, err := added.NewEvents(seed, filters)
	must(err)
	check(len(newEvents) == 1 && newEvents[0].ID == "added", "coalesced live event diff read unrelated history")
	newEvents, err = live.Read(added)
	must(err)
	check(len(newEvents) == 1 && newEvents[0].ID == "added", "live reader replayed its baseline or missed a local fact")
	newEvents, err = live.Read(added)
	must(err)
	check(len(newEvents) == 0, "live reader repeated a delivered fact")
	observed := update(func(tx *store.Tx) error { return tx.Put("private-session:observed", 2) })
	notified(local, observed.Revision())
	quiet(foreign, "other session")
	work := update(func(tx *store.Tx) error {
		return tx.SetWork("worker", "", store.Work{ID: "batch", EventIDs: []string{"added", "pending"}, Receipts: map[string]json.RawMessage{}})
	})
	notified(local, work.Revision())
	settled := update(func(tx *store.Tx) error { return tx.SettleWork("worker", "batch", store.Processed) })
	notified(local, settled.Revision())
	quiet(foreign, "other consumer settlement")
	read(settled)
	read(added, "added", "pending")
	read(settled)
	page, more, err := settled.QueryHistory(store.HistoryQuery{Filters: filters, EventIDs: []string{"pending", "foreign-new", "added", "added", "missing"}, Limit: 1})
	must(err)
	check(more && len(page) == 1 && page[0].ID == "added" && page[0].Outcomes["worker"] == store.Processed, "exact-ID history did not filter, order, deduplicate or join outcomes")
	page[0].Data[0] = '!'
	page[0].Outcomes["worker"] = store.Failed
	page, more, err = settled.QueryHistory(store.HistoryQuery{Filters: filters, EventIDs: []string{"pending", "added"}, Offset: 1, Limit: 1})
	must(err)
	check(!more && len(page) == 1 && page[0].ID == "pending" && page[0].Outcomes["worker"] == store.Processed && json.Valid(page[0].Data), "history page alias or cursor")
	empty, more, err := settled.QueryHistory(store.HistoryQuery{Filters: filters, EventIDs: []string{}, Limit: 1})
	must(err)
	check(!more && len(empty) == 0, "empty explicit ID selection read all history")
	deleted := update(func(tx *store.Tx) error {
		must(tx.Delete("lifecycle-outcome:worker:added"))
		return tx.Delete("event:added")
	})
	notified(local, deleted.Revision())
	read(deleted)
	read(added, "added", "pending")
	read(deleted)
	newEvents, err = live.Read(deleted)
	must(err)
	check(len(newEvents) == 0, "live reader turned event deletion into delivery")
	newEvents, err = live.Read(added)
	must(err)
	check(len(newEvents) == 0, "live reader redelivered a seen identity from an old view")
	stopLocal()
	stopLocal()
	_, open := <-local
	check(!open, "unsubscribed lifecycle channel remained open")
	must(db.Close())
	_, open = <-foreign
	check(!open, "store close retained a scoped subscription")
	stopForeign()
	db, err = store.Open(path)
	must(err)
	read(db.Snapshot())
	page, more, err = db.Snapshot().QueryHistory(store.HistoryQuery{Filters: filters, EventIDs: []string{"pending", "added"}, Limit: 1})
	must(err)
	check(!more && len(page) == 1 && page[0].ID == "pending" && page[0].Outcomes["worker"] == store.Processed, "reopen lost lifecycle indexes")
	must(db.Close())
	fmt.Println("PASS scoped lifecycle routing, own-session/work/outcome wakeups, incremental pending and backward snapshots, exact-ID history pagination, detached data, deletion and reopen")
	replayLifecycleReadScaling(ctx, root)
}

func replayLifecycleReadScaling(ctx context.Context, root string) {
	type allocation struct{ pending, history uint64 }
	measure := func(count int) allocation {
		db, err := store.Open(filepath.Join(root, fmt.Sprintf("lifecycle-scale-%d.sqlite", count)))
		must(err)
		defer func() { must(db.Close()) }()
		snapshot, err := db.Update(ctx, func(tx *store.Tx) error {
			for i := range count {
				id := fmt.Sprintf("settled-%06d", i)
				event := store.Event{ID: id, CreatedAt: int64(i), Type: "execution.completed", Scope: "local", Subject: store.Subject{Kind: "thread", TypeID: "agent", ID: "owner"}, Source: "application", Data: json.RawMessage(`{"body":"retained"}`)}
				must(tx.AppendEvent(event))
				must(tx.Put("lifecycle-outcome:worker:"+id, store.Processed))
				event.ID, event.Scope = "other-"+id, "unrelated"
				must(tx.AppendEvent(event))
			}
			return tx.AppendEvent(store.Event{ID: "active", CreatedAt: 5000, Type: "execution.completed", Scope: "local", Subject: store.Subject{Kind: "thread", TypeID: "agent", ID: "owner"}, Source: "application", Data: json.RawMessage(`{}`)})
		})
		must(err)
		filters := []store.Filter{{Scope: "local", Types: []string{"execution.completed"}, Sources: []string{"application"}}}
		reader := store.NewPendingReader("worker", filters, nil)
		pending, err := reader.Read(snapshot, store.PendingQuery{})
		must(err)
		check(len(pending) == 1 && pending[0].ID == "active", "pending scaling fixture")
		// Warmed consumer reads and exact batch history must not allocate per
		// acknowledged or foreign fact. Thresholds compare memory, not timing.
		var before, after runtime.MemStats
		runtime.ReadMemStats(&before)
		for range 64 {
			pending, err = reader.Read(snapshot, store.PendingQuery{})
			must(err)
		}
		runtime.ReadMemStats(&after)
		result := allocation{pending: (after.TotalAlloc - before.TotalAlloc) / 64}
		check(len(pending) == 1 && pending[0].ID == "active", "pending scaling probe lost current work")
		runtime.ReadMemStats(&before)
		var history []store.HistoryEntry
		for range 64 {
			history, _, err = snapshot.QueryHistory(store.HistoryQuery{Filters: filters, EventIDs: []string{"settled-000000"}, Limit: 1})
			must(err)
		}
		runtime.ReadMemStats(&after)
		result.history = (after.TotalAlloc - before.TotalAlloc) / 64
		check(len(history) == 1 && history[0].Outcomes["worker"] == store.Processed, "history scaling probe lost requested outcome")
		return result
	}
	small, large := measure(64), measure(4096)
	check(large.pending <= small.pending*2+4096, "pending allocation grows with processed/foreign history")
	check(large.history <= small.history*2+4096, "exact batch history allocation grows with unrelated history")
	fmt.Printf("PASS pending/exact-history allocation with 64/4096 acknowledged and foreign facts: %d/%d and %d/%d bytes\n", small.pending, large.pending, small.history, large.history)
}
