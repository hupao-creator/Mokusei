# Local checks

Inspect the actual required checks before planning verification. Default to focused local checks and affected replays. Hosted CI currently provides advisory feedback and does not need to finish before merging. A local run cannot replace a check required by branch protection. Do not duplicate equivalent full local verification unless explicitly requested, diagnosing a failure, or covering an affected boundary CI cannot execute. `make check` remains the local entry point: Go formatting, package boundaries and static registration, allowed external Harness JS resources, `go vet ./...`, Go/Swift builds, the complete Swift suite, concurrency properties, module tests and directory-tag checks.

`make check-swift` streams the full Swift run through the shared CI reporter and
retains its log, actual process status and JSON summary under `.build/check-swift`.
It requires complete XCTest and Swift Testing summaries with matching counts;
an early process exit with status zero is a failure. Use the report and named
native launchers to distinguish an incomplete run from explicit capability skips.

The no-Node check rejects npm manifests and JS/TS source outside the four explicitly allowed external Pi/OpenCode shims. It includes Go files outside the shipped binary and across build tags. It does not substitute for reviewing process lifetimes, data ownership or the behavior of injected plugin capabilities.

Install the repository-local hook with `make install-hooks`. `.githooks/pre-commit` runs `make lint` without modifying files. The hook checks the working tree; when partially staging, inspect `git diff --cached` and ensure the committed contents match the validated files. A fresh checkout still needs explicit checks even if hooks have not been installed.

Use the [verification policy](../scripts/ci/verification-policy.md) to select default CI, extended native-CLI/system CI, and specifically triggered hardware acceptance. The [integration replay commands](../tools/verification/README.md) remain available for local diagnosis and uncovered boundaries. Do not add unit tests unless explicitly requested. A plain Swift test run reports explicit skips for missing display capabilities and external fixtures; hosted CI supplies the fixtures and separate Go/AppKit launchers and rejects unexpected skips. Native integration cases share the test-only process gate across targets. The [Swift audit](../tools/verification/swift-tests/README.md) records the historical investigation, not current CI coverage.

Pure documentation changes require diff and local-link review plus confirmation of the workflow's documentation scope. Wait for hosted checks only when actual protection rules require them. Native tests outside that scope are not reported as executed. Document checks actually run, the source revision, unexpected skips and platform/toolchain limitations. Follow the root AGENTS.md for failure diagnosis, failed-job-only retries and final merge coordination. A local-only requirement needs concrete independent defect coverage and a triggering change; replace it with equivalent CI coverage when available, and remove it as a mandatory gate when it has no specific high value.

Work-item conventions are in [issue-tracker.md](issue-tracker.md).
