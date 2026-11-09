# Overview

[NativeOverviewWorkspaceModel](NativeOverviewWorkspaceModel.swift) projects public catalog records into visible cards, tags, selection and search scope. [NativeOverviewCanvas](NativeOverviewCanvas.swift) owns structural geometry; the registered plugin supplies each card's semantic content. All placements in the selected layout remain mounted, including outgoing cards through exit. Camera movement alone does not mount/unmount cards or start structural transitions.

[Membership facts](NativeOverviewMembership.swift) separate filter membership from
streaming card content. Admitted catalog deltas carry changed identities into the
workspace; content-only changes compare those identities' facts and refresh only
selected changed card slots, without scanning or sorting the selection. This also
applies to active searches when the changed record's metadata match is unchanged.
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
filtering, search and report coverage, including directory-only documents. Moku
uses these facts for its empty-workspace landing; an unloaded catalog remains
unknown. The All membership is invalidated lazily and resolved when that view is
requested. Filter chrome and Moku still receive the complete filter description
when membership changes, so producing that public output scales with the output
size; unrelated scope selections and card projections are reused. Selecting a
filter, changing search membership/rank or changing card geometry retains the
ordinary complete selected-layout transaction.

While the first creation awaits native admission, the canvas and filters stay
covered by landing so a durable, unadmitted shell cannot replace the primary
input. Ordinary eligibility rules, including archive and terminal visibility,
are shared with Overview rather than reimplemented by the Dock. The
[native landing replay](../../../../../tools/verification/reading-presentation/README.md#empty-workspace-and-first-dispatch)
checks this distinction against real catalog transactions. Each scope selection
normalizes its distinct labels once. The
[CPU benchmark and scenario matrix](../../../../../tools/verification/overview-performance/README.md)
distinguishes model work from GUI and GPU work.

All Overview cards, including Agent Threads and Report, use opaque palette
surfaces and a soft border, including completed cards.
Shell and semantic planes contain no Liquid Glass containers. The card boundary
supplies the shared flat-material policy to provider badges, terminal marks and
plan highlights. Agent Thread emoji badges use static opaque palette fills
without an added border: adaptive accent-soft green when completed, neutral
surface-strong otherwise. This also applies under Reduce Transparency. Removing
per-card Liquid Glass avoids its spatial update cost during canvas movement.
The terminal symbol and accessible status label remain independent of color.
Card shells and all other card surfaces stay flat.
The former `glass world` preference is removed. Chrome, directory menus, Moku,
Settings and shared controls outside a card keep their own materials. Cloud,
scan and spatial-animation ownership are unchanged.

Overview cannot originate steer/send input for a specified Thread. Emoji badges
are status content: they have no Send swap, button, keyboard focus stop or draft
callback. The Harness overview renderer receives only an existing-interaction
response callback plus ordinary reading navigation, rather than full thread
actions. Permission/question responses remain available; those are bound to a
current pending interaction. There is no per-card message editor, text/file drop
target or send shortcut. Canvas drag/scroll/pinch, search, Return-to-open and
card activation keep their navigation behavior. The independent Moku composer,
Thread-detail Moku input, Browser annotation sends and general Runtime APIs
remain owned by their existing boundaries; Moku operation decorations are observations,
not card send controls.

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
The model retains those slots' current presentation IDs alongside queued
revision snapshots until exit finishes. A queued revision can adopt newer
content only for the same structural identity; A→B→A lifecycle history remains
FIFO. Source replacement cancels the old queued work and refreshes ownership.

Presented placements have an identity index rebuilt only with a new layout.
Each pan/zoom input checks the current attention identities against that index,
so finished and unrelated placements do not participate. The empty attention set
returns immediately. The mounted replay checks the actual callback's visit count
while preserving mounted identities and solver state.

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

The existing mounting, transition and membership integration suites exercise
single-card text delivery with unchanged canvas-body/solver counts, retained
native identities, queued incompatible footprints and reversals, current-scene
camera memory, and the last visible snapshot surviving model pruning during
exit. The body counter is an observation-boundary diagnostic, not a CPU/FPS
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
See the [target-Mac investigation](../../../../../design/thread-transition-latency.md)
for samples, paired observations and validation limits.

## Layout, motion and input

Presentation pauses (including the expanded Moku composer) gate canvas hit
testing and accessibility without disabling the card control tree. Native
Button labels, including Report cards and Git summaries, therefore keep their
ordinary colors alongside gesture-based Agent cards. Camera pause, activation
guards and Moku outside-click dismissal retain their existing owners; transient
composer growth does not change the layout viewport. See the
[recording investigation](../../../../../design/moku-input-card-dimming.md)
for observed behavior and sprint verification limits.

The 1x grid cell is 360pt wide and 220pt high (10% taller than the former
200pt baseline), with a 16pt gap. Two-row cards are therefore 456pt high.
Packing, rendered card bounds, transitions, attention visibility and camera
readability all use the shared grid pitch; width and gap stay unchanged.

[NativeOverviewLayout](NativeOverviewLayout.swift) packs cards without overlap. In the production viewport path it first preserves surviving top-left positions, accepts nonconflicting footprint changes and fills vacancies before extending the envelope for entrants. Preserved geometry must fit at the readable floor, occupy at least 75% of its bounding grid, form one edge-connected component and contain no enclosed grid vacancies. Corner contact does not connect cards; decorative pixel gutters do not count as holes. Isolated cards and deleted center cells now enter compact planning even when no whole row or column can be removed. Healthy history still uses the existing area lower bound and bounded packing proof to detect avoidable rows/columns. Calls without a fitting region retain compact planning.

Topology checks, geometry optimization, move certification and optional batching share the existing search-step budget and cancellation polling. `topologyValidated` records a passed connectivity/hole check. A quality-certified witness is retained before motion certification; if motion cannot be proven, it uses transparent repack. If quality repair itself exhausts the budget, legal readable geometry can still return with `searchComplete = false` and `topologyValidated = false`; this is an explicitly incomplete quality outcome, not a promise that all cavities are repaired. No unbounded retry or extra repair loop runs.

The canvas supplies both the readable fitting extent and the natural-scale extent (framing region divided by `max(1, minimumScale)`). Fresh/ordinary global candidates prefer the greatest attainable natural scale before aspect and survivor travel. A still-readable previous candidate shape remains stable across resize. Execution and attention state do not reduce capacity or enlarge footprints. Explicit filter changes retain the compact planner and historical aspect preference, using visible survivors as placement history. This remains an identity-stable spatial layout, not a strict visual ordering of search rank; selection, grouping and keyword search ordering are unchanged.

Same-scene revisions with identical ID/outer-footprint sets refresh semantic snapshots and acknowledge structural history without acquiring a spatial stage or invoking the solver. This also applies to resize while the existing bounds remain readable. Reuse requires an assessment completed by this mounted canvas; a retained layout from an earlier host first visits the solver. The completed outcome, including an incomplete-budget fallback, is cached for exactly those placements to avoid repeatedly retrying the same quality repair. Exact viewport changes that invalidate capacity still plan normally; lifecycle revisions remain FIFO, including A→B→A and exits. `layoutSolveCount` and `geometryReuseCount` expose these distinct paths for native regression tests.

Fresh/filter framing centers the collection horizontally and vertically between persistent controls. In automatic mode, inserting a card refits the complete resulting collection to that anchor after its layout/entry completes; the old single-card camera must not remain the target of a multi-card scene. Ordinary revisions without entrants and with zero survivor world travel preserve the old camera scale/translation wherever the complete collection fits; otherwise translation is clamped to the nearest completely visible position. If the old scale cannot fit, normal readable fitting takes precedence. The resulting target survives delayed refits. Resize and explicit return to automatic framing restore the ordinary policy; manual framing remains user-owned, including during insertion. This protects stationary card origins on deletion and local footprint changes when capacity permits, but does not lock an individual editor through conflicting growth/global repacks.

Filter changes with visible survivors retain the old automatic scale only while
the new collection fits between persistent controls. If it exceeds that actual
capacity, the filter prepares the ordinary readable fit before presenting its
motion; retained framing cannot suppress a needed correction until a background
click. Preferred margins may yield to retained scale. Manual pan/zoom remains
user-owned, including when the new collection exceeds capacity. The production
transition replay covers two-to-eight-card expansion with both motion policies
and a Dock reservation, unchanged-scale fitting filters, manual overflow, rapid
filter reversal, automatic-return coordination and empty/nonempty recovery.

Geometry and straight-move optimization have separate outcomes. If the search budget expires after finding legal geometry but before certifying a move plan, the solver returns that geometry with `requiresRepack` rather than requiring a retry. A verified fitting candidate remains the fallback even if aspect enumeration is unfinished. The canvas keeps card identities mounted, fades the old presentation out, relocates while transparent, then reveals the result; new cards stay transparent during retirement. It never treats an uncertified straight path as collision-free. If capacity cannot be decided within the budget and there is no legal witness, the error remains visible and the last valid layout stays in place. Cancelled or replaced owners cannot overwrite the current scene with a stale layout error.

[NativeOverviewCardMotion](NativeOverviewCardMotion.swift) samples interruptible SwiftUI card motion. Filter changes animate exit, survivor movement and entry on their shared schedule. Ordinary revisions retain exit, shrink, move, grow and entry barriers. Shrinks run together inside disjoint old frames; grows run together inside disjoint final frames. `moveBatches` partitions the existing certified `moveOrder` into consecutive groups whose swept pixel bounding boxes are pairwise disjoint. This conservative proof holds for all progress pairs and renderer timing differences; overlapping envelopes remain serial even if a more precise timing proof might permit concurrency. Batch certification shares the search budget and falls back to the full singleton order on exhaustion. Each batch shares one start clock and one wait, without independent tasks. An interrupted presentation that differs from the solver's logical origins uses transparent repack before any new ordinary travel. Outgoing content survives until its exit finishes; shell and semantic content share geometry and opacity. Structural revisions are queued before SwiftUI can coalesce updates. Reduce Motion makes new card and camera spatial transitions immediate, while retaining stage ownership and cancellation. Enabling it during travel cancels the animated owner and drains unacknowledged revisions through the immediate recovery path. Retired and transparent semantic cards are explicitly hidden from accessibility. Retargeting samples current presentation, and completion cannot restore an obsolete scene.

Card motion starts, interruption samples and display samples all use
`ProcessInfo.systemUptime`. A MainActor clock shares one uptime sample for each
exact SwiftUI timeline date across the shell and semantic planes. Dates are only
tick identifiers, so wall-clock drift or adjustments cannot accumulate into the
motion's elapsed time. The clock retains the 64 most recent distinct ticks in
insertion order to share interleaved contexts while bounding process-lifetime
state; an evicted date receives a fresh uptime sample if it appears again.

The spatial frame builds its content when receiving new inputs and reuses that
view value across animation ticks. Ticks only sample the pose and apply its
geometry, opacity and accessibility state; they do not rerun the shell/semantic
content builder. New card inputs still replace the value without changing its
mounted identity, and child state, Observation and environment updates remain
live. The native resize replay changes presentation and locale during motion and
checks the retained semantic identity and final geometry.

[NativeOverviewStageCoordinator](NativeOverviewStageCoordinator.swift) serializes spatial motion with camera activity. Explicit return to automatic framing restores the default collection fit. Temporary interaction/visibility pauses defer that reset; fresh manual input cancels it. First nonempty layout prepares its camera before revealing cards.

Overview uses ordinary collection framing at the readable scale. Oversized
collections remain centered with readable overflow and can be panned or zoomed
manually. Execution and attention changes never select individual camera targets
or start periodic movement. The planner prefers its inset framing region and
retries against the control-free extent if that region would overflow; a wider
packing may fit even when the preferred shape is too tall. Manual framing stays
user-owned until an explicit return.

Camera memory is a runtime bookmark (scene, transform and manual ownership),
with no persisted mode selector. Existing preferences and user data need no
migration or cleanup.

The workspace supplies the Dock reservation from the same idle capsule geometry
used by the renderer (44pt height plus its viewport-dependent bottom seat).
Transient composer/note expansion stays an interaction overlay and does not
repack the scene. The reservation consumes the existing vertical padding budget;
the remaining preferred space is split equally above and below the collection.
This keeps ordinary wide-window packing/reading scale while balancing the gaps
to controls. The [balance investigation](../../../../../tools/verification/overview-layout/BALANCE.md)
records screenshot measurements, the compact fallback and verification limits.

Queued automatic refits read the latest bounds after acquiring the spatial
stage; a playing refit reconciles newer framing revisions on completion.
Content updates do not restart admitted work, so continuous Harness output
cannot postpone insertion framing until output stops or the user clicks the
background. The mounted capacity replay checks content updates and manual-camera
retention against the production canvas.

Reading-position preservation starts from settled automatic framing, or from an
already retained reading target. A footprint revision arriving before insertion
framing completes keeps the pending collection fit and resolves it against the
latest bounds. It cannot retain the old or partially animated camera as a new
reading position. Consecutive reading-preserving revisions carry their target
forward rather than repeatedly sampling intermediate motion; explicit return
and restoration take precedence over reading retention.

[NativeOverviewScrollInput](NativeOverviewScrollInput.swift) coordinates pan/zoom with native controls. Window header dragging and Moku controls are excluded from canvas navigation. A click that dismisses Moku input cannot also reset the camera. Real interaction pauses automatic camera motion; hover/restored focus alone does not imply editing.

The canvas combines SwiftUI's focused-card scope with the window's actual editable text responder before pausing for input. Search dismissal can restore keyboard focus to a whole card; that focus keeps keyboard activation without holding the text-editing pause. Window-scoped native responder notifications also release editing protection when a field loses focus or unmounts, without changing camera state from automation.

Overview cards, canvas background and directory chips expose no context menus. Background clicks still restore automatic framing; drag, scroll and pinch keep their existing camera behavior. Directory children remain available through hover and accessibility actions. Reading, composer and other scene menus are owned separately.

Geometry reuse applies only after presentation has settled. Recovery that cancels an entry, resize or exit still runs the normal sampled-presentation path, even when final member footprints match, so transparent entrants and retired snapshots are released. The native transition replay interrupts a two-card entry with a recovery epoch and checks the second card’s rendered pixels. Reading-position fit checks tolerate floating-point roundoff at a viewport edge; the capacity replay deletes a bottom row at a scale derived from that edge and verifies unchanged survivor screen positions.

Dev-only [transaction diagnostics](../../../build/layout-logging.md#overview-relayout-transactions) pair logical before, planned and completed/cancelled/failed snapshots under one random transaction ID. Per-transaction numeric card aliases allow before/after comparison without model identifiers or content. Snapshots are bounded and explicit about truncation; they do not reconstruct historical cases or certify animation pixels.

## Tags and search transition

[NativeOverviewChrome](NativeOverviewChrome.swift) owns the tag and action controls. Semantic tag identity remains a plain name with separately validated emoji. Each scope exposes up to five semantic tags, including singly assigned tags and separate names with equal membership. Directory filters use persistent scope identity for membership and exclude managed temporary roots. Labels are presentation only: a symlink alias or linked checkout with another label remains in its canonical directory’s All view, and same-named directories stay separate.

The tag bar omits a directory's sole semantic child when its actual selected
Agent Thread ID set and application thread reference set both equal the
directory's sets. This uses eligible catalog membership after the ordinary
visibility/archive and report-coverage rules, before search; equal badge counts
alone are insufficient. Untagged members or directory-only documents that change
those sets keep the child visible. Multiple semantic names (including a name
equal to the directory label) prevent this omission. Inbox tags are unaffected.
Catalog membership changes recompute the decision. Canonical filters, navigation,
published context and stored tags remain intact. An already selected semantic
child stays visible and selected even if it becomes redundant, preserving its
filtering meaning when later threads arrive; selecting its directory then omits
the redundant child. Global search and its return-to-browsing behavior are unchanged.

Selected tags use background-adaptive capsule fill and contrasting text. Directory menus use native glass composition and independent hover/hit regions. Selecting a child closes the menu; the directory chip keeps its current title until the glass exit transaction is removed, then shows the directory and child name separated by a short vertical divider. The selected child’s emoji replaces the folder prefix, without repeating it in the child name; a child without an emoji keeps the folder. The divider is absent without a selected child. Reopening invalidates an older close completion; the latest selection supplies the eventual title. There is no separate hierarchy caption above the bar. Archived records are excluded from Overview. Settings has no archive-restoration section; archive data and Runtime commands remain independent of that page. Tag-bar transitions explicitly read Reduce Motion; see the [shared UI motion boundaries](../../Shared/PluginUI/README.md#motion-and-materials).

Menu opening uses a 220ms smooth spring with zero extra bounce, both after initial measurement and when retargeting a mounted menu. Closing retains its existing timing. Menu closure morphs each mounted child capsule back into the measured parent capsule over 320ms. Position and size interpolate continuously; labels retire earlier than the glass, and the surface only disappears as it overlaps the parent. Reopening retargets the same mounted identities from their current presentation. Removed children remain in their old row slots during the return, then surviving children reflow smoothly. A removed directory fades its whole menu envelope because its return destination no longer exists. Retiring controls cannot receive clicks or accessibility actions. After menu exit, title, divider and prefix changes use a 280ms smooth, non-bouncing transition. Reopening still invalidates the earlier close completion. The measured scroll width carries its resize transaction across the layout boundary so the centered bar follows the chips. Initial measurements and Reduce Motion updates are immediate.

The child menu's clip contains both its viewport and the visible parent in viewport coordinates. A single short child can therefore expand from, and return to, a wider selected-directory capsule without cutting off its rounded ends. Scroll offset affects the morph's content-space target but not that clip. Overflowing rows retain horizontal clipping because their viewport already contains the parent. The native tag-glass replay samples WindowServer pixels during this transition.

The directory's own glass capsule uses its current animated frame plus only the leading/trailing overflow outside the scroll viewport. Using an absolute measured source width here can slice off its right rounded end while switching from a selected child to another top-level tag. The native replay samples both capsule edges during that shrink and the return to the child; the source still clips at the real viewport when scrolled partly offscreen.

Tag widths have no fixed point cap. Each top-level chip may use the scroll viewport left after All and bar insets; sibling chips remain horizontally scrollable. The centered bar reserves the actual action envelope plus 16pt clearance on both sides; at 620pt and narrower the actions occupy a separate row. Child chips may use the full available bar width, and overflowing child rows scroll within that width. Their glass container stays inside the scroll viewport so captured labels cannot bypass clipping. Each pill also clips its own glass render to its capsule: regular glass casts a shadow wider than the 4pt chip gap, and the bar and scroll-viewport clips would otherwise cut it into a hard-edged band that visually joins adjacent chips. Names only truncate when their individual viewport cannot hold them. Search’s temporary visual layer reuses the same title, divider and prefix components. Presentation does not change tag identity or membership.

The shared prefix keeps its native ideal size: an emoji's advance and line bounds can exceed its point size, so an icon-sized square can cut its glyph even inside a roomy chip. The Lucide folder keeps its original size; emoji do not use per-glyph offsets. The [tag-glass replay](../../../../../tools/verification/reading-presentation/README.md) compares production prefixes with unconstrained native glyphs and captures compact/light/dark Chrome.

[NativeOverviewSearchMorph](NativeOverviewSearchMorph.swift) expands the visible selected tag into the search field. If the selected tag is clipped, it falls back to visible All, then the first visible tag. Neighbor tags move outward and fade while keeping their measured size; the carrier label crossfades. Reversal preserves the actual mounted controls, focus and clipping.

## Search results

[NativeOverviewSearch](NativeOverviewSearch.swift) combines immediate keyword matches with the Runtime's [indexed body keyword search](../../../../../internal/services/threadsearch/README.md). Query, scene and search configuration define context; streaming thread revisions do not repeatedly clear rankings. Within one context, periodic refresh and temporary failures retain the last successful body result until a replacement arrives. Every nonempty query uses the global eligible catalog for both metadata matching and the Runtime `threads` request, including directory-only documents and tasks otherwise covered by reports. Archived and terminal-ineligible records remain excluded, and removed items disappear immediately. Attention-collapsed ordinary threads retain search eligibility. The search scene and request context are independent of the browsing tag: switching directory or semantic tags retains the query, rankings and in-flight request. A new query/configuration context clears old rankings, and cancelled or stale responses cannot replace current results. The search field always shows a localized global placeholder, without a tag scope badge.

Empty or whitespace-only queries hide the canvas cards and their attention indicator while retaining the current tag membership and browsing scene without issuing body searches. The search field stays focused, and the empty-results message appears only for a nonempty query. Clearing or closing search returns to the current browsing tag. The first nonempty query bookmarks the browsing camera. Without an intervening tag selection, clearing or closing search restores that camera into the current browsing scene, even when visible result cards survive the transition. Explicit tag selection retains its existing camera-reset behavior. Explicit bookmark restoration takes precedence over preserving the result scene's framing.

Validation uses existing Overview layout/camera/search/tag/directory tests and the [native input replay](../../../../../tools/verification/overview-input/README.md). `NativeOverviewCapacityTests` hosts the production canvas for the five-card mixed-footprint screenshot, six-card growth, attention updates, insufficient space, resize recovery and near-threshold stability. `NativeOverviewPackingTests` also exercises the six-card straight-move search exhaustion and truncated fitting-candidate optimization. Native window/input tests require macOS; a standalone design demo is not the production layout authority.

The centering and transition fixtures use the current grid dimensions and actual
packed bounds. Fitting-filter cases establish that the expanded collection fits
at the readable floor but exceeds the retained scale; resize observations wait
for growth beyond the old row height before asserting the shrink barrier.
Membership freshness uses Report's authored introduction and independent cover
revision, preserving the two-row covered-card footprint without rebuilding membership.
The subsequent coverage/filter cases retain the ordinary one-row card without a cover.

## Production control chaos

[NativeOverviewInteraction](../Interaction/NativeOverviewInteraction.swift) exposes the camera's production methods and registers callbacks owned by the mounted directory controls. Opening a menu calls the same `revealChildren` path as hover/accessibility; selecting a child requires its real glass menu to be mounted, then follows the production selection/exit transaction before the chip title changes. Explicit close uses the accessibility close callback; pointer exit retains its delayed dismissal. Filter-bar scrolling uses the mounted SwiftUI scroll view. A retiring registration cannot remove another view's callbacks.

The [Overview chaos guide](../../../../../tools/native-interaction/OVERVIEW.md) describes the actions and coverage limits. The [real app runner](../../../../../tools/verification/overview-interaction/README.md) creates actual directories, a symlink and a Git linked worktree, seeds an exclusively owned profile before launch, then drives the signed production Release app. Runtime `state:load` supplies the independent scope/membership oracle; mounted card identities, placement cells and camera bounds supply rendering invariants. No tag CRUD or multi-selection actions are invented: those controls do not exist in the current Overview.

The [layout comparison](../../../../../tools/verification/overview-layout/README.md) compiles baseline/current production geometry and reports screen displacement, visible fill, complete cards and solver work. Native capacity tests additionally assert same-footprint solver avoidance, deletion/refill screen anchors, automatic insertion framing without a background click and manual-pan retention in both motion settings. Insertion checks use actual rendered frames for one-to-two and six-to-seven cards, including footprint growth before the refit and coalesced Runtime revision history, wait through delayed refits, and verify that explicit return to automatic framing has no further correction to make.

## Agent reading panels

Reading entry shares the 420ms emphasized panel curve with tag-chrome withdrawal
and the resident Dock. Tag clearance remains fixed while the retained controls
move upward. See the [two-stage reading choreography](../../../../../design/reading-entrance-choreography.md)
for secondary Sidecard admission, cancellation and sprint verification limits.

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
the display's keyword filtering, sorting, plugin projections and content installs;
the mounted canvas also defers layout (including viewport changes). Existing card
snapshots, native controls, drafts and camera remain retained. Settings, Git
monitoring, runtime, notifications and Voice keep their existing lifecycles.

Before an animated return, the stack unhides the same host at the latest viewport,
resumes projection and awaits a new canvas
preparation receipt before sampling the current source frame. Removed/archived
cards cannot supply that destination. Preparation is cancelled with its route;
replacement, focus loss, disconnect/recovery and direct returns cannot let an old
waiter close a newer visit. A reversal during opening uses the participating parent
immediately. Hidden structural history is recovered as one current presentation,
while foreground revisions retain their FIFO. `NativeOverviewMembershipTests`,
`NativeMokuLandingTests.detailCoalescesHiddenOverviewAndPreparesLatestReturnFrame`
and the reading presentation preparation cases exercise these production paths.

Opening an Agent Thread captures its displayed card frame from the stable layout
and live camera transform. The shared reading stack expands that shell into an
opaque panel with equal horizontal margins, while retaining the Overview camera
and cards beneath it. The retained Filters and Settings chrome slides upward by
its full height and fades out over 200ms without scaling its labels or changing
canvas clearance, including in the narrow two-row layout. Closing reverses the
same transition; interrupted openings retarget the mounted chrome. Hidden chrome
remains excluded from hit testing and accessibility. Reduce Motion switches its
visibility immediately without translation or fading.
The production conversation content fades in unchanged; title, emoji and author
have no separate morph. Closing refreshes the source position after viewport
changes when available. Direct/restored entries without an eligible card use a
small centered expansion instead. Route identity, cancellation and reduced-motion
settling remain owned by the shared reading stack.

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
shared Shell predicate governs Overview, availability, search and ordinary
navigation; membership invalidates when its resulting visibility changes, even
if status and execution identity stay unchanged. Archive/unarchive choices,
plugin-owned application visibility and explicit result-reading links keep
their existing rules. Refresh and restart consume the retained envelope rather
than guessing from terminal status or local UI actions.

Attention-hidden ordinary threads remain in the search candidate catalog. Browsing memberships exclude them, including tag children. The window reports a stable visit identity and cumulative foreground time across history navigation. A completed execution observed in the foreground can start a read deadline without requiring another open.
