# Property checks

The main boundary is the Go runtime: `core/runtime` owns admission and durable
application state; `services/moku` owns coordination, the admission queue and tool
lifetimes; `core/store` supplies atomic persistence and lifecycle consumption.
Composition connects these owners to Harnesses, applications and HTTP. “Moku
runtime” is this cooperating boundary, not every package or just Moku's prompt.

Properties call production implementations with generated domains and invariant
oracles. Scripted peers control native outcomes without implementing host rules.
No ordinary example/table tests are included. Reduced counterexamples are replay
corpus inside generated properties. UI interaction belongs to e2e and experience
timing to benchmarks. Process deadlines are hang guards, not experience targets.

## Contract map

Owning module docs define current semantics and detailed bounds. The executable
[inventory](properties.json) ties contracts to exact entry points; the runner
selects only these entries and requires evidence that they actually ran.

| Property ID | Contract and generated domain | Oracle / boundary |
| --- | --- | --- |
| PBT-RUNTIME-ADMISSION | [Runtime](../../../internal/core/runtime/README.md): 1–25 native accept/reject/end/failure/cancel actions | Exact retry permission, execution identity, one event per acknowledgement; real Runtime + SQLite |
| PBT-MOKU-OUTBOX | [Runtime](../../../internal/core/runtime/README.md): 1–12 rounds of 1–10 lazy/waking arrivals, attempts, rejection/acknowledgement, reopen/reconcile | Stable order, atomic uncertainty fences, exact-batch removal, late arrivals retained; not scheduler wake behavior |
| PBT-MOKU-SCOPE | [Moku](../../../internal/services/moku/README.md): two owners, 1–12 executions, permuted/duplicate callbacks and configuration installs | Highest observed owner revision controls tools; retired scopes cancel |
| PBT-MOKU-QUEUE | [Moku](../../../internal/services/moku/README.md): 1–8 cohorts of 1–12 waiters and cancellation subsets | Cancelled waiters release behind held owner; surviving admission is exclusive; queue reusable |
| PBT-STORE-SNAPSHOT | [Store](../../../internal/core/store/README.md): 1–80 transactions, overlapping ASCII/Unicode/long prefixes, puts/deletes | Independent map oracle for exact prefix/diff results and snapshot immutability |
| PBT-STORE-LIFECYCLE | [Store](../../../internal/core/store/README.md): 1–60 append/batch/receipt/settle/rollback/reopen actions, three scopes/consumers | Independent fact/acknowledgement model; effect idempotency, rollback isolation, pending/history and durable work |
| PBT-CODEX-TERMINAL | [Codex](../../../internal/plugins/harness/codex/README.md): generated start/event/follow-up/reject/settle histories | Durable state decodes; first terminal is absorbing; rejection notice retained |
| PBT-REPORT-PREVIEW | [Report](../../../internal/plugins/applications/report/README.md): Go fuzz over bounded arbitrary HTML | Parser safety and preview code-point bound |
| PBT-OVERVIEW-GEOMETRY | [Overview](../../../app/macos/Sources/Host/Overview/README.md#property-boundaries): 0–18 cards, generated footprints/viewports/caps | Independent geometry constraints, regular-grid lower bound and exact area/fit of shuffled six-tile rectangles |
| PBT-OVERVIEW-COLLECTION | [Collection budget](../../../app/macos/Sources/Host/Overview/README.md#property-boundaries), 0–16 fixed cells and 1–2 types of 0–10 ordered eligible reports | Exhaustive scoring of allowed prefixes by overflow then hidden member count catches excessive grouping, zero savings and repeated spending across types |
| PBT-OVERVIEW-STATE | [Overview](../../../app/macos/Sources/Host/Overview/README.md#property-boundaries): generated 18-event schedule plus reduced corpus | Production-mounted latest-state convergence; no physical input, screenshot or frame pacing |
| PBT-SYSTEM-COMBINATION | [Runtime](../../../internal/core/runtime/README.md#property-boundaries): 1–3 scopes, role-wise HTTP/SSE faults, action sequence and restart | Real Codex + composition + loopback provider; command receipts, scoped effects and retained facts |

The limited cross-boundary properties have distinct value: Codex's absorbing
terminal state supplies Runtime execution facts; Report parses untrusted agent
output; geometry has mathematical invariants; Collection membership has a finite
set of feasible prefixes with an independent scoring rule; mounted Overview state has a
latest-wins convergence contract. They do not justify expanding PBT to every UI
or plugin. The optional system property validates durable composition effects,
not user gestures. Power-loss recovery, all-Harness equivalence, live model
services, arbitrary concurrent clients and physical process crash recovery are
outside this inventory.

## Commands and budgets

From the repository root:

```sh
make pbt-go
make pbt-native
make pbt-native-state
MOKUSEI_SYSTEM_CODEX=/absolute/path/to/native/codex make pbt-system
make pbt-go PBT_ARGS='--seed 20261117 --cases 300'
python3 tools/verification/pbt/run.py --property PBT-MOKU-QUEUE --race --cases 300
python3 tools/verification/pbt/run.py --list
```

`make pbt` and `make check` use routine Go properties, native geometry and the collection budget.
Mounted state and system properties are opt-in. Run Swift builds/properties
serially. The system suite requires macOS, a native executable (not the npm
JavaScript launcher), `sandbox-exec` and loopback listeners. It uses isolated
profiles/configuration and a scripted model provider; it does not read user
conversations or contact a real model service.

Rapid defaults to 100 cases per property (system: 3), seed 1. Swift geometry and collection budgets
default to 480 seeds, mounted state to 8 plus corpus. `--cases` (1–10000),
`--seed` (nonzero UInt64), `MOKUSEI_PBT_CASES` and `MOKUSEI_PBT_SEED` control
generated budgets. `--timeout` defaults to 600s per property including compilation;
`--shrink-seconds` defaults to 30. Swift checks its shrinking deadline between
replays; one in-progress replay may finish afterward. Rapid has its own shrinking
bound plus Go's process timeout. The system scenario bounds execution at 90s,
with separate bounded native discovery/cleanup.

Report uses Go's native fuzz engine, 10s by default (`--fuzz-seconds`) and two
workers. Go exposes no deterministic mutation seed: replay the concrete corpus
input. A fixed corpus-only run is not the fuzz gate. `--cases`/`--seed` do not
control this engine.

`--go` selects the Go executable/wrapper (`scripts/go.sh` on macOS, `go` elsewhere).
`--swift-scratch` selects independent Swift build storage. On an offline machine
with all pinned dependencies cached there, `--swift-skip-update` uses resolved
versions without updating remotes; missing dependencies still fail. These options
do not modify global toolchain or package configuration.

## Replay and evidence

```sh
python3 tools/verification/pbt/run.py --property PBT-RUNTIME-ADMISSION --seed 20261117
python3 tools/verification/pbt/run.py --property PBT-RUNTIME-ADMISSION --failfile /absolute/counterexample.fail
python3 tools/verification/pbt/run.py --property PBT-OVERVIEW-STATE --replay /absolute/reduced.json
./scripts/go.sh test ./internal/plugins/applications/report -run FuzzReportHTMLProjections/CORPUS_HASH -count=1
```

Rapid replays package `testdata/rapid` corpus before generated cases; ignored or
invalid corpus inputs make the runner exit 2. Explicit `--failfile` input is
snapshotted and hashed, decoded using Rapid v1.3.0's v0.4.8 format and executed
through `rapid.MakeFuzz` in a separate `explicit-replay` subtest. A completed pass
must be observed before generated checks run; malformed/version-mismatched or
out-of-domain input exits 2, a reproduced assertion exits 1. The summary records
the input identity and replay result separately from random counts. The
[test-only adapter](rapidcheck/check.go) is shared by all Rapid properties; it
does not enter product binaries. Failure emits a seed and minimized `.fail`.
Swift failures name the seed and input, save
`original.json` before shrinking, then `reduced.json`. Swift JSON replay executes
only that input and labels it as replay. Go fuzz writes failures to
`testdata/fuzz/FuzzReportHTMLProjections` with the concrete replay command.

Each invocation prints a new evidence directory, or accepts `--artifacts` naming
a directory that does not yet exist. `summary.json` records HEAD, dirty status,
tracked patch/untracked hashes, platform, commands, seed, budgets, elapsed time
and child exit codes. Each property has `output.log` and retained corpus; system
failures additionally retain provider/fault/convergence evidence and print
isolated profile paths. Evidence is diagnostic output, not production logging.
No production logging API is required. Business history, transcript and execution
results remain part of the property oracles.

Runner exits: `0` completed selected properties; `1` execution/assertion or missing
execution witness; `2` invalid configuration, missing declared capability, tool
launch/evidence error; `124` outer deadline; `130` interruption. Exact child exit
codes remain in the summary. Missing capability, skips, empty filters and timeouts
are never passes. Partial runs list only executed properties and cannot be
reported as a completed suite.

[Routine CI](../../../scripts/ci/README.md) runs the Go and headless native properties and uploads evidence.
Source/build success alone does not establish coverage. Record actual results
with the tested commit in the delivery record.

`python3 tools/verification/pbt/verify.py --output /tmp/replay-cli-evidence`
checks the real runner with generated malformed/version/word/exhausted inputs,
the Runtime admission corpus, and a temporary Go overlay that injects an oracle
failure after the real property. Removing the overlay proves that same input
passes the unchanged property. This CLI e2e verifies replay plumbing; it does not
add a Runtime property or ordinary example tests, nor certify every counterexample.
