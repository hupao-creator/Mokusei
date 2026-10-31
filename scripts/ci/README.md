# Continuous integration

[The workflow](../../.github/workflows/ci.yml) runs portable Go checks and
protocol replays on Linux alongside one native verification job on macOS 26
arm64. The native job builds once and runs the complete ordinary Swift suite,
Go/Swift interop and graphical replays serially in the same session. There are
no test shards, placement weights or cross-runner build/fixture transfers.

CGO and system SQLite remain enabled. Actions installs the toolchain from
`go.mod`; `scripts/go.sh` remains the local Apple Silicon bootstrap. Darwin-only
profile-rotation and clipboard-bridge tests run in the native job.

## Scope and scheduling

`scope.py` compares the complete PR or push diff before scheduling builds. Only
ordinary non-executable root AGENTS.md/CONTEXT.md/README.md, README entry points
in `internal`, `app/macos`, `tools/verification` and `demos`, and Markdown directly
under `.agents`/`scripts/ci` qualify for documentation-only validation. Both sides
of renames and both Git file modes are checked. Other README paths can be runtime
resources and do not qualify. Unknown/mixed paths, empty diffs and manual
runs retain full verification. Documentation-only runs execute scope, `Go / Linux`
and the aggregate; they validate the diff and explicitly state that native/build
tests were outside the scope. Local link review remains required.

PR and main push runs have separate per-ref concurrency groups. A newer revision
cancels that ref's older work using GitHub's cancelled state; it is never reported
as a successful `Complete coverage` check. Other PRs do not share a repository-wide
lock. Explicit dispatches have run-specific groups and cannot cancel PR/main work.
There is no custom API-based obsolete-head/base rejection: the required check
belongs to its actual checked-out revision and the remote strict ruleset controls
whether a PR is up to date. This is not GitHub Merge Queue.

Linux Go checks and the `runtime`/`adapters` protocol groups remain independent
jobs. Those groups represent different production boundaries, not slices of the
Swift inventory. Extended CLI/system dispatches remain separate from normal CI.
Hosted runner capacity can still queue jobs; removing the repository-wide lock
does not create additional account capacity.

## One native session

The native job performs these stages:

1. Prepare Xcode and Metal, restore the Swift compilation cache, and always build
   current sources and every test target with the resolved dependency versions.
2. Discover the complete inventory from the resulting binary and record current
   commit, workspace, architecture, configuration, toolchain, run and attempt.
3. Verify the graphical environment, run native Go checks and generate the five
   real Go fixture producers' six output files in the same evidence directory.
4. Execute every ordinary Swift method once with `--skip-build --no-parallel`.
5. Run all ten `interop` checks and all ten `native` checks serially.
6. Audit the actual ordinary/native outcomes, then retain logs, receipts, captures
   and the coverage summary together.

The Go and Swift compiler caches accelerate future runs, but cannot certify test
results. Even an exact Swift cache hit is followed by a current-source build and
new inventory. `MOKUSEI_SWIFT_SKIP_BUILD` is set only after that build and manifest
verification succeed. Replays reuse that same local build; no other runner's
binary or prior attempt's evidence is needed. Swift omits the editor index store
while retaining Debug code and test targets. DirectoryTag executes once.

The ordinary command has no positive suite filter. Its explicit `--skip` excludes
only full identities recorded in `swift_ownership.py`, including Swift Testing's
runtime source-location suffix. This is selection, not a passing skip result:
each excluded method must produce its actual passing outcome, marker and zero
exit receipt in the declared `native/tag-glass-captures` check. The title-reversal
pixel proof needs that host's AppKit loop and WindowServer delivery.

The same capture check owns
`SwiftUIOverviewInteractionTests.excerptRevealKeepsMovingThroughRewriteAndWidthChanges`.
It observes the production excerpt's intermediate ink through fixed-width reveal,
rewrite cancellation and a measured local width change, using complete WindowServer
frames in the AppKit host. `EXCERPT_INK_MOTION_CONFIRMED` is emitted only after
those pixel assertions. Its screenshots, frame times and source/binary provenance
are retained under the capture evidence's `excerpt` directory. Task completion
or final text alone cannot pass this exactly-once owner contract.
The native cloud/scan composition and retained Overview return cases use that
same `native/tag-glass-captures` owner, with
`NATIVE_OVERVIEW_DECORATION_MOTION_CONFIRMED` and
`OVERVIEW_RETAINED_RETURN_CONFIRMED` respectively.

Named live-Go-fixture and isolated-AppKit methods can defer ordinary execution
only when their mandatory replay supplies the observed passing result. Settings
capsule transitions, native input/responder/pointer cases and model-selector flows
keep their existing native launchers and assertions. No new skip is admitted
merely because the rest of the suite passed. The generated Moku Timer fixture is
available before the full suite, so its ordinary consumer must execute normally.

CI enables motion and transparency only in the disposable runner account: the
[stock image disables them](https://github.com/actions/runner-images/blob/19874e7af7ed79e9036b52cc749da639f5c9130f/images/macos/scripts/build/configure-system.sh).
Local commands do not alter developer accessibility preferences. Rendered geometry
uses actual backing scale, while pure camera math keeps its numerical tolerance.
Real-window fixtures fit the current display and retain their specified logical
component sizes. All GUI work within this session remains serial.

## Evidence and failure semantics

`swift-native.py` owns build identity, discovery and ordinary execution.
`build-manifest.json`, `swift.json` and `swift.log` live at the native evidence
root; `ci-fixtures`, `ci-interop` and `ci-native` contain the required replay reports.
`swift-tests.py` audits that directory before the native job can pass. Its actual
method identities and framework totals must match the discovered inventory, with
exactly one ordinary outcome or the declared native owner. Same-count omissions,
substitutions, duplicate methods, unexpected skips and missing terminal summaries
fail. An early exit with status zero cannot certify incomplete tests.

Every mandatory native owner needs one successful process receipt, one passing
method outcome and its execution marker at the declared group/check. A pass at
another check does not substitute. Reports limited with `--check` are useful for
local diagnosis but cannot satisfy a complete CI replay group. Display-capability
skips fail CI. The audit checks the current revision and the complete ordinary
selection rather than inferring execution from a command or cache hit.

Each native attempt uploads one `macos-native-evidence-attempt-N` artifact. A
failed-job-only retry reruns the entire native job when that job failed; successful
Linux jobs can be carried forward. There is no merging of seven native slots or
selection of old passing artifacts. Prior attempts remain available for diagnosis.
Failure summaries include bounded assertion excerpts and process/timeout details.
Missing logs are reported as not run, never as zero failures.

Every Go test invocation captures `go test -json`, stderr and the actual exit
code. Its always-run report distinguishes:

- **tests**: distinct package/test nodes, including parents, subtests and examples;
- **suites**: reported packages, including packages with no tests;
- **failures**: failed test nodes plus failed packages without a failed test node;
- **skipped**: explicitly skipped nodes, with skipped/no-test packages listed.

Nonzero/missing exit status, malformed or incomplete events, empty execution and
all-skipped commands fail. Partial skips remain visible; Go does not have Swift's
pre-discovered method audit. Unit, race, property and platform commands overlap,
so their counts are not unique coverage totals. `-count=1` prevents test-result
cache hits from replacing execution.

## Time and resource tradeoff

One native job lowers simultaneous macOS runner demand and eliminates repeated
checkout/setup/cache restore/fixture download and evidence transport. It may take
longer end to end than parallel shards. Report both wall time and summed runner
execution time; runner minutes are not a billing estimate.

The native job has a sixty-minute hang guard; Linux and extended jobs retain
thirty-minute guards. Each owned command retains an independent thirty-minute
default timeout and narrower existing CLI/test limits. There is no whole-run
fifteen-minute merge deadline. Timeouts still mean incomplete verification.

`run-summary.py` reports queueing, current attempt time and time since the first
trigger. Failure to fetch/upload these timing diagnostics does not override the
required-job gate. Successful jobs carried forward on a partial retry are marked reused,
not counted as new work. Diagnose a failure before retrying; a passing retry alone
does not establish that the first failure was harmless.

## Local verification

Run one production-boundary group with:

```sh
python3 scripts/ci/replays.py GROUP --go ./scripts/go.sh --output /tmp/new-evidence
```

`runtime`, `adapters`, `fixtures`, `interop` and `native` are the supported groups.
Native groups need the current Swift build and graphical capabilities. The
[verification policy](verification-policy.md) records independent defect coverage
and the limited device/signed-package acceptance requirements.

`make check-swift` invokes `swift-tests.py --run`, preserving the ordinary log,
actual process receipt and native-owner evidence under `.build/check-swift`.
It uses the same explicit ordinary exclusion, then invokes the existing producer
for each declared owner check serially. The complete CI path additionally runs
all fixtures/interop/native groups and audits the discovered method inventory.
To inspect an existing ordinary log without claiming native owner execution:

```sh
python3 scripts/ci/swift-tests.py --full-log /absolute/swift-tests.log \
  --exit-code 0 --output-dir /tmp/swift-log-review
```

`verify-ci-control.py` exercises the real scope, build discovery, ordinary command,
coverage and local capture entry points with temporary Git histories and controlled
external executables. It rejects omissions, duplicate/substituted methods, wrong
commits, incomplete zero exits, unexpected skips, missing receipts/markers and
partial or misrouted native evidence; real subprocesses check deadline termination.
These fixtures establish control behavior, not Swift/macOS rendering. The current
commit's hosted run must establish actual native execution.

`verify-go-reporting.py` checks the real reporter against temporary Go pass,
failure, skip, panic, build-error and empty-test packages, plus malformed/truncated
captures. Both control verifiers run in Linux CI.

## Pull request merge gates

The active [main-pr-gates ruleset](https://github.com/hupao-creator/Mokusei/rules/26004586)
requires a PR up to date with main and successful **Complete coverage** from
GitHub Actions. The aggregate requires scope and every job applicable to that
scope. It cannot turn a failed, cancelled, missing or unexpectedly skipped native
job green. Extended dispatches use the distinct `Extended native CLI coverage`
name and do not satisfy the ordinary gate.

Review conversations must be resolved; the required approving review count is
zero. There are no bypass actors, and force pushes/deletion of main remain blocked.
The remote ruleset is separate from workflow code; inspect its actual requirements
before planning a merge. Local checks and historical green runs cannot replace
the final revision's required check.
