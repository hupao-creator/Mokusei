# SwiftUI Overview replay

Build and run the isolated application on macOS 26:

```sh
python3 tools/verification/overview-input/run.py
```

The runner links this worktree's production Swift objects, assembles a temporary
application bundle under `/private/tmp/mokusei-overview-*` and launches it through
Launch Services. It starts no runtime,
reads no user conversations or preferences, and posts no global input. Success
requires `PASS Overview SwiftUI replay completed`; a successful build alone is not
a replay result. Each run has a fresh application identifier (isolating macOS saved-window
restoration) and result file, whose path is recorded in
`.build/overview-input/result-path.txt`. The app path is recorded in
`.build/overview-input/app-path.txt`. Each private run directory is retained for
inspection and can be removed after its application exits. `launch.json` records
the actual PID, bundle identity, cwd and loaded images. The runner requires a
fixture-local cwd and rejects non-system images loaded from outside the bundle.

For a Computer Use launch, compile with `--build-only` and open the resulting
app path printed by the runner (or stored in `app-path.txt`). Add `--interactive` to leave the
fixture open for manual input and rendering checks. The fixture includes the
production canvas, camera, flat card surfaces, cloud shader, reading stack and multiline editor.
Its card includes the production emoji badge and completion mark. Check that
the clear glass circle and emoji remain readable without an added border;
hovering leaves the emoji visible and exposes no Send action. Use Open conversation
to open detail. In interactive mode, Command-Shift-D toggles light/dark appearance
without system changes.

The build driver still reads this checkout and uses its SwiftPM cache. The GUI
fixture uses copied resources and an embedded WebRTC framework, with a relative
bundle rpath; it never follows a resource link back into the checkout. Its cwd,
result and capture staging directories are also outside Desktop, Documents and
Downloads, even if `TMPDIR` points into the checkout. Thus a Desktop checkout
does not require giving the **replay application** Files & Folders permission.
The invoking development tool still needs ordinary access to its source tree.
No TCC settings, database, permission prompts or production app are modified.
See [the investigation and verification evidence](../../../app/macos/Sources/Host/Overview/README.md).

Resize requests fit the current screen's usable area; the replay still requires
the measured SwiftUI viewport to equal each requested size.

The automatic replay verifies:

- Initial framing and empty-scene reentry.
- Manual camera persistence and stable card identity across membership changes.
- Search camera bookmark restoration after automatic result framing, including
  a surviving visible result, empty results and the delayed refit window.
- Card growth and shrinkage using actual SwiftUI geometry.
- Historical filter entry scale and 12-point screen-space rise, compact filter
  packing with stable shared visible cards and camera framing, rapid filter
  reversal and retained survivor identity (including the delayed refit window).
  Card probes use the canvas coordinate space, so full-window safe-area handling
  does not change the measured animation offsets.
- Conversation opening/return through window-dispatched mouse clicks on the
  visible back chevron, including repeated visits and return after resize;
  retained Overview state and automatic framing. The fixture uses the ordinary
  workspace's stationary, blurred backdrop and emphasized detail entrance; see
  [Thread Detail transitions](../../../app/macos/Sources/Host/WindowNavigation/README.md).
- Theme changes without replacing card content.
- Transparent window backing, hidden title, full-window content and alignment
  of the real system controls inside the reading navigation capsule. Check the
  historical button origins (24/44/64, 31 points) after window resize and return.

It drives scene and camera APIs, dispatches back-button mouse events and sends
synthetic two-axis event snapshots directly to the production bridge handler in
its own visible window. Scroll OS-queue/local-monitor delivery is not replayed;
window-dispatched mouse events do exercise the monitor's cancellation callback.
Gesture replay also checks momentum interruption, input-region
ownership and outer-window zoom conversion at 0.5 and 2. Pinch samples exercise
the production controller directly, not SwiftUI hardware recognition. See
[gesture behavior and verification limits](../../../app/macos/Sources/Host/Overview/README.md).
Physical drag/pinch, absence of Overview context menus,
keyboard shortcuts and text entry need the interactive fixture or UI tests.
The canvas uses native two-axis scrolling and SwiftUI drag/pinch. Background
clicks restore automatic framing; cards, background and directory chips have no
context menus. In the interactive fixture, right-click and Control-click both
card content and blank canvas, then verify ordinary left-click activation and
camera dragging still work. Directory hover/accessibility filtering is covered
by the production Overview interaction replay. Editors use Enter for a newline and
Command-Enter or the send button to submit.

Run the affected integration tests with:

```sh
MOKUSEI_OVERVIEW_SEARCH_NATIVE_REPLAY=1 xcrun swift test --package-path app/macos \
  --no-parallel --filter 'NativeOverview|NativeReadingPagePresentation|NativeMoku|NativeComposer|SwiftUIOverviewInteraction|NativeHTMLGeometry|NativePerformanceCache|NativeWindowControlPlacement'
./scripts/go.sh run -race ./tools/verification/runtime-helpers --swift-shutdown
make check
```

Tests host production SwiftUI in test-owned windows. Geometry, draft contents,
input-method composition, selection, palette rendering and navigation are checked
at their public behavior boundaries. AppKit used by test fixtures is separate
from production scene implementation.

The Overview capacity integration tests additionally cover five mixed-size cards
that fit a wider packing, attention eligibility changes, six-card growth that
exhausts straight-move optimization, count changes, insufficient space and resize
recovery at the readable boundary. They assert actual rendered frames and stable
mounted identities. Packing tests distinguish a legal repack fallback from a
certified straight-move order, including search cutoff after a fitting witness.

The production window uses AppKit bridges for its real traffic-light controls
and window-scoped canvas scroll routing. Window content, the navigation capsule,
drag and pinch recognition remain SwiftUI.

The historical transition contract and restoration are documented in
[Overview card transitions](../../../app/macos/Sources/Host/Overview/README.md).
`NativeOverviewTransitionTests` also samples ordinary exit opacity and geometry,
exit-before-reflow, shrink-before-grow, empty-result camera timing, instant entry
and successive structural revisions arriving while an entry is already playing.

## Real-card transition recording

```sh
python3 tools/verification/overview-input/run.py \
  --capture-transitions .build/overview-transition-capture
```

This alternate replay hosts the production `HarnessThreadCard` (text, emoji
badge and completion mark) in the production canvas with synthetic conversation
data. It records only its own full-size native WindowServer window using
ScreenCaptureKit; it does not start a runtime or change the installed app.
Light/dark runs cover 16 → 3, 3 → 16, a 95ms interrupted reversal, ordinary removal
and an ordinary empty result. Retained cards must keep their semantic identity.

A successful run requires recording completion, MP4 decoding and pixel checks,
not just a build. The output contains `real-cards.mp4`, `events.json`, lossless
reference/intermediate screenshots, decoded contact sheets and `inspection.json`.
Surface, badge and text regions of an outgoing card must match the empty background
after its 140ms exit, while survivor motion is still running. The same checks run
on an intermediate decoded video frame; video references use matching encoding
to avoid treating H.264/color conversion as a surface remnant. A missing/late
screenshot or invalid/short recording fails the replay.

Recording is a separate ScreenCaptureKit mode and may require Screen Recording
consent. It is not needed by the ordinary automatic input replay. Recording
files are produced and inspected in the private fixture directory; only after
success does the Python driver copy them to the requested output directory.
With `--build-only`, capture files remain in that private directory when the app
is opened manually; `--capture-transitions` specifies the eventual driver export.

Storyboard labels use approximate elapsed recording-callback times, not scan-out
timestamps. Capture cadence is not a display-FPS benchmark. Review intermediate
sheets as well as the automatic checks, especially interrupted transitions and
ordinary exits. To inspect an existing recording again:

```sh
xcrun swiftc -parse-as-library -swift-version 6 -warnings-as-errors \
  tools/verification/overview-input/inspect-capture.swift \
  -o .build/InspectTransitionCapture
.build/InspectTransitionCapture .build/overview-transition-capture
```

## Flat card materials and native lifetime

```sh
python3 tools/verification/reading-presentation/run.py --overview-mounting
python3 tools/verification/overview-input/run.py --card-materials .build/card-materials
```

The mounting suite changes light/dark appearance on the production Canvas while
a native editor retains focus, selection and draft. It asserts the flat material
policy on every mounted card, preserves native/SwiftUI identities, placements,
manual camera, selected filter and structural snapshot count, then adds a card,
filters during retirement, removes everything and reenters. No material
preference is created or simulated.

The capture mode takes four full, lossless WindowServer PNGs:
light/dark appearance × two deliberately different fixed backdrops. Its 1200×760
own-process window includes production Codex, Claude, Pi and OpenCode
`HarnessThreadCard` content/logos, Report, plan, completion marks, emoji badges,
Chrome and the actual bottom-centered `NativeMokuDock`. Fixture data
is deterministic and no Runtime starts. Cloud motion is paused and the Dock's
scene phase is inactive; their rendering remains present.

The independent PNG inspector requires every card's nonsemantic interior strip
to stay unchanged across the two backdrops. Completed Codex/Pi cards and Report,
whose strips have no running cloud overlay, must also match their resolved opaque
production palette colors. Running cards retain their cloud field and still
satisfy backdrop independence. The sample strips retain the existing 12-point
Dock shadow exclusion. An exterior control must visibly change, proving that
the pair did not accidentally capture one backdrop twice.

A separate quiet strip inside the production Dock, outside all cards, must
respond to the changed backdrop. This pixel check proves background response;
the untouched production material implementation establishes that the response
still comes from the existing glass. Chrome remains in the full images for
visual review. Reduce Transparency must be off for this observation; the runner
fails with an incomplete-observation message when the system selects the valid
opaque fallback, and never changes that preference.

Every capture retains the same mounted identities, appearances, placements,
manual camera, snapshot count and measured Dock frame. `captures.json` records
those facts and resolved palette references; `inspection.json` retains all
pixel regions and measurements. Files are copied to the requested output only
after replay and independent inspection succeed. ScreenCaptureKit may require
Screen Recording consent. Review all four images for text/control legibility,
borderless clear emoji glass, static terminal/plan appearance, rounded corners
and cloud color.

These static captures do not prove moving native decorations. The existing
`reading-presentation/run.py --tag-glass-captures` owner includes
`NativeOverviewDecorationCaptureTests.nativeCloudAndScanMoveInComposedOverview`,
which requires live native objects and actual cloud/scan pixel motion. Neither
entry point claims optical FPS or GPU duration.

The old circular-Moku and glass on/off images remain historical evidence in
[evidence/moku-dock-refresh](evidence/moku-dock-refresh/README.md); they do not
define current card materials.

## Historical glass performance

The on/off performance launcher is retired because Overview cards have one
fixed flat presentation. Running two identical conditions would not be a valid
material comparison. Historical raw evidence, analysis and plotting remain
documented in [PERFORMANCE.md](PERFORMANCE.md). Current independent product
comparisons use the [Overview Release CI runner](../overview-ci-performance/README.md);
this change adds no new performance measurement protocol.
