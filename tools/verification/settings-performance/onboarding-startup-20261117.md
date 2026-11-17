# Real-CLI onboarding startup measurement — 2026-11-17

This measures the production macOS data path, not inferred gains from fewer
requests. The final candidate improves the median time for **all Harnesses' next
onboarding configuration data**, but does not improve every startup metric.
Independent-role first readiness improves; inherited-role first readiness gets
slightly worse, and ordinary Settings defaults finish later in both scenarios.
Do not describe this as an across-the-board launch speedup.

## Revisions and method

- A: `3056a885cca1b33a0f10b4cf62dbd46832f24b38`, the configuration-ready
  discovery baseline before the startup scheduling/scope changes.
- B: `c030a4b4b11b3a90d0007eb8dbb3bc0c0e7fde1a`, the initial phased scheduler.
- C: B plus this commit's same-batch, execution-first scheduler correction.
  The JSON records the measured prefetch source SHA-256 to identify it without
  a self-referential commit hash.

A standalone native timing client links the real `MokuseiUI`/Core objects and
runs `NativeWorkspaceModel.start()` against a fresh, isolated production Go
daemon (`composition.New`, actual installed Harness plugins). A is compiled
using a Swift VFS overlay of its three changed production Swift files; B/C use
the corresponding production package objects. All use the same debug `-Onone`
dependencies and toolchain. No test case, mock catalog or graphical window was
added. Runs are sequential, with a new daemon/profile per sample. Neither the
running App nor its profile is restarted or modified. Native CLI account/config
reads use the existing user environment; no model prompt or paid execution is
sent. Temporary app state, workspaces and copied settings are isolated.

The **same predicate in both binaries** requires each Harness's Moku execution
surface and every enabled independent Tag/Report surface to have production
`loadState == .ready`. Inherited roles join Moku's resource. This includes native
models/capabilities and saved execution snapshots, rather than executable
availability or either version's title. Four Harnesses installed successfully
in every final sample. The first-ready endpoint is data for the first eligible
Harness, not a rendered Continue button or a completed configuration interaction.

Time starts immediately before `workspace.start()`, after the isolated daemon
publishes its connection. Daemon startup is recorded separately (final samples
86–120 ms). Polling is every 10 ms. New daemon processes give cold in-process
catalog caches, but OS/CLI filesystem and account caches are **not cleared**.
This is not a whole cold App launch measurement. Remote account/CLI latency can
vary; n=3 is descriptive evidence, not a statistical significance claim.

Two settings scenarios use the same copied current configuration:

- **Current**: existing saved execution profiles, Tag and Report independent.
- **Fresh inherited**: empty Moku execution profiles, auto host choice, both roles
  enabled with the exact production `{"mode":"inherit","enabled":true}` schema.
  This exercises initial capture and reuse, not a virgin machine/account.

## Final A/C results

Seconds; each cell is median (min–max), three samples per binary/scenario in
alternating `AC`, `CA`, `AC` pairs. Positive delta is slower. Every sample is
retained, including C's slowest independent-role run. All 12 samples have four
required Harnesses ready, no terminal primary error, and client/daemon exit 0.

| Scenario | Endpoint | A seconds | C seconds | Median delta |
| --- | --- | --- | --- | --- |
| Current independent roles | First Harness required data | 2.742 (2.657–4.800) | 1.819 (1.756–1.878) | -33.7% |
| Current independent roles | All Harness required data | 13.075 (12.436–19.139) | 11.613 (10.032–15.942) | -11.2% |
| Current independent roles | All retained resources terminal | 13.075 (12.437–19.139) | 15.620 (14.015–19.923) | +19.5% |
| Fresh inherited roles | First Harness required data | 1.363 (1.195–1.554) | 1.543 (1.469–1.547) | +13.2% |
| Fresh inherited roles | All Harness required data | 7.759 (7.561–8.033) | 5.639 (5.621–5.789) | -27.3% |
| Fresh inherited roles | All retained resources terminal | 7.786 (7.585–8.060) | 9.660 (9.638–9.807) | +24.1% |

The first usable Harness is not blocked by the slowest Harness. The all-required
endpoint is nevertheless useful for comparing the full set of configuration
choices: it improves by about 1.46 s with independent roles and 2.12 s with
inherited roles. In the fresh inherited scenario the first usable Harness instead
regresses by 0.18 s. The sample ranges overlap and native latency varies; the
results do not establish a universal improvement or eliminate the slowest run.

Per-Harness required-data medians, seconds:

| Harness | Current A | Current C | Fresh inherited A | Fresh inherited C |
| --- | --- | --- | --- | --- |
| pi | 2.742 | 1.819 | 1.363 | 1.543 |
| codex | 4.491 | 4.000 | 4.000 | 3.645 |
| claude | 4.851 | 3.119 | 3.579 | 3.747 |
| opencode | 13.075 | 11.613 | 7.759 | 5.639 |

Actual presentation-start request counts have median 21 → 21 (current) and
37 → 14 (fresh inherited). These include source replacement, cancellation and
bounded retry reads, not just stable scope counts. Stable scope counts remain
16 for independent roles and change from 16 to 8 with both roles inherited.
The production global-four/per-Harness-one limits are unchanged.

**Background cost:** the terminal endpoint also includes ordinary Thread defaults
that subsequent onboarding pages do not consume. Its median gets later by 2.55 s
(current) and 1.87 s (fresh inherited). Execution-first admission shifts work
away from those defaults; it is not a total-prefetch improvement. The recorder
for the paired series defines terminal as non-loading, which may include failure;
it must not be labelled "all settings ready". Two additional C diagnostics
record every final resource state: all 16 current and all 8 inherited resources
were `ready` in those particular runs (13.982 s and 8.887 s terminal times).
These diagnostics do not retroactively certify every paired default outcome.

## What the earlier A/B trials changed

The first A/B series suggested execution readiness improved, but initially only
waited five seconds after the primary endpoint. Extending observation revealed
B's phase barrier: in one current B/A pair the retained-resource terminal time
was 19.252 s vs 11.929 s; in the inherited pair it was 12.972 s vs 7.499 s.
The scheduler used to wait for all execution retries before admitting defaults.
C removes this phase barrier, queues scopes together, and places execution
resources ahead of defaults within each Harness. Each resource retains its own
bounded retry and visible failure. C is measured separately above; the remaining
background slowdown is reported, not assumed fixed by removing the barrier.

All valid earlier A/B samples are retained separately in the JSON. They are not
pooled with A/C. Initial malformed inherited-role seeds (leftover override keys)
and a pilot client missing `DYLD_FRAMEWORK_PATH` were preparation failures;
the entire original inherited subset is excluded. The corrected inherited A/B
series is included separately. No slow or failed product sample was discarded
from the final A/C series. Two preliminary pilots are outside the paired stats.

## Evidence and reproduction

[Sanitized per-sample JSON](onboarding-startup-20261117.json) contains revisions,
source hash, tool versions, raw per-Harness endpoints, request counts, exit
statuses, all valid A/B diagnostics, final A/C samples and summary statistics.
The temporary source/manifests/trace archive is
`/private/tmp/onboarding-startup-20261117-evidence.zip`. It excludes environment
values, copied settings, runtime tokens, profiles, databases, private logs and
large binaries. Its `REPRODUCE.md` describes compiling the native timing client
against production objects. Rerunning requires fresh private environment/settings
inputs and rebuilding the binaries; account responses and cached external state
cannot be reproduced bit-for-bit. The recorder's final revision additionally
records resource outcomes; that field is present in the diagnostic series only.

Environment: arm64 macOS 26.5.1, Swift 6.3.2, project-pinned Go 1.27.3,
Claude Code 2.1.325, Pi 1.3.0, OpenCode 2.3.0. Codex installed npm package metadata
is 0.167.0; its separate `--version` probe exited 1 in this shell, so that probe
is not reported as passed. The actual benchmark's Codex production resources
successfully reached ready in every final sample.

## Focused validation

After the measured source correction:

```sh
xcrun swift build --package-path app/macos --build-tests --force-resolved-versions --disable-index-store --scratch-path .build/swift -j 2
MOKUSEI_TEST_HEADLESS=1 xcrun swift test --skip-build --package-path app/macos --scratch-path .build/swift --no-parallel --filter NativeSettingsDiscoveryTests
MOKUSEI_TEST_HEADLESS=1 MOKUSEI_SWIFT_SKIP_BUILD=1 ./scripts/go.sh run ./tools/verification/transport -swift-settings-capacity
```

Build passed. Existing discovery case passed (1 case, no skips). Existing capacity
replay passed (1 case; 20 slow reads, responsive commands, queued/active
cancellation, no capacity increase). The first sandboxed capacity attempt could
not acquire the local ownership port; the approved local-port rerun passed.
No test case was added. No unrelated regressions, graphical replay, whole-suite
check, hosted CI, paid model request or App restart was run. Integration remains
owned by the coordinating thread; this detached worktree does not modify main.

Read-only remote audit: classic main protection returned `Branch not protected`;
the active branch-rules endpoint lists a pull-request rule and no required
status-check rule. The open-PR list has no head matching this detached revision.
GraphQL `gh pr status` was unavailable; REST queries succeeded. This is not hosted
CI evidence or authorization to alter remote rules. The coordinator owns final
integration and any remote checks.
