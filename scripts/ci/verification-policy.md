# Verification policy

Behavioral verification has three boundaries: e2e owns interaction, PBT owns
Moku runtime, and performance benchmarks own user experience. Additional PBT
needs a specific invariant and a reason for its extra coverage. Ordinary unit
tests are not a project boundary and are not added or restored.

In this source tree, no first-party correctness suites, Swift test
targets, property or e2e gates are configured. The [performance tools](../../tools/verification/README.md)
and [external benchmarks](../../tools/benchmarks/README.md) provide measurements
with explicit capability limits, not required product regression coverage.
This implementation limit is separate from verification ownership.

`make check` runs formatting, architecture/import and registration checks, Go
vet, Go builds and the Swift production build. [CI](README.md) runs Linux and
macOS builds/static checks under the aggregate name `Complete coverage`.
Build/static success does not establish runtime, interaction or visual correctness.

Use the [document-driven workflow](../../AGENTS.md#文档驱动) and
[fact index](../../docs/facts.md): each property, scenario or budget identifies
its current owning document, implemented boundary, evidence and decision rule.
The document describes implemented state, configuration and capability limits;
Git retains change history. An unexplained code result is not permission to
redefine a bug as correct behavior. Missing evidence is not a zero or a pass.

Choose affected builds/static checks and measurements proportional to the change.
A local-only documentation delivery needs diff and local-link review plus an
assessment of the actual [workflow path classification](scope.py). The allowlist
is narrower than all Markdown; a remote run may still build module-doc changes.
Before remote integration inspect real branch rules and final-revision status;
local checks cannot substitute for required hosted checks. Local-only delivery
does not trigger publication or remote runs.

Record the exact revision, command, workload, environment, artifact identity,
measurement validity and result. `blocked`, `skipped`, unrun and another
revision's results are not passes. Calibration establishes measurement
capability, not product correctness. Independent adversarial review checks
source/doc/evidence consistency, and findings require resolution and recheck.
