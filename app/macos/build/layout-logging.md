# Local development layout log

The `com.mokusei.native.dev` application records local layout geometry automatically,
including **Release builds packaged for the dev channel**. `DEBUG` alone does not
identify the channel. Production bundles never enable this recorder, even with
`MOKUSEI_LAYOUT_LOG=1`. Disable it for dev performance comparisons by launching
the process with `MOKUSEI_LAYOUT_LOG=0`.

A raw Debug Swift executable can opt in with `MOKUSEI_LAYOUT_LOG=1` **and an
explicit `--data-dir /absolute/profile`**. This is opt-in, **not isolation**:
the path may be the production profile or a symlink to it. The caller must choose
a separate temporary profile for demonstrations. Raw Release executables do not
opt in. The runtime exit-cleanup helper does not record. Startup configures logging
after acquiring the canonical profile lease; Reload retains the recording. Normal
Quit immediately stops collection/restores notification flags, then drains and
closes files on the writer queue. It never joins that queue on the main thread.
An independent background exit coordinator is armed before diagnostics cleanup:
it schedules a 750 ms deadline for both layout and performance drains, then exits
even if the main actor or either writer is blocked. This is an OS-scheduled
deadline, not a hard real-time wall-clock guarantee. A second Quit skips pending Settings/service/drain waits, but first arms an
independent hard deadline and prepares the Runtime helper. It takes ordinary
`exit()` so the existing atexit admission waits for actual helper launch, rather
than enqueueing a helper immediately before `_exit`. If helper launch itself,
stdio or exit handlers block past the deadline, `_exit` still bounds the wait;
Runtime cleanup is then best effort. Late runtime-cleanup completion is idempotent and
does not cut short an already requested drain. Normal exit is dispatched to the main actor to preserve AppKit/Swift
actor assumptions in exit handlers. The watchdog remains armed through
normal `exit()`/`atexit` too;
the deadline path uses `_exit` so stdio or exit handlers cannot join a stuck
writer. The existing epoch-fenced Runtime helper is prestarted when needed;
ordinary exit waits for its launch, while the deadline can cut off a launch
that has not completed. Timeout reports through unified logging (`com.mokusei.desktop`,
category `layout`), not through the stalled file or stderr pipe. Every segment
header sets `tailMayBeLostUnlessSessionEnd`; a missing final `sessionEnd` means
the tail may be lost. A blocked disk cannot be guaranteed an on-disk timeout
marker. Forced termination can also lose the buffered tail (normally about
250 ms, longer with delayed IO). This diagnostic deadline is separate from the
existing Settings/runtime cleanup gate and does not discard unsaved Settings.

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

## Reconstructing important layout paths

Start with a single session directory: IDs are session-local. Search `role` for
`workspace.window`, `agent.reading.panel`, `agent.sidecard`, `report.reading.panel`,
`moku.history.panel`, `timeline.document` or another container; retain that
component ID, then follow `parent` / `window`, `initial`, `change`, `reparent`,
visibility and removal events. `sequence` is the authoritative recording order;
wall time is useful for searching, but can change with clock corrections.

With jq, filter before sorting so the working set is only the chosen path:

```sh
log_session='/absolute/layout-pid-uuid'
jq -c --arg component 'v42' 'select(.component == $component)' "$log_session"/events-*.jsonl \
  | jq -s 'sort_by(.sequence)'
jq -c --argjson start_ms 1793699205000 --argjson end_ms 1793699210000 \
  'select(.sequence != null and .time >= $start_ms and .time <= $end_ms)' "$log_session"/events-*.jsonl \
  | jq -s 'sort_by(.sequence)'
```

Use the coordinate rules below: an AppKit view's frame moves in its parent's
space, while its bounds describes its own viewport. Compose parent/window
changes when investigating a native path. Compare a SwiftUI component's history
within its hosting root; the log does not automatically map separate hosting
roots or SwiftUI IDs into the native window tree. Cross-host coordinate conversion
and compositor-only travel cannot be fully reconstructed from these records.
Only the highest numbered retained segment determines normal session completion;
earlier segments can end at a rotation boundary without `sessionEnd`.

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

## Overview relayout transactions

New `kind: "relayout"` / `source: "overview.transaction"` events use
`role: "overview.relayout"` and a random `r-<UUID>` component for one `present`
transaction. They complement geometry events; they are not presentation samples
and are not mapped to SwiftUI/AppKit component IDs. Group by component, then sort
by sequence. No stable scene, filter, model ID, hash, title or content is recorded.

The `relayout` payload contains:

- `phase`: `began` captures the logical before state; `planned` captures the
  solver target; `completed` captures the submitted final logical state.
  `cancelled`/`failed` terminate an incomplete transaction and capture only that
  transaction's last submitted logical state. A cancelled target can already be
  published while pixels are still in flight; it is not a settled after image.
  Reuse has began/completed without a solver plan. A stopped/failed writer can
  lose any phase; a missing terminal event never implies completion.
- `cards`: `{index, column, row, columns, rows}` in the Overview world grid.
  An index identifies a card only within this transaction. A card missing from
  one side can be an entrant/exit or a truncated record. There is no cross-
  transaction identity map. Convert grid origins using pitches 376×216 points;
  pixel sizes are `columns * 376 - 16` and `rows * 216 - 16`.
- `totalCards` and `viewport`: total logical membership and `[width, height]`
  in viewport points. Each snapshot records at most 256 cards. When
  `totalCards > cards.length`, it is incomplete; never infer absent membership
  from a truncated array. Camera transforms and optical frames are not recorded.
- `strategy`: `reuse`, `immediate`, `filter`, `ordered` or `repack`. Planned
  ordered moves include `moveBatches` of numeric card indices, restricted to
  recorded target cards and the first 256 batches. `totalMoveBatches` exposes
  batch truncation. Empty entries can represent entirely omitted cards.
  These are solver-certified batches, executed only by the ordered strategy;
  filter/repack/immediate strategies do not consume them.
- Plans include `searchComplete`, `topologyValidated` and `searchSteps`.
  Incomplete search may still produce legal geometry; false topology validation
  means a quality repair was not certified. It does not certify a repaired hole.
  Optional batch certification can fall back to singleton batches independently
  of the geometry-search completion flag.

The token is scoped to its recording session: stop/restart cannot attach an old
terminal snapshot to a new recording. Existing dev-channel admission, mailbox,
rotation, permissions and data-loss reporting also apply to these events. They
only explain newly recorded transactions. Earlier geometry-only logs cannot
reliably reconstruct a user's old relayout case.

## Coverage and limits

Discovery walks all current `NSApplication.windows`, including exposed native
panels/sheets/popovers, from the content view's topmost ancestor (window chrome
included). Application/window updates only request a coalesced pass: starts are
limited to at most two per second, with no idle discovery polling timer. Each
pass yields after 128 nodes or a cooperative 2 ms budget, then resumes after
8 ms; cleanup is sliced too. A single AppKit call or a large child-array copy
cannot be preempted, so this is not a hard real-time budget. Frontier nodes and
registries hold weak view references. It enables native frame/bounds
notifications while attached and reconciles geometry/new children without
forcing layout. Known views' notifications are observed synchronously
at delivery. `source` distinguishes native notifications/window callbacks from
`appkit.discovery`. Detached trees release metadata and restore notification flags.

Marked SwiftUI surfaces: workspace window/surface, Overview canvas and each
semantic card, Agent panel/Sidecards, Moku history and application panels
(Report/Git), shared Close target, Moku Dock viewport/capsule/interaction panel/Note/Settings seat, Settings
page, onboarding panel, shared reading placeholders/conversation reader, timeline
reading column/document, composer and every shared `NativeScrollView`. Individual
timeline rows have **no global SwiftUI geometry observer**; native backing views
can still be observed after discovery. The shared Close implementation owns its
log hook; the 9a65b0f Thread/Report insets and cache ownership are retained. New surfaces can use
`.nativeLayoutLog("literal.role")`. Instrumentation adds no hit-test view, focus
target, padding, animation, content read or cache acquisition. Parallel Thread
padding, Moku focus, Close geometry/animation and loading/cache changes retain
their behavior ownership; this observes their resolved geometry.

This is **not every view or every layout callback**. SwiftUI flattens views;
unmarked leaves, TextKit glyph/line layout, WebKit DOM, Metal, layer-only geometry
and other processes' windows are not traversed. Native children created/removed
between discoveries and their pre-discovery first layout can be missed.
Coalescing and slicing increase this discovery delay: 500 ms plus queued/sliced
work under load, with no strict upper bound if the main actor is busy. A pass
is not an atomic tree snapshot; reparent/remove/reinsert between visits may be
merged, omitted or seen with temporarily stale ancestry. Only delivered changes
from already discovered views are immediate. No complete per-change coverage
is claimed, including for row layout now observed only through native backing
views and their containers. AppKit
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
JSON encoding or disk IO. Directory/file creation and final close also happen
on the utility queue. IO failure closes producer admission, cancels the writer
timer, reports once through unified logging (allowlisted domain/numeric code,
without error descriptions/userInfo/paths) and asks the main actor to remove
all AppKit observers/cancel discovery/restore flags. SwiftUI hooks keep structural
identity to avoid remounting focused controls, but become inert (no proxy/frame
reads or collection); their residual cost is a disabled check when SwiftUI
reevaluates geometry. No failed-file retry or continuing tree scan is scheduled.

Private session directories/files use `0700`/`0600`. Each session retains four
roughly 8 MiB segments (~32 MiB plus small header/loss/end records). Startup keeps
seven inactive sessions plus the new session; active sessions are excluded using
an OS file lease, with a separate nonblocking pruning lock for concurrent dev
generations. Normally eight sessions cost at most ~256 MiB; concurrent active
processes add their own ~32 MiB budgets. OS locks release on crashes. Pruning
runs at later startups, not periodically. The quota is per profile, not global.

Main-thread request cost is O(1) per application update. Discovery remains
O(current AppKit views) per pass, rate-limited and sliced as above; public AppKit
API does not expose a universal deep-child mutation notification to eliminate
this reconciliation safely. Known notifications have constant comparison/append
cost. SwiftUI resolves geometry for marked containers/cards, not every timeline
row; scroll/resize/layout animation can still produce many events.
This can noticeably affect CPU/disk/timing on large documents; use the disable
flag for uninstrumented performance baselines. Overflow trades explicit data loss
for bounded producer memory. Non-dev builds install no observer/writer/timer or
geometry modifiers; call sites perform only the disabled branch check.

## Historical verification: 359ca57

The observations below belong to the original implementation and do not certify
the corrected exit/discovery implementation. See the review evidence below.

### Original sprint observations

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

## Historical review evidence: 0d651bd (baseline 9a65b0f)

This correction is built in the detached worktree with the specified baseline.
The shared Close implementation owns the sole Close geometry hook. Thread/Report
balanced insets, cache/loading/focus behavior and both README contributions are
preserved; per-row global geometry hooks have been removed. Scope is important
windows, reading panels, Sidecards and containers, not universal leaf coverage.

[Raw manual measurements and source hashes](../../../design/dev-layout-logging-review-evidence.json)
retain the workload, individual runs, footer observations and unified-log
messages. Temporary source/interposer/output files remain under
`/private/tmp/mokusei-layout-review-pqsvafuh`. They are manual demonstrations,
not repository test targets; no tests, CI or hooks were added/run.

The optimized manual workload (`-O -D DEBUG`, macOS arm64) used 1,500 native
leaves, two marked SwiftUI surfaces, 8ms application-update requests, a 250-tick
warmup and 751 measured ticks over about six seconds. There was no concurrent
compiler during the paired measurements. `thread_info` measures main-thread CPU;
`getrusage` measures process CPU. This is not a foreground real Thread benchmark,
optical frame-rate measurement or a general latency bound.

| Six-second idle-update workload | Main CPU seconds | Process CPU seconds | update-call p95 ms |
| --- | ---: | ---: | ---: |
| Logging off, final source | 0.0354 | 0.0490 | 0.0285 |
| Logging on, final source | 0.1026 | 0.1236 | 0.1088 |
| Original 359ca57 logging on, one reference run | 0.5522 | 0.5665 | 1.0629 |

The update-call interval excludes asynchronously scheduled discovery slices;
main CPU includes them. Earlier reversed-order off/on pairs are retained to show
variability. The original reference is one run, not a counterbalanced old/new
benchmark. The observations support lower discovery cost on this workload, not
complete coverage or a promise of low overhead for all documents/animations.

Final lifecycle observations: normal completion returned to the main thread
and wrote `sessionEnd` (~3.5ms final drain in the on-idle run). Manual write
interposition returned ENOSPC after initial discovery: flags were enabled by
tick 40, collection disabled at tick 53, and flags were restored false/false
before exit. Subsequent updates continued until tick 500 without collection.
The file ended without `sessionEnd`; unified logging reported cocoa code 640.
A separate directory-creation failure also disabled collection (code 512).

Blocking the final layout footer, the real production performance footer, or a
main-actor `atexit` handler for 10 seconds each resulted in a background hard exit
at approximately 786–787ms, without waiting for the blocked operation. The layout
footer was absent only for the blocked layout writer; performance's footer was
absent for its blocked writer. With blocked `atexit`, diagnostics had already
finished, but the independent watchdog still forced exit. The deadline includes
OS scheduling/report overhead and is not hard real-time.

An initial manual `atexit` case trapped on `_dispatch_assert_queue_fail` / Swift
executor isolation when ordinary exit ran on a writer thread. Normal exit now
hops to main, while timeout bypasses exit handlers with `_exit`; the same manual
case completed under the watchdog after that fix. The failure/handling and exact
final-source hashes are retained in the evidence JSON.

Unverified: full-app Quit/unsaved-Settings/second-Quit interaction replay, actual
blocked helper launch, physical slow/full disks (faults were process-local
interposition), real loaded Thread/Sidecard/Report interactions, optical animation,
long-run rotation, mailbox overflow and concurrent pruning. Runtime helper
prelaunch/admission and late cleanup completion were reviewed statically and
compiled in the application. Final Debug and Release application builds passed
without warnings (9.90s incremental Debug, 177.89s Release); diff/JSON/local-link
review also completed. No test suite, CI, hook, push or PR ran.


## Follow-up: second-Quit Runtime helper admission

The second-Quit branch now calls the production `forceExit` boundary: arm an
independent 750ms watchdog, prepare the epoch-fenced helper, then use ordinary
exit. The existing atexit handler waits for the helper's actual Process.run
completion. Hard exit is reserved for the deadline; this is not enqueue-then-_exit.
The first Quit's Settings/service path and normal diagnostic drain are unchanged.

Debug and Release application builds passed without warnings (10.69s / 13.12s).
A temporary headless executable directly linked the production Core objects,
exit coordinator and Runtime helper; no helper preparation occurred before the
force-exit call. With a real isolated Runtime, normal and 300ms delayed
posix_spawn cases launched the helper and stopped the Runtime. The final delayed
case observed spawn success before parent exit (~395ms from force entry,
including observation overhead). A 1MiB stderr write into an unread pipe blocked
a real exit logger at 64KiB: the watchdog ended the parent after ~823ms from force
entry, while the helper launched and the Runtime stopped successfully.

When posix_spawn itself was blocked for 10s, the deadline ended the parent before
spawn could return. Runtime cleanup cannot be guaranteed in that hard-failure
case; its isolated Runtime was then stopped manually. This is the unavoidable
bounded-exit limit, rather than skipping helper launch on every early second Quit.
Raw summaries, spawn/child markers, source hashes and unified logs are retained
at `/private/tmp/mokusei-second-quit-z8z92_kr`.

Not exercised: complete SwiftUI repeated-Quit/unsaved-Settings interactions,
physical slow disks or a replacement-epoch race. The existing epoch fence was
not changed. No tests, CI, hooks, push, PR or system preference changes ran.
