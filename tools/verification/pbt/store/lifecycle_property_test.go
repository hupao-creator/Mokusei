package store_test

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"testing"

	"github.com/hupao-creator/Chief/internal/core/store"
	"github.com/hupao-creator/Chief/tools/verification/pbt/rapidcheck"
	"pgregory.net/rapid"
)

// PBT-STORE-LIFECYCLE: internal/core/store/README.md. The oracle retains facts,
// acknowledgements and accepted effects, not the production index algorithm.
func TestLifecycleProperties(t *testing.T) {
	rapidcheck.Check(t, func(t *rapid.T) {
		root, err := os.MkdirTemp("", "mokusei-lifecycle-pbt-")
		if err != nil {
			t.Fatal(err)
		}
		defer os.RemoveAll(root)
		path := filepath.Join(root, "state.sqlite")
		db, err := store.Open(path)
		if err != nil {
			t.Fatal(err)
		}
		defer func() {
			if db != nil {
				if err := db.Close(); err != nil {
					t.Fatal(err)
				}
			}
		}()
		type batch struct {
			id       string
			events   []string
			receipts map[string]int
		}
		facts := []store.Event{}
		batches := map[string]*batch{}
		ack := map[string]map[string]store.Outcome{}
		readers := map[string]*store.PendingReader{}
		for i := range 3 {
			consumer := fmt.Sprintf("consumer-%d", i)
			ack[consumer] = map[string]store.Outcome{}
			readers[consumer] = store.NewPendingReader(consumer, []store.Filter{{Scope: fmt.Sprintf("scope-%d", i)}}, nil)
		}
		effects := 0
		abort := errors.New("generated rollback")
		steps := rapid.IntRange(1, 60).Draw(t, "steps")
		for step := range steps {
			i := rapid.IntRange(0, 2).Draw(t, "consumer")
			consumer, scope := fmt.Sprintf("consumer-%d", i), fmt.Sprintf("scope-%d", i)
			kind := rapid.SampledFrom([]string{"append", "batch", "receipt", "receipt", "settle", "stale", "reopen"}).Draw(t, "action")
			rollback := rapid.IntRange(0, 4).Draw(t, "rollback") == 0
			before := db.Snapshot()
			switch kind {
			case "append":
				event := store.Event{ID: fmt.Sprintf("event-%03d", step), CreatedAt: rapid.Int64Range(0, 8).Draw(t, "timestamp"), Type: "execution.completed", Scope: scope, Source: "application", Subject: store.Subject{Kind: "thread", ID: fmt.Sprintf("thread-%d", i), TypeID: "agent"}, Data: json.RawMessage(`{}`)}
				_, err = db.Update(context.Background(), func(tx *store.Tx) error {
					if err := tx.AppendEvent(event); err != nil {
						return err
					}
					if rollback {
						return abort
					}
					return nil
				})
				if !rollback {
					facts = append(facts, event)
				}
			case "batch":
				pending := []string{}
				for _, event := range facts {
					if event.Scope == scope && ack[consumer][event.ID] == "" {
						pending = append(pending, event.ID)
					}
				}
				if len(pending) == 0 {
					continue
				}
				ids := rapid.SliceOfNDistinct(rapid.SampledFrom(pending), 1, len(pending), func(id string) string { return id }).Draw(t, "batch-events")
				id, expected := fmt.Sprintf("batch-%d", step), ""
				if active := batches[consumer]; active != nil {
					id, expected = active.id, active.id
				}
				_, err = db.Update(context.Background(), func(tx *store.Tx) error {
					if err := tx.SetWork(consumer, expected, store.Work{ID: id, EventIDs: ids}); err != nil {
						return err
					}
					if rollback {
						return abort
					}
					return nil
				})
				if !rollback {
					if batches[consumer] == nil {
						batches[consumer] = &batch{id: id, receipts: map[string]int{}}
					}
					for _, id := range ids {
						if !slices.Contains(batches[consumer].events, id) {
							batches[consumer].events = append(batches[consumer].events, id)
						}
					}
				}
			case "receipt":
				active := batches[consumer]
				if active == nil {
					continue
				}
				key := fmt.Sprintf("effect-%d", rapid.IntRange(0, 3).Draw(t, "receipt-key"))
				failChild := rapid.Bool().Draw(t, "effect-failure")
				previous, duplicate := active.receipts[key]
				calls := 0
				var result json.RawMessage
				_, err = db.Update(context.Background(), func(tx *store.Tx) error {
					var effectErr error
					result, effectErr = tx.ApplyReceipt(store.Receipt{ConsumerID: consumer, BatchID: active.id, Key: key}, func(child *store.Tx) (any, error) {
						calls++
						var count int
						if _, err := child.Get("effects", &count); err != nil {
							return nil, err
						}
						if err := child.Put("effects", count+1); err != nil {
							return nil, err
						}
						if failChild {
							return nil, abort
						}
						return count + 1, nil
					})
					// A handled child failure must still leave the parent safe to commit.
					if failChild && !duplicate {
						if !errors.Is(effectErr, abort) {
							return fmt.Errorf("missing child rejection: %v", effectErr)
						}
					} else if effectErr != nil {
						return effectErr
					}
					if rollback {
						return abort
					}
					return nil
				})
				if calls != 1 && !duplicate || calls != 0 && duplicate {
					t.Fatal("receipt did not fence effect invocation")
				}
				if !rollback && (duplicate || !failChild) {
					var got int
					if err := json.Unmarshal(result, &got); err != nil {
						t.Fatal(err)
					}
					if duplicate {
						if got != previous {
							t.Fatal("receipt replay changed result")
						}
					} else {
						effects++
						active.receipts[key] = effects
						if got != effects {
							t.Fatal("effect result differs from committed count")
						}
					}
				}
			case "settle":
				active := batches[consumer]
				if active == nil {
					continue
				}
				outcome := rapid.SampledFrom([]store.Outcome{store.Processed, store.Failed}).Draw(t, "outcome")
				_, err = db.Update(context.Background(), func(tx *store.Tx) error {
					if err := tx.SettleWork(consumer, active.id, outcome); err != nil {
						return err
					}
					if rollback {
						return abort
					}
					return nil
				})
				if !rollback {
					for _, id := range active.events {
						ack[consumer][id] = outcome
					}
					delete(batches, consumer)
				}
			case "stale":
				_, err = db.Update(context.Background(), func(tx *store.Tx) error { return tx.SettleWork(consumer, "never-admitted", store.Processed) })
				if err == nil {
					t.Fatal("stale batch mutated state")
				}
				rollback, err = true, abort
			case "reopen":
				if err := db.Close(); err != nil {
					t.Fatal(err)
				}
				db, err = store.Open(path)
				if err != nil {
					t.Fatal(err)
				}
				rollback = false
			}
			if rollback {
				if !errors.Is(err, abort) || db.Snapshot().Revision() != before.Revision() {
					t.Fatalf("rollback changed state: %v", err)
				}
			} else if err != nil {
				t.Fatal(err)
			}
			snapshot := db.Snapshot()
			var actualEffects int
			if _, err := snapshot.Get("effects", &actualEffects); err != nil {
				t.Fatal(err)
			}
			if actualEffects != effects {
				t.Fatal("uncommitted or duplicate effect leaked")
			}
			slices.SortFunc(facts, func(a, b store.Event) int {
				if a.CreatedAt != b.CreatedAt {
					if a.CreatedAt < b.CreatedAt {
						return -1
					}
					return 1
				}
				if a.ID < b.ID {
					return -1
				}
				if a.ID > b.ID {
					return 1
				}
				return 0
			})
			for j := range 3 {
				consumer, scope := fmt.Sprintf("consumer-%d", j), fmt.Sprintf("scope-%d", j)
				want := []store.Event{}
				for _, fact := range facts {
					if fact.Scope == scope && ack[consumer][fact.ID] == "" {
						want = append(want, fact)
					}
				}
				actual, err := snapshot.Pending(consumer, store.PendingQuery{Filters: []store.Filter{{Scope: scope}}})
				if err != nil {
					t.Fatal(err)
				}
				incremental, err := readers[consumer].Read(snapshot, store.PendingQuery{})
				if err != nil {
					t.Fatal(err)
				}
				if !reflect.DeepEqual(actual, want) || !reflect.DeepEqual(incremental, want) {
					t.Fatal("pending stream differs from unacknowledged facts")
				}
				work, exists, err := snapshot.Work(consumer)
				if err != nil {
					t.Fatal(err)
				}
				active := batches[consumer]
				if exists != (active != nil) {
					t.Fatal("active batch lost or resurrected")
				}
				if active != nil {
					if work.ID != active.id || !slices.Equal(work.EventIDs, active.events) || len(work.Receipts) != len(active.receipts) {
						t.Fatal("batch membership or receipts changed")
					}
					for key, value := range active.receipts {
						var got int
						if json.Unmarshal(work.Receipts[key], &got) != nil || got != value {
							t.Fatal("durable receipt changed")
						}
					}
				}
			}
			history, more, err := snapshot.History(nil, 0, 1000)
			if err != nil {
				t.Fatal(err)
			}
			if more || len(history) != len(facts) {
				t.Fatal("history lost facts")
			}
			for i, entry := range history {
				if !reflect.DeepEqual(entry.Event, facts[i]) {
					t.Fatal("history order or fact changed")
				}
				for consumer, outcomes := range ack {
					if entry.Outcomes[consumer] != outcomes[entry.ID] {
						t.Fatal("history outcome differs from settlement")
					}
				}
			}
		}
	})
}
