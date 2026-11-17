package devtool

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

// Alpha publishes a complete, versioned release directory. Its staging tree is
// on the destination filesystem so publication can be atomic without replacing
// any previously distributed release.
func Alpha(ctx context.Context, repo, output, buildNumber string) (string, error) {
	if err := platform(); err != nil {
		return "", err
	}
	if output == "" {
		output = filepath.Join(repo, "app/macos/dist/alpha")
	}
	output, err := bundleOutput(output)
	if err != nil {
		return "", err
	}
	if err = os.MkdirAll(output, 0755); err != nil {
		return "", err
	}
	staging, err := os.MkdirTemp(output, ".alpha-")
	if err != nil {
		return "", err
	}
	defer os.RemoveAll(staging)
	payload := filepath.Join(staging, "payload")
	release := filepath.Join(staging, "release")
	if err = os.Mkdir(release, 0755); err != nil {
		return "", err
	}
	app, err := Bundle(ctx, repo, BundleOptions{Channel: "alpha", Configuration: "release", Output: payload, BuildNumber: buildNumber})
	if err != nil {
		return "", err
	}
	if err = Smoke(ctx, repo, app, "alpha", ""); err != nil {
		return "", err
	}
	data, err := os.ReadFile(filepath.Join(app, "Contents/Resources/build-provenance.json"))
	if err != nil {
		return "", err
	}
	var provenance bundleProvenance
	if err = json.Unmarshal(data, &provenance); err != nil {
		return "", err
	}
	name := "Mokusei-" + provenance.ReleaseVersion + "-arm64"
	destination := filepath.Join(output, name)
	if _, err = os.Lstat(destination); err == nil {
		return "", fmt.Errorf("alpha release already exists: %s; choose a new --build-number", destination)
	} else if !os.IsNotExist(err) {
		return "", err
	}
	if err = os.Remove(filepath.Join(payload, ".native-publish.lock")); err != nil {
		return "", err
	}
	if err = os.Symlink("/Applications", filepath.Join(payload, "Applications")); err != nil {
		return "", err
	}
	for _, directory := range []string{payload, release} {
		if err = copyFile(filepath.Join(repo, "app/macos/build/alpha-installation.txt"), filepath.Join(directory, "READ-ME-FIRST.txt"), 0644); err != nil {
			return "", err
		}
	}
	image := filepath.Join(release, name+".dmg")
	if err = runVisible(ctx, repo, nil, "/usr/bin/hdiutil", "create", "-volname", "Mokusei "+provenance.ReleaseVersion, "-srcfolder", payload, "-fs", "HFS+", "-format", "UDZO", image); err != nil {
		return "", err
	}
	if err = runVisible(ctx, repo, nil, "/usr/bin/hdiutil", "verify", image); err != nil {
		return "", err
	}
	checksum, err := sha256File(image)
	if err != nil {
		return "", err
	}
	if err = os.WriteFile(filepath.Join(release, "SHA256SUMS"), []byte(checksum+"  "+filepath.Base(image)+"\n"), 0644); err != nil {
		return "", err
	}
	receipt := map[string]any{
		"build": provenance, "artifact": filepath.Base(image), "sha256": checksum,
		"architecture": "arm64", "minimumMacOS": "26.0", "notarized": false,
		"verification": "Disk image checksum; signed bundle metadata, portable binaries and packaged resources. No application launch or Gatekeeper acceptance is verified.",
	}
	data, err = json.MarshalIndent(receipt, "", "  ")
	if err != nil {
		return "", err
	}
	if err = os.WriteFile(filepath.Join(release, "release.json"), append(data, '\n'), 0644); err != nil {
		return "", err
	}
	publisher, err := buildBundlePublisher(ctx, repo, staging)
	if err != nil {
		return "", err
	}
	if _, err = run(ctx, repo, nil, publisher, "--exclusive-directory", release, destination); err != nil {
		return "", err
	}
	image = filepath.Join(destination, filepath.Base(image))
	fmt.Println("Alpha DMG:", image)
	fmt.Println("SHA-256:", checksum)
	fmt.Println("Ad-hoc signed, not notarized. Share READ-ME-FIRST.txt with invited users.")
	return image, nil
}
