# Verification and native build tools

[Property checks](pbt/README.md) generate runtime/state-machine histories with
explicit seeds, budgets and failure evidence. Independent measurements and shared
native packaging are available through:

- [Runtime CPU/allocation probes](runtime-performance/README.md).
- [Foreground Release comparison](overview-ci-performance/README.md), manually dispatched.
- [Overview internal CPU probe](overview-performance/README.md).
- [Glass evidence analyzer and geometry probe](overview-glass/README.md).
- [Note native preparation probe](moku-note-performance/README.md).
- `native_replay.py` and `NativeReplayIsolation.swift`: production-object compile,
  packaging, signing and isolated presentation helpers. They do not link test objects.

The performance tools do not establish property or interaction correctness.
Each property result applies only to its generated input domain. Measurements
retain source/artifact identity and do not certify another revision. Behavioral
ownership is PBT for Moku runtime, e2e for interaction and benchmarks for user
experience; see the [policy](../../scripts/ci/verification-policy.md) and
[fact index](../../docs/facts.md). Build/static and routine PBT checks are
specified in the [CI guide](../../scripts/ci/README.md).
