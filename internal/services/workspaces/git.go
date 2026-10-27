package workspaces

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"sync"
	"syscall"
	"time"
)

// runGit owns the detached group from spawn until both leader and pipe readers
// are joined. Descendants are cleaned even after a successful leader exit.
func runGit(parent context.Context, cwd string, args ...string) (string, error) {
	if err := parent.Err(); err != nil {
		return "", err
	}
	ctx, cancel := context.WithTimeout(parent, 10*time.Second)
	defer cancel()
	stdoutR, stdoutW, err := os.Pipe()
	if err != nil {
		return "", err
	}
	defer stdoutR.Close()
	stderrR, stderrW, err := os.Pipe()
	if err != nil {
		stdoutW.Close()
		return "", err
	}
	defer stderrR.Close()
	cmd := exec.Command("git", args...)
	cmd.Dir = cwd
	cmd.Stdin = nil
	cmd.Stdout = stdoutW
	cmd.Stderr = stderrW
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err = cmd.Start(); err != nil {
		stdoutW.Close()
		stderrW.Close()
		return "", err
	}
	stdoutW.Close()
	stderrW.Close()
	pgid := cmd.Process.Pid
	retired := false
	alive := func() bool {
		if retired {
			return false
		}
		e := syscall.Kill(-pgid, 0)
		if errors.Is(e, syscall.ESRCH) {
			retired = true
			return false
		}
		return true
	}
	signal := func(sig syscall.Signal) {
		if alive() {
			_ = syscall.Kill(-pgid, sig)
		}
	}
	var stdout, stderr bytes.Buffer
	var budgetMu sync.Mutex
	total := 0
	limit := make(chan struct{})
	var limitOnce sync.Once
	read := func(r *os.File, b *bytes.Buffer, done chan<- error) {
		buf := make([]byte, 32*1024)
		for {
			n, e := r.Read(buf)
			if n > 0 {
				budgetMu.Lock()
				total += n
				if total > 1024*1024 {
					limitOnce.Do(func() { close(limit) })
				} else {
					_, _ = b.Write(buf[:n])
				}
				budgetMu.Unlock()
			}
			if e != nil {
				if errors.Is(e, io.EOF) || errors.Is(e, os.ErrClosed) {
					e = nil
				}
				done <- e
				return
			}
		}
	}
	outDone := make(chan error, 1)
	errDone := make(chan error, 1)
	go read(stdoutR, &stdout, outDone)
	go read(stderrR, &stderr, errDone)
	wait := make(chan error, 1)
	go func() { wait <- cmd.Wait() }()
	ticker := time.NewTicker(20 * time.Millisecond)
	defer ticker.Stop()
	var reason, waitErr error
	waited := false
	running := true
	for running {
		select {
		case waitErr = <-wait:
			waited = true
			running = false
		case <-ctx.Done():
			reason = ctx.Err()
			running = false
		case <-limit:
			reason = errors.New("Git output exceeds 1 MiB limit")
			running = false
		case <-ticker.C:
			alive()
		}
	}
	// A group that still exists may contain descendants with inherited pipes.
	if alive() {
		signal(syscall.SIGTERM)
		deadline := time.NewTimer(500 * time.Millisecond)
		terminating := true
		for terminating && alive() {
			select {
			case e := <-wait:
				if !waited {
					waitErr = e
					waited = true
				}
			case <-ticker.C:
			case <-deadline.C:
				signal(syscall.SIGKILL)
				terminating = false
			}
		}
		deadline.Stop()
	}
	cleanupDeadline := time.NewTimer(1500 * time.Millisecond)
	defer cleanupDeadline.Stop()
	outJoined, errJoined := false, false
	var outErr, stderrErr error
	for !waited || !outJoined || !errJoined || alive() {
		select {
		case e := <-wait:
			if !waited {
				waitErr = e
				waited = true
			}
		case e := <-outDone:
			outJoined = true
			outErr = e
		case e := <-errDone:
			errJoined = true
			stderrErr = e
		case <-ticker.C:
		case <-cleanupDeadline.C:
			stdoutR.Close()
			stderrR.Close()
			if !outJoined {
				outErr = <-outDone
				outJoined = true
			}
			if !errJoined {
				stderrErr = <-errDone
				errJoined = true
			}
			return "", errors.Join(reason, waitErr, outErr, stderrErr, fmt.Errorf("Git owned process group/leader cleanup could not be confirmed: %d", pgid))
		}
	}
	budgetMu.Lock()
	out := strings.TrimSpace(stdout.String())
	errText := strings.TrimSpace(stderr.String())
	if total > 1024*1024 && reason == nil {
		reason = errors.New("Git output exceeds 1 MiB limit")
	}
	budgetMu.Unlock()
	if reason != nil {
		return "", errors.Join(reason, waitErr, outErr, stderrErr)
	}
	if waitErr != nil {
		if errText == "" {
			errText = waitErr.Error()
		}
		return "", fmt.Errorf("git %s: %s", strings.Join(args, " "), errText)
	}
	if err = errors.Join(outErr, stderrErr); err != nil {
		return "", err
	}
	return out, nil
}
