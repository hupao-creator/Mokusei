package devtool

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"strings"

	"github.com/hupao-creator/Mokusei/internal/platform/profile"
)

// ErrNativeClientRunning leaves both development directories untouched.
var ErrNativeClientRunning = errors.New("a native client still owns local profile state")

type nativeClientProcess struct {
	pid        int
	executable string
	arguments  []string
	home       string
}

// Native preferences and drafts remain writable without a runtime owner. Match
// the selected profile, not the bundle being built: fast generations and other
// checkouts can all retain a writer for the same directory.
func rejectNativeClientWriters(ctx context.Context, directories ...string) error {
	targets := make(map[string]bool, len(directories))
	for _, directory := range directories {
		p, err := profile.Resolve(profile.Options{DataDir: directory})
		if err != nil {
			return err
		}
		targets[p.DataDir] = true
	}
	clients, err := nativeClientProcesses(ctx)
	if err != nil {
		return err
	}
	for _, client := range clients {
		directory, err := client.dataDirectory(ctx)
		if err != nil {
			return fmt.Errorf("cannot establish native client %d profile before rotating data: %w", client.pid, err)
		}
		p, err := profile.Resolve(profile.Options{DataDir: directory})
		if err != nil {
			return err
		}
		if targets[p.DataDir] {
			return fmt.Errorf("%w: quit PID %d using %s before rotating development data", ErrNativeClientRunning, client.pid, p.DataDir)
		}
	}
	return nil
}

func (p nativeClientProcess) dataDirectory(ctx context.Context) (string, error) {
	args := p.arguments
	// The exit-cleanup helper uses the same executable and can still write its
	// shutdown-error diagnostic after the window has gone away.
	if len(args) == 4 && args[1] == "--finish-runtime" && filepath.IsAbs(args[2]) {
		return args[2], nil
	}
	options := map[string]string{}
	for i := 1; i < len(args); i++ {
		flag := args[i]
		if strings.HasPrefix(flag, "-psn_") {
			continue
		}
		if (flag != "--data-dir" && flag != "--runtime" && flag != "--automation-socket") ||
			i+1 == len(args) || !filepath.IsAbs(args[i+1]) || options[flag] != "" {
			return "", errors.New("unrecognized native launch arguments")
		}
		i++
		options[flag] = args[i]
	}
	if directory := options["--data-dir"]; directory != "" {
		return directory, nil
	}
	name := "Mokusei"
	contents := filepath.Dir(filepath.Dir(p.executable))
	if filepath.Base(filepath.Dir(p.executable)) == "MacOS" && filepath.Base(contents) == "Contents" {
		data, err := run(ctx, "", nil, "/usr/bin/plutil", "-convert", "json", "-o", "-", filepath.Join(contents, "Info.plist"))
		if err != nil {
			return "", err
		}
		var info map[string]any
		if err := json.Unmarshal([]byte(data), &info); err != nil {
			return "", err
		}
		if value, ok := info["MokuseiDataDirectoryName"].(string); ok {
			name = value
		}
	}
	if !filepath.IsAbs(p.home) {
		return "", errors.New("native home directory is unavailable")
	}
	return filepath.Join(p.home, "Library/Application Support", name), nil
}
