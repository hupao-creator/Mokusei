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

Overview projects a finished `interrupt_thread` from its tool acknowledgement.
The compact catalog carries just the batch `ok`. A detailed transcript can
identify each target by its argument position and matching Thread ID, including
duplicates. A missing or mismatched acknowledgement leaves the outcome unknown.
Tool dispatch errors remain failures. [Operation projection](NativeOverviewMokuOperations.swift)

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

The 1x grid cell is 320pt wide and 196pt high, with a 16pt gap. Two-row cards are
408pt high; two-column cards are 656pt wide. Footprints retain their column/row
semantics, including Agent Threads, individual Reports and Super Thread collections.
Packing, rendered card bounds, transitions and attention visibility all use
the shared grid pitch, as do camera bounds and hit regions. Manual and automatic
camera framing keep at least 1×, so large
layouts overflow the viewport and remain reachable by pan.

[NativeOverviewLayout](NativeOverviewLayout.swift) is a pure function. Its inputs are the latest members in product order, the usable viewport and an explicit geometry policy; its output is placements, bounds and the automatic camera. Previous placements, old cameras, animation progress, pauses and revision history are not inputs.

The solver scores each regular grid by dimensions and builds the best one's rows
using the cards' actual spans. This guarantees a raw fit at least as good as the
best largest-card grid. Equal-sized cards take this linear path. For mixed spans,
the solver also packs horizontal and vertical bands, trying product order and
then larger cross-axis spans first. Short cards can occupy openings left beside
or beneath earlier cards. Each pass samples up to 65 strip sizes and retains up
to 64 disjoint openings. Storage scales with card count, independently of span
magnitude. With these limits, sorting dominates asymptotic time at `O(N log N)`.
Candidates compete on raw FitAll scale, then smaller world area and width.
The first equally ranked layout wins. Returned placements follow product order.

One 2×1, one 1×2 and two 1×1 cards tile six cells. The better fitting of the
3×2 and 2×3 rectangles is available in any product order. Other mixed
collections use bounded packing and can retain unused space.

Card sizes remain their measured spans. A card may compose up to
`HarnessOverviewCapacity.maximumColumns` (three) grid columns; that is a card
capability, not an Overview viewport column count or a layout mode. A 3×2 card
is centered by the same solver at 1× even in the minimum window. Gaps are world-space; screen gaps are `scale × gap`. The solver never clips, stretches or equalizes cards. Empty input returns empty bounds and no camera; a zero-area usable viewport returns legal positions without a camera; negative viewport dimensions, malformed spans, duplicate IDs and invalid limits throw a typed input error. A later valid input always plans normally.

Same-scene structural slot changes with identical members and viewport reuse geometry. Reuse still cancels any obsolete worker waiting for the spatial stage, so an A→B→A membership or viewport update cannot later publish B over A. Content-only updates do not enqueue layout. A viewport size change re-evaluates candidates because aspect can change the chosen arrangement. `layoutSolveCount` and `geometryReuseCount` expose these paths.

Packing reserves a header allowance and the idle Dock footprint.
The canvas and fixtures share
`NativeOverviewViewportDefaults.toolbarBottom`. The shell and semantic planes
draw across the full window. Controls float above cards during panning.

Automatic framing fits the union of card frames to the usable width and height
with a 1× scale floor and the configured scale cap. It centers the union in
that region, then moves the target down to the window midpoint if the usable
center is above it. The same rule centers tall layouts at 1×. Panning can
reach every card. Manual bookmarks and zoom use the original usable region.
The window has a separate 1× to 5× zoom. Background layout preserves manual
pan and zoom. Returning to automatic uses the latest complete snapshot,
including after a pause, a hidden window or a failed or zero-area update.
If the header, Dock and framing margins exhaust the vertical packing area at
high workspace zoom, the automatic camera centers the packed cards using the
window's full logical height. This also initializes navigation on a cold open.
An empty collection disposes the camera.

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

Within a visible canvas selection, authoritative catalog changes use the
160ms upward shrink and fade when a card leaves. This includes eligible Agent
Thread and Report archive, linked Threads hidden by Report archive, and
visibility or coverage changes that remove a placement. Status and content
updates that preserve membership keep the mounted card. When the final
workspace card leaves, the Dock's landing composer takes input immediately
while the empty canvas layout finishes the card's exit. Reduce Motion hides
the canvas immediately on that handoff. **Clear all history**
is a workspace reset under Settings, where the covered canvas coalesces
catalog changes and resumes from the latest projection.

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
repack the scene. The reservation consumes the existing vertical padding budget when computing the usable size.

[NativeOverviewScrollInput](NativeOverviewScrollInput.swift) coordinates pan/zoom with native controls. The input monitor follows the top-left of the logical viewport at its exact size, including when the card stack overflows it. Window header dragging and Moku controls are excluded from canvas navigation. A click that dismisses Moku input cannot also reset the camera. Real interaction pauses automatic camera motion; hover/restored focus alone does not imply editing.

The canvas combines SwiftUI's focused-card scope with the window's actual editable text responder before pausing for input. Closing a covering surface can restore keyboard focus to a whole card; that focus keeps keyboard activation without holding the text-editing pause. Window-scoped native responder notifications also release editing protection when a field loses focus or unmounts, without changing camera state from automation.

The host supplies no context menu on the canvas background or directory chips. Report cards provide their plugin-owned archive menu. A background click restores automatic framing. Directory children remain available through hover and accessibility actions.

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

Tag widths have no fixed point cap. Each top-level chip may use the scroll viewport left after All and bar insets; sibling chips remain horizontally scrollable. The centered bar leaves room on both sides for the window controls and actions, plus 16pt clearance. Below 424 logical points of viewport width, filters move to a second row so the scroller remains usable at high workspace zoom. Child chips may use the full available bar width, and overflowing child rows scroll within that width. Their glass container stays inside the scroll viewport so captured labels cannot bypass clipping. Chips use shadowless `.clear` glass over a view-layer material fill rather than `.regular` glass: the regular variant's system-drawn shadow is composited outside the SwiftUI layer, so neither a per-chip `clipShape` nor the bar's capsule clip can trim it, and the 4pt gaps let neighboring shadows overlap into a visible band. The material fill supplies the frosted face and follows the pill shape, while selection tint and interactive feedback remain on the glass. Selected All, directory and semantic chips use the overview accent with 22% tint alpha, or 34% with Increased Contrast; unselected chips have no tint. Selected directory chips replace their folder or child emoji prefix with a check icon. Selected semantic chips replace their emoji prefix with the same check, including in child menus; All remains prefix-free. Accessibility labels retain the original tag names and emoji. Label font weights remain unchanged; the shared selected check uses a 2-unit Lucide stroke instead of the default 1.5-unit stroke. Names only truncate when their individual viewport cannot hold them. Presentation does not change tag identity or membership.

All, directory and semantic capsules (including child menus) retain the 1.1× enlarged label and prefix metrics. Their height shares `NativeWindowNavigationGeometry.height` (42pt) with the traffic-light capsule and right-side circular actions. At actual size, all three groups share a centerline, and the first row's top inset mirrors the resting Moku capsule's bottom inset (5% of viewport height, clamped to 24–36pt). The native buttons keep their system size at workspace zoom and follow the action row's center. Header dragging and scroll exclusion end 2pt below the last visible row. In short two-row viewports, the gap between rows shrinks to leave at least 8 logical points for starting canvas scrolling and pinching at supported window sizes and zoom levels. Card packing and camera framing retain their independent 60pt header allowance (120pt at widths up to 620pt with filters). Semantic labels always lay out the emoji separately from the plain title, in both selection states. The shared prefix retains both its unselected glyph and centered check as opacity-switched layout participants, reserving the same natural width and height across selection changes. This stability applies to a fixed title/child; choosing a different directory child can still change the title width. The shared prefix keeps its native ideal size: an emoji's advance and line bounds can exceed its point size, so an icon-sized square can cut its glyph even inside a roomy chip. The Lucide folder and selected check use the same icon size; emoji do not use per-glyph offsets.

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

For a native check of the empty-workspace handoff, use an isolated profile
with one ordinary Thread and Moku. Stop that Thread, then use its Overview
archive button. The card leaves while the Moku composer becomes available.
Repeat with Reduce Motion enabled and verify the immediate removal. Mounted
geometry properties do not exercise this handoff.

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

Report opts into one two-cell collection per selected space. The Host first applies
visibility, archive, directory/tag selection and exact execution coverage. It
uses the full individual footprints, including offscreen cards. A report with a
cover costs two cells and a coverless report costs one.

The [profile-local reading record](NativeOverviewCollectionReading.swift) determines
default membership across views. At **24 hours** from the end of the last visit
(or creation for an unvisited report), a report defaults to collection. Overview
samples age on presentation and space changes. Idle time alone does not schedule a
live canvas move. Two idle reports can share a collection even below budget. A
lone idle report stays individual until there is another member to group with it.

Opening a report and reading its uniquely associated Agent Threads share one
visit. Ownership follows catalog Thread identity across execution changes and
updates on rebinding. Ambiguous standalone Agent routes have no owner. With the
reader admitted, focused, visible and connected, monotonic foreground seconds
accumulate once across the visit. Covering or losing focus pauses the clock.
Qualification occurs at 25% of the report's full static body reading estimate,
clamped to 5–45 seconds, inclusive. A second distinct visit with positive
foreground time also qualifies if it begins less than 24 hours after the
previous foreground visit closed. Page selection and report updates do not
create visits. Each visit samples its estimate on open.

Qualification restores the default individual presentation. Under pressure the
[budget](NativeOverviewCollectionBudget.swift) selects idle members first, then
members without qualified visits, then qualified members. Within each class,
creation or the latest qualified visit orders candidates, with stable ties.
Take the shortest prefix meeting the 16-cell target, the idle-member minimum
and, for an already grouped prefix in the same space, a two-cell release margin.
A fresh qualification can use all 16 cells. Pressure grouping requires at least
two members and positive savings. When the target is unreachable, take the
largest saving available and allow pan. Display order follows the original
creation order, with the collection at its oldest member's position.

Opening uses the real report identity and the current source card. Prepared
return resolves the latest placement. A returned member that remains collected
occupies the cover until the user selects another page. Diagnostics distinguish
the profile's default from actual membership in the current space. Persistence
errors are reported and the session continues with its in-memory reading facts.

The Report plugin owns `NativeReportCollection`: a cover preserving its 360:308
logical viewport ratio slides horizontally while the remaining metadata region
stays in place and switches through the shared
`ThreadCardInkMask`. Cover and ink use one 460ms ease-in-out progress; backward
paging mirrors only the mask so the reveal follows cover travel. Outgoing ink
stays above incoming ink. At the current 320×408pt grid footprint, the cover is
273.8pt high and metadata is 130.2pt high. WebKit and its poster share a centered, uniformly scaled
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
active, visible collection. It is centered in an overlay at the bottom of the
fixed cover viewport, so mounting it leaves the cover, metadata and upper-right
count in place, including when all seven page markers are visible.
A transparent SwiftUI mask cannot reliably suppress
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
The glass capsule is sized by the padded label and inset 14pt from the top and
trailing edges of the cover. A vertical offset centers the visible digits and
slash within the capsule.
The panel preserves the filtered collection order (creation time, stable ties),
including members outside the carousel's four-cover preload window. Its cards keep
the ordinary opaque surfaces, archive actions and native trackless scrolling.
The count expands from the collection card into the workspace's centered reading
panel, using `NativeCollectionPanelPresentation`, the same `NativeReadingPageStack`
compositor, window-relative margins and emphasized 420ms opening as Agent/Report
readers. Overview and Dock fade out and reject input/accessibility while the panel
is open; this is not a screen-sized popover or a zoomed canvas child. The panel
uses a rounded regular Liquid Glass backdrop throughout opening, scrolling and
return. Close floats in the upper-left corner and stays fixed as rows scroll.
At logical panel widths of 320pt and above, the scroll viewport reaches the top
edge and the centered grid leaves 54pt on each side for the 32pt Close button
and its 14pt inset. Columns adapt up to 360pt per card with 20pt gaps.
In narrower panels, the single column uses the space below Close, with 14pt
side margins. The 320pt layout scales to fit the panel width, including its
scroll viewport and hit targets, so the cover, title and badge fit together. Cover
height preserves 360:308, with a separate metadata region. No panel dimension can
extend beyond the host viewport. Reduce Transparency gives the panel an opaque
reading surface matched to the current appearance.
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
per-card removals. While the member panel remains open, an outgoing card keeps
its last content and grid seat for a 160ms fade and slight shrink. It immediately
stops accepting input, leaves the accessibility tree and pauses cover playback.
Other members and Close remain available. Each exit has its own deadline.
A returning reference resumes in the same mounted card with the current data.
macOS Reduce Motion settles removals immediately, including in-progress exits.
A surviving selection is retained; removal of that selection chooses a
remaining member. If the new projection selects fewer than two eligible
members, the panel closes and each remaining report appears individually. Archive
changes no execution, background task, history or binding;
explicit archived reading and actions remain available. Errors retain the member
with retryable feedback. The panel and carousel keep their existing close, hover,
scale and cover timing contracts.
Member controls use the observable panel owner to admit drawing-time and invoked
actions. The retained panel content must not infer admission from a captured
card-local `showingMembers` State value: it can still hold the pre-opening value
and leave archive disabled. Closing, inactive and removed-member guards remain.

## Property boundaries

**PBT-OVERVIEW-COLLECTION** compares the production budget with exhaustive legal
prefix scores across mixed one- and two-cell reports, idle floors, retained
prefixes and up to two types. Generated foreground spans straddle qualification
and one-day boundaries and exercise pause/resume and distinct short visits.
The [mounted journey](../../../../../tools/e2e/README.md#current-scenario-contract)
checks return selection, promotion and the two-cell release margin.

**PBT-OVERVIEW-GEOMETRY** calls the production pure layout solver with 0–18
unique product-ordered cards (1–3 columns, 1–2 rows), usable viewport widths
240–2,600pt, heights 240–1,600pt, origins −400…400/−200…200pt and either no scale
cap or an explicit cap 1…2.6. The [generated property](../../../Tests/Properties/NativeOverviewGeometryProperties.swift)
checks exact membership/order/spans and uses the specified 320×196pt cell and
16pt gap to check the frame union against the solver's production metrics.
It checks finite positive nonoverlapping frames and bounded FitAll scale with its
1× floor, centered projection and viewport containment when raw fit permits it.
It independently enumerates largest-card regular grids to check the documented
quality floor. Every fourth seed shuffles the six-cell tiling with base spans of
1–3 columns and 1–2 rows per tile. An independent area and aspect check catches
empty cells or a poorer orientation even when the regular-grid floor passes.
Empty membership has no camera. No oracle calls the solver's
placement/fit helpers. Failures shrink membership/spans/viewport while retaining
the first violation and print seed plus minimized JSON. The generated positive
viewport domain does not claim invalid-input, zero-viewport, large-collection,
all-policy or global-optimality coverage.

**PBT-OVERVIEW-STATE** mounts the production Canvas in a native SwiftUI window.
[Generated traces](../../../Tests/Properties/NativeOverviewStateProperties.swift)
start with independent toolbar (0–120pt) and Dock (0–180pt) clearances.
Every fourth seed starts with 8–14 single-width cards of varying heights to
exercise overflow. Each trace makes 18 attempts at insert/remove/footprint/resize/pause/visibility/manual/auto/
content events, up to 1–2 column/row spans, 500–1,500 by 500–1,000pt sizes,
manual scales 0.6…1.5 (production normalization still applies) and revisions 0–5.
ID selection sorts the live set before seeded sampling. After releasing pause,
hiding and manual ownership, the latest snapshot must settle within 3s: presented
membership and rendered frame identities agree, card/camera projection differs
by less than one physical pixel, and final scale matches the documented FitAll
floor/cap formula. The union of mounted card frames must center horizontally
and balance the toolbar and Dock clearances according to the automatic framing
rule, including when the union overflows. Events are submitted 4ms apart; this samples interleavings
rather than enumerating all scheduler orders. A reduced trace is
retained as property corpus. Failures print original/reduced event traces and
only shrink to the same failure category. This checks mounted convergence, not
physical gestures, captured appearance or frame pacing.

These properties live in the dedicated `MokuseiProperties` SwiftPM target.
`make pbt-native` runs geometry and collection budgets with explicit seed/case
budgets. `make pbt-native-state` separately runs mounted convergence and requires
macOS 26 with a WindowServer; missing display fails. Its 3s bound is a hang guard,
not a user-experience latency threshold. Failures retain original/reduced JSON for
replay. These are scoped mathematical
and state-convergence properties; interaction coverage belongs to e2e and
experience measurements to benchmarks. See [PBT commands/evidence](../../../../../tools/verification/pbt/README.md).

## Camera interaction e2e

`E2E-OVERVIEW-001` opens an isolated workspace at Overview. The default
suite has one completed task. The Collection suite adds a second task and six
reports. The runner observes the mounted task, all card placements, the viewport
and both control clearances. At 1× it checks the automatic center, requests a
manual pan, checks both displacement axes, and returns to automatic framing.
The settled return must recover the original center. The three snapshots and
socket transcript certify semantic camera behavior. Physical input, clipping
at the window edges and cover pixels require separate observations.
[Desktop scenario and evidence](../../../../../tools/e2e/README.md)
