# Local checks

`make check` runs Go formatting, architecture/import boundaries, static plugin
registration, the external Harness JS allowlist, `go vet ./...`, `go build ./...`
and the macOS Swift production build. `make lint` runs only the static checks;
`make typecheck` runs the Go and Swift builds.

The repository contains no first-party automated test suites or test targets.
The former unit/property/native integration tests, assertion replays, fixture
producers and test reporting commands have been removed. Do not add tests unless
explicitly requested. Build success does not establish runtime behavior.

Install the repository-local hook with `make install-hooks`; it runs `make lint`
without modifying files. Review the staged diff when partially staging.

Use the [CI guide](../scripts/ci/README.md) and
[verification policy](../scripts/ci/verification-policy.md). Confirm actual remote
required checks before a remote integration; local checks cannot bypass branch
protection. Documentation-only changes require diff and local-link review.
Record checks actually run, the revision and any platform/toolchain limitations.
The independent performance tools are measurements, not automated test coverage.

Work-item conventions are in [issue-tracker.md](issue-tracker.md).
