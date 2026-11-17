# Continuous integration

[CI](../../.github/workflows/ci.yml) runs production builds, static checks and the
routine [property inventory](../../tools/verification/pbt/README.md). There are no
ordinary example/table unit-test suites. Each property names its module contract,
input domain and oracle; generated sample counts are not code-coverage percentages.

Linux runs Go formatting, architecture/import and static registration checks,
`go vet ./...`, `go build ./...` and Go PBT (seven Rapid properties, 100 cases each,
seed 1; Report HTML fuzz, 10s). macOS 26 arm64 builds all Go packages and the
Swift production products with warnings as errors and the Metal build plugin,
then runs 480 generated geometry cases with seed 1. Native work is serial on one
runner. Mounted Canvas and real Codex system properties are opt-in local/CI
commands; they are not part of this workflow's required coverage.
CGO/system SQLite and the exact Go toolchain in `go.mod` remain enabled.
SwiftPM and Go caches reuse compilation; current sources are always built.

`scope.py` classifies a conservative documentation-only diff from complete paths
and Git modes. Only root `AGENTS.md`, `README.md`, `CONTEXT.md`, the root Go/native/demo
READMEs and direct `.agents/*.md` / `scripts/ci/*.md` files are allowlisted,
with regular-file modes. Module READMEs, `docs/`, `design/`, packaged resources,
symlinks and unknown/mixed changes run production builds; dispatches do too.
The fast path validates diff whitespace, not Markdown links or factual accuracy.

The `Complete coverage` aggregate requires scope and Go plus the macOS job
for changes outside the documentation allowlist. It certifies declared
build/static and routine property checks, not interaction, performance or
opt-in system coverage. Property artifacts retain commands, revision/source
identity, seeds, budgets, output and failure corpus. A skip, empty filter,
missing capability or timeout cannot become a property pass.
Actual remote protection rules still govern remote integration.

PR/main runs cancel obsolete runs only within their own event/ref. Dispatches
have separate groups. Other PRs are independent. The macOS job has a 60-minute
hang guard; this is not a whole-run acceptance deadline.

[Self-hosted deployment](self-hosted.md) retains isolated macOS routing and fork
PR boundaries. The optional [Overview performance workflow](../../.github/workflows/overview-performance.yml)
remains a manually dispatched measurement tool with fixed baseline/candidate
SHAs. It is separate from required build checks.

Locally use `make lint`, `make typecheck` and `make pbt`, or their combined `make check`.
See the [verification policy](verification-policy.md) for limitations.

## Independent performance boundaries

[Performance contract](../../.github/workflows/performance-contract.yml) runs the
portable judgment CLI's generated properties and e2e scenarios on its configured
path triggers. [Runtime A/B](../../.github/workflows/runtime-performance.yml) and
[Overview A/B](../../.github/workflows/overview-performance.yml) are explicit
dispatch measurements with fail-closed judgments. Their reports and gate scope
are defined in the [performance guide](../../tools/benchmarks/gate/README.md).
These jobs are separate from `Complete coverage`; workflow presence does not
configure remote required checks. Signed optical UX suites have no hosted job.

## Product interaction boundaries

[Desktop e2e](../../.github/workflows/e2e.yml) is an independent manual, serial
hosted workflow for READ and SETTINGS. The [scenario inventory](../../tools/e2e/scenarios.json)
records the additional operator-assisted Composer boundary; no unattended
Composer job is configured. Real Runtime/native Codex/UI runs use deterministic
external model responses, not real provider availability or quality. Evidence
verification preserves failures and cleanup status; a report for another commit
does not establish the combined revision's GUI behavior.
