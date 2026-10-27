package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"time"

	"github.com/hupao-creator/Mokusei/internal/platform/profile"
	"github.com/hupao-creator/Mokusei/internal/tooling/devtool"
)

// This callback observes the real rotation boundary. It contains no filesystem
// mutation and remains inside every production maintenance/ownership guard.
func runOfflineClientFreshGated() {
	previous, err := devtool.FreshDevelopmentDataWithObserver(func() error {
		fmt.Println("gate")
		input := make(chan string, 1)
		go func() {
			scanner := bufio.NewScanner(os.Stdin)
			if scanner.Scan() {
				input <- scanner.Text()
			} else {
				input <- "closed"
			}
		}()
		timer := time.NewTimer(15 * time.Second)
		defer timer.Stop()
		select {
		case command := <-input:
			if command == "release" {
				return nil
			}
			return fmt.Errorf("fixture rotation observer aborted: %s", command)
		case <-timer.C:
			return errors.New("fixture rotation observer timed out")
		}
	})
	must(json.NewEncoder(os.Stdout).Encode(offlineFreshReply(previous, err)))
}

func startGatedOfflineFresh(ctx context.Context, home string) *offlineClientProcess {
	self, err := os.Executable()
	must(err)
	command := exec.CommandContext(ctx, self, "offline-client-fresh-gated")
	command.Env = offlineHomeEnvironment(home, "")
	process := launchOfflineCommand(command)
	if err := process.expect(ctx, "gate"); err != nil {
		process.close()
		panic(err)
	}
	return process
}

func finishGatedOfflineFresh(ctx context.Context, process *offlineClientProcess, command string) offlineFreshResult {
	_, err := io.WriteString(process.input, command+"\n")
	must(err)
	line, err := process.readLine(ctx)
	must(err)
	var result offlineFreshResult
	must(json.Unmarshal([]byte(line), &result))
	must(process.input.Close())
	must(process.waitExit(ctx))
	return result
}

func verifySwiftConcurrentClient() (failure error) {
	defer func() {
		if recovered := recover(); recovered != nil {
			failure = fmt.Errorf("%v", recovered)
		}
	}()
	if runtime.GOOS != "darwin" || runtime.GOARCH != "arm64" {
		return errors.New("the native admission replay requires Apple Silicon macOS")
	}
	repo, err := devtool.Repository(".")
	if err != nil {
		return err
	}
	root, err := os.MkdirTemp("", "mokusei concurrent client replay ")
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
	otherBinary := filepath.Join(root, "other checkout/app/macos/dist/fast/new generation/Mokusei Native Dev.app/Contents/MacOS/Mokusei")
	copyOfflineExecutable(binary, otherBinary)
	writeOfflineBundleConfiguration(binary)
	writeOfflineBundleConfiguration(otherBinary)
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	// Keep fresh-first first: the old unleased writer/rotation overlay must run
	// through the actual overwrite, rather than fail an earlier lease assertion.
	for _, previous := range []bool{false, true} {
		for _, alias := range []bool{false, true} {
			label := fmt.Sprintf("fresh-first previous-%t alias-%t", previous, alias)
			verifyFreshBeforeOfflineClient(ctx, binary, otherBinary, filepath.Join(root, label, "home 中文 e\u0301"), previous, alias, nil)
		}
	}
	defaultHome := filepath.Join(root, "fresh-first default", "home")
	defaultEnvironment := verifyOfflineFoundationHome(ctx, binary, defaultHome, filepath.Join(root, "different HOME"))
	verifyFreshBeforeOfflineClient(ctx, binary, otherBinary, defaultHome, false, false, defaultEnvironment)
	verifyOfflineObserverAbort(ctx, binary, filepath.Join(root, "observer abort", "home"))
	verifySharedOfflineClients(ctx, binary, otherBinary, filepath.Join(root, "shared clients", "home"))
	verifyMissingCaseAliasClients(ctx, binary, otherBinary, filepath.Join(root, "case aliases", "home"))
	verifyUnsafeOfflineClientLocks(ctx, binary, filepath.Join(root, "unsafe locks"))
	for _, previous := range []bool{false, true} {
		for _, alias := range []bool{false, true} {
			label := fmt.Sprintf("writer-first previous-%t alias-%t", previous, alias)
			verifyOfflineClientRejection(ctx, binary, otherBinary, filepath.Join(root, label, "home"), previous, alias)
		}
	}
	verifyDefaultOfflineClient(ctx, binary, otherBinary, defaultHome, defaultEnvironment)
	verifyNativeAdmissionEntryPoints(ctx, repo, binary, filepath.Join(root, "actual native entrypoints", "home"))
	fmt.Println("PASS native admission ordering: production leases before reads; final-scan gate excludes late current/previous/alias/default clients; replacement reads a fresh generation; shared clients, SIGKILL recovery, observer abort, unsafe locks and missing case aliases")
	return nil
}

func offlineReadEnvironment(environment []string) []string {
	var result []string
	for _, entry := range environment {
		if !strings.HasPrefix(entry, "MOKUSEI_OFFLINE_REPORT_READ=") {
			result = append(result, entry)
		}
	}
	return append(result, "MOKUSEI_OFFLINE_REPORT_READ=1")
}

func verifyFreshBeforeOfflineClient(ctx context.Context, binary, replacementBinary, home string, usePrevious, useAlias bool, defaultEnvironment []string) {
	current := filepath.Join(home, "Library/Application Support/Mokusei Native Dev")
	previous := current + ".previous"
	seedOfflineProfile(ctx, binary, current, "seed-current")
	seedOfflineProfile(ctx, replacementBinary, previous, "seed-previous")
	target := current
	if usePrevious {
		target = previous
	}
	selected := target
	if useAlias {
		selected = filepath.Join(home, "selected profile alias")
		must(os.Symlink(target, selected))
	}
	arguments, environment := []string{"--data-dir", selected}, os.Environ()
	if defaultEnvironment != nil {
		arguments, environment = nil, defaultEnvironment
	}
	beforeCurrent, beforePrevious := offlineSnapshot(current), offlineSnapshot(previous)
	gate := startGatedOfflineFresh(ctx, home)
	defer gate.close()
	late := launchOfflineClient(ctx, binary, arguments, "late-client", offlineReadEnvironment(environment))
	defer late.close()
	line, err := late.readLine(ctx)
	must(err)
	if strings.HasPrefix(line, "loaded ") {
		must(late.expect(ctx, "ready late-client 1"))
		reproduceAdmittedOfflineWriter(ctx, late, gate, replacementBinary, target)
	}
	if line == "ready late-client 1" {
		// The archived 0dd writer predates the read-report instrumentation.
		// Its ready line still proves real preferences/drafts were read/written.
		reproduceAdmittedOfflineWriter(ctx, late, gate, replacementBinary, target)
	}
	check(line == "blocked PROFILE_MAINTENANCE", "late native client was not rejected before reading profile state: "+line)
	must(late.waitExit(ctx))
	_, extra := <-late.lines
	check(!extra, "blocked native client emitted a state-read acknowledgement")
	check(sameOfflineSnapshot(beforeCurrent, offlineSnapshot(current)) && sameOfflineSnapshot(beforePrevious, offlineSnapshot(previous)), "late rejected client changed profile data while fresh held its final gate")
	result := finishGatedOfflineFresh(ctx, gate, "release")
	check(result.Failure == "" && result.Previous == previous, fmt.Sprintf("gated fresh failed after late client rejection: %+v", result))
	_, err = os.Lstat(current)
	check(errors.Is(err, os.ErrNotExist), "gated fresh did not retire the current profile")
	check(sameOfflineSnapshot(beforeCurrent, offlineSnapshot(previous)), "gated fresh changed the retained current generation")
	replacement := launchOfflineClient(ctx, replacementBinary, []string{"--data-dir", current}, "replacement-client", offlineReadEnvironment(os.Environ()))
	defer replacement.close()
	loaded, err := replacement.readLine(ctx)
	must(err)
	check(strings.HasPrefix(loaded, "loaded "), "replacement did not report its production state read")
	var state map[string]json.RawMessage
	must(json.Unmarshal([]byte(strings.TrimPrefix(loaded, "loaded ")), &state))
	check(string(state["selectedThread"]) == "null" && string(state["draft"]) == "null", "replacement loaded state from the retired generation")
	must(replacement.expect(ctx, "ready replacement-client 1"))
	replacement.write(ctx, 2)
	newCurrent := offlineSnapshot(current)
	replacement.quit(ctx)
	check(sameOfflineSnapshot(newCurrent, offlineSnapshot(current)) && sameOfflineSnapshot(beforeCurrent, offlineSnapshot(previous)), "retired client state overwrote a fresh profile or its backup")
}

func reproduceAdmittedOfflineWriter(ctx context.Context, late, gate *offlineClientProcess, binary, target string) {
	result := finishGatedOfflineFresh(ctx, gate, "release")
	check(result.Failure == "", "baseline fresh did not reach rotation after admitting the late writer")
	replacement := startOfflineClient(ctx, binary, target, "replacement-client")
	defer replacement.close()
	newState := offlineSnapshot(target)
	late.write(ctx, 2)
	overwritten := offlineSnapshot(target)
	check(changedOfflineRecords(newState, overwritten), "late client was admitted but the expected production-state overwrite did not occur")
	late.quit(ctx)
	replacement.quit(ctx)
	panic("CONCURRENT_START_REPRODUCED: a writer admitted after the final scan overwrote replacement preferences and drafts through production setters/store")
}

func verifyOfflineObserverAbort(ctx context.Context, binary, home string) {
	current := filepath.Join(home, "Library/Application Support/Mokusei Native Dev")
	previous := current + ".previous"
	seedOfflineProfile(ctx, binary, current, "seed-current")
	seedOfflineProfile(ctx, binary, previous, "seed-previous")
	beforeCurrent, beforePrevious := offlineSnapshot(current), offlineSnapshot(previous)
	gate := startGatedOfflineFresh(ctx, home)
	defer gate.close()
	result := finishGatedOfflineFresh(ctx, gate, "abort")
	check(result.Failure != "" && !result.NativeClient && !result.LeaseBusy, "observer failure was confused with native lease rejection")
	check(sameOfflineSnapshot(beforeCurrent, offlineSnapshot(current)) && sameOfflineSnapshot(beforePrevious, offlineSnapshot(previous)), "failed observer mutated profile data")
	seedOfflineProfile(ctx, binary, current, "after-abort")
	result, err := callOfflineFresh(ctx, home)
	must(err)
	check(result.Failure == "" && result.Previous == previous, "observer failure leaked a maintenance or runtime ownership guard")
}

func killOfflineClient(ctx context.Context, writer *offlineClientProcess) {
	must(writer.command.Process.Kill())
	err := writer.waitExit(ctx)
	var exited *exec.ExitError
	check(errors.As(err, &exited), "SIGKILL fixture did not report a killed process")
	status, ok := exited.ProcessState.Sys().(syscall.WaitStatus)
	check(ok && status.Signaled() && status.Signal() == syscall.SIGKILL, "fixture process did not exit through SIGKILL")
}

func expectOfflineLeaseBusy(directories ...string) {
	entered := false
	err := profile.WithClientMaintenance(directories, func([]profile.Profile) error { entered = true; return nil })
	check(errors.Is(err, profile.ErrClientLeaseBusy) && !entered, fmt.Sprintf("Go exclusive lease did not see the Swift shared owner: %v", err))
}

func verifySharedOfflineClients(ctx context.Context, binary, otherBinary, home string) {
	current := filepath.Join(home, "Library/Application Support/Mokusei Native Dev")
	previous := current + ".previous"
	seedOfflineProfile(ctx, binary, previous, "seed-previous")
	first := startOfflineClient(ctx, binary, current, "first-shared")
	defer first.close()
	// This owner drops its local lease scope before constructing any writer;
	// only the production process registry can keep its shared lock alive.
	second := startOfflineClientWithEnvironment(ctx, otherBinary, []string{"--data-dir", current}, "second-shared",
		append(os.Environ(), "MOKUSEI_OFFLINE_PROCESS_LEASE=1"))
	defer second.close()
	expectOfflineLeaseBusy(current, previous)
	first.write(ctx, 2)
	killOfflineClient(ctx, first)
	second.write(ctx, 2)
	expectOfflineLeaseBusy(current, previous)
	before := offlineSnapshot(current)
	result, err := callOfflineFresh(ctx, home)
	must(err)
	check(result.LeaseBusy && result.NativeClient, "killing one shared owner prematurely released the other native lease")
	killOfflineClient(ctx, second)
	must(profile.WithClientMaintenance([]string{current, previous}, func([]profile.Profile) error { return nil }))
	result, err = callOfflineFresh(ctx, home)
	must(err)
	check(result.Failure == "" && result.Previous == previous && sameOfflineSnapshot(before, offlineSnapshot(previous)), "SIGKILL left a stale native lease or lost the last saved state")
}

func verifyMissingCaseAliasClients(ctx context.Context, binary, otherBinary, home string) {
	parent := filepath.Join(home, "Library/Application Support")
	must(os.MkdirAll(parent, 0700))
	current, alias := filepath.Join(parent, "Mokusei Native Dev"), filepath.Join(parent, "mokusei native dev")
	for _, directory := range []string{current, alias} {
		_, err := os.Lstat(directory)
		check(errors.Is(err, os.ErrNotExist), "case-alias fixture must begin before either profile spelling exists")
	}
	first := startOfflineClient(ctx, binary, alias, "first-case")
	defer first.close()
	firstProfile, err := profile.Resolve(profile.Options{DataDir: alias})
	must(err)
	second := startOfflineClient(ctx, otherBinary, current, "second-case")
	defer second.close()
	secondProfile, err := profile.Resolve(profile.Options{DataDir: current})
	must(err)
	firstLock, err := profile.ClientLeasePath(firstProfile)
	must(err)
	secondLock, err := profile.ClientLeasePath(secondProfile)
	must(err)
	firstInfo, err := os.Stat(alias)
	must(err)
	secondInfo, err := os.Stat(current)
	must(err)
	if os.SameFile(firstInfo, secondInfo) {
		check(firstLock == secondLock, "newly created case aliases selected different native lease identities")
	} else {
		check(firstLock != secondLock, "case-sensitive profiles incorrectly shared one native lease identity")
	}
	expectOfflineLeaseBusy(current)
	first.quit(ctx)
	expectOfflineLeaseBusy(current)
	second.write(ctx, 2)
	second.quit(ctx)
	must(profile.WithClientMaintenance([]string{current, alias}, func([]profile.Profile) error { return nil }))
}

func verifyUnsafeOfflineClientLocks(ctx context.Context, binary, root string) {
	seed := filepath.Join(root, "production seed")
	seedOfflineProfile(ctx, binary, seed, "unsafe-seed")
	records := offlineSnapshot(seed)
	for _, mode := range []string{"symlink", "readable", "hardlink", "unreadable"} {
		home := filepath.Join(root, mode, "home")
		current := filepath.Join(home, "Library/Application Support/Mokusei Native Dev")
		previous := current + ".previous"
		for _, directory := range []string{current, previous} {
			for name, data := range records {
				path := filepath.Join(directory, name)
				must(os.MkdirAll(filepath.Dir(path), 0700))
				must(os.WriteFile(path, data, 0600))
			}
		}
		selected, err := profile.Resolve(profile.Options{DataDir: current})
		must(err)
		lockPath, err := profile.ClientLeasePath(selected)
		must(err)
		_, err = os.Lstat(lockPath)
		check(errors.Is(err, os.ErrNotExist), "unsafe fixture collided with an existing native lease file")
		func() {
			// Only this never-admitted, unique profile file is malformed. The
			// global namespace/admission lock and existing lease files stay intact.
			target := filepath.Join(root, mode, "fixture lock target")
			must(os.WriteFile(target, nil, 0600))
			if mode == "symlink" {
				must(os.Symlink(target, lockPath))
			} else if mode == "hardlink" {
				must(os.Link(target, lockPath))
			} else {
				file, err := os.OpenFile(lockPath, os.O_CREATE|os.O_EXCL|os.O_RDWR, 0600)
				must(err)
				permission := os.FileMode(0644)
				if mode == "unreadable" {
					permission = 0
				}
				must(file.Chmod(permission))
				must(file.Close())
			}
			defer func() { must(os.Remove(lockPath)) }()
			beforeLock, err := os.Lstat(lockPath)
			must(err)
			beforeCurrent, beforePrevious := offlineSnapshot(current), offlineSnapshot(previous)
			writer := launchOfflineClient(ctx, binary, []string{"--data-dir", current}, "unsafe-client", offlineReadEnvironment(os.Environ()))
			defer writer.close()
			code := "UNSAFE_PROFILE_LOCK"
			if mode == "unreadable" {
				code = "PROFILE_LOCK_IO"
			}
			must(writer.expect(ctx, "blocked "+code))
			must(writer.waitExit(ctx))
			result, err := callOfflineFresh(ctx, home)
			must(err)
			check(result.Failure != "" && !result.NativeClient && !result.LeaseBusy, "unsafe lock was accepted or misreported as a live native lease")
			check(sameOfflineSnapshot(beforeCurrent, offlineSnapshot(current)) && sameOfflineSnapshot(beforePrevious, offlineSnapshot(previous)), "unsafe-lock rejection read/wrote or rotated profile records")
			afterLock, err := os.Lstat(lockPath)
			must(err)
			check(os.SameFile(beforeLock, afterLock), "lease validation replaced an unsafe lockfile")
		}()
		seedOfflineProfile(ctx, binary, current, "recovered-client")
	}
}
