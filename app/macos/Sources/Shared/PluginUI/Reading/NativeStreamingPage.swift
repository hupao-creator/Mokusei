import AppKit
import SwiftUI

private struct NativeReadingPageCapacityKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    /// Height of one reading page in points, supplied by the timeline that
    /// owns the viewport. Streaming Markdown only pages when this is known;
    /// standalone hosts keep the literal streaming presentation.
    var nativeReadingPageCapacity: CGFloat? {
        get { self[NativeReadingPageCapacityKey.self] }
        set { self[NativeReadingPageCapacityKey.self] = newValue }
    }
}

/// Geometry and block measurements for page-level streaming.
///
/// A page is one visible reading viewport, expressed in points (not source
/// lines). Measurements mirror the production renderer's line heights and
/// block margins so a page closes at the same place the reader sees it fill.
/// They are estimates only for layout decisions; rendered blocks still use the
/// real Markdown views and are never re-measured here.
@MainActor
enum NativeStreamingPageMetrics {
    /// Used only if the environment loses its viewport while a page model is
    /// still mounted. Every mounted Thread timeline supplies a real height.
    static let fallbackCapacity: CGFloat = 640

    /// A new page enters along the same vertical axis as a history page
    /// replacement. The travel stays short because the page is appended below
    /// the reader while the timeline's follow scroll runs in the same layout
    /// pass; a full-viewport offset would leave the viewport empty mid-flight.
    static let entranceTravel: CGFloat = 18

    static func bodyLineHeight(_ fontSize: CGFloat) -> CGFloat { fontSize * 1.8 }

    static func headingSize(_ level: Int, fontSize: CGFloat) -> CGFloat {
        switch level {
        case 1: 30
        case 2: 20
        case 3: 16
        case 4: 14
        case 5: fontSize * 0.83
        default: fontSize * 0.67
        }
    }

    static func headingLineHeight(_ level: Int, size: CGFloat) -> CGFloat {
        size * (level <= 4 ? 1.28 : 1.8)
    }

    /// The trailing margin the renderer gives a block when more content follows.
    static func bottomMargin(_ block: MarkdownBlock, fontSize: CGFloat, compact: Bool) -> CGFloat {
        if case .heading(let level, _) = block {
            switch level {
            case 1...3: return 12
            case 4: return 10
            case 5: return fontSize * 0.83 * 1.67
            default: return fontSize * 0.67 * 2.33
            }
        }
        return compact ? 5 : 14
    }

    /// Heading space above a block, net of the previous block's bottom margin.
    /// A page that starts with a heading must retain that seam so splitting a
    /// document does not change its vertical rhythm.
    static func headingTopPadding(for block: MarkdownBlock, previous: MarkdownBlock?,
                                  compact: Bool, fontSize: CGFloat) -> CGFloat {
        guard case .heading(let level, _) = block, let previous else { return 0 }
        let desired: CGFloat = level <= 3 ? 26 : level == 4 ? 24
            : bottomMargin(block, fontSize: fontSize, compact: false)
        let previousBottom = compact ? 5 : bottomMargin(previous, fontSize: fontSize, compact: false)
        return max(0, desired - previousBottom)
    }

    /// Height of one page. The trailing margin is retained while more blocks
    /// may follow, matching the non-final pages rendered by `MarkdownContent`.
    static func estimatedHeight(of blocks: [MarkdownBlock], width: CGFloat, fontSize: CGFloat,
                                precedingBlock: MarkdownBlock? = nil, compact: Bool = false,
                                isFinal: Bool = false) -> CGFloat {
        var total: CGFloat = 0
        for (index, block) in blocks.enumerated() {
            let previous = index > 0 ? blocks[index - 1] : precedingBlock
            total += headingTopPadding(for: block, previous: previous, compact: compact, fontSize: fontSize)
            total += height(of: block, width: width, fontSize: fontSize, compact: compact)
            if index < blocks.count - 1 || !isFinal {
                total += bottomMargin(block, fontSize: fontSize, compact: compact)
            }
        }
        return total
    }

    static func height(of block: MarkdownBlock, width: CGFloat, fontSize: CGFloat, compact: Bool) -> CGFloat {
        switch block {
        case .paragraph(let spans):
            return textHeight(spans, width: width, fontSize: fontSize, weight: 400,
                              lineHeight: bodyLineHeight(fontSize))
        case .heading(let level, let spans):
            let size = headingSize(level, fontSize: fontSize)
            return textHeight(spans, width: width, fontSize: size,
                              weight: level <= 3 ? 600 : level == 4 ? 680 : 700,
                              lineHeight: headingLineHeight(level, size: size),
                              tracking: level <= 3 ? -0.25 : 0)
        case .quote(let children):
            // 3pt rule + 15pt gap, plus the renderer's 3pt vertical padding.
            return estimatedHeight(of: children, width: max(1, width - 18), fontSize: fontSize,
                                   compact: false, isFinal: true) + 6
        case .list(let items):
            guard !items.isEmpty else { return 0 }
            let markerWidth = listMarkerWidth(items, fontSize: fontSize)
            let spacing: CGFloat = items.first?.tight == false ? 14 : 5
            var total: CGFloat = 0
            for (index, item) in items.enumerated() {
                let content = estimatedHeight(of: item.blocks, width: max(1, width - markerWidth),
                                              fontSize: fontSize, compact: item.tight, isFinal: true)
                total += max(content, bodyLineHeight(fontSize))
                if index < items.count - 1 { total += spacing }
            }
            return total
        case .code(_, let source):
            // Fences scroll horizontally; every source line occupies one
            // rendered line. 16pt padding above and below the code text.
            let lines = source.isEmpty ? 1 : source.components(separatedBy: "\n").count
            return CGFloat(lines) * NativeMarkdownTypography.fenceLineHeight + 32
        case .table(let rows, _):
            return tableHeight(rows, width: width)
        case .rule:
            return 1 + 12
        case .footnote(_, _, let children):
            let content = estimatedHeight(of: children, width: max(1, width - 23), fontSize: fontSize,
                                          compact: true, isFinal: true)
            return max(content, bodyLineHeight(fontSize))
        }
    }

    static func listMarkerWidth(_ items: [MarkdownListItem], fontSize: CGFloat) -> CGFloat {
        let font = NativeTypography.interPlatformFont(size: fontSize)
        return items.reduce(CGFloat(23)) { width, item in
            item.checked == nil ? max(width, ceil((item.marker as NSString).size(withAttributes: [.font: font]).width) + 6) : width
        }
    }

    static func tableHeight(_ rows: [[[MarkdownSpan]]], width: CGFloat) -> CGFloat {
        let columns = rows.map(\.count).max() ?? 0
        guard columns > 0 else { return 0 }
        // The renderer may widen a table beyond the viewport for horizontal
        // scrolling. Sharing the available width here can overestimate wrapping
        // and therefore close a page slightly early; it never overflows.
        let columnWidth = max(60, width / CGFloat(columns))
        var total: CGFloat = 0
        for (rowIndex, row) in rows.enumerated() {
            var rowHeight = bodyLineHeight(12)
            for column in 0..<columns {
                let spans = column < row.count ? row[column] : []
                rowHeight = max(rowHeight, textHeight(spans, width: max(1, columnWidth - 22), fontSize: 12,
                                                     weight: rowIndex == 0 ? 500 : 400,
                                                     lineHeight: bodyLineHeight(12)))
            }
            total += rowHeight + 16
        }
        return total
    }

    static func textHeight(_ spans: [MarkdownSpan], width: CGFloat, fontSize: CGFloat, weight: CGFloat,
                           lineHeight: CGFloat, tracking: CGFloat = 0) -> CGFloat {
        guard !spans.isEmpty else { return 0 }
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        paragraph.lineBreakMode = .byWordWrapping
        let text = NSMutableAttributedString()
        for span in spans {
            let size = span.superscript ? fontSize * 0.72 : span.code ? fontSize * 0.88 : fontSize
            let font = span.code
                ? NativeMarkdownTypography.code(size: size, weight: span.strong ? 700 : weight, italic: span.emphasis)
                : NativeTypography.interPlatformFont(size: size, weight: span.strong ? 700 : weight)
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph]
            if tracking != 0 { attributes[.kern] = tracking }
            text.append(NSAttributedString(string: span.text, attributes: attributes))
        }
        // Inline code reserves a 5pt padding cell on each side.
        let inlineCodePadding = CGFloat(spans.filter(\.code).count) * MarkdownCodePaddingCell.horizontalWidth * 2
        let available = max(1, width - inlineCodePadding)
        let rect = text.boundingRect(with: CGSize(width: available, height: .greatestFiniteMagnitude),
                                     options: [.usesLineFragmentOrigin])
        return ceil(rect.height)
    }
}

/// Finds the longest prefix of a streamed source that ends between top-level
/// Markdown blocks. Only blank-line boundaries outside fenced/indented code and
/// lists are used, so a page break can never cut a code fence, table, or list
/// into independently parsed fragments. A single trailing newline does not
/// settle a block; it may still be continued by the next streamed line.
enum NativeStreamingSource {
    static func settledPrefix(in source: Substring) -> Substring {
        source[..<settledPrefixEnd(in: source)]
    }

    static func settledPrefixEnd(in source: Substring) -> Substring.Index {
        guard !source.isEmpty else { return source.endIndex }
        let starts = lineStarts(in: source)
        var boundary = source.startIndex
        var fence: (character: Character, count: Int)?
        var inList = false
        var listIndent = 0
        var inIndentedCode = false
        var sawBlank = false
        var trailingBlankLines = 0
        var isFirstLine = true

        for index in 0..<starts.count {
            let start = starts[index]
            let end = index + 1 < starts.count ? starts[index + 1] : source.endIndex
            let raw = source[start..<end]
            let content = raw.hasSuffix("\n") ? raw.dropLast() : raw
            let line = content.trimmingCharacters(in: .whitespacesAndNewlines)
            let indent = indentation(of: content)

            if let open = fence {
                if closesFence(line, character: open.character, count: open.count) { fence = nil }
                isFirstLine = false
                continue
            }
            if let opening = openingFence(line, indent: indent) {
                // The fence itself is a top-level block start, so a blank line
                // before it settles everything before the fence. A fence inside
                // a list remains part of that list.
                if sawBlank, !inList, !inIndentedCode {
                    boundary = start
                }
                fence = opening
                sawBlank = false
                trailingBlankLines = 0
                isFirstLine = false
                continue
            }
            if line.isEmpty {
                sawBlank = true
                trailingBlankLines += 1
                isFirstLine = false
                continue
            }

            let blankBefore = sawBlank
            trailingBlankLines = 0
            if blankBefore {
                let continuesList = inList && (isListMarker(line) || indent >= listIndent + 2)
                let continuesIndentedCode = inIndentedCode && indent >= 4
                if !continuesList && !continuesIndentedCode {
                    boundary = start
                    inList = false
                    inIndentedCode = false
                }
            }

            if indent <= 3, isListMarker(line) {
                inList = true
                listIndent = indent
            } else if inList {
                if indent < listIndent + 2, !isListMarker(line) { inList = false }
            }
            if indent >= 4, (blankBefore || inIndentedCode || isFirstLine) {
                inIndentedCode = true
            } else if indent < 4, !inList {
                inIndentedCode = false
            }
            sawBlank = false
            isFirstLine = false
        }

        // A blank line at the very end closes the final paragraph. Do not
        // settle a list, indented code block or open fence on it: a later
        // streamed item or line may still belong to the same block.
        if trailingBlankLines >= 2, !inList, !inIndentedCode, fence == nil {
            boundary = source.endIndex
        }
        return boundary
    }

    private static func indentation(of line: Substring) -> Int {
        var count = 0
        for character in line {
            if character == " " { count += 1 }
            else if character == "\t" { count += 4 }
            else { break }
        }
        return count
    }

    private static func isListMarker(_ line: String) -> Bool {
        guard let first = line.first else { return false }
        if "-*+".contains(first) {
            return line.dropFirst().first?.isWhitespace == true
        }
        var digits = 0
        for character in line {
            if character.isNumber { digits += 1; continue }
            guard digits > 0, digits <= 9, character == "." || character == ")" else { return false }
            return line.dropFirst(digits + 1).first?.isWhitespace == true
        }
        return false
    }

    private static func openingFence(_ line: String, indent: Int) -> (Character, Int)? {
        guard indent <= 3, let first = line.first, first == "`" || first == "~" else { return nil }
        let run = line.prefix { $0 == first }.count
        guard run >= 3 else { return nil }
        if first == "`", line.dropFirst(run).contains("`") { return nil }
        return (first, run)
    }

    private static func closesFence(_ line: String, character: Character, count: Int) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let run = trimmed.prefix { $0 == character }.count
        return run >= count && trimmed.dropFirst(run).isEmpty
    }

    /// One entry per physical line, including the empty line after a trailing
    /// newline. The last entry may equal `endIndex` for that empty line.
    private static func lineStarts(in source: Substring) -> [Substring.Index] {
        var starts: [Substring.Index] = [source.startIndex]
        var index = source.startIndex
        while let newline = source[index...].firstIndex(of: "\n") {
            index = source.index(after: newline)
            starts.append(index)
        }
        return starts
    }
}

/// Page-level streaming projection. Settled source blocks are measured until a
/// page closes; only then is the page published to SwiftUI. Unpublished blocks
/// never create a growing text view, and multiple chunks arriving in one state
/// update are coalesced into the same page flush.
@MainActor
final class NativeStreamingPageModel: ObservableObject {
    @Published private(set) var pages: [[MarkdownBlock]] = []
    @Published private(set) var completed = false

    /// Source prefix already converted to blocks, including blocks still in
    /// the open (unpublished) page.
    private var parsedText = ""
    private var openPage: [MarkdownBlock] = []
    private var openHeight: CGFloat = 0
    private var finalizeTask: Task<Void, Never>?
    private var finalizing = false
    private var finalizingText = ""
    private var generation = 0

    private struct PageInputs {
        let capacity: CGFloat
        let width: CGFloat
        let fontSize: CGFloat
    }

    func update(text: String, streaming: Bool, capacity: CGFloat, width: CGFloat, fontSize: CGFloat) {
        let inputs = PageInputs(capacity: max(1, capacity), width: max(1, width), fontSize: max(1, fontSize))

        if !text.hasPrefix(parsedText) || text.count < parsedText.count {
            reset()
        } else if completed, streaming || text != parsedText {
            reset()
        }

        if completed { return }

        if !streaming {
            // Completion reparses the whole source once. The parser cache is
            // shared with the ordinary Markdown model, so a second full parse
            // for the same bytes is normally a cache hit.
            if finalizing, text != finalizingText {
                finalizeTask?.cancel()
                finalizeTask = nil
                finalizing = false
                generation += 1
            }
            if !finalizing { startFinalization(text: text, inputs: inputs) }
            return
        }

        if finalizing, text != finalizingText {
            // A resumed stream supersedes the previous completion snapshot.
            finalizeTask?.cancel()
            finalizeTask = nil
            finalizing = false
            generation += 1
        }
        guard !finalizing else { return }
        let pending = text.dropFirst(parsedText.count)
        guard !pending.isEmpty else {
            reevaluateOpenPage(inputs: inputs)
            return
        }
        let settled = NativeStreamingSource.settledPrefix(in: pending)
        guard !settled.isEmpty else {
            reevaluateOpenPage(inputs: inputs)
            return
        }
        let source = String(settled)
        let document = MarkdownParser.parse(source)
        parsedText += source
        append(document.blocks, inputs: inputs)
    }

    private func startFinalization(text: String, inputs: PageInputs) {
        finalizing = true
        finalizingText = text
        let token = generation
        finalizeTask = Task { @MainActor [weak self] in
            let document = try? await NativeMarkdownParser.shared.parse(text)
            guard !Task.isCancelled, let self, self.generation == token else { return }
            self.applyFinal(document?.blocks ?? MarkdownParser.parse(text).blocks,
                            source: text, inputs: inputs)
        }
    }

    private func applyFinal(_ blocks: [MarkdownBlock], source: String, inputs: PageInputs) {
        finalizing = false
        finalizingText = ""
        finalizeTask = nil
        let existing = pages.flatMap { $0 } + openPage
        // Chunk parsing is equivalent to a whole-document parse except for
        // reference definitions/footnotes that point at later chunks. Rebuild
        // only when the completed document actually differs, so ordinary
        // completions keep already displayed pages stable.
        if !existing.isEmpty, blocks.count >= existing.count,
           Array(blocks.prefix(existing.count)) == existing {
            append(Array(blocks.dropFirst(existing.count)), inputs: inputs)
        } else {
            pages = []
            openPage = []
            openHeight = 0
            append(blocks, inputs: inputs)
        }
        emitOpenPage()
        parsedText = source
        completed = true
    }

    private func append(_ blocks: [MarkdownBlock], inputs: PageInputs) {
        guard !blocks.isEmpty else { return }
        var nextPages = pages
        var nextOpen = openPage
        var nextHeight = openHeight

        for block in blocks {
            let candidate = nextOpen + [block]
            let candidateHeight = NativeStreamingPageMetrics.estimatedHeight(
                of: candidate, width: inputs.width, fontSize: inputs.fontSize,
                precedingBlock: nextPages.last?.last, isFinal: false)
            if !nextOpen.isEmpty, candidateHeight > inputs.capacity {
                nextPages.append(nextOpen)
                nextOpen = [block]
                nextHeight = NativeStreamingPageMetrics.estimatedHeight(
                    of: nextOpen, width: inputs.width, fontSize: inputs.fontSize,
                    precedingBlock: nextPages.last?.last, isFinal: false)
            } else {
                nextOpen = candidate
                nextHeight = candidateHeight
            }
            if !nextOpen.isEmpty, nextHeight >= inputs.capacity {
                nextPages.append(nextOpen)
                nextOpen = []
                nextHeight = 0
            }
        }

        if nextPages.count != pages.count { pages = nextPages }
        openPage = nextOpen
        openHeight = nextHeight
    }

    private func emitOpenPage() {
        guard !openPage.isEmpty else { return }
        pages.append(openPage)
        openPage = []
        openHeight = 0
    }

    private func reevaluateOpenPage(inputs: PageInputs) {
        guard !openPage.isEmpty else { return }
        openHeight = NativeStreamingPageMetrics.estimatedHeight(
            of: openPage, width: inputs.width, fontSize: inputs.fontSize,
            precedingBlock: pages.last?.last, isFinal: false)
        if openHeight >= inputs.capacity { emitOpenPage() }
    }

    private func reset() {
        finalizeTask?.cancel()
        finalizeTask = nil
        finalizing = false
        finalizingText = ""
        generation += 1
        pages = []
        openPage = []
        openHeight = 0
        parsedText = ""
        completed = false
    }
}

/// Renders only closed pages. The open page stays invisible until the next
/// block proves it cannot accept more content, or the message completes.
struct NativeStreamingPagedMarkdown: View {
    let text: String
    let streaming: Bool
    let fontSize: CGFloat
    let options: MarkdownViewOptions
    @Environment(\.nativeReadingPageCapacity) private var pageCapacity
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var model = NativeStreamingPageModel()
    @State private var width: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(model.pages.enumerated()), id: \.offset) { index, page in
                MarkdownContent(blocks: page, options: options,
                                precedingBlock: index > 0 ? model.pages[index - 1].last : nil,
                                isFinal: model.completed && index == model.pages.count - 1)
                    .transition(pageTransition)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(reduceMotion ? nil : NativeReadingPageTiming.replacementAnimation, value: model.pages.count)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { value in
            guard value > 0, value != width else { return }
            width = value
            update()
        }
        .onChange(of: text, initial: true) { _, _ in update() }
        .onChange(of: streaming, initial: true) { _, _ in update() }
        .onChange(of: pageCapacity, initial: true) { _, _ in update() }
    }

    private var pageTransition: AnyTransition {
        guard !reduceMotion else { return .identity }
        return .asymmetric(
            insertion: .offset(y: NativeStreamingPageMetrics.entranceTravel).combined(with: .opacity),
            removal: .identity)
    }

    private func update() {
        // Wait for the real content width. Measuring with the default reading
        // width would close the first page at a width the message does not use.
        guard width > 0 else { return }
        let capacity = pageCapacity ?? NativeStreamingPageMetrics.fallbackCapacity
        model.update(text: text, streaming: streaming, capacity: capacity,
                     width: width, fontSize: fontSize)
    }
}
