package main

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/platform/daemon"
	"github.com/hupao-creator/Mokusei/internal/platform/profile"
	"github.com/hupao-creator/Mokusei/tools/verification/swiftfixture"
)

func verifyFailedShutdown(ctx context.Context, directory, executable string) {
	modes := []string{"go"}
	if len(os.Args) > 1 && os.Args[1] == "--swift-shutdown" {
		modes = append(modes, "swift")
	}
	for _, mode := range modes {
		verifyShutdownRecovery(ctx, directory, executable, mode)
	}
}

func verifyShutdownRecovery(ctx context.Context, directory, executable, mode string) {
	ctx, cancel := context.WithTimeout(ctx, 120*time.Second)
	defer cancel()
	p, err := profile.Resolve(profile.Options{DataDir: filepath.Join(directory, "failed-shutdown-"+mode)})
	must(err)
	gate := filepath.Join(directory, "close-gate-"+mode)
	c, err := daemon.Ensure(ctx, p, daemon.LaunchOptions{Executable: executable,
		Environment: append(os.Environ(), "MOKUSEI_HELPER_FAIL_CLOSE=1", "MOKUSEI_HELPER_CLOSE_GATE="+gate)})
	must(err)
	defer func() {
		_ = os.WriteFile(gate+".release", nil, 0600)
		cleanup, done := context.WithTimeout(context.Background(), 10*time.Second)
		defer done()
		_ = daemon.Stop(cleanup, p)
	}()
	// Existing profile data must survive retirement and the new owner.
	marker := filepath.Join(p.DataDir, "retained-draft")
	must(os.WriteFile(marker, []byte("keep my work"), 0600))
	stopped := make(chan error, 1)
	go func() { stopped <- daemon.Stop(ctx, p) }()
	deadline := time.Now().Add(5 * time.Second)
	for {
		if _, err := os.Stat(gate + ".started"); err == nil {
			break
		}
		assert(time.Now().Before(deadline), "shutdown did not reach cleanup gate")
		time.Sleep(5 * time.Millisecond)
	}
	_, err = daemon.Status(ctx, p)
	var pending *model.Error
	assert(errors.As(err, &pending) && pending.Code == "SERVICE_STOPPING", "pending shutdown did not revoke admission")
	other, err := profile.Acquire(p)
	if other != nil {
		_ = other.Release()
	}
	assert(err != nil, "pending cleanup allowed a second writer")
	verifyShutdownCommand(ctx, *c, http.StatusServiceUnavailable)

	if mode == "swift" {
		command := swiftfixture.Test(ctx, "--filter", "RuntimeShutdownInteropTests.testReopenAfterFailedShutdown")
		command.Env = append(os.Environ(), "MOKUSEI_SHUTDOWN_PROFILE="+p.DataDir,
			"MOKUSEI_SHUTDOWN_RUNTIME="+executable, "MOKUSEI_SHUTDOWN_GATE="+gate)
		command.Stdout, command.Stderr = os.Stdout, os.Stderr
		must(command.Run())
	} else {
		type result struct {
			connection *profile.Connection
			err        error
		}
		restarted := make(chan result, 1)
		go func() {
			connection, err := daemon.Ensure(ctx, p, daemon.LaunchOptions{Executable: executable})
			restarted <- result{connection, err}
		}()
		select {
		case outcome := <-restarted:
			panic(fmt.Sprintf("reopen did not wait for retiring owner: %+v", outcome))
		case <-time.After(150 * time.Millisecond):
		}
		must(os.WriteFile(gate+".release", nil, 0600))
		outcome := <-restarted
		must(outcome.err)
		assert(outcome.connection != nil && outcome.connection.Epoch != c.Epoch, "reopen reused the stopped owner")
	}
	select {
	case err := <-stopped:
		var failure *model.Error
		assert(errors.As(err, &failure) && failure.Code == "SHUTDOWN_FAILED" &&
			strings.Contains(failure.Message, "fixture durable flush failure"), "cleanup failure diagnostic was lost")
	case <-ctx.Done():
		panic("shutdown never completed")
	}
	replacement, err := daemon.Status(ctx, p)
	must(err)
	assert(replacement != nil && replacement.Epoch != c.Epoch, "replacement runtime is unavailable")
	verifyShutdownCommand(ctx, *replacement, http.StatusOK)
	data, err := os.ReadFile(marker)
	must(err)
	assert(string(data) == "keep my work", "reopening reset profile data")
	log, err := os.ReadFile(filepath.Join(p.DataDir, "runtime", "process.log"))
	must(err)
	assert(strings.Contains(string(log), "fixture durable flush failure"), "cleanup diagnostic missing")
	deadline = time.Now().Add(5 * time.Second)
	for profile.IsProcessAlive(c.PID) {
		assert(time.Now().Before(deadline), "retired daemon remained alive after cleanup failure")
		time.Sleep(10 * time.Millisecond)
	}
	must(daemon.Stop(ctx, p))
	must(daemon.Stop(ctx, p))
	live, err := profile.HasLiveOwner(p)
	must(err)
	assert(!live, "replacement failed to release profile")
}

func verifyShutdownCommand(ctx context.Context, c profile.Connection, status int) {
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, "http://127.0.0.1:"+fmt.Sprint(c.Port)+"/invoke/state:load", strings.NewReader(`{"commandId":"shutdown-recovery-command","args":[]}`))
	must(err)
	request.Header.Set("Authorization", "Bearer "+c.Token)
	request.Header.Set("X-Mokusei-Protocol", fmt.Sprint(c.ProtocolVersion))
	request.Header.Set("X-Mokusei-Epoch", c.Epoch)
	client := &http.Client{Timeout: 3 * time.Second}
	defer client.CloseIdleConnections()
	response, err := client.Do(request)
	must(err)
	must(response.Body.Close())
	assert(response.StatusCode == status, "unexpected command admission during shutdown/reopen")
}
