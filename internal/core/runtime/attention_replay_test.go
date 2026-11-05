package runtime

import (
	"context"
	"encoding/json"
	"fmt"
	"testing"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/services/threadattention"
)

// Exercise the Runtime command, real SQLite transactions, deferred work and
// receipt-fenced write boundary. Time advances only at the scheduler seam.
func TestAttentionReplay(t *testing.T) {
	r := coordinationRuntime(t)
	ctx := context.Background()
	db := r.config.Store
	agent := attentionCapability{r}
	update := func(f func(*store.Tx) error) {
		t.Helper()
		if _, err := db.Update(ctx, f); err != nil {
			t.Fatal(err)
		}
	}
	enable := func(on bool) {
		update(func(tx *store.Tx) error {
			var s model.Settings
			if _, err := tx.Get("settings", &s); err != nil {
				return err
			}
			raw, _ := json.Marshal(map[string]any{"enabled": on, "mode": "inherit"})
			s.PluginSettings = []model.PluginSettings{{ID: "attention.settings", SchemaVersion: 1, Value: raw}}
			return tx.Put("settings", s)
		})
	}
	enable(true)
	add := func(id string) {
		update(func(tx *store.Tx) error {
			rec := model.ThreadRecord{SessionRecord: model.SessionRecord{ID: id, HarnessID: "fixture", Revision: 1, CreatedAt: 1, UpdatedAt: 1, Settings: json.RawMessage("{}"), SessionState: json.RawMessage("null")}, Title: "Keep source"}
			if err := tx.Put("thread:"+id, rec); err != nil {
				return err
			}
			return r.threadEvents(tx, nil, &rec)
		})
	}
	schedule := func(at int64) {
		t.Helper()
		if _, err := agent.scheduleAt(ctx, at); err != nil {
			t.Fatal(err)
		}
	}
	events := func() []store.Event {
		var rows []store.Event
		s := db.Snapshot()
		for _, k := range s.Keys("event:") {
			var e store.Event
			if _, err := s.Get(k, &e); err != nil {
				t.Fatal(err)
			}
			if e.Type == "attention.evaluate" {
				rows = append(rows, e)
			}
		}
		return rows
	}
	now := time.Now().UnixMilli()
	for i := 0; i < 19; i++ {
		add(fmt.Sprint(i))
	}
	schedule(now)
	if len(events()) != 0 {
		t.Fatal("woke below threshold")
	}
	add("target")
	schedule(now + 1)
	rows := events()
	if len(rows) != 20 {
		t.Fatalf("crossing produced %d candidates", len(rows))
	}
	add("extra")
	schedule(now + 2)
	if len(events()) != 20 {
		t.Fatal("repeated threshold wake")
	}
	var selected store.Event
	for _, row := range rows {
		if row.Subject.ID == "target" {
			selected = row
		}
	}
	batch := plugin.BatchWriteContext{ConsumerID: "attention.agent.evaluate", BatchID: "batch", InvocationID: "hide"}
	update(func(tx *store.Tx) error {
		return tx.SetWork(batch.ConsumerID, "", store.Work{ID: batch.BatchID, EventIDs: []string{selected.ID}})
	})
	facts, err := agent.Evidence(ctx, []plugin.LifecycleEvent{{Subject: plugin.LifecycleSubject{ID: "target"}, Data: selected.Data}})
	if err != nil || len(facts) != 1 {
		t.Fatalf("missing evidence: %v, %v", facts, err)
	}
	if _, leak := facts[0]["title"]; leak {
		t.Fatal("title disclosed")
	}
	opts := plugin.BackgroundWriteOptions{Batch: batch}
	result, err := agent.Hide(ctx, "target", 0, opts)
	if err != nil || string(result) != "true" {
		t.Fatalf("hide %s %v", result, err)
	}
	catalog, err := r.projectThreads(db.Snapshot())
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, v := range catalog {
		if v.ID == "target" {
			found = v.AttentionHidden
		}
	}
	if !found {
		t.Fatal("missing hidden projection")
	}
	sources, err := r.searchSources(db.Snapshot(), false)
	if err != nil {
		t.Fatal(err)
	}
	found = false
	for _, s := range sources {
		found = found || s.Ref.ThreadID == "target"
	}
	if !found {
		t.Fatal("hidden thread removed from search")
	}
	visit := func(id string, ms int64, completed string, already, search bool) {
		t.Helper()
		payload, _ := json.Marshal(attentionVisit{ThreadID: "target", VisitID: id, Elapsed: ms, Foreground: true, CompletedExecution: completed, AlreadyVisible: already, SearchOpen: search})
		if _, err := r.Invoke(ctx, "thread:record-visit", []json.RawMessage{payload}); err != nil {
			t.Fatal(err)
		}
	}
	const visitID = "10000000-0000-4000-8000-000000000001"
	visit(visitID, 0, "", false, true)
	visit(visitID, 200, "", false, true)
	if db.Snapshot().Has(attentionHiddenPrefix + "target") {
		t.Fatal("search open failed to restore")
	}
	opts.Batch.InvocationID = "late"
	if _, err := agent.Hide(ctx, "target", 0, opts); err == nil && db.Snapshot().Has(attentionHiddenPrefix+"target") {
		t.Fatal("late hide defeated search recovery")
	}
	start := func(id, status string, at int64) {
		update(func(tx *store.Tx) error {
			var before model.ThreadRecord
			if _, err := tx.Get("thread:target", &before); err != nil {
				return err
			}
			after := before
			after.Revision++
			after.Observation.LatestExecution = &model.PublicExecution{ExecutionID: id, Status: status, StartedAt: at, FinishedAt: &at}
			if err := tx.Put("thread:target", after); err != nil {
				return err
			}
			return r.threadEvents(tx, &before, &after)
		})
	}
	start("A", "completed", now)
	visit(visitID, 350, "A", true, false)
	var stats threadattention.Thread
	get := func() {
		if _, err := db.Snapshot().Get(attentionPrefix+"target", &stats); err != nil {
			t.Fatal(err)
		}
	}
	get()
	if len(stats.Visits) != 1 || stats.Visits[0].ForegroundMillis != 350 || stats.FirstReadAt != now {
		t.Fatalf("bad first read %#v", stats)
	}
	schedule(now + threadattention.ReadDelay.Milliseconds() - 1)
	n := len(events())
	schedule(now + threadattention.ReadDelay.Milliseconds())
	if len(events()) != n+1 {
		t.Fatal("missing targeted wake")
	}
	schedule(now + threadattention.ReadDelay.Milliseconds() + 1)
	if len(events()) != n+1 {
		t.Fatal("duplicate read wake")
	}
	// The due event may hide A. Even with the switch off, B restores it and
	// the user's previous open count survives.
	var fresh store.Event
	for _, row := range events() {
		if row.Subject.ID == "target" && row.ID != selected.ID {
			fresh = row
		}
	}
	update(func(tx *store.Tx) error {
		return tx.SetWork(batch.ConsumerID, batch.BatchID, store.Work{ID: batch.BatchID, EventIDs: []string{fresh.ID}})
	})
	get()
	opts.Batch.InvocationID = "hide-after-read"
	hidden, err := agent.Hide(ctx, "target", stats.Revision, opts)
	if err != nil || string(hidden) != "true" {
		t.Fatalf("current evidence could not hide: %s %v", hidden, err)
	}
	enable(false)
	start("B", "running", now+3)
	if db.Snapshot().Has(attentionHiddenPrefix + "target") {
		t.Fatal("a successor must restore the card even while disabled")
	}
	get()
	if stats.FirstReadAt != 0 || len(stats.Visits) != 1 {
		t.Fatal("successor inherited deadline or lost visits")
	}
	enable(false)
	schedule(now + threadattention.FallbackInterval.Milliseconds())
	if len(events()) != n+1 {
		t.Fatal("disabled scheduler woke")
	}
	enable(true)
	schedule(now + threadattention.FallbackInterval.Milliseconds())
	if len(events()) != n+1+21 {
		t.Fatalf("daily sweep recorded %d", len(events()))
	}
}
