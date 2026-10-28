// Command opencode runs fixed local protocol replays. It never uses a user's
// OpenCode profile and only starts an installed CLI when explicitly selected.
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"time"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
func run() error {
	native := flag.String("native-cli", "", "explicit external OpenCode 2.0.25+ executable; enables native local-provider replays")
	toolchain := flag.String("go", filepath.Join(runtime.GOROOT(), "bin", "go"), "Go executable used to build fixture and replay cases")
	root := flag.String("root", ".", "repository root")
	race := flag.Bool("race", true, "enable Go race detector")
	only := flag.String("case", "all", "all, credentials, timeout, settings, native, thread, forms, foreground, renderer, or telemetry")
	flag.Parse()
	absolute, err := filepath.Abs(*root)
	if err != nil {
		return err
	}
	if _, err = os.Stat(filepath.Join(absolute, "go.mod")); err != nil {
		return fmt.Errorf("run from repository root or pass -root: %w", err)
	}
	allowed := map[string]bool{"all": true, "credentials": true, "timeout": true, "settings": true, "native": true, "thread": true, "forms": true, "foreground": true, "renderer": true, "telemetry": true}
	if !allowed[*only] {
		return fmt.Errorf("unknown replay case %q", *only)
	}
	if *native != "" {
		*native, err = filepath.Abs(*native)
		if err != nil {
			return err
		}
		info, e := os.Stat(*native)
		if e != nil || info.IsDir() {
			return fmt.Errorf("native CLI is unavailable")
		}
	}
	temp, err := os.MkdirTemp("", "mokusei-opencode-replay-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(temp)
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	fixture := filepath.Join(temp, "opencode-fixture")
	command := exec.CommandContext(ctx, *toolchain, "build", "-o", fixture, "./tools/verification/opencode/fixture")
	command.Dir = absolute
	command.Stdout = os.Stdout
	command.Stderr = os.Stderr
	if err = command.Run(); err != nil {
		return err
	}
	cases := []string{"credentials", "settings", "timeout", "renderer", "telemetry"}
	if *native != "" {
		cases = append(cases, "native", "thread", "forms", "foreground")
	}
	if *only != "all" {
		if (*only == "native" || *only == "thread" || *only == "forms" || *only == "foreground") && *native == "" {
			return fmt.Errorf("case %s requires explicit -native-cli", *only)
		}
		cases = []string{*only}
	}
	for _, name := range cases {
		fmt.Printf("OpenCode replay: %s\n", name)
		caseTimeout := 150 * time.Second
		if name == "thread" {
			caseTimeout = 240 * time.Second
		} // Includes independent discussion process lifetimes.
		bounded, stop := context.WithTimeout(ctx, caseTimeout)
		binary := filepath.Join(temp, name)
		args := []string{"build"}
		if *race {
			args = append(args, "-race")
		}
		args = append(args, "-o", binary, "./tools/verification/opencode/cases/"+name)
		command = exec.CommandContext(bounded, *toolchain, args...)
		command.Dir = absolute
		command.Stdout = os.Stdout
		command.Stderr = os.Stderr
		err = command.Run()
		if err == nil {
			command = exec.CommandContext(bounded, binary)
			command.Dir = absolute
			command.Env = append(withoutVariables(os.Environ(), "MOKUSEI_OPENCODE_NATIVE_CLI", "MOKUSEI_OPENCODE_FIXTURE"), "MOKUSEI_OPENCODE_NATIVE_CLI="+*native, "MOKUSEI_OPENCODE_FIXTURE="+fixture)
			command.Stdout = os.Stdout
			command.Stderr = os.Stderr
			command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
			command.Cancel = func() error { return syscall.Kill(-command.Process.Pid, syscall.SIGTERM) }
			command.WaitDelay = 10 * time.Second
			err = command.Run()
		}
		stop()
		if err != nil {
			return fmt.Errorf("%s replay failed: %w", name, err)
		}
	}
	fmt.Printf("PASS: %d OpenCode integration replay cases; all model requests use loopback scripted providers\n", len(cases))
	return nil
}
func withoutVariables(env []string, names ...string) []string {
	out := []string{}
	for _, value := range env {
		key, _, _ := strings.Cut(value, "=")
		drop := false
		for _, name := range names {
			drop = drop || name == key
		}
		if !drop {
			out = append(out, value)
		}
	}
	return out
}
