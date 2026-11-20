# Native motion and admission

Opening a Report from Overview or the [Super Thread member grid](../app/macos/Sources/Host/Overview/README.md#viewed-application-collections)
uses one native panel transition. The panel opens from the activated card and
returns to the card in the originating surface. The reader can show its usual loading state.
A Chief Note link closes the Note before Overview reveals its destination.
If the active filter excludes the destination, Overview selects a matching
filter. A grouped Report turns to the requested page before the reader opens.
The settled card uses its ordinary 420ms opening, including the Agent card’s
identity handoff when its anchors are available. The Report
admits the cited execution after its document and sidebar layout are ready.
The bottom Chief Dock opens and closes its Overview input over 420ms,
carrying the eyes and Stop button with the shell. [Dock and composer](../app/macos/Sources/Host/MokuScene/README.md#dock-and-composer)

Application-owned animations use their authored curves and completion gates.
Visibility, focus, occlusion, offscreen state, explicit pause, drag/resize and
performance gates govern when motion runs. Reduce Transparency and Increase
Contrast govern appearance. Keyboard navigation and accessibility semantics
follow the active controls.

The [PluginUI guide](../app/macos/Sources/Shared/PluginUI/README.md#motion-and-materials)
owns decorative rendering and reading carriers. Native panel/ink travel uses
Core Animation after admission; native main-thread layout can still delay
preparation, mounting and callback delivery. A scheduled tick, display-link
callback or GPU submission is not evidence of physical presentation or FPS.

The Overview Metal renderer receives immutable inputs and encodes on its serial
queue. Visibility retirement stops production; unchanged static fields stop
requesting work. Native status decorations use their own admitted motion clock.
Their completion/lifetime owners are distinct from task execution. Bounded
resource caches invalidate on actual input changes, not arbitrary redraws.

Source: [cloud renderer](../app/macos/Sources/Shared/PluginUI/Design/NativeOverviewCloudRenderer.swift),
[panel transition](../app/macos/Sources/Shared/PluginUI/Conversation/NativeReadingPanelTransition.swift),
[reading return](../app/macos/Sources/Shared/PluginUI/Conversation/NativeReadingPanelReturn.swift).

The reading parent's hide operation is deferred beyond `updateNSView` to avoid
AppKit key-view traversal reentering an active SwiftUI layout graph. A cancelled
or replaced route cannot hide its successor. Showing remains synchronous for
return preparation; keyboard/focus behavior is not disabled to hide warnings.
See [parent surface](../app/macos/Sources/Shared/PluginUI/Conversation/NativeReadingParentSurface.swift).

No main-thread-hold decoration or native transition correctness replay is
configured in this source tree. External pixel/resource benchmarks
report capture uncertainty and capability limits separately from product outcome.
