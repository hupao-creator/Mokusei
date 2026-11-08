package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/pi"
)

// The native reader settles while a real subscription callback is blocked. A
// stale steer must fail before native dispatch even though consumers lag behind.
func verifyQueuedSettlement(ctx context.Context) {
	s := startFixture(ctx, "")
	defer s.Close()
	entered, release := make(chan struct{}), make(chan struct{})
	var enteredOnce, releaseOnce sync.Once
	defer releaseOnce.Do(func() { close(release) })
	var starts, terminals atomic.Int64
	s.Subscribe(func(event pi.Event) {
		if event.Type == "started" {
			starts.Add(1)
			enteredOnce.Do(func() { close(entered) })
			select {
			case <-release:
			case <-ctx.Done():
			}
		}
		if event.Type == "settled" {
			terminals.Add(1)
		}
	})
	check(s.Prompt(ctx, pi.PromptInput{Message: "normal"}) == nil, "start queued-settlement source")
	select {
	case <-entered:
	case <-ctx.Done():
		panic(ctx.Err())
	}
	// The fixture reads this request only after writing its terminal event. Its
	// response therefore fences native decoding without unblocking subscribers.
	_, err := s.State(ctx)
	check(err == nil, "fence queued native settlement")
	err = s.Prompt(ctx, pi.PromptInput{Message: "stale follow-up", Steer: true})
	check(err == plugin.ErrExecutionEnded, "ended native run refuses stale steer")
	releaseOnce.Do(func() { close(release) })
	check(s.FlushEvents(ctx) == nil, "deliver queued terminal after stale rejection")
	check(starts.Load() == 1 && terminals.Load() == 1, "stale steer dispatched no new run")
}

func verifyAdmissionOrdering(ctx context.Context) {
	verifyQueuedSettlement(ctx)
	for _, scenario := range []string{"started", "queued", "handled", "rejected", "handled-exit", "rejected-exit", "unknown", "cancel-preflight", "cancel-written", "exit"} {
		verifyAdmissionCase(ctx, scenario)
	}
	fmt.Println("PASS Pi admission replay: queued settlement, stale execution reservation, continued native run, fast queued completion, rejected/handled input, missing outcome, cancellation and terminal-before-exit")
}

func verifyAdmissionCase(ctx context.Context, scenario string) {
	root, err := os.MkdirTemp(fixtureRoot, "admission-")
	check(err == nil, "create admission fixture")
	defer os.RemoveAll(root)
	options := fixtureOptions("admission-" + scenario)
	options.Env["MOKUSEI_PI_VERIFICATION_ADMISSION"] = root
	host := plugin.HostContext{
		HarnessDataRoot: filepath.Join(root, "data"), TemporaryWorkspaceRoot: filepath.Join(root, "temporary"),
		Environment:       func(context.Context) (map[string]string, error) { return options.Env, nil },
		ResolveExecutable: func(context.Context, string, string, string) (string, error) { return options.ExecutablePath, nil },
	}
	adapter := pi.New(host)
	defer adapter.Close()
	store := &memoryStore{}
	record := model.SessionRecord{ID: "thread", HarnessID: "pi", Cwd: root, Settings: json.RawMessage(`{"provider":"provider","model":"model","thinkingLevel":"high"}`)}
	handle, err := adapter.Open(ctx, plugin.OpenContext{ThreadID: record.ID, SessionState: store, ReadThread: func() model.SessionRecord { return record }})
	check(err == nil, "open admission fixture")
	defer handle.Close()
	request := func(text string) plugin.SendRequest {
		return plugin.SendRequest{ExecutionID: "e1", Input: model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: text}}}}
	}
	check(handle.Send(ctx, request("active")) == nil, "start admission source")
	var admissions atomic.Int64
	followUp := request("follow-up")
	followUp.Admitted = func() error {
		admissions.Add(1)
		state := store.state()
		check(len(state.Executions) == 1 && state.Executions[0].ExecutionID == "e1", "acknowledged input retains its execution")
		// A process exit may flush an already-confirmed terminal before its
		// failure notification; it must not turn completed work into a failure.
		check(state.Executions[0].Status == "running" || scenario == "exit" && state.Executions[0].Status == "completed", "native terminal waits for durable input acknowledgement")
		return nil
	}
	if strings.HasPrefix(scenario, "cancel-") {
		cancelled, cancel := context.WithCancel(ctx)
		defer cancel()
		done := make(chan error, 1)
		go func() { done <- handle.Send(cancelled, followUp) }()
		until := time.Now().Add(5 * time.Second)
		for {
			if _, statErr := os.Stat(filepath.Join(root, "ready")); statErr == nil {
				break
			}
			check(ctx.Err() == nil && time.Now().Before(until), "admission fixture reached cancellation boundary: "+scenario)
			time.Sleep(time.Millisecond)
		}
		cancel()
		select {
		case err = <-done:
		case <-ctx.Done():
			panic(ctx.Err())
		}
		check(errors.Is(err, context.Canceled), "cancelled input returns cancellation: "+fmt.Sprint(err))
		check(os.WriteFile(filepath.Join(root, "release"), nil, 0600) == nil, "release cancelled fixture preflight")
	} else {
		err = handle.Send(ctx, followUp)
	}
	accepted := scenario == "started" || scenario == "queued" || scenario == "exit"
	check((err == nil) == accepted, "native admission result: "+scenario+": "+fmt.Sprint(err))
	expectedAdmissions := int64(0)
	if accepted {
		expectedAdmissions = 1
	}
	check(admissions.Load() == expectedAdmissions, "ack only accepted input: "+scenario)
	status := "completed"
	if scenario == "unknown" || scenario == "cancel-written" {
		status = "failed"
	}
	state := waitStatus(ctx, store, "e1", status)
	check(len(state.Executions) == 1, "retained follow-up keeps one owning execution: "+scenario)
	followUps, replies := 0, 0
	for _, message := range state.Messages {
		if message.Role == "user" && message.Text == "follow-up" {
			followUps++
			check(message.ExecutionID == "e1" && message.FollowUp, "ordinary follow-up keeps retained input identity")
		}
		if message.Role == "assistant" && message.Text == "Continuation result" {
			replies++
			check(message.ExecutionID == "e1", "continued run reply belongs to admitted execution")
		}
	}
	if accepted {
		check(followUps == 1 && replies == 1, "accepted follow-up is consumed exactly once: "+scenario)
	} else {
		check(followUps == 0 && replies == 0, "unconsumed input is absent after rejection: "+scenario)
	}
	if status == "completed" && scenario != "exit" {
		// Core may already have reserved E1 when its terminal reaches Thread.
		// It must receive the retry certificate instead of a duplicate E1 row.
		before := store.Read()
		late := request("after terminal")
		late.Admitted = func() error { panic("terminal execution acknowledged new input") }
		check(handle.Send(ctx, late) == plugin.ErrExecutionEnded, "terminal reservation is renewed before retention")
		check(string(store.Read()) == string(before), "stale execution reservation changes no retained state")
	}
	check(handle.Close() == nil, "close admission fixture: "+scenario)
}
