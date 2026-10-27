package main

import (
	"context"
	"encoding/json"
	"errors"
	"sync/atomic"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

type admittingHandle struct {
	nativeHandle
	dispatchErr    error
	dispatched     bool
	afterAdmission func()
}

func (h *admittingHandle) Send(_ context.Context, request plugin.SendRequest) error {
	if err := request.Admitted(); err != nil {
		return err
	}
	if h.afterAdmission != nil {
		h.afterAdmission()
	}
	h.dispatched = true
	return h.dispatchErr
}

type failingMetadataStore struct{ *memoryStore }

func (s failingMetadataStore) Commit(context.Context, int64, json.RawMessage) (bool, error) {
	return false, errors.New("fixture metadata persistence failure")
}

func admission() {
	dispatchFailure := errors.New("fixture native startup failure")
	rejectedAdmission := errors.New("fixture admission rejected")
	for _, scenario := range []struct {
		name            string
		dispatchErr     error
		admissionErr    error
		cancelOnReceipt bool
		metadataFailure bool
	}{
		{name: "accepted input"},
		{name: "accepted input before failed dispatch", dispatchErr: dispatchFailure},
		{name: "released caller after successful dispatch", cancelOnReceipt: true},
		{name: "released caller after receipt", dispatchErr: context.Canceled, cancelOnReceipt: true},
		{name: "rejected admission", admissionErr: rejectedAdmission},
		{name: "failed metadata persistence", metadataFailure: true},
	} {
		s := store()
		var metadata plugin.MetadataStore = s
		if scenario.metadataFailure {
			metadata = failingMetadataStore{s}
		}
		native := &admittingHandle{dispatchErr: scenario.dispatchErr}
		h := plugin.WithGeneratedThreadMetadata(context.Background(), plugin.OpenContext{
			ThreadID: "fixture", Metadata: metadata,
			ReadThread: func() model.SessionRecord { return model.SessionRecord{} },
		}, native, func(context.Context, plugin.PromptRequest, json.RawMessage) (plugin.PromptResult, error) {
			return answer("Accepted task summary"), nil
		})
		ctx, cancel := context.WithCancel(context.Background())
		receipts := 0
		err := h.Send(ctx, plugin.SendRequest{ExecutionID: "admitted-execution", Input: input("accepted metadata intent"), Admitted: func() error {
			receipts++
			if scenario.cancelOnReceipt {
				cancel()
			}
			return scenario.admissionErr
		}})
		cancel()
		check(receipts == 1, scenario.name+": admission callback count changed")
		if scenario.admissionErr != nil {
			check(errors.Is(err, scenario.admissionErr) && !native.dispatched, scenario.name+": rejected input dispatched")
		} else {
			check(errors.Is(err, scenario.dispatchErr) && native.dispatched, scenario.name+": metadata changed native dispatch result")
		}
		if scenario.admissionErr != nil || scenario.metadataFailure {
			must(h.Close())
			check(s.Read().Revision == 0, scenario.name+": metadata unexpectedly changed")
			continue
		}
		s.wait("Accepted task summary")
		var recent model.AgentInput
		must(json.Unmarshal(s.fields()["recentInput"], &recent))
		check(len(recent.Parts) == 1 && recent.Parts[0].Text == "accepted metadata intent", scenario.name+": accepted input was lost or duplicated")
		must(h.Close())
	}
	pendingDispatch()
	interruptedAdmission()
}

func pendingDispatch() {
	s := store()
	receipt := make(chan struct{})
	release := make(chan struct{})
	native := &admittingHandle{afterAdmission: func() { close(receipt); <-release }}
	h := plugin.WithGeneratedThreadMetadata(context.Background(), plugin.OpenContext{
		ThreadID: "fixture", Metadata: s,
		ReadThread: func() model.SessionRecord { return model.SessionRecord{} },
	}, native, func(ctx context.Context, _ plugin.PromptRequest, _ json.RawMessage) (plugin.PromptResult, error) {
		<-ctx.Done()
		return plugin.PromptResult{}, ctx.Err()
	})
	sent := make(chan error, 1)
	go func() {
		sent <- h.Send(context.Background(), plugin.SendRequest{ExecutionID: "pending-dispatch", Input: input("admitted while dispatch is pending"), Admitted: func() error { return nil }})
	}()
	receive(receipt)
	var pending struct {
		ExecutionID string `json:"executionId"`
	}
	must(json.Unmarshal(s.fields()["pending"], &pending))
	check(pending.ExecutionID == "pending-dispatch", "metadata retention waited for native dispatch")
	close(release)
	must(receive(sent))
	must(h.Close())
}

type interruptedAdmissionHandle struct {
	nativeHandle
	interrupted chan struct{}
	sent        chan struct{}
}

func (h *interruptedAdmissionHandle) Send(_ context.Context, request plugin.SendRequest) error {
	defer close(h.sent)
	return request.Admitted()
}

func (h *interruptedAdmissionHandle) Interrupt(context.Context) error {
	close(h.interrupted)
	<-h.sent
	return nil
}

func interruptedAdmission() {
	s := store()
	native := &interruptedAdmissionHandle{interrupted: make(chan struct{}), sent: make(chan struct{})}
	var completions atomic.Int32
	h := plugin.WithGeneratedThreadMetadata(context.Background(), plugin.OpenContext{
		ThreadID: "fixture", Metadata: s,
		ReadThread: func() model.SessionRecord { return model.SessionRecord{} },
	}, native, func(context.Context, plugin.PromptRequest, json.RawMessage) (plugin.PromptResult, error) {
		completions.Add(1)
		return answer("Unexpected resumed title"), nil
	})
	receipt := make(chan struct{})
	release := make(chan struct{})
	sent := make(chan error, 1)
	go func() {
		sent <- h.Send(context.Background(), plugin.SendRequest{ExecutionID: "interrupted-execution", Input: input("accepted before interrupt"), Admitted: func() error {
			close(receipt)
			<-release
			return nil
		}})
	}()
	receive(receipt)
	interrupted := make(chan error, 1)
	go func() { interrupted <- h.Interrupt(context.Background()) }()
	receive(native.interrupted)
	close(release)
	must(receive(sent))
	must(receive(interrupted))
	check(completions.Load() == 0, "late admission restarted naming after interrupt")
	var pending struct {
		Input       model.AgentInput `json:"input"`
		ExecutionID string           `json:"executionId"`
	}
	must(json.Unmarshal(s.fields()["pending"], &pending))
	check(pending.ExecutionID == "interrupted-execution" && len(pending.Input.Parts) == 1 && pending.Input.Parts[0].Text == "accepted before interrupt", "interrupt lost acknowledged metadata intent")
	must(h.Close())
	reopened := open(s, func(context.Context, plugin.PromptRequest, json.RawMessage) (plugin.PromptResult, error) {
		return answer("Interrupted task summary"), nil
	})
	defer reopened.Close()
	s.wait("Interrupted task summary")
}
