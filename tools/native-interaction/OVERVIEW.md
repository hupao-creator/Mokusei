# Overview semantic controls

These actions use the existing opt-in, same-user Unix socket. They do not add an
endpoint or enable automation by default. Build provenance and isolated-profile
requirements are in the [production runner](../verification/overview-interaction/README.md).

| Action | Fields | Production implementation |
| --- | --- | --- |
| `filter.select` | `filterId` or null | `NativeOverviewWorkspaceModel.selectTag`, shared with tag buttons/context menus |
| `overview.filters.scroll` | top-level `filterId` | Mounted SwiftUI filter-bar `ScrollViewProxy.scrollTo` |
| `overview.directory.open` | `directoryId` | Visible directory control's `revealChildren`, also used by hover/accessibility |
| `overview.directory.select` | `directoryId`, child `filterId` | Mounted glass child button's callback, scope guards and selection-driven menu exit |
| `overview.directory.close` | `directoryId` | Native accessibility close callback and its glass exit transaction |
| `overview.pan` | `deltaX`, `deltaY`, each ±10,000 points | Production camera pan, shared with canvas navigation |
| `overview.zoom` | `delta` within ±1,000; `x`, `y` within 0–1 | Production camera zoom at a normalized viewport anchor |
| `overview.auto` | none | Toolbar/context-menu return to automatic framing |
| `overview.retry` | none | The existing layout error banner's refresh/retry operations; available only on error |
| `moku.input.toggle` | none | Existing Compose command's capsule input state |
| `moku.history.toggle` | none | Existing Moku command/context-menu history toggle |
| `moku.note.toggle` | none | Existing Moku Note command and its route admission |

`search.begin/update/end`, `thread.open`, `navigation.back` and Settings navigation
remain available through the shared protocol. Missing/stale directory controls
are rejected; selecting a child before its menu mounts is `unavailable`. Callers
should first scroll a clipped directory into view, open it, then observe its ID in
`overview.menu.mountedMenuIds`. A successful action acknowledges intent, not a
completed animation or rendered frame.

Selecting a child closes the submenu. The parent chip retains its existing title
until the production glass exit completes, then displays `directory / child`.
The runner waits for both the requested filter state and menu unmount, then
scrolls/reopens and waits for the real menu before selecting another child. Wrong
child tests reopen first; closed-menu tests deliberately remain closed. Random
candidates exclude retiring menus whose scope is no longer open. These waits use
mounted state rather than fixed animation sleeps.

`snapshot.overview` includes hierarchical filters with explicit `kind`, `scope`,
raw tag, display label, aliases and children; visible card refs and directory
metadata; actual mounted card/menu IDs; grid placements; camera transform,
readable scale limits, viewport and motion state; and Moku capsule route state.
Camera completion is explicit: `motionPending` includes queued reservations and
refits before a track exists; `automaticFitPending` stays true until an explicit
fit completes; `automaticFitBlocked` reports hidden-window, interaction or layout
deferral; `automaticFitTarget` is the production camera's current fit target.
`manual: false` alone does not mean automatic fitting has been applied.
The hierarchy is the source for discovering targets. The compatibility top-level
`filters` list remains flattened for the navigation client.

The dedicated runner waits for actual layout/motion and mounted-card agreement,
then checks scope membership against public Runtime state, cell non-overlap,
camera limits and control postconditions. Its seeded random phase mixes these
controls after a deterministic full-coverage smoke sequence. Every seed gets a
fresh profile and real filesystem fixture, with an incremental trace and coverage
counts; an unexpected assertion or rejection fails the run.

Run GUI acceptance scenes sequentially, or keep every tested app window visible
when using parallel processes. An occluded/hidden window can intentionally pause
the native camera, even though its socket remains responsive. Separate profiles
and sockets prevent data interference but do not provide independent desktops.
The runner waits for the real fit to finish and match its target; an unexpected
visibility blocker is reported as a timeout with the camera state. It never
pretends that deferred fitting has completed. The one intentional pending-fit
case is the smoke test that keeps Compose open, verifies the interaction blocker,
then closes Compose and waits for the fit to apply.

## Coverage matrix

| Feature | Covered behavior |
| --- | --- |
| Directory tags | Ordinary paths, same basename in different parents, nested independent scopes, Unicode/spaces, symlink canonicalization, real Git linked-worktree folding, temporary-workspace Inbox suppression |
| Semantic tags | Parent/child membership, same tag name in different scopes, single-member tags, separate tags with equal membership, count and archive exclusion |
| Directory glass menu | Filter-bar scroll, actual menu mounting/opening, every child callback, selection-driven close/reopen, explicit close, closed-menu and wrong-child rejection |
| Search | Empty/nonempty/Unicode/no-match queries, current-scope intersection, clear/exit, manual camera restoration; observed keyword/hybrid mode |
| Canvas | Pan, zoom/clamping, return to automatic view, deferred fit while Compose is open, finite transforms, readable scale bounds, actual mounted cards, stable non-overlapping placement cells |
| Cards/navigation | Open each seeded conversation and return; retained Overview state |
| Moku Dock | Compose open/close, history open/close, note open/close, route guards |
| Persistence | Independent public Runtime metadata before/during/after browsing; no unintended durable thread edits |

Current Overview has no tag create/bind/rename/remove controls, card multi-select,
pin/rename/archive context menu, layout-mode chooser, or manual search-mode
selector. Directory tags are derived from working directories; keyword/hybrid
mode is Runtime-owned. Archive restoration belongs to Settings. These are not
reported as tested features.

Task dispatch, interrupting real work, permission responses, credential changes,
installation, microphone/voice calls, attachment imports, OS directory/file
pickers and external-link/Git-opening effects are excluded from this browsing
runner. Physical pointer hit-testing, scroll-wheel routing, gestures, glass
pixels and accessibility announcements require their native/UI visual replays;
the semantic runner does not claim to cover them. Layout retry is exposed but
requires an actual layout failure and is not counted as covered by a passing
fixture run.
