package devtool

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/hupao-creator/Mokusei/internal/platform/profile"
)

// FreshDevelopmentData rotates the development data directory aside so the
// next launch starts with an empty database, settings and runtime metadata.
// The previous directory is kept next to it as "<name>.previous".
func FreshDevelopmentData() (string, error) {
	return FreshDevelopmentDataWithObserver(nil)
}

// FreshDevelopmentDataWithObserver observes the same production rotation after
// its final writer scan and before its first directory mutation. All admission,
// client and runtime guards remain held. The observer must not mutate profile
// data; returning an error aborts rotation and releases every guard.
func FreshDevelopmentDataWithObserver(beforeRotation func() error) (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	product, err := ProductConfiguration("development")
	if err != nil {
		return "", err
	}
	return rotateDevelopmentDataWithObserver(filepath.Join(home, "Library/Application Support", product.DataDirectoryName), beforeRotation)
}

func rotateDevelopmentData(directory string) (string, error) {
	return rotateDevelopmentDataWithObserver(directory, nil)
}

func rotateDevelopmentDataWithObserver(directory string, beforeRotation func() error) (string, error) {
	previous := directory + ".previous"
	rotated := false
	err := profile.WithClientMaintenance([]string{directory, previous}, func(profiles []profile.Profile) error {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := rejectNativeClientWriters(ctx, directory, previous); err != nil {
			return err
		}
		if _, err := os.Lstat(directory); err != nil {
			if errors.Is(err, os.ErrNotExist) {
				return nil
			}
			return err
		}
		p, backup := profiles[0], profiles[1]
		beforeMutation := func() error {
			if err := rejectNativeClientWriters(ctx, directory, previous); err != nil {
				return err
			}
			if beforeRotation != nil {
				return beforeRotation()
			}
			return nil
		}
		rename := func() error {
			if err := os.Rename(directory, previous); err != nil {
				return fmt.Errorf("rotate development data: %w", err)
			}
			rotated = true
			return nil
		}
		return withFreshRuntimeGuard(p, func() error {
			if _, err := os.Lstat(previous); errors.Is(err, os.ErrNotExist) {
				// Runtime startup also prepares directories before ownership.
				// Rename cannot replace its populated metadata directory; never
				// RemoveAll a destination that appeared after this missing check.
				if err := beforeMutation(); err != nil {
					return err
				}
				return rename()
			} else if err != nil {
				return err
			}
			replace := func() error {
				if err := beforeMutation(); err != nil {
					return err
				}
				if err := os.RemoveAll(previous); err != nil {
					return fmt.Errorf("remove previous development data: %w", err)
				}
				return rename()
			}
			if backup.DataDir == p.DataDir {
				// Two selected symlinks can name the same guarded profile.
				return replace()
			}
			return withFreshRuntimeGuard(backup, replace)
		})
	})
	if errors.Is(err, profile.ErrClientLeaseBusy) {
		err = fmt.Errorf("%w: %w", ErrNativeClientRunning, err)
	}
	if err != nil {
		return "", err
	}
	if !rotated {
		return "", nil
	}
	return previous, nil
}

func withFreshRuntimeGuard(p profile.Profile, operation func() error) error {
	entered := false
	err := profile.WithExclusiveAccess(p, func() error {
		entered = true
		return operation()
	})
	if !entered && err != nil {
		return fmt.Errorf("cannot obtain exclusive access to development profile %q (ownership port %d); if the profile is in use, quit its clients and stop its runtime with ./scripts/go.sh run ./cmd/mokusei-runtime stop --data-dir %q; if shutdown fails, inspect runtime/process.log under this profile: %w", p.DataDir, profile.GuardPort(p), p.DataDir, err)
	}
	return err
}

// LaunchDevelopment observes LaunchServices startup using logs outside TCC-protected checkouts.
// Only its temporary `open -W` observer is stopped; the application remains running.
func LaunchDevelopment(ctx context.Context, application string) (int, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return 0, err
	}
	root := filepath.Join(home, "Library/Logs/Mokusei Native Dev")
	if err = os.MkdirAll(root, 0700); err != nil {
		return 0, err
	}
	directory, err := os.MkdirTemp(root, "launch-")
	if err != nil {
		return 0, err
	}
	stdout, stderr := filepath.Join(directory, "stdout.log"), filepath.Join(directory, "stderr.log")
	for _, path := range []string{stdout, stderr} {
		if err = os.WriteFile(path, nil, 0600); err != nil {
			return 0, err
		}
	}
	cmd := exec.Command("/usr/bin/open", "-n", "-W", "--stdout", stdout, "--stderr", stderr, application)
	var diagnostics bytes.Buffer
	cmd.Stderr = &diagnostics
	if err = cmd.Start(); err != nil {
		return 0, err
	}
	exited := make(chan error, 1)
	go func() { exited <- cmd.Wait() }()
	reaped := false
	defer func() {
		if !reaped {
			_ = cmd.Process.Signal(syscall.SIGTERM)
			<-exited
		}
	}()
	ready := regexp.MustCompile(`(?m)^\[native-launch\] ready pid=(\d+)$`)
	deadline := time.NewTimer(30 * time.Second)
	defer deadline.Stop()
	ticker := time.NewTicker(100 * time.Millisecond)
	defer ticker.Stop()
	var pid int
	var readyAt time.Time
	failure := func(reason string) (int, error) {
		details, _ := os.ReadFile(stderr)
		return 0, fmt.Errorf("%s\nLaunch logs: %s\n%s", reason, directory, strings.TrimSpace(string(details)))
	}
	for {
		select {
		case <-ctx.Done():
			return failure("native application launch interrupted")
		case err := <-exited:
			reaped = true
			return failure(fmt.Sprintf("native application exited during startup (%v): %s", err, diagnostics.String()))
		case <-deadline.C:
			return failure("native application did not finish startup within 30 seconds")
		case <-ticker.C:
			if pid == 0 {
				data, _ := os.ReadFile(stdout)
				if m := ready.FindSubmatch(data); len(m) > 0 {
					pid, _ = strconv.Atoi(string(m[1]))
					readyAt = time.Now()
				}
			}
			if pid > 1 {
				if syscall.Kill(pid, 0) != nil {
					return failure(fmt.Sprintf("native application %d exited during startup", pid))
				}
				if time.Since(readyAt) >= 3*time.Second {
					fmt.Printf("Native application running (PID %d); launch logs: %s\n", pid, directory)
					return pid, nil
				}
			}
		}
	}
}
func applicationRunning(ctx context.Context, application string) (bool, error) {
	out, err := run(ctx, "", nil, "/bin/ps", "-axo", "command=")
	if err != nil {
		return false, err
	}
	binaries := []string{filepath.Join(application, "Contents/MacOS/Mokusei")}
	if canonical, err := filepath.EvalSymlinks(application); err == nil {
		binaries = append(binaries, filepath.Join(canonical, "Contents/MacOS/Mokusei"))
	}
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimSpace(line)
		for _, binary := range binaries {
			if line == binary || strings.HasPrefix(line, binary+" ") {
				return true, nil
			}
		}
	}
	return false, nil
}

// Install never quits a running app. The private candidate is verified before replacement.
func Install(ctx context.Context, source, destination string) (string, error) {
	product, _ := ProductConfiguration("production")
	source, err := filepath.Abs(source)
	if err != nil {
		return "", err
	}
	destination, err = filepath.Abs(destination)
	if err != nil {
		return "", err
	}
	if filepath.Base(destination) != product.AppName {
		return "", fmt.Errorf("installation destination must end with %s", product.AppName)
	}
	running, err := applicationRunning(ctx, destination)
	if err != nil {
		return "", err
	}
	if running {
		return "", fmt.Errorf("quit the installed application before replacing it: %s", destination)
	}
	if _, err = VerifySignature(ctx, source, product.BundleIdentifier, ""); err != nil {
		return "", err
	}
	parent := filepath.Dir(destination)
	if err = os.MkdirAll(parent, 0755); err != nil {
		return "", err
	}
	staging, err := os.MkdirTemp(parent, ".mokusei-install-")
	if err != nil {
		return "", err
	}
	// Retain a previous install if rollback fails, rather than deleting the only recoverable copy.
	cleanup := true
	defer func() {
		if cleanup {
			_ = os.RemoveAll(staging)
		}
	}()
	candidate, previous := filepath.Join(staging, product.AppName), filepath.Join(staging, "previous.app")
	if _, err = run(ctx, "", nil, "/usr/bin/ditto", source, candidate); err != nil {
		return "", err
	}
	if _, err = VerifySignature(ctx, candidate, product.BundleIdentifier, ""); err != nil {
		return "", err
	}
	running, err = applicationRunning(ctx, destination)
	if err != nil {
		return "", err
	}
	if running {
		return "", fmt.Errorf("application started during installation; retry after quitting: %s", destination)
	}
	moved := exists(destination)
	if moved {
		if err = os.Rename(destination, previous); err != nil {
			return "", err
		}
	}
	if err = os.Rename(candidate, destination); err != nil {
		if moved {
			if rollbackErr := os.Rename(previous, destination); rollbackErr != nil {
				cleanup = false
				return "", fmt.Errorf("install failed: %v; rollback failed: %v; retained previous app at %s", err, rollbackErr, previous)
			}
		}
		return "", err
	}
	return destination, nil
}
