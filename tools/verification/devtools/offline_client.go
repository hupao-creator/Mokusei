package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"maps"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"

	"github.com/hupao-creator/Mokusei/internal/platform/profile"
	"github.com/hupao-creator/Mokusei/internal/tooling/devtool"
)

type offlineFreshResult struct {
	Previous     string `json:"previous"`
	NativeClient bool   `json:"nativeClient"`
	LeaseBusy    bool   `json:"leaseBusy"`
	Failure      string `json:"error,omitempty"`
}

// A private self-exec mode gives FreshDevelopmentData its own disposable HOME;
// the runner and Swift writers keep the caller's environment and explicit paths.
func runOfflineClientFresh() {
	previous, err := devtool.FreshDevelopmentData()
	must(json.NewEncoder(os.Stdout).Encode(offlineFreshReply(previous, err)))
}

func offlineFreshReply(previous string, err error) offlineFreshResult {
	result := offlineFreshResult{Previous: previous, NativeClient: errors.Is(err, devtool.ErrNativeClientRunning),
		LeaseBusy: errors.Is(err, profile.ErrClientLeaseBusy)}
	if err != nil {
		result.Failure = err.Error()
	}
	return result
}

func callOfflineFresh(ctx context.Context, home string) (offlineFreshResult, error) {
	self, err := os.Executable()
	if err != nil {
		return offlineFreshResult{}, err
	}
	bounded, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	command := exec.CommandContext(bounded, self, "offline-client-fresh")
	for _, entry := range os.Environ() {
		if !strings.HasPrefix(entry, "HOME=") {
			command.Env = append(command.Env, entry)
		}
	}
	command.Env = append(command.Env, "HOME="+home)
	command.WaitDelay = time.Second
	var stderr bytes.Buffer
	command.Stderr = &stderr
	data, err := command.Output()
	if err != nil {
		return offlineFreshResult{}, fmt.Errorf("fresh fixture: %w: %s", err, strings.TrimSpace(stderr.String()))
	}
	var result offlineFreshResult
	if err = json.Unmarshal(data, &result); err != nil {
		return result, fmt.Errorf("fresh fixture response: %w", err)
	}
	return result, nil
}

func verifySwiftOfflineClient() (failure error) {
	defer func() {
		if recovered := recover(); recovered != nil {
			failure = fmt.Errorf("%v", recovered)
		}
	}()
	if runtime.GOOS != "darwin" || runtime.GOARCH != "arm64" {
		return errors.New("the native offline-client replay requires Apple Silicon macOS")
	}
	repo, err := devtool.Repository(".")
	if err != nil {
		return err
	}
	root, err := os.MkdirTemp("", "mokusei offline client replay ")
	if err != nil {
		return err
	}
	defer func() { failure = errors.Join(failure, os.RemoveAll(root)) }()
	root, err = filepath.EvalSymlinks(root)
	if err != nil {
		return err
	}
	compile, cancelCompile := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancelCompile()
	binary, err := buildOfflineClient(compile, repo, root)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	otherBinary := filepath.Join(root, "another checkout/app/macos/dist/fast/new generation/Mokusei Native Dev.app/Contents/MacOS/Mokusei")
	copyOfflineExecutable(binary, otherBinary)
	writeOfflineBundleConfiguration(binary)
	writeOfflineBundleConfiguration(otherBinary)
	defaultHome := filepath.Join(root, "Foundation default", "home with spaces")
	otherHome := filepath.Join(root, "Foundation default", "different HOME")
	defaultEnvironment := verifyOfflineFoundationHome(ctx, binary, defaultHome, otherHome)
	for _, previous := range []bool{false, true} {
		for _, alias := range []bool{false, true} {
			label := fmt.Sprintf("previous-%t alias-%t", previous, alias)
			verifyOfflineClientRejection(ctx, binary, otherBinary, filepath.Join(root, label, "home with spaces"), previous, alias)
		}
	}
	verifyUnrelatedOfflineClient(ctx, otherBinary, binary, filepath.Join(root, "unrelated profile", "home with spaces"))
	verifyDefaultOfflineClient(ctx, binary, otherBinary, defaultHome, defaultEnvironment)
	fmt.Println("PASS native offline writers: current/previous and canonical aliases rejected without runtime owners; both directories unchanged; retained production preferences/drafts continue writing after rejection; exited writers permit rotation; unrelated profile remains independent; Foundation/bundle default writer is excluded")
	return nil
}

func buildOfflineClient(ctx context.Context, repo, root string) (string, error) {
	build := filepath.Join(repo, "app/macos/.build/debug")
	modules := filepath.Join(build, "Modules")
	if _, err := os.Stat(filepath.Join(modules, "MokuseiCore.swiftmodule")); err != nil {
		return "", fmt.Errorf("build the current Core module with make check before this replay: %w", err)
	}
	objects, err := filepath.Glob(filepath.Join(build, "MokuseiCore.build/*.o"))
	if err != nil || len(objects) == 0 {
		return "", fmt.Errorf("current Core build objects are unavailable: %v", err)
	}
	binary := filepath.Join(root, "older checkout/app/macos/dist/fast/old generation/Mokusei Native Dev.app/Contents/MacOS/Mokusei")
	if err = os.MkdirAll(filepath.Dir(binary), 0700); err != nil {
		return "", err
	}
	arguments := []string{"swiftc", "-parse-as-library", "-swift-version", "6", "-target", "arm64-apple-macos26.0", "-module-cache-path", filepath.Join(root, "module-cache"), "-I", modules,
		filepath.Join(repo, "app/macos/Sources/Host/Shell/DesktopPreferences.swift"), filepath.Join(repo, "tools/verification/devtools/offline-client.swift")}
	arguments = append(arguments, objects...)
	arguments = append(arguments, "-o", binary)
	command := exec.CommandContext(ctx, "/usr/bin/xcrun", arguments...)
	command.WaitDelay = 2 * time.Second
	if output, err := command.CombinedOutput(); err != nil {
		return "", fmt.Errorf("compile production offline writer: %w\n%s", err, output)
	}
	return binary, nil
}

func copyOfflineExecutable(source, destination string) {
	data, err := os.ReadFile(source)
	must(err)
	must(os.MkdirAll(filepath.Dir(destination), 0700))
	must(os.WriteFile(destination, data, 0700))
}

func writeOfflineBundleConfiguration(binary string) {
	const plist = `<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>Mokusei</string><key>MokuseiDataDirectoryName</key><string>Mokusei Native Dev</string></dict></plist>`
	must(os.WriteFile(filepath.Join(filepath.Dir(filepath.Dir(binary)), "Info.plist"), []byte(plist), 0600))
}

func offlineHomeEnvironment(home, fixedHome string) []string {
	var environment []string
	for _, entry := range os.Environ() {
		if !strings.HasPrefix(entry, "HOME=") && !strings.HasPrefix(entry, "CFFIXED_USER_HOME=") && !strings.HasPrefix(entry, "MOKUSEI_OFFLINE_HOME_PROBE=") {
			environment = append(environment, entry)
		}
	}
	environment = append(environment, "HOME="+home)
	if fixedHome != "" {
		environment = append(environment, "CFFIXED_USER_HOME="+fixedHome)
	}
	return environment
}

func probeOfflineFoundationHome(ctx context.Context, binary string, environment []string) string {
	bounded, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	command := exec.CommandContext(bounded, binary)
	command.Env = append(environment, "MOKUSEI_OFFLINE_HOME_PROBE=1")
	command.WaitDelay = time.Second
	var stderr bytes.Buffer
	command.Stderr = &stderr
	data, err := command.Output()
	if err != nil {
		panic(fmt.Errorf("read-only Foundation home probe: %w: %s", err, strings.TrimSpace(stderr.String())))
	}
	resolved := strings.TrimSuffix(string(data), "\n")
	check(filepath.IsAbs(resolved) && !strings.ContainsAny(resolved, "\r\n"), "Foundation probe did not return exactly one absolute home path")
	return resolved
}

func verifyOfflineFoundationHome(ctx context.Context, binary, home, otherHome string) []string {
	must(os.MkdirAll(home, 0700))
	must(os.MkdirAll(otherHome, 0700))
	homeOnly := probeOfflineFoundationHome(ctx, binary, offlineHomeEnvironment(home, ""))
	environment := offlineHomeEnvironment(otherHome, home)
	fixed := probeOfflineFoundationHome(ctx, binary, environment)
	fmt.Printf("Foundation home (HOME only): %s\nFoundation home (CFFIXED_USER_HOME): %s\n", homeOnly, fixed)
	account, err := user.LookupId(strconv.Itoa(os.Getuid()))
	must(err)
	accountHome, err := filepath.EvalSymlinks(account.HomeDir)
	must(err)
	canonicalHomeOnly, err := filepath.EvalSymlinks(homeOnly)
	must(err)
	check(canonicalHomeOnly == accountHome, "Foundation HOME-only probe no longer resolves to the system account home")
	canonical, err := filepath.EvalSymlinks(fixed)
	must(err)
	expected, err := filepath.EvalSymlinks(home)
	must(err)
	check(canonical == expected, "CFFIXED_USER_HOME did not isolate the Foundation home; refusing to start a default writer")
	return environment
}

type offlineClientProcess struct {
	command *exec.Cmd
	input   io.WriteCloser
	lines   chan string
	done    chan error
	stopped bool
}

func startOfflineClient(ctx context.Context, binary, directory, identity string) *offlineClientProcess {
	return startOfflineClientWithEnvironment(ctx, binary, []string{"--data-dir", directory}, identity, os.Environ())
}

func startOfflineClientWithEnvironment(ctx context.Context, binary string, arguments []string, identity string, environment []string) *offlineClientProcess {
	client := launchOfflineClient(ctx, binary, arguments, identity, environment)
	if err := client.expect(ctx, "ready "+identity+" 1"); err != nil {
		client.close()
		panic(err)
	}
	return client
}

func launchOfflineClient(ctx context.Context, binary string, arguments []string, identity string, environment []string) *offlineClientProcess {
	command := exec.CommandContext(ctx, binary, arguments...)
	for _, entry := range environment {
		if !strings.HasPrefix(entry, "MOKUSEI_OFFLINE_CLIENT_ID=") && !strings.HasPrefix(entry, "MOKUSEI_OFFLINE_HOME_PROBE=") {
			command.Env = append(command.Env, entry)
		}
	}
	command.Env = append(command.Env, "MOKUSEI_OFFLINE_CLIENT_ID="+identity)
	return launchOfflineCommand(command)
}

func launchOfflineCommand(command *exec.Cmd) *offlineClientProcess {
	command.Stderr = os.Stderr
	command.WaitDelay = time.Second
	input, err := command.StdinPipe()
	must(err)
	output, err := command.StdoutPipe()
	must(err)
	must(command.Start())
	client := &offlineClientProcess{command: command, input: input, lines: make(chan string, 16), done: make(chan error, 1)}
	go func() {
		scanner := bufio.NewScanner(output)
		scanner.Buffer(make([]byte, 1024), 16*1024)
		for scanner.Scan() {
			client.lines <- scanner.Text()
		}
		close(client.lines)
		client.done <- errors.Join(scanner.Err(), command.Wait())
	}()
	return client
}

func (p *offlineClientProcess) expect(ctx context.Context, expected string) error {
	line, err := p.readLine(ctx)
	if err != nil {
		return err
	}
	if line != expected {
		return fmt.Errorf("native writer acknowledgement: got %q, want %q", line, expected)
	}
	return nil
}

func (p *offlineClientProcess) readLine(ctx context.Context) (string, error) {
	timer := time.NewTimer(5 * time.Second)
	defer timer.Stop()
	select {
	case line, open := <-p.lines:
		if !open {
			return "", errors.New("native fixture exited before its acknowledgement")
		}
		return line, nil
	case <-timer.C:
		return "", errors.New("native fixture did not acknowledge within five seconds")
	case <-ctx.Done():
		return "", ctx.Err()
	}
}

func (p *offlineClientProcess) write(ctx context.Context, sequence int) {
	_, err := fmt.Fprintf(p.input, "write %d\n", sequence)
	must(err)
	must(p.expect(ctx, fmt.Sprintf("written %d", sequence)))
}

func (p *offlineClientProcess) quit(ctx context.Context) {
	_, err := io.WriteString(p.input, "quit\n")
	must(err)
	must(p.expect(ctx, "bye"))
	must(p.closeInput())
	must(p.waitExit(ctx))
}

func (p *offlineClientProcess) closeInput() error {
	// The stdout reader calls Cmd.Wait after EOF; Wait also closes StdinPipe.
	// A fast cooperative exit may therefore close it before this controller.
	// Keep the acknowledgement and waitExit checks: an already-closed pipe alone
	// says nothing about successful native cleanup.
	err := p.input.Close()
	if errors.Is(err, os.ErrClosed) {
		return nil
	}
	return err
}

func (p *offlineClientProcess) waitExit(ctx context.Context) error {
	timer := time.NewTimer(5 * time.Second)
	defer timer.Stop()
	select {
	case err := <-p.done:
		p.stopped = true
		return err
	case <-timer.C:
		return errors.New("native fixture did not exit within five seconds")
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (p *offlineClientProcess) close() {
	if p.stopped {
		return
	}
	// This is emergency cleanup for this fixture PID only. Successful scenarios
	// await a cooperative quit before testing whether fresh can proceed.
	_ = p.input.Close()
	_ = p.command.Process.Kill()
	<-p.done
	p.stopped = true
}

func seedOfflineProfile(ctx context.Context, binary, directory, identity string) {
	writer := startOfflineClient(ctx, binary, directory, identity)
	defer writer.close()
	writer.quit(ctx)
}

func offlineSnapshot(directory string) map[string][]byte {
	files := make(map[string][]byte)
	must(filepath.WalkDir(directory, func(path string, entry fs.DirEntry, err error) error {
		if err != nil || entry.IsDir() {
			return err
		}
		if !entry.Type().IsRegular() {
			return fmt.Errorf("unexpected non-regular fixture record: %s", path)
		}
		name, err := filepath.Rel(directory, path)
		if err != nil {
			return err
		}
		files[name], err = os.ReadFile(path)
		return err
	}))
	check(len(files) == 2 && len(files["desktop-preferences.json"]) > 0, "native writer did not persist exactly preferences and one draft")
	drafts := 0
	for name := range files {
		if strings.HasPrefix(name, "client-drafts/") {
			drafts++
		}
	}
	check(drafts == 1, "production RuntimeDraftStore did not persist its draft")
	_, err := os.Lstat(filepath.Join(directory, "runtime/owner.json"))
	check(errors.Is(err, os.ErrNotExist), "offline writer unexpectedly acquired a runtime owner")
	return files
}

func sameOfflineSnapshot(left, right map[string][]byte) bool {
	return maps.EqualFunc(left, right, bytes.Equal)
}

func changedOfflineRecords(before, after map[string][]byte) bool {
	if len(before) != len(after) {
		return false
	}
	for name, data := range before {
		if len(after[name]) == 0 || bytes.Equal(data, after[name]) {
			return false
		}
	}
	return true
}

func verifyOfflineClientRejection(ctx context.Context, binary, replacementBinary, home string, usePrevious, useAlias bool) {
	current := filepath.Join(home, "Library/Application Support/Mokusei Native Dev")
	previous := current + ".previous"
	seedOfflineProfile(ctx, binary, current, "seed-current")
	seedOfflineProfile(ctx, replacementBinary, previous, "seed-previous")
	target, activeBinary := current, binary
	if usePrevious {
		target, activeBinary = previous, replacementBinary
	}
	selected := target
	if useAlias {
		selected = filepath.Join(home, "selected profile alias")
		must(os.Symlink(target, selected))
	}
	writer := startOfflineClient(ctx, activeBinary, selected, "active-client")
	defer writer.close()
	beforeCurrent, beforePrevious := offlineSnapshot(current), offlineSnapshot(previous)
	result, err := callOfflineFresh(ctx, home)
	must(err)
	check(result.NativeClient && result.LeaseBusy && result.Failure != "" && result.Previous == "", fmt.Sprintf("fresh did not reject the shared native lease (previous=%t alias=%t): %+v", usePrevious, useAlias, result))
	check(sameOfflineSnapshot(beforeCurrent, offlineSnapshot(current)), "rejected fresh changed current profile bytes")
	check(sameOfflineSnapshot(beforePrevious, offlineSnapshot(previous)), "rejected fresh changed previous profile bytes")
	writer.write(ctx, 2)
	afterCurrent, afterPrevious := offlineSnapshot(current), offlineSnapshot(previous)
	if usePrevious {
		check(changedOfflineRecords(beforePrevious, afterPrevious) && sameOfflineSnapshot(beforeCurrent, afterCurrent), "retained previous-profile writer could not continue production persistence after rejection")
	} else {
		check(changedOfflineRecords(beforeCurrent, afterCurrent) && sameOfflineSnapshot(beforePrevious, afterPrevious), "retained current-profile writer could not continue production persistence after rejection")
	}
	writer.quit(ctx)
	result, err = callOfflineFresh(ctx, home)
	must(err)
	check(!result.NativeClient && result.Failure == "" && result.Previous == previous, fmt.Sprintf("fresh remained blocked after native writer exit: %+v", result))
	_, err = os.Lstat(current)
	check(errors.Is(err, os.ErrNotExist), "fresh did not retire the old current directory")
	check(sameOfflineSnapshot(afterCurrent, offlineSnapshot(previous)), "fresh did not retain the old current profile as previous")
	replacement := startOfflineClient(ctx, replacementBinary, current, "new-current")
	defer replacement.close()
	replacement.write(ctx, 2)
	newCurrent := offlineSnapshot(current)
	check(changedOfflineRecords(afterCurrent, newCurrent), "replacement client did not initialize new preferences and drafts")
	replacement.quit(ctx)
	check(sameOfflineSnapshot(newCurrent, offlineSnapshot(current)) && sameOfflineSnapshot(afterCurrent, offlineSnapshot(previous)), "retired writer or replacement changed the other profile generation")
}

func verifyUnrelatedOfflineClient(ctx context.Context, binary, replacementBinary, home string) {
	current := filepath.Join(home, "Library/Application Support/Mokusei Native Dev")
	previous := current + ".previous"
	seedOfflineProfile(ctx, binary, current, "seed-current")
	seedOfflineProfile(ctx, replacementBinary, previous, "seed-previous")
	unrelated := filepath.Join(home, "unrelated profile with spaces")
	writer := startOfflineClient(ctx, binary, unrelated, "unrelated-client")
	defer writer.close()
	beforeCurrent, beforeUnrelated := offlineSnapshot(current), offlineSnapshot(unrelated)
	result, err := callOfflineFresh(ctx, home)
	must(err)
	check(!result.NativeClient && result.Failure == "" && result.Previous == previous, fmt.Sprintf("unrelated native writer blocked fresh: %+v", result))
	check(sameOfflineSnapshot(beforeCurrent, offlineSnapshot(previous)), "unrelated writer changed the rotated profile")
	replacement := startOfflineClient(ctx, replacementBinary, current, "new-current")
	defer replacement.close()
	newCurrent := offlineSnapshot(current)
	writer.write(ctx, 2)
	check(changedOfflineRecords(beforeUnrelated, offlineSnapshot(unrelated)), "unrelated writer could not continue production persistence")
	check(sameOfflineSnapshot(newCurrent, offlineSnapshot(current)) && sameOfflineSnapshot(beforeCurrent, offlineSnapshot(previous)), "unrelated writer overwrote the new current profile or its backup")
	writer.quit(ctx)
	replacement.quit(ctx)
}

func verifyDefaultOfflineClient(ctx context.Context, binary, replacementBinary, home string, environment []string) {
	current := filepath.Join(home, "Library/Application Support/Mokusei Native Dev")
	previous := current + ".previous"
	seedOfflineProfile(ctx, binary, current, "seed-current")
	seedOfflineProfile(ctx, replacementBinary, previous, "seed-previous")
	// The read-only probe confirmed this exact environment redirects Foundation
	// to the disposable tree before any process may write without --data-dir.
	writer := startOfflineClientWithEnvironment(ctx, binary, nil, "default-client", environment)
	defer writer.close()
	beforeCurrent, beforePrevious := offlineSnapshot(current), offlineSnapshot(previous)
	result, err := callOfflineFresh(ctx, home)
	must(err)
	check(result.NativeClient && result.LeaseBusy && result.Failure != "" && result.Previous == "", fmt.Sprintf("fresh missed the Foundation/bundle default native lease: %+v", result))
	check(sameOfflineSnapshot(beforeCurrent, offlineSnapshot(current)) && sameOfflineSnapshot(beforePrevious, offlineSnapshot(previous)), "default-client rejection changed profile bytes")
	writer.write(ctx, 2)
	afterCurrent := offlineSnapshot(current)
	check(changedOfflineRecords(beforeCurrent, afterCurrent) && sameOfflineSnapshot(beforePrevious, offlineSnapshot(previous)), "default native writer could not continue production persistence after rejection")
	writer.quit(ctx)
	result, err = callOfflineFresh(ctx, home)
	must(err)
	check(!result.NativeClient && result.Failure == "" && result.Previous == previous, fmt.Sprintf("fresh remained blocked after default native writer exit: %+v", result))
	check(sameOfflineSnapshot(afterCurrent, offlineSnapshot(previous)), "default-profile rotation did not retain the last production writes")
}
