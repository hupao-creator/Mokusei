package runtime

import (
	"context"
	"errors"
	"path/filepath"
	"testing"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/core/store"
)

type deliveryTestHandle struct {
	plugin.Handle
	send func(context.Context, plugin.SendRequest) error
}

func (h deliveryTestHandle) Send(ctx context.Context, req plugin.SendRequest) error {
	return h.send(ctx, req)
}

func TestMokuDeliveryTransactionAndRestart(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state.sqlite")
	db, err := store.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	r := &Runtime{config: Config{Store: db}}
	thread := model.ThreadRecord{SessionRecord: model.SessionRecord{ID: "child", Observation: model.PublicObservation{LatestExecution: &model.PublicExecution{ExecutionID: "exec", Status: "completed"}}}}
	commit := func(fail bool) error {
		_, err := db.Update(t.Context(), func(tx *store.Tx) error {
			if err := tx.Put("thread:child", thread); err != nil {
				return err
			}
			if err := r.threadEvents(tx, nil, &thread); err != nil {
				return err
			}
			if fail {
				return errors.New("injected rollback")
			}
			return nil
		})
		return err
	}
	if err := commit(true); err == nil {
		t.Fatal("rollback accepted")
	}
	if len(db.Snapshot().Keys(mokuDeliveryPrefix)) != 0 {
		t.Fatal("outbox escaped failed terminal transaction")
	}
	if err := commit(false); err != nil {
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	db, err = store.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	r.config.Store = db
	pending, err := r.PendingMokuDeliveries()
	if err != nil || len(pending) != 1 || pending[0].Uncertain {
		t.Fatalf("restart lost terminal: %+v %v", pending, err)
	}
	_, err = db.Update(t.Context(), func(tx *store.Tx) error { return r.threadEvents(tx, &thread, &thread) })
	if err != nil {
		t.Fatal(err)
	}
	if len(db.Snapshot().Keys(mokuDeliveryPrefix)) != 1 {
		t.Fatal("duplicate notification")
	}
	_, err = db.Update(t.Context(), func(tx *store.Tx) error { return r.threadEvents(tx, &thread, nil) })
	if err != nil {
		t.Fatal(err)
	}
	if len(db.Snapshot().Keys(mokuDeliveryPrefix)) != 0 {
		t.Fatal("deleted owner retained outbox")
	}
}

func TestMokuDeliveryAdmissionFence(t *testing.T) {
	root := t.TempDir()
	db, err := store.Open(filepath.Join(root, "state.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	r, err := New(t.Context(), Config{Store: db, DataDir: root, DefaultCwd: root})
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close(context.Background())
	child := model.ThreadRecord{SessionRecord: model.SessionRecord{ID: "child", Observation: model.PublicObservation{LatestExecution: &model.PublicExecution{ExecutionID: "exec", Status: "completed"}}}}
	moku := model.ThreadRecord{SessionRecord: model.SessionRecord{ID: "moku", Cwd: root}, Moku: true}
	_, err = db.Update(t.Context(), func(tx *store.Tx) error {
		if err := tx.Put("thread:moku", moku); err != nil {
			return err
		}
		return queueMokuDelivery(tx, child)
	})
	if err != nil {
		t.Fatal(err)
	}
	pending, _ := r.PendingMokuDeliveries()
	id := pending[0].ID
	input := model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "terminal"}}}
	// No native owner exists: a pre-admission failure must remain retryable.
	if _, err := r.SendMokuDelivery(t.Context(), id, "moku", input, nil, nil); err == nil {
		t.Fatal("missing harness succeeded")
	}
	pending, _ = r.PendingMokuDeliveries()
	if pending[0].Uncertain {
		t.Fatal("pre-native failure consumed delivery")
	}
	lifetime, cancel := context.WithCancel(t.Context())
	owner := &threadHandle{runtime: r, id: "moku", generation: r.generation, ctx: lifetime, cancel: cancel, opened: make(chan struct{})}
	close(owner.opened)
	r.mu.Lock()
	r.handles["moku"] = owner
	r.mu.Unlock()
	defer func() { owner.workers.Wait(); cancel(); r.mu.Lock(); delete(r.handles, "moku"); r.mu.Unlock() }()
	calls := 0
	owner.native = deliveryTestHandle{send: func(ctx context.Context, req plugin.SendRequest) error {
		calls++
		values, _ := r.PendingMokuDeliveries()
		if len(values) != 1 || !values[0].Uncertain {
			t.Error("native entered without durable attempt")
		}
		return errors.New("transport disconnected after possible consumption")
	}}
	if _, err := r.SendMokuDelivery(t.Context(), id, "moku", input, nil, nil); err == nil {
		t.Fatal("failed transport succeeded")
	}
	owner.workers.Wait()
	if _, err := r.SendMokuDelivery(t.Context(), id, "moku", input, nil, nil); err == nil {
		t.Fatal("uncertain delivery replayed")
	}
	owner.workers.Wait()
	if calls != 1 {
		t.Fatalf("native calls=%d", calls)
	}
	if err := r.ResolveMokuDelivery(t.Context(), id, "retry-confirmed-unadmitted"); err == nil {
		t.Fatal("live process reconciled its own attempt")
	}
	// A fresh runtime instance can reconcile after the old native worker drained.
	restarted := &Runtime{config: Config{Store: db}}
	if err := restarted.ResolveMokuDelivery(t.Context(), id, "retry-confirmed-unadmitted"); err != nil {
		t.Fatal(err)
	}
	owner.native = deliveryTestHandle{send: func(ctx context.Context, req plugin.SendRequest) error {
		calls++
		_, err := db.Update(ctx, func(tx *store.Tx) error {
			moku.Observation.LatestExecution = &model.PublicExecution{ExecutionID: req.ExecutionID, Status: "running"}
			return tx.Put("thread:moku", moku)
		})
		if err != nil {
			return err
		}
		return req.Admitted()
	}}
	if _, err := r.SendMokuDelivery(t.Context(), id, "moku", input, nil, nil); err != nil {
		t.Fatal(err)
	}
	owner.workers.Wait()
	pending, err = r.PendingMokuDeliveries()
	if err != nil || len(pending) != 0 {
		t.Fatalf("admitted delivery remains: %+v %v", pending, err)
	}
	if _, err := r.SendMokuDelivery(t.Context(), id, "moku", input, nil, nil); err == nil {
		t.Fatal("receipt replayed")
	}
	owner.workers.Wait()
	if calls != 2 {
		t.Fatalf("native calls=%d", calls)
	}
}

func TestClearHistoryRemovesMokuDeliveryAcrossRestart(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "state.sqlite")
	db, err := store.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	r, err := New(t.Context(), Config{Store: db, DataDir: root, DefaultCwd: root})
	if err != nil {
		t.Fatal(err)
	}
	_, err = db.Update(t.Context(), func(tx *store.Tx) error {
		for _, id := range []string{"pending", "uncertain"} {
			if err := tx.Put(mokuDeliveryPrefix+id, plugin.MokuDelivery{ID: id, Uncertain: id == "uncertain", AttemptEpoch: "prior-process"}); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := r.ClearHistory(t.Context()); err != nil {
		t.Fatal(err)
	}
	if err := r.Close(context.Background()); err != nil {
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	db, err = store.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	restarted := &Runtime{config: Config{Store: db}}
	pending, err := restarted.PendingMokuDeliveries()
	if err != nil || len(pending) != 0 {
		t.Fatalf("history resurrected outbox: %+v %v", pending, err)
	}
}
