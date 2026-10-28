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

## Parallel execution and the time budget

The normal workflow runs Linux checks/replays alongside two macOS preparation
jobs. One macOS job warms Go binaries and generates the five real Go fixtures;
the other **always builds** current Swift sources and all test targets. It lists
methods from that binary, then partitions every discovered suite into five
balanced groups, accounting for the replays assigned to each runner. Historical
suite weights affect placement only: new suites are
automatically included, never silently omitted.

The successful build is shared through a unique run/attempt cache key. Cache
transport preserves executable permissions and framework symlinks. Each consumer
checks the same revision, canonical checkout path, architecture, Debug configuration,
Xcode/Swift/SDK/compiler fingerprint and producer run/attempt before using
`--skip-build`. There is no cache-miss fallback to an old binary. Ordinary local
Go/Swift replay commands still build unless explicitly given the verified-build
option. Re-running failed jobs can reuse the successful producer's recorded attempt.

Five macOS runners then execute concurrently. Each runs its Swift shard and
assigned Go/Swift or isolated AppKit replays serially; scheduling weights balance
the combined workload. Tests within one graphical session remain serial.
Only the two capture-dependent tag-glass methods need the
standalone host; its other five methods already execute in the Swift shards.
The four input/responder methods deferred by the browser, history composer and
Report suites share one isolated host, without repeating their other methods.
The Go producer also exports this attempt's warmed race and ordinary build caches;
downstream jobs do not depend on an older immutable dependency-cache entry.
Swift CI omits the editor index store while retaining Debug code and test targets.
DirectoryTag is also executed once. Four native-CLI/system runners are separate
`extended=true` workflow dispatches, which do not repeat the normal workflow.
Default and extended attempts on the same branch share a concurrency group:
extended attempts wait instead of taking the default attempt's macOS slots,
while a new commit cancels stale work. Dispatch the extended gate after the
default run completes so its queue does not consume the time budget. CLI installs
are cached by exact package/version and architecture; a download gets at most
three minutes instead of exhausting the verification budget.
The removed long-running stability check is not replaced with another soak.

Each attempt must finish in **less than fifteen minutes**. Owned test/build commands
stop against a shared 840-second deadline measured from GitHub's current attempt
start, reserving cleanup time. Jobs also have a fourteen-minute timeout. Final job
coverage and elapsed time are checked after uploading summaries, with cleanup
headroom. Runner queue and Action download/cache delays are visible in the
observed whole-attempt time; a slow or incomplete attempt cannot be reported as
successful. Use actual hosted start/completion timestamps to validate the target.

## Native coverage evidence

Swift reports XCTest and Swift Testing separately. XCTest failures and Swift
Testing issues are framework counts, not interchangeable assertion counts.
The builder and all five consumers must supply identical manifests. Actual
terminal method identities, counts and receipts must match the discovered
inventory exactly once across shards. Same-count omissions/substitutions fail.
Named fixture/isolated-host skips additionally need observed passing outcomes in
the required replay logs; a new skip is not admitted just because most tests ran.

CI enables motion and transparency only in the disposable runner account: the
[stock image disables them](https://github.com/actions/runner-images/blob/19874e7af7ed79e9036b52cc749da639f5c9130f/images/macos/scripts/build/configure-system.sh).
Local commands never alter developer accessibility preferences. Rendered geometry
uses the actual backing scale for one-physical-pixel precision; pure camera math
keeps its numerical tolerance. Real-window resize fixtures fit the current
screen, while fixed component fixtures retain their specified logical viewport.

`replays.py` runs existing production-boundary commands, retaining commands,
exit status, logs and interrupted work. Reproduce a group locally with
`python3 scripts/ci/replays.py GROUP --go ./scripts/go.sh --output /tmp/new-evidence`.
Native groups require the current Swift build. The
[verification policy](verification-policy.md) records each gate's independent
value, triggers and the limited hardware/signed-package acceptance that remains.

Local `make check-swift` runs `python3 scripts/ci/swift-tests.py --run` with
`.build/check-swift` as its output directory. It streams the real `xcrun swift
test` output while retaining `swift-tests.log`, the command and actual exit code
in `swift-status.json`, and the framework counts/errors in `swift-summary.json`.
Success requires exit status zero, both frameworks' completion summaries and
matching case/skip counts. A process that exits zero partway through Swift
Testing fails this check. A complete run still does not certify skipped native
flows; run their named launchers separately.

To inspect an existing capture without starting Swift, supply its actual process
status explicitly:

```sh
python3 scripts/ci/swift-tests.py --full-log /absolute/swift-tests.log \
  --exit-code 0 --output-dir /tmp/swift-log-review
```

The no-argument CI mode audits collected shard/replay artifacts and writes
`swift-summary.json` under `RUNNER_TEMP`. Local capture and distributed CI share
`swift_reporting.py`; CI adds manifest and observed-identity checks.

Artifacts are refreshed when the same job is retried; per-attempt raw job logs
remain available in GitHub Actions. Raw test logs and JSON summaries are retained as Actions artifacts even when
tests fail. Missing logs are reported as not run, never as zero failures.
Hosted runner execution is established by actual workflow results, not by local
YAML validation or local tests.

`python3 scripts/ci/verify-go-reporting.py --go ./scripts/go.sh` exercises the
actual reporter with temporary Go packages: pass, parent/subtest failure, skips,
panic, package failure before tests, build failure and no tests. It also rejects
truncated, malformed and absent captures. CI runs the same verifier on Linux.

## Pull request merge gates

The active [main-pr-gates ruleset](https://github.com/hupao-creator/Mokusei/rules/26004586)
requires changes to `main` to go through a pull request. Before merging, the
branch must be up to date with `main`, and these GitHub Actions checks must pass:

- `Go / Linux`
- `Complete coverage and fifteen-minute budget`

The complete-coverage check includes every default job and the wall-clock budget.
Optional extended dispatches use a distinct aggregate check name and cannot
satisfy this required default check.

All code-review conversations must be resolved. General PR timeline comments
have no resolution state and are not covered by this rule. The required number
of approving reviews is zero; the review gate is resolution of outstanding
conversations.

There are no bypass actors, including repository administrators. Force pushes
and deletion of `main` are blocked. Check results must come from the GitHub
Actions app (integration ID `15368`).

GitHub stores this ruleset separately from the workflow. When adding or renaming
required CI jobs, coordinate the required-check contexts with the workflow and
update this list before merging. A stale context blocks merging indefinitely;
an omitted context leaves that job outside the merge gate. Keep optional,
manually dispatched jobs out of the required PR checks.

Inspect the effective configuration with the locally authenticated `gh` CLI:

```sh
gh api repos/hupao-creator/Mokusei/rulesets/26004586
gh api repos/hupao-creator/Mokusei/rules/branches/main
gh pr checks <number> --repo hupao-creator/Mokusei --required
```
