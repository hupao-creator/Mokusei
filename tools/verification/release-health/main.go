// Command release-health runs the release reliability gates with retained evidence.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"time"
)

type result struct {
	Name    string  `json:"name"`
	Status  string  `json:"status"`
	Seconds float64 `json:"seconds"`
	Log     string  `json:"log,omitempty"`
	Error   string  `json:"error,omitempty"`
}
type report struct {
	GoVersion string    `json:"goVersion"`
	Platform  string    `json:"platform"`
	Revision  string    `json:"revision"`
	Started   time.Time `json:"started"`
	Results   []result  `json:"results"`
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
func run() error {
	output := flag.String("output", "", "new evidence directory (default: temporary directory)")
	only := flag.String("only", "", "comma-separated gate names; omitted gates are reported skipped")
	native := flag.String("real-codex", "", "native Codex binary for isolated loopback provider gate")
	timeout := flag.Duration("timeout", 10*time.Minute, "deadline per replay, including compilation")
	cycles := flag.Int("cycles", 5, "headless start/stop/restart cycles")
	flag.Parse()
	if *timeout <= 0 || *cycles < 2 {
		return errors.New("timeout must be positive and cycles at least 2")
	}
	if _, err := os.Stat("go.mod"); err != nil {
		return errors.New("run from repository root")
	}
	names := []string{"headless", "runtime", "runtime-concurrency", "runtime-helpers", "moku", "transport", "storage-workspaces", "command-boundaries", "applicationhost", "settings-shell", "thread-metadata", "thread-search", "console-oauth", "git", "artificialanalysis", "artificialanalysis/lifecycle", "claude", "codex", "pi", "opencode", "native-codex", "moku-system"}
	selected := map[string]bool{}
	if *only != "" {
		for _, name := range strings.Split(*only, ",") {
			found := false
			for _, known := range names {
				if name == known {
					found = true
				}
			}
			if !found {
				return fmt.Errorf("unknown gate %q", name)
			}
			selected[name] = true
		}
	}
	var err error
	if *output == "" {
		*output, err = os.MkdirTemp("", "mokusei-release-health-")
	} else {
		err = os.Mkdir(*output, 0700)
	}
	if err != nil {
		return err
	}
	*output, err = filepath.Abs(*output)
	if err != nil {
		return err
	}
	fmt.Println("Evidence:", *output)
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	revision, err := exec.Command("git", "rev-parse", "HEAD").Output()
	if err != nil {
		return err
	}
	diff, err := exec.Command("git", "status", "--porcelain").Output()
	if err != nil {
		return err
	}
	r := report{GoVersion: runtime.Version(), Platform: runtime.GOOS + "/" + runtime.GOARCH, Revision: strings.TrimSpace(string(revision)), Started: time.Now().UTC()}
	if len(diff) != 0 {
		r.Revision += "+dirty"
	}
	failures := 0
	for _, name := range names {
		item := result{Name: name, Status: "skipped"}
		if (*only == "" || selected[name]) && !((name == "native-codex" || name == "moku-system") && *native == "") && ctx.Err() == nil {
			item.Log = strings.ReplaceAll(name, "/", "-") + ".log"
			log, e := os.OpenFile(filepath.Join(*output, item.Log), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
			if e != nil {
				return e
			}
			fmt.Println("RUN", name)
			start := time.Now()
			step, stop := context.WithTimeout(ctx, *timeout)
			if name == "headless" {
				e = headless(step, log, *cycles)
			} else {
				args := []string{"run", "-race", "./tools/verification/" + name}
				switch name {
				case "native-codex":
					args = []string{"run", "-race", "./tools/verification/codex", "-real-only", "-real-codex", *native}
				case "moku-system":
					args = []string{"run", "-race", "./tools/verification/moku-system", "-codex", *native, "-scopes", "3", "-faults", "moku=429,child=truncate,report=500,tag=429,read=truncate", "-evidence", filepath.Join(*output, "moku-system-evidence")}
				case "pi":
					args = append(args, "-mode", "all")
				}
				if name == "native-codex" {
					e = command(step, log, *native, "--version")
				}
				if e == nil {
					e = command(step, log, "./scripts/go.sh", args...)
				}
			}
			stop()
			e = errors.Join(e, log.Close())
			item.Seconds = time.Since(start).Seconds()
			item.Status = "passed"
			if e != nil {
				item.Status = "failed"
				item.Error = e.Error()
				failures++
			}
			fmt.Printf("%s %s (%.1fs)\n", strings.ToUpper(item.Status), name, item.Seconds)
		} else if (name == "native-codex" || name == "moku-system") && *native == "" {
			item.Error = "requires -real-codex; no installed CLI/provider evidence"
		}
		r.Results = append(r.Results, item)
		data, e := json.MarshalIndent(r, "", "  ")
		if e != nil {
			return e
		}
		if e = os.WriteFile(filepath.Join(*output, "report.json"), append(data, '\n'), 0600); e != nil {
			return e
		}
	}
	if ctx.Err() != nil {
		return ctx.Err()
	}
	if failures != 0 {
		return fmt.Errorf("%d release health gates failed; see %s", failures, *output)
	}
	fmt.Println("PASS selected release health gates; inspect skipped gates and coverage limits")
	return nil
}

// All replay subprocesses get an owned process group. On timeout kill the group,
// not just go run, so its compiled runner cannot continue after a failed gate.
func command(ctx context.Context, out io.Writer, executable string, args ...string) error {
	cmd := exec.CommandContext(ctx, executable, args...)
	cmd.Stdout, cmd.Stderr = out, out
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) }
	cmd.WaitDelay = 5 * time.Second
	err := cmd.Run()
	if ctx.Err() != nil {
		return errors.Join(ctx.Err(), err)
	}
	return err
}
