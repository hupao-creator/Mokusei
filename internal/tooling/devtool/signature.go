package devtool

import (
	"context"
	"crypto/sha1"
	"crypto/x509"
	"encoding/hex"
	"encoding/pem"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

const voiceFrameworkName = "LiveKitWebRTC.framework"
const voiceFrameworkIdentifier = "io.livekit.LiveKitWebRTC"
const voiceFrameworkDependency = "@rpath/LiveKitWebRTC.framework/LiveKitWebRTC"

type signingIdentity struct{ Hash, Name, Team, Keychain string }
type Signature struct{ Identifier, Team, Requirement string }

func developmentIdentity(ctx context.Context) (signingIdentity, error) {
	keychain := strings.TrimSpace(os.Getenv("CSC_KEYCHAIN"))
	args := []string{"find-identity", "-v", "-p", "codesigning"}
	if keychain != "" {
		args = append(args, keychain)
	}
	out, err := run(ctx, "", nil, "/usr/bin/security", args...)
	if err != nil {
		return signingIdentity{}, err
	}
	selector := strings.TrimSpace(os.Getenv("CSC_NAME"))
	matches := regexp.MustCompile(`(?m)^\s*\d+\) ([A-Fa-f0-9]{40}) "(Apple Development: [^"]+)"\s*$`).FindAllStringSubmatch(out, -1)
	var selected []signingIdentity
	for _, m := range matches {
		if selector == "" || selector == m[2] || strings.EqualFold(selector, m[1]) {
			selected = append(selected, signingIdentity{Hash: m[1], Name: m[2], Keychain: keychain})
		}
	}
	if len(selected) != 1 {
		return signingIdentity{}, fmt.Errorf("expected one valid Apple Development signing identity, found %d; set CSC_NAME to a full certificate name or SHA-1 (ad-hoc signing is unsupported)", len(selected))
	}
	identity := selected[0]
	args = []string{"find-certificate", "-a", "-c", identity.Name, "-p"}
	if keychain != "" {
		args = append(args, keychain)
	}
	out, err = run(ctx, "", nil, "/usr/bin/security", args...)
	if err != nil {
		return identity, err
	}
	data := []byte(out)
	for len(data) > 0 {
		block, rest := pem.Decode(data)
		if block == nil {
			break
		}
		data = rest
		cert, parseErr := x509.ParseCertificate(block.Bytes)
		if parseErr != nil {
			continue
		}
		hash := sha1.Sum(cert.Raw)
		if strings.EqualFold(hex.EncodeToString(hash[:]), identity.Hash) && len(cert.Subject.OrganizationalUnit) > 0 {
			identity.Team = cert.Subject.OrganizationalUnit[0]
			break
		}
	}
	if identity.Team == "" {
		return identity, fmt.Errorf("cannot determine signing team for %s", identity.Name)
	}
	return identity, nil
}
func sign(ctx context.Context, path string, identity signingIdentity, identifier, entitlements string) error {
	args := []string{"--force", "--sign", identity.Hash, "--options", "runtime", "--timestamp=none"}
	if identity.Keychain != "" {
		args = append(args, "--keychain", identity.Keychain)
	}
	if identifier != "" {
		args = append(args, "--identifier", identifier)
	}
	if entitlements != "" {
		args = append(args, "--entitlements", entitlements)
	}
	args = append(args, path)
	_, err := run(ctx, "", nil, "/usr/bin/codesign", args...)
	return err
}
func VerifySignature(ctx context.Context, path, identifier, expectedTeam string) (Signature, error) {
	if _, err := run(ctx, "", nil, "/usr/bin/codesign", "--verify", "--deep", "--strict", path); err != nil {
		return Signature{}, err
	}
	// codesign emits metadata to stderr and requirements to stdout.
	out, err := combined(ctx, "/usr/bin/codesign", "--display", "--verbose=4", "-r-", path)
	if err != nil {
		return Signature{}, err
	}
	first := func(pattern string) string {
		m := regexp.MustCompile(pattern).FindStringSubmatch(out)
		if len(m) > 1 {
			return m[1]
		}
		return ""
	}
	team := first(`(?m)^TeamIdentifier=([^\n]+)$`)
	requirement := first(`(?m)^(?:# )?(designated => .+)$`)
	if !strings.Contains(out, "Identifier="+identifier+"\n") || !strings.Contains(out, "Authority=Apple Development: ") || team == "" || team == "not set" || (expectedTeam != "" && team != expectedTeam) || !strings.Contains(requirement, "anchor apple generic") || regexp.MustCompile(`\bcdhash\b`).MatchString(requirement) || !strings.Contains(out, "(runtime)") {
		return Signature{}, fmt.Errorf("bundle has no stable hardened Apple Development signature: %s\n%s", path, out)
	}
	return Signature{Identifier: identifier, Team: team, Requirement: requirement}, nil
}
func machORPaths(ctx context.Context, path string) ([]string, error) {
	out, err := run(ctx, "", nil, "/usr/bin/otool", "-l", path)
	if err != nil {
		return nil, err
	}
	var result []string
	for _, m := range regexp.MustCompile(`cmd LC_RPATH\s+cmdsize \d+\s+path ([^\n]+) \(offset \d+\)`).FindAllStringSubmatch(out, -1) {
		result = append(result, m[1])
	}
	return result, nil
}
func portableRPath(path string) bool {
	return path == "@executable_path/../Frameworks" || path == "@loader_path" || path == "/usr/lib/swift"
}
func assertPortableMachO(ctx context.Context, path, frameworks string, allowUniversal bool) ([]string, error) {
	out, err := run(ctx, "", nil, "/usr/bin/lipo", "-archs", path)
	if err != nil {
		return nil, err
	}
	arches := strings.Fields(out)
	arm := false
	for _, a := range arches {
		if a == "arm64" {
			arm = true
		}
		if a != "arm64" && a != "x86_64" {
			return nil, fmt.Errorf("unsupported binary architecture %s: %s", a, path)
		}
	}
	if !arm || (!allowUniversal && len(arches) != 1) {
		return nil, fmt.Errorf("expected arm64 binary: %s", path)
	}
	ids, err := run(ctx, "", nil, "/usr/bin/otool", "-D", path)
	if err != nil {
		return nil, err
	}
	own := map[string]bool{}
	for _, line := range strings.Split(ids, "\n") {
		own[strings.TrimSpace(line)] = true
	}
	out, err = run(ctx, "", nil, "/usr/bin/otool", "-L", path)
	if err != nil {
		return nil, err
	}
	var dependencies []string
	expression := regexp.MustCompile(`^\s+(.+?)\s+\(compatibility version [^\n]+\)\s*$`)
	for _, line := range strings.Split(out, "\n") {
		if len(line) == 0 || (line[0] != '\t' && line[0] != ' ') {
			continue
		}
		m := expression.FindStringSubmatch(line)
		if len(m) != 2 {
			return nil, fmt.Errorf("unrecognized dependency in %s: %s", path, line)
		}
		dep := m[1]
		if own[dep] {
			continue
		}
		dependencies = append(dependencies, dep)
		if strings.HasPrefix(dep, "/usr/lib/") || strings.HasPrefix(dep, "/System/Library/") {
			continue
		}
		if frameworks != "" && dep == voiceFrameworkDependency {
			root, err := filepath.EvalSymlinks(frameworks)
			if err != nil {
				return nil, err
			}
			target, err := filepath.EvalSymlinks(filepath.Join(root, voiceFrameworkName, "LiveKitWebRTC"))
			if err != nil {
				return nil, err
			}
			rel, err := filepath.Rel(root, target)
			if err == nil && rel != ".." && !strings.HasPrefix(rel, "../") && !filepath.IsAbs(rel) {
				continue
			}
		}
		return nil, fmt.Errorf("non-system dynamic dependency in %s: %s", path, dep)
	}
	return dependencies, nil
}
