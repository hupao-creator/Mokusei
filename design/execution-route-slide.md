# Report execution continuation slide

The supplied 8.745s recording (`录屏2026-11-05 18.23.34.mov`) starts with Report
HTML on the left and its selected referenced execution on the right. Sending
`test` from the resident input replaces that Report route with an Agent route:
the previous execution is now the main document, and the new execution occupies
the right Conversation Sidecard. The recording contains an empty full-width
reading shell between those states. This request concerns that accepted-send
navigation, rather than the separate terminal-execution completion handoff.

`NativeWorkspacePresentation.finishExecutionSendNavigation` preserves its existing
receipt, catalog, route, exact-reference and composer-generation guards. After
opening the accepted destination, it requests motion for that destination route
UUID only when the source was a Report. No dispatch, fork, draft, cancellation,
reading target or Sidecard eligibility policy changes.

`NativeExecutionRouteSlide` wraps the production reading front in a native seat inside the
existing outer reading stack. On the requested route change it keeps the actual outgoing hosting tree,
including WebKit, while mounting the new production Agent workspace at its final
viewport size. The existing `readingEntranceAdmitted` signal acknowledges main
content reveal, auxiliary layout and Dock travel. Until then the old surface
covers preparation. After a native layout commitment, Core Animation moves the
old workspace left and the entire new double-card workspace in from the right,
using equal full-viewport distances and the shared 420ms replacement curve.
Neither card gets an independent offset or a width interpolated during travel.
The resident Dock remains outside the moving seat. The outer stack supplies a
stable container identity for this host; document route identities remain inside
the host. There is only one outer reading stack and one motion/Close owner.

Landing discards only the outgoing host; the new reader's host, scroll models
and content remain mounted. Subsequent catalog/streaming revisions cannot replay
a route change. Async start and completion are fenced by a local generation;
replacement navigation and dismantling invalidate that generation. Reader
interaction, pointer and accessibility gates exclude preparing/travelling
surfaces. Old route callbacks retain their existing visit fences. Reduced Motion
and inactive/covered scenes remove travel while retaining the preparation cover
until ready; changing policy during travel or resizing settles immediately.

## Sprint validation boundary

The supplied recording was decoded through AVFoundation and its before, empty
intermediate and destination frames inspected. This is evidence of the reported
behavior before this change, not evidence of the new rendered animation.

Per the user's Sprint scope, no tests were added, compiled or run, no replay or
manual application scenario was executed, and no remote PR/CI was requested.
Validation uses source review, diff/static checks and a native `Mokusei` product
build. The changed rendered motion has **not** been visually verified. Real
WebKit/native surface retention, focus behavior, narrow/stacked layouts, rapid
navigation, accessibility policy changes and resize during travel remain runtime
verification limits. Build success does not certify those visual behaviors.

The detached commit is supplied for caller-owned integration into local main.
