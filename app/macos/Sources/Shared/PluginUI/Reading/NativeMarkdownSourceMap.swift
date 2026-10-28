import Foundation
import cmark_gfm
import cmark_gfm_extensions

/// Maps cmark's container-stripped inline input back to physical UTF-8 bytes.
/// Columns on inline nodes are logical columns, not positions in a source line
/// whose quote/list prefix may be absent (lazy continuation) or contain a tab.
enum MarkdownSourceMap {
    private struct Coordinates {
        let count: Int
        let physicalStart: Int
        let virtualSpaces: Int
        let sourceOffsets: [Int]?
        func offset(_ column: Int) -> Int? {
            guard column >= 0, column <= count else { return nil }
            if let sourceOffsets { return sourceOffsets[column] }
            return physicalStart + max(0, column - virtualSpaces)
        }
    }
    private struct Line {
        let content: [UInt8]
        let coordinates: Coordinates
    }
    private final class Trace {
        var lines: [Line] = []
    }
    private final class TableOrigins {
        var columns: [Int: Int] = [:]
    }
    private struct Block {
        let firstLine: Int
        let columnOrigin: Int
        let lines: [Line]
        func offset(line: Int, column: Int) -> Int? {
            let index = line - firstLine
            guard lines.indices.contains(index) else { return nil }
            return lines[index].coordinates.offset(column)
        }
    }

    static func ranges(_ source: String, visibleText: Bool) -> [NSRange] {
        let bytes = Array(source.utf8)
        let rows = bytes.split(separator: 10, omittingEmptySubsequences: false)
        var starts: [Int] = []; var position = 0
        for row in rows { starts.append(position); position += row.count + 1 }
        cmark_gfm_core_extensions_ensure_registered()
        guard let parser = cmark_parser_new(CMARK_OPT_SOURCEPOS | CMARK_OPT_TABLE_SPANS) else { return [] }
        guard let observer = cmark_syntax_extension_new("mokusei-source-origins") else {
            cmark_parser_free(parser); return []
        }
        defer {
            cmark_parser_free(parser)
            cmark_syntax_extension_free(cmark_get_default_mem_allocator(), observer)
        }
        let tableOrigins = TableOrigins()
        cmark_syntax_extension_set_private(observer, Unmanaged.passRetained(tableOrigins).toOpaque()) { _, retained in
            if let retained { Unmanaged<TableOrigins>.fromOpaque(retained).release() }
        }
        // Observe the actual row start before the table extension consumes it.
        // Returning nil leaves grammar and AST ownership with bundled cmark.
        cmark_syntax_extension_set_open_block_func(observer) { ext, _, parser, parent, _, _ in
            if let parser, let parent, String(cString: cmark_node_get_type_string(parent)) == "table",
               let retained = cmark_syntax_extension_get_private(ext) {
                let origins = Unmanaged<TableOrigins>.fromOpaque(retained).takeUnretainedValue()
                origins.columns[Int(cmark_parser_get_line_number(parser))] = Int(cmark_parser_get_first_nonspace(parser))
            }
            return nil
        }
        cmark_parser_attach_syntax_extension(parser, observer)
        for name in ["table", "strikethrough", "tasklist"] {
            cmark_parser_attach_syntax_extension(parser, cmark_find_syntax_extension(name))
        }
        // Retain normalization coordinates for every input line, including
        // table cells and block literals that do not receive a paragraph trace.
        var inputLines: [Line] = []
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
            let coordinates = Coordinates(count: input.count, physicalStart: physicalStart,
                                          virtualSpaces: 0, sourceOffsets: inputOffsets)
            inputLines.append(Line(content: input, coordinates: coordinates))
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
            // A Setext delimiter changes a previous paragraph's type without
            // appending input. An ATX heading is created on the current line.
            if type == "heading", cmark_node_get_start_line(node) != cmark_parser_get_line_number(parser) { continue }
            let size = Int(node.pointee.content.size)
            let consumed = Int(cmark_parser_get_offset(parser))
            guard consumed >= 0, consumed <= input.count else { continue }
            let tail = input.dropFirst(consumed)
            let spaces = cmark_parser_has_partially_consumed_tab(parser) != 0
                ? 4 - Int(cmark_parser_get_column(parser)) % 4 : 0
            // Use the actual append, not net buffer growth: cmark can discard
            // leading definitions and append this line during the same feed.
            let added = type == "heading" ? size : tail.count + spaces
            guard added <= size else { continue }
            let chunk = Array(UnsafeBufferPointer(start: node.pointee.content.ptr.advanced(by: size - added), count: added))
            guard spaces <= chunk.count, chunk.prefix(spaces).allSatisfy({ $0 == 32 }),
                  chunk.dropFirst(spaces).elementsEqual(tail.prefix(chunk.count - spaces)) else { continue }
            let sourceOffsets = inputOffsets.map { offsets in
                Array(repeating: offsets[consumed], count: spaces) + Array(offsets[consumed...(consumed + chunk.count - spaces)])
            }
            let chunkCoordinates = Coordinates(count: chunk.count, physicalStart: physicalStart + consumed,
                                               virtualSpaces: spaces, sourceOffsets: sourceOffsets)
            trace.lines.append(Line(content: chunk, coordinates: chunkCoordinates))
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
        func cell(_ node: UnsafeMutablePointer<cmark_node>) -> Block? {
            let number = Int(cmark_node_get_start_line(node))
            guard inputLines.indices.contains(number - 1),
                  let row = cmark_node_parent(node), let table = cmark_node_parent(row) else { return nil }
            let input = inputLines[number - 1]
            let tableColumn = Int(cmark_node_get_start_column(table)) - 1
            let origin = cmark_gfm_extensions_get_table_row_is_header(row) != 0
                ? tableColumn : tableOrigins.columns[number] ?? tableColumn
            var first = origin + Int(cmark_node_get_start_column(node)) - 1 - tableColumn
            var end = origin + Int(cmark_node_get_end_column(node)) - tableColumn
            guard first >= 0, end >= first, end <= input.content.count else { return nil }
            // The table extension trims cells and removes backslashes before
            // pipes. Carry their positions through that transform, then verify
            // against the actual cell buffer before using any inline coordinates.
            let whitespace: Set<UInt8> = [9, 10, 11, 12, 13, 32]
            while first < end, whitespace.contains(input.content[first]) { first += 1 }
            while end > first, whitespace.contains(input.content[end - 1]) { end -= 1 }
            guard let start = input.coordinates.offset(first) else { return nil }
            var content: [UInt8] = [], offsets = [start]
            var cursor = first
            while cursor < end {
                if input.content[cursor] == 92, cursor + 1 < end, input.content[cursor + 1] == 124 { cursor += 1 }
                content.append(input.content[cursor]); cursor += 1
                guard let physical = input.coordinates.offset(cursor) else { return nil }
                offsets.append(physical)
            }
            let actual = UnsafeBufferPointer(start: node.pointee.content.ptr, count: Int(node.pointee.content.size))
            guard content.elementsEqual(actual) else { return nil }
            let coordinates = Coordinates(count: content.count, physicalStart: start, virtualSpaces: 0, sourceOffsets: offsets)
            return Block(firstLine: number,
                         columnOrigin: Int(cmark_node_get_start_column(node) - 1 + node.pointee.internal_offset),
                         lines: [Line(content: content, coordinates: coordinates)])
        }
        var result: [NSRange] = []
        func collect(_ node: UnsafeMutablePointer<cmark_node>, context: Block? = nil) {
            let type = String(cString: cmark_node_get_type_string(node))
            let context = type == "table_cell" ? cell(node)
                : (type == "paragraph" || type == "heading") ? block(node) : context
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
                    // These coordinates refer to the normalized parser input,
                    // not the original bytes (BOM and NUL affect table columns too).
                    lower = inputLines.indices.contains(firstLine - 1) ? inputLines[firstLine - 1].coordinates.offset(firstColumn - 1) : nil
                    upper = inputLines.indices.contains(lastLine - 1) ? inputLines[lastLine - 1].coordinates.offset(lastColumn) : nil
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
