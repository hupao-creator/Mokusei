# Integration record

Baseline: `8ca887b` (detached task checkout). Read-only plan UI reference:
`44d30d3170fcef5ed8319b585dbdbb5e646b560f`, “Hide plan entries in thread detail”.
This checkout does not include that commit or the parallel execution-summary and
nonstreaming-message changes. Integrate those changes before native acceptance.

## Ownership and hot paths

| Boundary | Observation and disposition |
| --- | --- |
| Canonical Harness state → public observation/context/search/Overview | Plan, reasoning, activity and message facts still have other consumers. No canonical ingestion, storage, batching, search or overview data was deleted. Pi/OpenCode tool todos also remain owned data. |
| `Runtime.ReadThreadContent` → Harness `ProjectRenderer` | Demand reads are keyed by thread/turn/execution, but freshness uses the whole thread revision. Each new revision still parses canonical state and projects the requested scope. No new long-lived cross-revision cache was introduced. |
| Codex/Claude `ProjectRenderer` turn scope | Remove plan steps, explanation and timeline markers before output encoding, for active and settled/inherited readers. Codex skips cloning excluded fields and avoids cloning interactions twice. Required empty plan arrays remain valid for native decoding. Overview, thread manifests, full/execution and context contracts retain their plans. |
| Content worker → `publishOne` → NDJSON | Workers serialize each subscription. Previously even byte-identical projections were decoded, diffed and a discarded empty patch encoded. A 32-byte SHA-256 digest per subscription, armed after a semantic no-op and disarmed on visible changes, now skips those stages and advances only the source revision. Continuously changing streams avoid hash computation. Equivalent differently encoded JSON still uses the semantic diff, then skips empty-patch encoding. Changed content keeps the existing wire patch chain. No extra raw payload is retained. |
| Swift `RuntimeContent.receiveContent` → Harness state caches | Only emitted snapshots/patches reach Swift decoding, reading cache writes and resource invalidation. No Swift transport changes were necessary. Bytes omitted in Go never reach native plan validation or row construction in fetched turns. |
| `ThreadDeferredExecutionContent` / `ThreadExecutionProcess` / Harness row builders | Parallel summary work owns removal of detail demand, loader leases, expanded nodes, Markdown/tool-detail construction and corresponding turn projection. Preserve reasoning/tool counts, interactions, errors and final replies. This task leaves full execution scope intact because it may still serve other clients. |
| `ThreadMessage` / Markdown streaming / timeline follow and geometry | Parallel nonstreaming work owns when messages become visible and whether streaming layout is mounted. `ThreadTimeline` also serves Moku, history reading, anchors and scrolling. No shared follow/geometry/anchor machinery was removed speculatively. |

## Integration intersections

- Codex `presentation.go`: turn projection calls `stProjectTurn(turn, reading)`;
  the helper excludes plan fields only for the reader. Reconcile this call with
  the summary task's lightweight active/settled projection. Keep prompt, answer,
  pending interaction, error, usage, activity-path/count and reasoning-presence facts.
- Claude `state.go`: plan pruning is immediately before the existing deferred
  projection. Move it into a replacement summary projection if that parallel
  work restructures this branch. Fork history plan items must also be pruned.
- The plan UI reference removes markers before native execution-source binding.
  Go filtering intentionally produces the same surviving sequence, so hidden
  plans do not introduce an extra execution-summary boundary.
- Transport changes have no UI API dependency and should apply independently.
  Re-run no-op and changed-content cases after integration. A source change that
  also changes visible timestamps/metadata is not digest-identical and will
  still take the ordinary path. This change does not promise zero refreshes
  for every plan/detail update or eliminate upstream projection costs.

## Verification and limits

Local evidence lives under `.scratch/thread-detail-performance` while this
worktree is retained. The new projection replay, affected `go vet`, architecture
check, CI-control replay, and race-enabled Codex, Claude and transport protocol
replays passed. Publication benchmark assertions also passed under the race
detector, including the digest fast path and the next visible patch. The
sandboxed transport/Claude/Codex attempts first failed because loopback binding
was forbidden; successful reruns used permission for their isolated loopback fixtures.
The first projection replay attempt rejected an invalid running fork-history
fixture; correcting the fixture required no product/validation relaxation.

GitHub required-check / PR / run queries failed with `error connecting to
api.github.com`. No hosted CI result certifies this task revision. No Swift or
GUI replay was run: this task changes only Go projections/transport and must be
rechecked with the integrated native UI by the coordinator. No push, PR or base
workspace merge is part of this handoff.

## Measurements (2026-11-03)

Apple M1 Pro, Darwin arm64, Go 1.27.3, `GOMAXPROCS=1`; sequential A/B then B/A,
three 300 ms samples per case per direction (six samples per implementation).
A is a temporary source archive of baseline `8ca887b` with the identical benchmark
file copied into it; B is this change. No branch or other worktree was modified.
Values below are medians of the six samples. Raw logs are in
[results/20261103](results/20261103/before-ab.txt). This is local process timing
on a shared, non-quiescent developer machine; small deltas are not a regression
or improvement certificate, and these are not hosted or end-to-end GUI results.

| Production publication case | μs/op before → after | Time delta | B/op before → after | Allocs/op before → after |
| --- | ---: | ---: | ---: | ---: |
| `BenchmarkUnchangedContent/bytes=2048/reencoded=false` | 11.94 → 1.82 | -84.7% | 12722 → 40 | 56 → 2 |
| `BenchmarkUnchangedContent/bytes=2048/reencoded=true` | 18.61 → 13.08 | -29.7% | 12722 → 11680 | 56 → 36 |
| `BenchmarkUnchangedContent/bytes=262144/reencoded=false` | 1524.10 → 126.00 | -91.7% | 1313514 → 518 | 67 → 2 |
| `BenchmarkUnchangedContent/bytes=262144/reencoded=true` | 1380.96 → 1012.46 | -26.7% | 1313509 → 1312228 | 67 → 44 |
| `BenchmarkChangedContent/bytes=2048` | 25.71 → 29.46 | +14.6% | 13702 → 13702 | 81 → 81 |
| `BenchmarkChangedContent/bytes=262144` | 3295.56 → 2689.86 | -18.4% | 1314441 → 1314457 | 89 → 89 |

The 100 × 1,024-character plan fixture isolates removal at the active reader
boundary: Codex full/baseline turn is 106,446 bytes versus 859 bytes after removal;
Claude is 106,177 versus 585 bytes. Terminal and inherited cases also pass, but
their full-to-reader byte counts include pre-existing deferred redaction and
must not be attributed entirely to this change.

An earlier always-hash candidate increased work for actual message changes.
The final adaptive implementation arms hashing only after a semantic no-op
and disarms it on every visible change; the continuously changing benchmark
therefore performs no hash computation. Alternating equivalent byte encodings
miss the digest and still pay for hashing and semantic comparison; that is an
explicit limitation. Production Harness JSON encoding is stable, but callers
with unstable encoding do not get the identical-byte fast path. The initial
semantic no-op also pays the normal decode/diff plus digest creation; the
steady-state benchmark amortizes it. Continuous no-ops retain only the digest
and the existing decoded baseline, not a second encoded payload.
