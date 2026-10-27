# Local checks

Run `make check` before merging code. It checks Go formatting, parses all Go imports for package boundaries, verifies static registration and the allowed external Harness JS resources, runs `go vet ./...`, builds all Go packages, builds the Swift package, runs the complete Swift test suite, the concurrency properties, module tests and directory-tag checks.

The no-Node check rejects npm manifests and active JS/TS outside the explicit external Pi/OpenCode shims and inactive Git reference source. It includes Go files outside the shipped binary and across build tags. It does not substitute for reviewing process lifetimes, data ownership or the behavior of injected plugin capabilities.

Install the repository-local hook with `make install-hooks`. `.githooks/pre-commit` runs `make lint` without modifying files. The hook checks the working tree; when partially staging, inspect `git diff --cached` and ensure the committed contents match the validated files. A fresh checkout still needs explicit checks even if hooks have not been installed.

Run the affected [integration replay commands](../tools/verification/README.md). Do not add unit tests unless explicitly requested. A plain Swift test run reports explicit skips for missing display capabilities and external fixtures; use the Go settings launcher for the real native settings flow. Native integration cases share the test-only process gate across targets. See [the Swift audit](../tools/verification/swift-tests/README.md) for reproduction commands and the skip inventory. A green headless run does not certify skipped native flows.

Pure documentation changes require diff and local-link review. Code changes also require `make check` and affected replays. Document the checks actually run and platform/toolchain limitations; a past success log does not validate the current revision.

Work-item conventions are in [issue-tracker.md](issue-tracker.md).
