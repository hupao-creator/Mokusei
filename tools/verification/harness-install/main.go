// Command harness-install verifies installer ownership with real local processes.
// Its curl/npm fixtures never download or install an external package.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/plugin"
	"github.com/hupao-creator/Mokusei/internal/platform/processgroup"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/claude"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/codex"
	"github.com/hupao-creator/Mokusei/internal/plugins/harness/opencode"
)

type installer interface {
	plugin.Installer
	Close() error
}

type processRecord struct {
	PID  int `json:"pid"`
	PGID int `json:"pgid"`
}

func main() {
	if len(os.Args) > 2 && os.Args[1] == "fixture" {
		if err := runFixture(os.Args[2]); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		return
	}
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run() error {
	onlyHarness := flag.String("harness", "all", "all, claude, codex, or opencode")
	onlyCase := flag.String("case", "all", "all, cancelled, leader-exit, failure, overflow, or precancelled")
	flag.Parse()
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	cases := []string{"cancelled", "leader-exit", "failure", "overflow", "precancelled"}
	if *onlyCase != "all" {
		valid := false
		for _, name := range cases {
			valid = valid || name == *onlyCase
		}
		if !valid {
			return fmt.Errorf("unknown case %q", *onlyCase)
		}
		cases = []string{*onlyCase}
	}
	factories := []struct {
		name string
		new  func(plugin.HostContext) installer
	}{
		{"claude", func(host plugin.HostContext) installer { return claude.New(host) }},
		{"codex", func(host plugin.HostContext) installer { return codex.New(host) }},
		{"opencode", func(host plugin.HostContext) installer { return opencode.New(host) }},
	}
	matched := false
	for _, factory := range factories {
		if *onlyHarness != "all" && *onlyHarness != factory.name {
			continue
		}
		matched = true
		// Initialize the runtime's poller before comparing owned file descriptors.
		if err := replay(ctx, factory.name, "success", factory.new, false); err != nil {
			return err
		}
		for _, scenario := range cases {
			if err := replay(ctx, factory.name, scenario, factory.new, true); err != nil {
				return err
			}
		}
	}
	if !matched {
		return fmt.Errorf("unknown harness %q", *onlyHarness)
	}
	fmt.Println("PASS: installer descendants and inherited output pipes drain before return")
	return nil
}

func replay(parent context.Context, name, scenario string, create func(plugin.HostContext) installer, checkDescriptors bool) (resultErr error) {
	dir, err := os.MkdirTemp("", "mokusei-install-replay-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(dir)
	self, err := os.Executable()
	if err != nil {
		return err
	}
	for file, source := range map[string]string{
		"curl": "#!/bin/sh\nprintf '%s\\n' 'exec \"$MOKUSEI_INSTALL_FIXTURE\" fixture installer'\n",
		"npm":  "#!/bin/sh\nexec \"$MOKUSEI_INSTALL_FIXTURE\" fixture installer\n",
	} {
		if err := os.WriteFile(filepath.Join(dir, file), []byte(source), 0700); err != nil {
			return err
		}
	}
	env := map[string]string{
		"PATH":                    dir + ":/usr/bin:/bin",
		"MOKUSEI_INSTALL_FIXTURE": self,
		"MOKUSEI_INSTALL_DIR":     dir,
		"MOKUSEI_INSTALL_CASE":    scenario,
		"GORACE":                  "atexit_sleep_ms=0",
	}
	h := create(plugin.HostContext{
		Environment: func(context.Context) (map[string]string, error) { return env, nil },
		ResolveExecutable: func(_ context.Context, requested, _, _ string) (string, error) {
			if requested != "npm" {
				return "", fmt.Errorf("unexpected executable %q", requested)
			}
			return filepath.Join(dir, "npm"), nil
		},
	})
	defer func() { resultErr = errors.Join(resultErr, h.Close()) }()
	before, err := descriptorCount()
	if err != nil {
		return err
	}
	ctx, cancel := context.WithCancel(parent)
	defer cancel()
	if scenario == "precancelled" {
		cancel()
	}
	done := make(chan error, 1)
	go func() { done <- h.Install(ctx) }()
	joined := false
	defer func() {
		if resultErr == nil {
			return
		}
		cancel()
		// Cleanup is independent of the production path so a failing regression
		// cannot strand its own fixture or inherited output writers.
		killFixture(dir)
		if !joined {
			select {
			case <-done:
			case <-time.After(5 * time.Second):
				resultErr = errors.Join(resultErr, errors.New("fixture installation did not join after emergency cleanup"))
			}
		}
	}()
	if scenario == "cancelled" {
		if err := waitForRecord(ctx, dir, "descendant"); err != nil {
			return fmt.Errorf("%s/%s: %w", name, scenario, err)
		}
		cancel()
	}
	started := time.Now()
	var installErr error
	select {
	case installErr = <-done:
		joined = true
	case <-time.After(8 * time.Second):
		return fmt.Errorf("%s/%s: Install did not join its process group and pipes", name, scenario)
	}
	switch scenario {
	case "cancelled", "precancelled":
		if !errors.Is(installErr, context.Canceled) || errors.Is(installErr, processgroup.ErrCleanup) {
			return fmt.Errorf("%s/%s: expected cancellation with confirmed cleanup, got %v", name, scenario, installErr)
		}
	case "failure":
		if installErr == nil || !strings.Contains(installErr.Error(), "23") || !strings.Contains(installErr.Error(), "fixture install failed") {
			return fmt.Errorf("%s/%s: lost exit status or diagnostic: %v", name, scenario, installErr)
		}
	case "overflow":
		if !errors.Is(installErr, processgroup.ErrOutputLimit) {
			return fmt.Errorf("%s/%s: expected bounded output failure, got %v", name, scenario, installErr)
		}
	default:
		if installErr != nil {
			return fmt.Errorf("%s/%s: %w", name, scenario, installErr)
		}
	}
	if scenario == "cancelled" || scenario == "leader-exit" {
		leader, err := readRecord(dir, "installer")
		if err != nil {
			return err
		}
		child, err := readRecord(dir, "descendant")
		if err != nil {
			return err
		}
		if leader.PGID <= 1 || leader.PGID == syscall.Getpgrp() || child.PGID != leader.PGID || child.PID == leader.PID {
			return fmt.Errorf("%s/%s: fixture did not run as an isolated process tree: %+v %+v", name, scenario, leader, child)
		}
		if err := assertGroupStopped(parent, leader.PGID); err != nil {
			return fmt.Errorf("%s/%s: %w", name, scenario, err)
		}
	}
	if scenario == "precancelled" {
		if _, err := os.Stat(filepath.Join(dir, "installer.json")); !errors.Is(err, os.ErrNotExist) {
			return fmt.Errorf("%s/%s: launched an installer after cancellation", name, scenario)
		}
	}
	after, err := descriptorCount()
	if err != nil {
		return err
	}
	if checkDescriptors && after != before {
		return fmt.Errorf("%s/%s: open descriptors changed from %d to %d", name, scenario, before, after)
	}
	fmt.Printf("PASS: %s/%s joined in %s; descriptors %d -> %d\n", name, scenario, time.Since(started).Round(time.Millisecond), before, after)
	return nil
}

func descriptorCount() (int, error) {
	entries, err := os.ReadDir("/dev/fd")
	return len(entries), err
}

func assertGroupStopped(parent context.Context, pgid int) error {
	ctx, cancel := context.WithTimeout(parent, 2*time.Second)
	defer cancel()
	command := exec.CommandContext(ctx, "/bin/ps", "-axo", "pgid=,stat=")
	command.WaitDelay = time.Second
	output, err := command.Output()
	if err != nil {
		return err
	}
	rows := 0
	for _, line := range strings.Split(string(output), "\n") {
		fields := strings.Fields(line)
		if len(fields) == 0 {
			continue
		}
		if len(fields) != 2 {
			return fmt.Errorf("malformed process row %q", line)
		}
		group, err := strconv.Atoi(fields[0])
		if err != nil {
			return err
		}
		rows++
		// A zombie cannot execute or keep a pipe open while awaiting its reaper.
		if group == pgid && !strings.HasPrefix(fields[1], "Z") {
			return fmt.Errorf("owned process group %d still has a running member (%s)", pgid, fields[1])
		}
	}
	if rows == 0 {
		return errors.New("empty process inspection cannot confirm cleanup")
	}
	return nil
}

func readRecord(dir, role string) (processRecord, error) {
	data, err := os.ReadFile(filepath.Join(dir, role+".json"))
	if err != nil {
		return processRecord{}, err
	}
	var record processRecord
	err = json.Unmarshal(data, &record)
	return record, err
}

func waitForRecord(ctx context.Context, dir, role string) error {
	timer := time.NewTimer(5 * time.Second)
	defer timer.Stop()
	ticker := time.NewTicker(5 * time.Millisecond)
	defer ticker.Stop()
	for {
		if _, err := readRecord(dir, role); err == nil {
			return nil
		} else if !errors.Is(err, os.ErrNotExist) {
			return err
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-timer.C:
			return fmt.Errorf("%s fixture never became ready", role)
		case <-ticker.C:
		}
	}
}

func killFixture(dir string) {
	for _, role := range []string{"descendant", "installer"} {
		record, err := readRecord(dir, role)
		if err != nil {
			continue
		}
		group, err := syscall.Getpgid(record.PID)
		if err != nil || group != record.PGID {
			continue
		}
		if record.PGID > 1 && record.PGID != syscall.Getpgrp() {
			_ = syscall.Kill(-record.PGID, syscall.SIGKILL)
		}
		if record.PID > 1 && record.PID != os.Getpid() {
			_ = syscall.Kill(record.PID, syscall.SIGKILL)
		}
	}
}

func runFixture(role string) error {
	dir := os.Getenv("MOKUSEI_INSTALL_DIR")
	if role == "descendant" {
		// The owner must escalate past TERM and join both inherited output pipes.
		signal.Ignore(syscall.SIGTERM)
	}
	record := processRecord{PID: os.Getpid(), PGID: syscall.Getpgrp()}
	data, err := json.Marshal(record)
	if err != nil {
		return err
	}
	path := filepath.Join(dir, role+".json")
	if err := os.WriteFile(path+".partial", data, 0600); err != nil {
		return err
	}
	if err := os.Rename(path+".partial", path); err != nil {
		return err
	}
	if role == "descendant" {
		fmt.Fprintln(os.Stdout, "fixture descendant holds stdout")
		fmt.Fprintln(os.Stderr, "fixture descendant holds stderr")
		time.Sleep(time.Minute)
		return nil
	}
	switch os.Getenv("MOKUSEI_INSTALL_CASE") {
	case "failure":
		fmt.Fprintln(os.Stderr, "fixture install failed")
		os.Exit(23)
	case "overflow":
		_, err := os.Stdout.WriteString(strings.Repeat("x", 9*1024*1024))
		return err
	case "cancelled", "leader-exit":
		child := exec.Command(os.Getenv("MOKUSEI_INSTALL_FIXTURE"), "fixture", "descendant")
		child.Stdout, child.Stderr = os.Stdout, os.Stderr
		if err := child.Start(); err != nil {
			return err
		}
		if err := waitForRecord(context.Background(), dir, "descendant"); err != nil {
			_ = child.Process.Kill()
			_ = child.Wait()
			return err
		}
		if os.Getenv("MOKUSEI_INSTALL_CASE") == "cancelled" {
			time.Sleep(time.Minute)
		}
	}
	return nil
}
