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
        let prepared = extractFootnotes(protectBareURLs(normalized))
        let main = prepareReferences(prepared.source, notes: prepared.notes)
        let document = Document(parsing: main.source, options: [.disableSmartOpts])
        var converter = Converter(source: main.source, tokens: main.tokens)
        var blocks = converter.blocks(document.children)
        var cursor = 0
        var noteBlocks: [(String, Int, [MarkdownBlock])] = []
        // A note can reference a later note; resolve in first-reference order.
        while cursor < converter.references.count {
            let id = converter.references[cursor]
            if let note = prepared.notes.first(where: { $0.id == id }) {
                let preparedNote = prepareReferences(note.source, notes: prepared.notes)
                let parsed = Document(parsing: preparedNote.source, options: [.disableSmartOpts])
                var noteConverter = Converter(source: preparedNote.source, tokens: preparedNote.tokens, references: converter.references, referenceCounts: converter.referenceCounts)
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
                span.link = "#mokusei-footnote-reference-\(anchorID(id))-\(reference)"
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
        let tokens: [String: String]
        var references: [String] = []
        var referenceCounts: [String: Int] = [:]

        init(source: String, tokens: [String: String], references: [String] = [], referenceCounts: [String: Int] = [:]) {
            // Source ranges are queried for table cells and footnote text nodes.
            // Splitting here keeps conversion linear in the document's length.
            lines = source.components(separatedBy: "\n")
            self.tokens = tokens
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
                if node is ListItem || node is UnorderedList || node is OrderedList,
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
                return textSpans(collapsedWhitespace(text.string), style: style)
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
                style.text = plainImageText(image); style.title = image.title
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

        mutating func textSpans(_ string: String, style: MarkdownSpan) -> [MarkdownSpan] {
            guard !string.isEmpty else { return [] }
            guard !tokens.isEmpty, !style.linkContext else { return autolinks(string, style: style) }
            var result: [MarkdownSpan] = []
            let ns = string as NSString
            var cursor = 0
            for match in referenceToken.matches(in: string, range: NSRange(location: 0, length: ns.length)) {
                guard let id = tokens[ns.substring(with: match.range)] else { continue }
                if match.range.location > cursor {
                    result += autolinks(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)), style: style)
                }
                if !references.contains(id) { references.append(id) }
                var span = style
                span.text = String((references.firstIndex(of: id) ?? 0) + 1)
                referenceCounts[id, default: 0] += 1
                span.superscript = true; span.link = "#mokusei-footnote-\(anchorID(id))"
                span.anchor = "mokusei-footnote-reference-\(anchorID(id))-\(referenceCounts[id]!)"
                result.append(span); cursor = NSMaxRange(match.range)
            }
            if cursor < ns.length { result += autolinks(ns.substring(from: cursor), style: style) }
            return result
        }

        private func plainImageText(_ node: any Markup) -> String {
            switch node {
            case let text as Markdown.Text: text.string
            case let code as InlineCode: code.code
            case is SoftBreak, is LineBreak: " "
            default: node.children.map(plainImageText).joined()
            }
        }
    }

    // Internal destinations use an opaque ASCII identity, so URL parsing cannot
    // decode a literal percent sequence or reinterpret punctuation in a label.
    static func anchorID(_ id: String) -> String {
        id.utf8.map { String(format: "%02x", $0) }.joined()
    }

    private static let referenceToken = try! NSRegularExpression(pattern: "\u{E000}mokusei-[A-Z0-9-]+\u{E001}")

    private static let footnoteReference = try! NSRegularExpression(pattern: #"\[\^([^\]\s]+)\]"#)
    private static let whitespace = try! NSRegularExpression(pattern: "[ \t\r\n\u{000C}]+")
    private static let footnoteDefinition = try! NSRegularExpression(pattern: #"^([ \t]*(?:(?:>[ \t]*)|(?:(?:[-+*]|[0-9]{1,9}[.)])[ \t]+))*)\[\^([^\]\s]+)\]:[ \t]*(.*)$"#)
    private static let referenceDefinition = try! NSRegularExpression(
        pattern: #"^([ \t]*(?:(?:>[ \t]*)|(?:(?:[-+*]|[0-9]{1,9}[.)])[ \t]+))*)\[(?:\\.|[^\]\\])+\]:[ \t]*(.*)$"#)
    private static let autolinkExpression = try! NSRegularExpression(
        pattern: #"(?i)(?:https?://|www\.)[^\s<>]+|[A-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Z0-9](?:[A-Z0-9-]*[A-Z0-9])?(?:\.[A-Z0-9](?:[A-Z0-9-]*[A-Z0-9])?)+"#)

    private static func collapsedWhitespace(_ text: String) -> String {
        whitespace.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
    }

    private static func normalizedID(_ id: String) -> String {
        id.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
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

    /// Protect source syntax before cmark splits emphasis or decodes entities.
    /// AST ranges keep code, explicit links/images and raw HTML literal.
    private static func protectedRanges(_ source: String) -> [NSRange] {
        let rows = source.components(separatedBy: "\n")
        let byteCount = source.utf8.count
        var starts: [Int] = []; var offset = 0
        for row in rows { starts.append(offset); offset += row.utf8.count + 1 }
        var ranges: [NSRange] = []
        func collect(_ node: any Markup) {
            if node is CodeBlock || node is InlineCode || node is Markdown.Link || node is Markdown.Image || node is HTMLBlock || node is InlineHTML {
                guard let range = node.range,
                      starts.indices.contains(range.lowerBound.line - 1), starts.indices.contains(range.upperBound.line - 1) else { return }
                let lower = starts[range.lowerBound.line - 1] + range.lowerBound.column - 1
                let upper = starts[range.upperBound.line - 1] + range.upperBound.column - 1
                guard lower >= 0, upper >= lower, upper <= byteCount else { return }
                let first = source.utf8.index(source.utf8.startIndex, offsetBy: lower)
                let last = source.utf8.index(source.utf8.startIndex, offsetBy: upper)
                if let first = String.Index(first, within: source), let last = String.Index(last, within: source) {
                    ranges.append(NSRange(first..<last, in: source))
                }
            } else { node.children.forEach(collect) }
        }
        collect(Document(parsing: source, options: [.disableSmartOpts]))
        return ranges
    }

    private static func protectBareURLs(_ source: String) -> String {
        guard source.contains("://") || source.range(of: "www.", options: .caseInsensitive) != nil else { return source }
        var protected = protectedRanges(source)
        // Reference definitions are absent from the AST. Rewriting their URL
        // as an inline link destroys the definition before cmark can resolve it.
        var offset = 0
        var destinationOnNextLine = false
        for line in source.components(separatedBy: "\n") {
            let range = NSRange(location: 0, length: line.utf16.count)
            if destinationOnNextLine {
                protected.append(NSRange(location: offset, length: range.length))
                destinationOnNextLine = false
            } else if footnoteDefinition.firstMatch(in: line, range: range) == nil,
                      let definition = referenceDefinition.firstMatch(in: line, range: range) {
                protected.append(NSRange(location: offset, length: range.length))
                destinationOnNextLine = definition.range(at: 2).length == 0
            }
            offset += range.length + 1
        }
        let result = NSMutableString(string: source)
        let matches = autolinkExpression.matches(in: source, range: NSRange(source.startIndex..., in: source))
        for match in matches.reversed() {
            guard !protected.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { continue }
            var candidate = result.substring(with: match.range)
            guard ["http://", "https://", "www."].contains(where: { candidate.lowercased().hasPrefix($0) }) else { continue }
            while let last = candidate.last, ".,:;!?*_'\"".contains(last)
                || (last == ")" && candidate.filter({ $0 == ")" }).count > candidate.filter({ $0 == "(" }).count) { candidate.removeLast() }
            guard !candidate.isEmpty else { continue }
            let range = NSRange(location: match.range.location, length: candidate.utf16.count)
            let visible = unescapedURL(candidate)
            let destination = visible.lowercased().hasPrefix("www.") ? "http://" + visible : visible
            let label = visible.map { "\\[]*_`~".contains($0) ? "\\" + String($0) : String($0) }.joined()
            result.replaceCharacters(in: range, with: "[" + label + "](<" + destination + ">)")
        }
        return result as String
    }

    private static func unescapedURL(_ source: String) -> String {
        var scalars = source.unicodeScalars.makeIterator()
        var result = ""
        while let scalar = scalars.next() {
            if scalar.value == 92, let next = scalars.next() {
                // Match CommonMark's backslash escapes before constructing the
                // explicit link. Angle destinations otherwise retain the slash.
                let punctuation = (33...47).contains(next.value) || (58...64).contains(next.value)
                    || (91...96).contains(next.value) || (123...126).contains(next.value)
                if !punctuation { result.unicodeScalars.append(scalar) }
                result.unicodeScalars.append(next)
            } else { result.unicodeScalars.append(scalar) }
        }
        return result
    }

    private static func prepareReferences(_ source: String, notes: [Footnote]) -> (source: String, tokens: [String: String]) {
        guard !notes.isEmpty, source.contains("[^") else { return (source, [:]) }
        let protected = protectedRanges(source)
        let raw = source as NSString
        let result = NSMutableString(string: source)
        let prefix = "\u{E000}mokusei-" + UUID().uuidString + "-"
        var tokens: [String: String] = [:]
        for (index, match) in footnoteReference.matches(in: source, range: NSRange(location: 0, length: raw.length)).enumerated().reversed() {
            guard !protected.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { continue }
            var cursor = match.range.location - 1, escapes = 0
            while cursor >= 0, raw.character(at: cursor) == 92 { escapes += 1; cursor -= 1 }
            guard escapes % 2 == 0 else { continue }
            let id = normalizedID(raw.substring(with: match.range(at: 1)))
            guard notes.contains(where: { $0.id == id }) else { continue }
            let token = prefix + String(index) + "\u{E001}"
            tokens[token] = id
            result.replaceCharacters(in: match.range, with: token)
        }
        return (result as String, tokens)
    }

    private static func extractFootnotes(_ source: String) -> (source: String, notes: [Footnote]) {
        guard source.contains("[^") else { return (source, []) }
        var lines = source.components(separatedBy: "\n")
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
                } else if !reduced.isEmpty,
                          footnoteDefinition.firstMatch(in: reduced, range: NSRange(reduced.startIndex..., in: reduced)) == nil,
                          let paragraph = Array(Document(parsing: (body + [reduced]).joined(separator: "\n"), options: [.disableSmartOpts]).children).last as? Paragraph,
                          let range = paragraph.range, range.lowerBound.line <= body.count,
                          range.upperBound.line == body.count + 1 {
                    body.append(reduced); lines[index] = ""; index += 1
                } else { break }
            }
            if !notes.contains(where: { $0.id == id }) { notes.append(Footnote(id: id, source: body.joined(separator: "\n"))) }
        }
        return (lines.joined(separator: "\n"), notes)
    }
}
