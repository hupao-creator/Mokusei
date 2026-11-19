package devtool

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

// Smoke validates the signed bundle without launching its runtime.
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
	signature, err := verifySignature(ctx, application, product.BundleIdentifier, "", product.Channel == "alpha")
	if err != nil {
		return err
	}
	binary := filepath.Join(application, "Contents/MacOS/mokusei-runtime")
	runtimeSignature, err := verifySignature(ctx, binary, product.BundleIdentifier+".runtime", signature.Team, product.Channel == "alpha")
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
	result := map[string]any{"application": application, "signature": signature, "runtimeSignature": runtimeSignature, "nodeFree": true, "headless": os.Getenv("MOKUSEI_HEADLESS") == "1", "scope": "Signed bundle, portable Go and Swift binaries, and packaged resources. No application processes are launched."}
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
