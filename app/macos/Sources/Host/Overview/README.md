# Overview

[NativeOverviewWorkspaceModel](NativeOverviewWorkspaceModel.swift) projects public catalog records into visible cards, tags and selection. [NativeOverviewCanvas](NativeOverviewCanvas.swift) owns structural geometry; the registered plugin supplies each card's semantic content. All placements in the selected layout remain mounted, including outgoing cards through exit. Camera movement alone does not mount/unmount cards or start structural transitions.

[Membership facts](NativeOverviewMembership.swift) separate filter membership from
streaming card content. Admitted catalog deltas carry changed identities into the
workspace; content-only changes compare those identities' facts and refresh only
selected changed card slots, without scanning or sorting the selection.
Activity-only mutations do no catalog/card work. Full snapshots, explicit refresh,
locale changes and reordered surviving records retain full reconciliation.
Same-patch removal and upsert of an existing identity, including renderer recovery
at the same revision, retains its slot and follows the changed-record path. Only
real creation/deletion or an explicit relative reorder marks structure dirty;
membership facts still invalidate affected scopes when the replacement changes them.

The [membership index](NativeOverviewMembershipIndex.swift) retains identities and
selection results per canonical scope. Execution, visibility, archive, tag and
scope changes reselect only affected old/new scopes. Unscoped applications have
reverse label dependencies so their matching directories and Inbox semantic
filters remain current. Coverage uses exact execution sets rather than checking
every selected application for each task. Stable per-scope order comes from the
admitted catalog positions; changing one scope cannot reorder equal-date records
in another. Cached inputs, membership facts, directory labels and results are
bounded by current catalog identities and exposed filters and are released on stop.

Global conversation availability is updated from changed eligible records before
tag filtering and report coverage, including directory-only documents. Moku
uses these facts for its empty-workspace landing; an unloaded catalog remains
unknown. The All membership is invalidated lazily and resolved when browsing or
tag activity needs it. Filter chrome and Moku still receive the complete filter
description
when membership changes, so producing that public output scales with the output
size; unrelated scope selections and card projections are reused. Selecting a
filter or changing card geometry retains the ordinary complete selected-layout
transaction.

While the first creation awaits native admission, the canvas and filters stay
covered by landing so a durable, unadmitted shell cannot replace the primary
input. Ordinary eligibility rules, including archive and terminal visibility,
are shared with Overview rather than reimplemented by the Dock. Each scope selection
normalizes its distinct labels once. The
[CPU benchmark and scenario matrix](../../../../../tools/verification/overview-performance/README.md)
distinguishes model work from GUI and GPU work.

Ordinary Overview cards, including Agent Threads and individual Reports, use
opaque palette surfaces and a soft border, including completed cards.
Super Thread collections provide one continuous regular Liquid Glass plate
behind their cover, metadata and intervening layout space. Their policy's
`providesCardSurface` omits the Canvas's opaque shell; glass remains in the
semantic camera plane so pan/zoom update its backdrop geometry. Collection
emoji badges opt into regular glass with a light mint tint at the unchanged
44pt diameter / top 12pt / trailing 17pt metadata seat. Reduce Transparency
uses opaque palette fills; the material helper falls back to system Material
when Liquid Glass is unavailable. Other card content keeps the shared flat
policy for provider badges, terminal marks and plan highlights.
Agent Thread emoji badges ordinarily use static opaque palette fills
without an added border: adaptive accent-soft green when completed, neutral
surface-strong otherwise. This also applies under Reduce Transparency. Removing
per-card Liquid Glass on ordinary cards avoids its spatial update cost during canvas movement.
The terminal symbol and accessible status label remain independent of color.
The isolated `--benchmark-agent-emoji-badge liquid-glass` scenario can compare only
Agent emoji backdrops with regular glass; ordinary launch defaults and all other
card materials remain unchanged. See the [external comparison](../../../../../tools/benchmarks/README.md#agent-emoji-badge-material-comparison).
Only Super Thread collections opt into the new card material; individual Report
and ordinary Thread surfaces stay flat.
There is no `glass world` preference. Chrome, directory menus, Moku,
Settings and shared controls outside a card keep their own materials. Cloud,
scan and spatial-animation ownership are unchanged.

Overview cannot originate steer/send input for a specified Thread. Emoji badges
retain their status presentation. For an unarchived ordinary Thread whose latest
execution was explicitly interrupted by user Stop, with no pending input or
background work, the badge becomes an independent Archive conversation button.
Hovering the card or focusing that button replaces the emoji with a close icon;
Return/Space and accessibility activation archive without opening the reader.
The Host rechecks current catalog eligibility, blocks duplicate requests and
displays failures on the card. Other interruption sources, including unknown
historical provenance, do not acquire this action. Badges have no Send swap or
draft callback. The Harness overview renderer receives only an existing-interaction
response callback plus ordinary reading navigation, rather than full thread
actions. Permission/question responses remain available; those are bound to a
current pending interaction. There is no per-card message editor, text/file drop
target or send shortcut. Canvas drag/scroll/pinch, Return-to-open and
card activation keep their navigation behavior. The independent Moku composer,
Thread-detail Moku input, Browser annotation sends and general Runtime APIs
remain owned by their existing boundaries. Moku tool operations do not decorate
card borders; returning from a reader must not replay an operation-completion
edge flash. The workspace-level running list-refresh indicator remains separate.

## Card update isolation

[NativeOverviewContentStore](NativeOverviewContentStore.swift) separates the
latest semantic snapshots from the canvas's structural inputs. The workspace
installs it synchronously at each admitted catalog transaction; the canvas reads
only its structural revision and retains a stable slot for each mounted
structural identity. A content-only change updates that card's slot directly,
without rebuilding the canvas body, its two placement loops or a second
`items`-to-`rendered` state copy. The production delta path updates only changed card slots and attention identities;
structural changes retain the full selected-layout transaction. Array-based
fixture hosts feed the same store and layout state machine.

Each card retains separate Equatable shell and semantic boundaries outside its
spatial frame. The shell keeps a neutral palette surface;
the semantic wrapper observes its current item, including completion. Geometry, motion,
visibility, viewport, locale, decorative policy, activation and explicit
renderer/state identities still invalidate the appropriate wrappers. Completion
changes reach the badge through the semantic wrapper's observed item.

Slots are keyed by structural identity, including footprint and internal
structure, rather than thread ID alone. Leaving the current collection or
changing footprint freezes the old mounted slot at its last compatible content.
The model retains those slots' current presentation IDs alongside the latest
structural snapshot until exit finishes. Newer content can adopt an existing
slot only for the same structural identity; a different incarnation starts its
own slot. Source replacement retires the old ownership.

Presented placements have an identity index rebuilt only with a new layout. Each pan/zoom input checks the current attention identities against that index,
so finished and unrelated placements do not participate. The empty attention set
returns immediately.

Offscreen attention changes notify the mounted coordinator without routing
ordinary text updates through canvas attachment or moving the camera. Structural,
scene and viewport changes refresh the camera callback, so its saved memory
always belongs to the active scene. The workspace's empty-state and Dock
reservation read separate presence facts, not the high-frequency item array or
complete Moku thread.

The card closure captures stable owners. Callers replacing its renderer must
update `cardContentIdentity`; the workspace supplies its model identity, and the
identity reaches the innermost Equatable content boundary. Callbacks use a stable
workspace-owned reference whose current receivers are refreshed when the
workspace view is rebuilt, so mounted actions reach the latest receiver without
remounting.

The body counter is an observation-boundary diagnostic, not a CPU/FPS
measurement.

The production card closure alone enables `threadCardNativeDecorationsEnabled`.
Clouds use an independently sampled native Metal view with the existing seeded field;
derived scans use a compositor-owned gradient animation. Neither decoration
publishes a SwiftUI frame value. Card semantics, duration, spatial wrappers and
surfaces remain with their existing owners. The native views fill the supplied
bounds, preserve pause/visibility behavior, and cannot own input or accessibility.
See the shared [native decoration contract](../../Shared/PluginUI/README.md#native-overview-decorations)
for color, lifetime and native-composition acceptance. Standalone card fixtures
default to the shared renderer, so Overview performance verification must mount
this production workspace path and confirm that its native renderer is active.

## Accessibility gesture ownership

The canvas groups its accessibility children **before** installing its pinch
recognizer. Each Agent card likewise creates a named container before attaching
its open gesture and action. Its title, preview, status and embedded interaction
controls remain readable and independently actionable inside that container.
Do not move these groups outside the gesture modifiers: SwiftUI otherwise derives
gesture attachments for every descendant when navigation or Moku input changes
visibility/enablement, blocking transition startup even for the retained backdrop.
See the [target-Mac contract](../../../../../design/reading.md)
for reading admission and source ownership.

## Layout, motion and input

The FitAll contract and verification limits are described in
[the layout refactor note](../../../../../design/overview.md).

Presentation pauses (including the expanded Moku composer) gate canvas hit
testing and accessibility without disabling the card control tree. Native
Button labels, including Report cards and Git summaries, therefore keep their
ordinary colors alongside gesture-based Agent cards. Camera pause, activation
guards and Moku outside-click dismissal retain their existing owners; transient
composer growth does not change the layout viewport. See the
[current contract](../../../../../design/composer.md)
for the implemented camera contract.

The 1x grid cell is 414pt wide and 253pt high, a 15% increase in each logical
dimension from 360×220pt, with the same 16pt gap. Two-row cards are therefore
522pt high; two-column cards are 844pt wide. Footprints retain their column/row
semantics, including Agent Threads, individual Reports and Super Thread collections.
Packing, rendered card bounds, transitions and attention visibility all use
the shared grid pitch, as do camera bounds and hit regions. Text/icon metrics
remain unchanged. Manual and automatic camera framing keep at least 1×, so large
layouts overflow the viewport and remain reachable by pan.

[NativeOverviewLayout](NativeOverviewLayout.swift) is a pure function. Its inputs are the latest members in product order, the usable viewport and an explicit geometry policy; its output is placements, bounds and the automatic camera. Previous placements, old cameras, animation progress, pauses and revision history are not inputs.

The solver evaluates a bounded, deterministic candidate set: a uniform grid for every column count `1...N` using the largest measured span as its cell, horizontal and vertical shelf packs, and horizontal product-order shelf packs. Candidates are ranked by unclamped FitAll scale, then world area, width and a stable enumeration ordinal. The uniform-grid pass also supplies the independent quality floor: for any input, the selected arrangement can never fit worse than the best regular grid built from the largest card. Shelf target ranges use the packing axis: columns for horizontal shelves and rows for vertical shelves. Enumeration samples at most 65 targets, including both endpoints, with a step of `ceil((count - 1) / 64)` for larger ranges. The grid pass is `O(N²)` in the visible card count; each shelf pass is `O(65N)` after sorting, with `O(N)` memory. Every valid nonempty input still returns legal geometry when quality enumeration is truncated.

Card sizes remain their measured spans. A card may compose up to
`HarnessOverviewCapacity.maximumColumns` (three) grid columns; that is a card
capability, not an Overview viewport column count or a layout mode. A 3×2 card
is centered by the same solver at 1× even in the minimum window. Gaps are world-space; screen gaps are `scale × gap`. The solver never clips, stretches or equalizes cards. Empty input returns empty bounds and no camera; a zero/negative usable viewport returns legal positions without a camera; malformed spans, duplicate IDs and invalid limits throw a typed input error. A later valid input always plans normally.

Same-scene structural slot changes with identical members and viewport reuse geometry. Reuse still cancels any obsolete worker waiting for the spatial stage, so an A→B→A membership or viewport update cannot later publish B over A. Content-only updates do not enqueue layout. A viewport size change re-evaluates candidates because aspect can change the chosen arrangement. `layoutSolveCount` and `geometryReuseCount` expose these paths.

The usable viewport uses the persistent tag bar's actual `OverviewTagMetrics`
clearance; the canvas and fixtures share `NativeOverviewViewportDefaults.toolbarBottom`.
Automatic framing uses the FitAll arrangement with a 1× floor. For `B` = the union of the latest world card frames and `V` = the usable viewport (window minus persistent controls and product margins): `fitScale = min(V.width / B.width, V.height / B.height)`, `scale = max(1, min(explicitScaleCap, fitScale))` and `translation = V.center - scale × B.center`. The 1× floor and explicit 1× cap are shared by automatic framing and manual zoom. Large collections stay centered at their logical size rather than shrinking to show every card; unrestricted pan reaches every member. Without a cap the fit scale still respects the 1× floor. Window zoom independently ranges from 1× to 5×, so the combined rendered card scale never falls below 1×. Manual and automatic camera bookmarks are normalized around the usable viewport center before restoration or animation; profile window zoom is normalized and rewritten at its existing JSON load entry. Manual pan/zoom is user-owned and is never replaced by background layout work. Returning to automatic mode always converges to the latest complete snapshot, including after pause, hiding or a failed/zero-viewport update. An empty collection disposes the camera.

Geometry targets are latest-wins. Each new structural snapshot cancels the in-flight presentation, samples the current card poses and starts a new transition to the latest target; no FIFO of historical revisions is queued. A successful solve publishes placements, bounds and camera from the same input snapshot. An older task cannot publish after a newer token, cannot clear `isLayingOut` for a newer owner and cannot consume a newer revision. Content updates do not restart admitted work. Pausing settles the displayed sample and retains the latest pending target; hiding defers only the camera target. Resuming plans from the latest content rather than replaying omitted revisions.

Camera ownership has one mutable source. Live bookmarks combine the sampled
transform with the current manual/automatic mode; animation samples cannot
restore an earlier manual mode after an explicit return to automatic framing.
The same ownership is published when the automatic target already matches the
current transform and no animation is needed.

[NativeOverviewCardMotion](NativeOverviewCardMotion.swift) samples each mounted card's current pose. An interrupted transition retargets from that sample. Outgoing content remains mounted until its exit completes; entries, moves and exits share one bounded transition and then release retiring snapshots. Shell and semantic planes share geometry and opacity. Retired and transparent semantic cards are hidden from accessibility.

Tag scene changes retain their filter choreography: outgoing cards shrink
and fade over 140ms, survivors move over 320ms after a 70ms delay, and new cards
enter over 230ms after a 150ms delay. The new collection first lays out at frozen
start poses; only that layout's acknowledgement starts the shared clock, so plugin
construction cannot consume the transition. Automatic framing is prepared at its
final transform before that layout; the card clock owns screen-space travel
rather than starting a second camera clock during mounting. Camera cuts reproject
sampled old poses to preserve their
screen positions. Visible survivors retain manual framing. Rapid selections
cancel the old owner and retarget those samples. An empty destination retains the
camera through the exit before disposing it; switching from an empty scene still
animates entry.

Card motion starts, interruption samples and display samples all use
`ProcessInfo.systemUptime`. A MainActor clock shares one uptime sample for each
exact SwiftUI timeline date across the shell and semantic planes. Dates are only
tick identifiers, so wall-clock drift or adjustments cannot accumulate into the
motion's elapsed time. The clock retains the 64 most recent distinct ticks.

The spatial frame builds its content when receiving new inputs and reuses that
view value across animation ticks. Ticks only sample the pose and apply its
geometry, opacity and accessibility state; they do not rerun the shell/semantic
content builder. New card inputs still replace the value without changing its
mounted identity, and child state, Observation and environment updates remain
live.

[NativeOverviewStageCoordinator](NativeOverviewStageCoordinator.swift) serializes card spatial motion with Moku. Camera geometry is latest-wins and does not wait in that card queue. Explicit return to automatic framing restores the latest collection fit. Temporary interaction/visibility pauses defer that reset; fresh manual input cancels it. First nonempty layout prepares its camera before revealing cards.

Camera memory is a runtime bookmark (scene, transform and manual ownership),
with no persisted mode selector. Existing preferences and user data need no
migration or cleanup.

The workspace supplies the Dock reservation from the same idle capsule geometry
used by the renderer (44pt height plus its viewport-dependent bottom seat). Transient composer/note expansion stays an interaction overlay and does not
repack the scene. The reservation consumes the existing vertical padding budget;
the remaining preferred space is split equally above and below the collection. This keeps ordinary wide-window packing while balancing the gaps to controls.

[NativeOverviewScrollInput](NativeOverviewScrollInput.swift) coordinates pan/zoom with native controls. Window header dragging and Moku controls are excluded from canvas navigation. A click that dismisses Moku input cannot also reset the camera. Real interaction pauses automatic camera motion; hover/restored focus alone does not imply editing.

The canvas combines SwiftUI's focused-card scope with the window's actual editable text responder before pausing for input. Closing a covering surface can restore keyboard focus to a whole card; that focus keeps keyboard activation without holding the text-editing pause. Window-scoped native responder notifications also release editing protection when a field loses focus or unmounts, without changing camera state from automation.

Overview cards, canvas background and directory chips expose no context menus. Background clicks still restore automatic framing; drag, scroll and pinch keep their existing camera behavior. Directory children remain available through hover and accessibility actions. Reading, composer and other scene menus are owned separately.

Geometry reuse applies when the current membership and viewport are unchanged; a structural slot refresh then updates content without invoking the solver. Recovery from an interrupted entry, resize or exit samples the current poses and starts the latest presentation, so transparent entrants and retired snapshots are released. No reading-position edge seat is retained.

## Tags and filter transitions

[NativeOverviewChrome](NativeOverviewChrome.swift) owns the tag and action controls. Semantic tag identity remains a plain name with separately validated emoji. Each scope exposes up to five semantic tags, including singly assigned tags and separate names with equal membership. Directory filters use persistent scope identity for membership and exclude managed temporary roots. Labels are presentation only: a symlink alias or linked checkout with another label remains in its canonical directory’s All view, and same-named directories stay separate.

The tag bar omits a directory's sole semantic child when its actual selected
Agent Thread ID set and application thread reference set both equal the
directory's sets. This uses eligible catalog membership after the ordinary
visibility/archive and report-coverage rules; equal member counts
alone are insufficient. Untagged members or directory-only documents that change
those sets keep the child visible. Multiple semantic names (including a name
equal to the directory label) prevent this omission. Inbox tags are unaffected.
Catalog membership changes recompute the decision. Canonical filters, navigation,
published context and stored tags remain intact. An already selected semantic
child stays visible and selected even if it becomes redundant, preserving its
filtering meaning when later threads arrive; selecting its directory then omits
the redundant child.

Filter capsules omit visible member counts, including in directory menus; counts remain available as accessibility values. Filter tags do not show hover tips; their accessibility labels, values and actions remain available. Selected tags use background-adaptive capsule fill and contrasting text. Directory menus use native glass composition and independent hover/hit regions. Selecting a child closes the menu; the directory chip keeps its current title until the glass exit transaction is removed, then shows the directory and child name separated by a short vertical divider. The selected child’s emoji replaces the folder prefix, without repeating it in the child name; a child without an emoji keeps the folder. The divider is absent without a selected child. Reopening invalidates an older close completion; the latest selection supplies the eventual title. There is no separate hierarchy caption above the bar. Archived records are excluded from Overview. Settings has no archive-restoration section; archive data and Runtime commands remain independent of that page. For tag-bar transitions, see the [shared UI motion boundaries](../../Shared/PluginUI/README.md#motion-and-materials).

Menu opening uses a 220ms smooth spring with zero extra bounce, both after initial measurement and when retargeting a mounted menu. Closing retains its existing timing. Menu closure morphs each mounted child capsule back into the measured parent capsule over 320ms. Position and size interpolate continuously; labels retire earlier than the glass, and the surface only disappears as it overlaps the parent. Reopening retargets the same mounted identities from their current presentation. Removed children remain in their old row slots during the return, then surviving children reflow smoothly. A removed directory fades its whole menu envelope because its return destination no longer exists. Retiring controls cannot receive clicks or accessibility actions. After menu exit, title, divider and prefix changes use a 280ms smooth, non-bouncing transition. Reopening still invalidates the earlier close completion. The measured scroll width carries its resize transaction across the layout boundary so the centered bar follows the chips. Initial measurements are immediate.

The child menu's clip contains both its viewport and the visible parent in viewport coordinates. A single short child can therefore expand from, and return to, a wider selected-directory capsule without cutting off its rounded ends. Scroll offset affects the morph's content-space target but not that clip. Overflowing rows retain horizontal clipping because their viewport already contains the parent.

Child-menu motion samples one retained progress for label scale/opacity and the
surface's actual frame/offset. Natural child widths still own row measurement.
Only the label scales; the material fill and clear glass receive the same
interpolated frame without another geometry animation. Applying a GeometryEffect
to captured glass lets its compositor geometry drift from the view-layer material,
creating offset capsule rims during opening and closing. Stable child glass IDs,
selection tint, viewport clipping and interrupted-return ownership are retained.

The directory's own glass capsule uses its current animated frame plus only the leading/trailing overflow outside the scroll viewport. Using an absolute measured source width here can slice off its right rounded end while switching from a selected child to another top-level tag.

Its source-surface leaf samples size and offscreen overflow together before
passing the actual frame to material and clear glass. The glass compositor must
not interpolate that geometry again: a retained old width can overlap the next
chip after its material and the row have already shrunk. Only this source leaf
clears the geometry animation; the directory group's position, child-menu target
and independent opening/closing progress keep their existing ownership.

Tag widths have no fixed point cap. Each top-level chip may use the scroll viewport left after All and bar insets; sibling chips remain horizontally scrollable. The centered bar reserves the actual action envelope plus 16pt clearance on both sides; at 620pt and narrower the actions occupy a separate row. Child chips may use the full available bar width, and overflowing child rows scroll within that width. Their glass container stays inside the scroll viewport so captured labels cannot bypass clipping. Chips use shadowless `.clear` glass over a view-layer material fill rather than `.regular` glass: the regular variant's system-drawn shadow is composited outside the SwiftUI layer, so neither a per-chip `clipShape` nor the bar's capsule clip can trim it, and the 4pt gaps let neighboring shadows overlap into a visible band. The material fill supplies the frosted face and follows the pill shape, while selection tint and interactive feedback remain on the glass. Selected All, directory and semantic chips use the overview accent with 22% tint alpha, or 34% with Increased Contrast; unselected chips have no tint. Selected directory chips replace their folder or child emoji prefix with a check icon. Selected semantic chips replace their emoji prefix with the same check, including in child menus; All remains prefix-free. Accessibility labels retain the original tag names and emoji. Label font weights remain unchanged; the shared selected check uses a 2-unit Lucide stroke instead of the default 1.5-unit stroke. Names only truncate when their individual viewport cannot hold them. Presentation does not change tag identity or membership.

All, directory and semantic capsules (including child menus) retain the 1.1× enlarged label and prefix metrics. Their height shares `NativeWindowNavigationGeometry.height` (42pt) with the traffic-light capsule and right-side circular actions. Measured frames, hit areas and canvas clearance follow that shared height. Semantic labels always lay out the emoji separately from the plain title, in both selection states. The shared prefix retains both its unselected glyph and centered check as opacity-switched layout participants, reserving the same natural width and height across selection changes. This stability applies to a fixed title/child; choosing a different directory child can still change the title width. The shared prefix keeps its native ideal size: an emoji's advance and line bounds can exceed its point size, so an icon-sized square can cut its glyph even inside a roomy chip. The Lucide folder and selected check use the same icon size; emoji do not use per-glyph offsets.

## Tag activity

Directory and semantic tag chips append an 11pt native status ring only when
their existing browsing membership contains a Thread whose public
`isExecutionActive` is true (running or waiting for user). Inactive tags omit both
the ring and its adjacent HStack spacing. Active tags retain the ring's measured
width while menu transitions temporarily hide it, keeping their source
geometry consistent. Background work alone does not redefine active. Selection tint, task counts,
membership, ordering and Runtime filter context remain independent.
Archive/visibility and Report-coverage exclusions come from the
same membership used to browse each tag; a Report does not itself become an active
Agent Thread. A changed-ID activity cache refreshes these booleans when active
participation changes, without rebuilding membership or reacting to every streamed
payload. Membership changes also refresh the markers, including the existing lazy
All membership for its accessibility value. The All chip has no visible activity
ring. Submenus share the other tags' indicator. Native window
visibility remains owned by the production spinner. Tooltips and
accessibility values announce active presence in the selected UI language. The
shared slot is implemented in [NativeOverviewTagActivity](NativeOverviewTagActivity.swift).

## Verification boundary

The [property boundaries](#property-boundaries) describe the generated geometry
and mounted convergence checks. Geometry containment applies only when the raw
fit permits the 1× floor. Mounted state reads rendered frame identities and
camera projection; it does not certify control-region geometry, Report content,
reading transitions, physical gestures or captured appearance.

## Production interaction controls

[NativeOverviewInteraction](../Interaction/NativeOverviewInteraction.swift) exposes the camera's production methods and registers callbacks owned by the mounted directory controls. Opening a menu calls the same `revealChildren` path as hover/accessibility; selecting a child requires its real glass menu to be mounted, then follows the production selection/exit transaction before the chip title changes. Explicit close uses the accessibility close callback; pointer exit retains its delayed dismissal. Filter-bar scrolling uses the mounted SwiftUI scroll view. A retiring registration cannot remove another view's callbacks.

Runtime `state:load` supplies scope/membership facts independently of mounted card
identities, placement cells and camera bounds. Overview exposes no tag CRUD or
multi-selection controls. The PBT target does not exercise the interaction driver.

The generated geometry and mounted-state input domains, assertions and runnable
commands are defined in [Property boundaries](#property-boundaries).

The [performance tools](../../../../../tools/verification/overview-performance/README.md)
measure internal CPU paths; the [external benchmark](../../../../../tools/benchmarks/README.md)
observes fixed-count app rendering with explicit measurement limits.

## Agent reading panels

Reading entry shares the 420ms emphasized panel curve with tag-chrome withdrawal
and the resident Dock. Tag clearance remains fixed while the retained controls
move upward. See the [reading choreography](../../../../../design/reading.md)
for secondary Sidecard admission and cancellation.

The presentation gate and prepared return apply to Agent and Report panels.
Report returns to its document card.
All sample their destination only after the refreshed canvas preparation completes.

The outer reading stack pauses Overview projection when opening begins. Cards
fade completely out during travel. Once the panel settles, it hides the separate
native host and reuses the window's existing ultra-thin material as the background;
it never rasterizes Overview or retains even blurred cards. Input, tracking and native layout
therefore do not need to traverse the retained cards for foreground reading.
Catalog installation, membership/filter context, selection validity and Moku
operation state continue at each runtime transaction. Hidden transactions coalesce
the display's sorting, plugin projections and content installs;
the mounted canvas also defers layout (including viewport changes). Existing card
snapshots, native controls, drafts and camera remain retained. Settings, Git
monitoring, runtime, notifications keep their existing lifecycles.

Before an animated return, the stack unhides the same host at the latest viewport,
resumes projection and awaits a new canvas
preparation receipt before sampling the current source frame. Removed/archived
cards cannot supply that destination. Preparation is cancelled with its route;
replacement, focus loss, disconnect/recovery and direct returns cannot let an old
waiter close a newer visit. A reversal during opening uses the participating parent
immediately. Hidden and foreground structural changes both resolve to the latest
snapshot; omitted intermediate geometry is not replayed. These reading-panel
lifecycle paths are outside the generated Overview property domain.

Opening an Agent Thread captures its displayed card frame from the stable layout
and live camera transform. The shared reading stack expands that shell into an
opaque panel with equal horizontal margins, while retaining the Overview camera
and cards beneath it. The retained Filters and Settings chrome slides upward by
its full height and fades out over 200ms without scaling its labels or changing
canvas clearance, including in the narrow two-row layout. Closing reverses the
same transition; interrupted openings retarget the mounted chrome. Hidden chrome
remains excluded from hit testing and accessibility.
The production conversation content fades in unchanged; title, emoji and author
have no separate morph. Closing refreshes the source position after viewport
changes when available. Direct/restored entries without an eligible card use a
small centered expansion instead. Route identity and cancellation
remain owned by the shared reading stack.

Reports expand from their own card. The shell uses that identity to refresh
the return frame after layout changes. Git summaries remain read-only card metadata.

Agent card title/emoji leaves register weak native anchors with the workspace's
identity registry. Only an actual ordinary open captures text and geometry;
this adds no projection cache or per-frame catalog publication. The destination
reader owns the independent opening handoff, and return still uses the refreshed
canvas frame and actual card content.

Ordinary failed executions remain hidden by default. Interrupted executions are
hidden only when their exact latest execution ID matches the Runtime-owned
`mokuInterruptedExecutionId`. User Stop and missing/unknown historical sources
remain visible. A successor execution stops matching the old provenance. The
shared Shell predicate governs Overview, availability and ordinary
navigation; membership invalidates when its resulting visibility changes, even
if status and execution identity stay unchanged. Archive/unarchive choices,
plugin-owned application visibility and explicit result-reading links keep
their existing rules. Refresh and restart consume the retained envelope rather
than guessing from terminal status or local UI actions.

Ordinary browsing ignores retired agent-authored visibility markers. Archive, execution eligibility and Report coverage retain their own selection rules. Detail reading sends no per-thread visit or foreground-time receipts to Runtime; application collection reading remains independently owned by the desktop.

## Viewed application collections

Application plugins can opt into `ApplicationOverviewCollectionPolicy`; Super
Thread opts in with a 300-second last-close interval and a 1×2 footprint. After
normal scope/tag filtering and report coverage, two or more eligible reports
become one view-only card. At exactly 300 seconds a report remains individual;
reports without close evidence and future-dated closes are ineligible. All is its own view. Canonical filters/counts and
report execution coverage still describe underlying documents.

The collection has a reserved canvas identity per type/filter, never a Runtime
record. Its snapshot retains the exact member projections. Content changes to a
collected member refresh the selected projection (including that collection);
unrelated deltas keep the ordinary incremental path. Selection changes within
the card do not create layout revisions. Only the nearest eligibility deadline
owns a cancellable timer; read-hidden or inactive canvas presentation cancels it and
return recomputes eligibility and rearms the deadline. No one-second catalog poll.

Admitted detail navigation is validated against `NativeWorkspaceCatalog`, even
before the first Overview projection. Each actual route departure (Close, Back,
replacement or orderly release) records a wall-clock close time. Opening clears
the previous close deadline, so time spent reading cannot age into a collection.
Every new close restarts the strict five-minute interval unless a short visit
retains eligibility that was already established at opening.

Reading an associated ordinary Thread uses the same Super Thread reading owner,
whether opened in the Report sidecard, through an execution link or
as a restored Agent route. Ownership comes from the full catalog's declared
execution coverage, independently of filters, collection membership and archive
visibility. It matches Thread identity even when reading a newer/current or older
execution than the report cites. Ordinary execution updates never edit the report
or reset its reading evidence. Unassociated Threads have no collection owner.

Moving between a Report and its associated Threads (or between its associated
Threads) continues one visit; loading/admission pauses its foreground clock.
Closing the route or moving to another owner records the close. Covers, previews,
carousel rotation and data prefetch do not open visits. Catalog binding changes
reconcile the active route: departure from the old owner closes that visit, and
the new owner starts a fresh visit with no transferred dwell. Unlinking leaves no
owner. A newly generated report can become the current associated reading owner,
but gains no eligibility until an actual departure and the normal close interval.
The reverse ownership index updates with application deltas, without a full scan
for ordinary execution/status events. Ambiguous ownership earns no read credit.

A document eligible at opening retains that eligibility through a short visit,
independently of tag projection or whether a second candidate is present.
Only **more than 120 seconds** of cumulative foreground reading in that visit
clears it. Exactly 120 seconds retains it. Focus loss, covering by Moku/Settings,
missing reader admission, inactive window and disconnection pause reading time;
resuming the same route accumulates time using monotonic uptime. Reopening the
same admitted route does not reset dwell. Actual close then reopen starts a new
visit, so separate short visits do not add up to a long read. One cancellable
deadline clears retained eligibility during uninterrupted reading. After a long
read, closing starts a fresh five-minute wait. Cover rotation is never a visit.

`desktop-preferences.json` stores profile-local `applicationCollectionReading`
entries (`lastClosedAt` in Unix seconds and `retainsEligibility`). Open writes a
marker without a close timestamp; a crash cannot invent a close. A retained
eligibility marker survives restart, but foreground duration does not. Orderly
release records its actual close. Ordinary preference writes preserve both the
new state and historical `applicationLastOpened`; the latter supplies **no close
evidence**. Old profiles therefore start unknown until a real open/close, without
inferring anything from creation, update or execution times. Invalid new reading
state reports a preferences read error. Failed writes report errors and preserve
session evidence without claiming disk recovery. These facts are local to the
client, not cross-device state; collection membership and selection remain
unpersisted view projections.

The Report plugin supplies a stable content fingerprint covering title, document
and cover revisions, emoji, introduction and the set of exact execution bindings.
A changed fingerprint clears both the old close and retained eligibility, so an
updated member appears individually until another actual visit closes and the
normal five-minute interval elapses. Updates during a short visit also revoke
retention; closing that visit starts a new interval. Tags, archive state, catalog
timestamps/revisions, source execution status and reference reordering do not
change this fingerprint. Runtime no-op writes retain document/cover revisions.

The fingerprint is saved as optional `contentRevision` in the same reading entry.
Both full snapshots/reconnects and incremental catalog changes compare it before
projection, including hidden presentation and other browsing filters. Unknown
fingerprints establish a baseline without claiming an update; initial generation
never counts as a revision of previously read content. Existing reading entries
without a fingerprint cannot detect edits predating that first baseline. Unvisited
documents acquire their first reading entry only when opened. Failed persistence
keeps the same session-only fallback as close evidence. Content invalidation does
not alter canonical counts, report coverage, creation ordering or other members;
a collection with one survivor dissolves under the existing minimum-two rule.

Opening captures the collection's displayed geometry and keeps its backdrop
through travel. Prepared return samples the refreshed collection for a short
visit, or the member's individual card after a long visit. One remaining
candidate dissolves the collection. Semantic interaction targets include every
real member, never the synthetic ID; snapshots expose membership and selection.

The Report plugin owns `NativeReportCollection`: a cover preserving its 360:308
logical viewport ratio slides horizontally while the remaining metadata region
stays in place and switches through the shared
`ThreadCardInkMask`. Cover and ink use one 460ms ease-in-out progress; backward
paging mirrors only the mask so the reveal follows cover travel. Outgoing ink
stays above incoming ink. At the current 414×522pt grid footprint, the cover is
354.2pt high and metadata is 163.8pt high. WebKit and its poster share a centered, uniformly scaled
360×308 CSS-pixel viewport, including for existing fixed-width HTML.
The 4pt layout spacing and card shell stay fixed;
the spacing is filled by the same glass plate as the body, without an exposed
background seam or a separate body glass edge. It reuses `NativeReportCover` and `NativeReportCard`
with `showsCover: false`, rather than duplicating metadata. Coverless reports use
their emoji on the ordinary surface. Arrow/dot/menu controls use native Liquid
Glass; the collection owns its regular-glass outer plate while the Canvas
retains geometry, clipping and hit testing. During page travel,
metadata gates pointer/accessibility/actions without disabling its visual label.
Open and archive callbacks recheck the current collection pose, including an
already-open context menu; accepted archive work may finish across page changes.
Carousel buttons and menu remain natively disabled, with the disabled boundary
inside the surrounding glass surface rather than around it; this preserves
keyboard/accessibility safety without restyling the material. Their ButtonStyle
keeps the ink appearance stable during the temporary lock.
The page menu uses the button menu style to inherit that same ButtonStyle;
the native borderless menu style would dim the x/x label during every turn.
The count and navigation glass inherit the workspace color scheme; selected
page markers use primary ink and unselected markers use secondary ink, retaining
the capsule/dot shape distinction in both light and dark appearances.
The entire lower navigation capsule mounts only while the pointer hovers this
active, visible collection. A transparent SwiftUI mask cannot reliably suppress
the native Liquid Glass surface; removing the surface also removes its invisible
hit targets and accessibility children. The upper-right count stays available
for keyboard/accessibility member navigation. Opening/closing the member panel,
focus loss, leaving the card and offscreen removal clear hover; keyboard focus
and menu tracking never force the capsule visible. Carousel timing remains
independent of hover.
A native cover input region retains pointer drag and trackpad input instead of
moving the canvas; its scroll/pinch region is intentionally reserved for the
collection cover.

The upper-right page count opens a scrollable, adaptive grid of the exact ordered
collection members, using the ordinary Super Thread cards and their open actions.
Its text, internal padding and glass capsule scale together by 1.2 around the
top-right anchor, preserving the existing 14pt outer inset and cover layout.
The panel preserves the filtered collection order (creation time, stable ties),
including members outside the carousel's four-cover preload window. Its cards keep
the ordinary opaque surfaces, archive actions and native trackless scrolling.
The count expands from the collection card into the workspace's centered reading
panel, using `NativeCollectionPanelPresentation`, the same `NativeReadingPageStack`
compositor, window-relative margins and emphasized 420ms opening as Agent/Report
readers. Overview and Dock fade out and reject input/accessibility while the panel
is open; this is not a screen-sized popover or a zoomed canvas child. The panel
has no gallery heading or total count. The grid reserves only 48pt above its
scroll viewport for the floating shared upper-left Close; only the centered
member grid scrolls.
Columns adapt to the logical window viewport (including window zoom), with up to
360pt cards, 20pt gaps, and a single shrinking column in narrow windows. Cover
height preserves 360:308, with a separate metadata region. No panel dimension can
extend beyond the host viewport. The opaque reading surface also works with
Reduce Transparency.
The carousel pauses through opening and return; closing starts a fresh dwell.
Escape, Close and blank-margin clicks reverse the panel into the current card
frame. The count is behind the expanded surface, not a second floating control.
Opening a member retires the collection panel before invoking existing navigation. Inactive,
offscreen and removed collections dismiss the panel. Dismissed card actions cannot
open a second member. The existing lower page menu and navigation controls
continue to select carousel pages.

The selected ID is shared by cover, metadata, opening and semantic navigation.
Automatic advance follows an 11-second dwell while foreground, visible and not in
a cover gesture. The dwell starts after the incoming page finishes travel and
WebKit acknowledges cover playback; loading does not consume it. Manual advance
resets the dwell. Offscreen and hidden collections stop advancing. Their covers
pause the current motion/hold, and preloaded neighbors stay at their beginning.
Each cover animates for at most 6 seconds. Collection covers play once per
selection and hold their final composition until paging; standalone covers hold
for 5 seconds after animation completion before replaying. Returning to a selected
page replays from its beginning.
Standalone application cards receive foreground/presentation activity through
the shared animation environment too.
Active/visibility loss and membership replacement settle the current selection and cancel its
motion owner. Only the stateless mask identity is replaced; settled metadata
subscriptions and in-flight card actions remain mounted. Cover geometry ignores
interpolated offsets once settled, preserving
mounted WebKit identities instead of reloading them to cancel travel. Transition ownership
prevents overlapping turns and opening intermediate content. At most four covers
mount (current, retiring and neighbors), regardless of collection size; larger
collections use the page menu instead of an overflowing dot row.

The [production-backed demo](../../../../../demos/super-thread-carousel/README.md)
provides headless model exports and manual viewing without running a Runtime.

There is no Cmd+F conversation search, search menu/interaction action or Runtime
keyword index. Tag filtering and Agent `grep_threads` remain
independent capabilities; native text editing keeps its own find behavior.

Collection member cards expose an icon-only Archive Super Thread button over the
upper-right cover corner (or the equivalent corner without a cover), alongside
their existing context menu. The button retains its accessible label and help.
Pending archive work replaces the icon with a spinner in the same 32pt target;
its accessible label and help announce that work is in progress.
Both invoke the same atomic
application archive command: hide the report and its persisted associated ordinary
Threads. UI membership and counts follow the authoritative catalog, not optimistic
per-card removals. A surviving selection is retained; removal of that selection
chooses a remaining member. Fewer than two visible members dissolve the Collection
and dismiss its panel, leaving any survivor as an ordinary Report card. Archive
changes no execution, background task, history or binding;
explicit archived reading and actions remain available. Errors retain the member
with retryable feedback. The panel and carousel keep their existing close, hover,
scale and cover timing contracts.
Member controls use the observable panel owner to admit drawing-time and invoked
actions. The retained panel content must not infer admission from a captured
card-local `showingMembers` State value: it can still hold the pre-opening value
and leave archive disabled. Closing, inactive and removed-member guards remain.

## Property boundaries

**PBT-OVERVIEW-GEOMETRY** calls the production pure layout solver with 0–18
unique product-ordered cards (1–3 columns, 1–2 rows), usable viewport widths
240–2,600pt, heights 240–1,600pt, origins −400…400/−200…200pt and either no scale
cap or an explicit cap 1…2.6. The [generated property](../../../Tests/Properties/NativeOverviewGeometryProperties.swift)
checks exact membership/order/spans, finite positive nonoverlapping card frames
with world gaps, bounds equal to the card union, bounded FitAll scale with its
1× floor, centered projection and viewport containment when raw fit permits it.
It independently enumerates largest-card regular grids to check the documented
quality floor. Empty membership has no camera. No oracle calls the solver's
placement/fit helpers. Failures shrink membership/spans/viewport while retaining
the first violation and print seed plus minimized JSON. The generated positive
viewport domain does not claim invalid-input, zero-viewport, large-collection,
all-policy or global-optimality coverage.

**PBT-OVERVIEW-STATE** mounts the production Canvas in a native SwiftUI window.
[Generated traces](../../../Tests/Properties/NativeOverviewStateProperties.swift)
have 18 attempts at insert/remove/footprint/resize/pause/visibility/manual/auto/
content events, up to 1–2 column/row spans, 500–1,500 by 500–1,000pt sizes,
manual scales 0.6…1.5 (production normalization still applies) and revisions 0–5.
ID selection sorts the live set before seeded sampling. After releasing pause,
hiding and manual ownership, the latest snapshot must settle within 3s: presented
membership and rendered frame identities agree, card/camera projection differs
by less than one physical pixel, and final scale matches the documented FitAll
floor/cap formula. Events are submitted 4ms apart; this samples interleavings
rather than enumerating all scheduler orders. A reduced trace is
retained as property corpus. Failures print original/reduced event traces and
only shrink to the same failure category. This checks mounted convergence, not
physical gestures, captured appearance or frame pacing.

Both properties live in the dedicated `MokuseiProperties` SwiftPM target; ordinary
Swift tests are absent. `make pbt-native` runs geometry with explicit seed/case
budgets. `make pbt-native-state` separately runs mounted convergence and requires
macOS 26 with a WindowServer; missing display fails. Its 3s bound is a hang guard,
not a user-experience latency threshold. Both write original/reduced JSON for
failure replay and bound shrinking by elapsed time. These are scoped mathematical
and state-convergence properties; interaction coverage belongs to e2e and
experience measurements to benchmarks. See [PBT commands/evidence](../../../../../tools/verification/pbt/README.md).
