# Moku + native CLI + mock LLM system verification

```sh
./scripts/go.sh run -race ./tools/verification/moku-system \
  -codex /absolute/path/to/native/codex \
  -evidence /tmp/moku-system-evidence
# Five simultaneous faults, each applied once to its actual model request role:
./scripts/go.sh run -race ./tools/verification/moku-system \
  -codex /absolute/path/to/native/codex \
  -scopes 3 \
  -faults moku=429,child=truncate,report=500,tag=429,read=truncate \
  -evidence /tmp/moku-system-faults
# Followup, fork, cancellation with a late response, deletion and clear:
./scripts/go.sh run -race ./tools/verification/moku-system \
  -codex /absolute/path/to/native/codex -scopes 2 \
  -actions followup,read,fork,interrupt,followup,delete,settings,clear \
  -evidence /tmp/moku-system-lifecycle
```

Run from the repository root on macOS. A native CLI is required. A fresh HOME,
native profile, application profile and SQLite store isolate all test data. The
CLI uses a localhost-only OS sandbox; proxy attempts to external services are
denied and audited separately. Evidence contains synthetic model requests, fault
plans/hits and unexpected requests. The evidence directory must be new. Failures
retain their synthetic profile and print its path. If the initial chain has been
observed, `convergence.json` preserves the last public state and delivery snapshot
before shutdown, its sample time and every readiness condition. Timeout text
includes Moku terminal readiness, active AgentRuns and pending delivery identities
with their uncertainty flags. These observations precede cleanup; retained durable
state after cleanup alone cannot establish the exact timeout state. Successful runs remove the
profile after joined production shutdown.

## Scenario time budget

In-process scenarios have a **90-second total budget**, starting immediately
before production composition initialization and covering the initial chain,
all actions and restart verification. Native catalog probing and joined cleanup
have separate bounds. Fixed matrices and generated tests keep this default.

For a deliberately longer manual trace, choose a budget explicitly:

```sh
./scripts/go.sh run -race ./tools/verification/moku-system \
  -codex /absolute/path/to/native/codex -scopes 3 -scenario-timeout 3m \
  -actions fork,delete-active,clear-active,recreate,followup,read,interrupt,followup,clear,recreate,followup,clear \
  -evidence /tmp/moku-system-long-trace
```

The value must be positive. It changes only the whole in-process scenario
budget: each convergence wait remains bounded by 30 seconds, and the HTTP
request timeout remains 20 seconds. It cannot configure the separate daemon
stability mode, which uses its existing soak duration and limits.

`SCENARIO` logs the configured budget and start time; action logs show start time,
remaining total budget and elapsed lifecycle duration, including failed lifecycle
actions. `provider.json` records `scenarioTimeout` (null for daemon stability).
A pass with an explicit larger budget is evidence for that configured trace,
not a pass under the default budget. Preserve a previous timeout and its stage
timings when using a larger budget to investigate cumulative work versus a stall.

## Current combined chain and assertions

The runner executes production composition in-process, authenticated HTTP,
Runtime, Moku, Report, Tag, SQLite and the installed Codex CLI. A scripted HTTP
Responses server supplies model decisions; no production test hook substitutes
for a tool, admission, domain write or native history fork.

- Submit to Moku and replay the identical HTTP command ID. Both return the same
  receipt and exactly the planned number of children are created through real
  injected MCP tools. `-scopes 1` uses Inbox; `-scopes 2` or `3` creates one child
  per independent directory. System temporary paths intentionally map to Inbox;
  scoped fixtures use private new directories under the real home and remove them
  on success. Failures print their retained path.
- Child completion fans out to the durable Moku queue, scoped Report runner and
  scoped Tag runner. Moku updates its note; Report lists tasks, reads the source
  through its native history fork, checks the returned evidence, and creates an
  explicitly linked report. Tag creates a pool entry and assigns it to the child.
- Each scoped Report attempts a foreign-task read and each scoped Tag attempts a
  foreign assignment. The actual tools must reject them with the expected scope
  error before the model continues its legitimate work. Scoped list results must
  contain only tasks in their own directory. Distinct scope tag names expose cross-scope writes.
- The oracle checks child/Moku terminal states, empty outbox, no active background
  runs, exactly one report per planned task, exact source execution reference,
  report text, independent scope identities and tag/emoji agreement.
- Post-completion public actions (`-actions read,archive,unarchive,settings`)
  verify read isolation, task and Report archive state, settings CAS success and
  stale-write rejection. Each action preserves source execution, settings and
  native history; the changed global settings and archive flags survive restart.
- Lifecycle actions add `followup`, `fork`, `interrupt`, `delete`, `clear`,
  `delete-active`, `clear-active` and `recreate`.
  Followup must create a fresh execution and exactly one Report linked to it.
  Fork must create an independent host/native identity with readable inherited
  history, preserve the full durable source session, and create no Report until
  it executes. The read model request must contain the persisted assistant result;
  a token appearing only in the user prompt does not count as history evidence.
  Work on archived tasks must be rejected with the expected reason.
- Interrupt holds the real model response at a request barrier, rejects a stale
  cancellation generation, cancels the active execution and then releases the
  late response. The interrupted execution must stay interrupted and produce no
  Report. A subsequent followup exercises recovery on the same native session.
- Delete uses the existing `Runtime.DeleteThread` boundary (there is no public
  delete command); the task becomes unreadable while reports remain. Clear uses
  public `history:clear`; task/report/note/outbox state disappears while global
  settings remain. The `-active` variants hold an actual child model response,
  remove the task/history, release the late response and verify no resurrection
  or completion Report. `recreate` starts a new full chain after clear. The fixed
  active-removal matrix exercises both Inbox and three directory scopes.
- Production composition and HTTP server close and reopen the same profile.
  Thread/execution/note/report/tag identities and projections must survive.
  Replaying the original command still returns its original receipt; changing
  its body while reusing its ID must return `COMMAND_ID_REUSED`.
- Fault injection supports HTTP 429, HTTP 500 and truncated SSE for Moku, child,
  Report, Tag and the read fork. Every requested role fault must actually occur.
  All cases use the same final-state and restart oracle.

The model and reasoning selection come from the installed native catalog. Tool
declarations may be top-level `tools` or developer `additional_tools`. Routing is
based on actual input, batch identity and tool receipts rather than global
request order. Report and Tag success-path identities come from their scoped model inputs.
Deliberate foreign-scope probes use peer IDs observed in Moku creation receipts;
they must fail before legitimate processing resumes.

## Fixed and generated combinations

```sh
MOKUSEI_SYSTEM_CODEX=/absolute/path/to/native/codex \
  ./scripts/go.sh test -race ./tools/verification/moku-system \
  -run TestSystemFaultMatrix -count=1 -timeout=4m
MOKUSEI_SYSTEM_CODEX=/absolute/path/to/native/codex \
  ./scripts/go.sh test -race ./tools/verification/moku-system \
  -run TestSystemFaultCombinationProperties -rapid.checks=8 \
  -rapid.seed=20261023 -count=1 -timeout=8m
```

`MOKUSEI_SYSTEM_CODEX=/absolute/path/to/native/codex make check-system` runs
all fixed matrices and properties (8 generated examples by default; use
`ARGS=-rapid.checks=...` to expand).
The matrix executes all 15 role/fault pairs at each of 1, 2 and 3 scopes. Rapid
generates scope count, fault combinations across five roles (including no fault),
and 0–6 read/archive/unarchive/settings/followup/fork/interrupt actions followed
by optional delete and clear, rerunning the complete real-CLI scenario and oracle
for every example. The fixed lifecycle matrix runs an archive rejection,
unarchive/followup/read/fork/interrupt/followup/delete/settings/clear trace at all
three scope counts with five mixed faults. Failures shrink and print their seed/replay
path plus retained
synthetic evidence. These tests skip without `MOKUSEI_SYSTEM_CODEX`; a skipped
ordinary `go test` is not evidence of native combination coverage.

## Real process crashes and continuous resource gate

```sh
MOKUSEI_SYSTEM_CODEX=/absolute/path/to/native/codex \
STABILITY_OUTPUT=/tmp/moku-stability-evidence \
  make check-stability
```

This separate target builds the actual headless runtime with the production
`go build -trimpath` recipe (without race instrumentation),
starts it through production daemon discovery, and keeps the mock model service
in the observing parent. It does not use the existing user's daemon. The output
directory must be new. Allow at least 30 minutes plus build/crash setup time.
The observing runner, module/system tests and ordinary release replays still use
the race detector. `runtimeRace` records whether the measured executable has it;
instrumented RSS and production RSS are distinct performance measurements.

The required evidence is:

| Gate | Acceptance |
| --- | --- |
| Completed-state crash | Three SIGKILL/restart cycles; new PID, epoch and credential; old connection rejected; task/Report/Tag identities, settings and durable command receipts preserved; changed-body replay rejected |
| Active-model crash | Three crashes after a real child request reaches a response barrier; original execution becomes interrupted, no completion Report or automatic input replay, new followup succeeds |
| Native process lifetime | Wrapper registers PID, process group and birth time; registered groups are checked after crash/clear, including reparented processes; fallback cleanup does not turn a leak into a pass |
| Continuous daemon | One unchanged daemon PID/epoch for at least 30 minutes and at least 100 cycles of create, followup, read and active clear |
| Settled resources | First five cycles warm up; cycles 6–10 establish baseline. Final five medians and every post-baseline sample stay within RSS baseline + max(64 MiB, 50%) and FD baseline + 8; empty-history descendants remain zero |
| Live Go heap | Capture `GODEBUG=gctrace=1`; require the final PID/epoch marker and GC samples reaching the late run window (at least 90% of soak duration on the owner's GC clock), with second-half post-GC live heap no more than first-five median + 32 MiB |
| Final cleanup | Daemon and all still-owned registered processes exit; process log has no race or panic |

`provider.json` records the runtime executable SHA-256, race build flag, native CLI version,
crash windows, cycle count, duration, resource samples, thresholds, qualification
and cleanup result, plus final-owner GC live-heap samples and GC timestamps.
Loaded-state native RSS is recorded separately; its magnitude
is diagnostic, while registered process exit is mandatory. The parent bounds its
request transcript memory independently of the measured daemon. Retired process
registrations are forgotten only after confirmed exit; fallback kills revalidate
birth/group/command identity to avoid killing a reused PID.

A quick harness smoke can use `ARGS='-soak-duration=0 -soak-cycles=15'`. It may
pass the resource assertions but must report `longRunQualified: false`; it is not
30-minute stability evidence. Thresholds are fixed before execution and are not
relaxed to make a run pass. Failure retains the isolated profile and diagnostics.

Quiescence means three consecutive public snapshots with terminal task states,
no active AgentRuns, empty Moku delivery queue and no live model requests. This is
a bounded observation, not proof that every durable consumer inbox was drained.
Crash recovery checks therefore use exact execution/report/receipt invariants.
The continuous run measures process RSS, descriptors, owned descendants and
post-GC live heap. It does not expose goroutine internals or prove multi-hour/day
stability. Do not erase an instrumented RSS failure when a production run passes:
retain both build identities and diagnostic evidence, and label the qualification
as applying to the production artifact only.

## Remaining verification scope

This is not yet the full combination gate. Cross-Harness chains, concurrent dependent
tasks within a scope, broader generated command sequences, exact uncertain-admission
crash windows, steering races, worktrees/attachments/Context, voice combinations
and multi-hour resource soak remain required work under
[the full objective](https://github.com/xinyuan0801/OpenAgent/issues/542).
It starts with one child per scope and can add forks and successive executions;
the ordinary system matrix uses graceful composition restart, while the separate
stability target uses actual daemon crashes. External Context acquisition is disabled. The separate
[release runner](../release-health/README.md) and module checks support this work
but do not substitute for the outstanding combination coverage.
