# Native Markdown layout

[PluginUI](../app/macos/Sources/Shared/PluginUI/README.md#reading-and-execution-disclosure)
owns the renderer. Parsing uses the pinned swift-markdown/cmark dependencies in
[Package.swift](../app/macos/Package.swift); source positions preserve raw UTF-8
identity, including normalization-distinct text, container prefixes and tables.

## Width and native views

Native paragraph wrapping uses its proposed width without asking TextKit for a
second fitted size. Layout and placement share layout-local child measurements;
list markers, quote rules and footnote numbers have fixed leading slots. RTL
mirroring remains SwiftUI-owned. A settled reply of up to 24 top-level blocks
uses measured heights throughout. Long replies in a Thread timeline, including
a Super Thread's related-execution reader, mount the first 12 blocks together.
The remaining sections reserve space at the reading width until they come
within one viewport of the visible area. Each then takes its measured height
and keeps its native views for the visit. The scroll extent can adjust on first
entry into a section or on reflow. Returning to a section preserves its layout
and block-local text selection.

Standalone documents, exposure-tracked notes and footnoted replies use the
fully measured column. Footnote destinations and return anchors stay mounted.
Lists, quotes, tables and code fences keep their internal width and selection
rules. A single large block is laid out as a unit. Streaming retains its own
page admission policy. Measurement and admission state belong to the current
view. Parse and content caches keep their own immutable input identities.

Code is unwrapped in a native horizontal code viewport. The viewport owns its
scroller and intrinsic content width so the tail remains reachable; the outer
page does not provide code scrolling. The document, native clip and copy action
retain the complete source. A stored reply containing obsolete commands is still
rendered literally; displaying text does not make those commands runnable.

The [Markdown view](../app/macos/Sources/Shared/PluginUI/Reading/NativeMarkdownView.swift)
composes [reading sections](../app/macos/Sources/Shared/PluginUI/Reading/NativeMarkdownReadingSections.swift),
[native text](../app/macos/Sources/Shared/PluginUI/Reading/NativeMarkdownText.swift)
and the [code viewport](../app/macos/Sources/Shared/PluginUI/Reading/NativeMarkdownCodeViewport.swift).
The [source map](../app/macos/Sources/Shared/PluginUI/Reading/NativeMarkdownSourceMap.swift)
preserves byte positions during parsing.

## Admission and replacement

A parsed document and its readiness token publish together. Newer revisions,
including empty replacement, supersede pending parse results; disappearance
cancels the worker. Stable message/native host identity survives settlement and
optional detail-loader arrival. Complete replies appear only after settlement.

Read-only transcript TextKit views disable Writing Tools. Width/scale measurement
caches are bounded per input revision; native execution-link roots change only
when their actual attachment, selection, locale or appearance inputs change.
Action callbacks read their current owner rather than retaining obsolete closures.

The [local sidebar replay](../tools/e2e/README.md#super-thread-reading-regression)
exercises scroll reversals and native selection in a referenced execution. The
[external reading benchmark](../tools/benchmarks/reading/README.md) observes
body checkpoints and scrolling with explicit capture bounds. Full syntax,
clipboard fidelity and physical frame pacing require separate evidence.
