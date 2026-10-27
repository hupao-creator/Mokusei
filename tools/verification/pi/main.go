// pi is an executable integration verifier, not a unit test. Its deterministic
// mode exercises the real adapter against a local child-process protocol fixture.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"github.com/hupao-creator/Mokusei/tools/verification/firstresponse"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/hupao-creator/Mokusei/internal/plugins/harness/pi"
)

var verificationConfig struct {
	timeouts            bool
	artifacts           string
	nativeShutdownOnly  bool
	swiftUsage          bool
	settingsPerformance bool
}

var fixtureRoot string

func main() {
	err := captureFailure(func() error {
		if os.Getenv("MOKUSEI_PI_VERIFICATION_FIXTURE") == "1" {
			serveFixture()
			return nil
		}
		return runVerification()
	})
	if err != nil {
		fmt.Fprintln(os.Stderr, "FAIL Pi verification:", err)
		os.Exit(1)
	}
}

func runVerification() error {
	mode := flag.String("mode", "deterministic", "deterministic, native, native-shutdown, or all")
	deadline := flag.Duration("timeout", 3*time.Minute, "deadline for the complete verification run")
	flag.BoolVar(&verificationConfig.settingsPerformance, "settings-performance", false, "measure concurrent state/catalog reads with the native fixture")
	flag.BoolVar(&verificationConfig.swiftUsage, "swift-usage", false, "verify Go usage projections with the real Swift plugin (deterministic mode)")
	flag.BoolVar(&verificationConfig.timeouts, "timeouts", false, "include real 15-second startup and 30-second request timeouts")
	flag.StringVar(&verificationConfig.artifacts, "artifacts", "", "optional directory in which to retain JSON evidence")
	flag.Parse()
	if flag.NArg() != 0 || (*mode != "deterministic" && *mode != "native" && *mode != "native-shutdown" && *mode != "all") {
		return errors.New("expected -mode deterministic|native|native-shutdown|all without positional arguments")
	}
	if verificationConfig.swiftUsage && *mode != "deterministic" && *mode != "all" {
		return errors.New("-swift-usage requires -mode deterministic or all")
	}
	if *deadline <= 0 {
		return errors.New("verification timeout must be positive")
	}
	if verificationConfig.artifacts != "" {
		absolute, err := filepath.Abs(verificationConfig.artifacts)
		if err != nil {
			return err
		}
		if err := os.MkdirAll(absolute, 0700); err != nil {
			return err
		}
		verificationConfig.artifacts = absolute
	}
	signals, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	ctx, cancel := context.WithTimeout(signals, *deadline)
	defer cancel()
	if *mode == "deterministic" || *mode == "all" {
		if err := runDeterministic(ctx); err != nil {
			return err
		}
	}
	verificationConfig.nativeShutdownOnly = *mode == "native-shutdown"
	if *mode == "native" || *mode == "native-shutdown" || *mode == "all" {
		if err := runNative(ctx); err != nil {
			return err
		}
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	if verificationConfig.artifacts != "" {
		fmt.Println("Artifacts:", verificationConfig.artifacts)
	}
	return nil
}

func runDeterministic(ctx context.Context) error {
	if _, err := firstresponse.Verify("pi"); err != nil {
		return err
	}
	root, err := os.MkdirTemp("", "mokusei-pi-verification-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(root)
	fixtureRoot = root
	defer func() { fixtureRoot = "" }()
	return captureFailure(func() error {
		if verificationConfig.settingsPerformance {
			verifySettingsSharing(ctx, false)
			return ctx.Err()
		}
		verifySettingsSharing(ctx, true)
		verifyTransport(ctx)
		verifyResponsesThinking()
		verifyAdapter(ctx)
		verifyUsage(ctx)
		verifyProcessOrdering(ctx)
		return ctx.Err()
	})
}

func captureFailure(run func() error) (err error) {
	defer func() {
		if failure := recover(); failure != nil {
			if cause, ok := failure.(error); ok {
				err = cause
			} else {
				err = fmt.Errorf("%v", failure)
			}
		}
	}()
	return run()
}

func check(condition bool, description string) {
	if !condition {
		panic(description)
	}
}

func writeArtifact(name string, data []byte) error {
	if verificationConfig.artifacts == "" {
		return nil
	}
	if name == "" || filepath.Base(name) != name || strings.ContainsRune(name, 0) {
		return errors.New("artifact name must be a basename")
	}
	return os.WriteFile(filepath.Join(verificationConfig.artifacts, name), data, 0600)
}

func fixtureOptions(scenario string) pi.ProcessOptions {
	executable, err := os.Executable()
	check(err == nil, "resolve verifier executable: "+fmt.Sprint(err))
	// The fixture never needs account credentials, shell startup, or an installed
	// Harness. Keep its environment independent of the caller's native profiles.
	env := map[string]string{
		"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8",
		"GORACE":                           "halt_on_error=1 atexit_sleep_ms=0",
		"TMPDIR":                           fixtureRoot,
		"MOKUSEI_PI_VERIFICATION_FIXTURE":  "1",
		"MOKUSEI_PI_VERIFICATION_ROOT":     fixtureRoot,
		"MOKUSEI_PI_VERIFICATION_SCENARIO": scenario,
	}
	return pi.ProcessOptions{ExecutablePath: executable, Cwd: fixtureRoot, Env: env}
}

func startFixture(ctx context.Context, scenario string) *pi.Session {
	session, err := pi.StartSession(ctx, fixtureOptions(scenario))
	check(err == nil, "start "+scenario+": "+fmt.Sprint(err))
	return session
}
