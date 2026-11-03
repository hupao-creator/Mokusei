# Local development layout log

The `com.mokusei.native.dev` application records local layout geometry automatically,
including **Release builds packaged for the dev channel**. `DEBUG` alone does not
identify the channel. Production bundles never enable this recorder, even with
`MOKUSEI_LAYOUT_LOG=1`. Disable it for dev performance comparisons by launching
the process with `MOKUSEI_LAYOUT_LOG=0`.

A raw Debug Swift executable can opt in with `MOKUSEI_LAYOUT_LOG=1` **and an
explicit `--data-dir /absolute/isolated/profile`**. Raw Release executables do not
opt in. The runtime exit-cleanup helper does not record. Startup configures logging
after acquiring the canonical profile lease; Reload retains the recording. Normal
Quit removes observers, restores notification flags, drains the bounded mailbox
and closes files/leases. Forced termination can lose buffered events (normally
about 250 ms, longer with delayed IO) and does not write `sessionEnd`.

## Files

Default location (or `<data-dir>/diagnostics/layout/` with `--data-dir`):

```text
~/Library/Application Support/Mokusei Native Dev/diagnostics/layout/
  layout-<pid>-<session UUID>/
    owner.lock
    events-0.jsonl
    events-1.jsonl
    ...
```

Startup prints `[layout-log] <session directory>/events-*.jsonl` to stderr. No
product UI is added. Logging is independent of the performance menu and
`MOKUSEI_PERFORMANCE`. Find recordings with:

```sh
find "$HOME/Library/Application Support/Mokusei Native Dev/diagnostics/layout" -name 'events-*.jsonl'
tail -f '/absolute/session/directory/events-0.jsonl'
```

Follow the next numbered file after rotation. Each segment starts with a `session`
header (schema, PID, segment, units and overwritten-segment count). Select the
newest session by directory creation time; UUIDs/PIDs do not sort by age. Sort
segments **numerically**.

## Records and coordinates

Geometry events include `time` (Unix epoch **milliseconds**, fractional precision),
`uptimeNs` (monotonic nanoseconds), increasing session-local `sequence`, `kind`,
`source`, `component`, `role` and optional `before`/`after`. Rectangles use
`[x, y, width, height]` in points without rounding or an epsilon. Illustrative event:

```json
{"time":1793670000123.5,"uptimeNs":1234567890,"sequence":42,"kind":"change","source":"swiftui.geometry","component":"s-<UUID>","role":"timeline.reading.column@MokuseiPluginUI/ThreadTimeline.swift:209","parent":"s-<parent UUID>","before":{"frame":[110,70,680,900],"bounds":[0,0,680,900]},"after":{"frame":[128,70,644,940],"bounds":[0,0,644,940]}}
```

- `initial`: first **observed** geometry per component identity, without `before`.
  Zero-size observations are retained. Later real sizing becomes `change`.
- `change`: frame or bounds changed exactly. Equal repeated callbacks produce no
  record. These are geometry observations, not a count of layout passes.
- `reparent`: AppKit window/parent/sibling changed, possibly with equal geometry;
  metadata describes the new location.
- `removed`: native view leaves the discovered tree or its window closes;
  `after` is absent. AppKit views get new IDs after detachment and rediscovery.
- `appeared` / `disappeared`: marked SwiftUI visibility callbacks, without geometry.
  A retained surface keeps its ID and last measured baseline across visibility
  changes. Equal geometry on return remains suppressed. Only a real geometry
  callback establishes `initial` or `change`; cached frames are never presented
  as a fresh measurement. New SwiftUI identities start a new baseline.
- `dataLoss`: the 4096-event mailbox overflowed. `dropped` and `throughSequence`
  report the loss; later `before` values still refer to last **observed** geometry,
  possibly from a dropped event. Segment headers separately report retention
  overwrites. Rotation continues the stream without rebaselining every view.

AppKit windows use `w…` IDs. Window `frame` uses screen coordinates; `bounds` is
`contentLayoutRect` in window coordinates. Views use `v…` IDs, bounded class names,
owning `window`, `parent`, sibling index and `flipped`. View `frame` is in superview
coordinates; `bounds` is local. These IDs are neither memory addresses nor business
identifiers. Tree metadata reconciles during discovery: a notification immediately
after reparenting can still refer to the previous tree location.

SwiftUI uses `s-<UUID>` instance IDs, literal roles, compile-time module/file/line
and nearest marked SwiftUI parent's ID. `frame` uses `.global` coordinates **within
that hosting root**; `bounds` is a zero-origin `GeometryProxy.size` rectangle.
Transforms/scroll/zoom/SwiftUI animation can change resolved geometry. Different
NSHostingViews do not necessarily share an origin or preserve every environment
scope. SwiftUI IDs are not mapped to AppKit view/window IDs. Locate components
using role/source, parent scope and geometry; convert coordinates before comparing
different hosting roots.

## Coverage and limits

Discovery walks all current `NSApplication.windows`, including exposed native
panels/sheets/popovers, from the content view's topmost ancestor (window chrome
included), after application updates. It uses weak references, enables native
frame/bounds notifications while attached, and reconciles geometry/new children
without forcing layout. Known views' notifications are observed synchronously
at delivery. `source` distinguishes native notifications/window callbacks from
`appkit.discovery`. Detached trees release metadata and restore notification flags.

Marked SwiftUI surfaces: workspace window/surface, Overview canvas and each
semantic card, Agent panel/Sidecards, Moku history and application panels
(Report/Git), shared Close target, Moku Dock viewport/capsule/interaction panel/Note/Settings seat, Settings
page, onboarding panel, shared reading placeholders/conversation reader, timeline reading column/document/each loaded
row, composer and every shared `NativeScrollView`. New surfaces can use
`.nativeLayoutLog("literal.role")`. Instrumentation adds no hit-test view, focus
target, padding, animation, content read or cache acquisition. Parallel Thread
padding, Moku focus, Close geometry/animation and loading/cache changes retain
their behavior ownership; this observes their resolved geometry.

This is **not every view or every layout callback**. SwiftUI flattens views;
unmarked leaves, TextKit glyph/line layout, WebKit DOM, Metal, layer-only geometry
and other processes' windows are not traversed. Native children created/removed
between discoveries and their pre-discovery first layout can be missed. AppKit
can coalesce notifications; components that disable notification flags lose
immediate callbacks (discovery still reconciles). Equal callbacks, undelivered
intermediate values and pure opacity changes are absent.

There is no display link, geometry-poll timer, swizzling or presentation-layer
sampling. Core Animation panel travel, masks/fades and compositor-owned Overview
motion can move pixels without changing layout; their presentation frames are
intentionally absent. Real per-frame frame/bounds or SwiftUI geometry callbacks
do produce records. A source never claims a `layout()` invocation. Use separate
animation captures for presentation motion.

## Privacy, bounds and cost

Only geometry, code-owned roles/class names/source locations, generated local
identities, time and tree coordinates enter records. No titles, prompts, bodies,
accessibility labels/values/identifiers, model paths/URLs, credentials, images,
view descriptions or reflected model data are read. Compile-time file IDs omit
absolute developer paths.

One utility queue encodes/writes batches approximately every 250 ms. Producers
append typed events with value-type CGRect snapshots under a mutex; unchanged
geometry comparisons allocate no rectangle arrays. Layout callbacks perform no
JSON encoding or disk IO. Directory/file creation also happens on the utility queue. Quit waits
for the bounded final drain; slow storage can delay it. IO failure prints one
stderr diagnostic and stops recording, without a crash/retry storm/unbounded queue.

Private session directories/files use `0700`/`0600`. Each session retains four
roughly 8 MiB segments (~32 MiB plus small header/loss/end records). Startup keeps
seven inactive sessions plus the new session; active sessions are excluded using
an OS file lease, with a separate nonblocking pruning lock for concurrent dev
generations. Normally eight sessions cost at most ~256 MiB; concurrent active
processes add their own ~32 MiB budgets. OS locks release on crashes. Pruning
runs at later startups, not periodically. The quota is per profile, not global.

Main-thread cost is O(current AppKit views) per application update, plus constant
comparison/append per notification. SwiftUI resolves geometry for each marked
surface/loaded row; scroll/resize/layout animation can produce many events.
This can noticeably affect CPU/disk/timing on large documents; use the disable
flag for uninstrumented performance baselines. Overflow trades explicit data loss
for bounded producer memory. Non-dev builds install no observer/writer/timer or
geometry modifiers; call sites perform only the disabled branch check.

## Verification: 2026-11-03 sprint

The application was built with `xcrun swift build --package-path app/macos
--configuration debug|release --product Mokusei --disable-sandbox` (each
configuration separately). The Go runtime was built with `./scripts/go.sh build
-trimpath -o /tmp/mokusei-layout-runtime ./cmd/mokusei-runtime`. Review included
the full diff, Swift concurrency diagnostics, `git diff --check` and local
documentation links. The first build exposed a Notification isolation diagnostic;
the observer now extracts only actor-isolated AppKit objects before entering the
main actor. Final build outcomes are reported with the delivered commit.

An isolated raw Debug application, with explicit profile, opt-in and its own
runtime/automation socket, mounted Overview/Moku and opened Settings, selected
General and closed Settings through production actions, then opened and closed
empty Moku history without sending tasks. Its recording contained 6,795
geometry/lifecycle events (3,375,757 bytes including header), including
`settings.page`, `moku.settings.seat`, `moku.history.panel`, `conversation.reader`,
`reading.placeholder` and `reading.close.target`, with no loss marker. The Close
target measured 32 × 32 points, separately from its outer padding. This is an
observed small-session output volume, not CPU-overhead certification. The app was stopped
with SIGTERM after observation and its isolated runtime stopped cooperatively;
that app recording has no normal `sessionEnd`.

A temporary manual executable directly compiled the production observer/writer
and modifier, with two real AppKit windows and a SwiftUI container/card. It resized
the hosting window/native container, changed bounds origin, repeated equal
geometry, reparented a native child, closed a panel and called the production
finish path. An optimized build without `DEBUG`, packaged with the dev identity,
automatically recorded 229 geometry/lifecycle events plus session/end headers
(70,225 bytes). The native container changed `[10,10,150,100]` to
`[10,10,190,120]`, then bounds origin to `[8,12]`; its equal repeat added no change.
Reparenting retained the leaf identity, and output included `sessionEnd` with
`0600` file permissions. Native notification flags initially set to false
were enabled while attached and restored to false/false when the panel closed;
already enabled hosting-view flags remained true after finish. The same optimized
manual scene with production bundle identity and `MOKUSEI_LAYOUT_LOG=1` created no recording directory. These disposable
manual scenes are not test targets and are not committed as a test suite.

No tests, CI, hooks, push, PR or system preference changes were performed, as
requested. Thread/Sidecard/Report/Git/Note content flows, actual Close clicks,
focus/IME, retained loading/cache continuity, animation pixels, full-screen/multiple
displays, rotation under sustained load, mailbox overflow, concurrent pruning,
disk-full/permission failure and force-kill recovery were not exercised. Their
implementation/compatibility was statically reviewed; this sprint does not claim
those runtime or performance scenarios passed.
