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

The isolated reading-presentation launcher uses the same support source with
the selected tests. Their conditional `SWIFT_PACKAGE` import lets SwiftPM share
one support module across targets. CI replays link that module's object and only
the selected test objects from the current verified build; local launches and
the standalone Workspace lifecycle suite compile the identical gate from source.
Native replays reject skipped cases as incomplete verification.

`SwiftUIReplay.window` requests the test application's enhanced accessibility
interface before mounting. Self-inspection must not depend on another suite or
an external accessibility client having materialized SwiftUI's lazy semantic
children. This affects only the test process; text assertions still read the
actual accessibility elements.

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

Revision consumption and `isLayingOut == false` certify completion of the
canvas's geometry work, before SwiftUI necessarily delivers the retired card's
`onDisappear`. CI run 41389322565 observed both FIFO consumptions and the full
entry travel, then read the old mounted set before that callback. The final
three-second wait now also requires the exact mounted set; the FIFO, movement,
appearance and membership assertions and their budgets remain unchanged. The
receipt retains the final mounted IDs, so an actually stranded card still fails.

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

## Real-time observer scheduling

CI optimization PR #225 recorded adjacent opening samples at x=740 and x=459,
67.186ms apart, missing the unchanged 472–708 midpoint interval. Another attempt
analyzed newest title frames at zero and 68.6% ink, missing its 10–60% interval.
Those failures remain failures; a later passing run does not classify them as
harmless. `Task.sleep` with unspecified tolerance permits clock-chosen leeway.
Passive `SwiftUIReplay.wait` specifies zero tolerance for its existing 10ms
sleeps. Title inspection instead waits for complete-frame arrival as described
below, avoiding an empty-queue polling timer. The isolated reading app holds a bounded
user-initiated/latency-critical activity and starts Testing at user-initiated
priority. This requests timely observation without forced layout, widening
bands, changing production animation duration, extending deadlines or retrying
input. OS preemption can still make the original assertions fail; retain actual
sample times and frame ages when diagnosing that outcome.

The scheduling contract is documented by Swift's
[ContinuousClock implementation](https://github.com/swiftlang/swift/blob/main/stdlib/public/Concurrency/ContinuousClock.swift)
and Apple's [latencyCritical activity option](https://developer.apple.com/documentation/foundation/processinfo/activityoptions/latencycritical).
Neither promises immunity to executor/OS preemption.

The ordinary `GitThreadExtensionTests.sharedTokenFlipAnimationWorksAtSummaryAndOriginalSizes`
fixture uses the same bounded activity and zero tolerance for its existing
100/90/300ms sampling sequence. Run 41395692467 failed its unchanged three-frame
inequality, but retained neither those frames nor individual delays, so the
failed interval cannot be classified. The fixture now saves all three PNGs,
actual input/capture times and pairwise comparisons under `MOKUSEI_CI_EVIDENCE`
(or `MOKUSEI_GIT_ARTIFACTS`, default `/tmp/mokusei-git-visual`) before asserting.
The production 260ms animation, input sequence and pixel predicate are unchanged;
missing intermediate evidence still fails rather than retrying or accepting a
later settled frame.

CI362 also failed the projected-usage card's three-frame comparison for 111
tokens. Its ordinary host retained neither the images nor actual sample times,
so that result cannot distinguish a missing animation from missed observation.
The same method now belongs only to the existing native rolling-number owner,
which supplies a running AppKit loop and foreground admission. The original
350/65/330ms timeline, seven updates, interrupted 40/400ms update and 350ms
reference comparison remain; sleeps request zero coalescing tolerance. All
original frame inequalities, snapshot/structure identities and appearance count
are required. Crops and actual times are held in memory until observation ends,
then saved even on failure; this recording does not establish the old failure's
cause. The ordinary stable-cell leaf remains enabled and is not duplicated.

## Title frame arrival

The title capture observer waits for a copied complete WindowServer frame to
arrive instead of polling an empty queue on a timer. Queue inspection, waiter
registration and frame publication share one lock, preventing a lost wakeup;
arrival, cancellation and the unchanged three-second deadline retire each waiter
exactly once. The losing deadline/arrival task is cancelled and joined.

This changes observation scheduling only. Incoming/reversal qualification still
inspects the newest complete frame, and cancellation still checks the first
replacement and every later frame in its batch. All raw frames, original ink
bands, 50ms freshness, single input, fixed 500ms check and offline pixel audits
remain. A late or missing live prerequisite still fails; retained historical
intermediate frames cannot substitute for a current one.

## Windowless feedback

The reviewed [execution registry](../../../../scripts/ci/swift_execution.py)
runs whole protocol, geometry/model, unattached-control and offscreen Metal
suites with display admission disabled in ordinary CI/local execution, followed
serially by the graphical remainder. Fixture-backed suites move only when their
existing producer environment is supplied. Each selected method must pass with
no skips. `swift-native.py headless` runs that selection independently; it is not
the full native gate. Metal uses SwiftUI ImageRenderer directly without initializing NSApplication
or creating a window. Main-actor controls retain the shared gate; genuinely pure
cases keep their ordinary scheduling. Tests for removed embedded selector
presentations are not carried forward as headless coverage.

## Native replay contract alignment

Settings Undo uses the real Harness settings form and explicitly selects custom
routing guidance, so the injected editor participates in the production binding.
Settings WindowServer captures use the window's actual backing scale; forcing a
2x destination on a 1x runner can leave black padding and misplace the existing
background-luminance sample. The contrast and luminance thresholds are unchanged.

Dock send replay checks immediate clearing of both live and retiring ink while
keeping its duplicate-send, failure restoration and route-replacement assertions.
The default Report view closes on one Escape; only a selected execution or Browser
adds a nested return step, as specified by the production navigation contract.
