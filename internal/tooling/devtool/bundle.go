package devtool

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"encoding/xml"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

type BundleOptions struct {
	Channel, Configuration, Output string
	SkipBuild, SkipRuntime, Zip    bool
}

func sha256File(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	hash := sha256.Sum256(data)
	return hex.EncodeToString(hash[:]), nil
}
func copyStable(src, dst string) (string, error) {
	before, err := sha256File(src)
	if err != nil {
		return "", err
	}
	if err = copyFile(src, dst, 0755); err != nil {
		return "", err
	}
	after, err := sha256File(src)
	if err != nil {
		return "", err
	}
	copied, err := sha256File(dst)
	if err != nil {
		return "", err
	}
	if before != after || before != copied {
		return "", fmt.Errorf("build input changed while packaging: %s", src)
	}
	return before, nil
}
func canonicalOutput(path string) (string, error) {
	path, err := filepath.Abs(path)
	if err != nil {
		return "", err
	}
	resolved, err := filepath.EvalSymlinks(path)
	if err == nil {
		return resolved, nil
	}
	if !os.IsNotExist(err) {
		return "", err
	}
	parent := filepath.Dir(path)
	if parent == path {
		return path, nil
	}
	parent, err = canonicalOutput(parent)
	if err != nil {
		return "", err
	}
	return filepath.Join(parent, filepath.Base(path)), nil
}
func bundleOutput(path string) (string, error) {
	path, err := canonicalOutput(path)
	if err != nil {
		return "", err
	}
	for _, part := range strings.Split(path, string(filepath.Separator)) {
		if part == "Applications" {
			return "", fmt.Errorf("packaging writes build artifacts only; use install for Applications destinations")
		}
	}
	if path == "/" {
		return "", fmt.Errorf("invalid bundle output /")
	}
	return path, nil
}
func xmlText(value string) string {
	var output strings.Builder
	_ = xml.EscapeText(&output, []byte(value))
	return output.String()
}
func infoPlist(version string, p Product) string {
	return fmt.Sprintf(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Mokusei</string>
<key>CFBundleIdentifier</key><string>%s</string>
<key>CFBundleName</key><string>%s</string>
<key>CFBundleDisplayName</key><string>%s</string>
<key>MokuseiDataDirectoryName</key><string>%s</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>%s</string>
<key>CFBundleVersion</key><string>%s</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSMicrophoneUsageDescription</key><string>Mokusei uses your microphone when you start a voice conversation.</string>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/><key>NSAllowsArbitraryLoadsInWebContent</key><true/></dict>
</dict></plist>
`, xmlText(p.BundleIdentifier), xmlText(p.DisplayName), xmlText(p.DisplayName), xmlText(p.DataDirectoryName), xmlText(version), xmlText(version))
}

func stageVoiceFramework(ctx context.Context, repo, frameworks, resources string) (string, error) {
	artifact := filepath.Join(repo, "app/macos/.build/artifacts/webrtc-xcframework/LiveKitWebRTC/LiveKitWebRTC.xcframework")
	out, err := run(ctx, repo, nil, "/usr/bin/plutil", "-convert", "json", "-o", "-", filepath.Join(artifact, "Info.plist"))
	if err != nil {
		return "", err
	}
	var info struct {
		AvailableLibraries []struct {
			LibraryIdentifier, LibraryPath, SupportedPlatform, SupportedPlatformVariant string
			SupportedArchitectures                                                      []string
		}
	}
	if err = json.Unmarshal([]byte(out), &info); err != nil {
		return "", err
	}
	var source string
	for _, lib := range info.AvailableLibraries {
		if lib.SupportedPlatform != "macos" || lib.SupportedPlatformVariant != "" || lib.LibraryPath != voiceFrameworkName {
			continue
		}
		for _, arch := range lib.SupportedArchitectures {
			if arch == "arm64" {
				source = filepath.Join(artifact, lib.LibraryIdentifier, lib.LibraryPath)
			}
		}
	}
	if source == "" {
		return "", fmt.Errorf("SwiftPM has no matching macOS arm64 WebRTC framework")
	}
	if _, err = assertPortableMachO(ctx, filepath.Join(source, "LiveKitWebRTC"), "", true); err != nil {
		return "", err
	}
	if err = os.MkdirAll(frameworks, 0755); err != nil {
		return "", err
	}
	destination := filepath.Join(frameworks, voiceFrameworkName)
	if _, err = run(ctx, repo, nil, "/usr/bin/ditto", source, destination); err != nil {
		return "", err
	}
	binary, err := filepath.EvalSymlinks(filepath.Join(destination, "LiveKitWebRTC"))
	if err != nil {
		return "", err
	}
	out, err = run(ctx, repo, nil, "/usr/bin/lipo", "-archs", binary)
	if err != nil {
		return "", err
	}
	if strings.TrimSpace(out) != "arm64" {
		if _, err = run(ctx, repo, nil, "/usr/bin/lipo", binary, "-thin", "arm64", "-output", binary+".arm64"); err != nil {
			return "", err
		}
		if err = os.Rename(binary+".arm64", binary); err != nil {
			return "", err
		}
	}
	if _, err = assertPortableMachO(ctx, binary, "", false); err != nil {
		return "", err
	}
	if err = copyFile(filepath.Join(artifact, "LICENSE"), filepath.Join(resources, "licenses/LiveKitWebRTC-LICENSE"), 0644); err != nil {
		return "", err
	}
	return destination, nil
}
func Bundle(ctx context.Context, repo string, opts BundleOptions) (string, error) {
	if err := platform(); err != nil {
		return "", err
	}
	if opts.Channel == "" {
		opts.Channel = "production"
	}
	if opts.Configuration == "" {
		opts.Configuration = "release"
	}
	product, err := ProductConfiguration(opts.Channel)
	if err != nil {
		return "", err
	}
	if opts.Output == "" {
		opts.Output = filepath.Join(repo, "app/macos/dist")
	}
	output, err := bundleOutput(opts.Output)
	if err != nil {
		return "", err
	}
	identity, err := developmentIdentity(ctx)
	if err != nil {
		return "", err
	}
	var directory string
	if opts.SkipBuild {
		directory, err = BinaryDirectory(ctx, repo, opts.Configuration)
	} else {
		directory, err = Build(ctx, repo, opts.Configuration, "Mokusei", opts.SkipRuntime)
	}
	if err != nil {
		return "", err
	}
	runtime := filepath.Join(repo, ".build/go/mokusei-runtime")
	if !exists(runtime) || !exists(filepath.Join(directory, "Mokusei")) {
		return "", fmt.Errorf("native executable or Go runtime missing; build before packaging")
	}
	if err = os.MkdirAll(output, 0755); err != nil {
		return "", err
	}
	staging, err := os.MkdirTemp(output, ".native-bundle-")
	if err != nil {
		return "", err
	}
	defer os.RemoveAll(staging)
	app := filepath.Join(staging, product.AppName)
	executables := filepath.Join(app, "Contents/MacOS")
	resources := filepath.Join(app, "Contents/Resources")
	frameworks := filepath.Join(app, "Contents/Frameworks")
	for _, dir := range []string{executables, filepath.Join(resources, "licenses")} {
		if err = os.MkdirAll(dir, 0755); err != nil {
			return "", err
		}
	}
	executable := filepath.Join(executables, "Mokusei")
	nativeHash, err := copyStable(filepath.Join(directory, "Mokusei"), executable)
	if err != nil {
		return "", err
	}
	runtimeHash, err := copyStable(runtime, filepath.Join(executables, "mokusei-runtime"))
	if err != nil {
		return "", err
	}
	provenance, _ := json.MarshalIndent(map[string]any{"channel": opts.Channel, "configuration": opts.Configuration, "executableInputSHA256": nativeHash, "runtimeInputSHA256": runtimeHash}, "", "  ")
	if err = os.WriteFile(filepath.Join(resources, "build-provenance.json"), append(provenance, '\n'), 0644); err != nil {
		return "", err
	}
	goroot, err := run(ctx, repo, nil, goExecutable(), "env", "GOROOT")
	if err != nil {
		return "", err
	}
	if err = copyFile(filepath.Join(strings.TrimSpace(goroot), "LICENSE"), filepath.Join(resources, "licenses/Go-LICENSE"), 0644); err != nil {
		return "", err
	}
	if err = copyFile(filepath.Join(repo, "app/macos/build/AppIcon.icns"), filepath.Join(resources, "AppIcon.icns"), 0644); err != nil {
		return "", err
	}
	framework, err := stageVoiceFramework(ctx, repo, frameworks, resources)
	if err != nil {
		return "", err
	}
	rpaths, err := machORPaths(ctx, executable)
	if err != nil {
		return "", err
	}
	embedded := false
	for _, path := range rpaths {
		if path == "@executable_path/../Frameworks" {
			embedded = true
		}
		if !portableRPath(path) {
			if _, err = run(ctx, repo, nil, "/usr/bin/install_name_tool", "-delete_rpath", path, executable); err != nil {
				return "", err
			}
		}
	}
	if !embedded {
		return "", fmt.Errorf("native executable has no embedded Frameworks rpath")
	}
	deps, err := assertPortableMachO(ctx, executable, frameworks, false)
	if err != nil {
		return "", err
	}
	linked := false
	for _, dep := range deps {
		if dep == voiceFrameworkDependency {
			linked = true
		}
	}
	if !linked {
		return "", fmt.Errorf("native executable does not link embedded voice framework")
	}
	if _, err = assertPortableMachO(ctx, filepath.Join(executables, "mokusei-runtime"), "", false); err != nil {
		return "", err
	}
	// Copy the resource bundle declared by the native package, rather than
	// stale bundles left by targets that no longer own resources.
	if _, err = run(ctx, repo, nil, "/usr/bin/ditto", filepath.Join(directory, uiResourceBundle), filepath.Join(resources, uiResourceBundle)); err != nil {
		return "", err
	}
	version, err := os.ReadFile(filepath.Join(repo, "VERSION"))
	if err != nil {
		return "", err
	}
	if err = os.WriteFile(filepath.Join(app, "Contents/Info.plist"), []byte(infoPlist(strings.TrimSpace(string(version)), product)), 0644); err != nil {
		return "", err
	}
	if err = os.WriteFile(filepath.Join(app, "Contents/PkgInfo"), []byte("APPL????"), 0644); err != nil {
		return "", err
	}
	if err = validatePackagedResources(app); err != nil {
		return "", err
	}
	if _, err = run(ctx, repo, nil, "/usr/bin/plutil", "-lint", filepath.Join(app, "Contents/Info.plist")); err != nil {
		return "", err
	}
	if _, err = run(ctx, repo, nil, "/usr/bin/xattr", "-cr", app); err != nil {
		return "", err
	}
	fmt.Printf("Signing native %s bundle with %s\n", opts.Channel, identity.Name)
	if err = sign(ctx, framework, identity, voiceFrameworkIdentifier, ""); err != nil {
		return "", err
	}
	if err = sign(ctx, filepath.Join(executables, "mokusei-runtime"), identity, product.BundleIdentifier+".runtime", ""); err != nil {
		return "", err
	}
	if err = sign(ctx, app, identity, "", filepath.Join(repo, "app/macos/build/entitlements.app.plist")); err != nil {
		return "", err
	}
	if _, err = VerifySignature(ctx, app, product.BundleIdentifier, identity.Team); err != nil {
		return "", err
	}
	if _, err = VerifySignature(ctx, framework, voiceFrameworkIdentifier, identity.Team); err != nil {
		return "", err
	}
	if _, err = VerifySignature(ctx, filepath.Join(executables, "mokusei-runtime"), product.BundleIdentifier+".runtime", identity.Team); err != nil {
		return "", err
	}
	if _, err = probeFramework(ctx, framework, identity, product); err != nil {
		return "", err
	}
	publisher := filepath.Join(staging, "publish-bundle")
	if _, err = run(ctx, repo, nil, "/usr/bin/xcrun", "clang", "-arch", "arm64", "-Os", "-Wall", "-Wextra", "-Werror", filepath.Join(repo, "app/macos/build/publish-bundle.c"), "-o", publisher); err != nil {
		return "", err
	}
	archive := "-"
	if opts.Zip {
		archive = filepath.Join(staging, product.AppName+".zip")
		if _, err = run(ctx, repo, nil, "/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, archive); err != nil {
			return "", err
		}
	}
	destination := filepath.Join(output, product.AppName)
	if _, err = run(ctx, repo, nil, publisher, filepath.Join(output, ".native-publish.lock"), app, destination, archive, filepath.Join(output, product.AppName+".zip")); err != nil {
		return "", err
	}
	fmt.Println("Verified native bundle:", destination)
	return destination, nil
}
