package main

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync/atomic"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/pi"
)

func verifyTransport(ctx context.Context) {
	for _, v := range []string{"0.83.0", "1.0.0", "2.1.5+build.1"} {
		o := fixtureOptions("")
		o.Env["MOKUSEI_PI_VERIFICATION_VERSION"] = v
		got, err := pi.GetVersion(ctx, o)
		check(err == nil && got == v, "stable version acceptance")
	}
	for _, v := range []string{"0.82.9", "1.0.0-beta", "v1.0.0", "01.0.0", "9007199254740992.0.0"} {
		o := fixtureOptions("")
		o.Env["MOKUSEI_PI_VERIFICATION_VERSION"] = v
		_, err := pi.GetVersion(ctx, o)
		check(err != nil, "stable version rejection")
	}
	s := startFixture(ctx, "")
	defer s.Close()
	native, err := s.State(ctx)
	check(err == nil && native.SessionID == "id" && native.Model != nil && *native.Model.Reasoning, "native state")
	models, err := s.Models(ctx)
	check(err == nil && len(models) == 2 && models[0].BaseURL == "" && models[0].SupportsReasoningEffort != nil && !*models[0].SupportsReasoningEffort, "models metadata")
	commands, err := s.Commands(ctx)
	check(err == nil && len(commands) == 1 && commands[0].SourcePath == "/extension", "commands")
	levels, err := s.ThinkingLevels(ctx)
	check(err == nil && len(levels) == 2, "thinking levels")
	check(s.Clone(ctx) == nil, "clone")
	var updates atomic.Int64
	var sawThinking atomic.Bool
	var invalidStreamingUsage atomic.Bool
	s.Subscribe(func(event pi.Event) {
		if event.Type == "assistant" && event.Phase == "update" {
			updates.Add(1)
			if event.Usage != nil {
				invalidStreamingUsage.Store(true)
			}
			if event.Thinking == "reason" {
				sawThinking.Store(true)
			}
		}
	})
	before := time.Now()
	completion, err := s.Complete(ctx, pi.PromptInput{Message: "normal"}, pi.CompletionPolicy{})
	check(err == nil && completion.Text == "Hello world" && completion.FinishReason == "stop" && completion.Usage.Input == 1, "completion")
	check(time.Since(before) >= 70*time.Millisecond, "agent_end not settlement")
	check(s.FlushEvents(ctx) == nil, "flush native events")
	check(updates.Load() == 5 && sawThinking.Load() && !invalidStreamingUsage.Load(), "delta accumulation and streaming usage exclusion")
	check(s.Prompt(ctx, pi.PromptInput{Message: "handled"}) != nil, "handled prompt rejects")
	_, err = s.Complete(ctx, pi.PromptInput{Message: "normal"}, pi.CompletionPolicy{})
	check(err == nil, "handled run released")
	check(s.Prompt(ctx, pi.PromptInput{Message: "active"}) == nil, "start active prompt")
	check(s.Prompt(ctx, pi.PromptInput{Message: "handled", Steer: true}) != nil, "handled steer rejects")
	_, err = s.Complete(ctx, pi.PromptInput{Message: "normal"}, pi.CompletionPolicy{})
	check(err != nil, "handled steer preserves active run")
	check(s.Prompt(ctx, pi.PromptInput{Message: "finish", Steer: true}) == nil, "steer completes active run")
	_ = s.Close()
	isolated := startFixture(ctx, "")
	steering := plugin.NewPromptSteering()
	completed := make(chan error, 1)
	go func() {
		result, err := isolated.CompleteSteerable(ctx, pi.PromptInput{Message: "active"}, pi.CompletionPolicy{DisallowTools: true}, steering)
		if err == nil && result.Text != "Hello world" {
			err = fmt.Errorf("wrong steered completion: %s", result.Text)
		}
		completed <- err
	}()
	steerErr := steering.Send(ctx, "normal")
	check(steerErr == nil || errors.Is(steerErr, plugin.ErrPromptSettled), "isolated native steer")
	select {
	case err := <-completed:
		check(err == nil, "steered isolated completion")
	case <-ctx.Done():
		panic(ctx.Err())
	}
	check(errors.Is(steering.Send(ctx, "late"), plugin.ErrPromptSettled), "settled isolated completion rejected without new native run")
	_ = isolated.Close()
	for _, scenario := range []string{"invalid-delta", "oversize", "tool", "interaction"} {
		session := startFixture(ctx, scenario)
		defer session.Close()
		_, err := session.Complete(ctx, pi.PromptInput{Message: "normal"}, pi.CompletionPolicy{DisallowTools: true})
		check(err != nil, "scenario rejects: "+scenario)
		_ = session.Close()
	}
	if verificationConfig.timeouts {
		verifyTimeouts(ctx)
	}
	fmt.Println("PASS Pi transport/session: version gate, catalogs, deltas, settled completion, handled input, policies, frame bound")
}

func verifyTimeouts(ctx context.Context) {
	checks := []func() error{func() error {
		before := time.Now()
		session, err := pi.StartSession(ctx, fixtureOptions("startup-timeout"))
		if session != nil {
			defer session.Close()
		}
		check(err != nil && strings.Contains(err.Error(), "startup timed out") && time.Since(before) >= 14*time.Second, "15s startup timeout")
		return nil
	}, func() error {
		session := startFixture(ctx, "request-timeout")
		defer session.Close()
		before := time.Now()
		_, err := session.Commands(ctx)
		check(err != nil && strings.Contains(err.Error(), "request timed out") && time.Since(before) >= 29*time.Second, "30s request timeout")
		return session.Close()
	}}
	results := make(chan error, len(checks))
	for _, run := range checks {
		go func() { results <- captureFailure(run) }()
	}
	var failure error
	for range checks {
		if err := <-results; err != nil && failure == nil {
			failure = err
		}
	}
	check(failure == nil, "real timeout verification: "+fmt.Sprint(failure))
	fmt.Println("PASS Pi actual timeout durations: 15-second startup and 30-second request")
}
