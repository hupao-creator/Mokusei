# Boundary execution contract v1

The performance runner implements this lifecycle, evidence envelope and exit
contract. PBT uses its own [summary format](../verification/pbt/README.md#replay-and-evidence);
format compatibility is not implied by the shared boundary ownership rules.
Interaction and performance remain independently owned boundaries.

## Lifecycle

`prepare → execute → collect → validate → judge → report → upload`

Prepare fixes the subject revision/artifact, suite/workload version, environment,
budget and output directory. Execute owns only its processes and isolated data.
Collect retains original evidence, including failures. Validate establishes
measurement capability and functional oracles. Judge applies a versioned policy.
Report always runs after cleanup, including failures/timeouts. Upload is an outer
CI step with `always()`; it must never turn a failing judgment green.

Collection refuses an existing output directory. Offline judgment refreshes only
derived reports; it never reseals or replaces source evidence. Cleanup is mandatory and its
failure blocks certification. Interrupted attempts remain separate; a retry never
replaces failed evidence. No production logging or user profile is required.

GUI/input/capture holds the atomic directory `/private/tmp/mokusei-ui-verification.lock`.
Creation is exclusive; an existing directory blocks and is never reclaimed by a
runner. `owner.json` records `thread_id`, PID and an ownership token; set
`MOKUSEI_VERIFICATION_THREAD_ID` to the coordinating thread identity. Performance
also retains the NativeReplay flock. Only a direct child with the exact owner
token may inherit a lease. Cleanup removes only the caller's own owner record.

## Report envelope

`schemaVersion: 1`, `kind: "boundary-report"`, `boundary: "performance" | "e2e" | "pbt"`,
`suite`, `runId`, `status`, `validity`, `decision`, `exitCode`, `reasons: string[]`,
`evidence: [{path, sha256}]`, and boundary-specific fields. JSON is authoritative;
Markdown is the human projection. `phases` records observed lifecycle events;
never fabricate completion of a phase. Upload receipts belong to CI.

| Condition | status | validity | decision | exitCode |
| --- | --- | --- | --- | --- |
| All required observations and oracles pass | passed | valid | passed | 0 |
| Established performance regression | failed | valid | regressed | 1 |
| Established functional/property failure | failed | valid | failed | 1 |
| Bad evidence / failed cleanup | blocked | invalid | not-evaluated | 2 |
| Missing case/sample/metric/evidence | blocked | incomplete | not-evaluated | 2 |
| Capability unavailable | blocked | unsupported | not-evaluated | 2 |
| Identity/configuration mismatch | blocked | valid | not-comparable | 2 |
| Too noisy or uncertain to decide | blocked | valid | inconclusive | 2 |

Blocked dominates aggregate success or failure; retain individual established
failures. No skipped, uncollected, cancelled or unknown result counts as passed.
All statuses are explicit strings, never inferred from an empty list. A wrapper
may map unexpected failures to exit 2; CLI syntax errors also exit 2.

Evidence paths are relative to the report bundle; reject traversal, symlinks
escaping the bundle and missing/different hashes. Hashes detect accidental changes,
not hostile authorship. Keep credentials and private profiles out of uploads.
Retain subject SHA, runner identity, versions, policy and raw values; reports from
another revision cannot certify the current subject.

Performance extensions are documented in [gate/README.md](gate/README.md).
E2e owns its own cases, fixtures, runner and workflow. Shared semantics do not
require shared implementations or concurrent edits to central CI files.
