package devtool

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

func runtimeCommand(binary, profile, command string) (map[string]any, error) {
	timeout := 45 * time.Second
	if command == "start" {
		timeout = 150 * time.Second
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	// The short-lived manager must finish before cleanup starts, even when the
	// terminal interrupts the parent. The detached daemon has its own lifetime.
	cmd := exec.CommandContext(ctx, binary, command, "--data-dir", profile)
	cmd.Dir = os.TempDir()
	cmd.Env = ProductionEnvironment()
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	var diagnostics bytes.Buffer
	cmd.Stderr = &diagnostics
	output, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("runtime %s failed: %w: %s", command, err, strings.TrimSpace(diagnostics.String()))
	}
	out := string(output)
	if len(out) > 1024*1024 {
		return nil, fmt.Errorf("runtime status output exceeds 1 MiB")
	}
	var result map[string]any
	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		if strings.HasPrefix(line, "{") {
			if err = json.Unmarshal([]byte(line), &result); err != nil {
				return nil, err
			}
		}
	}
	if result == nil {
		return nil, fmt.Errorf("runtime %s did not return JSON status", command)
	}
	return result, nil
}
func runtimeLifecycle(ctx context.Context, binary string) (result map[string]any, err error) {
	profile, err := os.MkdirTemp("", "mokusei-native-smoke-")
	if err != nil {
		return nil, err
	}
	profile, err = filepath.EvalSymlinks(profile)
	if err != nil {
		return nil, err
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return nil, err
	}
	hash := sha256.Sum256([]byte(profile))
	workspaceProfile := filepath.Join(home, ".Mokusei/profiles", hex.EncodeToString(hash[:]))
	if exists(workspaceProfile) {
		_ = os.RemoveAll(profile)
		return nil, fmt.Errorf("temporary smoke profile unexpectedly has an existing workspace")
	}
	defer func() {
		_, stopErr := runtimeCommand(binary, profile, "stop")
		status, statusErr := runtimeCommand(binary, profile, "status")
		stopped := statusErr == nil && status["status"] == "stopped"
		if stopped {
			if err == nil && stopErr == nil {
				_ = os.RemoveAll(profile)
				_ = os.RemoveAll(workspaceProfile)
			} else {
				err = errors.Join(err, fmt.Errorf("stopped smoke profile retained for diagnosis: %s", profile))
			}
			if result != nil {
				result["stop"] = "stopped"
			}
		} else {
			stopErr = errors.Join(stopErr, statusErr, fmt.Errorf("smoke runtime cleanup incomplete; recovery profile retained at %s", profile))
		}
		err = errors.Join(err, stopErr)
	}()
	if err = ctx.Err(); err != nil {
		return nil, err
	}
	start, err := runtimeCommand(binary, profile, "start")
	if err != nil {
		return nil, err
	}
	if err = ctx.Err(); err != nil {
		return nil, err
	}
	if start["status"] != "running" || start["pid"] == nil {
		return nil, fmt.Errorf("packaged runtime did not start")
	}
	status, err := runtimeCommand(binary, profile, "status")
	if err != nil {
		return nil, err
	}
	if status["status"] != "running" || status["pid"] != start["pid"] || status["epoch"] != start["epoch"] {
		return nil, fmt.Errorf("packaged runtime status does not match startup")
	}
	return map[string]any{"start": "running", "status": "running", "sameProcess": true}, ctx.Err()
}

// Smoke validates only staged artifacts and an isolated profile. It never opens a GUI or audio device.
func Smoke(ctx context.Context, repo, application, channel, report string) error {
	if err := platform(); err != nil {
		return err
	}
	product, err := ProductConfiguration(channel)
	if err != nil {
		return err
	}
	application, err = filepath.Abs(application)
	if err != nil {
		return err
	}
	signature, err := VerifySignature(ctx, application, product.BundleIdentifier, "")
	if err != nil {
		return err
	}
	binary := filepath.Join(application, "Contents/MacOS/mokusei-runtime")
	runtimeSignature, err := VerifySignature(ctx, binary, product.BundleIdentifier+".runtime", signature.Team)
	if err != nil {
		return err
	}
	_, err = assertPortableMachO(ctx, filepath.Join(application, "Contents/MacOS/Mokusei"), false)
	if err != nil {
		return err
	}
	if _, err = assertPortableMachO(ctx, binary, false); err != nil {
		return err
	}
	rpaths, err := machORPaths(ctx, filepath.Join(application, "Contents/MacOS/Mokusei"))
	if err != nil {
		return err
	}
	hasEmbedded := false
	for _, path := range rpaths {
		if !portableRPath(path) {
			return fmt.Errorf("nonportable framework search path %s", path)
		}
		if path == "@executable_path/../Frameworks" {
			hasEmbedded = true
		}
	}
	if !hasEmbedded {
		return fmt.Errorf("missing embedded Frameworks rpath")
	}
	if err = validatePackagedResources(application); err != nil {
		return err
	}
	for _, path := range []string{"Contents/MacOS/node", "Contents/Resources/native-renderer", "Contents/Resources/runtime/runtime.js", "Contents/Resources/node-provenance.json"} {
		if exists(filepath.Join(application, path)) {
			return fmt.Errorf("unexpected legacy Node artifact %s", path)
		}
	}
	out, err := run(ctx, repo, nil, "/usr/bin/plutil", "-convert", "json", "-o", "-", filepath.Join(application, "Contents/Info.plist"))
	if err != nil {
		return err
	}
	var info map[string]any
	if err = json.Unmarshal([]byte(out), &info); err != nil {
		return err
	}
	expected := map[string]string{"CFBundleIdentifier": product.BundleIdentifier, "CFBundleDisplayName": product.DisplayName, "MokuseiDataDirectoryName": product.DataDirectoryName, "LSMinimumSystemVersion": "26.0", "CFBundleExecutable": "Mokusei"}
	for key, value := range expected {
		if info[key] != value {
			return fmt.Errorf("unexpected bundle metadata %s", key)
		}
	}
	lifecycle, err := runtimeLifecycle(ctx, binary)
	if err != nil {
		return err
	}
	result := map[string]any{"application": application, "signature": signature, "runtimeSignature": runtimeSignature, "runtime": lifecycle, "nodeFree": true, "headless": os.Getenv("MOKUSEI_HEADLESS") == "1", "scope": "Signed bundle, portable Go and Swift binaries, packaged resources and isolated runtime lifecycle. GUI is not exercised."}
	data, err := json.MarshalIndent(result, "", "  ")
	if err != nil {
		return err
	}
	if report != "" {
		if err = os.WriteFile(report, append(data, '\n'), 0600); err != nil {
			return err
		}
	}
	fmt.Println(string(data))
	return nil
}
