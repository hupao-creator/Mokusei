# Continuous integration

[The workflow](../../.github/workflows/ci.yml) runs portable Go checks on Linux
and native Go plus graphical Swift checks on macOS 26 arm64. `scripts/go.sh` is
the local Apple Silicon bootstrap; Actions installs the `go.mod` toolchain
with setup-go so Linux does not invoke a Darwin-only wrapper. CGO and system
SQLite remain enabled. The Darwin profile-rotation tests run on macOS, and
the native Moku clipboard bridge test uses synthetic NSData, not user data.

Every Go test invocation captures `go test -json`, stderr and the actual exit
code. An always-run report includes failed commands and absent/interrupted
captures. Its four primary statistics have these definitions:

- **tests**: distinct `(package, Test)` nodes observed, including parent tests,
  subtests and examples. Incomplete nodes remain counted and fail the gate.
- **suites**: packages reported by the command, including no-test packages.
- **failures**: terminal failed test nodes plus failed packages that have no
  failed test node. Go does not expose an assertion-level issue count. A failed
  parent and failed subtest are two nodes, not two inferred independent bugs.
- **skipped**: terminal skipped test nodes. Skipped packages and packages with
  no test files are separately listed; neither is silently counted as passing.

The JSON report also names failed tests/packages/builds and incomplete work.
Nonzero/missing process status, malformed events, missing completion events,
empty execution and all-skipped runs fail the reporting step. Use `-count=1`;
the report rejects repeated terminal events. Unit, race, property and platform
runs overlap, so their counts are not unique coverage totals.

Swift reports XCTest and Swift Testing separately. XCTest failures and Swift
Testing issues are framework counts, not interchangeable assertion counts.
DirectoryTag runs once inside the full suite. CI does not force headless mode;
missing display capability and unexpected skipped methods fail the report.
The exact allowlist contains only methods executed through the required live Go
fixtures or isolated AppKit launchers. Four Go producers supply the remaining
Swift fixtures before the full suite. All three replay reports must complete.

`replays.py` runs the existing integration commands serially within each group,
records command/exit/status/log evidence from before execution, kills its owned
process group on timeout, and rejects native test skips. Linux runs `runtime`
and `adapters`; macOS runs `fixtures`, `interop` and `native` around the full
Swift suite. It does not recreate product logic. Reproduce a group with
`python3 scripts/ci/replays.py GROUP --go ./scripts/go.sh --output /tmp/new-evidence`.
Native groups require the current Swift build; for local full-suite fixture use,
export the four paths recorded by the `fixtures` group.

Dispatch `CI` with `extended=true` for pinned external CLI loopback verification,
Moku system matrices and the full 30-minute stability gate. These checks are
separate from the fast PR jobs and never need a real model account. See the
[value and execution policy](verification-policy.md) for triggers, equivalent
local-check replacement and the limited hardware acceptance that remains.

Raw test logs and JSON summaries are retained as Actions artifacts even when
tests fail. Missing logs are reported as not run, never as zero failures.
Hosted runner execution is established by actual workflow results, not by local
YAML validation or local tests.

`python3 scripts/ci/verify-go-reporting.py --go ./scripts/go.sh` exercises the
actual reporter with temporary Go packages: pass, parent/subtest failure, skips,
panic, package failure before tests, build failure and no tests. It also rejects
truncated, malformed and absent captures. CI runs the same verifier on Linux.
