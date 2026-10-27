// Package processgroup runs finite commands and joins their owned process group,
// including descendants left after a successful leader exit.
package processgroup

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

var ErrOutputLimit = errors.New("process output exceeds its limit")
var ErrCleanup = errors.New("owned process cleanup could not be confirmed")

type Result struct {
	Stdout, Stderr string
	ExitCode       int
}

func Run(ctx context.Context, executable string, args []string, cwd string, env []string, limit int64) (Result, error) {
	if err := ctx.Err(); err != nil {
		return Result{}, err
	}
	if limit <= 0 {
		return Result{}, errors.New("positive output limit required")
	}
	outR, outW, err := os.Pipe()
	if err != nil {
		return Result{}, err
	}
	defer outR.Close()
	defer outW.Close()
	errR, errW, err := os.Pipe()
	if err != nil {
		return Result{}, err
	}
	defer errR.Close()
	defer errW.Close()
	command := exec.Command(executable, args...)
	command.Dir = cwd
	command.Env = env
	command.Stdout = outW
	command.Stderr = errW
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err = command.Start(); err != nil {
		return Result{}, err
	}
	_ = outW.Close()
	_ = errW.Close()
	pgid := command.Process.Pid
	retired := false
	alive := func() bool {
		if retired {
			return false
		}
		if errors.Is(syscall.Kill(-pgid, 0), syscall.ESRCH) {
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
	var mu sync.Mutex
	var total int64
	overflow := make(chan struct{})
	var once sync.Once
	read := func(file *os.File, buffer *bytes.Buffer, done chan<- error) {
		chunk := make([]byte, 32768)
		for {
			n, err := file.Read(chunk)
			if n > 0 {
				mu.Lock()
				remaining := max(int64(0), limit-total)
				if int64(n) <= remaining {
					buffer.Write(chunk[:n])
				} else {
					buffer.Write(chunk[:int(remaining)])
					once.Do(func() { close(overflow) })
				}
				total += int64(n)
				mu.Unlock()
			}
			if err != nil {
				if errors.Is(err, io.EOF) || errors.Is(err, os.ErrClosed) {
					err = nil
				}
				done <- err
				return
			}
		}
	}
	outDone, errDone := make(chan error, 1), make(chan error, 1)
	go read(outR, &stdout, outDone)
	go read(errR, &stderr, errDone)
	wait := make(chan error, 1)
	go func() { wait <- command.Wait() }()
	var reason, waitErr, outErr, stderrErr error
	waited, outJoined, errJoined := false, false, false
	select {
	case waitErr = <-wait:
		waited = true
	case <-ctx.Done():
		reason = ctx.Err()
	case <-overflow:
		reason = ErrOutputLimit
	}
	ticker := time.NewTicker(20 * time.Millisecond)
	defer ticker.Stop()
	if alive() {
		signal(syscall.SIGTERM)
		grace := time.NewTimer(time.Second)
		terminating := true
		for terminating && alive() {
			select {
			case waitErr = <-wait:
				waited = true
			case <-ticker.C:
			case <-grace.C:
				signal(syscall.SIGKILL)
				terminating = false
			}
		}
		grace.Stop()
	}
	drain := time.NewTimer(2 * time.Second)
	defer drain.Stop()
	cleanupFailed := false
	for !waited || !outJoined || !errJoined || alive() {
		select {
		case waitErr = <-wait:
			waited = true
		case outErr = <-outDone:
			outJoined = true
		case stderrErr = <-errDone:
			errJoined = true
		case <-ticker.C:
		case <-drain.C:
			// A zombie has stopped executing but remains in the kernel process table.
			// Inspection failure is never proof of cleanup.
			stopped := !alive() || (waited && groupStopped(pgid))
			cleanupFailed = !waited || !outJoined || !errJoined || !stopped
			_ = outR.Close()
			_ = errR.Close()
			if !outJoined {
				outErr = <-outDone
				outJoined = true
			}
			if !errJoined {
				stderrErr = <-errDone
				errJoined = true
			}
			retired = stopped
			if cleanupFailed {
				return Result{}, errors.Join(reason, outErr, stderrErr, ErrCleanup)
			}
		}
	}
	mu.Lock()
	result := Result{Stdout: stdout.String(), Stderr: stderr.String(), ExitCode: command.ProcessState.ExitCode()}
	if total > limit {
		reason = ErrOutputLimit
	}
	mu.Unlock()
	if err = errors.Join(reason, outErr, stderrErr); err != nil {
		return result, err
	}
	var exitError *exec.ExitError
	if waitErr != nil && !errors.As(waitErr, &exitError) {
		return result, waitErr
	}
	return result, nil
}

// A successful complete scan proves a group is absent or contains only zombies.
// Empty, malformed or unavailable process tables never prove cleanup.
func groupStopped(pgid int) bool {
	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()
	command := exec.CommandContext(ctx, "/bin/ps", "-axo", "pgid=,stat=")
	command.WaitDelay = 100 * time.Millisecond
	var output boundedPS
	command.Stdout = &output
	if command.Run() != nil {
		return false
	}
	sawProcess := false
	for _, line := range strings.Split(output.String(), "\n") {
		fields := strings.Fields(line)
		if len(fields) == 0 {
			continue
		}
		if len(fields) != 2 {
			return false
		}
		group, err := strconv.Atoi(fields[0])
		if err != nil {
			return false
		}
		sawProcess = true
		if group == pgid {
			if !strings.HasPrefix(fields[1], "Z") {
				return false
			}
		}
	}
	return sawProcess
}

type boundedPS struct{ bytes.Buffer }

func (b *boundedPS) Write(data []byte) (int, error) {
	if b.Len()+len(data) > 8*1024*1024 {
		return 0, fmt.Errorf("process table exceeds bound")
	}
	return b.Buffer.Write(data)
}
