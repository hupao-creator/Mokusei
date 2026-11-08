package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	core "github.com/hupao-creator/Mokusei/internal/core/runtime"
	"github.com/hupao-creator/Mokusei/internal/core/store"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/pi"
)

const runtimeFinalJSONL = "{\"type\":\"message\",\"id\":\"shutdown-final\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"final native shutdown write\"}]}}\n"

func runtimeLifecycleModel() map[string]any {
	return map[string]any{"id": "model", "provider": "provider", "api": "openai-responses", "reasoning": true,
		"thinkingLevelMap": map[string]any{"high": "high"}, "input": []string{"text", "image"}}
}

func awaitRuntimeLifecycle(ctx context.Context, ready func() bool, description string) {
	for !ready() {
		select {
		case <-ctx.Done():
			panic(fmt.Errorf("%s: %w", description, ctx.Err()))
		case <-time.After(5 * time.Millisecond):
		}
	}
}

// Unlike the adapter replay's memoryStore, this crosses Core ownership and the
// SQLite commit/reopen boundary while the actual native process owns its file.
func verifyRuntimeLifecycle(parent context.Context) {
	ctx, cancel := context.WithTimeout(parent, 20*time.Second)
	defer cancel()
	root, err := os.MkdirTemp(fixtureRoot, "runtime-lifecycle-")
	check(err == nil, "create runtime lifecycle profile")
	defer os.RemoveAll(root)
	options := fixtureOptions("runtime-lifecycle")
	options.Env["MOKUSEI_PI_LIFECYCLE_ROOT"] = root
	open := func() (*core.Runtime, *store.Store, *pi.Adapter) {
		db, err := store.Open(filepath.Join(root, "state.sqlite"))
		check(err == nil, "open lifecycle SQLite: "+fmt.Sprint(err))
		adapter := pi.New(plugin.HostContext{
			HarnessDataRoot: filepath.Join(root, "harness"), TemporaryWorkspaceRoot: filepath.Join(root, "temporary"),
			Environment:       func(context.Context) (map[string]string, error) { return options.Env, nil },
			ResolveExecutable: func(context.Context, string, string, string) (string, error) { return options.ExecutablePath, nil },
		})
		runtime, err := core.New(ctx, core.Config{Store: db, Harnesses: map[string]plugin.Harness{"pi": adapter}, DataDir: root, DefaultCwd: root})
		if err != nil {
			_ = adapter.Close()
			_ = db.Close()
			panic(err)
		}
		return runtime, db, adapter
	}
	runtime, db, adapter := open()
	release := filepath.Join(root, "release")
	defer func() {
		_ = os.WriteFile(release, nil, 0600)
		_ = runtime.Close(context.Background())
		_ = adapter.Close()
		_ = db.Close()
	}()
	input := func(text string) model.AgentInput {
		return model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: text}}}
	}
	settings, err := adapter.Settings().ResolveThread(ctx, plugin.ResolveSettingsRequest{Cwd: root,
		Merged: json.RawMessage(`{"provider":"provider","model":"model","thinking":{"mode":"effort","effort":"high"}}`)})
	check(err == nil, "resolve ordinary Pi settings: "+fmt.Sprint(err))
	created, err := runtime.CreateThread(ctx, core.CreateThreadRequest{HarnessID: "pi", Cwd: root,
		Settings: settings, Input: input("active")})
	check(err == nil, "create real Pi runtime thread: "+fmt.Sprint(err))
	read := func() (model.ThreadRecord, pi.State) {
		thread, err := runtime.Thread(created.Record.ID)
		check(err == nil, "read lifecycle thread: "+fmt.Sprint(err))
		var state pi.State
		check(json.Unmarshal(thread.SessionState, &state) == nil, "decode lifecycle snapshot")
		return thread, state
	}
	// Core admission precedes native startup. Wait for the real child to receive
	// its prompt before exercising shutdown, rather than racing its creation.
	awaitRuntimeLifecycle(ctx, func() bool {
		thread, _ := read()
		if execution := thread.Observation.LatestExecution; execution != nil && execution.Terminal() {
			data, _ := json.Marshal(execution)
			panic(fmt.Sprintf("native startup settled before prompt: %s", data))
		}
		_, err := os.Stat(filepath.Join(root, "source.pid"))
		return err == nil
	}, "native prompt admission")
	_, before := read()
	check(before.SessionFile != "", "native session file admitted through Core")
	closing := make(chan error, 1)
	go func() { closing <- runtime.InterruptThread(ctx, created.Record.ID) }()
	awaitRuntimeLifecycle(ctx, func() bool { _, err := os.Stat(filepath.Join(root, "eof")); return err == nil }, "native EOF barrier")
	select {
	case err := <-closing:
		panic(fmt.Sprintf("interrupt returned before native disposal: %v", err))
	default:
	}
	pending, pendingState := read()
	check(pending.Observation.LatestExecution != nil && !pending.Observation.LatestExecution.Terminal(), "SQLite terminal published before native disposal")
	check(pendingState.NativeSessionJSONL == before.NativeSessionJSONL, "snapshot changed before native final write")
	check(os.WriteFile(release, nil, 0600) == nil, "release native disposal")
	select {
	case err := <-closing:
		check(err == nil, "runtime interrupt drains Pi: "+fmt.Sprint(err))
	case <-ctx.Done():
		panic(ctx.Err())
	}
	stopped, final := read()
	check(stopped.Observation.LatestExecution != nil && stopped.Observation.LatestExecution.Status == "interrupted", "interruption persisted after drain")
	data, err := os.ReadFile(final.SessionFile)
	check(err == nil && string(data) == final.NativeSessionJSONL && strings.Contains(final.NativeSessionJSONL, runtimeFinalJSONL), "SQLite retained the final native shutdown write")
	assertReaped := func(name string) {
		data, err := os.ReadFile(filepath.Join(root, name))
		check(err == nil, "read native process identity")
		pid, err := strconv.Atoi(string(data))
		check(err == nil && pid > 0 && errors.Is(syscall.Kill(pid, 0), syscall.ESRCH), "native process was reaped before owner replacement")
	}
	assertReaped("source.pid")
	err = errors.Join(runtime.Close(ctx), adapter.Close(), db.Close())
	check(err == nil, "close persisted lifecycle profile: "+fmt.Sprint(err))
	runtime, db, adapter = open()
	reopened, restored := read()
	check(restored.NativeSessionJSONL == final.NativeSessionJSONL && reflect.DeepEqual(reopened.Observation.LatestExecution, stopped.Observation.LatestExecution), "SQLite reopen changed the final native snapshot or execution")
	next, err := runtime.SendThread(ctx, created.Record.ID, input("normal"))
	check(err == nil && next.ExecutionID != created.Execution.ExecutionID, "reopened owner accepts one successor: "+fmt.Sprint(err))
	awaitRuntimeLifecycle(ctx, func() bool {
		thread, _ := read()
		return thread.Observation.LatestExecution != nil && thread.Observation.LatestExecution.ExecutionID == next.ExecutionID && thread.Observation.LatestExecution.Terminal()
	}, "successor terminal commit")
	after, successor := read()
	check(after.Observation.LatestExecution.Status == "completed" && after.Observation.LatestExecution.Summary != nil && *after.Observation.LatestExecution.Summary == "Hello world", "successor retained only its own native completion")
	check(len(successor.Executions) == 2 && reflect.DeepEqual(successor.Executions[0], final.Executions[0]), "retired native callbacks rewrote the original terminal execution")
	check(runtime.Close(ctx) == nil, "close successor runtime")
	assertReaped("successor.pid")
	check(writeArtifact("runtime-lifecycle-state.json", after.SessionState) == nil, "retain runtime lifecycle evidence")
	fmt.Println("PASS Pi Runtime/SQLite lifecycle: EOF barrier, final native snapshot, process reap, durable reopen and successor isolation")
}

func runtimeLifecyclePrompt(text, sessionPath string) bool {
	root := os.Getenv("MOKUSEI_PI_LIFECYCLE_ROOT")
	name := "source.pid"
	if text == "normal" {
		data, err := os.ReadFile(sessionPath)
		check(err == nil && strings.Contains(string(data), runtimeFinalJSONL), "reopened native session has final snapshot")
		name = "successor.pid"
	} else if text != "active" {
		return false
	}
	check(os.WriteFile(filepath.Join(root, name), []byte(strconv.Itoa(os.Getpid())), 0600) == nil, "record lifecycle child")
	return text == "active"
}

func runtimeLifecycleShutdown(sessionPath string) {
	root := os.Getenv("MOKUSEI_PI_LIFECYCLE_ROOT")
	check(os.WriteFile(filepath.Join(root, "eof"), nil, 0600) == nil, "report native EOF")
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	awaitRuntimeLifecycle(ctx, func() bool { _, err := os.Stat(filepath.Join(root, "release")); return err == nil }, "release native EOF")
	file, err := os.OpenFile(sessionPath, os.O_APPEND|os.O_WRONLY, 0600)
	check(err == nil, "open final native snapshot")
	_, err = file.WriteString(runtimeFinalJSONL)
	check(err == nil && file.Close() == nil, "finish final native snapshot")
	// These real late frames must not become another execution's completion.
	emitFixture(map[string]any{"type": "message_end", "message": map[string]any{"role": "assistant", "content": []any{map[string]any{"type": "text", "text": "obsolete shutdown reply"}}, "stopReason": "stop"}})
	emitFixture(map[string]any{"type": "agent_settled"})
}
