import Foundation
import Markdown

/// Converts swift-markdown's immutable AST to a small Sendable presentation tree.
/// No AppKit objects or text layout are created on this background actor.
enum MarkdownParser {
    private struct Footnote {
        let id: String
        let source: String
    }

    static func parse(_ source: String) -> MarkdownDocument {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let prepared = extractFootnotes(normalized)
        let document = Document(parsing: prepared.source, options: [.disableSmartOpts])
        var converter = Converter(source: prepared.source, footnotes: prepared.notes)
        var blocks = converter.blocks(document.children)
        var cursor = 0
        var noteBlocks: [(String, Int, [MarkdownBlock])] = []
        // A note can reference a later note; resolve in first-reference order.
        while cursor < converter.references.count {
            let id = converter.references[cursor]
            if let note = prepared.notes.first(where: { $0.id == id }) {
                let parsed = Document(parsing: note.source, options: [.disableSmartOpts])
                var noteConverter = Converter(source: note.source, footnotes: prepared.notes, references: converter.references, referenceCounts: converter.referenceCounts)
                let content = noteConverter.blocks(parsed.children)
                converter.references = noteConverter.references
                converter.referenceCounts = noteConverter.referenceCounts
                noteBlocks.append((id, cursor + 1, content))
            }
            cursor += 1
        }
        if !noteBlocks.isEmpty { blocks.append(.heading(2, [MarkdownSpan(text: "Footnotes")])) }
        for (id, index, original) in noteBlocks {
            var content = original
            let count = converter.referenceCounts[id] ?? 1
            let backlinks = (1...max(1, count)).map { reference -> MarkdownSpan in
                var span = MarkdownSpan(text: reference == 1 ? " ↩" : " ↩\(reference)")
                span.link = "#mokusei-footnote-reference-\(id)-\(reference)"
                span.title = "Back to reference \(index)"; return span
            }
            if case .paragraph(let spans) = content.last {
                content[content.count - 1] = .paragraph(spans + backlinks)
            } else { content.append(.paragraph(backlinks)) }
            blocks.append(.footnote(id: id, index: index, blocks: content))
        }
        return MarkdownDocument(blocks: blocks, sourceBytes: source.utf8.count)
    }

    private struct Converter {
        let lines: [String]
        let footnotes: [Footnote]
        var references: [String] = []
        var referenceCounts: [String: Int] = [:]

        init(source: String, footnotes: [Footnote], references: [String] = [], referenceCounts: [String: Int] = [:]) {
            // Source ranges are queried for table cells and footnote text nodes.
            // Splitting here keeps conversion linear in the document's length.
            lines = source.components(separatedBy: .newlines)
            self.footnotes = footnotes
            self.references = references
            self.referenceCounts = referenceCounts
        }

        mutating func blocks(_ children: MarkupChildren) -> [MarkdownBlock] {
            children.flatMap { block($0) }
        }

        mutating func block(_ node: any Markup) -> [MarkdownBlock] {
            switch node {
            case let paragraph as Paragraph:
                return [.paragraph(inlines(paragraph.children))]
            case let heading as Heading:
                return [.heading(heading.level, inlines(heading.children))]
            case let quote as BlockQuote:
                return [.quote(blocks(quote.children))]
            case let list as UnorderedList:
                let tight = listIsTight(list.children)
                return [.list(list.children.compactMap { item($0, marker: "•", tight: tight) })]
            case let list as OrderedList:
                let tight = listIsTight(list.children)
                return [.list(list.children.enumerated().compactMap { index, child in
                    item(child, marker: "\(list.startIndex + UInt(index)).", tight: tight)
                })]
            case let code as CodeBlock:
                return [.code(language: code.language ?? "", source: code.code)]
            case let table as Table:
                let head = table.head.children.map { tableCell($0) }
                let rows = table.body.children.map { row in row.children.map { tableCell($0) } }
                let alignments = table.columnAlignments.map { alignment -> MarkdownAlignment in
                    switch alignment { case .center: .center; case .right: .right; default: .left }
                }
                return [.table(rows: [head] + rows, alignments: alignments)]
            case is ThematicBreak:
                return [.rule]
            case let html as HTMLBlock:
                // The production renderer intentionally renders raw HTML literally.
                return [.paragraph([MarkdownSpan(text: collapsedWhitespace(html.rawHTML).trimmingCharacters(in: .whitespacesAndNewlines))])]
            default:
                return blocks(node.children)
            }
        }

        mutating func tableCell(_ node: any Markup) -> [MarkdownSpan] {
            // swift-markdown enables cmark's non-GFM table spans. GFM keeps
            // empty cells and renders standalone ^/" cells literally; cmark
            // removes the marker's inline node when it merges a previous row.
            if let cell = node as? Table.Cell, cell.rowspan == 0, cell.childCount == 0,
               let range = cell.range, range.lowerBound.line == range.upperBound.line {
                let row = range.lowerBound.line - 1
                let sourceLines = lines
                if sourceLines.indices.contains(row) {
                    let bytes = Array(sourceLines[row].utf8)
                    let start = min(bytes.count, max(0, range.lowerBound.column - 1))
                    let end = min(bytes.count, max(start, range.upperBound.column - 1))
                    let marker = String(decoding: bytes[start..<end], as: UTF8.self)
                        .trimmingCharacters(in: CharacterSet(charactersIn: " \t|"))
                    if marker == "^" || marker == "\"" { return [MarkdownSpan(text: marker)] }
                }
            }
            return inlines(node.children)
        }

        mutating func item(_ node: any Markup, marker: String, tight: Bool) -> MarkdownListItem? {
            guard let item = node as? ListItem else { return nil }
            let checked = item.checkbox.map { $0 == .checked }
            return MarkdownListItem(marker: marker, checked: checked, tight: tight, blocks: blocks(item.children))
        }

        func listIsTight(_ children: MarkupChildren) -> Bool {
            func lastContentLine(_ node: any Markup) -> Int? {
                if node is ListItem || node is UnorderedList || node is OrderedList || node is BlockQuote,
                   let last = Array(node.children).last { return lastContentLine(last) }
                return node.range?.upperBound.line
            }
            let items = Array(children)
            for (index, item) in items.enumerated() {
                if index > 0, let previous = lastContentLine(items[index - 1]), let current = item.range,
                   current.lowerBound.line - previous > 1 { return false }
                let blocks = Array(item.children)
                for pair in zip(blocks, blocks.dropFirst()) {
                    if let first = lastContentLine(pair.0), let second = pair.1.range,
                       second.lowerBound.line - first > 1 { return false }
                }
            }
            return true
        }

        mutating func inlines(_ children: MarkupChildren, style: MarkdownSpan = MarkdownSpan(text: "")) -> [MarkdownSpan] {
            children.flatMap { inline($0, style: style) }
        }

        mutating func inline(_ node: any Markup, style: MarkdownSpan) -> [MarkdownSpan] {
            var style = style
            switch node {
            case let text as Markdown.Text:
                return textSpans(collapsedWhitespace(text.string), style: style, escapedReferences: escapedReferences(in: text))
            case let code as InlineCode:
                style.text = code.code; style.code = true
                if !style.linkContext, style.link == nil, let url = URL(string: code.code),
                   ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                   url.host != nil, !code.code.contains(where: \.isWhitespace) {
                    style.link = MarkdownURLPolicy.sanitized(code.code)
                }
                return [style]
            case is Strong:
                style.strong = true; return inlines(node.children, style: style)
            case is Emphasis:
                style.emphasis = true; return inlines(node.children, style: style)
            case is Strikethrough:
                style.strikethrough = true; return inlines(node.children, style: style)
            case let link as Markdown.Link:
                style.link = MarkdownURLPolicy.sanitized(link.destination)
                style.linkContext = true
                style.title = link.title
                return inlines(node.children, style: style)
            case let image as Markdown.Image:
                style.image = MarkdownURLPolicy.sanitized(image.source)
                style.text = image.plainText; style.title = image.title
                // A blocked source still leaves its alternative text visible.
                return [style]
            case is SoftBreak:
                style.text = " "; return [style]
            case is LineBreak:
                style.text = "\n"; return [style]
            case let html as InlineHTML:
                style.text = collapsedWhitespace(html.rawHTML); return [style]
            default:
                return inlines(node.children, style: style)
            }
        }

        mutating func textSpans(_ string: String, style: MarkdownSpan, escapedReferences: Set<Int>) -> [MarkdownSpan] {
            guard !string.isEmpty else { return [] }
            guard !footnotes.isEmpty, string.contains("[^"), !style.linkContext else { return autolinks(string, style: style) }
            var result: [MarkdownSpan] = []
            let ns = string as NSString
            var cursor = 0
            let matches = footnoteReference.matches(in: string, range: NSRange(location: 0, length: ns.length))
            for (referenceIndex, match) in matches.enumerated() {
                guard !escapedReferences.contains(referenceIndex) else { continue }
                let id = normalizedID(ns.substring(with: match.range(at: 1)))
                guard footnotes.contains(where: { $0.id == id }) else { continue }
                if match.range.location > cursor {
                    result += autolinks(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)), style: style)
                }
                if !references.contains(id) { references.append(id) }
                var span = style
                span.text = String((references.firstIndex(of: id) ?? 0) + 1)
                referenceCounts[id, default: 0] += 1
                span.superscript = true; span.link = "#mokusei-footnote-\(id)"
                span.anchor = "mokusei-footnote-reference-\(id)-\(referenceCounts[id]!)"
                result.append(span); cursor = NSMaxRange(match.range)
            }
            if cursor < ns.length { result += autolinks(ns.substring(from: cursor), style: style) }
            return result
        }

        func escapedReferences(in node: Markdown.Text) -> Set<Int> {
            guard !footnotes.isEmpty, node.string.contains("[^"), let range = node.range else { return [] }
            let rows = lines
            let first = range.lowerBound.line - 1, last = range.upperBound.line - 1
            guard rows.indices.contains(first), rows.indices.contains(last) else { return [] }
            var bytes: [UInt8] = []
            for row in first...last {
                let line = Array(rows[row].utf8)
                let start = row == first ? min(line.count, max(0, range.lowerBound.column - 1)) : 0
                let end = row == last ? min(line.count, max(start, range.upperBound.column - 1)) : line.count
                bytes += line[start..<end]
                if row != last { bytes.append(10) }
            }
            let raw = String(decoding: bytes, as: UTF8.self) as NSString
            var escaped = Set<Int>()
            for (index, match) in footnoteReference.matches(in: raw as String, range: NSRange(location: 0, length: raw.length)).enumerated() {
                var cursor = match.range.location - 1, count = 0
                while cursor >= 0, raw.character(at: cursor) == 92 { count += 1; cursor -= 1 }
                if count % 2 == 1 { escaped.insert(index) }
            }
            return escaped
        }
    }

    private static let footnoteReference = try! NSRegularExpression(pattern: #"\[\^([^\]\s]+)\]"#)
    private static let whitespace = try! NSRegularExpression(pattern: "[ \t\r\n\u{000C}]+")
    private static let footnoteDefinition = try! NSRegularExpression(pattern: #"^([ \t]*(?:(?:>[ \t]*)|(?:(?:[-+*]|[0-9]{1,9}[.)])[ \t]+))*)\[\^([^\]]+)\]:[ \t]*(.*)$"#)
    private static let autolinkExpression = try! NSRegularExpression(
        pattern: #"(?i)(?:https?://|www\.)[^\s<>]+|[A-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Z0-9](?:[A-Z0-9-]*[A-Z0-9])?(?:\.[A-Z0-9](?:[A-Z0-9-]*[A-Z0-9])?)+"#)

    private static func collapsedWhitespace(_ text: String) -> String {
        whitespace.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
    }

    private static func normalizedID(_ id: String) -> String {
        id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func autolinks(_ text: String, style: MarkdownSpan) -> [MarkdownSpan] {
        guard !style.linkContext, style.link == nil, !style.code else { var span = style; span.text = text; return [span] }
        let ns = text as NSString
        var result: [MarkdownSpan] = []; var cursor = 0
        for match in autolinkExpression.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var range = match.range
            var candidate = ns.substring(with: range)
            // GFM excludes trailing sentence punctuation and unmatched parentheses.
            while let last = candidate.last, ".,:;!?*_'\"".contains(last)
                || (last == ")" && candidate.filter({ $0 == ")" }).count > candidate.filter({ $0 == "(" }).count) {
                candidate.removeLast(); range.length -= 1
            }
            guard !candidate.isEmpty else { continue }
            if range.location > cursor {
                var plain = style; plain.text = ns.substring(with: NSRange(location: cursor, length: range.location - cursor)); result.append(plain)
            }
            var span = style; span.text = candidate
            let destination = candidate.lowercased().hasPrefix("www.") ? "http://" + candidate
                : candidate.contains("://") ? candidate : "mailto:" + candidate
            span.link = MarkdownURLPolicy.sanitized(destination); result.append(span)
            cursor = NSMaxRange(range)
        }
        if cursor < ns.length { var plain = style; plain.text = ns.substring(from: cursor); result.append(plain) }
        return result
    }

    private static func extractFootnotes(_ source: String) -> (source: String, notes: [Footnote]) {
        guard source.contains("[^") else { return (source, []) }
        var lines = source.components(separatedBy: .newlines)
        var notes: [Footnote] = []
        // Parse once to identify literal regions before examining definition
        // syntax; a definition in a fence or HTML literal is never a footnote.
        let document = Document(parsing: source, options: [.disableSmartOpts])
        var literalLines = Set<Int>()
        func collect(_ node: any Markup) {
            if node is CodeBlock || node is HTMLBlock, let range = node.range {
                literalLines.formUnion((range.lowerBound.line - 1)...(range.upperBound.line - 1))
            } else { node.children.forEach(collect) }
        }
        collect(document)
        var index = 0
        while index < lines.count {
            let line = lines[index] as NSString
            guard !literalLines.contains(index), let match = footnoteDefinition.firstMatch(in: lines[index], range: NSRange(location: 0, length: line.length)) else { index += 1; continue }
            let prefix = line.substring(with: match.range(at: 1))
            let id = normalizedID(line.substring(with: match.range(at: 2)))
            var body = [line.substring(with: match.range(at: 3))]
            let quoteCount = prefix.filter { $0 == ">" }.count
            let afterQuotes = prefix.split(separator: ">", omittingEmptySubsequences: false).last.map(String.init) ?? prefix
            let listMarker = afterQuotes.range(of: #"[-+*]|[0-9]{1,9}[.)]"#, options: .regularExpression)
            let containerIndent = listMarker != nil || afterQuotes.count >= 4 ? afterQuotes.count : 0
            func continuation(_ value: String) -> String? {
                var value = value
                for _ in 0..<quoteCount {
                    value = String(value.drop(while: { $0 == " " || $0 == "\t" }))
                    guard value.first == ">" else { return nil }
                    value.removeFirst()
                    if value.first == " " { value.removeFirst() }
                }
                if containerIndent > 0 {
                    let indent = value.prefix(while: { $0 == " " }).count
                    guard indent >= containerIndent || value.isEmpty else { return nil }
                    value = String(value.dropFirst(min(containerIndent, value.count)))
                }
                return value
            }
            lines[index] = ""; index += 1
            while index < lines.count {
                guard let reduced = continuation(lines[index]) else { break }
                if reduced.hasPrefix("    ") || reduced.hasPrefix("\t") {
                    body.append(String(reduced.dropFirst(reduced.hasPrefix("\t") ? 1 : 4)))
                    lines[index] = ""; index += 1
                } else if reduced.isEmpty, index + 1 < lines.count,
                          let next = continuation(lines[index + 1]), next.hasPrefix("    ") || next.hasPrefix("\t") {
                    body.append(""); lines[index] = ""; index += 1
                } else { break }
            }
            if !notes.contains(where: { $0.id == id }) { notes.append(Footnote(id: id, source: body.joined(separator: "\n"))) }
        }
        return (lines.joined(separator: "\n"), notes)
    }
}
