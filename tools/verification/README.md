# Performance and native build tools

Automated correctness replays, test suites, test-only fixture producers and their
stored evidence have been removed. This directory retains independent diagnostic
measurements and shared native packaging used by interactive demos:

- [Runtime performance](runtime-performance/README.md), with its shared list seed.
- [Overview Release comparison](overview-ci-performance/README.md), manually dispatched.
- [Overview performance](overview-performance/README.md) and [historical glass analysis](overview-glass/README.md).
- [Note performance](moku-note-performance/README.md).
- `native_replay.py` and `NativeReplayIsolation.swift`: compile, package and isolate
  production-linked demos and performance tools. They do not reuse test objects.

These tools do not provide automated test coverage. Build/static validation is
specified in the [CI guide](../../scripts/ci/README.md).
