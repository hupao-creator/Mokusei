# Native Markdown layout

[PluginUI](../app/macos/Sources/Shared/PluginUI/README.md#reading-and-execution-disclosure)
owns the renderer. Parsing uses the pinned swift-markdown/cmark dependencies in
[Package.swift](../app/macos/Package.swift); source positions preserve raw UTF-8
identity, including normalization-distinct text, container prefixes and tables.

## Width and native views

Native paragraph wrapping uses its proposed width without asking TextKit for a
second fitted size. Layout and placement share layout-local child measurements;
list markers, quote rules and footnote numbers have fixed leading slots. RTL
mirroring remains SwiftUI-owned. Settled top-level blocks use a lazy stack near
the viewport; footnoted documents keep anchors mounted and exposure-tracked notes
retain exact geometry. Nested lists/quotes, tables and code keep their own width
contracts. There is no cross-document height cache or shared native-view/selection
registry. Parse and content caches keep their own immutable input identities.

Code is unwrapped in a native horizontal code viewport. The viewport owns its
scroller and intrinsic content width so the tail remains reachable; the outer
page does not provide code scrolling. The document, native clip and copy action
retain the complete source. A stored reply containing obsolete commands is still
rendered literally; displaying text does not make those commands runnable.

Source: [Markdown view](../app/macos/Sources/Shared/PluginUI/Reading/NativeMarkdownView.swift),
[text](../app/macos/Sources/Shared/PluginUI/Reading/NativeMarkdownText.swift),
[code viewport](../app/macos/Sources/Shared/PluginUI/Reading/NativeMarkdownCodeViewport.swift),
[source map](../app/macos/Sources/Shared/PluginUI/Reading/NativeMarkdownSourceMap.swift).

## Admission and replacement

A parsed document and its readiness token publish together. Newer revisions,
including empty replacement, supersede pending parse results; disappearance
cancels the worker. Stable message/native host identity survives settlement and
optional detail-loader arrival. Complete replies appear only after settlement.

Read-only transcript TextKit views disable Writing Tools. Width/scale measurement
caches are bounded per input revision; native execution-link roots change only
when their actual attachment, selection, locale or appearance inputs change.
Action callbacks read their current owner rather than retaining obsolete closures.

No native Markdown correctness replay is configured in this source tree. The [external reading benchmark](../tools/benchmarks/reading/README.md)
observes body checkpoints and scrolling with explicit capture bounds; it does not
certify all Markdown syntax, native selection/copy or physical frame pacing.
