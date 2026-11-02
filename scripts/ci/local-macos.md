# Local macOS CI with gh-signoff

The macOS build/test/replay work formerly executed in Actions now runs through
`local-macos.py` on a reviewed local checkout. Linux Go tests, runtime/adapters
and documentation scope retain their original Actions execution. The workflows
and event triggers remain; their macOS jobs now check local results on Ubuntu.
No GitHub self-hosted runner, daemon or registration is required.

## Setup and trigger

Use Apple Silicon macOS 26, full Xcode/Swift 6.2+, Metal, Python >=3.11, Git,
GitHub CLI, and the existing pinned Go bootstrap. Extended checks also need Node
22 and npm. An unlocked graphical session, enabled motion/transparency and the
existing capture/input permissions remain required. The entry point does not
change personal preferences, install the product, run paid models or add skips.

Install the reviewed official extension once:

```sh
gh extension install basecamp/gh-signoff --pin 02e0cf9c11c9a1587784fec17c07b93fcb22ec24
gh api user --jq .login
```

Authenticate locally as `hupao-creator` for this repository. Posting commit
statuses requires repository status-write permission (`repo:status` on an
appropriate classic token); read-only `GITHUB_TOKEN` is insufficient. Do not put
personal tokens in workflow secrets, command arguments, logs or tracked files.
The test subprocess environment omits `GH_TOKEN` and `GITHUB_TOKEN`, but this is
**not a sandbox** and does not prevent reviewed code from using account files.

GitHub workflows never trigger local code automatically. Review the exact
source, dependencies and CI scripts, including external PR changes, before
running anything on a personal Mac. A PR author cannot schedule local execution
through a modified workflow or runner label: there is no registered runner.
External-fork workflow approval is additionally set to `all_external_contributors`.

For a workflow's missing local status, its job summary prints the **exact full
checkout SHA** and command. On a clean checkout of that commit, run:

```sh
python3 scripts/ci/local-macos.py native --commit FULL_40_CHARACTER_SHA --reviewed
```

PR Actions normally checks the merge commit, not the PR branch head. Fetch/check
out the actual `refs/pull/NUMBER/merge` with ordinary operator tooling and verify
that `git rev-parse HEAD` equals the job's SHA. Do not substitute a nearby branch
head or an old passing revision. The entry point never pushes, switches branches,
fetches shared refs, or modifies another checkout. If the PR merge revision moves,
check out and verify the new revision.

The wrapper requires a clean worktree and matching HEAD before and after checks,
proves the SHA is known to GitHub before publishing, pins the extension, serializes
runs across worktrees with a local process lock, and retains each fresh attempt.
It posts `pending` before execution, invokes `gh signoff fail` on failures and
publishes success only after all required command receipts and audits pass.
Cancellation/crash can leave `pending`; it cannot create success. A newer pending
or failing status supersedes an older success. A rerun always executes again.

The reviewed gh-signoff implementation otherwise fetches all remote-tracking
refs while checking `--commit`, and does not recognize every PR merge object as
published. After its own independent remote/clean/exact-SHA checks, the wrapper
uses gh-signoff's `-f` for **success publication only** to avoid that implicit fetch
and branch-tip restriction. It never bypasses the tests or uses that override to
publish an unpublished commit. Do not invoke bare `gh signoff` as a substitute
for this project's checked entry point: gh-signoff is a trust-based attestation,
not a test runner or cryptographic proof of execution.

For an unpublished development commit, or to avoid all remote writes:

```sh
python3 scripts/ci/local-macos.py native --commit FULL_40_CHARACTER_SHA --reviewed --no-publish
```

This still requires a clean exact checkout and executes the same checks. It does
not satisfy GitHub's gate. `--output /new/absolute/path` selects a fresh evidence
directory; the default is ignored `.scratch/local-ci/SHA/MODE-TIMESTAMP`. Optional
`--url https://...` links a published evidence location from the status; evidence
is not silently uploaded. Keep the complete local evidence, including failures.

After the matching signoff is successful, rerun only the failed metadata gate and
aggregate in the same Actions run, reusing completed Linux jobs:

```sh
gh run rerun RUN_ID --failed -R hupao-creator/Mokusei
```

A missing local result intentionally leaves a red gate with instructions. Posting
an unrelated status or completing tests on another SHA cannot pass it. There is
no idle polling VM and no requirement to rerun successful Linux work.

## Preserved execution and gates

| Local mode | Actual work | Required status |
| --- | --- | --- |
| `native` | Current-source build of all Swift tests; binary discovery/identity; Darwin Go race/devtool tests and reporting; all five fixture producers; ordinary serial Swift suite; complete interop/native replay groups; exactly-once native-owner and skip audit | `signoff/macos-native` |
| `extended` | All four original pinned native CLI/system lanes, serially, with Node 22 and the original package/command versions | `signoff/macos-cli` |
| `overview --baseline SHA --candidate SHA` | Original clock-contract checks and fixed Release AB/BA harness; actual foreground/display/CPU validity; no profiler or automatic display-mode changes | `signoff/macos-overview-PAIR_DIGEST` |

For performance, the tested harness is `--commit`; the full product baseline and
candidate SHAs also determine the status context. A different pair cannot reuse
its result. Copy the exact command from the performance job. Both product SHAs
must be available locally and reviewed before running the harness.

The ordinary Actions `Complete coverage` keeps its name and GitHub Actions app
binding (15368). Its unchanged aggregate requires Linux checks **and** the native
signoff gate for full scope. Documentation-only scope still skips native tests;
no native coverage is claimed there. An extended dispatch retains the distinct
`Extended native CLI coverage` aggregate and requires its local CLI gate. Overview
performance remains separately triggered and does not replace ordinary coverage.
No `gh signoff install` or new bypass rule is needed: Actions verifies the status
inside the existing protected gate. Existing main protection remains unchanged.

Each owned command keeps its deadline. Native execution has a 60-minute overall
guard; Overview has 30 minutes. Extended lanes retain a 30-minute command guard
and 3-minute install guard per serial lane. Timeout is incomplete verification.
Existing native assertions, fixtures, pixel frames and required owners are
unchanged. Historical flaky candidates and current fixes remain documented in
[flaky-review.md](flaky-review.md); no bulk test removal is part of this migration.

## Implementation and deployment status

The official [README](https://github.com/basecamp/gh-signoff/blob/02e0cf9c11c9a1587784fec17c07b93fcb22ec24/README.md)
and [implementation](https://github.com/basecamp/gh-signoff/blob/02e0cf9c11c9a1587784fec17c07b93fcb22ec24/gh-signoff)
were inspected. `create` posts a success commit status; `fail` posts failure.
They do not execute this project's checks. Its optional ruleset installation
would add an independent signoff policy, so it is intentionally not used.

The pinned extension is installed locally. The earlier runner/Tart/Softnet
packages remain installed but inactive; **no runner was registered or listener
started**, and no self-hosted routing variable was enabled. The user replaced
that plan with gh-signoff. See the [preparation record](self-hosted.md) for the
actual installation paths, commands, privilege/network results and stopped VM
pull. No administrator privilege or VM is required for this replacement.

Until this commit is integrated by the caller, the published workflows still run
macOS on GitHub. No local status or current-revision Complete coverage is claimed
without an actual successful run. This worktree remains detached and is not pushed.
The caller owns integration and the operator must run local checks for each
required published revision. Never weaken the existing main protection to hide a
missing local run.
