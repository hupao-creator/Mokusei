# Verification and native build tools

The [fact and verification index](facts.md) connects current contracts to their
owners and evidence. The [documentation coverage map](coverage.md) shows the
reviewed entries and the limits of that evidence.

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
experience. See the [verification policy](../../scripts/ci/verification-policy.md).
Build/static and routine PBT checks are specified in the [CI guide](../../scripts/ci/README.md).
