package store_test

import (
	"context"
	"fmt"
	"maps"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/hupao-creator/Chief/internal/core/store"
	"github.com/hupao-creator/Chief/tools/verification/pbt/rapidcheck"
	"pgregory.net/rapid"
)

// PBT-STORE-SNAPSHOT: internal/core/store/README.md
// The historical storage-workspaces/fanout.go random model, generalized from
// PCG(19,23) to Rapid-generated shrinkable traces. No allocation/timing examples.
func TestSnapshotProperties(t *testing.T) {
	rapidcheck.Check(t, func(t *rapid.T) {
		root, err := os.MkdirTemp("", "mokusei-store-pbt-")
		if err != nil {
			t.Fatal(err)
		}
		defer os.RemoveAll(root)
		db, err := store.Open(filepath.Join(root, "state.sqlite"))
		if err != nil {
			t.Fatal(err)
		}
		defer db.Close()
		type retained struct {
			snapshot store.Snapshot
			values   map[string]int
		}
		values := map[string]int{}
		history := []retained{{db.Snapshot(), maps.Clone(values)}}
		prefixes := []string{"a", "alpha", "alpine", "app:", "thread:", "线程:", "😀:", strings.Repeat("x", 1010)}
		steps := rapid.IntRange(1, 80).Draw(t, "steps")
		for step := range steps {
			// Draw before the production writer callback: Rapid and the oracle remain
			// owned by the property goroutine, while SQLite serializes real writes.
			count := rapid.IntRange(1, 8).Draw(t, "writes")
			type operation struct {
				key    string
				remove bool
			}
			operations := make([]operation, count)
			for i := range operations {
				operations[i] = operation{rapid.SampledFrom(prefixes).Draw(t, "prefix") + fmt.Sprint(rapid.IntRange(0, 19).Draw(t, "key")), rapid.IntRange(0, 2).Draw(t, "kind") == 0}
			}
			snapshot, err := db.Update(context.Background(), func(tx *store.Tx) error {
				for _, op := range operations {
					if op.remove {
						if err := tx.Delete(op.key); err != nil {
							return err
						}
					} else if err := tx.Put(op.key, step); err != nil {
						return err
					}
				}
				return nil
			})
			if err != nil {
				t.Fatal(err)
			}
			for _, op := range operations {
				if op.remove {
					delete(values, op.key)
				} else {
					values[op.key] = step
				}
			}
			previous := history[rapid.IntRange(0, len(history)-1).Draw(t, "previous")]
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
				if !slices.Equal(snapshot.Keys(prefix), keys) || snapshot.Count(prefix) != len(keys) {
					t.Fatal("prefix keys/count differ from map model")
				}
				if !slices.Equal(snapshot.ChangedKeys(previous.snapshot, prefix), changes) || !slices.Equal(previous.snapshot.ChangedKeys(snapshot, prefix), changes) {
					t.Fatal("symmetric snapshot diff differs from map model")
				}
				if snapshot.PrefixEqual(previous.snapshot, prefix) != (len(changes) == 0) {
					t.Fatal("prefix equality differs from map model")
				}
			}
			for key, expected := range previous.values {
				var actual int
				exists, err := previous.snapshot.Get(key, &actual)
				if err != nil {
					t.Fatal(err)
				}
				if !exists || actual != expected {
					t.Fatal("later write mutated retained snapshot")
				}
			}
			if step%8 == 0 {
				history = append(history, retained{snapshot, maps.Clone(values)})
			}
		}
	})
}
