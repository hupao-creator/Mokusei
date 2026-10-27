package main

import (
	"context"
	"encoding/json"
	"fmt"
	"reflect"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

func lateTerminal(rawState json.RawMessage) json.RawMessage {
	var snapshot state
	must(json.Unmarshal(rawState, &snapshot))
	next := *snapshot.Observation.LatestExecution
	at := time.Now().UnixMilli() + 1000
	next.FinishedAt = &at
	summary := "late close callback"
	next.Summary = &summary
	snapshot.Observation.LatestExecution = &next
	return raw(snapshot)
}
func verifyCanonicalClosingOwner() {
	r, h, cleanup := setup("canonical-close")
	defer cleanup()
	created, err := create(r)
	must(err)
	native := receive(h.opened)
	before, err := r.Thread(created.Record.ID)
	must(err)
	settled, err := h.SessionState().Settle(plugin.SettleRequest{SessionState: before.SessionState, ExecutionID: created.Execution.ExecutionID, Outcome: "interrupted", FinishedAt: time.Now().UnixMilli()})
	must(err)
	observation, err := h.SessionState().Project(settled)
	must(err)
	must(r.UpdateThread(context.Background(), before.ID, func(t *model.ThreadRecord) error { t.SessionState = settled; t.Observation = observation; return nil }))
	canonical, err := r.Thread(before.ID)
	must(err)
	assert(native.open.SessionState.Commit(context.Background(), lateTerminal(settled)) != nil, "live owner rewrote canonical terminal")
	must(r.Close(context.Background()))
	after, err := r.Thread(before.ID)
	must(err)
	assert(reflect.DeepEqual(canonical.Observation, after.Observation) && reflect.DeepEqual(canonical.SessionState, after.SessionState), "closing callback changed persisted terminal or session state")
	fmt.Println("PASS closing owner fence: live terminal rewrites rejected, late closing snapshot discarded, canonical native state preserved")
}
