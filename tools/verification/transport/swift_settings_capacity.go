package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/hupao-creator/Mokusei/internal/platform/profile"
	"github.com/hupao-creator/Mokusei/internal/platform/transport"
)

// Only native discovery is a fixture. Authentication, request slots, read
// cancellation, stream hydration and the Swift client are production code.
type settingsCapacityHost struct {
	*mockHost
	settingsMu                           sync.Mutex
	active, maximum, completed, obsolete int
	blocked, cancelled                   int
	perHarness                           map[string]int
	maximumPerHarness                    int
	coldReady                            chan struct{}
	coldOnce                             sync.Once
}

func (*settingsCapacityHost) HasChannel(channel string) bool {
	return channel == "state:load" || channel == "application:query" || channel == "harness:settings-presentation" || channel == "harness:detect-installation" || channel == "settings:diagnostics"
}

func (h *settingsCapacityHost) Invoke(ctx context.Context, channel string, args []json.RawMessage) (any, error) {
	if channel == "state:load" {
		return json.RawMessage(`{"revision":1,"defaultCwd":"","threads":[],"executions":[],"applicationThreads":[],"settings":{},"settingsRevision":1}`), nil
	}
	if channel == "settings:diagnostics" {
		return nil, nil
	}
	if channel == "application:query" {
		h.settingsMu.Lock()
		defer h.settingsMu.Unlock()
		return map[string]any{"maximum": h.maximum, "maximumPerHarness": h.maximumPerHarness, "coldCompleted": h.completed, "obsolete": h.obsolete, "blocked": h.blocked, "cancelled": h.cancelled}, nil
	}
	var request struct{ HarnessID, Owner, Phase string }
	var installation string
	if channel == "harness:detect-installation" {
		if err := json.Unmarshal(args[0], &installation); err != nil {
			return nil, err
		}
		request.Phase = "cold"
		if strings.HasPrefix(installation, "blocked-") {
			request.Phase = "blocked"
		}
	} else if err := json.Unmarshal(args[0], &request); err != nil {
		return nil, err
	}
	key := request.HarnessID
	if installation != "" {
		key = installation
	}
	h.settingsMu.Lock()
	h.active++
	h.maximum = max(h.maximum, h.active)
	h.perHarness[key]++
	h.maximumPerHarness = max(h.maximumPerHarness, h.perHarness[key])
	if request.Phase == "obsolete" {
		h.obsolete++
	}
	if request.Phase == "blocked" {
		h.blocked++
	}
	h.settingsMu.Unlock()
	defer func() {
		h.settingsMu.Lock()
		h.active--
		h.perHarness[key]--
		h.settingsMu.Unlock()
	}()
	if request.Phase == "cold" {
		h.coldOnce.Do(func() { time.AfterFunc(6*time.Second, func() { close(h.coldReady) }) })
		select {
		case <-h.coldReady:
		case <-ctx.Done():
			return nil, ctx.Err()
		}
		h.settingsMu.Lock()
		h.completed++
		h.settingsMu.Unlock()
	}
	if request.Phase == "blocked" {
		<-ctx.Done()
		h.settingsMu.Lock()
		h.cancelled++
		h.settingsMu.Unlock()
		return nil, ctx.Err()
	}
	return map[string]any{"harnessId": request.HarnessID, "phase": request.Phase}, nil
}

func verifySwiftSettingsCapacity() (failure error) {
	directory, err := os.MkdirTemp("", "mokusei-swift-settings-capacity-")
	if err != nil {
		return err
	}
	defer func() { failure = errors.Join(failure, os.RemoveAll(directory)) }()
	p, err := profile.Resolve(profile.Options{DataDir: filepath.Join(directory, "data"), HomeDir: directory})
	if err != nil {
		return err
	}
	owner, err := profile.Acquire(p)
	if err != nil {
		return err
	}
	defer func() { failure = errors.Join(failure, owner.Release()) }()
	host := &settingsCapacityHost{mockHost: newMockHost(), coldReady: make(chan struct{}), perHarness: map[string]int{}}
	server, err := transport.Start(transport.Options{Profile: p, Epoch: owner.Epoch, Host: host})
	if err != nil {
		return err
	}
	defer func() {
		cleanup, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		failure = errors.Join(failure, server.Close(cleanup), server.Drain(cleanup), server.Finish(cleanup))
	}()
	if err = profile.PublishConnection(p, server.Connection); err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()
	command := exec.CommandContext(ctx, "/usr/bin/xcrun", "swift", "test", "--package-path", "app/macos", "--no-parallel", "--filter", "RuntimeSettingsCapacityInteropTests")
	command.Env = append(os.Environ(), "MOKUSEI_SWIFT_SETTINGS_PROFILE="+p.DataDir)
	var output bytes.Buffer
	command.Stdout = io.MultiWriter(os.Stdout, &output)
	command.Stderr = os.Stderr
	command.WaitDelay = 5 * time.Second
	if err = command.Run(); err != nil {
		return err
	}
	if !bytes.Contains(output.Bytes(), []byte("PASS native cold settings capacity and cancellation")) {
		return errors.New("native settings capacity verification was skipped")
	}
	fmt.Println("PASS Go/Swift cold settings: 20 slow reads, responsive commands, queued and active cancellation, no capacity increase")
	return nil
}
