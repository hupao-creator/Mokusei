package devtool

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

func validateConfiguration(configuration string) error {
	if configuration != "debug" && configuration != "release" {
		return fmt.Errorf("configuration must be debug or release")
	}
	return nil
}
func BinaryDirectory(ctx context.Context, repo, configuration string) (string, error) {
	if err := validateConfiguration(configuration); err != nil {
		return "", err
	}
	out, err := run(ctx, repo, nil, "/usr/bin/xcrun", "swift", "build", "--package-path", filepath.Join(repo, "app", "macos"), "--configuration", configuration, "--arch", "arm64", "--show-bin-path")
	return strings.TrimSpace(out), err
}
func BuildRuntime(ctx context.Context, repo string) error {
	inputs, err := buildInputs(repo, false)
	if err != nil {
		return err
	}
	directory := filepath.Join(repo, ".build/go")
	if err := os.MkdirAll(directory, 0755); err != nil {
		return err
	}
	// Publish only a fully linked binary so parallel development launches never see a partial executable.
	file, err := os.CreateTemp(directory, "runtime-build-*")
	if err != nil {
		return err
	}
	temp := file.Name()
	file.Close()
	defer os.Remove(temp)
	if err = runVisible(ctx, repo, nil, goExecutable(), "build", "-trimpath", "-o", temp, "./cmd/mokusei-runtime"); err != nil {
		return err
	}
	if err = unchangedBuildInputs(repo, false, inputs); err != nil {
		return err
	}
	return os.Rename(temp, filepath.Join(directory, "mokusei-runtime"))
}
func Build(ctx context.Context, repo, configuration, product string, skipRuntime bool) (string, error) {
	inputs, inputErr := buildInputs(repo, true)
	if inputErr != nil {
		return "", inputErr
	}
	if err := platform(); err != nil {
		return "", err
	}
	if err := validateConfiguration(configuration); err != nil {
		return "", err
	}
	switch product {
	case "Mokusei", "MokuseiProbe":
	default:
		return "", fmt.Errorf("unknown native product %q", product)
	}
	sdk, err := run(ctx, repo, nil, "/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-version")
	if err != nil {
		return "", err
	}
	major, _ := strconv.Atoi(strings.Split(strings.TrimSpace(sdk), ".")[0])
	if major < 26 {
		return "", fmt.Errorf("macOS 26 SDK or later is required")
	}
	if !skipRuntime {
		if err = BuildRuntime(ctx, repo); err != nil {
			return "", err
		}
	} else if !exists(filepath.Join(repo, ".build/go/mokusei-runtime")) {
		return "", fmt.Errorf("missing Go runtime; run make runtime first")
	}
	if err = runVisible(ctx, repo, nil, "/usr/bin/xcrun", "swift", "build", "--package-path", filepath.Join(repo, "app", "macos"), "--configuration", configuration, "--arch", "arm64", "--product", product); err != nil {
		return "", err
	}
	if err = unchangedBuildInputs(repo, true, inputs); err != nil {
		return "", err
	}
	directory, err := BinaryDirectory(ctx, repo, configuration)
	if err == nil {
		fmt.Println("Built", filepath.Join(directory, product))
	}
	return directory, err
}
