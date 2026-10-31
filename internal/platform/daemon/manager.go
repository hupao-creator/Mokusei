// Package daemon manages the independent runtime process. A disconnected UI or
// launcher is not permission to stop accepted work in the service.
package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/hupao-creator/Mokusei/internal/core/model"
	"github.com/hupao-creator/Mokusei/internal/platform/profile"
	"github.com/hupao-creator/Mokusei/internal/platform/transport"
)

func request(ctx context.Context, connection profile.Connection, method, path string, target any) error {
	req, err := http.NewRequestWithContext(ctx, method, fmt.Sprintf("http://127.0.0.1:%d%s", connection.Port, path), nil)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+connection.Token)
	req.Header.Set("X-Mokusei-Protocol", strconv.Itoa(transport.ProtocolVersion))
	req.Header.Set("X-Mokusei-Epoch", connection.Epoch)
	// Local authority must never follow redirects or environment proxies.
	client := &http.Client{Transport: &http.Transport{Proxy: nil, DisableKeepAlives: true}, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	defer client.CloseIdleConnections()
	response, err := client.Do(req)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	data, err := io.ReadAll(io.LimitReader(response.Body, 1024*1024+1))
	if err != nil {
		return err
	}
	if len(data) > 1024*1024 {
		return model.NewError("RESPONSE_TOO_LARGE", "Runtime management response exceeds its size limit")
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		var failure struct {
			Error *model.Error `json:"error"`
		}
		if json.Unmarshal(data, &failure) == nil && failure.Error != nil {
			return failure.Error
		}
		return fmt.Errorf("runtime management HTTP %d", response.StatusCode)
	}
	if target != nil {
		return json.Unmarshal(data, target)
	}
	return nil
}

func Status(ctx context.Context, p profile.Profile) (*profile.Connection, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	p, err := profile.Refresh(p)
	if err != nil {
		return nil, err
	}
	connection, err := profile.ReadConnection(p)
	if err != nil || connection == nil {
		return connection, err
	}
	if connection.ProtocolVersion != transport.ProtocolVersion {
		if !profile.IsProcessAlive(connection.PID) {
			return nil, nil
		}
		return nil, model.NewError("PROTOCOL_MISMATCH", "A live runtime uses a different protocol; stop it with its matching client first")
	}
	probe, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	var health struct {
		profile.Connection
		Status string `json:"status"`
	}
	err = request(probe, *connection, http.MethodGet, "/health", &health)
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}
	if err == nil {
		switch {
		case health.Epoch != connection.Epoch || health.DataDir != p.DataDir || health.PID != connection.PID || health.ProtocolVersion != transport.ProtocolVersion:
			err = model.NewError("IDENTITY_MISMATCH", "Runtime identity does not match this profile")
		case health.Status == "stopping":
			err = model.NewError("SERVICE_STOPPING", "Runtime is stopping")
		case health.Status != "running":
			err = model.NewError("INVALID_STATUS", "Runtime returned an unknown lifecycle status")
		}
	}
	if err != nil {
		// Cleanup can retire discovery between this probe and its response.
		// The old PID may still be flushing /stop; it no longer owns discovery.
		current, readErr := profile.ReadConnection(p)
		if readErr != nil {
			return nil, readErr
		}
		if current == nil || current.Epoch != connection.Epoch {
			return nil, nil
		}
		// A dead owner's port can belong to an unrelated HTTP service now.
		// Its typed rejection is not evidence that this profile is still owned.
		if !profile.IsProcessAlive(connection.PID) {
			return nil, nil
		}
		var public *model.Error
		if errors.As(err, &public) {
			return nil, err
		}
		return nil, model.NewError("RUNTIME_UNREACHABLE", "The profile owner is alive but its runtime API is unavailable")
	}
	return connection, nil
}

type LaunchOptions struct {
	Executable  string
	Directory   string
	Environment []string
}

func Ensure(ctx context.Context, p profile.Profile, options LaunchOptions) (*profile.Connection, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if err := profile.Prepare(p); err != nil {
		return nil, err
	}
	p, err := profile.Refresh(p)
	if err != nil {
		return nil, err
	}
	retirementDeadline := time.Now().Add(2 * time.Minute)
	for {
		connection, err := Status(ctx, p)
		var failure *model.Error
		if !errors.As(err, &failure) || failure.Code != "SERVICE_STOPPING" {
			if err != nil || connection != nil {
				return connection, err
			}
			break
		}
		if time.Now().After(retirementDeadline) {
			return nil, model.NewError("STARTUP_TIMEOUT", "Previous runtime has not finished stopping")
		}
		if err := delay(ctx, 100*time.Millisecond); err != nil {
			return nil, err
		}
	}
	executable := options.Executable
	if executable == "" {
		var err error
		executable, err = os.Executable()
		if err != nil {
			return nil, err
		}
	}
	command := exec.Command(executable, "serve", "--data-dir", p.DataDir)
	command.Dir = options.Directory
	command.Env = options.Environment
	if command.Env == nil {
		command.Env = os.Environ()
	}
	command.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	launchRead, launchWrite, err := os.Pipe()
	if err != nil {
		return nil, err
	}
	defer launchRead.Close()
	defer launchWrite.Close()
	command.ExtraFiles = []*os.File{launchRead}
	command.Env = append(command.Env, "MOKUSEI_LAUNCH_FD=3")
	// Startup errors are persisted independently by the service. Keep only a
	// bounded launcher diagnostic file, not a pipe that ties it to the launcher.
	logPath := filepath.Join(filepath.Dir(p.DiscoveryPath), "process.log")
	if info, err := os.Stat(logPath); err == nil && info.Size() > 8*1024*1024 {
		if err = os.Rename(logPath, logPath+".previous"); err != nil {
			return nil, err
		}
	}
	log, err := os.OpenFile(logPath, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600)
	if err != nil {
		return nil, err
	}
	command.Stdout = log
	command.Stderr = log
	if err = command.Start(); err != nil {
		log.Close()
		return nil, model.NewError("LAUNCH_FAILED", err.Error())
	}
	_ = launchRead.Close()
	_ = log.Close()
	exited := make(chan error, 1)
	go func() { exited <- command.Wait() }()
	// A timed-out launcher must leave evidence of its still-live child. Stop
	// waits for these launches as well as an acquired profile owner, so cleanup
	// cannot mistake a slow pre-acquisition child for a fully stopped service.
	launchPath := filepath.Join(filepath.Dir(p.DiscoveryPath), fmt.Sprintf("launch-%d.json", command.Process.Pid))
	if err := profile.WritePrivateJSON(launchPath, struct {
		PID     int    `json:"pid"`
		DataDir string `json:"dataDir"`
	}{command.Process.Pid, p.DataDir}); err != nil {
		// EOF rejects the child before it opens a profile. Reap it before the
		// caller may clean its temporary directory.
		_ = launchWrite.Close()
		<-exited
		return nil, err
	}
	settled := false
	defer func() {
		if settled {
			_ = os.Remove(launchPath)
		}
	}()
	if _, err = launchWrite.Write([]byte{1}); err != nil {
		_ = launchWrite.Close()
		<-exited
		settled = true
		return nil, model.NewError("LAUNCH_FAILED", "Runtime rejected its startup handoff")
	}
	_ = launchWrite.Close()
	startup, cancelStartup := context.WithTimeout(context.WithoutCancel(ctx), 2*time.Minute)
	defer cancelStartup()
	tick := time.NewTicker(100 * time.Millisecond)
	defer tick.Stop()
	childExited := false
	for {
		// Once spawned, settle ownership before observing launcher cancellation.
		// Otherwise Stop could see no owner and a late child could recreate a
		// profile after its caller had already removed the temporary directory.
		connection, err := Status(startup, p)
		if err != nil {
			return nil, err
		}
		if connection != nil && (connection.PID == command.Process.Pid || childExited) {
			settled = true
			return connection, ctx.Err()
		}
		if childExited {
			// A competing Ensure child can own the guard before publishing the
			// owner record. Read its handoff before owner metadata so a successful
			// competitor cannot retire its receipt between two negative reads.
			pending, err := hasPendingLaunch(p)
			if err != nil {
				return nil, err
			}
			live, err := profile.HasLiveOwner(p)
			if err != nil {
				return nil, err
			}
			if !pending && !live {
				if ctx.Err() != nil {
					return nil, ctx.Err()
				}
				return nil, model.NewError("LAUNCH_FAILED", "Runtime exited before becoming ready; inspect "+profile.StartupErrorPath(p))
			}
		}
		select {
		case <-startup.Done():
			return nil, model.NewError("STARTUP_TIMEOUT", "Runtime did not become ready within two minutes; no process was terminated")
		case <-tick.C:
		case <-exited:
			childExited = true
			settled = true
		}
	}
}

func Stop(ctx context.Context, p profile.Profile) error {
	deadline := time.Now().Add(30 * time.Second)
	var connection *profile.Connection
	for {
		var err error
		p, err = profile.Refresh(p)
		if err != nil {
			return err
		}
		connection, err = Status(ctx, p)
		if err != nil {
			var public *model.Error
			if !errors.As(err, &public) || public.Code != "SERVICE_STOPPING" {
				return err
			}
			connection, err = profile.ReadConnection(p)
			if err != nil {
				return err
			}
		}
		if connection != nil {
			break
		}
		live, err := profile.HasLiveOwner(p)
		if err != nil {
			return err
		}
		pending, pendingErr := hasPendingLaunch(p)
		if pendingErr != nil {
			return pendingErr
		}
		if !live && !pending {
			return nil
		}
		if time.Now().After(deadline) {
			return model.NewError("STOP_TIMEOUT", "The profile owner has not become reachable or released ownership; no process was terminated")
		}
		if err = delay(ctx, 100*time.Millisecond); err != nil {
			return err
		}
	}
	stopContext, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	var result struct {
		OK    bool         `json:"ok"`
		Error *model.Error `json:"error,omitempty"`
	}
	if err := request(stopContext, *connection, http.MethodPost, "/stop", &result); err != nil {
		return err
	}
	if !result.OK {
		if result.Error != nil {
			return result.Error
		}
		return errors.New("runtime did not confirm shutdown")
	}
	deadline = time.Now().Add(30 * time.Second)
	for time.Now().Before(deadline) {
		current, err := profile.ReadConnection(p)
		if err != nil {
			return err
		}
		if current != nil && current.Epoch != connection.Epoch {
			return model.NewError("STOP_SUPERSEDED", "A different runtime generation now owns the profile; preserve its data")
		}
		if current == nil || !profile.IsProcessAlive(current.PID) {
			pending, err := hasPendingLaunch(p)
			if err != nil {
				return err
			}
			if !pending {
				return nil
			}
		}
		if err = delay(ctx, 100*time.Millisecond); err != nil {
			return err
		}
	}
	return model.NewError("STOP_TIMEOUT", "Runtime shutdown is still in progress; no process was forcibly terminated")
}

// AwaitLaunch must precede profile acquisition in the serve entry point. Direct
// foreground launches have no handoff; detached children start only after their
// launcher has persisted an identity that Stop can wait for.
func AwaitLaunch() error {
	value := os.Getenv("MOKUSEI_LAUNCH_FD")
	if value == "" {
		return nil
	}
	_ = os.Unsetenv("MOKUSEI_LAUNCH_FD")
	if value != "3" {
		return errors.New("invalid runtime startup handoff")
	}
	file := os.NewFile(3, "mokusei-launch")
	if file == nil {
		return errors.New("runtime startup handoff unavailable")
	}
	defer file.Close()
	var token [1]byte
	if _, err := io.ReadFull(file, token[:]); err != nil || token[0] != 1 {
		return errors.New("runtime launcher withdrew startup")
	}
	return nil
}

func hasPendingLaunch(p profile.Profile) (bool, error) {
	entries, err := os.ReadDir(filepath.Dir(p.DiscoveryPath))
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	for _, entry := range entries {
		name := entry.Name()
		if !strings.HasPrefix(name, "launch-") || !strings.HasSuffix(name, ".json") {
			continue
		}
		pid, err := strconv.Atoi(strings.TrimSuffix(strings.TrimPrefix(name, "launch-"), ".json"))
		if err != nil || pid <= 0 {
			return false, errors.New("invalid runtime launch metadata")
		}
		path := filepath.Join(filepath.Dir(p.DiscoveryPath), name)
		var launch struct {
			PID     int    `json:"pid"`
			DataDir string `json:"dataDir"`
		}
		if err = profile.ReadPrivateJSON(path, &launch); errors.Is(err, os.ErrNotExist) {
			continue
		} else if err != nil {
			return false, err
		}
		if launch.PID != pid || launch.DataDir != p.DataDir {
			return false, errors.New("runtime launch metadata belongs to another identity")
		}
		if profile.IsProcessAlive(pid) {
			return true, nil
		}
		if err = os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
			return false, err
		}
	}
	return false, nil
}

func delay(ctx context.Context, d time.Duration) error {
	timer := time.NewTimer(d)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}
