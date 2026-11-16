package main

import (
	"context"
	"fmt"
	oc "github.com/hupao-creator/Mokusei/internal/plugins/harness/opencode"
	"os"
	"path/filepath"
	"strings"
	"time"
)

func main() {
	cli := os.Getenv("MOKUSEI_OPENCODE_FIXTURE")
	if cli == "" {
		panic("run through verification runner")
	}
	root, err := os.MkdirTemp("", "mokusei-opencode-timeout-")
	if err != nil {
		panic(err)
	}
	defer os.RemoveAll(root)
	env := map[string]string{"PATH": os.Getenv("PATH"), "HOME": root, "OPENCODE_DB": filepath.Join(root, "native.db"), "FIXTURE_ROOT": root, "FIXTURE_STARTUP_DELAY_MS": "3000"}
	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()
	start := time.Now()
	runtime, err := oc.NewRuntime(ctx, oc.Options{CWD: root, ExecutablePath: cli, Environment: env})
	if err == nil {
		runtime.Close()
		panic("startup cancellation ignored")
	}
	if time.Since(start) > 5*time.Second {
		panic("startup cleanup unbounded")
	}
	log, err := os.ReadFile(filepath.Join(root, "operations.log"))
	if err != nil {
		panic(err)
	}
	if strings.Count(string(log), "process-start") != 1 || strings.Count(string(log), "process-exit") != 1 {
		panic("startup cancellation leaked server")
	}
	fmt.Println("PASS: cancelled startup closes the single native server before returning", time.Since(start).Round(time.Millisecond))
	// A server that exits after publishing its address but before the plugin
	// activates must fail startup immediately, not spend the activation budget
	// retrying a dead endpoint.
	crash, err := os.MkdirTemp("", "mokusei-opencode-crash-")
	if err != nil {
		panic(err)
	}
	defer os.RemoveAll(crash)
	crashEnv := map[string]string{"PATH": os.Getenv("PATH"), "HOME": crash, "OPENCODE_DB": filepath.Join(crash, "native.db"), "FIXTURE_ROOT": crash, "FIXTURE_PLUGIN_DELAY_MS": "60000", "FIXTURE_PROCESS_EXIT_MS": "150"}
	start = time.Now()
	runtime, err = oc.NewRuntime(context.Background(), oc.Options{CWD: crash, ExecutablePath: cli, Environment: crashEnv})
	if err == nil {
		runtime.Close()
		panic("exit during plugin activation ignored")
	}
	if time.Since(start) > 5*time.Second {
		panic("exit during plugin activation waited for the full budget")
	}
	if !strings.Contains(err.Error(), "exited") {
		panic("startup did not report the process exit: " + err.Error())
	}
	crashLog, readErr := os.ReadFile(filepath.Join(crash, "operations.log"))
	if readErr != nil {
		panic(readErr)
	}
	if strings.Count(string(crashLog), "process-exit") != 1 {
		panic("exit during plugin activation leaked server")
	}
	fmt.Println("PASS: exit during plugin activation fails startup immediately", time.Since(start).Round(time.Millisecond), "-", err.Error())
}
