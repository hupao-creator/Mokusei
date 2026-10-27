package main

import (
	"bufio"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// These processes exercise kernel argv/default-profile discovery. The separate
// Swift replay supplies actual production preference and draft writes.
func verifyNativeProcessProfiles(ctx context.Context, root, executable string) {
	data, err := os.ReadFile(executable)
	must(err)
	for _, scenario := range []string{"bundle-default", "exit-cleanup", "unrelated-raw", "invalid-bundle", "unlinked-binary", "unlinked-non-native"} {
		home := filepath.Join(root, scenario, "home with spaces")
		current := filepath.Join(home, "Library/Application Support/Mokusei Native Dev")
		previous := current + ".previous"
		for directory, marker := range map[string]string{current: "current", previous: "previous"} {
			must(os.MkdirAll(directory, 0700))
			must(os.WriteFile(filepath.Join(directory, "marker"), []byte(marker), 0600))
		}
		binary := filepath.Join(root, scenario, "another checkout", "fast", "old generation", "Mokusei Native Dev.app", "Contents/MacOS/Mokusei")
		if scenario == "unrelated-raw" {
			binary = filepath.Join(root, scenario, "raw build", "Mokusei")
		} else if scenario == "unlinked-non-native" {
			binary = filepath.Join(root, scenario, "raw build", "generic-worker")
		}
		must(os.MkdirAll(filepath.Dir(binary), 0700))
		must(os.WriteFile(binary, data, 0700))
		if scenario != "unrelated-raw" && scenario != "unlinked-non-native" {
			plist := `<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>MokuseiDataDirectoryName</key><string>Mokusei Native Dev</string></dict></plist>`
			if scenario == "invalid-bundle" {
				plist = "invalid fixture metadata"
			}
			must(os.WriteFile(filepath.Join(filepath.Dir(filepath.Dir(binary)), "Info.plist"), []byte(plist), 0600))
		}
		args := []string{}
		if scenario == "exit-cleanup" {
			args = []string{"--finish-runtime", previous, "fixture-epoch"}
		} else if scenario == "unlinked-binary" {
			args = []string{"--data-dir", current}
		}
		child := exec.CommandContext(ctx, binary, args...)
		child.Env = append(os.Environ(), "HOME="+filepath.Join(home, "different shell home"), "CFFIXED_USER_HOME="+home, "MOKUSEI_NATIVE_CLIENT_FIXTURE=1")
		input, err := child.StdinPipe()
		must(err)
		output, err := child.StdoutPipe()
		must(err)
		must(child.Start())
		func() {
			defer func() { must(input.Close()); must(child.Wait()) }()
			ready := bufio.NewScanner(output)
			check(ready.Scan() && ready.Text() == "ready", "native process fixture did not become ready")
			if strings.HasPrefix(scenario, "unlinked-") {
				must(os.Remove(binary))
			}
			result, err := callOfflineFresh(ctx, home)
			must(err)
			switch scenario {
			case "unrelated-raw", "unlinked-non-native":
				check(result.Failure == "" && !result.NativeClient && result.Previous == previous, "unrelated raw default profile blocked development rotation")
				value, err := os.ReadFile(filepath.Join(previous, "marker"))
				must(err)
				check(string(value) == "current", "unrelated client changed rotation output")
			default:
				if scenario == "invalid-bundle" {
					check(result.Failure != "" && !result.NativeClient && strings.Contains(result.Failure, "cannot establish native client"), "uninspectable live client did not fail closed")
				} else if scenario == "unlinked-binary" {
					check(result.Failure != "" && result.Previous == "", "a live native client with a removed executable was treated as exited")
				} else {
					check(result.NativeClient && result.Failure != "" && result.Previous == "", "native process profile was not excluded: "+scenario+": "+result.Failure)
				}
				for directory, marker := range map[string]string{current: "current", previous: "previous"} {
					value, err := os.ReadFile(filepath.Join(directory, "marker"))
					must(err)
					check(string(value) == marker, "rejected native process changed profile data")
				}
			}
		}()
	}
	fmt.Println("PASS native process profile discovery: older bundle/Foundation home, exit cleanup, unrelated raw profile; unreadable metadata and unlinked live native executable fail closed")
}
