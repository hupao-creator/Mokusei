// Package swiftfixture constructs the real Swift test client used by Go replays.
package swiftfixture

import (
	"context"
	"os"
	"os/exec"
)

// Test leaves fixture environment, output and behavioral assertions with the
// caller. CI enables reuse only after validating this run's build manifest;
// ordinary local invocations still build the current sources.
func Test(ctx context.Context, extra ...string) *exec.Cmd {
	args := []string{"swift", "test", "--package-path", "app/macos"}
	if os.Getenv("MOKUSEI_SWIFT_SKIP_BUILD") == "1" {
		args = append(args, "--skip-build")
	}
	return exec.CommandContext(ctx, "/usr/bin/xcrun", append(args, extra...)...)
}
