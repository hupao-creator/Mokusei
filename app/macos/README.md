# Native macOS application package

[Package.swift](Package.swift) builds the macOS application and its Swift modules. SwiftUI presents shared UI/state, with AppKit handling native text, input and window behavior.

App-owned viewports use the
[trackless scrollbar policy](Sources/Shared/PluginUI/README.md#scrollbars);
Report HTML uses thin, trackless WebKit scrollbars. External Browser pages and
embedded external frames retain their own styles.
AppKit controls retain scrolling, drag tracking and accessibility; transient
hiding follows system preferences. AppKit-owned viewports reserve a persistent
native gutter; SwiftUI-owned viewports retain SwiftUI's indicator visibility and
gutter measurement, with a persistent knob whenever scrolling is possible.

| Location | Responsibility |
| --- | --- |
| Sources/App | Mac application entry, windows and application lifecycle |
| [Sources/Composition](Sources/Composition/NativePlugins.swift) | Shared static Harness, Application and Sidecard registration |
| [Sources/Core](Sources/Core/README.md) | Protocol, connections, public state, host files and offline recovery |
| [Sources/Host/Overview](Sources/Host/Overview/README.md) | Layout, camera, selection, filtering and search |
| [Sources/Host/MokuScene](Sources/Host/MokuScene/README.md) | Moku Dock, history composer, Talk, dispatch and notes |
| [Sources/Host/Onboarding](Sources/Host/Onboarding/README.md) | First-run admission, role configuration and handoff into the Moku Dock |
| [Sources/Host/Settings](Sources/Host/Settings/README.md) | Settings drafts, validation and autosave |
| [Sources/Host/WindowNavigation](Sources/Host/WindowNavigation/README.md) | Window controls and reading navigation |
| [Sources/Host/Interaction](Sources/Host/Interaction/README.md) | Typed workspace actions and observable state for script-driven interaction |
| [Sources/Host/Git](Sources/Host/Git/README.md) | Built-in worktree facts and native diff reader |
| [Sources/Shared/PluginAPI](Sources/Shared/PluginAPI/README.md) | Public presentation/capability contracts |
| [Sources/Shared/PluginUI](Sources/Shared/PluginUI/README.md) | Reading, forms, composer, cards and design resources |
| Sources/Plugins/Harnesses | Codex, Claude, Pi and OpenCode projections and views |
| Sources/Plugins/Applications | Report and Tag native contributions |
| [Sources/Plugins/Sidecards](Sources/Plugins/Sidecards/README.md) | Conversation, browser and read-only voice discussions |
| [Sources/Voice](Sources/Voice/README.md) | Native media, WebRTC and ownership |

Agent Thread detail admits assistant replies and execution records: reasoning,
tools/activities, approvals/questions, review, context compaction, background work,
execution status, author and usage. Errors are exempt from the content allowlist:
explicit error records, error-level notices, failed assistant messages and
execution failures remain readable, including after completion and with work collapsed.
Input messages (user, developer/system), ordinary info/warning notices and plan
timeline entries are excluded. History headings and sidebar labels use the title
stored for their exact execution, with the execution timestamp when no reliable title is available.
Thread title/emoji remain catalog metadata; the current title is never used to
fill missing historical titles.

This is a native reader policy shared by Codex, Claude, Pi and OpenCode across
live, loaded historical, inherited/fork and deferred execution content (including
OpenCode child sessions). Canonical history, transport, Overview, Moku, search
and other conversation surfaces retain their data and policies. Adjacent
execution entries remain grouped across hidden entries. Running/waiting
executions retain settled assistant replies and existing streaming disclosure.
After termination, intermediate ordinary replies belong to summary-only execution
work; only the last non-error reply, independent errors, pending interactions
and an explicitly targeted reply remain separate from summaries.
Failed tools remain execution work: hiding work hides their rows and diagnostics
as well. Showing execution work in Agent Thread detail displays only the shared
reasoning/tool-count summary and reported reasoning usage. Tool-group titles
(such as Used tools), Hooks, commands, reasoning bodies and failed-tool
diagnostics are execution details and never mount here; deferred detail content
is not acquired. This applies while running, streaming, waiting for an interaction
and after completion; pending permissions/questions remain actionable.
Background terminal/task sections expose only static counts
and status, without commands, task descriptions or disclosures; hiding work
hides those summaries too. Other conversation surfaces retain full execution disclosure.
Failure status does not create another execution boundary or an independent
error message.
OpenCode child sessions retain independent assistant errors without revealing
their sibling tools, even when execution summaries are visible. Lightweight
Pi/OpenCode history retains interim
reply data for explicit message visits without loading execution detail; the
reader applies the same terminal-execution policy to live settlement, loaded
history and inherited turns. Repeated native tool references render
once by identity; separate calls with equal labels or output remain separate.
See the [terminal reply investigation](../../design/terminal-assistant-disclosure.md)
for the regression source, verification scope and remaining limits.

Panel opening uses compositor-owned geometry. Ordinary Agent card readers start
hidden preparation after native animation-start delivery, overlapping travel;
content drawing, input, accessibility, text entrance and secondary surfaces wait
for arrival. Source-less and non-Agent entries keep their existing mounting gate.
Once submitted, panel travel no longer waits for main-actor animation ticks;
reader mounting can still occupy the main thread.
Data-only route prefetch overlaps content acquisition with travel; a bounded
short-lived cache transfers continuously subscribed ready data between readers.
Codex reader admission validates/decodes changed opaque state off the main actor,
reuses only exact immutable inputs and skips construction of collapsed work rows.
Read-only transcript TextKit views disable Writing Tools. Reader/view, history
requests and scroll state remain scoped to their existing lifetimes. See the
[loading/cache investigation](../../design/thread-loading-performance-cache.md). Native
content and error admission policies remain owned by their existing boundaries.
See the [manual investigation](../../design/thread-open-animation-investigation.md)
for evidence and the limits of the isolated measurements.

New shared features register once through `NativePlugins.make()`. Platform-specific capabilities live behind their declared interfaces rather than a second copy of the page or plugin tree. [Build and packaging](build/README.md) describes Mac requirements and commands. Functional tests live under `Tests`; executable cross-language/native replays live in [tools/verification](../../tools/verification/README.md).

`make check` runs the complete `swift test` suite as well as building it. Native
integration suites share the [test environment](Tests/Support/README.md) to isolate
AppKit and main-actor timing across test targets. Tests requiring a WindowServer
session and display visibly skip when those capabilities are absent; fixture-gated
Go/native replays also print their required launcher. A green headless run does
not certify those skipped UI or cross-language flows. The [Swift test audit](../../tools/verification/swift-tests/README.md)
records the failure/skip inventory and reproduction commands.
Hosted macOS CI now runs graphical tests and the Go/AppKit fixture launchers,
rejecting unexpected skips. Its current-revision results replace equivalent
local runs under the [verification policy](../../scripts/ci/verification-policy.md).
[Windowless execution](../../scripts/ci/headless.md) runs reviewed whole suites
before the graphical remainder in ordinary CI/local checks. Its independent
developer command uses the same registry without replacing hosted native coverage.

Workspace startup and Dock presence are narrow observable facts. `hasSnapshot`
changes only when the workspace snapshot becomes present/absent, and the catalog
publishes `hasMoku` only when Moku is added or removed. `hasInitialContent` derives
from those two booleans, so payload updates do not invalidate startup/overview
ancestors and direct catalog installations retain the same presence semantics.
Offline and shutdown paths keep the last admitted snapshot as before.

The application, runtime-exit helper and Probe enter the shared
[native profile lease](Sources/Core/RuntimeProfileClientLease.swift) boundary
before retaining any profile-local state. Fresh rotation uses the same
cross-process admission and lifetime locks; offline preferences and drafts
therefore remain protected independently of the runtime service's ownership.

Quit remains available during Reload and never requires successful runtime or voice cleanup. It gives local cleanup up to three seconds before requesting process exit; a second Quit skips pending application/drain waits while admitting the Runtime cleanup helper. Errors go to profile diagnostics, and the existing epoch-fenced exit helper continues cooperative service cleanup. Workspace teardown releases local clients even when service shutdown reports an error. Reopening waits for a retiring service and starts a fresh owner without clearing saved data.
Once exit is accepted, diagnostic writers drain asynchronously under a separate
750ms background deadline; a slow writer cannot hold process exit indefinitely.
Timeout can lose the diagnostic tail and is reported through unified logging.
A second Quit enters ordinary exit so atexit waits for the actual helper launch;
the independent deadline still forces exit if launch, logs or exit handlers
block. It does not merely enqueue a helper immediately before `_exit`.

Before Runtime teardown, Quit flushes pending valid Settings edits. Invalid or
failed saves expose an explicit continue-editing or quit-without-saving choice.
The View menu routes Reload and Zoom through the focused Browser/Report document
before changing the workspace. App zoom persists levels bounded to 0.25×…5×,
so the first reverse step at either limit changes the visible scale.


Agent panels now carry source title/emoji ink separately during deferred opening,
show a scoped skeleton while loading, and reveal admitted native text top-down
for completed executions or bottom-up for active executions. A per-execution
presentation scope protects first paint and releases masks on change/cancellation.
Closing retains the 420ms native return: reader content fades over the first
80%, travel reaches the source card at 86%, and the shell crossfades to the
refreshed card over the final 14%. See the shared PluginUI and WindowNavigation
documentation for lifecycle boundaries and the production fixture command.
