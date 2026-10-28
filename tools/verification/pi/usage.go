package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"github.com/hupao-creator/Mokusei/tools/verification/swiftfixture"
	"os"
	"path/filepath"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/pi"
)

// Replay the production RPC decoder, reducer, durable reopen and compact scopes.
// The expected values are fixed provider facts, never recomputed from the output.
func verifyUsage(ctx context.Context) {
	root, err := os.MkdirTemp(fixtureRoot, "usage-")
	check(err == nil, "usage workspace")
	defer os.RemoveAll(root)
	options := fixtureOptions("")
	adapter := pi.New(plugin.HostContext{HarnessDataRoot: filepath.Join(root, "data"), TemporaryWorkspaceRoot: filepath.Join(root, "temporary"), Environment: func(context.Context) (map[string]string, error) { return options.Env, nil }, ResolveExecutable: func(context.Context, string, string, string) (string, error) { return options.ExecutablePath, nil }})
	store := &memoryStore{}
	record := model.SessionRecord{ID: "usage", HarnessID: "pi", Cwd: root, Settings: json.RawMessage(`{"provider":"provider","model":"model","thinkingLevel":"high"}`)}
	open := plugin.OpenContext{ThreadID: "usage", ReadThread: func() model.SessionRecord { return record }, SessionState: store}
	handle, err := adapter.Open(ctx, open)
	check(err == nil, "open usage thread")
	defer handle.Close()
	fixtures := []model.Object{}
	capture := func(name, id string, expected *pi.Usage, total *int) {
		raw := store.Read()
		fixtures = append(fixtures, model.Object{"name": name + "/durable", "state": json.RawMessage(raw), "executionId": id, "expected": total})
		for _, kind := range []string{"overview", "thread", "execution", "turn"} {
			projection, err := adapter.SessionState().ProjectRenderer(raw, model.RendererScope{Kind: kind, Key: id})
			check(err == nil, "project usage "+kind)
			var value struct {
				ExecutionUsage map[string]*pi.Usage `json:"executionUsage"`
				State          json.RawMessage      `json:"state"`
			}
			check(json.Unmarshal(projection, &value) == nil, "decode usage projection")
			if len(value.State) > 0 {
				projection = value.State
				check(json.Unmarshal(projection, &value) == nil, "decode deferred usage projection")
			}
			actual := value.ExecutionUsage[id]
			check((actual == nil) == (expected == nil), "usage availability "+name+"/"+kind)
			if expected != nil {
				check(actual.Input == expected.Input && actual.Output == expected.Output && actual.CacheRead == expected.CacheRead && actual.CacheWrite == expected.CacheWrite, "usage counts "+name+"/"+kind)
			}
			fixtures = append(fixtures, model.Object{"name": name + "/" + kind, "state": json.RawMessage(projection), "executionId": id, "expected": total})
		}
	}
	send := func(id, text string, count int) {
		check(handle.Send(ctx, plugin.SendRequest{ExecutionID: id, Input: model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: text}}}}) == nil, "send usage "+text)
		until := time.Now().Add(4 * time.Second)
		for {
			rows := store.state().Messages
			assistants := 0
			for _, row := range rows {
				if row.Role == "assistant" {
					assistants++
				}
			}
			if assistants == count && len(rows) > 0 && (text == "usage-stream" || rows[len(rows)-1].Status != "streaming") {
				return
			}
			check(ctx.Err() == nil && time.Now().Before(until), "usage event timeout "+text)
			time.Sleep(5 * time.Millisecond)
		}
	}
	a, b := 121, 343
	first := &pi.Usage{Input: 11, Output: 7, CacheRead: 100, CacheWrite: 3}
	both := &pi.Usage{Input: 24, Output: 12, CacheRead: 300, CacheWrite: 7}
	send("first", "usage-stream", 1)
	capture("initial-stream", "first", nil, nil)
	send("first", "usage-first", 2)
	capture("first-call", "first", first, &a)
	send("first", "usage-next", 3)
	capture("second-call", "first", both, &b)
	send("first", "usage-zero", 4)
	capture("failed-zero", "first", both, &b)
	send("first", "usage-missing", 5)
	capture("failed-missing", "first", both, &b)
	send("first", "usage-stream", 6)
	capture("retry-stream", "first", both, &b)
	// A process restart settles the old execution but must not reset its usage.
	snapshot := store.Read()
	check(handle.Close() == nil, "close usage thread")
	store = &memoryStore{raw: snapshot}
	open.SessionState = store
	handle, err = adapter.Open(ctx, open)
	check(err == nil, "reopen usage thread")
	defer handle.Close()
	waitStatus(ctx, store, "first", "interrupted")
	capture("reopened", "first", both, &b)
	send("second", "usage-first", 7)
	capture("new-execution", "second", first, &a)
	capture("old-execution", "first", both, &b)
	check(handle.Interrupt(ctx) == nil, "interrupt usage replay")
	capture("settled", "second", first, &a)
	zero := 0
	send("zero-only", "usage-zero", 8)
	capture("only-failed-zero", "zero-only", &pi.Usage{}, &zero)
	check(handle.Interrupt(ctx) == nil, "interrupt zero-only replay")
	send("missing-only", "usage-missing", 9)
	capture("only-failed-missing", "missing-only", nil, nil)
	check(handle.Interrupt(ctx) == nil, "interrupt missing-only replay")
	data, err := json.Marshal(fixtures)
	check(err == nil && writeArtifact("usage-fixtures.json", data) == nil, "write usage fixtures")
	if verificationConfig.swiftUsage {
		path := filepath.Join(root, "usage-fixtures.json")
		check(os.WriteFile(path, data, 0600) == nil, "write Swift usage fixtures")
		command := swiftfixture.Test(ctx, "--filter", "PiTokenUsageTests")
		command.Env = append(os.Environ(), "MOKUSEI_PI_USAGE_FIXTURES="+path)
		var output bytes.Buffer
		command.Stdout = &output
		command.Stderr = os.Stderr
		command.WaitDelay = 5 * time.Second
		err := command.Run()
		fmt.Print(output.String())
		check(err == nil && bytes.Contains(output.Bytes(), []byte(fmt.Sprintf("PASS Pi usage fixtures: %d", len(fixtures)))), "Swift usage replay: "+fmt.Sprint(err))
	}
	fmt.Println("PASS Pi usage replay: per-call native fields, running totals, failed zero/missing usage, retry streaming, durable reopen, execution isolation, compact scopes")
}
