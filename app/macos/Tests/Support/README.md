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
Its disposable account enables motion/transparency before launching tests;
local tests never change system accessibility preferences. Rendered geometry
comparisons use one physical pixel from the actual window's backing scale, so
1x hosted screens and 2x Retina screens enforce equivalent precision. Pure
geometry assertions retain their original numerical precision.
Fixture-gated methods may defer only to their required Go/AppKit replay step;
see the [verification policy](../../../../scripts/ci/verification-policy.md).

The isolated reading-presentation launcher compiles the same support source with
the selected tests. Their conditional `SWIFT_PACKAGE` import lets SwiftPM share
one support module across targets while standalone native apps use the identical
gate. Native replays reject skipped cases as incomplete verification.

Keep all behavioral assertions active when their required environment exists.
Native mouse-tracking cases also require the isolated AppKit application loop.
An ordinary SwiftPM host can exit during NSTextView tracking before producing
its final summary; the Moku composer launcher explicitly owns that capability.
Set `MOKUSEI_NATIVE_TEST_GATE_TRACE=1` to log the active native fixture when
diagnosing an SDK exit. `make check-swift` rejects incomplete captures even when
the test process reports status zero.
When a replay observes asynchronous cleanup, wait for every required boundary:
discarding a staged attachment can finish before its temporary file is removed.
A thread switch may also reset presentation state before the old cleanup task
finishes; that state alone does not certify cleanup.
See the [Swift failure audit](../../../../tools/verification/swift-tests/README.md)
for the baseline, failure classifications, skipped fixtures and validation logs.

The tag-prefix geometry-only case mounts its filter bar offscreen to exclude
native glass hover from chip-height measurements. Its optional WindowServer
capture mode remains on-screen; glyph reference and pixel assertions are unchanged.

## Overview revision timing

The entry-revision fixture observes geometry as it is delivered. A card's first
polled frame can arrive with only two points of its eight-point entry remaining;
sleeping another 40ms cannot establish an interruption during that entry.
The fixture instead injects its second revision synchronously after two actual
descending samples while at least four points remain and the first revision is
unconsumed. It records the injection and consumption boundaries and uses actual
geometry from before the first consumption. The original strict movement of more
than two points, FIFO, mounted-identity and final-membership assertions remain.
Failure to observe the prerequisite within the original three seconds is an
explicit incomplete-observation failure. Diagnostics retain the finite geometry
history; a theoretical destination or the next revision's exit cannot stand in
for continued entry motion.

## Retained Overview return observation

Post-merge CI #261 failed to observe the retained-page opening midpoint. Its
recorded x positions crossed the unchanged 40–60% window-width band between
716.14ms and 800.98ms; by 1345.84ms the opening had finished. The latest-content,
return-direction and parent-retention assertions had not run. These observations
do not establish whether a qualifying intermediate frame was committed or only
missed by polling, so the failure is not classified as a product regression or
discarded as flaky.

This method now uses `SwiftUIReplay.wait(driveLayout: false)`, which requires an
actual running `NSApplication` event loop. Other callers retain the default
layout/display driving behavior. Repeated synchronous all-window layout and
display share the main actor with the production animation task and can disturb
the observation; passive waiting removes that intervention, not OS scheduling
uncertainty. Each wait retains the original three-second deadline and 10ms sleep.

Before the single opening, the existing initial-content wait also requires the
actual root to reach the explicitly requested 1180×780 points within one physical
pixel and motion to be idle. The original 1.2-second duration and strict
`0.4W < x < 0.6W` qualification are unchanged. After observing that band, the test
synchronously rereads the current front, root, window ownership and active motion
and requires the same band before updating the text and closing. There is no
intervening await or forced layout. Setup, every opening/return predicate,
open/close source times, the 100ms return observation and the final state are
retained with their uptime clock; no 50ms diagnostic subsampling omits checks.
The original return direction, latest content and parent appearance assertions
remain. No wider band, longer animation or deadline, retry, skip, or retrospective
midpoint interpolation can substitute for the actual prerequisite.

## Execution-link streaming input

The running execution-link replay supplies complete Markdown paragraphs while
the message remains streaming. Mounted reading timelines publish closed pages;
a single unclosed paragraph, even with many single line breaks, cannot establish
the prerequisite of visible page growth. The replay keeps its original height,
follow, user-scroll, Jump Latest and exact-execution assertions and wait budgets.
Finite stage receipts include the actual timeline controls and supplied input
lengths, and the final state is emitted on both success and failure.

## Title reversal timing

The early `A → B → A` replay sends B once, then observes an outgoing A before
sending A. A requested 50ms sleep can resume after B is already displayed and
does not establish that prerequisite. The replacement observation has a fixed
three-second budget: the newest WindowServer frame must follow B's input, have
10–90% of the settled A ink, and be less than 50ms old. Both the final check before
A and its actual setter return must precede B's `ContinuousClock` instant plus
150ms. That is the earliest possible replacement allowed by the production
owner's outgoing sleep, not an extra observation allowance. The same clock
brackets the single A setter; a preemption across the bound explicitly fails
after saving its receipt. This establishes early source submission, not when
SwiftUI consumes it. AX label/value is diagnostic outside the live input path:
a still-visible fading A can have model opacity zero and disappear from AX.
Raw frames, pixel-analysis timings, sample age, and continuous/raw input receipts
remain evidence. Failure to establish the prerequisite fails the case; there
is no repeated B input or retrospective use of an older partial frame.

This replaces the assumed 50ms input interval, not the fixed 500ms final check or
its original self-rendered equality assertion. The last available WindowServer
frame at that same check must also follow A's setter return and exactly match
the original content pixels. The replay does not wait for a match or accept a
frame presented after the check. A later return to A cannot certify that earlier
check. The separate incoming-cancellation oracle retains its 10–60% ink, 50ms
freshness, three-second budget and exact replacement-pixel assertions.
