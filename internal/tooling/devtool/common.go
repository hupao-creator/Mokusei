// Package devtool provides the native application's Go-only development and distribution tools.
package devtool

import (
	"bytes"
	"context"
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

	"github.com/hupao-creator/Mokusei/internal/platform/processgroup"
)

type Product struct{ Channel, BundleIdentifier, AppName, DisplayName, DataDirectoryName string }

func ProductConfiguration(channel string) (Product, error) {
	switch channel {
	case "development":
		return Product{channel, "com.mokusei.native.dev", "Mokusei Native Dev.app", "Mokusei Native Dev", "Mokusei Native Dev"}, nil
	case "production":
		return Product{channel, "com.mokusei.desktop", "Mokusei.app", "Mokusei", "Mokusei"}, nil
	default:
		return Product{}, fmt.Errorf("unknown application channel %q", channel)
	}
}
func Repository(start string) (string, error) {
	path, err := filepath.Abs(start)
	if err != nil {
		return "", err
	}
	for {
		if exists(filepath.Join(path, "go.mod")) && exists(filepath.Join(path, "app/macos/Package.swift")) {
			return path, nil
		}
		parent := filepath.Dir(path)
		if parent == path {
			return "", fmt.Errorf("run mokusei-dev from a Mokusei checkout or pass --repo")
		}
		path = parent
	}
}
func exists(path string) bool { _, err := os.Stat(path); return err == nil }
func run(ctx context.Context, dir string, env []string, name string, args ...string) (string, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Dir = dir
	cmd.Env = env
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err := runCommand(ctx, cmd, false)
	if err != nil {
		return stdout.String(), fmt.Errorf("%s %s: %w\n%s", name, strings.Join(args, " "), err, strings.TrimSpace(stderr.String()))
	}
	return stdout.String(), nil
}
func runVisible(ctx context.Context, dir string, env []string, name string, args ...string) error {
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Dir = dir
	cmd.Env = env
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := runCommand(ctx, cmd, false); err != nil {
		return fmt.Errorf("%s: %w", name, err)
	}
	return nil
}

func runCommand(ctx context.Context, cmd *exec.Cmd, cooperativeTool bool) error {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error {
		err := syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM)
		if errors.Is(err, syscall.ESRCH) {
			return os.ErrProcessDone
		}
		return err
	}
	if !cooperativeTool {
		cmd.WaitDelay = 2 * time.Second
	}
	if err := cmd.Start(); err != nil {
		return err
	}
	// A nested development tool owns its own compiler groups and build lease.
	// Its signal handler joins those groups before exiting; killing the tool on
	// a timer would abandon that cleanup. Ordinary finite commands are bounded
	// by WaitDelay, including pipes retained by descendants after leader exit.
	waitErr := cmd.Wait()
	return errors.Join(waitErr, processgroup.DrainAfterExit(cmd.Process.Pid), ctx.Err())
}
func copyFile(src, dst string, mode os.FileMode) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(dst, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, mode)
	if err != nil {
		return err
	}
	_, copyErr := io.Copy(out, in)
	closeErr := out.Close()
	if copyErr != nil {
		return copyErr
	}
	if closeErr != nil {
		return closeErr
	}
	return os.Chmod(dst, mode)
}
func ProductionEnvironment() []string {
	env := []string{"PATH=/usr/bin:/bin:/usr/sbin:/sbin"}
	for _, entry := range os.Environ() {
		key, _, _ := strings.Cut(entry, "=")
		if key == "PATH" || key == "NODE_ENV" || key == "NODE_OPTIONS" || key == "NODE_PATH" || key == "ELECTRON_RUN_AS_NODE" || strings.HasPrefix(key, "DYLD_") {
			continue
		}
		env = append(env, entry)
	}
	return env
}
func goExecutable() string {
	if value := os.Getenv("MOKUSEI_GO"); value != "" {
		return value
	}
	if path, err := exec.LookPath("go"); err == nil {
		return path
	}
	return filepath.Join(runtime.GOROOT(), "bin", "go")
}
func platform() error {
	if runtime.GOOS != "darwin" || runtime.GOARCH != "arm64" {
		return fmt.Errorf("native application requires Apple Silicon and macOS 26 or later")
	}
	return nil
}
func combined(ctx context.Context, name string, args ...string) (string, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	var output bytes.Buffer
	cmd.Stdout, cmd.Stderr = &output, &output
	err := runCommand(ctx, cmd, false)
	if err != nil {
		return output.String(), fmt.Errorf("%s: %w\n%s", name, err, output.String())
	}
	return output.String(), nil
}
