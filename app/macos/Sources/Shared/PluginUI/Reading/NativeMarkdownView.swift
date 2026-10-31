import AppKit
import Combine
import MokuseiCore
import MokuseiPluginAPI
import SwiftUI

public struct NativeMarkdownAppliedDocument: Equatable, Sendable {
    public let token: String
    public let coverageEligible: Bool
}

/// Native conversation/document Markdown. Hosts supply their external navigation
/// and attachment resolver; plain Markdown never creates a browser view.
public struct NativeMarkdownView: View {
    public let text: String
    // SwiftUI compares stored inputs before evaluating body. String equality
    // alone can suppress a raw Unicode replacement before the task ID is read.
    private let sourceBytes: Data
    public var streaming: Bool
    public var fontSize: CGFloat
    public var muted: Bool
    public var openExternal: ((URL) -> Void)?
    public var openExecution: ((ApplicationExecutionRef) -> Void)?
    public var resolveMedia: NativeMarkdownMediaResolver?
    public var documentToken: String?
    public var onDocumentApplied: ((NativeMarkdownAppliedDocument?) -> Void)?
    @Environment(\.nativeMarkdownMediaResolver) private var environmentMediaResolver
    @Environment(\.nativeReadingPageCapacity) private var pageCapacity
    @StateObject private var model = MarkdownViewModel()
    @State private var hasStreamed = false
    @Environment(\.nativePerformanceOperation) private var performanceOperation

    public init(text: String, streaming: Bool = false, fontSize: CGFloat = 16,
                muted: Bool = false, openExternal: ((URL) -> Void)? = nil,
                resolveMedia: NativeMarkdownMediaResolver? = nil,
                openExecution: ((ApplicationExecutionRef) -> Void)? = nil,
                documentToken: String? = nil,
                onDocumentApplied: ((NativeMarkdownAppliedDocument?) -> Void)? = nil) {
        self.text = text; self.sourceBytes = Data(text.utf8); self.streaming = streaming
        self.fontSize = fontSize; self.muted = muted; self.openExternal = openExternal
        self.resolveMedia = resolveMedia; self.openExecution = openExecution
        self.documentToken = documentToken; self.onDocumentApplied = onDocumentApplied
    }

    public var body: some View {
        let actions = model.actions
        actions.openLink = { url in
            if url.scheme?.lowercased() == "mokusei" {
                if let reference = ApplicationExecutionLink.parse(url) { openExecution?(reference) }
            } else { (openExternal ?? { MarkdownPlatformActions.open($0) })(url) }
        }
        actions.resolveMedia = resolveMedia ?? environmentMediaResolver
        let media: NativeMarkdownMediaResolver?
        if actions.resolveMedia == nil { media = nil }
        else { media = { try await actions.loadMedia($0) } }
        let options = MarkdownViewOptions(
            fontSize: fontSize, muted: muted,
            openLink: actions.open, resolveMedia: media,
            anchorPrefix: model.anchorPrefix, actions: actions)
        return Group {
            if pageCapacity != nil, streaming || hasStreamed {
                // Page-level streaming keeps the open page invisible until it
                // cannot accept another block. The view owns its own settled
                // blocks because the ordinary parser deliberately stays idle
                // while a message is still growing.
                NativeStreamingPagedMarkdown(text: text, streaming: streaming,
                                             fontSize: fontSize, options: options)
            } else if streaming {
                // One literal span preserves native selection/copy without
                // parsing Markdown, constructing blocks or resolving media.
                MarkdownSelectableText(spans: [MarkdownSpan(text: text)], fontSize: fontSize,
                    muted: muted, selectionScope: model.anchorPrefix, openLink: actions.open)
            } else {
                MarkdownContent(blocks: model.blocks, options: options)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            Button("复制 Markdown") { MarkdownPlatformActions.copy(text) }
        }
        .onChange(of: streaming, initial: true) { _, value in
            // Keep the paged projection mounted after completion until the
            // whole-document parse replaces its final page.
            if value { hasStreamed = true }
        }
        .task(id: MarkdownRevision(text: text, streaming: streaming, token: documentToken)) {
            model.submit(text: text, streaming: streaming, token: documentToken, context: performanceOperation)
        }
        .onChange(of: model.applied, initial: true) { _, applied in onDocumentApplied?(applied) }
        .onDisappear { model.cancel() }
    }
}

struct MarkdownRevision: Equatable {
    let text: String
    let streaming: Bool
    let token: String?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text.utf8.elementsEqual(rhs.text.utf8) && lhs.streaming == rhs.streaming && lhs.token == rhs.token
    }
}

@MainActor
private final class MarkdownViewModel: ObservableObject {
    @Published var blocks: [MarkdownBlock] = []
    @Published private(set) var applied: NativeMarkdownAppliedDocument?
    let anchorPrefix = UUID().uuidString
    let actions = MarkdownViewActions()
    private var pending: MarkdownRevision?
    private var worker: Task<Void, Never>?
    private var workerGeneration = UUID()

    func submit(text: String, streaming: Bool, token: String?, context: UInt64?) {
        if streaming {
            cancel()
            if !blocks.isEmpty { blocks = [] }
            return
        }
        pending = MarkdownRevision(text: text, streaming: streaming, token: token)
        if applied?.token != token { applied = nil }
        guard worker == nil else { return }
        let generation = UUID()
        workerGeneration = generation
        worker = Task { [weak self] in
            guard let self else { return }
            defer { if workerGeneration == generation { worker = nil } }
            while pending != nil, !Task.isCancelled {
                let measurement = NativePerformance.begin(.markdownDelivery, context: context)
                defer { measurement?.end(.cancelled) }
                do {
                    guard let next = pending else { break }
                    pending = nil
                    let document = try await NativePerformance.$context.withValue(measurement?.id ?? context) {
                        try await NativeMarkdownParser.shared.parse(next.text)
                    }
                    try Task.checkCancellation()
                    // A parser result cannot replace a newer pending revision.
                    if pending == nil {
                        if blocks != document.blocks { blocks = document.blocks }
                        // The new identity must publish even when cached or
                        // textually identical blocks reused the old view tree.
                        applied = next.token.map { NativeMarkdownAppliedDocument(token: $0,
                            coverageEligible: document.coverageEligible) }
                    }
                    measurement?.end(pending == nil ? .completed : .cancelled,
                        values: ["streaming": next.streaming ? 1 : 0, "blocks": Double(document.blocks.count)])
                } catch { break }
            }
        }
    }

    func cancel() { workerGeneration = UUID(); worker?.cancel(); worker = nil; pending = nil; applied = nil }

}

/// Completed blocks can keep their view tree while the tail changes. Their
/// callbacks route through this document-owned object so reuse never retains an
/// obsolete navigation handler or attachment resolver.
@MainActor
final class MarkdownViewActions {
    var openLink: (URL) -> Void = { MarkdownPlatformActions.open($0) }
    var resolveMedia: NativeMarkdownMediaResolver?

    func open(_ url: URL) { openLink(url) }
    func loadMedia(_ url: URL) async throws -> Data {
        if let resolveMedia { return try await resolveMedia(url) }
        return try await MarkdownMediaCache.shared.load(url)
    }
}

struct MarkdownViewOptions {
    var fontSize: CGFloat
    var muted: Bool
    var openLink: (URL) -> Void
    var resolveMedia: NativeMarkdownMediaResolver?
    var anchorPrefix: String
    var actions: MarkdownViewActions? = nil

    struct Rendering: Equatable, Sendable {
        let actions: ObjectIdentifier?
        let fontSize: CGFloat
        let muted: Bool
        let anchorPrefix: String
        let media: Bool
    }

    var rendering: Rendering {
        Rendering(actions: actions.map(ObjectIdentifier.init), fontSize: fontSize, muted: muted,
                  anchorPrefix: anchorPrefix, media: resolveMedia != nil)
    }
}

struct MarkdownContent: View {
    let blocks: [MarkdownBlock]
    let options: MarkdownViewOptions
    var compact = false
    /// The block immediately before this page in the same document. A page
    /// that starts with a heading needs it to preserve the document's seam.
    var precedingBlock: MarkdownBlock?
    /// False while more pages follow, so the last block keeps its bottom margin.
    var isFinal = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                MarkdownBlockView(block: block, options: options)
                    .equatable()
                    .padding(.top, headingMargin(block, index: index))
                    .padding(.bottom, index == blocks.count - 1 && isFinal ? 0
                        : NativeStreamingPageMetrics.bottomMargin(block, fontSize: options.fontSize, compact: compact))
            }
        }
    }

    private func headingMargin(_ block: MarkdownBlock, index: Int) -> CGFloat {
        let previous = index > 0 ? blocks[index - 1] : precedingBlock
        return NativeStreamingPageMetrics.headingTopPadding(for: block, previous: previous,
                                                            compact: compact, fontSize: options.fontSize)
    }

}

private struct MarkdownBlockView: View, Equatable {
    let block: MarkdownBlock
    let options: MarkdownViewOptions
    let rendering: MarkdownViewOptions.Rendering

    init(block: MarkdownBlock, options: MarkdownViewOptions) {
        self.block = block; self.options = options; rendering = options.rendering
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        // A standalone host without a router must receive every callback update.
        lhs.rendering.actions != nil && lhs.rendering == rhs.rendering && lhs.block == rhs.block
    }

    @ViewBuilder var body: some View {
        switch block {
        case .paragraph(let spans):
            MarkdownInlineView(spans: spans, fontSize: options.fontSize, muted: options.muted, options: options)
        case .heading(let level, let spans):
            let size = NativeStreamingPageMetrics.headingSize(level, fontSize: options.fontSize)
            MarkdownInlineView(spans: spans, fontSize: size, weight: level <= 3 ? 600 : level == 4 ? 680 : 700, strongInk: level <= 4, tracking: level <= 3 ? -0.25 : 0, lineHeight: NativeStreamingPageMetrics.headingLineHeight(level, size: size), options: options)
                .accessibilityAddTraits(.isHeader)
        case .quote(let children):
            HStack(alignment: .top, spacing: 15) {
                Rectangle().fill(NativePlatformPalette.thread.line.swiftUI).frame(width: 3)
                MarkdownContent(blocks: children, options: quoteOptions)
            }.fixedSize(horizontal: false, vertical: true).padding(.vertical, 3)
        case .list(let items):
            let markerWidth = markerWidth(items)
            VStack(alignment: .leading, spacing: items.first?.tight == false ? 14 : 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 0) {
                        Group {
                            if let checked = item.checked {
                                Image(systemName: checked ? "checkmark.square.fill" : "square")
                                    .font(.system(size: 12)).foregroundStyle(NativePlatformPalette.thread.muted.swiftUI)
                                    .accessibilityLabel(checked ? "已完成" : "未完成")
                            } else {
                                MarkdownSelectableText(spans: [MarkdownSpan(text: item.marker)], fontSize: options.fontSize,
                                    muted: options.muted, lineHeight: options.fontSize * 1.8,
                                    selectionScope: options.anchorPrefix, openLink: options.openLink)
                            }
                        }.frame(width: markerWidth, height: options.fontSize * 1.8, alignment: .leading)
                        MarkdownContent(blocks: item.blocks, options: options, compact: item.tight)
                    }
                }
            }
        case .code(_, let source):
            MarkdownCodeBlock(source: source, selectionScope: options.anchorPrefix)
        case .table(let rows, let alignments):
            MarkdownTableView(rows: rows, alignments: alignments, options: options)
        case .rule:
            Rectangle().fill(NativePlatformPalette.thread.line.swiftUI).frame(height: 1).padding(.vertical, 6)
        case .footnote(let id, let index, let children):
            HStack(alignment: .top, spacing: 0) {
                MarkdownSelectableText(spans: [MarkdownSpan(text: "\(index).")], fontSize: options.fontSize,
                    muted: options.muted, lineHeight: options.fontSize * 1.8,
                    selectionScope: options.anchorPrefix, openLink: options.openLink)
                    .frame(width: 23, height: options.fontSize * 1.8, alignment: .leading)
                MarkdownContent(blocks: children, options: options, compact: true)
            }.background(MarkdownAnchor(identifier: options.anchorPrefix + "-mokusei-footnote-" + MarkdownParser.anchorID(id)))
        }
    }

    private func markerWidth(_ items: [MarkdownListItem]) -> CGFloat {
        let font = NativeTypography.interPlatformFont(size: options.fontSize)
        return items.reduce(CGFloat(23)) { width, item in
            item.checked == nil ? max(width, ceil((item.marker as NSString).size(withAttributes: [.font: font]).width) + 6) : width
        }
    }

    private var quoteOptions: MarkdownViewOptions { var value = options; value.muted = true; return value }
}

struct MarkdownInlineView: View {
    let spans: [MarkdownSpan]
    let fontSize: CGFloat
    var weight: CGFloat = 400
    var muted = false
    var strongInk = false
    var tracking: CGFloat = 0
    var lineHeight: CGFloat? = nil
    var alignment: MarkdownAlignment = .left
    let options: MarkdownViewOptions
    @State private var images: [String: NativePlatformImage] = [:]
    @State private var imageFailure: String?

    private var anchoredSpans: [MarkdownSpan] {
        spans.map { span in
            var value = span
            if let anchor = value.anchor { value.anchor = options.anchorPrefix + "-" + anchor }
            if let link = value.link, link.hasPrefix("#mokusei-footnote-") { value.link = "#" + options.anchorPrefix + "-" + link.dropFirst() }
            return value
        }
    }

    // Probe only local links. Failed/non-image probes leave the original text
    // untouched; adjacent styled spans sharing a destination get one preview.
    private var sources: [String] {
        var seen = Set<String>()
        return spans.compactMap { span in
            let source = span.image ?? span.link.flatMap { MarkdownURLPolicy.localFileURL($0) == nil ? nil : $0 }
            guard let source, seen.insert(source).inserted else { return nil }
            return source
        }
    }

    private var displayedSpans: [MarkdownSpan] {
        var result = anchoredSpans.map { span in
            var span = span
            if let source = span.image, let url = MarkdownURLPolicy.localFileURL(source), span.link == nil {
                span.link = url.absoluteString
            }
            return span
        }
        // Keep the original sentence and its links together. Supplementary
        // previews follow it rather than splitting prose at each linked span.
        for source in sources where images[source] != nil && !spans.contains(where: { $0.image == source }) {
            var preview = MarkdownSpan(text: spans.filter { $0.link == source }.map(\.text).joined())
            preview.image = source; preview.link = source
            result.append(MarkdownSpan(text: "\n"))
            result.append(preview)
        }
        return result
    }

    var body: some View {
        MarkdownSelectableText(spans: displayedSpans, fontSize: fontSize, weight: weight, muted: muted, strongInk: strongInk, tracking: tracking,
                               lineHeight: lineHeight, alignment: alignment, images: images, selectionScope: options.anchorPrefix, openLink: options.openLink)
        .fixedSize(horizontal: false, vertical: true)
        .help(imageFailure ?? "")
        .task(id: sources) {
            images = images.filter { sources.contains($0.key) }
            imageFailure = nil
            for source in sources where images[source] == nil {
                guard let url = MarkdownURLPolicy.url(source) else { continue }
                do {
                    let image: NativePlatformImage
                    if let local = MarkdownURLPolicy.localFileURL(source) {
                        let raster = try await MarkdownLocalImage.load(local)
                        image = NSImage(cgImage: raster, size: NSSize(width: raster.width, height: raster.height))
                    } else {
                        let data: Data
                        if let resolver = options.resolveMedia { data = try await resolver(url) }
                        else { data = try await MarkdownMediaCache.shared.load(url) }
                        try Task.checkCancellation()
                        guard let decoded = MarkdownMediaCache.decode(data) else { throw MarkdownMediaError.invalidImage }
                        image = decoded
                    }
                    try Task.checkCancellation()
                    images[source] = image
                } catch is CancellationError { return }
                catch { imageFailure = "图片加载失败：\(error.localizedDescription)" }
            }
        }
    }

}

struct MarkdownCodeBlock: View {
    let source: String
    private let sourceBytes: Data
    var selectionScope: String? = nil

    init(source: String, selectionScope: String? = nil) {
        self.source = source; self.sourceBytes = Data(source.utf8)
        self.selectionScope = selectionScope
    }
    var body: some View {
        NativeScrollView(.horizontal) {
            MarkdownSelectableText(spans: [MarkdownSpan(text: source.hasSuffix("\n") ? String(source.dropLast()) : source)],
                                   fontSize: NativeMarkdownTypography.fenceSize, lineHeight: NativeMarkdownTypography.fenceLineHeight, code: true, selectionScope: selectionScope, openLink: { _ in })
                .frame(width: max(1, codeWidth), alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NativePlatformPalette.thread.surface.swiftUI, in: RoundedRectangle(cornerRadius: 5))
        .contextMenu {
            Button("复制代码") { MarkdownPlatformActions.copy(source) }
        }
    }
    private var codeWidth: CGFloat {
        NativeMarkdownCodeMetrics.width(of: source)
    }
}

private struct MarkdownTableView: View {
    let rows: [[[MarkdownSpan]]]
    let alignments: [MarkdownAlignment]
    let options: MarkdownViewOptions
    @State private var availableWidth: CGFloat = NativeGeometry.readingWidth

    var body: some View {
        let columnWidths = widths
        return NativeScrollView(.horizontal) {
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                    GridRow {
                        ForEach(Array(columnWidths.enumerated()), id: \.offset) { columnIndex, width in
                            MarkdownInlineView(spans: columnIndex < row.count ? row[columnIndex] : [], fontSize: 12,
                                               weight: rowIndex == 0 ? 500 : 400,
                                               alignment: columnIndex < alignments.count ? alignments[columnIndex] : .left,
                                               options: options)
                                .padding(.horizontal, 11).padding(.vertical, 8)
                                .frame(width: width, alignment: .topLeading)
                                .frame(maxHeight: .infinity, alignment: .topLeading)
                                .background(rowIndex == 0 ? NativePlatformPalette.thread.surface.swiftUI : Color.clear)
                                .overlay(Rectangle().strokeBorder(NativePlatformPalette.thread.line.swiftUI, lineWidth: 0.5))
                        }
                    }
                }
            }
            // Keep wrapped rows at their intrinsic height inside the horizontal viewport.
            .fixedSize(horizontal: false, vertical: true)
        }
        .background(GeometryReader { geometry in
            Color.clear.onAppear { availableWidth = geometry.size.width }
                .onChange(of: geometry.size.width) { _, width in availableWidth = width }
        })
    }

    private var widths: [CGFloat] {
        let count = rows.map(\.count).max() ?? 0
        guard count > 0 else { return [] }
        var natural = Array(repeating: CGFloat(23), count: count)
        var minimum = natural
        for (rowIndex, row) in rows.enumerated() {
            for (column, spans) in row.enumerated() {
                let metrics = NativeMarkdownCellMetrics.measure(spans, weight: rowIndex == 0 ? 500 : 400)
                natural[column] = max(natural[column], metrics.natural)
                minimum[column] = max(minimum[column], metrics.minimum)
            }
        }
        let full = natural.reduce(0, +), floor = minimum.reduce(0, +)
        // The source table is display:block: its inner table remains intrinsic
        // when narrow, and its columns share the available width when wrapping.
        guard full > availableWidth else { return natural }
        guard availableWidth > floor else { return minimum }
        let ratio = (availableWidth - floor) / max(1, full - floor)
        return zip(natural, minimum).map { natural, minimum in minimum + (natural - minimum) * ratio }
    }

}

/// Internal footnote destinations stay in the native conversation scroll view.
private struct MarkdownAnchor: NSViewRepresentable {
    let identifier: String
    func makeNSView(context: Context) -> NSView { let view = NSView(); view.identifier = NSUserInterfaceItemIdentifier(identifier); return view }
    func updateNSView(_ view: NSView, context: Context) { view.identifier = NSUserInterfaceItemIdentifier(identifier) }
}
