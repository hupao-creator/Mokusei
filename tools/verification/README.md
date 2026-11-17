# Performance and native packaging tools

This tree contains independent measurements and packaging for interactive demos:

- [Runtime CPU/allocation probes](runtime-performance/README.md).
- [Foreground Release comparison](overview-ci-performance/README.md), manually dispatched.
- [Overview internal CPU probe](overview-performance/README.md).
- [Glass evidence analyzer and geometry probe](overview-glass/README.md).
- [Note native preparation probe](moku-note-performance/README.md).
- `native_replay.py` and `NativeReplayIsolation.swift`: production-object compile,
  packaging, signing and isolated presentation helpers. They do not link test objects.

No correctness assertion replay, test-only fixture producer or test coverage
report is configured in this source tree. Measurements retain explicit
source and artifact identity and do not certify another revision. Behavioral
ownership is PBT for Moku runtime, e2e for interaction and benchmarks for user
experience; see the [policy](../../scripts/ci/verification-policy.md) and
[fact index](../../docs/facts.md). Current CI supplies build/static validation.
