package main

import (
	"bufio"
	"context"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/hupao-creator/Mokusei/internal/tooling/architecture"
	"github.com/hupao-creator/Mokusei/internal/tooling/devtool"
)

func must(err error) {
	if err != nil {
		panic(err)
	}
}
func check(ok bool, message string) {
	if !ok {
		panic(message)
	}
}
func main() {
	if len(os.Args) > 1 && os.Args[1] == "offline-client-fresh-gated" {
		runOfflineClientFreshGated()
		return
	}
	if len(os.Args) > 1 && os.Args[1] == "offline-client-fresh" {
		runOfflineClientFresh()
		return
	}
	if os.Getenv("MOKUSEI_NATIVE_CLIENT_FIXTURE") == "1" {
		fmt.Println("ready")
		bufio.NewScanner(os.Stdin).Scan()
		return
	}
	if len(os.Args) > 1 && os.Args[1] == "compiler-descendant" {
		compilerDescendant()
		return
	}
	if len(os.Args) > 1 && os.Args[1] == "hold-application" {
		fmt.Println("ready")
		for {
			time.Sleep(time.Hour)
		}
	}
	if os.Getenv("MOKUSEI_BUILD_FIXTURE") == "1" {
		if len(os.Args) > 1 && os.Args[1] == "fast" {
			nestedToolFixture()
			return
		}
		compileFixture()
		return
	}
	swiftOffline := flag.Bool("swift-offline-client", false, "verify fresh against a live Swift preferences/draft writer without a runtime")
	swiftConcurrent := flag.Bool("swift-concurrent-client", false, "verify atomic native startup and fresh rotation at the final-scan boundary")
	flag.Parse()
	if *swiftConcurrent {
		must(verifySwiftConcurrentClient())
		return
	}
	if *swiftOffline {
		must(verifySwiftOfflineClient())
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	root, err := os.MkdirTemp("", "mokusei-devtool-replay-")
	must(err)
	defer os.RemoveAll(root)
	root, err = filepath.EvalSymlinks(root)
	must(err)
	for _, path := range []string{"internal", "cmd/mokusei-runtime", ".build"} {
		must(os.MkdirAll(filepath.Join(root, path), 0700))
	}
	must(os.WriteFile(filepath.Join(root, "go.mod"), []byte("module fixture\ngo 1.27.0\n"), 0600))
	source := filepath.Join(root, "cmd/mokusei-runtime/main.go")
	must(os.WriteFile(source, []byte("package main\nfunc main(){}\n"), 0600))
	self, err := os.Executable()
	must(err)
	must(os.Setenv("MOKUSEI_GO", self))
	must(os.Setenv("MOKUSEI_BUILD_FIXTURE", "1"))
	count := func() int {
		data, _ := os.ReadFile(filepath.Join(root, ".build/starts"))
		return strings.Count(string(data), "start\n")
	}
	waitFor := func(want int) {
		deadline := time.Now().Add(5 * time.Second)
		for count() < want {
			check(time.Now().Before(deadline), "compiler fixture did not enter")
			time.Sleep(5 * time.Millisecond)
		}
	}
	release := filepath.Join(root, ".build/release")
	done := make(chan error, 2)
	go func() { done <- devtool.Run(ctx, root, []string{"runtime"}) }()
	waitFor(1)
	go func() { done <- devtool.Run(ctx, root, []string{"runtime"}) }()
	time.Sleep(100 * time.Millisecond)
	check(count() == 1, "parallel builds entered compiler together")
	must(os.WriteFile(release, nil, 0600))
	must(<-done)
	must(<-done)
	check(count() == 2, "second build did not resume")
	lock, err := os.OpenFile(filepath.Join(root, ".build/tooling.lock"), os.O_RDWR, 0600)
	must(err)
	must(syscall.Flock(int(lock.Fd()), syscall.LOCK_EX))
	short, stop := context.WithTimeout(ctx, 50*time.Millisecond)
	err = devtool.Run(short, root, []string{"runtime"})
	stop()
	check(errors.Is(err, context.DeadlineExceeded) && count() == 2, "cancelled lock waiter compiled")
	must(syscall.Flock(int(lock.Fd()), syscall.LOCK_UN))
	must(lock.Close())
	artifact := filepath.Join(root, ".build/go/mokusei-runtime")
	before, err := os.ReadFile(artifact)
	must(err)
	must(os.Remove(release))
	go func() { done <- devtool.Run(ctx, root, []string{"runtime"}) }()
	waitFor(3)
	must(os.WriteFile(source, []byte("package main\nfunc main(){}\n// input changed during compilation\n"), 0600))
	must(os.WriteFile(release, nil, 0600))
	err = <-done
	check(err != nil && strings.Contains(err.Error(), "build inputs changed"), "source change was published")
	after, err := os.ReadFile(artifact)
	must(err)
	check(string(before) == string(after), "failed build replaced prior artifact")
	app := filepath.Join(root, "installed", "Mokusei.app")
	binary := filepath.Join(app, "Contents/MacOS/Mokusei")
	must(os.MkdirAll(filepath.Dir(binary), 0700))
	data, err := os.ReadFile(self)
	must(err)
	must(os.WriteFile(binary, data, 0700))
	alias := filepath.Join(root, "alias")
	must(os.Symlink(filepath.Dir(app), alias))
	holdCtx, stopHold := context.WithCancel(ctx)
	child := exec.CommandContext(holdCtx, binary, "hold-application")
	pipe, err := child.StdoutPipe()
	must(err)
	must(child.Start())
	scanner := bufio.NewScanner(pipe)
	check(scanner.Scan() && scanner.Text() == "ready", "application fixture not ready")
	_, err = devtool.Install(ctx, filepath.Join(root, "invalid-source.app"), filepath.Join(alias, "Mokusei.app"))
	check(err != nil && strings.Contains(err.Error(), "quit the installed application"), "installer missed running application through symlink alias")
	stopHold()
	check(child.Wait() != nil, "application fixture did not stop")
	verifyArchitectureScope(filepath.Join(root, "architecture"))
	verifyFreshDevelopmentData(filepath.Join(root, "home"))
	verifyNativeProcessProfiles(ctx, filepath.Join(root, "native profiles"), self)
	verifyCompilerCleanup(ctx, filepath.Join(root, "compiler-cleanup"))
	verifyWatcherCleanup(ctx, filepath.Join(root, "watcher-cleanup"))
	fmt.Println("PASS devtool process integration: serial build lease, cancelled waiter, input-change rejection preserving prior artifact, fresh profile exclusion, compiler descendants joined before lease release/publication, nested watcher cancellation, and running-app installation guard through a symlink alias; compiler and application are isolated self-exec fixtures")
}

func verifyArchitectureScope(root string) {
	write := func(relative string, data []byte) {
		path := filepath.Join(root, relative)
		must(os.MkdirAll(filepath.Dir(path), 0700))
		must(os.WriteFile(path, data, 0600))
	}
	for _, relative := range []string{
		"internal/core/composition/bootstrap.go",
		"app/macos/Sources/Plugins/Applications/NativeApplicationModules.swift",
		"internal/plugins/harness/pi/resources/host-extension.mjs",
		"internal/plugins/harness/pi/resources/read-guard.mjs",
		"internal/plugins/harness/opencode/assets/index.mjs",
		"internal/plugins/harness/opencode/assets/credentials.mjs",
	} {
		data, err := os.ReadFile(relative)
		must(err)
		write(relative, data)
	}
	for _, relative := range []string{
		".claude/dev-main/user-data/external-plugin/package.json",
		".claude/worktrees/old/package.json",
		".claude/worktrees/old/runtime.mjs",
	} {
		write(relative, []byte("{}\n"))
	}
	must(architecture.Check(root))
	for _, relative := range []string{"internal/worker.mjs", ".claude/skills/worker.mjs", "package.json"} {
		write(relative, []byte("{}\n"))
		err := architecture.Check(root)
		check(err != nil && strings.Contains(err.Error(), relative), "architecture scope hid current-checkout source: "+relative)
		must(os.Remove(filepath.Join(root, relative)))
	}
	fmt.Println("PASS architecture scope: ignored local profiles/worktrees excluded; active code, skill resources and root manifests still checked")
}

func compileFixture() {
	var output string
	for i, arg := range os.Args {
		if arg == "-o" && i+1 < len(os.Args) {
			output = os.Args[i+1]
		}
	}
	check(output != "", "compiler output path missing")
	if os.Args[len(os.Args)-1] == "./cmd/mokusei-dev" {
		self, err := os.Executable()
		must(err)
		data, err := os.ReadFile(self)
		must(err)
		must(os.WriteFile(output, data, 0700))
		must(os.Chmod(output, 0700))
		return
	}
	if data, err := os.ReadFile(".build/required-stopped.pid"); err == nil {
		check(processStopped(parsePID(data)), "next compiler entered before the old descendant stopped")
	}
	file, err := os.OpenFile(".build/starts", os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0600)
	must(err)
	_, err = file.WriteString("start\n")
	must(err)
	must(file.Close())
	mode, _ := os.ReadFile(".build/compiler-mode")
	if string(mode) == "nonzero" {
		os.Exit(9)
	}
	if string(mode) == "descendant" || string(mode) == "orphan" {
		startCompilerDescendant()
	}
	for {
		if string(mode) == "orphan" {
			break
		}
		if _, err := os.Stat(".build/release"); err == nil {
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	starts, err := os.ReadFile(".build/starts")
	must(err)
	must(os.WriteFile(output, []byte(fmt.Sprintf("linked fixture %d", strings.Count(string(starts), "start\n"))), 0700))
}
