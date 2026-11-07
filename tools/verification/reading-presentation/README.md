# Reading-page background presentation replay

## Thread send, execution entry and completion handoff

```sh
python3 tools/verification/reading-presentation/run.py --thread-send-feedback
```

Runs the production detail Dock, Sidecard model/Conversation plugin and Codex
readers in an isolated AppKit app. Twelve tests cover receipt/catalog/index
ordering, failure, repeat sends/steering, card choices, covering/navigation,
terminal/replaced executions, explicit current/result/history requests and
single-execution sessions. Completion folds the Sidecard to its actual launcher
while widening the main shell, retaining the old native reader and preparing a
hidden destination at final width. The replay supplies an active scene and checks
the production aperture marker during travel, its folded launcher bounds and
the expanded main-panel marker. An intentionally delayed destination row (or
mounted read error) must keep the incoming host hidden after folding. Only content
admission releases the downward page turn; native presentation-layer samples
verify both moving pages before the same incoming host survives landing. Content
identity, first responder and the absence of a second blank text reveal are also
asserted. Wide and stacked layouts, including Reduced Motion policy, retain source,
fold travel, waiting, page travel and final AppKit-rendered snapshots. Reduced
Motion still waits for content but settles without an intermediate page turn.
The fixture supplies native content resources and send receipts; it starts no
Runtime or model-provider task. A graphical AppKit session is required. Set
`MOKUSEI_THREAD_SEND_WINDOWSERVER=1` to request WindowServer captures instead;
that explicit mode requires TCC screen-capture permission and fails if denied.
AppKit caching can omit compositor-owned layers; these snapshots are diagnostic,
not a pixel acceptance oracle or optical compositor/FPS evidence. This is bounded
interaction evidence, not a real-provider latency claim. CI uses
`--thread-send-feedback-native` for only the five native-owned methods; the seven
state/identity and scoped-content methods run in its ordinary suite.
The composer regression sends from the real resident Dock, supplies accepted
receipt/catalog/content fixtures and waits for completion handoff and outgoing
reader teardown. Both ordinary detail and exact-execution visits must remain
editable, acquire first responder from an ordinary native mouse click, and
receive a key event in the draft without a second submission. Closing the
workspace must still withdraw its input target. Both paths also interrupt a
prepared handoff to check input restoration when the retained reader returns.
It uses the production Host
input-target admission and native editor; no Runtime/provider task is sent.
Run just this regression with
`python3 tools/verification/reading-presentation/run.py --execution-composer-focus`.
Real right-side launcher controls toggle Conversation, Browser and retained Voice
transcripts without
an independent card Close icon; switching launchers retains execution identity
and never navigates back or starts voice media. Browser uses a loopback URL; Voice
uses a completed transcript with unavailable live-media capabilities, verifies
that it remains readable after toggling and records zero media actions. Neither
external pages nor microphone access are required.

The native subset also checks sidecard fold geometry using colored fixture
plugins inside `NativeSidecardWorkspaceLayout`. Native aperture bounds must
travel between the actual AX launcher frame and panel in both directions for the
top, middle and bottom buttons at 1180pt and 800pt widths. It covers reversal/switching, removing
an earlier launcher, selected-card unavailability, resizing during travel across
the stacking breakpoint and retained divider width. Captures use `fold-*` names;
`THREAD_SIDECARD_ORIGIN_GEOMETRY_CONFIRMED` is required alongside the existing three
native markers. The fixture supplies content only; folding is the production
modifier and layout, with normal motion enabled.
The first source measurement waits for the requested native viewport and stable
launcher bounds: a wide test window can initially be constrained to the CI screen
before NSHostingView settles its size. Failure retains the requested and observed
window/root bounds and launcher frame. This readiness check leaves every opening,
closing and intermediate-frame assertion and its original tolerance intact.

## Thread history sidebar

```sh
python3 tools/verification/reading-presentation/run.py --thread-sidebar
```

Mounts the production conversation, lazy TOC, timeline and turn components in an
isolated AppKit host. Six integration cases cover selection and Back scroll
retention, author and visibility controls, Up/Down, Home/End, Return/Space and Escape,
inherited history, deletion, arriving successors and external result anchors.
The visibility case also mounts a production execution summary with reasoning/tool
counts, checks that its detail body and execution-group action are absent, and
hides/restores it through the existing overall execution visibility control.
The running-state case covers both ordinary work rows and static summaries:
the selected running execution keeps work visible without a collapse control,
while historical visits and completion retain their own visibility behavior.
A 2,500-turn fixture asserts bounded mounted index controls and body demand, and
locates an old turn outside the current window. This is a resource-demand check,
not an FPS or target-device latency claim. Widths 360, 640 and 1180 exercise long
author accessibility and save settled dark/light screenshots under
`.scratch/reading-presentation/NativeThreadHistorySidebarTests`. The same mounted
fixtures verify title-free execution cards keep their author, user messages and
work content at those widths while full reading pages retain headings.

The ordinary Swift suite runs the four state/layout cases. The pointer case
requires the isolated application's running AppKit loop and a foreground visible
window; CI executes that exact method in `--isolated-input` and the coverage
collector requires its observed passing outcome. Forced headless admission
skips display assertions explicitly. The sidebar launcher requires all five
cases without skips. A finite onscreen pointer replay synchronizes the system
cursor and native events (restoring the original cursor on exit) to exercise the
production tracking areas: restored focus, keyboard preview, mark-to-panel handoff,
rapid row changes and final dismissal. Synthetic arrow/Return pairs acknowledge
the focused row before activation while retaining 30ms page reversals; they do
not wait for the page transition to settle. `hover-panel.png` and `hover-dismissed.png`
record the mounted result. These are native synthetic events with the real cursor
and component renders, not physical input or WindowServer capture. The default
reading-page replay also checks both vertical directions between history identities,
intermediate geometry, full-column pixel coverage and cancellation. It retains
`vertical-middle.png`, `earlier-middle.png` and `later-middle.png` under its suite
evidence directory. The system Reduce Motion
setting is observed by production code; this replay does not mutate that setting.
Existing `--moku-execution-links` separately covers
deferred bodies and exact-result following through all four real Harness renderers.

## Empty workspace and first dispatch

```sh
python3 tools/verification/reading-presentation/run.py --moku-landing
```

Runs ten `NativeMokuLandingTests` against the production workspace, catalog,
Overview and Moku presentation. The real shell waits for Moku hydration before
centering. Installed public snapshots cover durable shells before native admission,
failed dispatch, a successful result followed by Talk/another pending creation,
global membership versus scoped search, archive/delete reentry, directory-only
documents and snapshot rehydration. Mounted production surfaces also check one persistent character through native
submission, running, Talk and dispatch, the accessible Stop action, notification
deferral while editing, failed submission draft retention, Escape retaining landing
input from both editor and native fallback, bottom-Dock Escape dismissal,
narrow resize and Settings/history cover/remount without forced reopening.
Landing outside-click coverage checks that a click inside keeps input open,
a window-background click keeps it open without losing the draft, including
after covering routes and remounting. The three methods sending
native mouse/key events run in CI's isolated AppKit input host; the remaining
state/layout methods also run in the ordinary Swift suite. Plain SwiftPM's native
text tracking was observed to exit zero before its completion summary, which
coverage treats as failure. A second native window also
checks that both focus loss and an actual click retain input and preserve the
draft. The outside-click Swift suite additionally drives native
child/sheet windows and nested menu-tracking notifications to protect auxiliary
composer interactions; this is not a physical cross-app mouse-delivery test.

Catalog transactions pass through the actual preparation/installation boundary.
The fixture also delivers a connected client event to the real workspace so a
running snapshot is not mistaken for disconnected, retained execution state.
Fixture send callbacks replace unavailable remote admission; no Runtime, model
provider, installed profile or microphone is used. The independent
[Moku backend replay](../moku/README.md) verifies actual creation/admission and audit
records. The [visual demo](../../../demos/moku-landing/README.md) additionally checks
cursor movement, light/dark pixel contrast and attachment layout. These are native
behavior checks, not optical frame pacing. The launcher requires all nine cases
without skips; plain headless Swift runs explicitly skip this display-dependent suite.

The Moku composer's native click/NFD-persistence case uses the isolated AppKit
loop. Plain SwiftPM explicitly skips that mouse-tracking case; `--moku-composer`
must complete all eight tests without skips to certify it.
The session-picker case mounts the production Moku reader and window navigation
at 0.25×, 1× and 5× workspace zoom. It checks native accessibility geometry below
Back, activates Back, retains the draft and exports `history-session-*.png`.

The composer hold replay mounts the Overview input row, the current owner of
voice entry. The history click/persistence case separately requires that the
reader has no voice monitor. The hold proof queues each down/drag/up through AppKit in order. A
window- and gesture-scoped local monitor anchors a private serial Dispatch timer
to actual down dispatch. Strict zero-leeway deadlines supply drag after 100ms
and release after the unchanged 100/800ms duration; the worker creates and posts
each event without waiting for the MainActor. Apple permits
[posting events from secondary threads](https://developer.apple.com/documentation/appkit/nsapplication/postevent(_:atstart:)).
The Swift SDK nevertheless imports this inherited AppKit method as `MainActor`.
The [native input test support](../../../app/macos/Tests/NativeInputSupport/README.md)
provides one typed Objective-C function that creates and posts the mouse event
on the calling worker. The application reference and window coordinates are
captured on the main actor; the bridge never inspects a window or view. SwiftPM's
Host test target and the isolated replay compile the same source. The replay
stages its header, module map and implementation, compiles with warnings as errors,
and records their hashes, the object hash and compiler command in `launch.json`.
Planned and actual post times, optional drag/up dispatch observations and
voice-start timestamps are retained. Each post must complete within 50ms of its
deadline; drag and short release must also precede the recognizer's actual
minimum press duration. Nested text tracking can bypass local drag/up monitors,
so these optional observations cannot certify or invalidate execution merely by
being absent. Every stage still requires real release posting and the recognizer
back at `.possible` within three seconds, without forcing layout/display while
the gesture is in flight. The original start-count, draft and detachment
assertions, 90-second replay timeout and owned-process stack capture remain unchanged.
Posting receipts do not claim physical input delivery.

CI uses `--isolated-input` to compile the same history-composer, browser-viewport,
Report, Thread TOC and Landing test sources into one AppKit host. It executes
exactly the nine input/responder, pointer and native-panel methods deferred by
SwiftPM, requiring all nine to pass without skips, while their remaining methods execute
in the single ordinary Swift suite. The Report modal case acknowledges WebKit's focused
frame before native Escape and observes its close event and trusted cancel;
a fixed delay or JavaScript dismissal cannot certify default input handling.

`--harness-forms` generates its interaction fixture through the production Go
OpenCode reducer/projections, then mounts the native Pi settings and OpenCode
Reader. It checks colliding provider/model choices, default/optional/hidden/
conditional fields, exact Go public IDs and cancellation without required answers.

`--browser-viewport` mounts the real loopback Browser fixtures, including cancelled
navigation, SPA history traversal, blocked protocols and popup POST notices,
popup downloads, native editing keys, and annotation capture after
page changes. `--composer-contrast` additionally checks the mounted host directory
picker's 50-reference limit through its real accessibility controls, then selects
the same directory after removing a reference. Both use the AppKit event loop.

## Application page navigation

```sh
python3 tools/verification/reading-presentation/run.py --application-navigation
```

Mounts the production Report reading page with an observable host
that renders its published back action. Git is a Thread extension, not a separate
application page. The replay requires navigation to
settle without republishing on unrelated redraws, checks language changes and
back dispatch, then verifies cleanup and a fresh identity after remounting.
Missing fixture records exercise the Report's unavailable-content state without
starting a Runtime, reading a repository or loading WebKit.

## Overview search and return

```sh
python3 tools/verification/reading-presentation/run.py --overview-search
```

Runs the complete `NativeOverviewSearchTests` suite in the AppKit event loop,
including the three cases skipped by ordinary SwiftPM: selected-chip search
morph/reversal at 360/540/1100pt in light/dark appearance, fixture-backed Chinese
body keyword search, and continuous query edits retaining mounted card identities.
The suite uses the production model, Chrome and Canvas with synthetic public
catalog/search responses; it starts no Runtime or model provider. The morph case
slows its test animation to inspect intermediate geometry, so this is functional
coverage, not production transition timing or rendered-frame measurement.

## Reading presentation

Run on macOS with the current Xcode toolchain:

```sh
python3 tools/verification/reading-presentation/run.py
```

The isolated AppKit app links the worktree's production reading stack and
Overview canvas. It runs the native-only Swift integration suite with real
window visibility, preserving the 420 ms opening animation and live glass.
It checks retained native controls, deferred content/full environment updates,
latest content during return, first-responder eligibility and activation,
cloud visibility, and opening interrupted by reverse/cancel/resize/disable.
It also opens the production history route at narrow and wide window sizes,
checking that long Chinese/path and multiline prompt headings occupy the same
height as a two-line title and keep the answer in place.

The launcher stages link objects, modules, headers, framework, replay sources
and resource bundles outside the checkout. The app validates its temporary
workspace before mounting Cocoa. Logs, launch paths and the app PID are exported
to `.scratch/reading-presentation/<suite>` after exit. Timeout/cancellation
terminates the owned app; diagnose a permission/focus failure before retrying,
without granting Desktop access.

No Mokusei runtime, provider, model request, microphone or global input is
used. This is a behavioral replay with small fixture controls, not a performance
benchmark or an optical FPS measurement. Ordinary SwiftPM also runs these reading
cases when a graphical session and display are available, using the shared native
test gate to prevent cross-suite window/focus contention. This isolated launcher
additionally exercises AppKit's application event loop. It requires a successful
process status, the complete suite's pass marker and no skipped cases.

The launcher compiles the same [test environment](../../../app/macos/Tests/Support/README.md)
source as SwiftPM. Missing graphical capability produces explicit test skips in a
plain test run; it fails an explicitly requested native replay as incomplete.
The [Swift audit](../swift-tests/README.md) records the scheduling/host controls,
headless admission check and existing Go-fixture skips. Do not treat a successful
headless summary as verification of the native cases that it lists as skipped.

## Browser page-owned dialogs

```sh
python3 tools/verification/reading-presentation/run.py --browser-dialogs
```

Runs `NativeBrowserDialogTests` against the production Browser delegate using
WebKit frame and file-panel parameters from local HTML. Its four tests contain
19 cases: alert/confirm/prompt/file selection across release, suppression and
navigation; hidden presentation; a confirmed prompt opening the next dialog;
and cancellation callbacks attempting to reopen during recursive navigation.
Each callback must complete once, and retired pages receive negative results.
The runner requires every parameter group and the final suite pass marker.

This suite needs AppKit's application event loop. A plain SwiftPM process can
exit at its first native file panel without a complete test summary, even with
status 0, so that runner explicitly skips it. Normal file selection returning
URLs and positive alert/confirm clicks are not covered by these cases. No
external page, model request, global input or installed app is used.

## Browser viewport and navigation

```sh
python3 tools/verification/reading-presentation/run.py --browser-viewport
```

Runs all eight `NativeBrowserViewportTests` in the isolated AppKit event loop.
Real loopback HTTP fixtures cover rejected iframe/new-window downloads, canceled
provisional navigation, native word navigation in ordinary and shadow-root text
editors, modal Escape, annotation capture after target mutation/removal, document
zoom, native portal layers and thread-isolated cookies. It uses only events sent
to its own windows and makes no external page or model request. Run serially with
other native replays and SwiftPM builds. Plain SwiftPM still runs the existing
portal geometry, render layers and navigation cases. The real annotation mouse
input and focused document responder-chain tests explicitly skip without this
native replay capability; both run without skips in this eight-test launcher.

## Overview animation and native decoration evidence

The title cancellation case starts its WindowServer stream before the initial
`A → B → A` reversal. It sends B once and establishes an outgoing A from the
latest post-input frame with 10–90% reference ink and less than 50ms age. The
actual A setter must begin and return before B's `ContinuousClock` instant plus
the production owner's 150ms outgoing sleep, with freshness rechecked. This
earliest-replacement bound excludes B's incoming frames; the saved before/after
receipts reject preemption across it. It proves early source submission, not
SwiftUI consumption. AX label/value is diagnostic outside that live path because
model opacity zero can hide a still-visible fading Text from AX. The bounded
three-second prerequisite replaces the assumed 50ms sleep; it does not repeat B
or change the original 500ms return observation and self-rendered equality
assertion. The last available WindowServer frame at that same check must follow
A's setter return and exactly match the original content pixels, without waiting
for a match or using a later frame. Continuous/raw source times, pixel-analysis
times, all captured frames and the actual observation time distinguish a blank
`cacheDisplay` snapshot from a blank composed window; a later settled frame cannot
certify the earlier observation. The incoming-cancellation sensor still requires the
latest frame, 10–60% ink, less than 50ms sample age and the original three-second
deadline. It caches each frame's exact ink total using Accelerate's integer
histogram over the same BGRA pixels, with static references computed before
input. It retains batch sizes and processing times, then checks the accelerated
values against the original scalar formula after the stream stops. Skipped
intermediate frames remain evidence, not substitutes for a current frame.

The existing `--tag-glass-captures` host also executes
`SwiftUIOverviewInteractionTests.excerptRevealKeepsMovingThroughRewriteAndWidthChanges`.
It mounts production `ThreadCardExcerpt` in a fixed onscreen window, captures
complete WindowServer frames during reveal and rewrite, and changes the component's
local width from 360 to 280pt during a reveal. Measured width and intermediate ink
observations are required; a completed 280ms task or matching final text is
insufficient. Reference frames use the same production text renderer. The moving
cases keep Reduce Motion disabled and do not substitute self-rendered snapshots.

The rewrite input waits for two observed partial frames with the same minimum
0.06 ink gain and 4pt leftward boundary movement used by the final oracle. The
latest frame must still be partial, at most 80% exposed, and less than 50ms old
after sensor work; the 450ms sensor deadline fails if this prerequisite is
unavailable. Every raw frame is retained, while the live sensor examines only
the latest frame in each received batch. It validates sRGB premultiplied BGRA
format and row stride, reads precomputed glyph offsets and a narrow width-marker
region, and records per-stage processing times and sample age. Before input,
its exposure and boundary values must match the existing crop oracle on the
settled blank and full reference; after capture, every live sample is checked
against the unchanged offline oracle. Sensor samples, input times, presentation
timestamps and accepted frame indices are retained. PNG encoding and complete
frame, geometry and motion assertions run after capture stops. The local resize
still occurs
140ms after input. Rewrite frames must have no hard rising mask edge and must
still show an early reset within 65ms, new incoming motion and the exact settled
production reference within the existing pixel-error tolerance.

The method has one explicit `native/tag-glass-captures` owner, so the
ordinary Swift run excludes it while complete coverage requires its passing native
outcome and `EXCERPT_INK_MOTION_CONFIRMED` marker. Screenshots, capture timestamps
and measurements are retained in `excerpt/` under this host's evidence directory,
including failed runs. `provenance.json` records the actual checkout and product
Git tree, worktree-diff digest, input-file and signed replay binary SHA256 values,
run/attempt identifiers, and capture-file hashes. The width stripe uses the
component frame's top-leading geometry; its measured pixel bounds must stay
outside all ink regions. This Debug replay validates component behavior; the
separate [Release CI comparison](../overview-ci-performance/README.md) owns CPU.

`NativeOverviewDecorationCaptureTests.nativeCloudAndScanMoveInComposedOverview`
mounts the production Overview workspace with one public Codex running thread
and a running subagent. It requires the actual 2×1 projection, native cloud and
scan views, a live Metal layer and CA scan animation. Two disjoint later capture
intervals must show cloud pixel changes in a quiet region that excludes duration,
text and scan pixels. The fixed fixture's quiet bottom strip spans both card cells
(x=24...712, y=106...176 card points). Its title, duration, single excerpt and
derived row stay above the strip; 24-point side/bottom insets exclude rounded
corners. This covers a random cloud concentrated in either cell. The former
right-cell crop remains diagnostic, since a locally dark region cannot establish
that the cloud stopped. The 3.9-second capture, two predetermined intervals,
static control and movement thresholds are unchanged. Narrow-row contrast must show the scan moving through the
composed image. A legal 0.90→1.0 camera change must preserve the native objects.
Complete fixed/zoom PNGs, pixel measurements, geometry and provenance are retained
under `native-decoration/`. Transparency, glass colors, rounded corners and zoom
alignment require review of those real images; neither callbacks nor these
capture samples certify optical FPS or GPU time. The required success marker is
`NATIVE_OVERVIEW_DECORATION_MOTION_CONFIRMED`.

The same fixture also holds the main thread for 200ms after initial rendering.
Its independent ScreenCaptureKit queue requests 60Hz samples and admits only
complete frames with presentation timestamps inside the hold (excluding the
first 30ms). At least three frames and cloud changes in both halves above the
static control are required. A production Codex spinner in a separate corner
must change pixels in both halves too; hiding/resuming its native view must
remove/restore its compositor animation. `main-hold` PNGs, per-frame presentation
times and measurements retain the evidence, including the measured interval
that fails an assertion. `main-hold-context` retains the same 60Hz stream's
pre-drain frames and frames excluded by the hold filter; compare their timestamps
with `mainHoldWindow` to identify the surrounding frames and excluded prefix.
These diagnostic frames never contribute to the passing frame count or pixel
assertions. This does not certify input responsiveness, physical FPS or energy.

The same running AppKit host owns
`NativeReadingPagePresentationTests.retainedOverviewReturnsWithLatestContent`.
This test requires an actual `NSApplication.run` loop before observing an opening
midpoint, reversing the page and checking latest Overview content with no remount.
Its original geometry and return assertions remain intact. Ordinary Swift execution
excludes this exact method; complete coverage requires its native passing outcome
and `OVERVIEW_RETAINED_RETURN_CONFIRMED`, so deferring it cannot become a skip.
These are AppKit geometry/content observations, not WindowServer pixel assertions.

The capture launcher requires all seven assigned methods: two tag-glass captures,
title reversal, excerpt reveal, native decorations, retained Overview return and
Tag Settings first-frame capture. The last case mounts the production onboarding
animation across initial entry and retained returns. Capture starts before
insertion and keeps every entry frame; the 400ms observation window starts only
after the native scene has prepared and begun playback (or resumed its settled
composition). At least two complete frames must follow that readiness boundary,
and every retained frame must reject a broad light rectangle. Cold texture
preparation therefore cannot substitute a blank pre-mount frame for entry proof.
It runs with the real AppKit loop and emits `TAG_ONBOARDING_FIRST_FRAME_CONFIRMED`;
ordinary SwiftPM timing cannot certify capture delivery. A clock outside the
sampled area supplies compositor updates during paused final scenes. Frame times,
all PNGs and source/binary provenance are retained under `tag-first-frame`, and
pixel scans/encoding run only after capture stops.

## Overview tag bar

The same isolated AppKit runner can exercise the production Overview tag bar:

```sh
python3 tools/verification/reading-presentation/run.py --tag-glass
```

This runs seven `NativeOverviewTagGlassTests` cases against production Chrome.
CI uses `--tag-glass-captures` for the two WindowServer pixel cases, because the
other five already run in the ordinary Swift suite. Both modes reject skips and retain
the same assertions. The same job's verified Swift build avoids repeating SwiftPM build;
ordinary local invocations still build current sources.
WindowServer capture explicitly scales to the requested two-pixels-per-point
buffer. On a 1x screen the default only downsizes, leaving padded space instead
of the 2x coordinates required by the unchanged pixel assertions.
Moving frames use a WindowServer stream started before input. Complete pixel
buffers are copied off the main actor; pixel scans and PNG/JSON writes happen
after capture stops, so they cannot consume the short animation. Reading-page
opacity samples use the actual AppKit front position and one shared bitmap.
They check selected-child titles, directory widths, narrow and zoomed layouts,
menu input ownership and interrupted close/reopen transitions. The parent title
stays frozen while its child glass returns, then updates after exit. Controls
are driven through their real accessibility actions, without physical hover.

The prefix case compares production glyph pixels with unconstrained native text
for bare/variation-selector tools, palette and skin-tone/ZWJ emoji, plus the
actual Lucide folder fallback. It also renders the real glass/scroll hierarchy
with short and long Chinese/directory names, counts and all three actions at
360/540/1000pt in light/dark appearance. The chip height, viewport containment
and action clearance must remain intact. To retain glyph references, pixel
measurements and 30 WindowServer PNGs:

```sh
MOKUSEI_TAG_ICON_ARTIFACTS=/tmp/tag-icon-evidence python3 tools/verification/reading-presentation/run.py --tag-glass
```

Glyph comparisons use SwiftUI ImageRenderer; the optional window captures show
the same prefix inside production Chrome and require screen-capture access.
The folder in this bar uses bundled Lucide paths, not SF Symbols. This replay
does not exercise physical horizontal scrolling or search-morph frame pacing;
search uses the same production prefix.

The directory-selection case reproduces the recorded `OpenAgent / 功能改进`
→ `界面设计` switch and selects the child again through the real accessibility
actions. WindowServer pixel spans require both directory capsule ends to stay
rounded throughout the resize, with intermediate widths required when Reduce
Motion is off. This catches the transient straight right edge that settled
geometry checks miss. It uses real glass on a black background in dark appearance;
it also scrolls the mounted filter bar to clip each side of the directory and
checks pixels immediately inside/outside the viewport. It does not measure
optical frame pacing or drive the physical pointer.

```sh
MOKUSEI_TAG_SWITCH_ARTIFACTS=/tmp/tag-switch-evidence python3 tools/verification/reading-presentation/run.py --tag-glass
```

The launcher retains before/during/after PNGs and `pixels.json` under the run's
`switch` evidence directory by default, including failed captures. The variable
above overrides that destination. Screen-capture access is required.
See the [recording diagnosis and native before/after evidence](evidence/switch-clipping.md).

The short-child regression additionally captures this process's WindowServer
window during the production glass return animation. Its selected `OpenAgent`
parent is wider than the single `配置修复` child, as in the reported recording.
Pixels must extend beyond both sides of the settled child viewport below the
parent; the old fixed-width clip paints neither strip. Set
`MOKUSEI_TAG_MORPH_ARTIFACTS=/tmp/tag-morph-evidence` to override the default
`morph` evidence directory for PNG samples.
The same artifact flag also records a fresh opening at target offsets 0/50/100/150/220/320/450ms, with actual WindowServer capture intervals in `opening-times.json`. Compare identical fixtures before and after a motion change; these are sampled keyframes, not an optical latency or FPS measurement.
This case needs screen-capture access and skips the moving-pixel assertions
when the system has Reduce Motion enabled. It exercises the real accessibility
close action, not physical hover or an optical frame-rate benchmark.

The combined Chrome + Canvas case invokes production accessibility actions to
open a directory submenu, select each child and close it through the same 180 ms
clear path used on hover exit. It checks the parent button's accessibility value, absence of a separate
current-filter caption, and stable parent geometry during menu exit at wide
and narrow window widths. Scroll snapshots enter
the production canvas handler at the live child-button coordinates: a visible
submenu retains input, a nearby canvas point pans, and the former menu location
pans after dismissal. Complete direct/end/momentum sequences check both
menu-to-canvas native ownership and canvas-to-menu canvas ownership. The fixture
requests its own enhanced accessibility tree through AppKit; it changes no
system accessibility setting. Chrome and Canvas share the workspace-owned native region
registry. These snapshots do not exercise OS scroll delivery or physical hover.
The combined Chrome + Canvas AX/direct-scroll case hosts its native window
outside all physical screens before showing it, with AppKit frame constraints
disabled only for this fixture. It asserts offscreen placement, production open
scope and mounted-menu state before selecting a child. This prevents physical
hover from closing the menu during its unchanged 300ms observation. The glass
pixel cases remain onscreen. The replay does not move the user's pointer or
disable production hover logic. See the [baseline/speed hover investigation](evidence/subtag-ax-isolation.md).

The long-title regression also renders all three production action buttons
(automatic view, restart and settings) with three long directory names that fill
the filter bar. At 360/540/620pt and at 2× window zoom with 720/1000/1242pt windows,
selecting a child, returning to its directory and clearing must leave the bar
inside the window and separate from the actions. A wide 1000pt window is the
control case. Child selection stays in the parent title without a separate caption.

## Settings capsule and return

```sh
python3 tools/verification/reading-presentation/run.py --settings-transition
```

Three integration cases mount the production scene, Dock and Settings page.
They check the stable panel size, bottom and landing anchors, narrow windows and
1×/2×/5× zoom, retained page/Overview identity, rendered backdrop blur, the dark
page and glass shell inside a forced light window, consumed
outside clicks, native Escape and close clicks, input/Note restoration, pending
messages/interventions, reversal, resize, inactivity and explicit settling.
Screenshots are exported with the suite's evidence. This compositor-dependent
suite launches through LaunchServices so its first window has foreground
activation; capture requires a key window and full-size WindowServer geometry,
rejecting system transition thumbnails. Reduce Motion is observed
from production's environment without changing system preferences.
The required CI `native` replay group runs all three methods through
`settings-transition` in this host. SwiftPM explicitly defers them and the coverage
auditor rejects any missing passing replay outcome. The separate Go Settings launcher retains real persistence, conflict, validation
and IME coverage. The production-app navigation replay verifies rejection outside
Overview and keeps reading routes and their back actions intact.

## Report navigation and native window controls

```sh
python3 tools/verification/reading-presentation/run.py --report-navigation
```

Runs the four existing `NativeReportNavigationTests` cases in the isolated AppKit
runner. The mounted navigation and native dialog/download cases require its
running AppKit event loop for trusted WebKit mouse/key delivery and explicitly
skip in plain SwiftPM; the recoverable-error and route-state cases still run
there. A green plain Swift run needs this replay to complete Report input
coverage. A production Report loads fixture HTML in WebKit,
opens through the reading stack, replaces its document, changes workspace zoom
(0.25×/0.8×/1×/1.44×/5×),
scrolls to collapse/reveal and reverses an in-flight collapse. Intermediate samples
require the three real window buttons to share the navigation portal's vertical
offset; the collapsed endpoint requires all buttons hidden. Checks cover native
button sizes/actions, suppression/restoration while scrolled, resize and simulated
activation/deminiaturize/full-screen-exit notifications without losing the hidden
state, document focus and the dispatched back-button click. Leaving the Report
must restore ordinary window controls. The other cases cover native dialogs and
downloads without document replacement, recovery without retaining a retired
surface error, and return to the source execution or Overview.

The same mounted case keeps top content outside the fixed navigation safe area,
checks native word movement in closed Shadow DOM and Escape in editable elements
and a native HTML dialog, and rejects script-generated navigation keys. Its real
POST form click must show the non-GET new-window rejection notice without an
external open or HTTP request. Navigating from a collapsed Report to a short
loopback HTTP page must restore the native navigation and window controls. This
check acquires the ready destination's portal because the main-frame loading
cycle withdraws the previous document's navigation; it verifies its hit target,
back-button click and exit motion with the document.

This uses real production views and document scroll events, not a duplicated
animation implementation. It does not exercise physical hover, actual macOS
minimize/full-screen transitions, hardware zoom gestures or optical frame pacing;
window lifecycle notifications are synthetic. No runtime or installed app changes
are required. Ordinary native placement/hit-target tests and the Overview replay
provide additional coverage for the shared bridge.

## Local images in thread detail

```sh
MOKUSEI_LOCAL_IMAGES_ARTIFACTS=/tmp/thread-local-images-evidence python3 tools/verification/reading-presentation/run.py --local-images
```

Runs three native integration cases using production `ThreadMessage` and Markdown:
standard images and ordinary local image links at 360/900pt widths, Unicode/spaces
and encoded file URLs, case-insensitive localhost/empty-host acceptance and remote-host
rejection through the production parser (previews and click targets), bounded
raster/display size and aspect ratio, native link
delegate actions, non-image/missing/unreadable/oversize-file and directory fallback, blocked remote file/executable
URLs, and streaming literal text without media. Fixture images are generated in
an isolated temporary directory and removed afterwards. Optional artifacts are
window-content PNGs. This does not drive Finder/Preview, a live Harness session,
or measure frame latency; local decode uses the existing background ImageIO
thumbnail path. Existing network/host attachment behavior is unchanged.

Set `MOKUSEI_LOCAL_IMAGES_SOURCE` to an existing absolute image path to also
capture that file through the production message component as `reported-orbit.png`.
This optional input never changes or deletes the selected source file.

## Overview card appearance and retained native controls

```sh
python3 tools/verification/reading-presentation/run.py --overview-mounting
```

Runs `NativeOverviewMountingIntegrationTests`, including repeated light/dark
appearance changes on the flat production Canvas while a native editor owns focus,
a selected text range and a draft. It checks retained native/SwiftUI identities,
placements, structural snapshot count, camera and filter selection, then new
membership, filtering during exit, empty removal and reentry. The dedicated
[Card material capture fixture](../overview-input/README.md#flat-card-materials-and-native-lifetime)
provides four production screenshots with independent backdrop/opacity/palette
checks; this mounting suite checks state and lifecycle.

## Thread-card usage numbers

```sh
MOKUSEI_ROLLING_NUMBER_ARTIFACTS=/tmp/thread-usage-evidence python3 tools/verification/reading-presentation/run.py --rolling-numbers
```

Runs two `RollingNumberCellTests` and the Git summary/original-size case in the native application event loop. The
production Codex plugin consumes changing session-state token totals and replaces
its type-erased card snapshot, covering increases/decreases, compact-unit and
width changes, stable structure identity, interrupted updates and convergence to
a freshly mounted reference. The leaf checks retain equal-width digit cells at
raster scale 2. Incoming glyph direction is no longer automatically checked after
the unstable direction-correlation test was removed under explicit user authorization.
Optional PNGs capture the usage region of the production card. These are native
view snapshots, not optical frame pacing or a live provider/Runtime replay. No
system motion preference is changed; the number path retains its existing
always-animate policy. Historical pre-SwiftUI-shell metrics scrolled upward; the
restored interaction deliberately scrolls downward as requested.

## First response in Overview

```sh
python3 tools/verification/reading-presentation/run.py --initial-response
```

Four integration cases consume actual overview payloads exported by all four Go
adapters. They exercise first-scope eligibility, null/empty state, pending versus
execution precedence, reasoning/completed-answer eligibility, incomplete text,
no-text terminal states, second execution and fork exclusion, plans and bounded
Unicode prompts. They require unchanged search excerpts and composition keys,
reject malformed flags, and conservatively disable missing flags and Moku.
The mounted production plugin cards check body accessibility at their actual
1×1/extended footprints and save light/dark
PNGs under `.build/reading-presentation/initial-response-captures` (override with
`MOKUSEI_INITIAL_RESPONSE_ARTIFACTS`). A mounted identity also changes to real
content while hidden and returns without restoring the loading copy. A visible
handoff retains approximately 60ms/180ms production-component captures; those
are observation samples rather than a physical frame-pacing assertion.

The runner requires all four suite pass markers. It uses isolated AppKit windows,
no installed app or paid model. These fixtures do not toggle the user's Reduce
Motion preference, prove physical display frame pacing or cover real account
startup. System Reduce Motion and the 120ms visual entrance require separate
visual inspection; ordinary SwiftPM skips are not native replay evidence.

## Markdown reading regressions

```sh
python3 tools/verification/reading-presentation/run.py --markdown
```

Runs eleven native integration cases against production `ThreadMessage` and
`NativeMarkdownView`. They check complete bare URLs, source-aware escaped/entity
footnotes, whitespace-containing ordinary reference labels, Unicode code preservation,
NFC-to-NFD link replacement in a mounted reader, text growth/shrink and native
window resizing, left-to-right/right-to-left marker placement, paced-mount revision
supersession, folded labels and lazy continuations,
plain alternative text, partial/native copy, empty table columns, Command-arrow
selection collapse, long ordered markers, inline-code table geometry, tight lists
with empty quoted lines, and a percent-label footnote round trip through a
horizontally scrolling table in the outer reading viewport. The replay needs a
graphical session; it opens no external websites and makes no model requests.

The SwiftPM `MarkdownSourceIdentityTests` also cover definition-shaped prose,
multiline reference labels/titles, shifted inline source ranges after reference
definitions, extracted footnote URLs and byte-distinct parser cache entries.
`MarkdownRawSourceRenderingTests` retains the mounted `ThreadMessage` regression
for NFC-to-NFD body and code replacement without changing a document token.
`MarkdownSourceRangeTests` exercises Paragraph, ATX/Setext, table, code and HTML
boundaries under quotes and lists, including multiple/multiline definitions,
Unicode/Tab columns, LF/CRLF, trailing input, adjacent blocks and lazy code
continuations with an adjacent real footnote. The lazy HTML/prose matrix checks
attributes versus adjacent real references and full URLs across quote/list
prefixes, omitted prefixes, spaces, tabs and CR/LF/CRLF; BOM/NUL fixtures check
physical byte provenance through parser input normalization. It asserts both
complete URLs and the absence of leaked footnote tokens. The native eight-case
replay also renders a definition-prefixed Setext heading with literal code,
a multiline HTML attribute beside a real footnote, and a complete lazy-line URL.
`MarkdownFallbackSourceTests` covers normalization outside paragraph traces:
BOM/NUL tables, header/body cells, inline code/HTML/links/images, escaped pipes,
block literals and row-to-row changes in space/Tab container prefixes. `MarkdownTableRewriteTests` checks paragraph-to-header promotion with and without
blank lines, literal code/HTML and URLs in the synthesized paragraph, and raw
URL escapes against working explicit-link controls. It requires stable table
column counts, complete targets/display labels and later-cell references, even
without separator spaces. Indented code remains a literal control.
The production native fixture combines a BOM-prefixed paragraph immediately
before a table, header code, NUL, and an escaped-pipe URL before a later footnote
cell.
These run in the default Swift suite; the mounted source test requires a display.


The `--moku-composer`, `--composer-paste` and `--moku-note-tests` modes run the existing production Moku/composer suites in this same isolated event loop. They cover ordinary-click editing and exact Unicode persistence, immediate Return during 20/200-file paste preparation, accessible execution Stop and first-page interaction Cancel, and selectable Markdown in a 64-point note panel. Run each mode serially with all other native replays and SwiftPM builds.

The twelve-method note suite checks Talk-bubble note entry in both Natural
Scrolling directions, retaining the message and preserving native overflow
scrolling and Stop-control exclusion at narrow and wide widths. It also
activates the expanded production Dock's
history button through accessibility, with and without a note, checking real
scene navigation and draft preservation. Wide and narrow mounted layouts assert
history's position before voice or Stop, its shared action row, and separation
from a long voice transcript. The short-viewport Markdown case checks that
reading remains scrollable independently of the Dock-owned history button.

For headless-only verification, run
`MOKUSEI_TEST_HEADLESS=1 xcrun swift test --package-path app/macos --filter 'NativeMokuNoteTests|NativeMokuTalkTests'`.
Windowless production-Dock tests exercise retained text and eyes across widths
and verify minimum readable width when actions share the row. A mounted action
stack checks compact and stacked controls at narrow-width boundaries. Display-gated
button geometry/activation and rendered
Markdown cases explicitly skip; this run does not certify those cases.

## Moku execution links

`python3 tools/verification/reading-presentation/run.py --moku-execution-links`
runs the production note Markdown callback, Host admission and all four Harness
readers with delayed content resources. It checks exact result positioning,
message-completion follow/stop/resume, successor isolation, archived/failed and missing
execution targets. These cases also run in the complete hosted Swift suite.
The running-link case sends enough streaming blocks to fill multiple pages and
requires that none appear before message completion, including while waiting
for input. OpenCode's mixed text/reasoning/tool fixture must retain both execution
rows while withholding reply text. It then settles a message
while execution remains running, retains that reply while a successor message
streams, and checks full successor text after completion. Terminal cases retain
failed/cancelled reply text, including Pi's stale streaming marker after execution
settlement. The generic Markdown streaming path remains available to other readers.
The twelve tests include mounted `ThreadDetailFrame` and window Back controls:
application execution callbacks and explicit start-position reading requests to
old, current and missing executions return to Overview in one action, including
archived threads. Note deep links establish a successor before entry and reopen
the same old/missing result. Window Back, native Escape and the document close
callback all exit directly. Native sibling controls outside the viewport and a
real editor first consume their own Escape; a subsequent unfocused document
Escape still exits the route. Explicitly reselecting the entry's TOC row resumes
internal Back,
including when a successor arrives afterward; ordinary TOC history still returns
to the loaded current document before leaving the thread. A production
Harness-surface resource case checks that closing one of two equal-scope
consumers cannot revoke the survivor, and that surface retirement releases both remaining
consumers. The fixture supplies content, without opening a user Runtime/profile.
For window-free Host routing and content-handle lifetime verification, run
`MOKUSEI_TEST_HEADLESS=1 swift test --package-path app/macos --filter NativeMokuExecutionLinkRoutingTests`.
These two tests cover 12 route cases and three content scopes. They do not
certify the mounted window Back control, Escape delivery or return animation;
the other ten tests require a graphical session and explicitly skip headless.
The lifecycle case checks current and result timelines across completed, running,
waiting for input and completed states for all four Harnesses. Jump to latest
is absent for completed executions, disappears on completion without scrolling,
and stays absent when a successor starts. The existing running-link case verifies
that activating the mounted action resumes following.
The twelve-method replay also mounts the production clear-glass execution capsules
for all four Harnesses. It checks narrow long-title geometry, native accessible
activation, ordinary-link styling, full-title Copy and neutral/unknown/rehydrated
brands without changing the note incarnation or revision. That capsule method
has a mandatory `native/moku-execution-links` CI owner and must emit
`MOKU_NOTE_EXECUTION_CAPSULES_CONFIRMED`; a non-running AppKit host fails its
prerequisite rather than silently omitting the mouse path.

## Report controls and recovery

`--report-controls` runs the two focused regression cases.
`--report-navigation` runs four cases, including actual
WebKit confirm/prompt acceptance, alert completion, file-panel cancellation and
a loopback binary response that must preserve the loaded report. The production
Report detail is also mounted with a recovering HTML capability to ensure it
does not retain a duplicate failure overlay at the same content revision.

## Retired selector fixture

The direct embedded model/reasoning popover and headless slider suites were
removed. Current Settings and compact configuration select through the system
control; their Settings/Harness-form replays remain. The retired
`--model-selector` command fails explicitly rather than silently running another
suite. No native method may still defer to that removed launcher.

Title-motion capture waits on copied-frame arrival with the existing absolute
three-second deadline; it does not poll an empty capture queue. Every retained
frame and the newest-live-frame/freshness rules remain authoritative. Frame-wake
receipts accompany the existing pixel/input timing evidence. The production
Canvas revision replay separately waits for actual final mounted membership,
not only the logical FIFO/layout completion flag.

### Git token animation owner

`--rolling-numbers` runs the two remaining cell/projection cases and the Git
summary/original-size flip case in the real AppKit loop. The latter has an explicit
mandatory `native/rolling-numbers` CI owner: foreground/key-window admission, the
original three sampling intervals, three distinct frames and fixed 400×90 geometry
remain required. `GIT_TOKEN_FLIP_FRAMES_CONFIRMED` and the native process receipt
are audited; ordinary-suite exclusion never substitutes for that execution.
The rolling producer starts through LaunchServices so macOS admits it as a
foreground application before the existing window and pixel checks. Its scoped
artifact paths are forwarded so the original frames and receipts remain retained.
Bounded foreground admission precedes the original 100/90/300ms sampling timeline;
the foreground requirement is checked again at input and still fails if absent.


## Agent reading panel admission

`--moku-landing` also mounts the production workspace with a real catalog Agent
record. It checks source-card geometry, the measured native panel frame, resident
Moku identity and input, Settings exclusion, same-thread result retargeting,
resize/return and direct-result Back. A window capture is exported under
`agent-panel/root.png`. The Agent fixture delivers current and historical Codex
content through the Runtime client's ordered subscription stream. It verifies
the active execution's automatic sidecard, real launcher clicks and icon pixels,
Thread-owned input, and the production upper-left Close. The execution sidecard
is read-only, so its open state is checked by panel geometry rather than the
input-sidecard `followUpVisible` flag. Return/interruption input waits for both
outer admission and automatic sidecard layout to settle.
The card-identity case includes generated emoji metadata and waits for real
source anchors. It requires title/emoji to finish their travel with the panel
and checks the mounted heading stays centered in its current reading viewport
when the execution sidecard opens and folds. Do not assert a frozen screen
position across a viewport resize: that previously encouraged a left-aligned
layout regression. The production demo additionally tests a wide pane without
sidecards, requiring centered loading and loaded headings with no second flight.
The standalone thread-panel demo exercises real Sidecard content and shared
production split geometry with mock capabilities, including retained widths,
rapid switching and narrow vertical splits.

### Report and Git reading panels

The existing `--report-navigation` mounted case also exercises Report HTML in the
production application-panel wrapper and reading stack: scaled panel geometry,
Close clearance, unchanged traffic lights while scrolling, editing-first Escape,
DOM Escape return, the full Close circle and resize during an accepted return.
Its original full-window HTML checks remain coverage for the standalone surface.
The existing `--moku-landing` full-workspace case now opens both Report and Git,
checking actual source-card geometry, wide/narrow panel frames, retained Moku
identity/input, Settings exclusion, Close hit testing and resize completion.
These workspace fixtures exercise loading/unavailable content without a Runtime.
Report/Git cases also merge hidden catalog changes and require the refreshed
source-card frame before their close animation completes.
The Report fixture separately loads real HTML, and `GitNativeTests` retains diff,
selection, refresh and cancellation coverage with scoped capability fixtures.
