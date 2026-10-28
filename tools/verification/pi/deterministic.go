package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/pi"
)

type memoryStore struct {
	mu  sync.Mutex
	raw json.RawMessage
}

func (s *memoryStore) Read() json.RawMessage {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append(json.RawMessage(nil), s.raw...)
}
func (s *memoryStore) Commit(_ context.Context, raw json.RawMessage) error {
	s.mu.Lock()
	s.raw = append(json.RawMessage(nil), raw...)
	s.mu.Unlock()
	return nil
}
func (s *memoryStore) state() pi.State {
	var state pi.State
	check(json.Unmarshal(s.Read(), &state) == nil, "decode persisted state")
	return state
}
func waitStatus(ctx context.Context, store *memoryStore, id, status string) pi.State {
	until := time.Now().Add(4 * time.Second)
	for time.Now().Before(until) {
		check(ctx.Err() == nil, "waiting for state: "+fmt.Sprint(ctx.Err()))
		state := store.state()
		for _, execution := range state.Executions {
			if execution.ExecutionID == id && execution.Status == status {
				return state
			}
			if execution.ExecutionID == id && execution.Terminal() {
				panic(fmt.Sprintf("wanted %s, got %+v", status, execution))
			}
		}
		time.Sleep(time.Millisecond * 5)
	}
	panic("wait status timeout " + id + " " + status + " " + string(store.Read()))
}
func verifyAdapter(ctx context.Context) {
	root, err := os.MkdirTemp(fixtureRoot, "adapter-")
	check(err == nil, "create temp directory")
	defer os.RemoveAll(root)
	fakeOptions := fixtureOptions("")
	host := plugin.HostContext{HarnessDataRoot: filepath.Join(root, "data"), TemporaryWorkspaceRoot: filepath.Join(root, "temporary"), Environment: func(context.Context) (map[string]string, error) { return fakeOptions.Env, nil }, ResolveExecutable: func(context.Context, string, string, string) (string, error) { return fakeOptions.ExecutablePath, nil }}
	adapter := pi.New(host)
	settings := json.RawMessage(`{"provider":"provider","model":"model","thinkingLevel":"high"}`)
	store := &memoryStore{}
	record := model.SessionRecord{ID: "thread", HarnessID: "pi", Cwd: root, Settings: settings}
	open := plugin.OpenContext{ThreadID: "thread", ReadThread: func() model.SessionRecord { return record }, SessionState: store}
	handle, err := adapter.Open(ctx, open)
	check(err == nil, "open adapter")
	defer handle.Close()
	send := func(handle plugin.Handle, id, text string) error {
		return handle.Send(ctx, plugin.SendRequest{ExecutionID: id, Input: model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: text}}}})
	}
	var admissions atomic.Int64
	err = handle.Send(ctx, plugin.SendRequest{ExecutionID: "admission-denied", Input: model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "normal"}}}, Admitted: func() error {
		admissions.Add(1)
		state := store.state()
		check(len(state.Executions) == 1 && state.Executions[0].Status == "running" && state.SessionFile == "", "admit after durability before native startup")
		return fmt.Errorf("rejected admission")
	}})
	check(err != nil && admissions.Load() == 1, "admission callback exactly once")
	waitStatus(ctx, store, "admission-denied", "failed")
	check(send(handle, "first", "normal") == nil, "send normal")
	untilLive := time.Now().Add(time.Second)
	for {
		check(ctx.Err() == nil, "live state context: "+fmt.Sprint(ctx.Err()))
		live := store.Read()
		var value map[string]any
		_ = json.Unmarshal(live, &value)
		foregrounds, _ := value["foregrounds"].([]any)
		if len(foregrounds) > 0 {
			foreground := foregrounds[0].(map[string]any)["foreground"].(map[string]any)
			_, hasIdentity := foreground["executionId"]
			check(!hasIdentity, "foreground nested execution ID omitted")
			check(writeArtifact("live-state.json", live) == nil, "capture live state")
			projected, err := adapter.SessionState().ProjectRenderer(live, model.RendererScope{Kind: "overview"})
			check(err == nil && writeArtifact("live-overview.json", projected) == nil, "capture live overview")
			break
		}
		check(time.Now().Before(untilLive), "live foreground observed")
		time.Sleep(time.Millisecond)
	}
	state := waitStatus(ctx, store, "first", "completed")
	check(len(state.Messages) == 3 && state.NativeSessionJSONL != "", "persisted user/assistant and native snapshot")
	reply, ok := handle.(plugin.CompletedReply).CompletedReply("first")
	check(ok && reply == "Hello world", "completed reply")
	// Cancellation after the acceptance acknowledgment must not cancel the task.
	for i := 0; i < 12; i++ {
		accept, cancel := context.WithCancel(ctx)
		id := fmt.Sprintf("ack-%d", i)
		err := handle.Send(accept, plugin.SendRequest{ExecutionID: id, Input: model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "normal"}}}})
		cancel()
		check(err == nil, "ack send")
		waitStatus(ctx, store, id, "completed")
	}
	check(send(handle, "steer", "active") == nil, "active prompt")
	check(send(handle, "steer", "handled") != nil, "consumed steer rejects")
	state = store.state()
	check(state.Executions[len(state.Executions)-1].Status == "running", "consumed steer leaves run alive")
	check(send(handle, "steer", "finish") == nil, "steer input accepted")
	waitStatus(ctx, store, "steer", "completed")
	check(send(handle, "question", "ask") == nil, "interaction prompt")
	state = waitStatus(ctx, store, "question", "waiting-for-user")
	interaction := state.Executions[len(state.Executions)-1].Interactions[0]
	check(interaction.Questions[0].Options[0].Value == "rawchoice", "sanitized public native choice")
	answer, _ := json.Marshal(interaction.Questions[0].Options[0].Value)
	check(handle.Respond(ctx, model.RespondRequest{ExecutionID: "stale-execution", InteractionID: interaction.ID, ActionID: "submit", Answers: map[string]json.RawMessage{"answer": answer}}) != nil, "stale execution answered Pi interaction")
	err = handle.Respond(ctx, model.RespondRequest{ExecutionID: "question", InteractionID: interaction.ID, ActionID: "submit", Answers: map[string]json.RawMessage{"answer": answer}})
	check(err == nil, "answer interaction")
	waitStatus(ctx, store, "question", "completed")
	check(send(handle, "editor", "edit") == nil, "editor prompt")
	state = waitStatus(ctx, store, "editor", "waiting-for-user")
	interaction = state.Executions[len(state.Executions)-1].Interactions[0]
	check(interaction.Questions[0].Form != nil, "editor default reaches public form")
	checked := model.ValidatePublicInteractionAnswers(interaction, nil)
	check(checked.Valid && checked.ValidatedFormValues["answer"] == "PREFILL_KEEP_43E9\nsecond line 中文 🚀", "editor initial value survives RPC and public preflight")
	check(handle.Respond(ctx, model.RespondRequest{ExecutionID: "editor", InteractionID: interaction.ID, ActionID: "submit", Answers: checked.Answers, ValidatedFormValues: checked.ValidatedFormValues}) == nil, "reply with unchanged editor default")
	waitStatus(ctx, store, "editor", "completed")
	check(send(handle, "editor-no-prefill", "edit-no-prefill") == nil, "editor without prefill prompt")
	state = waitStatus(ctx, store, "editor-no-prefill", "waiting-for-user")
	interaction = state.Executions[len(state.Executions)-1].Interactions[0]
	answer, _ = json.Marshal("PREFILL_KEEP_43E9\nsecond line 中文 🚀")
	checked = model.ValidatePublicInteractionAnswers(interaction, map[string]json.RawMessage{"answer": answer})
	check(checked.Valid, "editor without prefill accepts typed input")
	check(handle.Respond(ctx, model.RespondRequest{ExecutionID: "editor-no-prefill", InteractionID: interaction.ID, ActionID: "submit", Answers: checked.Answers, ValidatedFormValues: checked.ValidatedFormValues}) == nil, "reply to editor without prefill")
	waitStatus(ctx, store, "editor-no-prefill", "completed")
	check(send(handle, "todo-clear", "todos") == nil, "todo prompt")
	state = waitStatus(ctx, store, "todo-clear", "completed")
	var clears int
	for _, message := range state.Messages {
		if message.ExecutionID == "todo-clear" && message.ToolName == "todo" && message.Todos != nil && len(message.Todos) == 0 {
			clears++
		}
	}
	check(clears == 1, "explicit empty todo persisted")
	rendered, err := adapter.SessionState().ProjectRenderer(store.Read(), model.RendererScope{Kind: "overview"})
	check(err == nil, "overview")
	var overview pi.State
	check(json.Unmarshal(rendered, &overview) == nil, "overview decode")
	check(len(overview.Messages) > 0, "overview contents")
	check(writeArtifact("terminal-overview.json", rendered) == nil, "capture terminal overview")
	check(writeArtifact("terminal-state.json", store.Read()) == nil, "capture terminal state")
	check(send(handle, "cancel", "active") == nil, "cancel prompt")
	check(handle.Interrupt(ctx) == nil, "interrupt")
	waitStatus(ctx, store, "cancel", "interrupted")
	check(send(handle, "after-cancel", "normal") == nil, "resume after interrupt")
	state = waitStatus(ctx, store, "after-cancel", "completed")
	fork, err := adapter.Fork(ctx, plugin.ForkRequest{Source: model.ThreadRecord{SessionRecord: model.SessionRecord{Settings: settings, SessionState: store.Read()}}})
	check(err == nil, "fork snapshot")
	forkStore := &memoryStore{raw: fork.SessionState}
	forkRecord := model.SessionRecord{ID: "fork", HarnessID: "pi", Cwd: root, Settings: settings}
	forkHandle, err := adapter.Open(ctx, plugin.OpenContext{ThreadID: "fork", SessionState: forkStore, ReadThread: func() model.SessionRecord { return forkRecord }})
	check(err == nil, "open fork")
	defer forkHandle.Close()
	check(send(forkHandle, "fork-first", "normal") == nil, "send fork")
	forkState := waitStatus(ctx, forkStore, "fork-first", "completed")
	check(forkState.SessionFile != state.SessionFile && forkState.ForkSource == nil, "independent native cloned fork")
	check(forkHandle.Close() == nil, "close fork")
	check(send(handle, "recovery", "active") == nil, "running recovery source")
	snapshot := store.Read()
	check(handle.Close() == nil, "close active handle")
	recoveredStore := &memoryStore{raw: snapshot}
	open.SessionState = recoveredStore
	recovered, err := adapter.Open(ctx, open)
	check(err == nil, "reopen persisted active state")
	defer recovered.Close()
	waitStatus(ctx, recoveredStore, "recovery", "interrupted")
	check(send(recovered, "recovered-next", "normal") == nil, "new task after recovery")
	waitStatus(ctx, recoveredStore, "recovered-next", "completed")
	check(recovered.Close() == nil, "close recovery handle")
	check(recovered.Close() == nil, "idempotent close")
	fmt.Println("PASS Pi adapter replay: send/stream/settle, ack cancellation, steering rejection, native interaction response, empty todo persistence, cancel/resume, independent fork, crash recovery")
	bridgeStore := &memoryStore{}
	bridgeRecord := model.SessionRecord{ID: "bridge", HarnessID: "pi", Cwd: root, Settings: settings}
	var toolCalls atomic.Int64
	binding := plugin.ToolBinding{Name: "double", Description: "Double an integer", InputSchema: json.RawMessage(`{"type":"object","properties":{"n":{"type":"number"}},"required":["n"]}`), Execute: func(_ context.Context, call plugin.ToolCall) (json.RawMessage, error) {
		if call.CallID != "native-1" {
			return nil, errors.New("unexpected native tool identity")
		}
		var args struct {
			N int `json:"n"`
		}
		if json.Unmarshal(call.Arguments, &args) != nil || args.N != 7 {
			return nil, errors.New("unexpected host tool arguments")
		}
		toolCalls.Add(1)
		return json.RawMessage(`{"value":14}`), nil
	}}
	bridgeHandle, err := adapter.Open(ctx, plugin.OpenContext{ThreadID: "bridge", ReadThread: func() model.SessionRecord { return bridgeRecord }, SessionState: bridgeStore, Injection: &plugin.Injection{Instructions: []string{"injected instruction"}, Tools: &plugin.ToolInjection{Mode: "exclusive", Bindings: []plugin.ToolBinding{binding}}}})
	check(err == nil, "open injected adapter")
	defer bridgeHandle.Close()
	err = send(bridgeHandle, "bridge-execution", "bridge")
	check(err == nil, fmt.Sprint("send injected ", err))
	waitStatus(ctx, bridgeStore, "bridge-execution", "completed")
	check(toolCalls.Load() == 1, "exactly one injected tool call")
	check(bridgeHandle.Close() == nil, "close bridge")
	fmt.Println("PASS Pi FD3 bridge replay: exact registered tools, native call ID, Go host callback, structured result")
	_, err = adapter.Settings().Normalize(json.RawMessage(`{"unexpected":true}`))
	check(err != nil, "reject unknown Harness settings")
	_, err = adapter.Settings().ResolveThread(ctx, plugin.ResolveSettingsRequest{Merged: json.RawMessage(`{"provider":"provider","model":"missing","thinkingLevel":"high"}`), Cwd: root})
	check(err != nil, "reject unavailable exact model")
	presentation, err := adapter.Settings().Presentation(ctx, plugin.SettingsPresentationRequest{Settings: adapter.DefaultSettings(), ThreadSettings: settings, Cwd: root})
	check(err == nil, "settings presentation")
	var catalog struct {
		Models []struct {
			ID     string   `json:"id"`
			Levels []string `json:"thinkingLevels"`
		}
	}
	check(json.Unmarshal(presentation, &catalog) == nil && len(catalog.Models) == 2, "catalog model count")
	for _, entry := range catalog.Models {
		check(entry.Levels != nil, "model thinkingLevels array, never null")
	}
	check(writeArtifact("presentation.json", presentation) == nil, "capture presentation")
	schema, err := adapter.Settings().Describe(ctx, plugin.SettingsRequest{Settings: adapter.DefaultSettings(), Cwd: root})
	check(err == nil && json.Valid(schema), "settings description schema")
	fmt.Println("PASS Pi configuration replay: strict unknown fields, exact unavailable model rejection, Describe/Presentation arrays")
}

func verifyProcessOrdering(ctx context.Context) {
	root, err := os.MkdirTemp(fixtureRoot, "process-")
	check(err == nil, "temp tree dir")
	defer os.RemoveAll(root)
	graceful := fixtureOptions("graceful-close")
	graceful.Env["MOKUSEI_PI_VERIFICATION_CLOSE"] = filepath.Join(root, "native-close")
	closing, err := pi.StartSession(ctx, graceful)
	check(err == nil, "start native cleanup fixture")
	check(closing.Close() == nil, "close native cleanup fixture")
	cleaned, err := os.ReadFile(graceful.Env["MOKUSEI_PI_VERIFICATION_CLOSE"])
	check(err == nil && string(cleaned) == "disposed", "Close waits for native EOF disposal")
	stubbornOptions := fixtureOptions("stubborn-close")
	stubbornOptions.Env["MOKUSEI_PI_VERIFICATION_PID"] = filepath.Join(root, "stubborn.pid")
	stubborn, err := pi.StartSession(ctx, stubbornOptions)
	check(err == nil, "start uncooperative native process")
	pidData, err := os.ReadFile(stubbornOptions.Env["MOKUSEI_PI_VERIFICATION_PID"])
	check(err == nil, "read uncooperative native PID")
	pid, err := strconv.Atoi(string(pidData))
	check(err == nil && pid > 0, "uncooperative native PID is valid")
	before := time.Now()
	check(stubborn.Close() == nil, "close uncooperative native process")
	check(time.Since(before) < 4*time.Second, "uncooperative native close remains bounded")
	check(errors.Is(syscall.Kill(pid, 0), syscall.ESRCH), "uncooperative native child was reaped")
	fmt.Println("PASS Pi shutdown replay: native EOF disposal finishes before Close returns; uncooperative child is forcibly bounded")
	opts := fixtureOptions("tree")
	opts.Env["MOKUSEI_PI_VERIFICATION_PID"] = filepath.Join(root, "child.pid")
	session, err := pi.StartSession(ctx, opts)
	check(err == nil, "start process tree")
	defer session.Close()
	data, err := os.ReadFile(opts.Env["MOKUSEI_PI_VERIFICATION_PID"])
	check(err == nil, "read child pid")
	childPID, err := strconv.Atoi(strings.TrimSpace(string(data)))
	check(err == nil && childPID > 0, "valid descendant PID")
	check(session.Close() == nil, "close process tree")
	ps, err := exec.LookPath("ps")
	check(err == nil, "process inspection requires ps")
	until := time.Now().Add(time.Second * 2)
	for {
		stat, err := exec.CommandContext(ctx, ps, "-o", "stat=", "-p", strconv.Itoa(childPID)).Output()
		check(ctx.Err() == nil, "process inspection context: "+fmt.Sprint(ctx.Err()))
		if err != nil {
			var exit *exec.ExitError
			check(errors.As(err, &exit) && exit.ExitCode() == 1 && len(strings.TrimSpace(string(stat))) == 0, "inspect child process: "+fmt.Sprint(err))
			break
		}
		state := strings.TrimSpace(string(stat))
		if state == "" || strings.HasPrefix(state, "Z") {
			break
		}
		check(time.Now().Before(until), "descendant survived close: "+string(stat))
		time.Sleep(time.Millisecond * 10)
	}
	fmt.Println("PASS Pi process lifetime replay: detached descendant terminated on Close")
	unowned := startFixture(ctx, "unowned")
	defer unowned.Close()
	release := make(chan struct{})
	blocked := make(chan struct{})
	var releaseOnce sync.Once
	var blockedOnce sync.Once
	releaseCallbacks := func() { releaseOnce.Do(func() { close(release) }) }
	defer releaseCallbacks()
	unowned.Subscribe(func(event pi.Event) {
		if event.Type == "notification" {
			blockedOnce.Do(func() { close(blocked) })
			select {
			case <-release:
			case <-ctx.Done():
			}
		}
	})
	_, err = unowned.Commands(ctx)
	check(err == nil, "commands before unowned settlement")
	select {
	case <-blocked:
	case <-ctx.Done():
		panic(ctx.Err())
	}
	completion, err := unowned.Complete(ctx, pi.PromptInput{Message: "normal"}, pi.CompletionPolicy{})
	check(err == nil && completion.Text == "Hello world", "stale settlement never owns later prompt")
	releaseCallbacks()
	check(unowned.FlushEvents(ctx) == nil, "callback fence")
	check(unowned.Close() == nil, "close queued session")
	for i := 0; i < 5; i++ {
		session := startFixture(ctx, "exit-settled")
		defer session.Close()
		completion, err := session.Complete(ctx, pi.PromptInput{Message: "normal"}, pi.CompletionPolicy{})
		check(err == nil && completion.Text == "Hello world", fmt.Sprint("final settlement drained before exit: ", err))
		_ = session.Close()
	}
	fmt.Println("PASS Pi event ordering replay: unowned settlement rejected under blocked callback, final settlement survives immediate process exit")
}
