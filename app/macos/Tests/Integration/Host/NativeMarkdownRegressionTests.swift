import AppKit
import ImageIO
import SwiftUI
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
import UniformTypeIdentifiers
import MokuseiPluginUI

@MainActor @Suite(.serializedNative, .requiresDisplay, .serialized)
struct NativeMarkdownRegressionTests {
    private func texts(_ root: NSView) -> [NSTextView] {
        (root as? NSTextView).map { [$0] } ?? root.subviews.flatMap(texts)
    }

    private func links(_ root: NSView) -> [(NSTextView, URL, NSRange)] {
        texts(root).flatMap { view in
            var found: [(NSTextView, URL, NSRange)] = []
            view.textStorage?.enumerateAttribute(.link, in: NSRange(location: 0, length: view.string.utf16.count)) { value, range, _ in
                if let url = value as? URL { found.append((view, url, range)) }
            }
            return found
        }
    }

    private func window(_ source: String, width: CGFloat = 900, height: CGFloat = 700) -> NSWindow {
        SwiftUIReplay.window(ScrollView {
            ThreadMessage(id: "markdown-regression", author: .assistant, content: source)
                .padding(24)
        }, width: width, height: height)
    }

    @MainActor private final class UnicodeSource: ObservableObject {
        @Published var text = "[Distinct resource](http://127.0.0.1/caf\u{e9})"
    }

    private struct UnicodeReader: View {
        @ObservedObject var source: UnicodeSource
        var body: some View { NativeMarkdownView(text: source.text) }
    }

    @Test func mountedReaderUpdatesCanonicallyEquivalentLink() async throws {
        let source = UnicodeSource()
        let window = SwiftUIReplay.window(UnicodeReader(source: source), width: 700, height: 400)
        defer { window.close() }
        let root = try #require(window.contentView)
        try await SwiftUIReplay.wait { links(root).contains { $0.1.absoluteString.hasSuffix("caf%C3%A9") } }
        source.text = "[Distinct resource](http://127.0.0.1/cafe\u{301})"
        try await SwiftUIReplay.wait { links(root).contains { $0.1.absoluteString.hasSuffix("cafe%CC%81") } }
        #expect(!links(root).contains { $0.1.absoluteString.hasSuffix("caf%C3%A9") })
    }

    @Test func sourceSyntaxPreservesURLsFootnotesAndCode() async throws {
        let source = """
        \u{FEFF}lead `prefix [^table-map]`
        | [^table-map]`literal [^table-map]` | URL | Follow |
        | --- | --- | --- |
        | nul\0 | https://example.com/table\\|a*b | real[^table-map] |

        http://127.0.0.1/a*b*c.html

        http://127.0.0.1/a~b~c.html

        www.example.com/a*b*c.html

        See https://example.com/a\\[b\\].html end.

        Entity: &#91;^x] then escaped: \\[^x].

        Ref[^STRASSE]. Real[^rate%20value]. Ordinary[^two words].

        ```text
        UNICODE_BEFORE\u{2028}UNICODE_AFTER
        ```

        Before [![Alt `CODE` *italic*](javascript:alert)](https://example.com/after) after.

        [setext]: https://example.com/target
        `literal [^rate%20value]` and https://example.com/set*ext*path
        ===

        > lazy head
        https://example.com/lazy*a*b

        > text <span
        title="[^lazy-html]">[^lazy-html]

        [^table-map]: TABLE_MAP_NOTE
        [^lazy-html]: LAZY_HTML_NOTE
        [^two words]: https://example.com/reference
        [^x]: Unreferenced escaped note.
        [^straße]: FIRST_NOTE_LINE
        SECOND_NOTE_LINE
        [^rate%20value]: PERCENT_NOTE
        """
        let window = window(source)
        defer { window.close() }
        let root = try #require(window.contentView)
        try await SwiftUIReplay.wait { texts(root).contains { $0.string.contains("PERCENT_NOTE") } }
        let rendered = texts(root).map(\.string).joined(separator: "\n")
        #expect(rendered.contains("Entity: [^x] then escaped: [^x]."))
        #expect(rendered.contains("UNICODE_BEFORE\u{2028}UNICODE_AFTER"))
        #expect(rendered.contains("Alt CODE italic"))
        #expect(!rendered.contains("Alt `CODE`"))
        #expect(texts(root).contains { $0.string.contains("FIRST_NOTE_LINE SECOND_NOTE_LINE") })
        let destinations = links(root).map { $0.1.absoluteString }
        #expect(destinations.contains("https://example.com/reference"))
        #expect(destinations.contains("https://example.com/set*ext*path"))
        #expect(destinations.contains("https://example.com/lazy*a*b"))
        #expect(rendered.contains("title=\"[^lazy-html]\""))
        #expect(rendered.contains("LAZY_HTML_NOTE"))
        #expect(rendered.contains("TABLE_MAP_NOTE"))
        #expect(rendered.contains("literal [^table-map]"))
        #expect(rendered.contains("prefix [^table-map]"))
        #expect(destinations.contains(URL(string: "https://example.com/table|a*b")!.absoluteString))
        #expect(rendered.contains("literal [^rate%20value]"))
        #expect(destinations.contains("http://127.0.0.1/a*b*c.html"))
        #expect(destinations.contains("http://127.0.0.1/a~b~c.html"))
        #expect(destinations.contains("http://www.example.com/a*b*c.html"))
        #expect(destinations.contains("https://example.com/a%5Bb%5D.html") || destinations.contains("https://example.com/a[b].html"))
        #expect(rendered.contains("See https://example.com/a[b].html end."))
        #expect(links(root).filter { $0.1.fragment != nil && !$0.1.absoluteString.contains("reference") }.count == 5)
        #expect(!rendered.contains("mokusei-"))
    }

    @Test func nativeCopyPreservesImageAlternativeText() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("markdown-copy-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: file) }
        let context = try #require(CGContext(data: nil, width: 20, height: 10, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let destination = try #require(CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        let window = window("Before ![IMPORTANT ALT](<\(file.path)>) after")
        defer { window.close() }
        let root = try #require(window.contentView)
        try await SwiftUIReplay.wait { texts(root).contains { $0.string.contains("\u{FFFC}") } }
        let paragraph = try #require(texts(root).first { $0.string.hasPrefix("Before ") })
        window.makeFirstResponder(paragraph)
        paragraph.setSelectedRange(NSRange(location: 0, length: paragraph.string.utf16.count))
        paragraph.copy(nil)
        #expect(NSPasteboard.general.string(forType: .string) == "Before IMPORTANT ALT after")
        paragraph.selectAll(nil)
        paragraph.copy(nil)
        #expect(NSPasteboard.general.string(forType: .string) == "Before IMPORTANT ALT after")
    }

    @Test func fullTableCopyPreservesEmptyColumns() async throws {
        let window = window("""
            | H1 | H2 | H3 |
            | --- | --- | --- |
            | A |  | C |
            |  | B |  |
            """)
        defer { window.close() }
        let root = try #require(window.contentView)
        try await SwiftUIReplay.wait { texts(root).contains { $0.string == "C" } }
        let cell = try #require(texts(root).first { $0.string == "A" })
        window.makeFirstResponder(cell)
        cell.selectAll(nil)
        cell.copy(nil)
        #expect(NSPasteboard.general.string(forType: .string) == "H1\tH2\tH3\nA\t\tC\n\tB\t")
    }

    @Test func commandArrowClearsEveryJoinedSelection() async throws {
        let window = window("First paragraph.\n\nSecond paragraph.\n\n```text\nCODE_BLOCK\n```\n\nThird paragraph.")
        defer { window.close() }
        let root = try #require(window.contentView)
        try await SwiftUIReplay.wait { texts(root).contains { $0.string == "Third paragraph." } }
        let first = try #require(texts(root).first { $0.string == "First paragraph." })
        window.makeFirstResponder(first)
        first.selectAll(nil)
        #expect(texts(root).filter { $0.selectedRange().length > 0 }.count == 4)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{F703}", charactersIgnoringModifiers: "\u{F703}", isARepeat: false, keyCode: 124))
        first.keyDown(with: event)
        #expect(texts(root).allSatisfy { $0.selectedRange().length == 0 })
    }

    @Test func tableCodeAndLongListMarkersKeepSingleLines() async throws {
        let window = window("""
            123456789. Nine-digit marker A
            123456790. Nine-digit marker B

            | Code letters | Code digits |
            | --- | --- |
            | `ABCDEFGHIJ` | `1234567890` |
            """)
        defer { window.close() }
        let root = try #require(window.contentView)
        try await SwiftUIReplay.wait { texts(root).contains { $0.string.contains("ABCDEFGHIJ") } }
        let singleLines = texts(root).filter { $0.string == "123456789." || $0.string == "123456790." || $0.string.contains("ABCDEFGHIJ") || $0.string.contains("1234567890") }
        #expect(singleLines.count == 4)
        for view in singleLines {
            let layout = try #require(view.layoutManager)
            layout.ensureLayout(for: try #require(view.textContainer))
            var lineCount = 0
            layout.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layout.numberOfGlyphs)) { _, _, _, _, _ in lineCount += 1 }
            #expect(lineCount == 1)
        }
        let letters = try #require(texts(root).first { $0.string.contains("ABCDEFGHIJ") })
        let digits = try #require(texts(root).first { $0.string.contains("1234567890") })
        #expect(abs(letters.convert(letters.bounds, to: nil).maxY - digits.convert(digits.bounds, to: nil).maxY) < 1)
    }

    @Test func emptyQuoteLineDoesNotLoosenItsOuterList() async throws {
        var heights: [CGFloat] = []
        for source in ["* a\n  > b\n  >\n* c", "* a\n  > b\n* c"] {
            let window = window(source)
            defer { window.close() }
            let root = try #require(window.contentView)
            try await SwiftUIReplay.wait { texts(root).contains { $0.string == "c" } }
            let first = try #require(texts(root).first { $0.string == "a" })
            let last = try #require(texts(root).first { $0.string == "c" })
            heights.append(abs(first.convert(first.bounds, to: nil).maxY - last.convert(last.bounds, to: nil).maxY))
        }
        #expect(abs(heights[0] - heights[1]) < 1)
    }

    @Test func tableFootnotesReturnAcrossNestedViewports() async throws {
        let middle = (0..<30).map { "Paragraph \($0) provides enough content for a real native scroll." }.joined(separator: "\n\n")
        let window = window("| Column | Value |\n| --- | --- |\n| Reference | Table note[^rate%20value]. |\n\n" + middle + "\n\n[^rate%20value]: TABLE_FOOTNOTE_TARGET", height: 500)
        defer { window.close() }
        let root = try #require(window.contentView)
        try await SwiftUIReplay.wait { links(root).contains { $0.0.string.contains("TABLE_FOOTNOTE_TARGET") } }
        let reference = try #require(links(root).first { $0.0.string.contains("Table note") })
        let initialY = reference.0.convert(reference.0.bounds, to: nil).maxY
        #expect(reference.0.delegate?.textView?(reference.0, clickedOnLink: reference.1, at: reference.2.location) == true)
        try await SwiftUIReplay.wait { abs(reference.0.convert(reference.0.bounds, to: nil).maxY - initialY) > 100 }
        let backlink = try #require(links(root).first { $0.0.string.contains("TABLE_FOOTNOTE_TARGET") })
        #expect(backlink.0.delegate?.textView?(backlink.0, clickedOnLink: backlink.1, at: backlink.2.location) == true)
        try await SwiftUIReplay.wait { abs(reference.0.convert(reference.0.bounds, to: nil).maxY - initialY) < 80 }
    }
}
