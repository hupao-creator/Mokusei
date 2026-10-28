# Continuous integration

[The workflow](../../.github/workflows/ci.yml) runs portable Go checks on Linux
and native Go plus headless Swift checks on macOS 26 arm64. `scripts/go.sh` is
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
DirectoryTag is repeated inside the full suite and must not be added twice.
`MOKUSEI_TEST_HEADLESS=1` deliberately exercises capability admission; the
display-dependent tests visibly skip. This does not verify native user flows
or a physically display-less machine. Keep the local graphical `make check`
and affected [native replays](../../tools/verification/README.md).

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

The no-argument CI mode retains its two log inputs under `RUNNER_TEMP`, writes
`swift-summary.json` there, and appends the table/errors to `GITHUB_STEP_SUMMARY`.
The local runner and CI share the same parser.

Raw test logs and JSON summaries are retained as Actions artifacts even when
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
- `Swift headless and native Go / macOS`

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
