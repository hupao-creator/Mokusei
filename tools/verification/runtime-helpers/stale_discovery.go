package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/platform/daemon"
	"github.com/hupao-creator/Mokusei/internal/platform/profile"
	"github.com/hupao-creator/Mokusei/internal/platform/transport"
	"github.com/hupao-creator/Mokusei/tools/verification/swiftfixture"
)

type staleDiscoveryCase struct {
	Path        string `json:"path"`
	Recoverable bool   `json:"recoverable"`
	SwiftCode   string `json:"swiftCode"`
}

func verifyStaleDiscovery(ctx context.Context, directory, executable string) {
	ctx, cancel := context.WithTimeout(ctx, 2*time.Minute)
	defer cancel()
	dead := exec.CommandContext(ctx, "/usr/bin/true")
	must(dead.Run())
	deadPID := dead.Process.Pid
	assert(!profile.IsProcessAlive(deadPID), "reaped fixture PID is still alive")
	cases := []staleDiscoveryCase{}
	for _, response := range []struct {
		name, body, goCode, swiftCode string
		status                        int
	}{
		{"unauthorized", `{"error":{"code":"UNAUTHORIZED","message":"another service"}}`, "UNAUTHORIZED", "UNAUTHORIZED", 401},
		{"stale-epoch", `{"error":{"code":"STALE_EPOCH","message":"another epoch"}}`, "STALE_EPOCH", "STALE_EPOCH", 409},
		{"invalid-json", `not-json`, "RUNTIME_UNREACHABLE", "INVALID_RESPONSE", 200},
		{"foreign-health", `{}`, "IDENTITY_MISMATCH", "IDENTITY_MISMATCH", 200},
	} {
		endpoint := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(response.status)
			_, _ = w.Write([]byte(response.body))
		}))
		defer endpoint.Close()
		for _, alive := range []bool{false, true} {
			p, err := profile.Resolve(profile.Options{DataDir: filepath.Join(directory, fmt.Sprintf("stale-%s-%t", response.name, alive))})
			must(err)
			must(profile.Prepare(p))
			pid := deadPID
			if alive {
				pid = os.Getpid()
			}
			connection := profile.Connection{Port: endpoint.Listener.Addr().(*net.TCPAddr).Port, Token: strings.Repeat("x", 32), Epoch: "stale-owner", ProtocolVersion: transport.ProtocolVersion, PID: pid, DataDir: p.DataDir}
			must(profile.PublishConnection(p, connection))
			current, err := daemon.Status(ctx, p)
			if alive {
				requireDaemonFailure(err, response.goCode)
				_, err = daemon.Ensure(ctx, p, daemon.LaunchOptions{Executable: executable})
				requireDaemonFailure(err, response.goCode)
				requireDaemonFailure(daemon.Stop(ctx, p), response.goCode)
			} else {
				must(err)
				assert(current == nil, "dead discovery owner was reported as running")
				must(daemon.Stop(ctx, p))
				current, err = daemon.Ensure(ctx, p, daemon.LaunchOptions{Executable: executable})
				if current != nil {
					defer func(p profile.Profile) {
						cleanup, stop := context.WithTimeout(context.Background(), 5*time.Second)
						defer stop()
						must(daemon.Stop(cleanup, p))
					}(p)
				}
				must(err)
				assert(current != nil && current.Epoch != connection.Epoch, "dead discovery prevented an explicit restart")
				must(daemon.Stop(ctx, p))
				// Keep the same rejected endpoint alive for the actual Swift client.
				must(profile.PublishConnection(p, connection))
			}
			cases = append(cases, staleDiscoveryCase{Path: p.DataDir, Recoverable: !alive, SwiftCode: response.swiftCode})
		}
	}
	// A dead PID never excuses untrusted local metadata. These errors must stay
	// outside the health-probe recovery path in both implementations.
	for _, unsafe := range []bool{true, false} {
		p, err := profile.Resolve(profile.Options{DataDir: filepath.Join(directory, fmt.Sprintf("invalid-discovery-%t", unsafe))})
		must(err)
		must(profile.Prepare(p))
		connection := profile.Connection{Port: 1, Token: strings.Repeat("x", 32), Epoch: "invalid-metadata", ProtocolVersion: transport.ProtocolVersion, PID: deadPID, DataDir: p.DataDir}
		code := "INVALID_DISCOVERY"
		if !unsafe {
			connection.DataDir = filepath.Join(directory, "another-profile")
		}
		must(profile.PublishConnection(p, connection))
		if unsafe {
			must(os.Chmod(p.DiscoveryPath, 0644))
			code = "UNSAFE_PROFILE"
		}
		_, err = daemon.Status(ctx, p)
		requireDaemonFailure(err, code)
		cases = append(cases, staleDiscoveryCase{Path: p.DataDir, SwiftCode: code})
	}
	verifyCanceledStatus(ctx, directory, deadPID)
	if len(os.Args) > 1 && os.Args[1] == "--swift-shutdown" {
		manifest := filepath.Join(directory, "stale-discovery.json")
		must(profile.WritePrivateJSON(manifest, cases))
		command := swiftfixture.Test(ctx, "--filter", "RuntimeShutdownInteropTests/testStaleDiscoveryRecovery")
		command.Env = append(os.Environ(), "MOKUSEI_STALE_DISCOVERY_CASES="+manifest)
		var output bytes.Buffer
		command.Stdout, command.Stderr = io.MultiWriter(os.Stdout, &output), os.Stderr
		command.WaitDelay = 5 * time.Second
		must(command.Run())
		assert(bytes.Contains(output.Bytes(), []byte(fmt.Sprintf("PASS stale discovery fixtures: %d", len(cases)))), "Swift stale-discovery replay was skipped or did not execute all fixtures")
	}
	fmt.Println("PASS stale discovery: dead-owner typed HTTP/JSON/identity errors recover through restart; live-owner errors and private metadata failures retained; in-flight cancellation preserved")
}

func requireDaemonFailure(err error, code string) {
	var failure *model.Error
	assert(errors.As(err, &failure) && failure.Code == code, fmt.Sprintf("expected %s, got %v", code, err))
}

func verifyCanceledStatus(ctx context.Context, directory string, deadPID int) {
	entered := make(chan struct{}, 2)
	endpoint := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		entered <- struct{}{}
		<-r.Context().Done()
	}))
	defer endpoint.Close()
	for _, pid := range []int{deadPID, os.Getpid()} {
		p, err := profile.Resolve(profile.Options{DataDir: filepath.Join(directory, fmt.Sprintf("cancelled-status-%d", pid))})
		must(err)
		must(profile.Prepare(p))
		must(profile.PublishConnection(p, profile.Connection{Port: endpoint.Listener.Addr().(*net.TCPAddr).Port, Token: strings.Repeat("x", 32), Epoch: "cancelled-status", ProtocolVersion: transport.ProtocolVersion, PID: pid, DataDir: p.DataDir}))
		probe, cancel := context.WithCancel(ctx)
		finished := make(chan error, 1)
		go func() { _, err := daemon.Status(probe, p); finished <- err }()
		select {
		case <-entered:
		case <-ctx.Done():
			cancel()
			panic("cancelled-status fixture did not receive its probe")
		}
		cancel()
		select {
		case err := <-finished:
			assert(errors.Is(err, context.Canceled), "caller cancellation became a stale-owner recovery")
		case <-ctx.Done():
			panic("status ignored caller cancellation")
		}
	}
}
