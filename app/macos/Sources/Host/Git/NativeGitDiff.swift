import AppKit
import Foundation
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import SwiftUI

/// Parsed off the main actor by the Git detail model. Keeping this value across
/// unchanged reads preserves TextKit selection and the reader's scroll position.
public struct NativeGitParsedDiff: Sendable {
    let files: [GitDiffFile]
    public var isEmpty: Bool { files.isEmpty }

    public static func parse(_ patch: JSONText) throws -> NativeGitParsedDiff {
        guard patch.codeUnits.count <= 2 * 1024 * 1024 else { throw GitDisplayLimitError() }
        let lines = patch.string.components(separatedBy: "\n")
        guard lines.count <= 12_000, lines.allSatisfy({ $0.utf16.count <= 32_768 }) else { throw GitDisplayLimitError() }
        var parser = GitPatchParser(lines: lines)
        var files = try parser.parse()
        for fileIndex in files.indices {
            for rowIndex in files[fileIndex].rows.indices {
                try Task.checkCancellation()
                guard case .code = files[fileIndex].rows[rowIndex].kind else { continue }
                if var old = files[fileIndex].rows[rowIndex].old {
                    old.tokens = GitNativeSyntax.tokens(old.text, path: files[fileIndex].path)
                    files[fileIndex].rows[rowIndex].old = old
                }
                if var new = files[fileIndex].rows[rowIndex].new {
                    new.tokens = GitNativeSyntax.tokens(new.text, path: files[fileIndex].path)
                    files[fileIndex].rows[rowIndex].new = new
                }
            }
        }
        return NativeGitParsedDiff(files: files)
    }
}

/// The source renderer has one fixed split presentation. Its partial patches do
/// not contain omitted context, so their hunk separators have no expand action.
public struct NativeGitDiffView: View {
    private let document: NativeGitParsedDiff
    private let theme: PluginTheme
    private let locale: JSONText

    public init(document: NativeGitParsedDiff, theme: PluginTheme, locale: JSONText) {
        self.document = document; self.theme = theme; self.locale = locale
    }

    public var body: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(document.files) { file in
                    Section {
                        if !file.rows.isEmpty {
                            GitDiffFileContent(file: file, theme: theme, locale: locale)
                        } else {
                            Text(locale == "en-US" ? "No text changes. File name, mode or metadata changed." : "无文本改动；文件名、权限或元数据有变化。")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                        }
                    } header: {
                        GitDiffHeader(file: file, theme: theme)
                    }
                }
            }
            .padding(.bottom, 24)
        }
        .background(GitDiffColors(theme).background.swiftUI)
        .accessibilityLabel(locale == "en-US" ? "File diff" : "文件差异")
    }
}

private struct GitDiffFileContent: View {
    let file: GitDiffFile
    let theme: PluginTheme
    let locale: JSONText
    @State private var scrollSync = GitDiffScrollSync()
    var body: some View {
        HStack(spacing: 1) {
            if file.kind != .added {
                GitDiffColumn(file: file, addition: false, theme: theme, locale: locale, scrollSync: scrollSync)
            }
            if file.kind != .deleted {
                GitDiffColumn(file: file, addition: true, theme: theme, locale: locale, scrollSync: scrollSync)
            }
        }
        .frame(height: file.height + 14)
        .background(GitDiffColors(theme).separator.swiftUI)
        .padding(.bottom, 8)
    }
}

private struct GitDiffHeader: View {
    let file: GitDiffFile
    let theme: PluginTheme
    private var colors: GitDiffColors { GitDiffColors(theme) }
    private var oldName: String? {
        file.oldPath.flatMap { $0.utf16.elementsEqual(file.path.utf16) ? nil : $0 }
    }
    var body: some View {
        HStack(spacing: 8) {
            changeIcon
                .foregroundStyle((file.kind == .added ? colors.added : file.kind == .deleted ? colors.deleted : colors.modified).swiftUI)
            if let oldPath = oldName {
                Text(oldPath).foregroundStyle(colors.foreground.swiftUI.opacity(0.7)).lineLimit(1).truncationMode(.head)
                NativeIcon(name: "ArrowRight", size: 14)
            }
            Text(file.path).lineLimit(1).truncationMode(.head)
            Spacer(minLength: 8)
            if file.deletions > 0 || file.additions == 0 {
                Text("−\(file.deletions)").font(.system(size: 12, design: .monospaced)).foregroundStyle(colors.deleted.swiftUI)
            }
            if file.additions > 0 || file.deletions == 0 {
                Text("+\(file.additions)").font(.system(size: 12, design: .monospaced)).foregroundStyle(colors.added.swiftUI)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(colors.foreground.swiftUI)
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(colors.background.swiftUI)
        .help(oldName.map { "\($0) → \(file.path)" } ?? file.path)
    }
    @ViewBuilder private var changeIcon: some View {
        if file.kind == .deleted {
            GitDiffDeletedIcon().stroke(style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
                .frame(width: 16, height: 16).accessibilityHidden(true)
        } else { NativeIcon(name: file.kind == .added ? "FilePlus" : "FileDiff", size: 16) }
    }
}

private struct GitDiffDeletedIcon: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 14, y: 2)); path.addLine(to: CGPoint(x: 6, y: 2))
        path.addQuadCurve(to: CGPoint(x: 4, y: 4), control: CGPoint(x: 4, y: 2))
        path.addLine(to: CGPoint(x: 4, y: 20)); path.addQuadCurve(to: CGPoint(x: 6, y: 22), control: CGPoint(x: 4, y: 22))
        path.addLine(to: CGPoint(x: 18, y: 22)); path.addQuadCurve(to: CGPoint(x: 20, y: 20), control: CGPoint(x: 20, y: 22))
        path.addLine(to: CGPoint(x: 20, y: 8)); path.closeSubpath()
        path.move(to: CGPoint(x: 14, y: 2)); path.addLine(to: CGPoint(x: 14, y: 8)); path.addLine(to: CGPoint(x: 20, y: 8))
        path.move(to: CGPoint(x: 9, y: 15)); path.addLine(to: CGPoint(x: 15, y: 15))
        return path.applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24).translatedBy(x: rect.minX, y: rect.minY))
    }
}

enum GitDiffKind: Sendable { case changed, added, deleted }
struct GitDiffFile: Identifiable, Sendable {
    let id: Int
    let revision = UUID()
    var path = ""
    var oldPath: String?
    var kind = GitDiffKind.changed
    var rows: [GitDiffRow] = []
    var additions = 0
    var deletions = 0
    var height: CGFloat { rows.reduce(0) { $0 + $1.height } }
}
struct GitDiffRow: Sendable {
    enum Kind: Sendable { case code, separator(Int), noNewline }
    var kind = Kind.code
    var old: GitDiffLine?
    var new: GitDiffLine?
    var separatorTop: CGFloat = 0
    var height: CGFloat { if case .separator = kind { 40 + separatorTop } else { 20 } }
}
struct GitDiffLine: Sendable {
    let number: Int
    let text: String
    var changed = false
    var noNewline = false
    var tokens: [GitDiffToken] = []
    var emphasis: [NSRange] = []
}
struct GitDiffToken: Sendable {
    let range: NSRange
    let style: GitDiffTokenStyle
}
struct GitDiffTokenStyle: Sendable {
    let light: GitDiffColor?
    let dark: GitDiffColor?
    let lightFontStyle: Int
    let darkFontStyle: Int
    let lightBackground: GitDiffColor?
    let darkBackground: GitDiffColor?
}
struct GitDiffColor: Sendable {
    let rgb: UInt32
    let alpha: Double
}

struct GitDisplayLimitError: Error {}
private struct GitPatchError: Error {}

private struct GitPatchParser {
    let lines: [String]
    var index = 0
    private static let header = try! NSRegularExpression(pattern: #"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@"#)
    private static let paths = try! NSRegularExpression(pattern: #"^diff --git ("a/(?:[^"\\]|\\.)*"|a/.+?) ("b/(?:[^"\\]|\\.)*"|b/.+?)$"#)

    mutating func parse() throws -> [GitDiffFile] {
        var files: [GitDiffFile] = []
        while index < lines.count {
            try Task.checkCancellation()
            let header = lines[index]
            guard header.hasPrefix("diff --git ") else { index += 1; continue }
            var file = GitDiffFile(id: files.count)
            if let match = Self.paths.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)) {
                file.oldPath = Self.path(substring(header, match.range(at: 1)), prefix: true)
                file.path = Self.path(substring(header, match.range(at: 2)), prefix: true)
            }
            // Spaces are not C-quoted by Git. A name containing " b/" makes
            // the generic two-path header ambiguous. Ordinary mode-only
            // patches have no ---/+++ headers to correct it, so first recover
            // the repeated name. Renames/copies override it from metadata.
            let names = Array(header.dropFirst("diff --git ".count).utf8)
            let split = names.count / 2
            if names.count % 2 == 1, names[split] == 32 {
                let old = Self.path(String(decoding: names[..<split], as: UTF8.self), prefix: true)
                let new = Self.path(String(decoding: names[(split + 1)...], as: UTF8.self), prefix: true)
                if old == new { file.oldPath = old; file.path = new }
            }
            index += 1
            var previousEnd = 0
            while index < lines.count, !lines[index].hasPrefix("diff --git ") {
                let line = lines[index]
                if line.hasPrefix("@@ ") {
                    try hunk(into: &file, previousEnd: &previousEnd)
                    continue
                }
                if line.hasPrefix("--- ") {
                    let value = Self.path(String(line.dropFirst(4)), prefix: true)
                    if value != "/dev/null" { file.oldPath = value; if file.path.isEmpty { file.path = value } }
                } else if line.hasPrefix("+++ ") {
                    let value = Self.path(String(line.dropFirst(4)), prefix: true)
                    if value != "/dev/null" { file.path = value }
                } else if line.hasPrefix("new file mode ") { file.kind = .added
                } else if line.hasPrefix("deleted file mode ") { file.kind = .deleted
                } else if line.hasPrefix("rename from ") { file.oldPath = Self.path(String(line.dropFirst(12)))
                } else if line.hasPrefix("rename to ") { file.path = Self.path(String(line.dropFirst(10)))
                } else if line.hasPrefix("copy from ") { file.oldPath = Self.path(String(line.dropFirst(10)))
                } else if line.hasPrefix("copy to ") { file.path = Self.path(String(line.dropFirst(8))) }
                index += 1
            }
            guard !file.path.isEmpty else { throw GitPatchError() }
            files.append(file)
        }
        if files.isEmpty, lines.contains(where: { !$0.isEmpty }) { throw GitPatchError() }
        return files
    }

    private mutating func hunk(into file: inout GitDiffFile, previousEnd: inout Int) throws {
        let header = lines[index]
        guard let match = Self.header.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)),
              let oldStart = Int(substring(header, match.range(at: 1))),
              let newStart = Int(substring(header, match.range(at: 3))) else { throw GitPatchError() }
        let oldCount = Int(substring(header, match.range(at: 2))) ?? 1
        let newCount = Int(substring(header, match.range(at: 4))) ?? 1
        guard oldStart <= Int.max - oldCount, newStart <= Int.max - newCount else { throw GitPatchError() }
        let gap = max(0, newStart - (newCount > 0 ? 1 : 0) - previousEnd)
        if gap > 0 { file.rows.append(GitDiffRow(kind: .separator(gap), separatorTop: file.rows.isEmpty ? 0 : 8)) }
        index += 1
        var oldNumber = oldStart, newNumber = newStart
        var removed: [GitDiffLine] = [], added: [GitDiffLine] = []
        var lastPrefix: Character?
        func flush() throws {
            file.rows.append(contentsOf: try Self.align(removed: removed, added: added))
            removed.removeAll(keepingCapacity: true); added.removeAll(keepingCapacity: true)
        }
        while index < lines.count {
            try Task.checkCancellation()
            let raw = lines[index]
            if raw.hasPrefix("\\ No newline at end of file") {
                if lastPrefix == "-", !removed.isEmpty { removed[removed.count - 1].noNewline = true
                } else if lastPrefix == "+", !added.isEmpty { added[added.count - 1].noNewline = true
                } else if lastPrefix == " ", !file.rows.isEmpty {
                    file.rows[file.rows.count - 1].old?.noNewline = true
                    file.rows[file.rows.count - 1].new?.noNewline = true
                    file.rows.append(GitDiffRow(kind: .noNewline, old: file.rows.last?.old, new: file.rows.last?.new))
                } else { throw GitPatchError() }
                index += 1; continue
            }
            if oldNumber == oldStart + oldCount, newNumber == newStart + newCount { break }
            guard let prefix = raw.first, prefix == " " || prefix == "-" || prefix == "+" else { throw GitPatchError() }
            var text = String(raw.dropFirst())
            // A CR belongs to the line ending, not another TextKit paragraph.
            if text.last == "\r" { text.removeLast() }
            switch prefix {
            case " ":
                guard oldNumber < oldStart + oldCount, newNumber < newStart + newCount else { throw GitPatchError() }
                try flush()
                let old = GitDiffLine(number: oldNumber, text: text)
                let new = GitDiffLine(number: newNumber, text: text)
                file.rows.append(GitDiffRow(old: old, new: new)); oldNumber += 1; newNumber += 1
            case "-":
                guard oldNumber < oldStart + oldCount else { throw GitPatchError() }
                removed.append(GitDiffLine(number: oldNumber, text: text, changed: true))
                oldNumber += 1; file.deletions += 1
            default:
                guard newNumber < newStart + newCount else { throw GitPatchError() }
                added.append(GitDiffLine(number: newNumber, text: text, changed: true))
                newNumber += 1; file.additions += 1
            }
            lastPrefix = prefix; index += 1
        }
        guard oldNumber == oldStart + oldCount, newNumber == newStart + newCount else { throw GitPatchError() }
        try flush(); previousEnd = newStart + newCount - (newCount > 0 ? 1 : 0)
    }

    private static func align(removed: [GitDiffLine], added: [GitDiffLine]) throws -> [GitDiffRow] {
        let pairs = min(removed.count, added.count), surplus = abs(removed.count - added.count)
        var offset = 0
        // Bounded similarity alignment keeps nearby replacements on the same row.
        if pairs > 0, surplus > 0, pairs <= 128, surplus <= 32, pairs * (surplus + 1) <= 4096 {
            let old = removed.map { Self.withoutWhitespace($0.text) }, new = added.map { Self.withoutWhitespace($0.text) }
            var best: Double = -1
            for candidate in 0...surplus {
                try Task.checkCancellation()
                var score: Double = 0
                for pair in 0..<pairs {
                    score += similarity(old[pair + (removed.count > added.count ? candidate : 0)], new[pair + (added.count > removed.count ? candidate : 0)])
                }
                if candidate == 0 { best = score + Double(pairs) * 0.5 }
                else if score > best { offset = candidate; best = score }
            }
        }
        let oldOffset = added.count > removed.count ? offset : 0
        let newOffset = removed.count > added.count ? offset : 0
        var rows: [GitDiffRow] = []
        for row in 0..<max(removed.count + oldOffset, added.count + newOffset) {
            try Task.checkCancellation()
            let oldIndex = row - oldOffset, newIndex = row - newOffset
            var old = removed.indices.contains(oldIndex) ? removed[oldIndex] : nil
            var new = added.indices.contains(newIndex) ? added[newIndex] : nil
            // CollectionDifference is local to a small paired line. Git owns
            // the repository/hunk diff and long lines skip quadratic work.
            if let before = old?.text, let after = new?.text,
               before.utf16.count + after.utf16.count <= 1024, pairs <= 128 {
                let changes = Array(after.utf16).difference(from: Array(before.utf16))
                for change in changes {
                    switch change {
                    case .remove(let offset, _, _): old?.emphasis.append(NSRange(location: offset, length: 1))
                    case .insert(let offset, _, _): new?.emphasis.append(NSRange(location: offset, length: 1))
                    }
                }
            }
            rows.append(GitDiffRow(old: old, new: new))
            if old?.noNewline == true || new?.noNewline == true {
                rows.append(GitDiffRow(kind: .noNewline, old: old?.noNewline == true ? old : nil, new: new?.noNewline == true ? new : nil))
            }
        }
        return rows
    }
    private static func withoutWhitespace(_ text: String) -> [UInt16] {
        // Compare source code units without Unicode normalization.
        text.utf16.filter { value in
            !((9...13).contains(value) || (0x2000...0x200a).contains(value)
              || [0x20, 0xa0, 0x1680, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000, 0xfeff].contains(value))
        }
    }
    private static func similarity(_ a: [UInt16], _ b: [UInt16]) -> Double {
        if a == b { return 1 }
        let length = min(a.count, b.count)
        guard length > 0 else { return 0 }
        var prefix = 0, suffix = 0
        while prefix < length, a[prefix] == b[prefix] { prefix += 1 }
        while suffix < length - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        return Double(prefix + suffix) / Double(max(a.count, b.count))
    }
    private static func path(_ source: String, prefix: Bool = false) -> String {
        var value = source
        // Git's ---/+++ headers can append a tab (or timestamp) after a
        // quoted name. The delimiter is outside the C-quoted path itself.
        if value.first == "\"" {
            var escaped = false
            for index in value.indices.dropFirst() {
                let character = value[index]
                if escaped { escaped = false; continue }
                if character == "\\" { escaped = true; continue }
                if character == "\"" { value = String(value[...index]); break }
            }
        } else if let tab = value.firstIndex(of: "\t") { value = String(value[..<tab]) }
        if value.first == "\"", value.last == "\"" {
            let input = Array(value.dropFirst().dropLast().utf8)
            var bytes: [UInt8] = []; var i = 0
            while i < input.count {
                if input[i] != 92 { bytes.append(input[i]); i += 1; continue }
                i += 1; guard i < input.count else { break }
                if (48...55).contains(input[i]) {
                    var number = 0, count = 0
                    while i < input.count, count < 3, (48...55).contains(input[i]) {
                        number = number * 8 + Int(input[i] - 48); i += 1; count += 1
                    }
                    bytes.append(UInt8(truncatingIfNeeded: number))
                } else {
                    let escapes: [UInt8: UInt8] = [97: 7, 98: 8, 116: 9, 110: 10, 118: 11, 102: 12, 114: 13]
                    bytes.append(escapes[input[i]] ?? input[i]); i += 1
                }
            }
            value = String(decoding: bytes, as: UTF8.self)
        }
        if prefix, value.hasPrefix("a/") || value.hasPrefix("b/") { value = String(value.dropFirst(2)) }
        return value
    }
    private func substring(_ source: String, _ range: NSRange) -> String {
        range.location == NSNotFound ? "" : (source as NSString).substring(with: range)
    }
}

private struct GitDiffColors {
    let dark: Bool
    let background: NativePlatformColor
    let foreground: NativePlatformColor
    let muted: NativePlatformColor
    let separator: NativePlatformColor
    let buffer: NativePlatformColor
    let added: NativePlatformColor
    let deleted: NativePlatformColor
    let modified: NativePlatformColor
    private let addedFill: NativePlatformColor
    private let deletedFill: NativePlatformColor
    private let addedGutter: NativePlatformColor
    private let deletedGutter: NativePlatformColor
    private static let lightColors = GitDiffColors(dark: false)
    private static let darkColors = GitDiffColors(dark: true)
    private static let lab = CGColorSpace(name: CGColorSpace.genericLab)!

    init(_ theme: PluginTheme) { self = theme == .dark ? Self.darkColors : Self.lightColors }
    private init(dark: Bool) {
        self.dark = dark
        let background = NativePlatformPalette.color(dark ? 0x0a0a0a : 0xffffff)
        let foreground = NativePlatformPalette.color(dark ? 0xfafafa : 0x0a0a0a)
        let mixer = NativePlatformPalette.color(dark ? 0xffffff : 0x000000)
        let added = NativePlatformPalette.color(dark ? 0x5ecc71 : 0x0dbe4e)
        let deleted = NativePlatformPalette.color(dark ? 0xff6762 : 0xff2e3f)
        self.background = background; self.foreground = foreground
        self.added = added; self.deleted = deleted
        modified = NativePlatformPalette.color(dark ? 0x69b1ff : 0x009fff)
        muted = Self.mix(foreground, background, fraction: 0.35)
        separator = Self.mix(background, mixer, fraction: dark ? 0.15 : 0.04)
        buffer = Self.mix(background, mixer, fraction: 0.08)
        addedFill = Self.mix(background, added, fraction: dark ? 0.20 : 0.12)
        deletedFill = Self.mix(background, deleted, fraction: dark ? 0.20 : 0.12)
        addedGutter = Self.mix(background, added, fraction: dark ? 0.15 : 0.09)
        deletedGutter = Self.mix(background, deleted, fraction: dark ? 0.15 : 0.09)
    }
    func fill(addition: Bool, gutter: Bool = false) -> NativePlatformColor {
        addition ? (gutter ? addedGutter : addedFill) : (gutter ? deletedGutter : deletedFill)
    }
    func token(_ token: GitDiffToken) -> NativePlatformColor {
        guard let value = dark ? token.style.dark : token.style.light else { return foreground }
        return NativePlatformPalette.color(value.rgb, alpha: value.alpha)
    }
    private static func mix(_ base: NativePlatformColor, _ accent: NativePlatformColor, fraction: CGFloat) -> NativePlatformColor {
        // Both adapters use the original stylesheet's Lab interpolation.
        // Cache these colors once; painting only depends on visible rows.
        guard let space = NSColorSpace(cgColorSpace: lab),
              let base = base.usingColorSpace(space), let accent = accent.usingColorSpace(space) else { return base }
        var a = [CGFloat](repeating: 0, count: 4), b = a
        base.getComponents(&a); accent.getComponents(&b)
        let components = zip(a, b).map { $0 * (1 - fraction) + $1 * fraction }
        return NSColor(colorSpace: space, components: components, count: 4)
    }
}

/// One attributed document owns source ranges, row metrics and painting on both
/// platforms. Native text views only supply selection and scroll integration.
private struct GitDiffTextLayout {
    private struct DisplayRow {
        let y: CGFloat
        let height: CGFloat
        let number: Int?
        let changed: Bool
        let buffer: Bool
        let separator: Bool
        let separatorTop: CGFloat
    }
    @MainActor private static let lineWidths = NativeLineWidthCache()
    private var displayRows: [DisplayRow] = []
    private var copyableRanges: [NSRange] = []
    private let sourceText: NSString
    let text: NSAttributedString
    let palette: GitDiffColors
    let addition: Bool
    let gutter: CGFloat
    let contentWidth: CGFloat
    let contentHeight: CGFloat
    let accessibilityLabel: String

    @MainActor init(file: GitDiffFile, addition: Bool, theme: PluginTheme, locale: JSONText) {
        self.addition = addition
        palette = GitDiffColors(theme)
        let font = NativePlatformFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let maxNumber = file.rows.compactMap { (addition ? $0.new : $0.old)?.number }.max() ?? 1
        gutter = max(40, CGFloat(String(maxNumber).count) * 7.3 + 24)
        var y: CGFloat = 0, widest: CGFloat = 0
        let output = NSMutableAttributedString(string: "")
        let source = NSMutableString(capacity: 0)
        for row in file.rows {
            let line = addition ? row.new : row.old
            let paragraph = NSMutableParagraphStyle()
            paragraph.minimumLineHeight = row.height; paragraph.maximumLineHeight = row.height
            paragraph.firstLineHeadIndent = gutter + 8; paragraph.headIndent = gutter + 8
            paragraph.defaultTabInterval = font.maximumAdvancement.width * 4
            paragraph.tabStops = []; paragraph.lineBreakMode = .byClipping
            let value: String
            let separator: Bool
            switch row.kind {
            case .code: value = line?.text ?? ""; separator = false
            case .separator(let count):
                value = locale == "en-US" ? "\(count) unmodified \(count == 1 ? "line" : "lines")" : "省略 \(count) 行未修改内容"
                separator = true
            case .noNewline: value = line == nil ? "" : (locale == "en-US" ? "No final newline" : "文件末尾无换行"); separator = false
            }
            let offset = output.length
            source.append(value + "\n")
            // Git rows count LF physical lines. Visible one-code-unit glyphs
            // prevent TextKit from inventing rows for in-line separators;
            // selection offsets still address the untouched source for copy.
            let displayed = value.unicodeScalars.map { scalar -> String in
                switch scalar.value {
                case 0x000B: "␋"
                case 0x000C: "␌"
                case 0x000D: "␍"
                case 0x0085: "␤"
                case 0x2028: "↵"
                case 0x2029: "¶"
                default: String(scalar)
                }
            }.joined()
            output.append(NSAttributedString(string: displayed + "\n", attributes: [
                .font: separator ? NativePlatformFont.systemFont(ofSize: 12) : font,
                .foregroundColor: separator ? palette.muted : palette.foreground,
                .paragraphStyle: paragraph,
                .baselineOffset: 3 + (row.height - 20) / 2 + (separator && row.separatorTop == 0 ? 4 : 0),
            ]))
            if case .code = row.kind, let line {
                copyableRanges.append(NSRange(location: offset, length: (value as NSString).length + (line.noNewline ? 0 : 1)))
                for token in line.tokens {
                    let range = NSRange(location: offset + token.range.location, length: token.range.length)
                    output.addAttribute(.foregroundColor, value: palette.token(token), range: range)
                    if let background = palette.dark ? token.style.darkBackground : token.style.lightBackground {
                        output.addAttribute(.backgroundColor, value: NativePlatformPalette.color(background.rgb, alpha: background.alpha), range: range)
                    }
                    let style = palette.dark ? token.style.darkFontStyle : token.style.lightFontStyle
                    if style & 3 != 0 {
                        output.addAttribute(.font, value: Self.styledFont(font, style: style), range: range)
                    }
                    if style & 4 != 0 { output.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range) }
                }
                for emphasis in line.emphasis {
                    output.addAttribute(.backgroundColor, value: (addition ? palette.added : palette.deleted).withAlphaComponent(palette.dark ? 0.20 : 0.15), range: NSRange(location: offset + emphasis.location, length: emphasis.length))
                }
            }
            let number: Int?
            if case .code = row.kind { number = line?.number } else { number = nil }
            displayRows.append(DisplayRow(y: y, height: row.height, number: number,
                changed: line?.changed == true, buffer: line == nil && !separator,
                separator: separator, separatorTop: row.separatorTop))
            // Native font measurement includes wide Unicode and combining marks.
            widest = max(widest, Self.lineWidths.width(displayed.replacingOccurrences(of: "\t", with: "    "), font: font))
            y += row.height
        }
        text = output
        sourceText = source.copy() as! NSString
        contentWidth = ceil(widest + gutter + 24); contentHeight = y
        accessibilityLabel = locale == "en-US" ? (addition ? "New version" : "Previous version") : (addition ? "修改后" : "修改前")
    }

    @MainActor private static func styledFont(_ font: NativePlatformFont, style: Int) -> NativePlatformFont {
        var traits: NSFontTraitMask = []
        if style & 1 != 0 { traits.insert(.italicFontMask) }
        if style & 2 != 0 { traits.insert(.boldFontMask) }
        return NSFontManager.shared.convert(font, toHaveTrait: traits)
    }

    func copiedText(selections: [NSRange]) -> String? {
        // Gutters, omitted-context labels and split-alignment placeholders are
        // presentation, and must not become code when a selection is copied.
        let source = sourceText
        var fragments: [String] = []
        for selection in selections {
            guard selection.location != NSNotFound, selection.location <= source.length,
                  selection.length <= source.length - selection.location else { continue }
            for sourceRange in copyableRanges {
                let range = NSIntersectionRange(selection, sourceRange)
                if range.length > 0 { fragments.append(source.substring(with: range)) }
            }
        }
        return fragments.isEmpty ? nil : fragments.joined()
    }

    func drawBackground(in rect: CGRect, context: CGContext) {
        context.setFillColor(palette.background.cgColor); context.fill(rect)
        for row in visibleRows(rect) {
            let color = row.separator ? palette.separator : row.buffer ? palette.buffer : row.changed ? palette.fill(addition: addition) : palette.background
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: rect.minX, y: row.y + row.separatorTop, width: rect.width, height: row.separator ? 32 : row.height).intersection(rect))
        }
    }

    func drawGutter(in rect: CGRect, x: CGFloat, context: CGContext) {
        for row in visibleRows(rect) {
            let color = row.separator ? palette.separator : row.buffer ? palette.buffer : row.changed ? palette.fill(addition: addition, gutter: true) : palette.background
            context.setFillColor(palette.background.cgColor)
            context.fill(CGRect(x: x, y: row.y, width: gutter, height: row.height))
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: x, y: row.y + row.separatorTop, width: gutter, height: row.separator ? 32 : row.height))
            if let number = row.number {
                let text = String(number) as NSString
                let attributes: [NSAttributedString.Key: Any] = [.font: NativePlatformFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: row.changed ? (addition ? palette.added : palette.deleted) : palette.muted]
                let size = text.size(withAttributes: attributes)
                text.draw(at: CGPoint(x: x + gutter - size.width - 10, y: row.y + (row.height - size.height) / 2), withAttributes: attributes)
            }
            if row.changed {
                context.setFillColor((addition ? palette.added : palette.deleted).cgColor)
                context.fill(CGRect(x: x, y: row.y, width: 2, height: row.height))
            }
        }
    }

    private func visibleRows(_ rect: CGRect) -> ArraySlice<DisplayRow> {
        // Binary search keeps painting proportional to visible lines even for a
        // near-limit patch, rather than walking its entire line list per frame.
        var low = 0, high = displayRows.count
        while low < high { let mid = (low + high) / 2; if displayRows[mid].y + displayRows[mid].height < rect.minY { low = mid + 1 } else { high = mid } }
        let start = low
        while low < displayRows.count, displayRows[low].y <= rect.maxY { low += 1 }
        return displayRows[start..<low]
    }
}

private typealias GitDiffPlatformRepresentable = NSViewRepresentable

private struct GitDiffColumn: GitDiffPlatformRepresentable {
    let file: GitDiffFile
    let addition: Bool
    let theme: PluginTheme
    let locale: JSONText
    let scrollSync: GitDiffScrollSync
    func makeNSView(context: Context) -> GitDiffHorizontalScroll { GitDiffHorizontalScroll() }
    func updateNSView(_ view: GitDiffHorizontalScroll, context: Context) {
        view.configure(file: file, addition: addition, theme: theme, locale: locale, scrollSync: scrollSync)
    }
}

@MainActor private final class GitDiffScrollSync {
    private weak var old: GitDiffHorizontalScroll?
    private weak var new: GitDiffHorizontalScroll?
    private var applying = false
    func register(_ view: GitDiffHorizontalScroll, addition: Bool) {
        if addition { new = view } else { old = view }
    }
    func changed(_ source: GitDiffHorizontalScroll) {
        guard !applying, let target = source === old ? new : old else { return }
        let x = min(target.maximumHorizontalOffset, max(0, source.horizontalOffset))
        guard target.horizontalOffset != x else { return }
        applying = true
        target.setHorizontalOffset(x)
        applying = false
    }
}

/// Vertical scrolling belongs to the surrounding pinned-section reader. Each
/// side synchronizes horizontal scrolling with its peer, with gutters pinned.
private final class GitDiffHorizontalScroll: NSScrollView {
    private let code = GitDiffTextView(frame: .zero, textContainer: nil)
    private var scrollSync: GitDiffScrollSync?
    var horizontalOffset: CGFloat { contentView.bounds.minX }
    var maximumHorizontalOffset: CGFloat { max(0, (documentView?.frame.width ?? 0) - contentSize.width) }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        borderType = .noBorder; hasVerticalScroller = false; hasHorizontalScroller = true
        autohidesScrollers = false; scrollerStyle = .legacy
        drawsBackground = false; documentView = code
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: contentView)
    }
    required init?(coder: NSCoder) { nil }
    func configure(file: GitDiffFile, addition: Bool, theme: PluginTheme, locale: JSONText, scrollSync: GitDiffScrollSync) {
        self.scrollSync = scrollSync; scrollSync.register(self, addition: addition)
        code.configure(file: file, addition: addition, theme: theme, locale: locale)
        resizeDocument()
    }
    override func layout() { super.layout(); resizeDocument() }
    private func resizeDocument() {
        let size = NSSize(width: max(contentSize.width, code.contentWidth), height: code.contentHeight)
        if code.frame.size != size { code.setFrameSize(size) }
    }
    func setHorizontalOffset(_ x: CGFloat) {
        contentView.scroll(to: NSPoint(x: x, y: 0))
        reflectScrolledClipView(contentView)
    }
    @objc private func scrolled() { code.needsDisplay = true; scrollSync?.changed(self) }
    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX), !event.modifierFlags.contains(.shift) {
            nextResponder?.scrollWheel(with: event)
        } else { super.scrollWheel(with: event) }
    }
}

private final class GitDiffTextView: NSTextView {
    private let sourceStorage: NSTextStorage
    private var rendered: GitDiffTextLayout?
    private var signature: String?
    var contentWidth: CGFloat { rendered?.contentWidth ?? 0 }
    var contentHeight: CGFloat { rendered?.contentHeight ?? 0 }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        let textContainer = container ?? NSTextContainer(size: NSSize(width: 30_000_000, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(manager); manager.addTextContainer(textContainer)
        sourceStorage = storage
        super.init(frame: frameRect, textContainer: textContainer)
        isEditable = false; isSelectable = true; isRichText = true; importsGraphics = false
        drawsBackground = false; isHorizontallyResizable = false; isVerticallyResizable = false
        textContainerInset = .zero; textContainer.lineFragmentPadding = 0
        textContainer.widthTracksTextView = false
        textContainer.containerSize = NSSize(width: 30_000_000, height: CGFloat.greatestFiniteMagnitude)
        layoutManager?.usesFontLeading = false
        minSize = .zero; maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    }
    required init?(coder: NSCoder) { nil }

    func configure(file: GitDiffFile, addition: Bool, theme: PluginTheme, locale: JSONText) {
        let key = "\(file.revision):\(theme.rawValue):\(locale.string):\(addition)"
        guard key != signature else { return }; signature = key
        let value = GitDiffTextLayout(file: file, addition: addition, theme: theme, locale: locale)
        rendered = value
        let selection = selectedRanges
        textStorage?.setAttributedString(value.text)
        selectedRanges = selection.filter { NSMaxRange($0.rangeValue) <= value.text.length }
        setAccessibilityLabel(value.accessibilityLabel)
        needsDisplay = true
    }

    override func copy(_ sender: Any?) {
        guard let text = rendered?.copiedText(selections: selectedRanges.map(\.rangeValue)) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    override func drawBackground(in rect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        rendered?.drawBackground(in: rect, context: context)
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        rendered?.drawGutter(in: dirtyRect, x: enclosingScrollView?.contentView.bounds.minX ?? 0, context: context)
    }
}
