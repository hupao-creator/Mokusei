# Overview

[NativeOverviewWorkspaceModel](NativeOverviewWorkspaceModel.swift) projects public catalog records into visible cards, tags, selection and search scope. [NativeOverviewCanvas](NativeOverviewCanvas.swift) owns structural geometry; the registered plugin supplies each card's semantic content. All placements in the selected layout remain mounted, including outgoing cards through exit. Camera movement alone does not mount/unmount cards or start structural transitions.

[Membership facts](NativeOverviewMembership.swift) separate filter membership from streaming card content. The main-actor workspace retains only current-catalog identity lists for All and exposed filters, resolving them against the latest records before projection/search. Visibility, archive state, scope/labels, tags/emoji, creation/order, covered executions and locale invalidate membership; a new authority or explicit refresh also rebuilds it. Content-only updates still refresh plugin snapshots and Moku operations. Cache storage is bounded by the current catalog and exposed filters, is replaced on invalidation and is released on stop. The [CPU benchmark and scenario matrix](../../../../../tools/verification/overview-performance/README.md) distinguishes these costs from GUI and GPU work.

Rebuilding membership partitions eligible Agent Threads by canonical scope once, so each directory and child scans only its scope. Application candidates still follow the full selection rules, including unscoped documents and covered executions. The partition exists only during that rebuild; it does not retain another catalog or change equal-date ordering.

That rebuild also publishes global conversation availability before filtering,
search and report coverage, including directory-only documents. Moku uses these
facts for its empty-workspace landing; an unloaded catalog remains unknown. While
the first creation awaits native admission, the canvas and filters stay covered
by landing so a durable, unadmitted shell cannot replace the primary input. Ordinary
eligibility rules, including archived and failed/interrupted visibility, are shared
with Overview rather than reimplemented by the Dock. The
[native landing replay](../../../../../tools/verification/reading-presentation/README.md#empty-workspace-and-first-dispatch)
checks this distinction against real catalog transactions.

The same rebuild also normalizes each distinct tag/label once and supplies those keys to the existing selection rules. This memo is local to the synchronous rebuild, bounded by its distinct labels, and discarded before another locale/catalog revision can use it. Standalone selection calls retain the ordinary normalization path.

The `glassWorld` preference controls only the outer shells of Thread cards. Enabled shells use regular glass with the existing success tint for completed Threads; disabled shells use the opaque overview surface with a soft border. Both styles stay inside the same animated card frame, so geometry, opacity and exit behavior remain shared. Semantic badges retain their own glass composition, and Follow-up, plan, tag and Moku surfaces are unaffected.

## Card update isolation

Each card has separate Equatable shell and semantic boundaries outside its
spatial frame and glass container. A presentation-only update refreshes the
changed card's semantic wrapper without reevaluating unchanged cards' frames or
the target card's unchanged shell. The canvas still constructs wrapper values
for all placements. Geometry, motion, visibility and completed tint remain shell
inputs; semantic inputs also include the item presentation, viewport, locale,
decorative-animation policy, layout/activation state and renderer/state identity.

The card closure captures stable owners. Callers replacing its renderer must
update `cardContentIdentity`; the workspace supplies its model identity.
Callbacks use a stable workspace-owned reference whose current receivers are
refreshed when the workspace view is rebuilt, so mounted card actions reach the
latest receiver without requiring content reevaluation or remounting. Observable
content dependencies remain owned by the card.

## Layout, motion and input

[NativeOverviewLayout](NativeOverviewLayout.swift) packs cards without overlap. In the production viewport path it first preserves every surviving top-left position, accepts nonconflicting footprint changes and fills existing vacancies before extending the envelope for entrants. This path must fit at the readable floor and occupy at least 75% of its bounding grid. Necessary vacancies, including enclosed ones, are allowed; if production packing proves the collection can lose an entire row or column without enlarging the other axis, the existing bounded compact planner repairs the avoidable envelope. This catches deletion/shrink histories that strand a wide card below a fitting vacancy even at exactly 75% occupancy. An area lower bound avoids searching already irreducible envelopes. If that proof exhausts the shared search budget, the legal preserved candidate returns with incomplete search; once a smaller readable witness exists, subsequent optimization retains it as a geometric fallback. Conflicting growth, excessive fragmentation and insufficient capacity also use the compact planner and its collision-certified move order. Calls without a fitting region retain the compact-planning contract.

The canvas supplies both the readable fitting extent and the natural-scale extent (framing region divided by `max(1, minimumScale)`). Fresh/ordinary global candidates prefer the greatest attainable natural scale before aspect and survivor travel. A still-readable previous candidate shape remains stable across resize. Execution/attention eligibility does not reduce capacity or enlarge footprints. Explicit filter changes retain the compact planner and historical aspect preference, using visible survivors as placement history. This remains an identity-stable spatial layout, not a strict visual ordering of search rank; selection, grouping and semantic search ordering are unchanged.

Same-scene revisions with identical ID/outer-footprint sets refresh semantic snapshots and acknowledge structural history without acquiring a spatial stage or invoking the solver. This also applies to resize while the existing bounds remain readable. Exact viewport changes that invalidate capacity still plan normally; lifecycle revisions remain FIFO, including A→B→A and exits. `layoutSolveCount` and `geometryReuseCount` expose these distinct paths for native regression tests.

Fresh/filter framing centers the collection horizontally and vertically between persistent controls. In automatic mode, inserting a card refits the complete resulting collection to that anchor after its layout/entry completes; the old single-card camera must not remain the target of a multi-card scene. Ordinary revisions without entrants and with zero survivor world travel preserve the old camera scale/translation wherever the complete collection fits; otherwise translation is clamped to the nearest completely visible position. If the old scale cannot fit, normal readable fitting takes precedence. The resulting target survives delayed refits. Resize and explicit return to automatic framing restore the ordinary policy; manual framing remains user-owned, including during insertion. This protects stationary card origins on deletion and local footprint changes when capacity permits, but does not lock an individual editor through conflicting growth/global repacks.

Geometry and straight-move optimization have separate outcomes. If the search budget expires after finding legal geometry but before certifying a move plan, the solver returns that geometry with `requiresRepack` rather than requiring a retry. A verified fitting candidate remains the fallback even if aspect enumeration is unfinished. The canvas keeps card identities mounted, fades the old presentation out, relocates while transparent, then reveals the result; new cards stay transparent during retirement. It never treats an uncertified straight path as collision-free. If capacity cannot be decided within the budget and there is no legal witness, the error remains visible and the last valid layout stays in place. Cancelled or replaced owners cannot overwrite the current scene with a stale layout error.

[NativeOverviewCardMotion](NativeOverviewCardMotion.swift) samples interruptible SwiftUI card motion. Filter changes animate exit, survivor movement and entry on their shared schedule. Ordinary revisions serialize exit, shrink, ordered moves, grow and entry. Outgoing content survives until its exit finishes; glass and semantic content share geometry and opacity. Structural revisions are queued before SwiftUI can coalesce updates. Reduce Motion makes new card and camera spatial transitions immediate, while retaining stage ownership and cancellation. Retired and transparent semantic cards are explicitly hidden from accessibility. Retargeting samples current presentation, and completion cannot restore an obsolete scene.

[NativeOverviewStageCoordinator](NativeOverviewStageCoordinator.swift) serializes spatial motion with camera activity. Explicit return to automatic framing first restores the default fit, then resumes attention. Temporary interaction/visibility pauses defer that reset; fresh manual input cancels it. First nonempty layout prepares its camera before revealing cards.

Carousel admission, restoration and exit use the whole collection's readable
extent against the actual viewport between the toolbar and the idle Moku Dock. The preferred 32/64pt
framing margins are breathing room, not a reason to start attention movement.
The layout planner still prefers that inset region. If its result exceeds actual
capacity, it retries against the control-free extent before admitting a carousel;
a wider packing may fit even when the preferred shape is too tall. Capacity
does not depend on the current camera translation or which cards are offscreen.
Manual navigation still stops attention and retains ownership until an explicit
return. The [carousel regression investigation](../../../../../tools/verification/overview-layout/CAROUSEL.md)
records the recording geometry and production-canvas coverage.

The workspace supplies the Dock reservation from the same idle capsule geometry
used by the renderer (44pt height plus its viewport-dependent bottom seat).
Transient composer/note expansion stays an interaction overlay and does not
repack the scene. The reservation consumes the existing vertical padding budget;
the remaining preferred space is split equally above and below the collection.
This keeps ordinary wide-window packing/reading scale while balancing the gaps
to controls. The [balance investigation](../../../../../tools/verification/overview-layout/BALANCE.md)
records screenshot measurements, the compact fallback and verification limits.

Carousel facts join the presented placements against the canvas's existing current-record index in linear time. For unchanged structural identities, the canvas rebuilds those facts only when carousel eligibility changes; text, counters and other presentation metadata skip that work while attention counts still refresh. Structural and geometry changes retain the ordinary presentation/refit path, and manual navigation keeps ownership.

Changed carousel facts do not restart an already queued or playing automatic refit. Queued work reads the latest bounds after acquiring the spatial stage; a playing refit reconciles newer framing revisions on completion. Continuous Harness output therefore cannot postpone insertion framing until output stops or the user clicks the background. The mounted carousel replay checks content-only updates, eligibility changes and manual-camera retention against the production canvas.

Reading-position preservation starts from settled automatic framing, or from an
already retained reading target. A footprint revision arriving before insertion
framing completes keeps the pending collection fit and resolves it against the
latest bounds. It cannot retain the old or partially animated camera as a new
reading position. Consecutive reading-preserving revisions carry their target
forward rather than repeatedly sampling intermediate motion; explicit return,
restoration and attention framing take precedence over reading retention.

[NativeOverviewScrollInput](NativeOverviewScrollInput.swift) coordinates pan/zoom with native controls. Window header dragging and Moku controls are excluded from canvas navigation. A click that dismisses Moku input cannot also reset the camera. Real interaction pauses automatic attention; hover/restored focus alone does not imply editing.

The canvas combines SwiftUI's focused-card scope with the window's actual editable text responder before pausing for input. Search dismissal can restore keyboard focus to a whole card; that focus keeps keyboard activation without holding the text-editing pause. Window-scoped native responder notifications also release editing protection when a field loses focus or unmounts, without changing camera state from automation.

Overview cards, canvas background and directory chips expose no context menus. Background clicks still restore automatic framing; drag, scroll and pinch keep their existing camera behavior. Directory children remain available through hover and accessibility actions. Reading, composer and other scene menus are owned separately.

Geometry reuse applies only after presentation has settled. Recovery that cancels an entry, resize or exit still runs the normal sampled-presentation path, even when final member footprints match, so transparent entrants and retired snapshots are released. The native transition replay interrupts a two-card entry with a recovery epoch and checks the second card’s rendered pixels. Reading-position fit checks tolerate floating-point roundoff at a viewport edge; the capacity replay deletes a bottom row at a scale derived from that edge and verifies unchanged survivor screen positions.

## Tags and search transition

[NativeOverviewChrome](NativeOverviewChrome.swift) owns the tag and action controls. Semantic tag identity remains a plain name with separately validated emoji. Each scope exposes up to five semantic tags, including singly assigned tags and separate names with equal membership. Directory filters use persistent scope identity for membership and exclude managed temporary roots. Labels are presentation only: a symlink alias or linked checkout with another label remains in its canonical directory’s All view, and same-named directories stay separate.

Selected tags use background-adaptive capsule fill and contrasting text. Directory menus use native glass composition and independent hover/hit regions. Selecting a child closes the menu; the directory chip keeps its current title until the glass exit transaction is removed, then shows the directory and child name separated by a short vertical divider. The selected child’s emoji replaces the folder prefix, without repeating it in the child name; a child without an emoji keeps the folder. The divider is absent without a selected child. Reopening invalidates an older close completion; the latest selection supplies the eventual title. There is no separate hierarchy caption above the bar. Archived records are excluded from Overview; restoration is in Settings. Tag-bar transitions explicitly read Reduce Motion; see the [shared UI motion boundaries](../../Shared/PluginUI/README.md#motion-and-materials).

Menu opening uses a 220ms smooth spring with zero extra bounce, both after initial measurement and when retargeting a mounted menu. Closing retains its existing timing. Menu closure morphs each mounted child capsule back into the measured parent capsule over 320ms. Position and size interpolate continuously; labels retire earlier than the glass, and the surface only disappears as it overlaps the parent. Reopening retargets the same mounted identities from their current presentation. Removed children remain in their old row slots during the return, then surviving children reflow smoothly. A removed directory fades its whole menu envelope because its return destination no longer exists. Retiring controls cannot receive clicks or accessibility actions. After menu exit, title, divider and prefix changes use a 280ms smooth, non-bouncing transition. Reopening still invalidates the earlier close completion. The measured scroll width carries its resize transaction across the layout boundary so the centered bar follows the chips. Initial measurements and Reduce Motion updates are immediate.

The child menu's clip contains both its viewport and the visible parent in viewport coordinates. A single short child can therefore expand from, and return to, a wider selected-directory capsule without cutting off its rounded ends. Scroll offset affects the morph's content-space target but not that clip. Overflowing rows retain horizontal clipping because their viewport already contains the parent. The native tag-glass replay samples WindowServer pixels during this transition.

The directory's own glass capsule uses its current animated frame plus only the leading/trailing overflow outside the scroll viewport. Using an absolute measured source width here can slice off its right rounded end while switching from a selected child to another top-level tag. The native replay samples both capsule edges during that shrink and the return to the child; the source still clips at the real viewport when scrolled partly offscreen.

Tag widths have no fixed point cap. Each top-level chip may use the scroll viewport left after All and bar insets; sibling chips remain horizontally scrollable. The centered bar reserves the actual action envelope plus 16pt clearance on both sides; at 620pt and narrower the actions occupy a separate row. Child chips may use the full available bar width, and overflowing child rows scroll within that width. Their glass container stays inside the scroll viewport so captured labels cannot bypass clipping. Names only truncate when their individual viewport cannot hold them. Search’s temporary visual layer reuses the same title, divider and prefix components. Presentation does not change tag identity or membership.

The shared prefix keeps its native ideal size: an emoji's advance and line bounds can exceed its point size, so an icon-sized square can cut its glyph even inside a roomy chip. The Lucide folder keeps its original size; emoji do not use per-glyph offsets. The [tag-glass replay](../../../../../tools/verification/reading-presentation/README.md) compares production prefixes with unconstrained native glyphs and captures compact/light/dark Chrome.

[NativeOverviewSearchMorph](NativeOverviewSearchMorph.swift) expands the visible selected tag into the search field. If the selected tag is clipped, it falls back to visible All, then the first visible tag. Neighbor tags move outward and fade while keeping their measured size; the carrier label crossfades. The carrier fades into the shared Moku warm-black capsule gradient as the label retires, and the mounted search contents take Moku's local dark appearance. Reversal preserves the actual mounted controls, focus, clipping and the material's fade-out.

[OverviewThreadSearchField](NativeOverviewSearch.swift) uses the shared native [composer editor](../../Shared/PluginUI/README.md#cards-composer-and-forms) in single-line mode and opts into the [emphasized insertion mark](../../Shared/PluginUI/README.md#cards-composer-and-forms). The native viewport stays vertically pinned while the carrier expands, so text and the insertion mark remain aligned with the capsule. Long queries scroll horizontally on one line instead of wrapping; Return never inserts a break or submits; pasted or dropped line breaks become spaces. Escape exits. Focus and repeated select-all requests travel through native selection, so reopening search still replaces the previous query, and clearing refocuses the editor at its start.

## Search results

[NativeOverviewSearch](NativeOverviewSearch.swift) combines immediate keyword matches with the Runtime's [local semantic search](../../../../../internal/services/threadsearch/README.md). Query, scene and search configuration define context; streaming thread revisions do not repeatedly clear rankings. Within one context, periodic refresh and temporary failures retain the last successful semantic result until a replacement arrives. Results are always intersected with the current visible scope, so removed/archived items disappear immediately. A new query/scope context clears old rankings, and cancelled or stale responses cannot replace current results.

The first nonempty query bookmarks the browsing camera. Clearing or closing search restores that camera into the current browsing scene, even when visible result cards survive the transition. Explicit bookmark restoration takes precedence over preserving the result scene's framing.

Validation includes the full Workspace search morph in the [native landing replay](../../../../../tools/verification/reading-presentation/README.md), comparing native text and caret geometry with the carrier and exercising direct clip scrolling. Validation also uses existing Overview layout/camera/search/tag/directory tests and the [native input replay](../../../../../tools/verification/overview-input/README.md). `NativeOverviewCapacityTests` hosts the production canvas for the five-card mixed-footprint screenshot, six-card growth, execution/attention updates, insufficient space, resize recovery and near-threshold stability. `NativeOverviewPackingTests` also exercises the six-card straight-move search exhaustion and truncated fitting-candidate optimization. Native window/input tests require macOS; a standalone design demo is not the production layout authority.

## Production control chaos

[NativeOverviewInteraction](../Interaction/NativeOverviewInteraction.swift) exposes the camera's production methods and registers callbacks owned by the mounted directory controls. Opening a menu calls the same `revealChildren` path as hover/accessibility; selecting a child requires its real glass menu to be mounted, then follows the production selection/exit transaction before the chip title changes. Explicit close uses the accessibility close callback; pointer exit retains its delayed dismissal. Filter-bar scrolling uses the mounted SwiftUI scroll view. A retiring registration cannot remove another view's callbacks.

The [Overview chaos guide](../../../../../tools/native-interaction/OVERVIEW.md) describes the actions and coverage limits. The [real app runner](../../../../../tools/verification/overview-interaction/README.md) creates actual directories, a symlink and a Git linked worktree, seeds an exclusively owned profile before launch, then drives the signed production Release app. Runtime `state:load` supplies the independent scope/membership oracle; mounted card identities, placement cells and camera bounds supply rendering invariants. No tag CRUD or multi-selection actions are invented: those controls do not exist in the current Overview.

The [layout comparison](../../../../../tools/verification/overview-layout/README.md) compiles baseline/current production geometry and reports screen displacement, visible fill, complete cards and solver work. Native capacity tests additionally assert same-footprint solver avoidance, deletion/refill screen anchors, automatic insertion framing without a background click and manual-pan retention in both motion settings. Insertion checks use actual rendered frames for one-to-two and six-to-seven cards, including footprint growth before the refit and coalesced Runtime revision history, wait through delayed refits, and verify that explicit return to automatic framing has no further correction to make.
