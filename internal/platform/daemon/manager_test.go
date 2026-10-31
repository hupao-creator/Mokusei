package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/platform/profile"
	"github.com/hupao-creator/Mokusei/internal/platform/transport"
)

type launchTestHost struct{}

func (launchTestHost) Initialize(context.Context) (transport.Host, error) {
	return launchTestHost{}, nil
}
func (launchTestHost) Close(context.Context) error { return nil }
func (launchTestHost) HasChannel(string) bool      { return false }
func (launchTestHost) Invoke(context.Context, string, []json.RawMessage) (any, error) {
	return nil, nil
}
func (launchTestHost) SubscribeMutations(func(json.RawMessage)) func() { return func() {} }
func (launchTestHost) ReadThreadContent(context.Context, string, transport.ContentScope, *int64) (*transport.ContentSnapshot, error) {
	return nil, nil
}

func TestMain(m *testing.M) {
	if os.Getenv("MOKUSEI_DAEMON_TEST_CHILD") == "1" {
		if err := serveLaunchTestChild(); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		os.Exit(0)
	}
	os.Exit(m.Run())
}

func serveLaunchTestChild() error {
	if len(os.Args) != 4 || os.Args[1] != "serve" || os.Args[2] != "--data-dir" {
		return errors.New("unexpected daemon test child arguments")
	}
	if err := AwaitLaunch(); err != nil {
		return err
	}
	gate := os.Getenv("MOKUSEI_DAEMON_TEST_GATE")
	if err := os.WriteFile(gate+".started", []byte(strconv.Itoa(os.Getpid())), 0600); err != nil {
		return err
	}
	deadline := time.Now().Add(15 * time.Second)
	for {
		if _, err := os.Stat(gate + ".release"); err == nil {
			break
		} else if !errors.Is(err, os.ErrNotExist) {
			return err
		}
		if time.Now().After(deadline) {
			return errors.New("daemon test launch gate timed out")
		}
		time.Sleep(5 * time.Millisecond)
	}
	p, err := profile.Resolve(profile.Options{DataDir: os.Args[3], HomeDir: os.Getenv("MOKUSEI_DAEMON_TEST_HOME_DIR")})
	if err != nil {
		return err
	}
	// A lost parent cannot leave this test-only service running indefinitely.
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	return Serve(ctx, ServeOptions{Profile: p, Bootstrap: launchTestHost{}, Output: os.Stdout,
		Log: func(err error) { fmt.Fprintln(os.Stderr, err) }})
}

type launchTestResult struct {
	connection *profile.Connection
	err        error
}

type launchTestAttempt struct {
	gate     string
	pid      int
	done     chan launchTestResult
	finished bool
	result   launchTestResult
}

type launchTestWindow struct {
	t        *testing.T
	root     string
	p        profile.Profile
	home     string
	guard    net.Listener
	attempts []*launchTestAttempt
	invalid  string
}

func newLaunchTestWindow(t *testing.T) *launchTestWindow {
	t.Helper()
	root, err := os.MkdirTemp("", "mokusei-daemon-launch-test-")
	if err != nil {
		t.Fatal(err)
	}
	home := filepath.Join(root, "home")
	w := &launchTestWindow{t: t, root: root, home: home}
	// The fixture removes its directory only after all owned launch attempts and
	// children settle. A failed cleanup preserves the directory as evidence.
	t.Cleanup(w.cleanup)
	p, err := profile.Resolve(profile.Options{DataDir: filepath.Join(root, "profile"), HomeDir: home})
	if err != nil {
		t.Fatal(err)
	}
	if err = profile.Prepare(p); err != nil {
		t.Fatal(err)
	}
	p, err = profile.Refresh(p)
	if err != nil {
		t.Fatal(err)
	}
	w.p = p
	guard, err := net.Listen("tcp4", fmt.Sprintf("127.0.0.1:%d", profile.GuardPort(p)))
	if err != nil {
		t.Fatal(err)
	}
	w.guard = guard
	return w
}

func (w *launchTestWindow) begin(name string) *launchTestAttempt {
	w.t.Helper()
	executable, err := os.Executable()
	if err != nil {
		w.t.Fatal(err)
	}
	a := &launchTestAttempt{gate: filepath.Join(w.p.DataDir, name), done: make(chan launchTestResult, 1)}
	w.attempts = append(w.attempts, a)
	environment := append(os.Environ(), "MOKUSEI_DAEMON_TEST_CHILD=1", "MOKUSEI_DAEMON_TEST_GATE="+a.gate,
		"MOKUSEI_DAEMON_TEST_HOME_DIR="+w.home, "GORACE=halt_on_error=1 atexit_sleep_ms=0")
	go func() {
		connection, err := Ensure(context.Background(), w.p, LaunchOptions{Executable: executable, Environment: environment})
		a.done <- launchTestResult{connection, err}
	}()
	w.wait("child reached its persisted launch gate", func() bool {
		data, err := os.ReadFile(a.gate + ".started")
		if err != nil {
			return false
		}
		a.pid, err = strconv.Atoi(string(data))
		return err == nil && a.pid > 0
	})
	var launch struct {
		PID     int    `json:"pid"`
		DataDir string `json:"dataDir"`
	}
	path := filepath.Join(filepath.Dir(w.p.DiscoveryPath), fmt.Sprintf("launch-%d.json", a.pid))
	if err := profile.ReadPrivateJSON(path, &launch); err != nil || launch.PID != a.pid || launch.DataDir != w.p.DataDir {
		w.t.Fatalf("child has no matching persisted handoff: pid=%d metadata=%+v error=%v", a.pid, launch, err)
	}
	w.t.Logf("gated child %s pid=%d profile=%s", name, a.pid, w.p.DataDir)
	return a
}

func (w *launchTestWindow) wait(reason string, ready func() bool) {
	w.t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for !ready() {
		if time.Now().After(deadline) {
			w.t.Fatal("timed out waiting for " + reason)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func (w *launchTestWindow) release(a *launchTestAttempt) {
	w.t.Helper()
	if err := os.WriteFile(a.gate+".release", nil, 0600); err != nil {
		w.t.Fatal(err)
	}
}

func (w *launchTestWindow) result(a *launchTestAttempt) launchTestResult {
	w.t.Helper()
	if !a.finished {
		select {
		case a.result = <-a.done:
			a.finished = true
		case <-time.After(5 * time.Second):
			w.t.Fatal("Ensure did not settle after the controlled launch outcome")
		}
	}
	return a.result
}

func (w *launchTestWindow) cleanup() {
	// One deadline covers the child's 15-second gate and 20-second service
	// lifetimes, even if begin failed before it could read the child's PID.
	deadline := time.Now().Add(40 * time.Second)
	if w.t.Failed() && w.p.DataDir != "" {
		if data, err := os.ReadFile(filepath.Join(filepath.Dir(w.p.DiscoveryPath), "process.log")); err == nil {
			w.t.Logf("owned test process log before cleanup:\n%s", data)
		}
	}
	if w.guard != nil {
		_ = w.guard.Close()
	}
	if w.invalid != "" {
		_ = os.Remove(w.invalid)
	}
	for _, a := range w.attempts {
		if err := os.WriteFile(a.gate+".release", nil, 0600); err != nil {
			w.t.Error(err)
		}
	}
	for _, a := range w.attempts {
		if !a.finished {
			timer := time.NewTimer(time.Until(deadline))
			select {
			case a.result = <-a.done:
				a.finished = true
			case <-timer.C:
				w.t.Error("cleanup could not join owned Ensure")
			}
			timer.Stop()
		}
	}
	ctx, cancel := context.WithDeadline(context.Background(), deadline)
	defer cancel()
	stopOK := true
	if len(w.attempts) > 0 {
		if err := Stop(ctx, w.p); err != nil {
			stopOK = false
			w.t.Error("cleanup could not stop owned daemon: ", err)
		}
	}
	for {
		allExited := true
		for _, a := range w.attempts {
			if !a.finished {
				select {
				case a.result = <-a.done:
					a.finished = true
				default:
				}
			}
			if a.pid == 0 {
				if data, err := os.ReadFile(a.gate + ".started"); err == nil {
					a.pid, _ = strconv.Atoi(string(data))
				}
				if a.pid == 0 && a.finished && a.result.connection != nil {
					a.pid = a.result.connection.PID
				}
			}
			if !a.finished || a.pid <= 0 || profile.IsProcessAlive(a.pid) {
				allExited = false
			}
		}
		if allExited && stopOK {
			if err := os.RemoveAll(w.root); err != nil {
				w.t.Error(err)
			}
			return
		}
		if !time.Now().Before(deadline) {
			w.t.Errorf("owned launches did not settle before cleanup deadline; preserved %s", w.root)
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func TestEnsureWaitsForPendingCompetitorBeforePublication(t *testing.T) {
	w := newLaunchTestWindow(t)
	winner := w.begin("winner")
	loser := w.begin("loser")
	w.release(loser)
	w.wait("loser child to actually exit", func() bool { return !profile.IsProcessAlive(loser.pid) })
	if !profile.IsProcessAlive(winner.pid) {
		t.Fatal("winner left its launch gate")
	}
	for _, path := range []string{w.p.LockPath, w.p.DiscoveryPath} {
		if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("prepublication barrier already has metadata at %s: %v", path, err)
		}
	}
	var launch struct {
		PID     int    `json:"pid"`
		DataDir string `json:"dataDir"`
	}
	if err := profile.ReadPrivateJSON(filepath.Join(filepath.Dir(w.p.DiscoveryPath), fmt.Sprintf("launch-%d.json", winner.pid)), &launch); err != nil || launch.PID != winner.pid || launch.DataDir != w.p.DataDir {
		t.Fatalf("live winner lost its pending launch: %+v, %v", launch, err)
	}
	// Child exit and the live, unpublished competitor are observed before this
	// bounded absence check; no sleep guesses when either child reaches the race.
	select {
	case loser.result = <-loser.done:
		loser.finished = true
		t.Fatalf("Ensure returned while another owned launch was pending: %v", loser.result.err)
	case <-time.After(200 * time.Millisecond):
	}
	if err := w.guard.Close(); err != nil {
		t.Fatal(err)
	}
	w.release(winner)
	first, second := w.result(winner), w.result(loser)
	if first.err != nil || second.err != nil || first.connection == nil || second.connection == nil {
		t.Fatalf("launches did not converge after publication: winner=%v loser=%v", first.err, second.err)
	}
	if first.connection.PID != winner.pid || second.connection.PID != winner.pid || first.connection.Epoch != second.connection.Epoch {
		t.Fatal("pending launch was treated as success without the same published PID and epoch")
	}
	t.Logf("both Ensure calls observed winner pid=%d epoch=%s", winner.pid, first.connection.Epoch)
}

func TestEnsureRejectsExitedChildWithoutValidPendingLaunch(t *testing.T) {
	for _, invalid := range []bool{false, true} {
		name := "external-guard-without-pending"
		if invalid {
			name = "invalid-pending-metadata"
		}
		t.Run(name, func(t *testing.T) {
			w := newLaunchTestWindow(t)
			child := w.begin("only-child")
			if invalid {
				w.invalid = filepath.Join(filepath.Dir(w.p.DiscoveryPath), "launch-invalid.json")
				if err := os.WriteFile(w.invalid, []byte("{}"), 0600); err != nil {
					t.Fatal(err)
				}
			}
			w.release(child)
			result := w.result(child)
			if result.connection != nil || result.err == nil {
				t.Fatal("external occupied guard or invalid metadata became a successful launch")
			}
			if invalid {
				if !strings.Contains(result.err.Error(), "invalid runtime launch metadata") {
					t.Fatalf("pending metadata error was swallowed: %v", result.err)
				}
			} else {
				var public *model.Error
				if !errors.As(result.err, &public) || public.Code != "LAUNCH_FAILED" {
					t.Fatalf("missing pending launch changed the original failure: %v", result.err)
				}
			}
		})
	}
}

func TestEnsureRejectsInvalidOwnerWhileCompetitorIsPending(t *testing.T) {
	w := newLaunchTestWindow(t)
	winner := w.begin("winner")
	loser := w.begin("loser")
	w.invalid = w.p.LockPath
	if err := os.WriteFile(w.invalid, []byte("{"), 0600); err != nil {
		t.Fatal(err)
	}
	w.release(loser)
	result := w.result(loser)
	var malformed *json.SyntaxError
	if result.connection != nil || !errors.As(result.err, &malformed) {
		t.Fatalf("live pending launch hid malformed owner metadata: %v", result.err)
	}
	if !profile.IsProcessAlive(winner.pid) {
		t.Fatal("metadata rejection did not occur while the competing child was pending")
	}
}
