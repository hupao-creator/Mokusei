# Local checks

`make check` runs Go formatting, architecture/import boundaries, static plugin
registration, the external Harness JS allowlist, `go vet ./...`, `go build ./...`
and the macOS Swift production build. `make lint` runs only the static checks;
`make typecheck` runs the Go and Swift builds.

In this source tree, no first-party test suites, native test targets,
assertion replays or test-only fixture producers are configured. No PBT/e2e
regression gate is configured. Ordinary unit tests are not a project boundary;
do not add or restore them. Build success does not establish runtime behavior.

Follow the [document-driven workflow](../AGENTS.md#文档驱动): read the owning guide,
check its facts against implementation, document implemented behavior and
constraints, then derive PBT properties, e2e scenarios or benchmark metrics and
criteria from those facts. Link the guide and actual evidence in the
[fact/verification index](../docs/facts.md). Keep gaps and blocked/skipped results
explicit. The index is not a second specification or a claim of test coverage.
e2e owns interactions, PBT owns Moku runtime, and benchmarks own user experience.
Extra PBT coverage needs a concrete reason and does not replace that ownership.
Independent adversarial review checks documentation, implementation and evidence
at a fixed commit, with findings resolved and rechecked. The coordinator arranges
GLM-5.3 reviews for final checkpoints and combined revisions without adding a user approval step.

Install the repository-local hook with `make install-hooks`; it runs `make lint`
without modifying files. Review the staged diff when partially staging.

Use the [CI guide](../scripts/ci/README.md) and
[verification policy](../scripts/ci/verification-policy.md). Confirm actual remote
required checks before a remote integration; local checks cannot bypass branch
protection. Documentation-only changes require diff and local-link review.
Record checks actually run, the revision and any platform/toolchain limitations.
The independent performance tools are measurements, not automated test coverage.

Work-item conventions are in [issue-tracker.md](issue-tracker.md).
