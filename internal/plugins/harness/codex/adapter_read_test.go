package codex

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/core/plugin"
)

type readSessionStore struct {
	mu    sync.Mutex
	state json.RawMessage
}

func (s *readSessionStore) Read() json.RawMessage {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append(json.RawMessage(nil), s.state...)
}

func (s *readSessionStore) Commit(_ context.Context, state json.RawMessage) error {
	if _, err := DecodeState(rawMap(state)); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.state = append(json.RawMessage(nil), state...)
	return nil
}

type readFixture struct {
	handle *Handle
	store  *readSessionStore
	root   string
	source json.RawMessage
}

func openReadFixture(t *testing.T, mode string, nativeHistory bool) *readFixture {
	t.Helper()
	root := t.TempDir()
	for _, name := range []string{"home", "native-home", "work", "tmp", "peers"} {
		if err := os.Mkdir(filepath.Join(root, name), 0700); err != nil {
			t.Fatal(err)
		}
	}
	binary, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	launcher := filepath.Join(root, "codex-peer")
	// Keep production executable discovery and process ownership. Only the
	// external native protocol is scripted, using this test binary as its peer.
	script := "#!/bin/sh\ncase \"$1\" in\n--version) printf 'codex-cli 999.0.0\\n'; exit 0;;\ndebug) printf '%s\\n' '{\"models\":[{\"slug\":\"read-fixture\"}]}'; exit 0;;\nesac\nexec \"$MOKUSEI_CODEX_READ_TEST_BINARY\" -test.run='^TestCodexReadPeer$'\n"
	if err := os.WriteFile(launcher, []byte(script), 0700); err != nil {
		t.Fatal(err)
	}
	adapter := New(plugin.HostContext{
		HarnessDataRoot:        filepath.Join(root, "harness"),
		TemporaryWorkspaceRoot: filepath.Join(root, "tmp"),
		Environment: func(context.Context) (map[string]string, error) {
			return map[string]string{
				"PATH": "/usr/bin:/bin", "HOME": filepath.Join(root, "home"),
				"CODEX_HOME": filepath.Join(root, "native-home"), "CODEX_SQLITE_HOME": filepath.Join(root, "native-home"),
				"MOKUSEI_CODEX_READ_TEST_BINARY": binary, "MOKUSEI_CODEX_READ_PEER": mode,
				"MOKUSEI_CODEX_READ_ROOT": root, "GORACE": "atexit_sleep_ms=0",
			}, nil
		},
	})
	t.Cleanup(func() {
		if err := adapter.Close(); err != nil {
			t.Errorf("close adapter: %v", err)
		}
	})
	state, err := StageExecutionChecked(EmptyState(1), "source-execution", Map{"parts": []any{Map{"kind": "text", "text": "source task"}}}, 2, nil)
	if err != nil {
		t.Fatal(err)
	}
	state = ReduceEvent(state, "source-execution", Map{"type": "text-final", "itemId": "source-answer", "text": "source final answer", "at": 3})
	state = ReduceEvent(state, "source-execution", Map{"type": "done", "outcome": "completed", "at": 4})
	if nativeHistory {
		state, err = BindPrimarySession(state, "source-native", 5)
		if err != nil {
			t.Fatal(err)
		}
	}
	store := &readSessionStore{state: raw(state)}
	record := model.SessionRecord{ID: "source", CreatedAt: 1, Cwd: filepath.Join(root, "work"), Settings: raw(Map{"executablePath": launcher, "model": "read-fixture", "serviceTier": "default"})}
	handle, err := adapter.Open(t.Context(), plugin.OpenContext{ThreadID: record.ID, ReadThread: func() model.SessionRecord { return record }, SessionState: store})
	if err != nil {
		t.Fatal(err)
	}
	return &readFixture{handle: handle.(*Handle), store: store, root: root, source: store.Read()}
}

func (f *readFixture) assertDrained(t *testing.T) {
	t.Helper()
	f.handle.mu.Lock()
	retained := len(f.handle.reads)
	f.handle.mu.Unlock()
	if retained != 0 {
		t.Errorf("Read returned with %d retained native session owners", retained)
	}
	if !bytes.Equal(f.source, f.store.Read()) {
		t.Error("Read changed the source session state")
	}
	for _, pattern := range []string{"tmp/*", "harness/application-tools-only/session-*", "peers/*.error"} {
		paths, err := filepath.Glob(filepath.Join(f.root, pattern))
		if err != nil || len(paths) != 0 {
			t.Errorf("Read retained temporary resources or peer errors (%s): %v, %v", pattern, paths, err)
		}
	}
	paths, err := filepath.Glob(filepath.Join(f.root, "peers", "*.json"))
	if err != nil || len(paths) == 0 {
		t.Fatalf("missing native process evidence: %v", err)
	}
	for _, path := range paths {
		data, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		pid := int(num(rawMap(data)["pid"]))
		if err := syscall.Kill(pid, 0); !errors.Is(err, syscall.ESRCH) {
			t.Errorf("Read returned before native process %d was reaped: %v", pid, err)
		}
	}
}

func (f *readFixture) requests(t *testing.T) []Map {
	t.Helper()
	paths, err := filepath.Glob(filepath.Join(f.root, "peers", "*.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	var frames []Map
	for _, path := range paths {
		data, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		for _, line := range bytes.Split(bytes.TrimSpace(data), []byte{'\n'}) {
			var frame Map
			if err := json.Unmarshal(line, &frame); err != nil {
				t.Fatalf("invalid captured native request: %v", err)
			}
			frames = append(frames, frame)
		}
	}
	return frames
}

func TestHandleReadReleasesNativeSessions(t *testing.T) {
	for _, test := range []struct {
		name, mode, answer, failure string
		nativeHistory               bool
		forks, starts               int
	}{
		{"native-fork", "fork-success", "fork answer", "", true, 1, 0},
		{"snapshot-fallback", "fallback-success", "snapshot answer", "", true, 1, 1},
		{"without-native-history", "fallback-success", "snapshot answer", "", false, 0, 1},
		{"fallback-turn-failure", "fallback-error", "", "fixture snapshot failed", true, 1, 1},
		{"fallback-launch-failure", "fallback-start-error", "", "fixture isolated launch failed", true, 1, 0},
	} {
		t.Run(test.name, func(t *testing.T) {
			f := openReadFixture(t, test.mode, test.nativeHistory)
			// Reuse the same Handle: returning an answer must not accumulate retired
			// owners until the outer Handle eventually closes.
			for attempt := 1; attempt <= 2; attempt++ {
				ctx, cancel := context.WithTimeout(t.Context(), 15*time.Second)
				answer, err := f.handle.Read(ctx, "What happened?")
				cancel()
				if test.failure == "" && err != nil || test.failure != "" && (err == nil || !strings.Contains(err.Error(), test.failure)) || answer != test.answer {
					t.Fatalf("Read = %q, %v; want %q, error containing %q", answer, err, test.answer, test.failure)
				}
				f.assertDrained(t)
				forks, starts := 0, 0
				for _, frame := range f.requests(t) {
					params := obj(frame["params"])
					switch frame["method"] {
					case "thread/fork":
						forks++
						if params["threadId"] != "source-native" || params["ephemeral"] != true {
							t.Errorf("Read did not fork the exact source ephemerally: %v", params)
						}
					case "thread/start":
						starts++
						if params["ephemeral"] != true || params["sandbox"] != "read-only" || params["approvalPolicy"] != "never" {
							t.Errorf("snapshot fallback lost its read-only boundary: %v", params)
						}
					}
				}
				if forks != test.forks*attempt || starts != test.starts*attempt {
					t.Fatalf("native requests after Read %d: fork=%d start=%d", attempt, forks, starts)
				}
			}
		})
	}
}

func TestHandleReadCancellationAndConcurrentClose(t *testing.T) {
	for _, mode := range []string{"fork-wait", "fallback-wait"} {
		for _, closeHandle := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/close=%t", mode, closeHandle), func(t *testing.T) {
				f := openReadFixture(t, mode, true)
				ctx, cancel := context.WithTimeout(t.Context(), 15*time.Second)
				defer cancel()
				finished := make(chan error, 1)
				go func() {
					_, err := f.handle.Read(ctx, "What happened?")
					finished <- err
				}()
				// Observe the real native turn after its RPC response, not an elapsed
				// delay. The peer holds completion until cancellation/Close retires it.
				for {
					active := false
					f.handle.mu.Lock()
					for native := range f.handle.reads {
						native.mu.Lock()
						active = active || native.turnID != "" && !native.terminal
						native.mu.Unlock()
					}
					f.handle.mu.Unlock()
					if active {
						break
					}
					select {
					case err := <-finished:
						t.Fatalf("Read ended before native barrier: %v", err)
					case <-ctx.Done():
						t.Fatal("Read did not reach the native turn barrier")
					case <-time.After(time.Millisecond):
					}
				}
				if closeHandle {
					start := make(chan struct{})
					closed := make(chan error, 2)
					for range 2 {
						go func() { <-start; closed <- f.handle.Close() }()
					}
					close(start)
					for range 2 {
						select {
						case err := <-closed:
							if err != nil {
								t.Fatalf("concurrent Close: %v", err)
							}
							f.assertDrained(t)
						case <-ctx.Done():
							t.Fatal("Close did not join the in-flight Read")
						}
					}
					if err := f.handle.Close(); err != nil {
						t.Fatalf("repeated Close: %v", err)
					}
					if _, err := f.handle.Read(ctx, "after close"); err == nil {
						t.Fatal("closed Handle accepted Read")
					}
				} else {
					cancel()
				}
				select {
				case err := <-finished:
					if err == nil || !closeHandle && !errors.Is(err, context.Canceled) {
						t.Fatalf("cancelled Read returned %v", err)
					}
				case <-time.After(5 * time.Second):
					t.Fatal("cancelled Read did not release native ownership")
				}
				f.assertDrained(t)
			})
		}
	}
}

// This subprocess enters only through the launcher above; os.Exit keeps the Go
// test runner's PASS output off the production JSONL transport.
func TestCodexReadPeer(t *testing.T) {
	mode := os.Getenv("MOKUSEI_CODEX_READ_PEER")
	if mode == "" {
		return
	}
	if err := runReadPeer(mode); err != nil {
		_ = os.WriteFile(filepath.Join(os.Getenv("MOKUSEI_CODEX_READ_ROOT"), "peers", fmt.Sprintf("%d.error", os.Getpid())), []byte(err.Error()), 0600)
		os.Exit(1)
	}
	os.Exit(0)
}

func runReadPeer(mode string) error {
	root := os.Getenv("MOKUSEI_CODEX_READ_ROOT")
	cwd, err := os.Getwd()
	if err != nil {
		return err
	}
	prefix := filepath.Join(root, "peers", fmt.Sprint(os.Getpid()))
	if err := os.WriteFile(prefix+".json", raw(Map{"pid": os.Getpid(), "cwd": cwd, "home": os.Getenv("CODEX_HOME")}), 0600); err != nil {
		return err
	}
	requests, err := os.Create(prefix + ".jsonl")
	if err != nil {
		return err
	}
	defer requests.Close()
	log := json.NewEncoder(requests)
	wire := json.NewEncoder(os.Stdout)
	scan := bufio.NewScanner(os.Stdin)
	session := "read-native"
	for scan.Scan() {
		frame := rawMap(scan.Bytes())
		if err := log.Encode(frame); err != nil {
			return err
		}
		if frame["id"] == nil {
			continue
		}
		params := obj(frame["params"])
		result, failure := Map{}, ""
		switch frame["method"] {
		case "initialize":
			if mode == "fallback-start-error" && os.Getenv("CODEX_HOME") != filepath.Join(root, "native-home") {
				failure = "fixture isolated launch failed"
			}
		case "config/read":
			result["config"] = Map{}
		case "getAuthStatus":
			result["requiresOpenaiAuth"] = false
		case "skills/list":
			result["data"] = []any{}
		case "thread/fork", "thread/start":
			if frame["method"] == "thread/fork" && !strings.HasPrefix(mode, "fork-") {
				failure = "fixture source fork unavailable"
				break
			}
			result = Map{"thread": Map{"id": session}, "model": "read-fixture", "serviceTier": nil,
				"approvalPolicy": params["approvalPolicy"], "approvalsReviewer": params["approvalsReviewer"],
				"sandbox": Map{"type": map[string]string{"read-only": "readOnly", "workspace-write": "workspaceWrite"}[str(params["sandbox"])]}}
		case "turn/start":
			if mode == "fallback-error" {
				failure = "fixture snapshot failed"
				break
			}
			if err := wire.Encode(Map{"id": frame["id"], "result": Map{"turn": Map{"id": "read-turn"}}}); err != nil {
				return err
			}
			if strings.HasSuffix(mode, "-wait") {
				continue
			}
			answer := "snapshot answer"
			if strings.HasPrefix(mode, "fork-") {
				answer = "fork answer"
			}
			item := Map{"type": "agentMessage", "id": "read-answer", "text": answer, "phase": "final_answer"}
			if err := wire.Encode(Map{"method": "item/completed", "params": Map{"threadId": session, "turnId": "read-turn", "item": item}}); err != nil {
				return err
			}
			if err := wire.Encode(Map{"method": "turn/completed", "params": Map{"threadId": session, "turn": Map{"id": "read-turn", "status": "completed", "items": []any{item}}}}); err != nil {
				return err
			}
			continue
		case "turn/interrupt":
		default:
			return fmt.Errorf("unexpected native request: %s", frame["method"])
		}
		reply := Map{"id": frame["id"], "result": result}
		if failure != "" {
			reply = Map{"id": frame["id"], "error": Map{"code": -32603, "message": failure}}
		}
		if err := wire.Encode(reply); err != nil {
			return err
		}
	}
	return scan.Err()
}
