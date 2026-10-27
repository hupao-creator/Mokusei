package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/hupao-creator/Mokusei/internal/platform/processgroup"
)

func verifyZombieGroupDrain() error {
	// Keep the zombie's parent (this replay) outside the owned group so it can
	// delay reaping deterministically after the group's leader has been reaped.
	leader := exec.Command("/bin/sleep", "30")
	leader.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := leader.Start(); err != nil {
		return err
	}
	defer func() { _ = leader.Process.Kill(); _ = leader.Wait() }()
	zombie := exec.Command("/usr/bin/true")
	zombie.SysProcAttr = &syscall.SysProcAttr{Setpgid: true, Pgid: leader.Process.Pid}
	if err := zombie.Start(); err != nil {
		return err
	}
	defer func() { _ = zombie.Process.Kill(); _ = zombie.Wait() }()
	deadline := time.Now().Add(5 * time.Second)
	for {
		status, err := exec.Command("/bin/ps", "-o", "stat=", "-p", strconv.Itoa(zombie.Process.Pid)).Output()
		if err != nil {
			return err
		}
		if strings.HasPrefix(strings.TrimSpace(string(status)), "Z") {
			break
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("fixture child did not become a zombie")
		}
		time.Sleep(10 * time.Millisecond)
	}
	if err := leader.Process.Signal(syscall.SIGTERM); err != nil {
		return err
	}
	_ = leader.Wait()
	probeErr := syscall.Kill(-leader.Process.Pid, 0)
	if runtime.GOOS == "darwin" && !errors.Is(probeErr, syscall.EPERM) {
		return fmt.Errorf("zombie-only Darwin group did not reproduce EPERM: %v", probeErr)
	}
	if err := processgroup.DrainAfterExit(leader.Process.Pid); err != nil {
		return fmt.Errorf("drain zombie-only group after leader exit: %w", err)
	}
	if err := zombie.Wait(); err != nil {
		return err
	}
	if err := processgroup.DrainAfterExit(leader.Process.Pid); err != nil {
		return fmt.Errorf("drain reaped group: %w", err)
	}
	fmt.Println("PASS owned process group: zombie-only group is drained despite Darwin EPERM; reaped group also releases cleanup")
	return nil
}

func verifyDescendantDrain() error {
	root, err := os.MkdirTemp("", "owned-group-drain-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(root)
	path := filepath.Join(root, "child.pid")
	// The child closes inherited pipes and survives its leader, just like a native
	// plugin worker flushing its compile cache after the server exits.
	leader := exec.Command("/bin/sh", "-c", `sleep 30 </dev/null >/dev/null 2>&1 & printf '%s' "$!" > "$1"`, "fixture", path)
	leader.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err = leader.Run(); err != nil {
		return err
	}
	defer syscall.Kill(-leader.Process.Pid, syscall.SIGKILL)
	raw, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	child, err := strconv.Atoi(string(raw))
	if err != nil {
		return err
	}
	if err = processgroup.DrainAfterExit(leader.Process.Pid); err != nil {
		return err
	}
	status, err := exec.Command("/bin/ps", "-o", "stat=", "-p", strconv.Itoa(child)).Output()
	if err == nil && !strings.HasPrefix(strings.TrimSpace(string(status)), "Z") {
		return fmt.Errorf("owned descendant %d still running after leader exit", child)
	}
	fmt.Println("PASS owned process group: descendant without inherited pipes is drained after leader exit before directory removal")
	return nil
}
