package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"sync/atomic"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	core "github.com/hupao-creator/Mokusei/internal/core/runtime"
	"github.com/hupao-creator/Mokusei/internal/services/directorytag"
)

var readCalls atomic.Int64
var readStarted = make(chan struct{}, 1)
var readFailure = errors.New("fixture native read failure")

func verifyTaskReadCapability(ctx context.Context, r *core.Runtime, id, privateID string) {
	source, err := r.Thread(id)
	must(err)
	tasks, err := plugin.Require[plugin.OrdinaryTaskReadCapability](r.BackgroundCapabilities(plugin.BackgroundAgentRef{PluginID: "report", AgentID: "report.agent.read-verification", Binding: plugin.ScopeBinding{Kind: plugin.DirectoryScopeKind, Scope: directorytag.Scope(source.Cwd)}}, "report.settings"), plugin.OrdinaryTaskReadCapabilityKey)
	must(err)
	before, err := r.Thread(id)
	must(err)
	for _, question := range []string{"result", "verification"} {
		result, err := tasks.ReadThread(ctx, model.ThreadRef{ThreadID: id, TypeID: "agent"}, question)
		must(err)
		if result != "answer: "+question {
			panic("task capability read did not return the Harness answer")
		}
	}
	after, err := r.Thread(id)
	must(err)
	if !bytes.Equal(raw(before), raw(after)) {
		panic("task capability read changed source record or execution")
	}
	must(r.SetArchived(ctx, id, true))
	_, err = tasks.ReadThread(ctx, model.ThreadRef{ThreadID: id, TypeID: "agent"}, "archived evidence")
	must(err)
	must(r.SetArchived(ctx, id, false))
	moku, err := r.EnsureMokuThread(ctx, "fixture", raw(model.Object{}), before.Cwd)
	must(err)
	mokuID := moku.ID
	baseline, err := r.Thread(id)
	must(err)
	calls := readCalls.Load()
	for _, target := range []string{mokuID, privateID, "missing-thread"} {
		if _, err := tasks.ReadThread(ctx, model.ThreadRef{ThreadID: target, TypeID: "agent"}, "result"); err == nil {
			panic("question capability accepted invalid target")
		}
	}
	if _, err := tasks.ReadThread(ctx, model.ThreadRef{ThreadID: id, TypeID: "report"}, "result"); err == nil {
		panic("question capability accepted nonordinary reference")
	}
	if readCalls.Load() != calls {
		panic("invalid read reached native Harness")
	}
	_, err = tasks.ReadThread(ctx, model.ThreadRef{ThreadID: id, TypeID: "agent"}, "native error")
	if !errors.Is(err, readFailure) {
		panic("native read error was hidden or fell back to transcript")
	}
	{
		callCtx, cancel := context.WithCancel(ctx)
		done := make(chan error, 1)
		go func() {
			_, err := tasks.ReadThread(callCtx, model.ThreadRef{ThreadID: id, TypeID: "agent"}, "wait for cancellation")
			done <- err
		}()
		select {
		case <-readStarted:
		case <-time.After(5 * time.Second):
			panic("native read did not start")
		}
		cancel()
		select {
		case err := <-done:
			if !errors.Is(err, context.Canceled) {
				panic("read cancellation was not propagated")
			}
		case <-time.After(5 * time.Second):
			panic("native read did not stop")
		}
	}
	after, err = r.Thread(id)
	must(err)
	if !bytes.Equal(raw(baseline), raw(after)) {
		panic("failed or cancelled task capability read changed source record")
	}
	history, err := tasks.CaptureHistory(ctx, model.ThreadRef{ThreadID: id, TypeID: "agent"})
	must(err)
	if history.Content != string(after.SessionState) {
		panic("raw history capability changed")
	}
	fmt.Println("PASS Ordinary-task question capability through Runtime/Harness, source isolation, archived evidence, ordinary-task boundary, native errors and cancellation")
}
