package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

func nativeReplayExecutable(repo, name string) string {
	path := filepath.Join(repo, "app/macos/.build/debug", name)
	info, err := os.Stat(path)
	if err != nil {
		panic(fmt.Errorf("build current %s with make check before the native-entrypoint replay: %w", name, err))
	}
	check(info.Mode().IsRegular() && info.Mode()&0111 != 0, "native-entrypoint replay requires a built executable: "+path)
	return path
}

// These are the actual Probe and raw application executables. The application's
// --finish-runtime branch returns before WorkspaceApp or any GUI is initialized.
func verifyNativeAdmissionEntryPoints(ctx context.Context, repo, writerBinary, home string) {
	probeBinary, appBinary := nativeReplayExecutable(repo, "MokuseiProbe"), nativeReplayExecutable(repo, "Mokusei")
	current := filepath.Join(home, "Library/Application Support/Mokusei Native Dev")
	previous := current + ".previous"
	seedOfflineProfile(ctx, writerBinary, current, "entrypoint-current")
	seedOfflineProfile(ctx, writerBinary, previous, "entrypoint-previous")
	beforeCurrent, beforePrevious := offlineSnapshot(current), offlineSnapshot(previous)
	gate := startGatedOfflineFresh(ctx, home)
	defer gate.close()
	probeContext, cancelProbe := context.WithTimeout(ctx, 5*time.Second)
	defer cancelProbe()
	probe := exec.CommandContext(probeContext, probeBinary, "--data-dir", current, "--duration", "0")
	probe.WaitDelay = time.Second
	var probeError bytes.Buffer
	probe.Stderr = &probeError
	output, err := probe.Output()
	var exited *exec.ExitError
	check(errors.As(err, &exited) && exited.ExitCode() == 1, fmt.Sprintf("actual Probe did not reject maintenance: %v; %s", err, probeError.String()))
	var report struct {
		OK    bool   `json:"ok"`
		Error string `json:"error"`
	}
	must(json.Unmarshal(output, &report))
	check(!report.OK && strings.Contains(report.Error, "profile is being maintained"), "actual Probe did not report profile-maintenance refusal: "+string(output))
	check(sameOfflineSnapshot(beforeCurrent, offlineSnapshot(current)) && sameOfflineSnapshot(beforePrevious, offlineSnapshot(previous)), "actual Probe changed user records before admission")

	helperContext, cancelHelper := context.WithTimeout(ctx, 10*time.Second)
	defer cancelHelper()
	helper := exec.CommandContext(helperContext, appBinary, "--finish-runtime", current, "old-fixture-epoch")
	helper.WaitDelay = time.Second
	var stdout bytes.Buffer
	helper.Stdout = &stdout
	stderr, err := helper.StderrPipe()
	must(err)
	must(helper.Start())
	type completion struct {
		err            error
		stdout, stderr string
	}
	waiting := make(chan struct{})
	done := make(chan completion, 1)
	const waitMarker = "[native-exit] waiting for profile admission"
	go func() {
		var captured bytes.Buffer
		scanner := bufio.NewScanner(stderr)
		scanner.Buffer(make([]byte, 1024), 16*1024)
		reported := false
		for scanner.Scan() {
			line := scanner.Text()
			captured.WriteString(line + "\n")
			if line == waitMarker && !reported {
				reported = true
				close(waiting)
			}
		}
		waitError := helper.Wait()
		done <- completion{err: errors.Join(scanner.Err(), waitError), stdout: stdout.String(), stderr: captured.String()}
	}()
	stopped := false
	defer func() {
		if !stopped {
			// Only this private helper PID is stopped on a failed assertion.
			_ = helper.Process.Kill()
			<-done
		}
	}()
	acknowledgement := time.NewTimer(5 * time.Second)
	defer acknowledgement.Stop()
	select {
	case <-waiting:
	case result := <-done:
		stopped = true
		panic(fmt.Errorf("actual exit helper did not wait for admission: %v; %s", result.err, result.stderr))
	case <-acknowledgement.C:
		panic("actual exit helper did not acknowledge maintenance within five seconds")
	case <-ctx.Done():
		panic(ctx.Err())
	}
	check(sameOfflineSnapshot(beforeCurrent, offlineSnapshot(current)) && sameOfflineSnapshot(beforePrevious, offlineSnapshot(previous)), "actual exit helper accessed user records while waiting for admission")
	rotation := finishGatedOfflineFresh(ctx, gate, "release")
	check(rotation.Failure == "" && rotation.Previous == previous, fmt.Sprintf("actual-entrypoint rotation failed: %+v", rotation))
	select {
	case result := <-done:
		stopped = true
		check(result.err == nil && result.stdout == "" && !strings.Contains(result.stderr, "admission failed"), fmt.Sprintf("actual exit helper did not finish cleanly after admission: %v; %s", result.err, result.stderr))
	case <-helperContext.Done():
		panic("actual exit helper did not finish after fresh released admission")
	}
	entries, err := os.ReadDir(current)
	must(err)
	check(len(entries) == 0, "actual exit helper wrote old preferences, drafts or diagnostics into the new current profile")
	check(sameOfflineSnapshot(beforeCurrent, offlineSnapshot(previous)), "actual exit helper changed the retired current profile")
	fmt.Println("PASS actual native entrypoints: Probe refuses before state access; headless exit helper waits without a lease, resumes after fresh and leaves new current empty")
}
