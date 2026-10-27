package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"debug/buildinfo"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/platform/daemon"
	"github.com/hupao-creator/Mokusei/internal/platform/profile"
	"github.com/hupao-creator/Mokusei/internal/platform/transport"
)

type stabilityOptions struct {
	Runtime   string
	Duration  time.Duration
	MinCycles int
}
type stabilityReport struct {
	RuntimeSHA256    string           `json:"runtimeSHA256"`
	RuntimeRace      bool             `json:"runtimeRace"`
	GCLiveHeapMiB    []int            `json:"gcLiveHeapMiB"`
	GCSeconds        []float64        `json:"gcSeconds"`
	NativeVersion    string           `json:"nativeVersion"`
	CrashWindows     []string         `json:"crashWindows"`
	Samples          []resourceSample `json:"samples"`
	LoadedSamples    []resourceSample `json:"loadedSamples"`
	SoakSeconds      float64          `json:"soakSeconds"`
	Cycles           int              `json:"cycles"`
	SoakPID          int              `json:"soakPID"`
	SoakEpoch        string           `json:"soakEpoch"`
	LongRunQualified bool             `json:"longRunQualified"`
	CleanupPassed    bool             `json:"cleanupPassed"`
	Thresholds       object           `json:"thresholds"`
}

func runStability(root string, p profile.Profile, env map[string]string, mock *provider, opts stabilityOptions) (err error) {
	if opts.Duration < 0 || opts.MinCycles < 1 || !filepath.IsAbs(opts.Runtime) {
		return errors.New("stability requires absolute runtime path, nonnegative duration and positive cycles")
	}
	report := &stabilityReport{Thresholds: object{"warmupCycles": 5, "baselineCycles": "6-10", "finalWindow": 5, "rssGrowthKiB": 65536, "rssGrowthFraction": 0.5, "fdGrowth": 8, "settledDescendants": 0, "minimumDurationSeconds": 1800, "minimumCycles": 100}}
	mock.stability = report
	defer func() {
		if err != nil {
			report.LongRunQualified = false
		} else {
			fmt.Printf("PASS final stability audit: cleanup and heap verified; longRunQualified=%v\n", report.LongRunQualified)
		}
	}()
	ctx, cancel := context.WithTimeout(context.Background(), opts.Duration+10*time.Minute)
	defer cancel()
	environment := []string{"MOKUSEI_HEADLESS=1", "GODEBUG=gctrace=1"}
	for k, v := range env {
		environment = append(environment, k+"="+v)
	}
	launch := daemon.LaunchOptions{Executable: opts.Runtime, Directory: root, Environment: environment}
	binary, e := os.ReadFile(opts.Runtime)
	if e != nil {
		return e
	}
	report.RuntimeSHA256 = fmt.Sprintf("%x", sha256.Sum256(binary))
	build, e := buildinfo.ReadFile(opts.Runtime)
	if e != nil {
		return e
	}
	for _, setting := range build.Settings {
		if setting.Key == "-race" && setting.Value == "true" {
			report.RuntimeRace = true
		}
	}
	version := exec.CommandContext(ctx, filepath.Join(root, "bin/codex"), "--version")
	version.Env = environment
	versionText, e := version.Output()
	if e != nil {
		return e
	}
	report.NativeVersion = strings.TrimSpace(string(versionText))
	var connection *profile.Connection
	var owned []processSample
	nativeConsumed := 0
	collectNative := func() ([]processSample, error) {
		rows, e := registeredNative(root)
		if e != nil {
			return nil, e
		}
		if nativeConsumed > len(rows) {
			return nil, errors.New("native process registry was truncated")
		}
		return rows[nativeConsumed:], nil
	}
	defer func() {
		cleanup, stop := context.WithTimeout(context.Background(), 30*time.Second)
		defer stop()
		if connection != nil {
			tree, e := processTree(cleanup, connection.PID)
			err = errors.Join(err, e)
			owned = append(owned, tree...)
		}
		registered, regErr := collectNative()
		err = errors.Join(err, regErr)
		owned = append(owned, registered...)
		e := daemon.Stop(cleanup, p)
		e = errors.Join(e, waitProcessesGone(cleanup, owned))
		report.CleanupPassed = e == nil
		if e != nil {
			cleanupProcesses(owned)
		}
		err = errors.Join(err, e)
		log, readErr := os.ReadFile(filepath.Join(p.DataDir, "runtime/process.log"))
		err = errors.Join(err, readErr)
		if len(log) > 0 {
			fmt.Print(string(log))
		}
		if bytes.Contains(log, []byte("WARNING: DATA RACE")) || bytes.Contains(log, []byte("panic:")) {
			err = errors.Join(err, errors.New("daemon race/panic detected"))
		}
		if report.Cycles >= 15 {
			// Each restart resets GC numbering. Missing/wrong owner evidence fails.
			ownerLog, ownerErr := finalOwnerGCLog(log, report.SoakPID, report.SoakEpoch)
			err = errors.Join(err, ownerErr)
			report.GCLiveHeapMiB, report.GCSeconds = parseGCTrace(ownerLog)
			err = errors.Join(err, verifyGCHeap(report.GCLiveHeapMiB))
			if len(report.GCSeconds) == 0 || report.GCSeconds[len(report.GCSeconds)-1] < report.SoakSeconds*0.9 {
				err = errors.Join(err, errors.New("GC evidence does not cover the late soak window"))
			}
		}
	}()
	connection, err = daemon.Ensure(ctx, p, launch)
	if err != nil {
		return err
	}
	if connection == nil {
		return errors.New("daemon start returned no connection")
	}
	client := &http.Client{Timeout: 20 * time.Second, Transport: &http.Transport{Proxy: nil}}
	defer client.CloseIdleConnections()
	call := func(channel string, args []any, target any) error {
		return invoke(ctx, client, *connection, channel, args, target)
	}
	state, err := startChain(ctx, call, mock)
	if err != nil {
		return err
	}
	// Persist one ordinary mutation receipt before all crash windows.
	commandID, err := transport.CreateCommandID()
	if err != nil {
		return err
	}
	args := []any{ordinary(state)[0].ID, false}
	var receipt json.RawMessage
	if err = invokeWithID(ctx, client, *connection, commandID, "thread:set-archived", args, &receipt); err != nil {
		return err
	}
	if err = call("state:load", []any{}, &state); err != nil {
		return err
	}
	restart := func() error {
		old := *connection
		tree, e := processTree(ctx, old.PID)
		if e != nil {
			return e
		}
		owned = tree
		if e = syscall.Kill(old.PID, syscall.SIGKILL); e != nil {
			return e
		}
		registered, e := collectNative()
		if e != nil {
			return e
		}
		owned = append(owned, registered...)
		if e = waitProcessesGone(ctx, owned); e != nil {
			return e
		}
		owned = nil
		nativeConsumed += len(registered)
		connection, e = daemon.Ensure(ctx, p, launch)
		if e != nil {
			return e
		}
		if connection == nil || connection.PID == old.PID || connection.Epoch == old.Epoch || connection.Token == old.Token {
			return errors.New("crash restart reused owner identity")
		}
		if e = invoke(ctx, client, old, "state:load", []any{}, nil); e == nil {
			return errors.New("old connection remained authorized")
		}
		var replay json.RawMessage
		if e = invokeWithID(ctx, client, *connection, commandID, "thread:set-archived", args, &replay); e != nil {
			return e
		}
		if !bytes.Equal(receipt, replay) {
			return errors.New("crash changed command receipt")
		}
		e = invokeWithID(ctx, client, *connection, commandID, "thread:set-archived", []any{args[0], true}, nil)
		if e == nil || !strings.Contains(e.Error(), "COMMAND_ID_REUSED") {
			return fmt.Errorf("crash receipt body fence failed: %v", e)
		}
		return nil
	}
	for i := 0; i < 3; i++ {
		if err = restart(); err != nil {
			return fmt.Errorf("settled crash %d: %w", i, err)
		}
		var restored model.AppState
		if err = call("state:load", []any{}, &restored); err != nil {
			return err
		}
		if err = verifyRestored(state, restored); err != nil {
			return err
		}
		report.CrashWindows = append(report.CrashWindows, "settled")
		fmt.Printf("PASS process crash settled[%d]: fresh owner, durable state and receipts\n", i)
	}
	for i := 0; i < 3; i++ {
		source := ordinary(state)[0]
		marker := fmt.Sprintf("SYSTEM_CRASH_%d_END", i)
		mock.mu.Lock()
		if mock.crashInputs == nil {
			mock.crashInputs = map[string]int{}
		}
		mock.crashInputs[marker] = 0
		mock.mu.Unlock()
		gate, execution, e := heldFollowup(ctx, call, mock, source.ID, marker)
		defer gate.unblock()
		if e != nil {
			return e
		}
		if e = restart(); e != nil {
			return fmt.Errorf("active crash %d: %w", i, e)
		}
		gate.unblock()
		select {
		case <-gate.finished:
		case <-ctx.Done():
			return ctx.Err()
		}
		next, e := settleSystem(ctx, call, mock, func(s model.AppState) bool {
			t, ok := findThread(s, source.ID)
			return ok && t.Observation.LatestExecution != nil && t.Observation.LatestExecution.ExecutionID == execution && t.Observation.LatestExecution.Status == "interrupted"
		})
		if e != nil {
			return e
		}
		if reportCount(next) != reportCount(state) {
			return errors.New("crashed execution created a completion report")
		}
		mock.mu.Lock()
		seen := mock.crashInputs[marker]
		mock.mu.Unlock()
		if seen != 1 {
			return fmt.Errorf("crashed input was replayed: %d model requests", seen)
		}
		report.CrashWindows = append(report.CrashWindows, "active-model")
		fmt.Printf("PASS process crash active[%d]: original execution interrupted; input not replayed; native descendants exited\n", i)
		state = next
		state, e = remoteFollowup(ctx, call, mock, state)
		if e != nil {
			return e
		}
	}
	// The soak below retains this exact daemon PID and epoch for its entire run.
	report.SoakPID = connection.PID
	report.SoakEpoch = connection.Epoch
	epoch := connection.Epoch
	started := time.Now()
	for cycle := 1; cycle <= opts.MinCycles || time.Since(started) < opts.Duration; cycle++ {
		if err = call("history:clear", []any{}, nil); err != nil {
			return err
		}
		state, err = startChain(ctx, call, mock)
		if err != nil {
			return fmt.Errorf("cycle %d create: %w", cycle, err)
		}
		state, err = remoteFollowup(ctx, call, mock, state)
		if err != nil {
			return fmt.Errorf("cycle %d followup: %w", cycle, err)
		}
		var answer string
		if err = call("thread:read", []any{object{"threadId": ordinary(state)[0].ID, "question": "What is the exact SYSTEM_CHAIN_CHILD result?"}}, &answer); err != nil || answer != "SYSTEM_CHILD_DONE" {
			return fmt.Errorf("cycle %d read: %q %v", cycle, answer, err)
		}
		loaded, e := sampleResources(ctx, connection.PID, cycle, time.Since(started))
		if e != nil {
			return e
		}
		report.LoadedSamples = append(report.LoadedSamples, loaded)
		tree, e := processTree(ctx, connection.PID)
		if e != nil {
			return e
		}
		var native []processSample
		for _, proc := range tree {
			if proc.PID != connection.PID {
				native = append(native, proc)
			}
		}
		if err = remoteActiveClear(ctx, call, mock, state, cycle); err != nil {
			return fmt.Errorf("cycle %d active clear: %w", cycle, err)
		}
		if err = waitProcessesGone(ctx, native); err != nil {
			return err
		}
		if err = waitEmptyProcessTree(ctx, connection.PID); err != nil {
			return err
		}
		registered, e := collectNative()
		if e != nil {
			return e
		}
		if err = waitProcessesGone(ctx, registered); err != nil {
			return err
		}
		nativeConsumed += len(registered)
		sample, e := sampleResources(ctx, connection.PID, cycle, time.Since(started))
		if e != nil {
			return e
		}
		if sample.Descendants != 0 {
			return fmt.Errorf("empty history retained %d descendants", sample.Descendants)
		}
		report.Samples = append(report.Samples, sample)
		report.Cycles = cycle
		report.SoakSeconds = time.Since(started).Seconds()
		if cycle >= 15 {
			if err = verifyResources(report.Samples); err != nil {
				return err
			}
		}
		current, e := daemon.Status(ctx, p)
		if e != nil {
			return e
		}
		if current == nil || current.PID != report.SoakPID || current.Epoch != epoch {
			return errors.New("soak daemon restarted")
		}
		// Request transcripts are bounded in the observing parent. Daemon resource
		// samples never include this fixture server's memory.
		mock.mu.Lock()
		mock.requests = nil
		mock.mu.Unlock()
		fmt.Printf("SOAK cycle=%d elapsed=%.1fs rss=%dKiB fd=%d children=%d\n", cycle, report.SoakSeconds, sample.RSSKiB, sample.FDs, sample.Descendants)
		if cycle >= opts.MinCycles && time.Since(started) >= opts.Duration {
			break
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(time.Second):
		}
	}
	if err = verifyResources(report.Samples); err != nil {
		return err
	}
	mock.mu.Lock()
	for marker, count := range mock.crashInputs {
		if count != 1 {
			err = errors.Join(err, fmt.Errorf("crash input %s count=%d", marker, count))
		}
	}
	mock.mu.Unlock()
	if err != nil {
		return err
	}
	report.LongRunQualified = report.Cycles >= 100 && report.SoakSeconds >= 1800
	fmt.Printf("PASS resource sampling phase: cycles=%d duration=%.1fs; final cleanup/heap audit pending\n", report.Cycles, report.SoakSeconds)
	return nil
}

func parseGCHeap(log []byte) []int {
	values, _ := parseGCTrace(log)
	return values
}
func parseGCTrace(log []byte) ([]int, []float64) {
	matches := regexp.MustCompile(`gc \d+ @([\d.]+)s [^\n]* (\d+)->(\d+)->(\d+) MB,`).FindAllSubmatch(log, -1)
	values := []int{}
	seconds := []float64{}
	for _, m := range matches {
		v, _ := strconv.Atoi(string(m[4]))
		sec, _ := strconv.ParseFloat(string(m[1]), 64)
		values = append(values, v)
		seconds = append(seconds, sec)
	}
	return values, seconds
}
func finalOwnerGCLog(log []byte, pid int, epoch string) ([]byte, error) {
	offset, found := 0, -1
	for _, line := range bytes.SplitAfter(log, []byte("\n")) {
		var record struct {
			PID    int    `json:"pid"`
			Epoch  string `json:"epoch"`
			Status string `json:"status"`
		}
		if json.Unmarshal(bytes.TrimSpace(line), &record) == nil && record.PID == pid && record.Epoch == epoch && record.Status == "running" {
			found = offset + len(line)
		}
		offset += len(line)
	}
	if found < 0 {
		return nil, errors.New("missing final daemon owner marker in GC log")
	}
	return log[found:], nil
}
func verifyGCHeap(values []int) error {
	if len(values) < 10 {
		return errors.New("missing sustained GC live-heap evidence")
	}
	base := median(values[:5])
	for _, v := range values[len(values)/2:] {
		if v > base+32 {
			return fmt.Errorf("GC live-heap growth exceeded 32 MiB: baseline=%d live=%d", base, v)
		}
	}
	return nil
}

func latestUserContains(input any, marker string) bool {
	items := list(input)
	for i := len(items) - 1; i >= 0; i-- {
		m := record(items[i])
		if m["role"] == "user" {
			return strings.Contains(string(encoded(m["content"])), marker)
		}
	}
	return false
}
func remoteFollowup(ctx context.Context, call systemInvoke, mock *provider, state model.AppState) (model.AppState, error) {
	id := ordinary(state)[0].ID
	var receipt struct {
		ExecutionID         string
		StartedNewExecution bool
	}
	if e := call("thread:follow-up", []any{object{"threadId": id, "input": object{"parts": []any{object{"kind": "text", "text": "SYSTEM_CHAIN_CHILD: continue and reply SYSTEM_CHILD_DONE"}}}}}, &receipt); e != nil {
		return state, e
	}
	if !receipt.StartedNewExecution || receipt.ExecutionID == "" {
		return state, errors.New("missing successor execution receipt")
	}
	next, e := settleSystem(ctx, call, mock, func(s model.AppState) bool {
		t, ok := findThread(s, id)
		return ok && t.Observation.LatestExecution != nil && t.Observation.LatestExecution.ExecutionID == receipt.ExecutionID && t.Observation.LatestExecution.Status == "completed" && reportCount(s) == reportCount(state)+1
	})
	return next, e
}
func remoteActiveClear(ctx context.Context, call systemInvoke, mock *provider, state model.AppState, cycle int) error {
	id := ordinary(state)[0].ID
	settings := encoded(state.Settings)
	revision := state.SettingsRevision
	gate, _, e := heldFollowup(ctx, call, mock, id, fmt.Sprintf("SYSTEM_SOAK_CLEAR_%d_END", cycle))
	defer gate.unblock()
	if e != nil {
		return e
	}
	if e = call("history:clear", []any{}, nil); e != nil {
		return e
	}
	gate.unblock()
	select {
	case <-gate.finished:
	case <-ctx.Done():
		return ctx.Err()
	}
	next, e := settleSystem(ctx, call, mock, func(s model.AppState) bool { return len(ordinary(s)) == 0 && len(s.ApplicationThreads) == 0 })
	if e != nil {
		return e
	}
	if !bytes.Equal(settings, encoded(next.Settings)) || revision != next.SettingsRevision {
		return errors.New("active clear altered settings")
	}
	for _, t := range next.Threads {
		if t.Note != nil {
			return errors.New("active clear retained note")
		}
	}
	e = call("thread:read", []any{object{"threadId": id, "question": "removed generation"}}, nil)
	if e == nil || !strings.Contains(e.Error(), "unknown thread: "+id) {
		return fmt.Errorf("old generation remains readable: %v", e)
	}
	return nil
}
