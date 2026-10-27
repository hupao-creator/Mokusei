package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"sync/atomic"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	core "github.com/hupao-creator/Mokusei/internal/core/runtime"
	"github.com/hupao-creator/Mokusei/internal/plugins/applications/background"
	"github.com/hupao-creator/Mokusei/internal/services/directorytag"
)

var readCalls atomic.Int64
var readStarted = make(chan struct{}, 1)
var readFailure = errors.New("fixture native read failure")

func verifyReportRead(ctx context.Context, r *core.Runtime, id, privateID string) {
	source, err := r.Thread(id)
	must(err)
	tasks, err := plugin.Require[plugin.OrdinaryTaskReadCapability](r.BackgroundCapabilities(plugin.BackgroundAgentRef{PluginID: "report", AgentID: "report.agent.read-verification", Binding: plugin.ScopeBinding{Kind: plugin.DirectoryScopeKind, Scope: directorytag.Scope(source.Cwd)}}, "report.settings"), plugin.OrdinaryTaskReadCapabilityKey)
	must(err)
	lifetime, stop := context.WithCancel(ctx)
	defer stop()
	var tool plugin.ToolBinding
	for _, binding := range background.EvidenceTools(lifetime, tasks, nil) {
		if binding.Name == "read_thread" {
			tool = binding
		}
	}
	var schema struct {
		Properties map[string]json.RawMessage `json:"properties"`
		Required   []string                   `json:"required"`
	}
	must(json.Unmarshal(tool.InputSchema, &schema))
	if len(schema.Properties) != 2 || len(schema.Required) != 2 || schema.Properties["question"] == nil || schema.Properties["threadId"] == nil {
		panic("report read schema is not threadId + question")
	}
	invoke := func(callCtx context.Context, args model.Object) (json.RawMessage, error) {
		return tool.Execute(callCtx, plugin.ToolCall{Arguments: raw(args)})
	}
	before, err := r.Thread(id)
	must(err)
	for _, question := range []string{"result", "verification"} {
		result, err := invoke(ctx, model.Object{"threadId": id, "question": " " + question + " "})
		must(err)
		if !bytes.Equal(result, raw(model.Object{"ok": true, "threadId": id, "answer": "answer: " + question})) {
			panic("report read did not return the Harness answer")
		}
	}
	after, err := r.Thread(id)
	must(err)
	if !bytes.Equal(raw(before), raw(after)) {
		panic("report read changed source record or execution")
	}
	must(r.SetArchived(ctx, id, true))
	_, err = invoke(ctx, model.Object{"threadId": id, "question": "archived evidence"})
	must(err)
	must(r.SetArchived(ctx, id, false))
	moku, err := r.EnsureMokuThread(ctx, "fixture", raw(model.Object{}), before.Cwd)
	must(err)
	mokuID := moku.ID
	baseline, err := r.Thread(id)
	must(err)
	calls := readCalls.Load()
	for _, args := range []model.Object{
		{"threadId": id},
		{"threadId": id, "question": " "},
		{"threadId": id, "question": 42},
		{"threadId": id, "question": "bad\x00question"},
		{"threadId": id, "question": strings.Repeat("😀", 500001)},
		{"threadId": strings.Repeat("a", 129), "question": "result"},
		{"threadId": id, "question": "result", "offset": 0},
		{"threadId": id, "question": "result", "limit": 100},
		{"threadId": mokuID, "question": "result"},
		{"threadId": privateID, "question": "result"},
		{"threadId": "missing-thread", "question": "result"},
	} {
		if _, err := invoke(ctx, args); err == nil {
			panic("report read accepted invalid arguments or target")
		}
	}
	if _, err := tasks.ReadThread(ctx, model.ThreadRef{ThreadID: id, TypeID: "report"}, "result"); err == nil {
		panic("question capability accepted nonordinary reference")
	}
	if readCalls.Load() != calls {
		panic("invalid read reached native Harness")
	}
	_, err = invoke(ctx, model.Object{"threadId": id, "question": "native error"})
	if !errors.Is(err, readFailure) {
		panic("native read error was hidden or fell back to transcript")
	}
	for _, cancelLifetime := range []bool{false, true} {
		callCtx, cancel := context.WithCancel(ctx)
		done := make(chan error, 1)
		go func() {
			_, err := invoke(callCtx, model.Object{"threadId": id, "question": "wait for cancellation"})
			done <- err
		}()
		select {
		case <-readStarted:
		case <-time.After(5 * time.Second):
			panic("native read did not start")
		}
		if cancelLifetime {
			stop()
		} else {
			cancel()
		}
		select {
		case err := <-done:
			if !errors.Is(err, context.Canceled) {
				panic("read cancellation was not propagated")
			}
		case <-time.After(5 * time.Second):
			panic("native read did not stop")
		}
		cancel()
	}
	if _, err := invoke(ctx, model.Object{"threadId": id, "question": "retired tool"}); !errors.Is(err, context.Canceled) {
		panic("retired report tool retained read authority")
	}
	after, err = r.Thread(id)
	must(err)
	if !bytes.Equal(raw(baseline), raw(after)) {
		panic("failed or cancelled report read changed source record")
	}
	history, err := tasks.CaptureHistory(ctx, model.ThreadRef{ThreadID: id, TypeID: "agent"})
	must(err)
	if history.Content != string(after.SessionState) {
		panic("raw history capability changed")
	}
	fmt.Println("PASS Report question reads through Runtime/Harness, answer contract, source isolation, archived evidence, validation, ordinary-task boundary, native errors and cancellation")
}
