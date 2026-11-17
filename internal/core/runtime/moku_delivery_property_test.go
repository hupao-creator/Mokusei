package runtime

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"pgregory.net/rapid"
)

// PBT-MOKU-OUTBOX: README.md. Exercise the actual transaction seam without a
// native process: attempt is immediately-before-I/O and admitted is its durable
// acknowledgement. This does not simulate the scheduler or claim provider effects.
func TestMokuOutboxProperties(t *testing.T) {
	rapid.Check(t, func(t *rapid.T) {
		root, err := os.MkdirTemp("", "mokusei-outbox-pbt-")
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
		r := &Runtime{config: Config{Store: db}}
		ctx := context.Background()
		rounds := rapid.IntRange(1, 12).Draw(t, "rounds")
		lastSequence := int64(0)
		for round := range rounds {
			count := rapid.IntRange(1, 10).Draw(t, "deliveries")
			for i := range count {
				delivery := plugin.MokuDelivery{ID: fmt.Sprintf("delivery-%d-%d", round, i), Lazy: rapid.Bool().Draw(t, "lazy"), Notification: "fact", Thread: model.ThreadRecord{SessionRecord: model.SessionRecord{ID: "source", UpdatedAt: rapid.Int64Range(0, 5).Draw(t, "timestamp")}}}
				_, err := db.Update(ctx, func(tx *store.Tx) error {
					if err := putMokuDelivery(tx, delivery); err != nil {
						return err
					}
					return putMokuDelivery(tx, delivery)
				})
				if err != nil {
					t.Fatal(err)
				}
			}
			pending, err := r.PendingMokuDeliveries()
			if err != nil {
				t.Fatal(err)
			}
			for i, delivery := range pending {
				if i > 0 && delivery.Sequence <= pending[i-1].Sequence {
					t.Fatal("delivery order ignored transaction sequence")
				}
				if delivery.Sequence > lastSequence {
					lastSequence = delivery.Sequence
				}
			}
			request := ""
			if rapid.Bool().Draw(t, "explicit-request") {
				request = pending[rapid.IntRange(0, len(pending)-1).Draw(t, "requested-index")].ID
			}
			captureCtx := context.WithValue(ctx, mokuDeliveryRequestKey{}, request)
			_, entries, batch, captureErr := r.prepareMokuDeliveries(captureCtx, nil)
			_, _, staleBatch, _ := r.prepareMokuDeliveries(captureCtx, nil)
			selected := map[string]bool{}
			lazyRequest := false
			found := request == ""
			for _, d := range pending {
				if d.ID == request {
					lazyRequest = d.Lazy
					found = !d.Uncertain
				}
			}
			for _, d := range pending {
				if !d.Uncertain && (d.ID == request || (d.Lazy && !lazyRequest)) {
					selected[d.ID] = true
				}
			}
			if !found {
				if !errors.Is(captureErr, errMokuDeliveryUnavailable) {
					t.Fatal("uncertain request was capturable")
				}
				continue
			}
			if captureErr != nil {
				t.Fatal(captureErr)
			}
			if len(batch.deliveries) != len(selected) {
				t.Fatal("capture selected wrong delivery count")
			}
			for _, d := range batch.deliveries {
				if !selected[d.ID] {
					t.Fatal("capture selected unrelated delivery")
				}
			}
			wantEntries := len(selected)
			if request != "" {
				wantEntries--
			}
			if len(entries) != wantEntries {
				t.Fatal("lazy context did not match selected identities")
			}
			if err := batch.attempt(ctx); err != nil {
				t.Fatal(err)
			}
			if len(selected) > 0 {
				before := db.Snapshot().Revision()
				if err := staleBatch.attempt(ctx); !errors.Is(err, errMokuDeliveryUnavailable) || db.Snapshot().Revision() != before {
					t.Fatal("stale capture partially claimed a batch")
				}
			}
			// A fact arriving after capture must survive that batch's admission.
			late := plugin.MokuDelivery{ID: fmt.Sprintf("late-%d", round), Lazy: true, Notification: "late", Thread: model.ThreadRecord{SessionRecord: model.SessionRecord{ID: "source"}}}
			if _, err := db.Update(ctx, func(tx *store.Tx) error { return putMokuDelivery(tx, late) }); err != nil {
				t.Fatal(err)
			}
			mode := rapid.SampledFrom([]string{"admit", "idle", "configuration", "rejected", "wrapped", "cancelled", "unknown"}).Draw(t, "result")
			cause := errors.New("unknown native outcome")
			safe := mode == "idle" || mode == "configuration" || mode == "rejected"
			switch mode {
			case "idle":
				cause = plugin.ErrMokuIdle
			case "configuration":
				cause = plugin.ErrMokuConfigurationPending
			case "rejected":
				cause = &plugin.MokuAdmissionRejectedError{Cause: errors.New("generated rejection")}
			case "wrapped":
				cause = fmt.Errorf("uncertain: %w", plugin.ErrMokuIdle)
			case "cancelled":
				cause = context.Canceled
			}
			if mode == "admit" {
				if err := batch.admitted(ctx); err != nil {
					t.Fatal(err)
				}
			} else if err := batch.releaseUnconsumed(ctx, cause); err != cause {
				t.Fatalf("release changed cause: %v", err)
			}
			after, err := r.PendingMokuDeliveries()
			if err != nil {
				t.Fatal(err)
			}
			byID := map[string]plugin.MokuDelivery{}
			for _, d := range after {
				byID[d.ID] = d
			}
			for _, d := range pending {
				actual, exists := byID[d.ID]
				if selected[d.ID] {
					if mode == "admit" {
						if exists {
							t.Fatal("admitted delivery retained")
						}
						continue
					}
					if !exists || actual.Uncertain != !safe || actual.Sequence != d.Sequence {
						t.Fatal("attempt fence or identity changed")
					}
					if !safe && r.ResolveMokuDelivery(ctx, d.ID, "retry-confirmed-unadmitted") == nil {
						t.Fatal("live uncertain attempt reconciled before restart")
					}
				} else if !exists || !reflect.DeepEqual(actual, d) {
					t.Fatal("batch changed unselected delivery")
				}
			}
			if d, exists := byID[late.ID]; !exists || d.Uncertain || d.Sequence != lastSequence+1 {
				t.Fatal("late arrival consumed by captured batch")
			}
			lastSequence++
			if err := db.Close(); err != nil {
				t.Fatal(err)
			}
			db, err = store.Open(path)
			if err != nil {
				t.Fatal(err)
			}
			r = &Runtime{config: Config{Store: db}}
			restored, err := r.PendingMokuDeliveries()
			if err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(after, restored) {
				t.Fatal("restart replayed or changed pending deliveries")
			}
			for _, d := range restored {
				if !d.Uncertain {
					continue
				}
				decision := rapid.SampledFrom([]string{"retry-confirmed-unadmitted", "acknowledge-confirmed-admitted"}).Draw(t, "reconciliation")
				if err := r.ResolveMokuDelivery(ctx, d.ID, decision); err != nil {
					t.Fatal(err)
				}
				var actual plugin.MokuDelivery
				exists, err := db.Snapshot().Get(mokuDeliveryPrefix+d.ID, &actual)
				if err != nil {
					t.Fatal(err)
				}
				if decision == "acknowledge-confirmed-admitted" {
					if exists {
						t.Fatal("confirmed admission not retired")
					}
				} else if !exists || actual.Uncertain || actual.Sequence != d.Sequence {
					t.Fatal("confirmed retry lost delivery identity")
				}
			}
		}
	})
}
