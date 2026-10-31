package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/hupao-creator/Mokusei/internal/tooling/devtool"
)

func buildFixtureRoot(root string) string {
	for _, path := range []string{"internal", "cmd/mokusei-runtime", ".build/go"} {
		must(os.MkdirAll(filepath.Join(root, path), 0700))
	}
	must(os.WriteFile(filepath.Join(root, "go.mod"), []byte("module fixture\ngo 1.27.0\n"), 0600))
	must(os.WriteFile(filepath.Join(root, "cmd/mokusei-runtime/main.go"), []byte("package main\nfunc main() {}\n"), 0600))
	artifact := filepath.Join(root, ".build/go/mokusei-runtime")
	must(os.WriteFile(artifact, []byte("original artifact"), 0700))
	return artifact
}

func waitFixtureFile(path string) []byte {
	deadline := time.Now().Add(10 * time.Second)
	for {
		data, err := os.ReadFile(path)
		if err == nil && len(data) > 0 {
			return data
		}
		check(time.Now().Before(deadline), "fixture did not publish "+path)
		time.Sleep(5 * time.Millisecond)
	}
}

func parsePID(data []byte) int {
	pid, err := strconv.Atoi(strings.TrimSpace(string(data)))
	must(err)
	check(pid > 1, "invalid fixture PID")
	return pid
}

func processStopped(pid int) bool {
	if errors.Is(syscall.Kill(pid, 0), syscall.ESRCH) {
		return true
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	state, err := exec.CommandContext(ctx, "/bin/ps", "-o", "stat=", "-p", strconv.Itoa(pid)).Output()
	return (err == nil && strings.HasPrefix(strings.TrimSpace(string(state)), "Z")) || errors.Is(syscall.Kill(pid, 0), syscall.ESRCH)
}

func assertCompilerStopped(root string) {
	for _, name := range []string{"leader.pid", "child.pid"} {
		check(processStopped(parsePID(waitFixtureFile(filepath.Join(root, ".build", name)))), "compiler still executing after operation returned: "+name)
	}
	path := filepath.Join(root, ".build/heartbeat")
	before := waitFixtureFile(path)
	time.Sleep(50 * time.Millisecond)
	after, err := os.ReadFile(path)
	must(err)
	check(string(before) == string(after), "compiler descendant heartbeat continued after cleanup")
}

// Failure cleanup runs only after the assertions above inspect production
// behavior. The replay must never supply the cleanup that it is verifying.
func cleanupCompilerFixture(root string) {
	for _, name := range []string{"child.pid", "leader.pid", "tool.pid"} {
		if data, err := os.ReadFile(filepath.Join(root, ".build", name)); err == nil {
			pid := parsePID(data)
			if !processStopped(pid) {
				_ = syscall.Kill(pid, syscall.SIGKILL)
			}
		}
	}
}

func verifyCompilerCleanup(ctx context.Context, root string) {
	artifact := buildFixtureRoot(root)
	defer cleanupCompilerFixture(root)
	must(os.WriteFile(filepath.Join(root, ".build/compiler-mode"), []byte("descendant"), 0600))
	firstContext, cancel := context.WithCancel(ctx)
	defer cancel()
	first, second := make(chan error, 1), make(chan error, 1)
	go func() { first <- devtool.Run(firstContext, root, []string{"runtime"}) }()
	child := waitFixtureFile(filepath.Join(root, ".build/child.pid"))
	must(os.WriteFile(filepath.Join(root, ".build/required-stopped.pid"), child, 0600))
	must(os.WriteFile(filepath.Join(root, ".build/compiler-mode"), []byte("normal"), 0600))
	go func() { second <- devtool.Run(ctx, root, []string{"runtime"}) }()
	cancel()
	check(errors.Is(<-first, context.Canceled), "active compiler cancellation was lost")
	assertCompilerStopped(root)
	data, err := os.ReadFile(artifact)
	must(err)
	check(string(data) == "original artifact", "cancelled compiler published an artifact")
	must(os.WriteFile(filepath.Join(root, ".build/release"), nil, 0600))
	must(<-second)
	data, err = os.ReadFile(filepath.Join(root, ".build/starts"))
	must(err)
	check(strings.Count(string(data), "start\n") == 2, "queued compiler did not resume")
	must(os.Remove(filepath.Join(root, ".build/required-stopped.pid")))
	must(os.Remove(filepath.Join(root, ".build/child.pid")))
	must(os.WriteFile(filepath.Join(root, ".build/compiler-mode"), []byte("orphan"), 0600))
	must(devtool.Run(ctx, root, []string{"runtime"}))
	assertCompilerStopped(root)
	data, err = os.ReadFile(artifact)
	must(err)
	check(string(data) == "linked fixture 3", "successful compiler did not publish after joining its orphan")
	must(os.WriteFile(filepath.Join(root, ".build/compiler-mode"), []byte("nonzero"), 0600))
	err = devtool.Run(ctx, root, []string{"runtime"})
	var exit *exec.ExitError
	check(errors.As(err, &exit) && exit.ExitCode() == 9, "compiler exit status was lost")
	data, err = os.ReadFile(artifact)
	must(err)
	check(string(data) == "linked fixture 3", "nonzero compiler replaced the prior artifact")
}

func verifyWatcherCleanup(ctx context.Context, root string) {
	artifact := buildFixtureRoot(root)
	defer cleanupCompilerFixture(root)
	must(os.WriteFile(filepath.Join(root, ".gitignore"), []byte(".build/\n"), 0600))
	for _, args := range [][]string{
		{"init", "-b", "main"}, {"add", "."},
		{"-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", "commit", "-m", "Fixture"},
	} {
		cmd := exec.CommandContext(ctx, "git", args...)
		cmd.Dir = root
		output, err := cmd.CombinedOutput()
		if err != nil {
			panic(fmt.Errorf("fixture git: %w: %s", err, output))
		}
	}
	must(os.WriteFile(filepath.Join(root, ".build/compiler-mode"), []byte("descendant"), 0600))
	watchContext, cancel := context.WithCancel(ctx)
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- devtool.WatchMain(watchContext, root, true) }()
	waitFixtureFile(filepath.Join(root, ".build/child.pid"))
	cancel()
	check(errors.Is(<-done, context.Canceled), "watcher cancellation was lost")
	assertCompilerStopped(root)
	check(processStopped(parsePID(waitFixtureFile(filepath.Join(root, ".build/tool.pid")))), "watcher returned before its development tool exited")
	data, err := os.ReadFile(artifact)
	must(err)
	check(string(data) == "original artifact", "cancelled nested compiler published an artifact")
}

func nestedToolFixture() {
	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGTERM, os.Interrupt)
	defer cancel()
	must(os.WriteFile(".build/tool.pid", []byte(strconv.Itoa(os.Getpid())), 0600))
	root, err := os.Getwd()
	must(err)
	if err = devtool.Run(ctx, root, []string{"runtime"}); err != nil {
		if errors.Is(err, context.Canceled) {
			os.Exit(130)
		}
		panic(err)
	}
}

func startCompilerDescendant() {
	must(os.WriteFile(".build/leader.pid", []byte(strconv.Itoa(os.Getpid())), 0600))
	self, err := os.Executable()
	must(err)
	child := exec.Command(self, "compiler-descendant")
	child.Stdout, child.Stderr = os.Stdout, os.Stderr
	must(child.Start())
	waitFixtureFile(".build/child.pid")
}

func publishCompilerHeartbeat() {
	// Production cleanup may kill the writer at any instruction. Publish only a
	// fully written, closed value so termination cannot truncate the last receipt.
	const pending = ".build/heartbeat.next"
	must(os.WriteFile(pending, []byte(strconv.FormatInt(time.Now().UnixNano(), 10)), 0600))
	must(os.Rename(pending, ".build/heartbeat"))
}

func compilerDescendant() {
	signal.Ignore(syscall.SIGTERM)
	_ = os.Stdin.Close()
	_ = os.Stdout.Close()
	_ = os.Stderr.Close()
	publishCompilerHeartbeat()
	must(os.WriteFile(".build/child.pid", []byte(strconv.Itoa(os.Getpid())), 0600))
	for {
		time.Sleep(10 * time.Millisecond)
		publishCompilerHeartbeat()
	}
}
