import Foundation
import cmark_gfm
import cmark_gfm_extensions

/// Maps cmark's container-stripped inline input back to physical UTF-8 bytes.
/// Columns on inline nodes are logical columns, not positions in a source line
/// whose quote/list prefix may be absent (lazy continuation) or contain a tab.
enum MarkdownSourceMap {
    private struct Line {
        let content: [UInt8]
        let physicalStart: Int
        let virtualSpaces: Int
        let sourceOffsets: [Int]?
        func offset(_ column: Int) -> Int? {
            guard column >= 0, column <= content.count else { return nil }
            if let sourceOffsets { return sourceOffsets[column] }
            return physicalStart + max(0, column - virtualSpaces)
        }
    }
    private final class Trace {
        var size = 0
        var lines: [Line] = []
    }
    private struct Block {
        let firstLine: Int
        let columnOrigin: Int
        let lines: [Line]
        func offset(line: Int, column: Int) -> Int? {
            let index = line - firstLine
            guard lines.indices.contains(index) else { return nil }
            return lines[index].offset(column)
        }
    }

    static func ranges(_ source: String, visibleText: Bool) -> [NSRange] {
        let bytes = Array(source.utf8)
        let rows = bytes.split(separator: 10, omittingEmptySubsequences: false)
        var starts: [Int] = []; var position = 0
        for row in rows { starts.append(position); position += row.count + 1 }
        cmark_gfm_core_extensions_ensure_registered()
        guard let parser = cmark_parser_new(CMARK_OPT_SOURCEPOS | CMARK_OPT_TABLE_SPANS) else { return [] }
        defer { cmark_parser_free(parser) }
        for name in ["table", "strikethrough", "tasklist"] {
            cmark_parser_attach_syntax_extension(parser, cmark_find_syntax_extension(name))
        }
        for (index, row) in rows.enumerated() {
            if index == rows.count - 1 && row.isEmpty { break }
            // Match cmark's input normalization while retaining physical byte
            // positions. Only NUL-containing lines need a non-linear byte map.
            let bom = index == 0 && row.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
            let physicalStart = starts[index] + bom
            let original = Array(row.dropFirst(bom)) + [10]
            var input = original
            var inputOffsets: [Int]?
            if original.contains(0) {
                input = []
                var offsets = [physicalStart]
                for (column, byte) in original.enumerated() {
                    if byte == 0 {
                        input.append(contentsOf: [0xEF, 0xBF, 0xBD])
                        offsets.append(contentsOf: [physicalStart + column, physicalStart + column, physicalStart + column + 1])
                    } else {
                        input.append(byte); offsets.append(physicalStart + column + 1)
                    }
                }
                inputOffsets = offsets
            }
            input.withUnsafeBytes { buffer in
                cmark_parser_feed(parser, buffer.baseAddress!.assumingMemoryBound(to: CChar.self), input.count)
            }
            // This is the only parser-state access: the pinned cmark 0.9.0
            // header exposes the block that actually received this input line.
            guard let node = parser.pointee.current else { continue }
            let type = String(cString: cmark_node_get_type_string(node))
            guard type == "paragraph" || type == "heading" else { continue }
            let trace: Trace
            if let retained = cmark_node_get_user_data(node) {
                trace = Unmanaged<Trace>.fromOpaque(retained).takeUnretainedValue()
            } else {
                // The cmark block owns its trace. Freed definition-only blocks
                // cannot transfer provenance to a later allocation at that address.
                trace = Trace()
                cmark_node_set_user_data(node, Unmanaged.passRetained(trace).toOpaque())
                cmark_node_set_user_data_free_func(node) { _, retained in
                    if let retained { Unmanaged<Trace>.fromOpaque(retained).release() }
                }
            }
            let size = Int(node.pointee.content.size)
            let added = size - trace.size
            if added > 0 {
                // Copy only this line, not the growing paragraph on every feed.
                let chunk = Array(UnsafeBufferPointer(start: node.pointee.content.ptr.advanced(by: size - added), count: added))
                let consumed = Int(cmark_parser_get_offset(parser))
                if consumed >= 0, consumed <= input.count {
                    let tail = input.dropFirst(consumed)
                    let spaces = max(0, chunk.count - tail.count)
                    // Partially consumed tabs produce virtual spaces before the
                    // untouched source suffix. ATX headings can trim that suffix.
                    if chunk.prefix(spaces).allSatisfy({ $0 == 32 }),
                       chunk.dropFirst(spaces).elementsEqual(tail.prefix(chunk.count - spaces)) {
                        let sourceOffsets = inputOffsets.map { offsets in
                            Array(repeating: offsets[consumed], count: spaces) + Array(offsets[consumed...(consumed + chunk.count - spaces)])
                        }
                        trace.lines.append(Line(content: chunk, physicalStart: physicalStart + consumed,
                                                virtualSpaces: spaces, sourceOffsets: sourceOffsets))
                    }
                }
            }
            trace.size = size
        }
        guard let root = cmark_parser_finish(parser) else { return [] }
        defer { cmark_node_free(root) }

        func block(_ node: UnsafeMutablePointer<cmark_node>) -> Block? {
            guard let retained = cmark_node_get_user_data(node) else { return nil }
            let trace = Unmanaged<Trace>.fromOpaque(retained).takeUnretainedValue()
            let content = Array(UnsafeBufferPointer(start: node.pointee.content.ptr, count: Int(node.pointee.content.size)))
            var rows = content.split(separator: 10, omittingEmptySubsequences: false)
            if rows.last?.isEmpty == true { rows.removeLast() }
            let lines = Array(trace.lines.suffix(rows.count))
            guard lines.count == rows.count,
                  zip(lines, rows).allSatisfy({ line, row in
                      let body = line.content.last == 10 ? line.content.dropLast() : line.content[...]
                      return body.elementsEqual(row)
                  }) else { return nil }
            // Reference definitions disappear from the beginning of the raw
            // block buffer. Its remaining lines retain their recorded provenance;
            // neither Setext delimiters nor the next block need to be guessed.
            return Block(firstLine: Int(cmark_node_get_start_line(node)),
                         columnOrigin: Int(cmark_node_get_start_column(node) - 1 + node.pointee.internal_offset), lines: lines)
        }
        var result: [NSRange] = []
        func collect(_ node: UnsafeMutablePointer<cmark_node>, context: Block? = nil) {
            let type = String(cString: cmark_node_get_type_string(node))
            let context = (type == "paragraph" || type == "heading") ? block(node) : context
            let literal = ["code_block", "html_block", "code", "html_inline", "link", "image"].contains(type)
            if visibleText && literal { return }
            if visibleText ? type == "text" : literal {
                let firstLine = Int(cmark_node_get_start_line(node))
                let lastLine = Int(cmark_node_get_end_line(node))
                let firstColumn = Int(cmark_node_get_start_column(node))
                let lastColumn = Int(cmark_node_get_end_column(node))
                let lower: Int?, upper: Int?
                if let context {
                    lower = context.offset(line: firstLine, column: firstColumn - 1 - context.columnOrigin)
                    // cmark's multiline code/HTML end columns are already
                    // block-relative; HTML's endpoint excludes its final '>'.
                    let multilineLiteral = firstLine != lastLine && (type == "code" || type == "html_inline")
                    let end = multilineLiteral ? lastColumn + (type == "html_inline" ? 1 : 0) : lastColumn - context.columnOrigin
                    upper = context.offset(line: lastLine, column: end)
                } else {
                    // Block literals and single-line table cells have physical
                    // coordinates; they never use paragraph lazy continuation.
                    lower = starts.indices.contains(firstLine - 1) ? starts[firstLine - 1] + firstColumn - 1 : nil
                    upper = starts.indices.contains(lastLine - 1) ? starts[lastLine - 1] + lastColumn : nil
                }
                if let lower, let upper, lower >= 0, upper >= lower, upper <= bytes.count {
                    let first = source.utf8.index(source.utf8.startIndex, offsetBy: lower)
                    let last = source.utf8.index(source.utf8.startIndex, offsetBy: upper)
                    if let first = String.Index(first, within: source), let last = String.Index(last, within: source) {
                        result.append(NSRange(first..<last, in: source))
                    }
                }
                return
            }
            var child = cmark_node_first_child(node)
            while let current = child {
                collect(current, context: context)
                child = cmark_node_next(current)
            }
        }
        collect(root)
        return result
    }
}
