# Native reading lifecycle

The [native package guide](../app/macos/README.md) defines reader policy across
Codex, Claude, Pi and OpenCode. The [WindowNavigation guide](../app/macos/Sources/Host/WindowNavigation/README.md)
owns route and return admission; [PluginUI](../app/macos/Sources/Shared/PluginUI/README.md)
owns shared reading components. These are source-backed contracts; no mounted
correctness replay is configured in this source tree.

## Content and execution identity

Agent detail displays settled assistant replies and compact ordinary follow-up
text/time rows. Initial/internal user input, plans and ordinary info/warning
notices do not appear. Pending permissions/questions and independent errors remain
readable. Unfinished assistant bodies stay hidden until the message settles.
Running/waiting executions retain settled replies; terminal executions retain the
last non-error reply and an explicitly targeted reply outside work summaries.
Intermediate replies and failed tools remain execution work. Agent detail shows
reasoning/tool-count summaries, not nested commands, reasoning bodies or tool
diagnostics; other conversation surfaces retain their disclosure policy.
Empty no-output bookkeeping does not create a visible execution summary.

Current and historical documents resolve the title and author for their exact
execution. Missing historical titles use its instruction or timestamp, never the
mutable current Thread title. Outgoing and incoming title/author ink follows the
same vertical document ownership. Deferred data and optional detail loaders update
at one stable renderer site so loader availability does not replace the reader.

Source: [ThreadConversation](../app/macos/Sources/Shared/PluginUI/Conversation/ThreadConversation.swift),
[execution groups](../app/macos/Sources/Shared/PluginUI/Conversation/ThreadExecutionGroups.swift),
[Harness host](../app/macos/Sources/Host/HarnessHost/NativeHarnessThreadSurface.swift).

## Reading palette

Agent reading uses the shared thread palette: dark canvas `#232323`, surface
`#2b2b2a`, strong surface `#333331`, text `#d4d3cf` and strong text `#eeeeec`.
SwiftUI and AppKit/TextKit resolve the same palette; status, contrast and Reduce
Transparency keep their own rendering boundaries. Source: [NativePalette](../app/macos/Sources/Shared/PluginUI/Design/NativePalette.swift).

## Opening and return

The panel uses compositor-owned geometry and 420ms travel. Native animation-start
admits hidden preparation of an ordinary Agent reader while travel continues.
Drawing, input, accessibility, text entrance and secondary surfaces wait for
arrival and their own readiness. Source-less and non-Agent entries retain their
own mount gate. The same reader survives arrival. Both title anchors must exist;
coalesced native layout freezes actual geometry before the identity handoff.

Direct historical/result requests select their destination before the page stack
mounts. A never-visited current page need not acquire and construct its body
behind the historical page. Once visited, current/history scroll ownership stays
with that reader. Late anchors respect `userPositioned`; a new explicit request
starts a new positioning identity.

Closing retains the native return: reader ink fades over the first 80%, shell
travel reaches the refreshed source at 86%, and the final 14% crossfades to card
content. Closing before primary admission uses the opening-reversal path.
A deleted/archived source supplies no stale return target. Route/generation
identity fences all preparation and completion callbacks.

The reading parent uses the window's existing material, without capturing the
Overview bitmap. It keeps the native Overview owner and hides its host after
entry. Hiding is deferred out of `updateNSView` so AppKit focus handoff does not
reenter SwiftUI layout. Showing is synchronous during return preparation.
Hidden display projection/layout coalesces dirty state while the authoritative
catalog, membership, selection, drafts and task work continue. Return installs
current content and viewport, waits for canvas preparation, then samples its frame.

Source: [page stack](../app/macos/Sources/Shared/PluginUI/Conversation/NativeReadingPageStack.swift),
[parent](../app/macos/Sources/Shared/PluginUI/Conversation/NativeReadingParentSurface.swift),
[return](../app/macos/Sources/Shared/PluginUI/Conversation/NativeReadingPanelReturn.swift).

## Data and native layout

Route prefetch uses the production manifest and at most one Harness-owned opaque
row scope. Host code does not parse a Harness timeline to invent that scope.
The Runtime client retains at most four ready idle live subscriptions for 30s,
with an 8MiB accounting budget. Idle wires continue processing patches. Pending,
failed, stale, gapped or oversized resources do not transfer. Releasing a consumer
retires its ID immediately; transfer gives the wire a fresh owner. The cache
owns data, never views, actions, scroll state, selection or Sidecards.

Changed opaque state validates/decodes off main. Same-thread prepared inputs and
state publish together; changing Thread starts a new admission. Native text and
AppKit mounting remain main-actor work. Read-only transcript views disable
Writing Tools. Finite parent width/height proposals are answered directly by
native carriers; unspecified proposals retain native sizing. Timeline geometry
has a narrow observation owner; precise scroll offsets are neither throttled nor
used to invalidate the entire parent timeline.

Source: [retention](../app/macos/Sources/Core/RuntimeReadingRetention.swift),
[timeline](../app/macos/Sources/Shared/PluginUI/Conversation/ThreadTimeline.swift),
[transition](../app/macos/Sources/Shared/PluginUI/Conversation/NativeReadingPanelTransition.swift).

## Report and execution Sidecards

Report commits folded layout, matching HTML query revision and WebKit main-frame
completion before related-card admission. Primary travel and layout must also
finish; a cancellable 200ms admission interval starts after readiness. WebKit
`didFinish` does not certify all later scripts/assets. Covering, replacing or
closing retires that visit. The stable Report route remains exempt from composer
suppression during selected-execution handoff.

List state uses a 3:7 Sidecard-to-Report ratio; exact execution detail uses 5:5,
subject to shared width/stacking constraints. HTML stays mounted, anchored left,
and its viewport follows shell width continuously. A selected execution waits for
scoped content and Markdown readiness, then fades one retained host over 200ms.
Hidden controls/accessibility cannot act. Streaming/retry does not replay the
entrance; unavailable/error content admits as readable content.

Report continuation keeps the Report, shell, column and resident composer in
place. A successor execution enters from below as the old viewport moves up;
same-execution steer keeps reader and scroll. The Back button stays outside the
carrier and returns to the list. Exact forks and uncertain receipts retain the
[Runtime](../internal/core/runtime/README.md) and [client](../app/macos/Sources/Core/README.md)
authority boundaries. No guessed resend follows an uncertain outcome.

On ordinary execution completion, the active Sidecard folds to its real launcher
using the shared 380ms fold. Fold completion and destination-content readiness
are independent gates; only when both finish does the 420ms downward page turn
start. Late content keeps the old main reader visible with the Sidecard folded.
Outgoing width is retained; the incoming reader lays out at destination width.
Handoff/execution identity fences cancellation, coverage, replacement and resize.
These transitions do not request editor focus.

Source: [Report presentation](../app/macos/Sources/Shared/PluginUI/Conversation/NativeReportSidecardPresentation.swift),
[execution scroll](../app/macos/Sources/Shared/PluginUI/Conversation/NativeReportExecutionScroll.swift),
[Agent workspace](../app/macos/Sources/Host/Sidecards/NativeAgentThreadWorkspace.swift).
