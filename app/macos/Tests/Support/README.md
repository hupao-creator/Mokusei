# Native test environment

This module is a test dependency, never an application dependency. The Host and
Threads test targets share its asynchronous gate. `.serialized` only orders tests
inside one suite; `@MainActor` still interleaves test bodies at suspension points.
Neither protects the process-wide AppKit application, key window, menu, clipboard,
performance recorder or the main actor's real-time animation observations.

Apply `.serializedNative` to native suites, including model suites that share the
main actor and bounded waits. It acquires once per test case, keeps ownership through
async cleanup and releases on success, failure or cancellation. It never blocks
the main actor while waiting. Pure concurrent Core/protocol/geometry tests retain
their existing scheduling.

Apply `.requiresDisplay` only to cases that mount native UI or to suites whose
cases all need it. Mixed suites keep their model assertions enabled. The trait
checks the WindowServer session and available screens; it reports an explicit
skip when unavailable. `MOKUSEI_TEST_HEADLESS=1 swift test --package-path app/macos`
exercises this admission path without changing the desktop. This is a simulated
absence of display capability, not proof from a physically disconnected machine.
Hosted CI intentionally does not set that override and rejects display skips.
Fixture-gated methods may defer only to their required Go/AppKit replay step;
see the [verification policy](../../../../scripts/ci/verification-policy.md).

The isolated reading-presentation launcher compiles the same support source with
the selected tests. Their conditional `SWIFT_PACKAGE` import lets SwiftPM share
one support module across targets while standalone native apps use the identical
gate. Native replays reject skipped cases as incomplete verification.

Keep all behavioral assertions active when their required environment exists.
When a replay observes asynchronous cleanup, wait for every required boundary:
discarding a staged attachment can finish before its temporary file is removed.
A thread switch may also reset presentation state before the old cleanup task
finishes; that state alone does not certify cleanup.
See the [Swift failure audit](../../../../tools/verification/swift-tests/README.md)
for the baseline, failure classifications, skipped fixtures and validation logs.
