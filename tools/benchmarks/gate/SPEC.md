# Performance architecture

The implementation uses the shared [boundary lifecycle](../BOUNDARY_CONTRACT.md).
Its current scenario and policy definitions are [UX](UX.md) and the
[runner specification](README.md); `catalog.json` references those documents.

- User experience is the primary boundary: signed App startup, Overview input
  progress and reader entry/scroll response. Resource cost is reported with exact
  process scope. Runtime API costs are separate diagnostic support.
- `performance.py` owns catalog selection, explicit artifact/revision binding,
  execution, report/exit agreement and immutable baseline approval.
- `runner.py` serializes host work, budgets subprocesses and owns disposable
  Runtime sources. Overview uses its foreground lease and fixed Release harness.
- `ux.py` reuses independent signed-App collection and revalidates raw optical
  controls. It excludes only named out-of-scope hitch/descendant limitations; it
  never certifies the complete application resource lifecycle.
- `engine.py` validates untrusted versioned JSON and hashes at the bundle boundary.
  It preserves raw pairs, propagates optical intervals and evaluates both orders,
  noise and bootstrap intervals. Invalid/incomplete/incomparable is never passed.
- `capabilities.py` records installed tools and existing permissions without
  changing authorization. Physical frame presentation, App GPU/energy and real
  automated pinch remain unsupported on the current collector boundary.
- Synthetic CLI PBT/e2e validates gate mechanics. Actual product observations are
  separate artifacts, identified by product/collector/policy/runner/session.

The artifact format does not authenticate hostile authors. Operator revision
bindings are explicit because the signed bundle provenance has no source SHA.
The system does not change main, publish branches, configure remote required
checks, infer performance from production logs or automatically promote baselines.

The supplementary PBT domain is the judgment mechanism: scale/direction and
interval invariants, evidence rejection, GPU interval ownership/union and explicit
baseline state transitions. These mathematical/state invariants justify the
limited use of PBT outside Moku runtime. They do not replace interaction e2e or
measure product UX, and ordinary example unit-test suites are not introduced.
