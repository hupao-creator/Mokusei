# Reading-page background presentation replay

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

## Overview tag bar

The same isolated AppKit runner can exercise the production Overview tag bar:

```sh
python3 tools/verification/reading-presentation/run.py --tag-glass
```

This runs seven `NativeOverviewTagGlassTests` cases against production Chrome.
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

The optional directory retains before/during/after PNGs and `pixels.json` with
the measured widths and corner insets. Screen-capture access is required.
See the [recording diagnosis and native before/after evidence](evidence/switch-clipping.md).

The short-child regression additionally captures this process's WindowServer
window during the production glass return animation. Its selected `OpenAgent`
parent is wider than the single `配置修复` child, as in the reported recording.
Pixels must extend beyond both sides of the settled child viewport below the
parent; the old fixed-width clip paints neither strip. Set
`MOKUSEI_TAG_MORPH_ARTIFACTS=/tmp/tag-morph-evidence` to retain PNG samples.
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

## Settings reveal and return

```sh
python3 tools/verification/reading-presentation/run.py --settings-transition
```

Three integration cases render the production `NativeMokuScene` with solid-color
fixture seats. Pixel samples require opaque Settings at the source while the far
Overview corner is still unrevealed (a uniform fade/scale fails), and complete
coverage at the end. At 1×/2× zoom the live page retains its full layout size.
Lifecycle checks cover deferred unmount/background admission during return,
opening/closing reversal, resize, inactive scene, missing source and explicit
settling. Reduce Motion handling is reviewed but not toggled by this runner (the
SwiftUI environment value is read-only; it changes no system preference).
No Runtime or model service is used. These check SwiftUI rendering and
semantic transition lifetime, not WindowServer frame pacing or physical clicks;
the separate Go Settings launcher exercises real page controls and save gates.

## Report navigation and native window controls

```sh
python3 tools/verification/reading-presentation/run.py --report-navigation
```

Runs the two existing `NativeReportNavigationTests` cases in the isolated AppKit
runner. A production Report loads fixture HTML in WebKit, opens through the
reading stack, replaces its document, changes workspace zoom (0.8×/1×/1.44×),
scrolls to collapse/reveal and reverses an in-flight collapse. Intermediate samples
require the three real window buttons to share the navigation portal's vertical
offset; the collapsed endpoint requires all buttons hidden. Checks cover native
button sizes/actions, suppression/restoration while scrolled, resize and simulated
activation/deminiaturize/full-screen-exit notifications without losing the hidden
state, document focus and the dispatched back-button click. Leaving the Report
must restore ordinary window controls. The second case checks return to the
source execution and ordinary thread return to Overview.

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
