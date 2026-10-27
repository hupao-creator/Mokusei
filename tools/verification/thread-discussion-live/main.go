// Command thread-discussion-live opts into real-account inference with a
// disposable synthetic source. It never changes saved account/model settings.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	oc "github.com/hupao-creator/Mokusei/internal/plugins/harness/opencode"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/pi"
	"github.com/hupao-creator/Mokusei/internal/services/threadvoice"
)

type store struct {
	mu  sync.Mutex
	raw json.RawMessage
}

func (s *store) Read() json.RawMessage {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append(json.RawMessage{}, s.raw...)
}
func (s *store) Commit(_ context.Context, raw json.RawMessage) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.raw = append(json.RawMessage{}, raw...)
	return nil
}
func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
func run() (err error) {
	name := flag.String("harness", "", "pi or opencode; opts into real account requests")
	selection := flag.String("settings", "", "exact native Thread settings JSON (no credentials)")
	timeout := flag.Duration("timeout", 3*time.Minute, "whole probe timeout")
	flag.Parse()
	if (*name != "pi" && *name != "opencode") || !json.Valid([]byte(*selection)) {
		return errors.New("supply -harness pi|opencode and -settings with exact model/thinking JSON")
	}
	cli, err := exec.LookPath(*name)
	if err != nil {
		return err
	}
	root, err := os.MkdirTemp("", "mokusei-discussion-live-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(root)
	host := plugin.HostContext{HarnessDataRoot: filepath.Join(root, "harness"), TemporaryWorkspaceRoot: filepath.Join(root, "temporary"), ResolveExecutable: func(context.Context, string, string, string) (string, error) { return cli, nil }}
	var h plugin.Harness
	if *name == "pi" {
		h = pi.New(host)
	} else {
		native := oc.New(host)
		defer native.Close()
		h = native
	}
	ctx, cancel := context.WithTimeout(context.Background(), *timeout)
	defer cancel()
	settings := json.RawMessage(*selection)
	state := &store{}
	record := model.SessionRecord{ID: "voice-live-source", HarnessID: *name, Cwd: root, Settings: settings}
	handle, err := h.Open(ctx, plugin.OpenContext{ThreadID: record.ID, SessionState: state, ReadThread: func() model.SessionRecord { return record }, RequireExplicitSettings: true})
	if err != nil {
		return fmt.Errorf("source open: %w", err)
	}
	defer func() {
		err = errors.Join(err, handle.Close())
		if *name == "opencode" {
			err = errors.Join(err, cleanupOpenCode(cli, root, state.Read()))
		}
	}()
	err = handle.Send(ctx, plugin.SendRequest{ExecutionID: "seed", Input: model.AgentInput{Parts: []model.AgentInputPart{{Kind: "text", Text: "This is synthetic discussion verification data. A fictional gauge reads 17 units. This is public test data. Do not call tools or inspect files. Reply only ACK."}}}})
	if err != nil {
		return fmt.Errorf("source admission: %w", err)
	}
	for {
		observed, e := h.SessionState().Project(state.Read())
		if e != nil {
			return e
		}
		settled := false
		if run := observed.LatestExecution; run != nil {
			if run.ExecutionID == "seed" && run.Terminal() {
				if run.Status != "completed" {
					b, _ := json.Marshal(run)
					return fmt.Errorf("source account/native execution: %s", b)
				}
				settled = true
			}
		}
		if settled {
			break
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(50 * time.Millisecond):
		}
	}
	fmt.Println("PASS real-account source completed:", *name)
	before := state.Read()
	record.SessionState = before
	var inspect *oc.Runtime
	var nativeSnapshot []byte
	if *name == "opencode" {
		native, e := oc.DecodeState(before)
		if e != nil {
			return e
		}
		inspect, e = oc.NewRuntime(ctx, oc.Options{CWD: root, ExecutablePath: cli, IsolateConfig: true})
		if e != nil {
			return e
		}
		defer inspect.Close()
		if e = inspect.ConfigureSession(ctx, native.NativeSessionID, oc.BridgeConfiguration{}); e != nil {
			return e
		}
		value, e := inspect.Snapshot(ctx, native.NativeSessionID)
		if e != nil {
			return e
		}
		nativeSnapshot, _ = json.Marshal(value)
	}
	var sourceFile string
	var nativeBefore []byte
	if *name == "pi" {
		var s pi.State
		if err = json.Unmarshal(before, &s); err != nil {
			return err
		}
		sourceFile = s.SessionFile
		nativeBefore, err = os.ReadFile(sourceFile)
		if err != nil {
			return err
		}
	}
	tools, closeTools, err := threadvoice.ProjectReadTools(root)
	if err != nil {
		return err
	}
	defer closeTools()
	if err = os.WriteFile(filepath.Join(root, "reference.txt"), []byte("The fictional project gauge reads 29 units."), 0600); err != nil {
		return err
	}
	discussion, err := h.(plugin.DiscussionPreparer).PrepareDiscussion(ctx, plugin.DiscussionRequest{Source: model.ThreadRecord{SessionRecord: record}, Instructions: threadvoice.DiscussionInstructions, Tools: tools})
	if err != nil {
		return fmt.Errorf("discussion preparation: %w", err)
	}
	defer func() { err = errors.Join(err, discussion.Close()) }()
	fmt.Println("PASS private discussion prepared:", *name)
	for i, q := range []string{"What reading did the fictional gauge in the source conversation show? Reply only the number.", "Read reference.txt using read_project_file. Reply with the source gauge reading you just gave AND the project gauge reading, separated by a space."} {
		answer, e := discussion.Ask(ctx, q)
		if e != nil {
			return fmt.Errorf("discussion account/native request %d: %w", i+1, e)
		}
		if !strings.Contains(answer, "17") || i == 1 && !strings.Contains(answer, "29") {
			return fmt.Errorf("discussion %d lost synthetic history or project read: %q", i+1, answer)
		}
		fmt.Printf("PASS real-account discussion %d: native history%s\n", i+1, map[bool]string{true: " + continuous private history + Core project read"}[i == 1])
	}
	if err = discussion.Close(); err != nil {
		return err
	}
	if string(before) != string(state.Read()) {
		return errors.New("discussion changed source Thread state")
	}
	if inspect != nil {
		native, e := oc.DecodeState(before)
		if e != nil {
			return e
		}
		value, e := inspect.Snapshot(ctx, native.NativeSessionID)
		if e != nil {
			return e
		}
		after, _ := json.Marshal(value)
		if string(after) != string(nativeSnapshot) {
			return errors.New("discussion changed OpenCode native source history")
		}
	}
	if sourceFile != "" {
		after, e := os.ReadFile(sourceFile)
		if e != nil {
			return e
		}
		if string(after) != string(nativeBefore) {
			return errors.New("discussion changed native source JSONL")
		}
	}
	fmt.Println("PASS source unchanged and private discussion closed:", *name)
	return nil
}
func cleanupOpenCode(cli, root string, raw json.RawMessage) error {
	state, err := oc.DecodeState(raw)
	if err != nil || state.NativeSessionID == "" {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	runtime, err := oc.NewRuntime(ctx, oc.Options{CWD: root, ExecutablePath: cli, IsolateConfig: true})
	if err != nil {
		return err
	}
	defer runtime.Close()
	if err = runtime.ConfigureSession(ctx, state.NativeSessionID, oc.BridgeConfiguration{}); err != nil {
		return err
	}
	if err = runtime.Request(ctx, "POST", "/api/session/"+state.NativeSessionID+"/interrupt?resume=false", nil, nil); err != nil {
		return err
	}
	return runtime.Request(ctx, "DELETE", "/api/session/"+state.NativeSessionID, nil, nil)
}
