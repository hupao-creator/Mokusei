# Continuous integration

[The workflow](../../.github/workflows/ci.yml) runs portable Go checks on Linux
and native Go plus graphical Swift checks on macOS 26 arm64. `scripts/go.sh` is
the local Apple Silicon bootstrap; Actions installs the `go.mod` toolchain
with setup-go so Linux does not invoke a Darwin-only wrapper. CGO and system
SQLite remain enabled. The Darwin profile-rotation tests run on macOS, and
the native Moku clipboard bridge test uses synthetic NSData, not user data.

`scope.py` compares the complete PR or push diff before scheduling builds. Only
ordinary non-executable root AGENTS.md/CONTEXT.md/README.md, README entry points
in `internal`, `app/macos`, `tools/verification` and `demos`, and Markdown directly
under `.agents`/`scripts/ci` qualify for documentation-only validation. Other
README paths are not inferred to be documentation: they may be bundled resources.
Both sides of a rename and both Git file modes are checked. Mixed/unknown paths,
empty diffs and manual dispatches retain full verification. Documentation-only
runs still execute the scope, `Go / Linux` and aggregate checks: they validate the
diff and explicitly report that native/build tests are outside this scope. Local
link review remains required. No workflow-level path filter leaves required
checks pending. This avoids native runner work for documentation-only PRs and
their main pushes without omitting coverage for code changes.

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

## Parallel execution and queueing

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
The five input/responder and native-panel methods deferred by the browser, history composer and
Report suites share one isolated host, without repeating their other methods.
The Go producer also exports this attempt's warmed race and ordinary build caches;
downstream jobs do not depend on an older immutable dependency-cache entry.
Swift CI omits the editor index store while retaining Debug code and test targets.
DirectoryTag is also executed once. Four native-CLI/system runners are separate
`extended=true` workflow dispatches, which do not repeat the normal workflow.
Default PR/main and extended runs share a repository-wide concurrency queue
(`queue: max`, no cancellation of another queued run). One workflow cohort is
admitted at a time; its Linux checks, preparation jobs and native shards still
run in parallel. The scope job rejects obsolete PR heads/bases and superseded
main pushes before scheduling native work. Explicit dispatches remain pinned to
the requested revision. This is a workflow queue, not GitHub Merge Queue.
CLI installs are cached by exact package/version and architecture, and downloads
retain their three-minute execution timeout. The removed long-running stability
check is not replaced with another soak.

There is **no whole-run fifteen-minute merge gate** and no shared 840-second
command deadline. Queueing cannot consume a later command's execution allowance.
Each owned command has an independent thirty-minute default timeout and each
build/test job has a thirty-minute timeout to stop hung work; narrower existing
CLI/test limits remain in force. Timeout is incomplete execution and still fails
coverage. These execution guards are not a wall-clock acceptance requirement.

The aggregate reports each job's queue time, attempt time and elapsed time since
the first trigger. Carried-forward successful jobs on partial retries retain
old execution timestamps even when GitHub assigns new job IDs; they are labeled
reused, not counted as new work. Time is diagnostic and does not decide merge
eligibility. All required jobs and complete observed coverage must still pass.
The queue only coordinates workflows using this key in this repository; other
repositories or older workflow revisions may still consume account capacity.

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
The `native-controls` group also runs the [windowless scrollbar replay](../../tools/verification/scrollbars/README.md),
which compiles the production viewport policy and checks native control state
without creating a window. It does not count as rendered scrollbar coverage.

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

Artifacts have an `-attempt-N` suffix and are never overwritten by a retry.
Each consumer downloads the fixture producer's exact artifact name. The
aggregate selects the newest numeric execution attempt for each of the seven
native slots from API metadata before downloading only those archives into a
separate audit directory. Earlier captures stay available without repeated
downloads on each retry. It never selects by passing status;
a newer failed/incomplete receipt cannot be replaced by an older success. Failed
or missing required jobs prevent certification even if older artifacts exist.
Successful prior producers/shards can be reused by `gh run rerun RUN --failed`;
the unchanged build and method-identity audit still applies. Selection mappings,
raw logs and screenshots remain available for diagnosis. Swift failures print
bounded assertion excerpts directly in the job log and summary; replay errors
report command status and timeout reason even when their log is empty.
Missing logs are reported as not run, never as zero failures.
GitHub [supports `queue: max`](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency); actionlint 1.7.12 predates that syntax. Local lint
ignores only its exact unknown-queue-key diagnostic, and actual hosted workflow
acceptance remains required.

Hosted runner execution is established by actual workflow results, not by local
YAML validation or local tests.

`python3 scripts/ci/verify-go-reporting.py --go ./scripts/go.sh` exercises the
actual reporter with temporary Go packages: pass, parent/subtest failure, skips,
panic, package failure before tests, build failure and no tests. It also rejects
truncated, malformed and absent captures. CI runs the same verifier on Linux.

`python3 scripts/ci/verify-ci-control.py` exercises the real scope and evidence
entry points with temporary Git histories and retained artifact directories,
and runs real subprocess success, nonzero exit and command-timeout termination cases.
It runs on Linux alongside the existing Go reporter verifier.

## Pull request protection and advisory CI

The active [main-pr-gates ruleset](https://github.com/hupao-creator/Mokusei/rules/26004586)
requires changes to `main` to go through a pull request. CI is advisory:
`Go / Linux` and `Complete coverage` are no longer required status checks,
and the CI requirement to be up to date with `main` has been removed with them.
The workflow still runs on PRs and main pushes, with manual extended dispatches
available. Failures remain visible for diagnosis but do not block merging.
The complete-coverage check still audits every default job and the selected
verification scope; its internal evidence requirements are unchanged.

All code-review conversations must be resolved. General PR timeline comments
have no resolution state and are not covered by this rule. The required number
of approving reviews is zero; the review gate is resolution of outstanding
conversations.

There are no bypass actors, including repository administrators. Force pushes
and deletion of `main` remain blocked. No other protection was disabled.

GitHub stores this ruleset separately from the workflow. Editing or renaming
workflow jobs does not change remote merge requirements. Inspect the effective
configuration with the locally authenticated `gh` CLI:

```sh
gh api repos/hupao-creator/Mokusei/rulesets/26004586
gh api repos/hupao-creator/Mokusei/rules/branches/main
gh pr checks <number> --repo hupao-creator/Mokusei --required
```
