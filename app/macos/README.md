# Native macOS application package

[Package.swift](Package.swift) builds the macOS application and its Swift modules. SwiftUI presents shared UI/state, with AppKit handling native text, input and window behavior.

App-owned viewports, Browser frames and Report HTML share the
[trackless scrollbar policy](Sources/Shared/PluginUI/README.md#scrollbars).
Native controls retain scrolling, drag tracking and accessibility; transient
hiding follows system preferences, and persistent modes reserve their native
gutter at every content height and keep a knob whenever scrolling is possible.

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

Quit remains available during Reload and never requires successful runtime or voice cleanup. It gives local cleanup up to three seconds, then exits; a second Quit exits immediately. Errors go to profile diagnostics, and the existing epoch-fenced exit helper continues cooperative service cleanup. Workspace teardown releases local clients even when service shutdown reports an error. Reopening waits for a retiring service and starts a fresh owner without clearing saved data.

Before Runtime teardown, Quit flushes pending valid Settings edits. Invalid or
failed saves expose an explicit continue-editing or quit-without-saving choice.
The View menu routes Reload and Zoom through the focused Browser/Report document
before changing the workspace. App zoom persists levels bounded to 0.25×…5×,
so the first reverse step at either limit changes the visible scale.
