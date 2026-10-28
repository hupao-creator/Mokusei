package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sync"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	core "github.com/hupao-creator/Mokusei/internal/core/runtime"
)

func cancelObserved(r *core.Runtime, thread model.ThreadRecord) model.CancellationResult {
	value, err := r.Invoke(context.Background(), "thread:interrupt", []json.RawMessage{raw(model.CancellationRequest{ThreadID: thread.ID, ExpectedCancellationID: thread.CancellationID})})
	must(err)
	return value.(model.CancellationResult)
}

func verifyMultiClientContracts() {
	ctx := context.Background()
	for _, mode := range []string{"opening", "pending"} {
		r, h, cleanup := setup(mode)
		done := make(chan error, 1)
		go func() { _, err := create(r); done <- err }()
		native := receive(h.opened)
		observed, err := r.Thread(native.open.ThreadID)
		must(err)
		assert(observed.PendingInput && observed.CancellationID != "" && observed.Observation.LatestExecution == nil, "pre-execution admission has no visible cancellation identity")
		stale := observed
		stale.CancellationID = "another-admission"
		assert(cancelObserved(r, stale).Status == "stale", "stale admission cancelled preparation")
		assert(cancelObserved(r, observed).Status == "cancelled", "observed admission was not cancelled")
		assert(receive(done) != nil, "cancelled preparation succeeded")
		h.mode = "normal"
		native.mu.Lock()
		native.mode = "normal"
		native.mu.Unlock()
		_, err = r.SendThread(ctx, observed.ID, model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "successor"}}})
		must(err)
		next, err := r.Thread(observed.ID)
		must(err)
		assert(next.CancellationID != observed.CancellationID, "successor reused cancelled admission identity")
		assert(cancelObserved(r, observed).Status == "stale", "late cancellation stopped successor")
		current, err := r.Thread(observed.ID)
		must(err)
		assert(current.Observation.LatestExecution.Status == "running", "successor was interrupted by old UI")
		assert(cancelObserved(r, next).Status == "cancelled", "current cancellation did not interrupt")
		cleanup()
	}
	fmt.Println("PASS public cancellation fences native opening, pending admission and successor execution")

	r, h, cleanup := setup("normal")
	defer cleanup()
	created, err := create(r)
	must(err)
	native := receive(h.opened)
	initial, err := r.Thread(created.Record.ID)
	must(err)
	_, err = r.Invoke(ctx, "thread:interrupt", []json.RawMessage{raw(initial.ID)})
	assert(err != nil, "unfenced public interrupt remains available")
	assert(cancelObserved(r, initial).Status == "cancelled", "initial cancellation failed")
	var observedMu sync.Mutex
	previousCancellation := initial.CancellationID
	unwatch := r.OnThreadCommitted(func(record model.ThreadRecord) {
		if record.ID != initial.ID {
			return
		}
		observedMu.Lock()
		defer observedMu.Unlock()
		if record.CancellationID != previousCancellation && !record.PendingInput {
			assert(record.Observation.LatestExecution != nil && record.Observation.LatestExecution.ExecutionID == record.CancellationID, "native wake published cancellation identity before its execution")
		}
		previousCancellation = record.CancellationID
	})
	defer unwatch()
	for range 20 {
		// Native automatic wake and stale cancellation race at the actual host
		// admission gate. Either the wake is refused or the new execution lives.
		before, err := r.Thread(initial.ID)
		must(err)
		var value state
		must(json.Unmarshal(native.open.SessionState.Read(), &value))
		value.Observation.BackgroundWork = &model.PublicBackgroundWork{Status: "running"}
		must(native.open.SessionState.Commit(ctx, raw(value)))
		start := make(chan struct{})
		accepted := make(chan error, 1)
		stopped := make(chan model.CancellationResult, 1)
		go func() {
			<-start
			_, err := native.open.ExecutionAdmission.Accept(ctx, func(id string) (json.RawMessage, error) {
				return raw(state{Observation: model.PublicObservation{LatestExecution: &model.PublicExecution{ExecutionID: id, Status: "running", StartedAt: time.Now().UnixMilli()}}}), nil
			})
			accepted <- err
		}()
		go func() { <-start; stopped <- cancelObserved(r, before) }()
		close(start)
		acceptErr, result := receive(accepted), receive(stopped)
		after, err := r.Thread(initial.ID)
		must(err)
		if acceptErr == nil {
			assert(after.Observation.LatestExecution.Status == "running" && after.CancellationID != before.CancellationID, "cancellation crossed native successor admission")
			assert(cancelObserved(r, after).Status == "cancelled", "successor cleanup failed")
		} else {
			assert(result.Status == "cancelled", "neither racing operation completed")
		}
	}
	fmt.Println("PASS native successor/cancellation race cannot interrupt a replacement execution")

	before, err := r.Thread(initial.ID)
	must(err)
	results := make(chan core.ThreadSettingsResult, 2)
	var writes sync.WaitGroup
	for _, choice := range []string{"mac", "ipad"} {
		writes.Add(1)
		go func(choice string) {
			defer writes.Done()
			value, err := r.Invoke(ctx, "thread:update-settings", []json.RawMessage{raw(model.Object{"threadId": before.ID, "harnessId": "fixture", "expectedSettingsRevision": before.SettingsRevision, "change": model.Object{"choice": choice}})})
			must(err)
			results <- value.(core.ThreadSettingsResult)
		}(choice)
	}
	writes.Wait()
	first, second := <-results, <-results
	assert(first.Status != second.Status && first.SettingsRevision == before.SettingsRevision+1 && second.SettingsRevision == first.SettingsRevision, "thread settings CAS admitted two concurrent writers")
	assert(string(first.Settings) == string(second.Settings), "conflict response did not return winning authority")
	_, err = r.Invoke(ctx, "thread:update-settings", []json.RawMessage{raw(model.Object{"threadId": before.ID, "harnessId": "fixture", "change": model.Object{}})})
	assert(err != nil, "settings save allowed no expected revision")

	_, err = r.SendThread(ctx, before.ID, model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "answer once"}}})
	must(err)
	current, err := r.Thread(before.ID)
	must(err)
	var waiting state
	must(json.Unmarshal(native.open.SessionState.Read(), &waiting))
	interaction := model.PublicInteraction{ID: "permission-one", Kind: "permission", Title: "Allow fixture?", Actions: []model.PublicInteractionAction{{ID: "allow", Intent: "allow", Label: "Allow"}}, Questions: []model.PublicInteractionQuestion{}}
	waiting.Observation.LatestExecution.Status = "waiting-for-user"
	waiting.Observation.LatestExecution.Interactions = []model.PublicInteraction{interaction}
	must(native.open.SessionState.Commit(ctx, raw(waiting)))
	answers := make(chan error, 2)
	for range 2 {
		go func() {
			_, err := r.Invoke(ctx, "thread:interaction-respond", []json.RawMessage{raw(model.Object{"threadId": before.ID, "executionId": current.Observation.LatestExecution.ExecutionID, "interactionId": interaction.ID, "actionId": "allow"})})
			answers <- err
		}()
	}
	a, b := receive(answers), receive(answers)
	assert((a == nil) != (b == nil) && native.responses.Load() == 1, "duplicate answer reached native transport")
	_, err = r.UpdateThreadSettings(ctx, before.ID, "fixture", first.SettingsRevision, raw(model.Object{"choice": "busy"}))
	assert(err != nil, "settings changed during waiting execution")
	fmt.Println("PASS SQLite two-client thread settings CAS and first-answer claim before native acknowledgement")

	interaction.ID = "permission-retry"
	waiting.Observation.LatestExecution.Interactions = []model.PublicInteraction{interaction}
	must(native.open.SessionState.Commit(ctx, raw(waiting)))
	response := model.RespondRequest{ExecutionID: current.Observation.LatestExecution.ExecutionID, InteractionID: interaction.ID, ActionID: "allow"}
	native.responseNotSent.Store(true)
	err = r.RespondThread(ctx, before.ID, response)
	var rejected *plugin.InteractionResponseNotSentError
	assert(errors.As(err, &rejected), "pre-I/O rejection lost its explicit classification")
	must(r.RespondThread(ctx, before.ID, response))
	assert(native.responses.Load() == 2, "local rejection consumed claim or reached native I/O")

	interaction.ID = "permission-uncertain"
	waiting.Observation.LatestExecution.Interactions = []model.PublicInteraction{interaction}
	must(native.open.SessionState.Commit(ctx, raw(waiting)))
	response.InteractionID = interaction.ID
	native.responseUncertain.Store(true)
	assert(r.RespondThread(ctx, before.ID, response) != nil, "uncertain native error not returned")
	assert(r.RespondThread(ctx, before.ID, response) != nil && native.responses.Load() == 3, "uncertain reply released its duplicate-prevention claim")

	limit := 16.0
	interaction = model.PublicInteraction{ID: "numeric-typed", Kind: "question", Title: "Typed numeric answer", Actions: []model.PublicInteractionAction{{ID: "submit", Intent: "submit", Label: "Submit"}}, Questions: []model.PublicInteractionQuestion{{ID: "count", Prompt: "Count", AllowOther: true, Options: []model.PublicInteractionOption{}, Form: &model.PublicQuestionForm{Type: "integer", Required: true, Minimum: &limit, Maximum: &limit}}}}
	waiting.Observation.LatestExecution.Interactions = []model.PublicInteraction{interaction}
	must(native.open.SessionState.Commit(ctx, raw(waiting)))
	native.requireTypedNumber.Store(true)
	must(r.RespondThread(ctx, before.ID, model.RespondRequest{ExecutionID: current.Observation.LatestExecution.ExecutionID, InteractionID: interaction.ID, ActionID: "submit", Answers: map[string]json.RawMessage{"count": raw("0x10")}}))
	native.requireTypedNumber.Store(false)
	fmt.Println("PASS typed numeric handoff, retry after certain pre-I/O rejection, and retained claim after uncertain native I/O")

	must(r.SetServiceDraining(true))
	assert(cancelObserved(r, current).Status == "cancelled", "drain prevented cancellation")
	_, err = r.SendThread(ctx, before.ID, model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "must not start"}}})
	assert(err != nil, "draining admitted an independent execution")
	must(r.SetServiceDraining(false))
	_, err = r.SendThread(ctx, before.ID, model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "drain cancelled"}}})
	must(err)
	must(r.SetServiceDraining(true))
	follow, err := r.SendThread(ctx, before.ID, model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "continuation allowed"}}})
	must(err)
	assert(!follow.StartedNewExecution, "drain continuation started another execution")
	activity, err := r.ServiceActivity()
	must(err)
	assert(activity.Busy(), "drain ignored active work")
	must(r.SetServiceDraining(false))
	fmt.Println("PASS host drain rejects new execution, permits continuation/cancel and exposes active work")
}
