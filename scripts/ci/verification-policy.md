# Verification policy

PBT owns generated invariants of the Moku coordination service, Runtime authority
and their durability/lifecycle boundaries. e2e owns interactions; benchmarks own
user-experience measurements. Cross-boundary properties require a specific
mathematical or state-machine invariant, not a renamed example test or timing
scenario. The [PBT guide](../../tools/verification/pbt/README.md) declares current
domains, oracles and limited exceptions. Ordinary example/table unit-test suites
are absent.

Use the [document-driven workflow](../../AGENTS.md#文档驱动) and
[fact index](../../docs/facts.md): each property, scenario or budget identifies
its current owning document, implemented boundary, evidence and decision rule.
The document describes implemented state, configuration and capability limits;
Git retains change history. An unexplained code result is not permission to
redefine a bug as correct behavior. Missing evidence is not a zero or a pass.


Routine [CI](README.md) runs formatting, architecture/import and registration
checks, Go vet/build, runtime PBT and Swift production build/geometry PBT. Locally
run affected checks and use larger sample counts or `--race` to investigate a
specific concern. `make check` combines routine checks; do not run an equivalent
local full suite merely to repeat required hosted validation.

`make pbt-native-state` requires a graphical macOS session and checks mounted
state convergence. `make pbt-system` is headless and requires macOS, an installed native
Codex CLI and loopback/sandbox capability; it checks generated provider faults
and durable cross-component effects. These are opt-in because their required
environment is not supplied by routine CI. Missing capability fails, not skips.
Their unique boundary coverage and limitations are in the property inventory;
neither is a user-experience latency gate.

Before remote integration, inspect actual branch protection and final-revision
checks. The aggregate is named `Complete coverage`; local checks cannot replace
a required hosted check. Local-only artifact delivery does not publish or launch
remote runs. Skipped checks and historical commits cannot certify current work.

Pure documentation changes require diff and local-link review plus actual
workflow scope classification. Build/static success does not prove runtime or
visual correctness. Record execution failures, evidence, the diagnosed reason and
any rerun; do not weaken assertions or skip samples to obtain a pass.

[External benchmarks](../../tools/benchmarks/README.md) and
[performance tools](../../tools/verification/README.md) answer independent
measurement questions. Missing capture, permissions, signing or descendant
accounting remains an explicit limitation, never a passing measurement.

Record the exact revision, command, workload, environment, artifact identity,
measurement validity and result. `blocked`, `skipped`, unrun and another
revision's results are not passes. Calibration establishes measurement
capability, not product correctness. Independent adversarial review checks
source/doc/evidence consistency, and findings require resolution and recheck.

The [product e2e runner](../../tools/e2e/README.md) implements mounted READ and
SETTINGS journeys plus an explicitly operator-assisted system-input Composer
journey. Its independent manual hosted workflow excludes Composer. A deterministic
external peer is not real-model/network coverage; offline artifact verification
does not rerun the product. During signed UX sampling, defer heavy builds and
property runs through the shared desktop/resource lease without stealing it.
