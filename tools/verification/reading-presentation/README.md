# Reading-page background presentation replay

## Thread history sidebar

```sh
python3 tools/verification/reading-presentation/run.py --thread-sidebar
```

Mounts the production conversation, lazy TOC, timeline and turn components in an
isolated AppKit host. Five integration cases cover selection and Back scroll
retention, author and visibility controls, Up/Down, Home/End, Return/Space and Escape,
inherited history, deletion, arriving successors and external result anchors.
A 2,500-turn fixture asserts bounded mounted index controls and body demand, and
locates an old turn outside the current window. This is a resource-demand check,
not an FPS or target-device latency claim. Widths 360, 640 and 1180 exercise long
author accessibility and save settled dark/light screenshots under
`.scratch/reading-presentation/NativeThreadHistorySidebarTests`.

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
deferral while editing, failed submission draft retention, Escape/reopening,
narrow resize and Settings/history cover/remount without forced reopening.
Landing outside-click coverage checks that a click inside keeps input open,
a window-background click keeps it open without losing the draft, including
after covering routes and remounting. The three methods sending
native mouse/key events and the full Workspace search geometry method run in
CI's isolated AppKit input host; the remaining state/layout methods also run in
the ordinary Swift shard. Plain SwiftPM's native
text tracking was observed to exit zero before its completion summary, which
coverage treats as failure. A second native window also
checks that both focus loss and an actual click retain input and preserve the
draft. The outside-click Swift suite additionally drives native
child/sheet windows and nested menu-tracking notifications to protect auxiliary
composer interactions; this is not a physical cross-app mouse-delivery test.

The full Workspace search case runs the production morph in a native window
and waits for settled carrier and viewport geometry before comparing rendered
text, AppKit's actual `drawInsertionPoint` rectangle and the emphasized caret
layer. The recorded native rectangle must belong to the current selection; the
zero-width `firstRect` logical boundary independently checks text centering and
scroll visibility. The layer
assertions always execute, including horizontal position, long-query scrolling,
clear/reopen, resize and application scaling. A direct clip scroll retains the
vertical-origin assertion. The method is explicitly owned by CI's
`native-controls/isolated-input` check and excluded from ordinary Swift execution,
because a plain SwiftPM host can leave the production morph and native viewport
unfinished. Both `--isolated-input` and `--moku-landing` require its passing result
and `SEARCH_CARET_GEOMETRY_CONFIRMED` marker; a partial morph or absent caret
cannot count as successful coverage. These are native geometry assertions, not
a WindowServer pixel comparison.

Catalog transactions pass through the actual preparation/installation boundary.
The fixture also delivers a connected client event to the real workspace so a
running snapshot is not mistaken for disconnected, retained execution state.
Fixture send callbacks replace unavailable remote admission; no Runtime, model
provider, installed profile or microphone is used. The independent
[Moku backend replay](../moku/README.md) verifies actual creation/admission and audit
records. The [visual demo](../../../demos/moku-landing/README.md) additionally checks
cursor movement, light/dark pixel contrast and attachment layout. These are native
behavior checks, not optical frame pacing. The launcher requires all ten cases
without skips; plain headless Swift runs explicitly skip this display-dependent suite.

The Moku composer's native click/NFD-persistence case uses the isolated AppKit
loop. Plain SwiftPM explicitly skips that mouse-tracking case; `--moku-composer`
must complete all seven tests without skips to certify it.

The composer hold replay queues each down/drag/up through AppKit in order. A
window- and gesture-scoped local monitor anchors a private serial Dispatch timer
to actual down dispatch. Strict zero-leeway deadlines supply drag after 100ms
and release after the unchanged 100/800ms duration; the worker creates and posts
each event without waiting for the MainActor. Apple permits
[posting events from secondary threads](https://developer.apple.com/documentation/appkit/nsapplication/postevent(_:atstart:)).
Planned and actual post times, optional drag/up dispatch observations and
voice-start timestamps are retained. Each post must complete within 50ms of its
deadline; drag and short release must also precede the recognizer's actual
minimum press duration. Nested text tracking can bypass local drag/up monitors,
so these optional observations cannot certify or invalidate execution merely by
being absent. Every stage still requires real release posting and the recognizer
back at `.possible` within three seconds, without forcing layout/display while
the gesture is in flight. The original start-count, draft and detachment
assertions, 90-second replay timeout and owned-process stack capture remain unchanged.

CI uses `--isolated-input` to compile the same history-composer, browser-viewport,
Report, Thread TOC and Landing test sources into one AppKit host. It executes
exactly the ten input/responder, pointer, search-geometry and native-panel methods
assigned to the native host, requiring all ten to pass without skips, while their
remaining methods execute in the normal Swift shards. The Report modal case acknowledges WebKit's focused
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

Mounts the production application and Git reading pages with an observable host
that renders their published back action. The replay requires navigation to
settle without republishing on unrelated redraws, checks language changes and
back dispatch, then verifies cleanup and a fresh identity after remounting.
Missing fixture records exercise both pages' unavailable-content state without
starting a Runtime, reading a repository or loading WebKit.

## Overview search and return

```sh
python3 tools/verification/reading-presentation/run.py --overview-search
```

Runs all 14 existing `NativeOverviewSearchTests` in the AppKit event loop,
including the three cases skipped by ordinary SwiftPM: selected-chip search
morph/reversal at 360/540/1100pt in light/dark appearance, fixture-backed Chinese
hybrid search, and continuous query edits retaining mounted card identities.
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

The method has one explicit `native-capture/tag-glass-captures` owner, so ordinary
Swift shards exclude it while complete coverage requires its passing native
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

The same running AppKit host owns
`NativeReadingPagePresentationTests.retainedOverviewReturnsWithLatestContent`.
This test requires an actual `NSApplication.run` loop before observing an opening
midpoint, reversing the page and checking latest Overview content with no remount.
Its original geometry and return assertions remain intact. Ordinary Swift shards
exclude this exact method; complete coverage requires its native passing outcome
and `OVERVIEW_RETAINED_RETURN_CONFIRMED`, so deferring it cannot become a skip.
These are AppKit geometry/content observations, not WindowServer pixel assertions.

The capture launcher requires all six assigned methods: two tag-glass captures,
title reversal, excerpt reveal, native decorations and retained Overview return.

## Overview tag bar

The same isolated AppKit runner can exercise the production Overview tag bar:

```sh
python3 tools/verification/reading-presentation/run.py --tag-glass
```

This runs seven `NativeOverviewTagGlassTests` cases against production Chrome.
CI uses `--tag-glass-captures` for the two WindowServer pixel cases, because the
other five already run in its Swift shards. Both modes reject skips and retain
the same assertions. A verified shared CI build avoids repeating SwiftPM build;
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
1×/2×/5× zoom, retained page/Overview identity, rendered backdrop blur, consumed
outside clicks, native Escape and close clicks, input/Note restoration, pending
messages/interventions, reversal, resize, inactivity and explicit settling.
Screenshots are exported with the suite's evidence. This compositor-dependent
suite launches through LaunchServices so its first window has foreground
activation; capture requires a key window and full-size WindowServer geometry,
rejecting system transition thumbnails. Reduce Motion is observed
from production's environment without changing system preferences.
The required CI native-capture lane runs all three methods in this host;
SwiftPM explicitly defers them and the coverage aggregator rejects any missing
passing replay outcome. The separate Go Settings launcher retains real persistence, conflict, validation
and IME coverage. The production-app navigation replay verifies rejection outside
Overview and keeps reading routes and their back actions intact.

## Report navigation and native window controls

```sh
python3 tools/verification/reading-presentation/run.py --report-navigation
```

Runs the two existing `NativeReportNavigationTests` cases in the isolated AppKit
runner. The mounted-document case requires its running AppKit event loop for
trusted WebKit mouse/key delivery and explicitly skips in plain SwiftPM; the
route-state case still runs there. A green plain Swift run needs this replay to
complete Report input coverage. A production Report loads fixture HTML in WebKit,
opens through the reading stack, replaces its document, changes workspace zoom
(0.25×/0.8×/1×/1.44×/5×),
scrolls to collapse/reveal and reverses an in-flight collapse. Intermediate samples
require the three real window buttons to share the navigation portal's vertical
offset; the collapsed endpoint requires all buttons hidden. Checks cover native
button sizes/actions, suppression/restoration while scrolled, resize and simulated
activation/deminiaturize/full-screen-exit notifications without losing the hidden
state, document focus and the dispatched back-button click. Leaving the Report
must restore ordinary window controls. The second case checks return to the
source execution and ordinary thread return to Overview.

The same mounted case keeps top content outside the fixed navigation safe area,
checks native word movement in closed Shadow DOM and Escape in editable elements
and a native HTML dialog, and rejects script-generated navigation keys. Its real
POST form click must show the non-GET new-window rejection notice without an
external open or HTTP request. Navigating from a collapsed Report to a short
loopback HTTP page must restore the native navigation and window controls.

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

## Overview mounted material changes

```sh
python3 tools/verification/reading-presentation/run.py --overview-mounting
```

Runs all six `NativeOverviewMountingIntegrationTests`, including repeated live
Glass world changes on the production Canvas while a native editor owns focus,
a selected text range and a draft. It checks retained native/SwiftUI identities,
placements, structural snapshot count, camera and filter selection, then new
membership, filtering during exit, empty removal and reentry. The dedicated
[Glass world capture fixture](../overview-input/README.md#glass-world-live-changes-and-fixed-production-captures)
provides four fixed semantic production screenshots and independent on/off
shell pixel comparisons; this mounting suite checks state and lifecycle.

## Thread-card usage numbers

```sh
MOKUSEI_ROLLING_NUMBER_ARTIFACTS=/tmp/thread-usage-evidence python3 tools/verification/reading-presentation/run.py --rolling-numbers
```

Runs three `RollingNumberCellTests` in the native application event loop. The
production Codex plugin consumes changing session-state token totals and replaces
its type-erased card snapshot, covering increases/decreases, compact-unit and
width changes, stable structure identity, interrupted updates and convergence to
a freshly mounted reference. The leaf checks retain equal-width digit cells at
raster scale 2 and measure incoming glyph direction against settled glyph ink.
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

Runs eight native integration cases against production `ThreadMessage` and
`NativeMarkdownView`. They check complete bare URLs, source-aware escaped/entity
footnotes, whitespace-containing ordinary reference labels, Unicode code preservation,
NFC-to-NFD link replacement in a mounted reader, folded labels and lazy continuations,
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

The note suite also activates the expanded production Dock's
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
streaming follow/stop/resume, successor isolation, archived/failed and missing
execution targets. These cases also run in the complete hosted Swift suite.
The eight tests include mounted `ThreadDetailFrame` and window Back controls:
note links to current, older and missing executions return to Overview in one
action and can be reopened; ordinary TOC history still returns to the loaded
current document before leaving the thread. A production Harness-surface
resource case checks that closing one of two equal-scope consumers cannot
revoke the survivor, and that surface retirement releases both remaining
consumers. The fixture supplies content, without opening a user Runtime/profile.
For window-free Host routing and content-handle lifetime verification, run
`MOKUSEI_TEST_HEADLESS=1 swift test --package-path app/macos --filter NativeMokuExecutionLinkRoutingTests`.
These two tests cover 12 route cases and three content scopes. They do not
certify the mounted window Back control, Escape delivery or return animation;
the other six tests require a graphical session and explicitly skip headless.

## Report controls and recovery

`--report-controls` runs the two focused regression cases.
`--report-navigation` runs four cases, including actual
WebKit confirm/prompt acceptance, alert completion, file-panel cancellation and
a loopback binary response that must preserve the loaded report. The production
Report detail is also mounted with a recovering HTML capability to ensure it
does not retain a duplicate failure overlay at the same content revision.

## Model and reasoning selector

`python3 tools/verification/reading-presentation/run.py --model-selector` runs
four mounted production-selector cases in the isolated AppKit application loop.
They cover exact IDs, disabled choices, keyboard commit/cancellation/type-ahead,
slider actions and reset, the model-list subpage, capability refresh, and a single
fixed choice. The Settings Escape monitor case dispatches through NSApplication
to verify model/reasoning cancellation before page return, unchanged values,
restored anchor focus, reopening and the second Escape. Light/dark model lists
and the reasoning panel are rendered under
`.scratch/reading-presentation/NativeModelSelectorReplayTests`. These component
renders do not certify WindowServer compositing or physical input delivery.

SwiftPM defers these four methods to this launcher because transient popovers
need a running AppKit application. The default CI `native-controls` replay group
runs them and the coverage collector requires their observed passing outcomes;
a skipped or incomplete replay is a failure.
