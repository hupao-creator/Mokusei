import AppKit
import SwiftUI
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
@testable import MokuseiPluginUI

@MainActor @Suite(.serializedNative, .requiresDisplay, .serialized)
struct SwiftUIMarkdownReadingTests {
    private func nativeTexts(_ root: NSView) -> [MarkdownTextView] {
        (root as? MarkdownTextView).map { [$0] } ?? root.subviews.flatMap(nativeTexts)
    }

    @Test func agentReaderUsesSwiftUITextAndPublishesAccessibleContent() async throws {
        let source = "# HEADING\n\nSELECTABLE **bold** `code` 中🙂\n\n- ITEM\n\n| A | B | C |\n|---|---|---|\n| x | | z |\n\n```swift\nlet value = 42\n```"
        let window = SwiftUIReplay.window(ScrollView {
            NativeMarkdownView(text: source).environment(\.nativeMarkdownUsesSwiftUIText, true).padding(20)
        }, width: 640, height: 700)
        defer { window.close() }
        let root = try #require(window.contentView)
        try await SwiftUIReplay.wait {
            let text = SwiftUIReplay.text(in: root).joined(separator: "\n")
            return text.contains("HEADING") && text.contains("SELECTABLE") && text.contains("let value = 42")
        }
        #expect(nativeTexts(root).isEmpty)
        let text = SwiftUIReplay.text(in: root).joined(separator: "\n")
        #expect(text.contains("ITEM"))
        #expect(text.contains("中🙂"))
        #expect(text.contains("z"))
        if let path = ProcessInfo.processInfo.environment["MOKUSEI_READING_MOTION_ARTIFACTS"] {
            let directory = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let image = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: image)
            try #require(image.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("swiftui-markdown.png"))
        }
    }

    @Test func otherReadersRetainTheirNativeSelectionSurface() async throws {
        let window = SwiftUIReplay.window(NativeMarkdownView(text: "Native note remains selectable"))
        defer { window.close() }
        let root = try #require(window.contentView)
        try await SwiftUIReplay.wait { nativeTexts(root).contains { $0.string == "Native note remains selectable" } }
    }

    @MainActor private final class Content: ObservableObject {
        @Published var text = "Short paragraph"
    }
    private struct ResizingReader: View {
        @ObservedObject var content: Content
        let measured: (CGFloat) -> Void
        var body: some View {
            ScrollView {
                NativeMarkdownView(text: content.text)
                    .environment(\.nativeMarkdownUsesSwiftUIText, true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measured($0) }
            }
        }
    }

    @Test func swiftUILayoutGrowsReflowsAndShrinks() async throws {
        let content = Content()
        var height: CGFloat = 0
        let window = SwiftUIReplay.window(EmptyView(), width: 700, height: 500)
        defer { window.close() }
        let host = NSHostingView(rootView: ResizingReader(content: content, measured: { height = $0 }))
        host.sizingOptions = []
        window.contentView = host
        try await SwiftUIReplay.wait { height > 0 }
        let shortHeight = height
        content.text = "# Heading\n\n" + String(repeating: "A **styled** paragraph with `inline code` and 中文🙂. ", count: 35)
        try await SwiftUIReplay.wait { height > shortHeight + 100 }
        let wideHeight = height
        window.setContentSize(CGSize(width: 350, height: 500))
        try await SwiftUIReplay.wait { height > wideHeight + 100 }
        content.text = "Short paragraph"
        try await SwiftUIReplay.wait { abs(height - shortHeight) < 1 }
    }

    @Test func footnoteLinkScrollsToItsBlock() async throws {
        let source = "[^note]\n\n" + (0..<35).map { "Filler paragraph \($0)" }.joined(separator: "\n\n") + "\n\n[^note]: FOOTNOTE DESTINATION"
        let window = SwiftUIReplay.window(ScrollView {
            NativeMarkdownView(text: source).environment(\.nativeMarkdownUsesSwiftUIText, true).padding(20)
        }, width: 500, height: 350)
        defer { window.close() }
        let root = try #require(window.contentView)
        func scroll(_ root: NSView) -> NSScrollView? {
            (root as? NSScrollView) ?? root.subviews.lazy.compactMap(scroll).first
        }
        try await SwiftUIReplay.wait { textElement("[1]", link: true, in: root) != nil }
        let viewport = try #require(scroll(root))
        let frame = try #require(textElement("[1]", link: true, in: root)).accessibilityFrame()
        if let path = ProcessInfo.processInfo.environment["MOKUSEI_READING_MOTION_ARTIFACTS"] {
            let image = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: image)
            try #require(image.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path).appendingPathComponent("footnote.png"))
        }
        try click(NSPoint(x: frame.midX, y: frame.midY), in: window)
        try await SwiftUIReplay.wait { viewport.contentView.bounds.minY > 300 }
        #expect(SwiftUIReplay.text(in: root).contains { $0.contains("FOOTNOTE DESTINATION") })
        let back = try #require(textElement(" ↩", link: true, in: root)).accessibilityFrame()
        try click(NSPoint(x: back.midX, y: back.midY), in: window)
        try await SwiftUIReplay.wait { viewport.contentView.bounds.minY < 50 }
        print("SWIFTUI_FOOTNOTE_NAVIGATION_CONFIRMED")
    }

    private func preservePasteboard() -> @MainActor () -> Void {
        let saved: [NSPasteboardItem] = NSPasteboard.general.pasteboardItems?.map { item in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        } ?? []
        return { () -> Void in
            NSPasteboard.general.clearContents()
            _ = NSPasteboard.general.writeObjects(saved)
        }
    }

    private func textElement(_ text: String, link: Bool = false, in root: NSView) -> (any NSAccessibilityProtocol)? {
        var seen = Set<ObjectIdentifier>()
        func find(_ object: AnyObject) -> (any NSAccessibilityProtocol)? {
            guard seen.insert(ObjectIdentifier(object)).inserted, let object = object as? NSObject else { return nil }
            for key in ["accessibilityValue", "accessibilityLabel"] {
                let selector = NSSelectorFromString(key)
                if object.responds(to: selector), object.perform(selector)?.takeUnretainedValue() as? String == text,
                   let element = object as? any NSAccessibilityProtocol, !link || element.accessibilityRole() == .link { return element }
            }
            let selector = NSSelectorFromString("accessibilityChildren")
            if object.responds(to: selector), let children = object.perform(selector)?.takeUnretainedValue() as? [AnyObject] {
                for child in children { if let found = find(child) { return found } }
            }
            if let view = object as? NSView {
                for child in view.subviews { if let found = find(child) { return found } }
            }
            return nil
        }
        _ = root.window?.accessibilityChildren()
        return find(root)
    }

    private func click(_ point: NSPoint, in window: NSWindow, count: Int = 1) throws {
        let oldPoint = NSEvent.mouseLocation
        let screenTop = NSScreen.screens.first?.frame.maxY ?? 0
        CGWarpMouseCursorPosition(CGPoint(x: point.x, y: screenTop - point.y))
        defer { CGWarpMouseCursorPosition(CGPoint(x: oldPoint.x, y: screenTop - oldPoint.y)) }
        let local = window.convertPoint(fromScreen: point)
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: local, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: count, pressure: 1))
        let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: local, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime + 0.01, windowNumber: window.windowNumber,
            context: nil, eventNumber: 2, clickCount: count, pressure: 0))
        NSApp.postEvent(up, atStart: true)
        NSApp.sendEvent(down)
    }

    @Test func singleParagraphSelectionCopiesThroughTheSystemResponder() async throws {
        let restore = preservePasteboard()
        defer { restore() }
        let window = SwiftUIReplay.window(NativeMarkdownView(text: "ALPHA beta GAMMA")
            .environment(\.nativeMarkdownUsesSwiftUIText, true).padding(20), width: 500, height: 180)
        defer { window.close() }
        let root = try #require(window.contentView)
        try await SwiftUIReplay.wait { textElement("ALPHA beta GAMMA", in: root) != nil }
        let frame = try #require(textElement("ALPHA beta GAMMA", in: root)).accessibilityFrame()
        // A real double click first delivers count=1, allowing SwiftUI to
        // install its system selection responder before the second down.
        try click(NSPoint(x: frame.minX + 15, y: frame.midY), in: window)
        try await SwiftUIReplay.wait { window.firstResponder is NSTextView }
        try click(NSPoint(x: frame.minX + 15, y: frame.midY), in: window, count: 2)
        try await SwiftUIReplay.wait { (window.firstResponder as? NSTextView)?.selectedRange().length == 5 }
        NSPasteboard.general.clearContents()
        #expect(NSApp.sendAction(NSSelectorFromString("copy:"), to: nil, from: nil))
        try await SwiftUIReplay.wait { NSPasteboard.general.string(forType: .string) == "ALPHA" }
        #expect(nativeTexts(root).isEmpty)
        print("SWIFTUI_PARAGRAPH_SELECTION_CONFIRMED")
    }

    @Test func swiftUILinkRoutesThroughTheDocumentAction() async throws {
        var opened: URL?
        let window = SwiftUIReplay.window(NativeMarkdownView(text: "[OPEN LINK](https://example.com/path)", openExternal: { opened = $0 })
            .environment(\.nativeMarkdownUsesSwiftUIText, true).padding(20), width: 500, height: 180)
        defer { window.close() }
        let root = try #require(window.contentView)
        try await SwiftUIReplay.wait { textElement("OPEN LINK", link: true, in: root) != nil }
        let frame = try #require(textElement("OPEN LINK", link: true, in: root)).accessibilityFrame()
        try click(NSPoint(x: frame.midX, y: frame.midY), in: window)
        try await SwiftUIReplay.wait { opened?.absoluteString == "https://example.com/path" }
        print("SWIFTUI_MARKDOWN_LINK_CONFIRMED")
    }

    @Test func parsedCopyUsesLocalPasteboardAndPreservesEmptyCellsAndUnicode() async throws {
        let source = "| A | B | C |\n|---|---|---|\n| **cafe\u{301}** | | `中🙂` |"
        let document = try await NativeMarkdownParser.shared.parse(source)
        guard case .table(let rows, _) = document.blocks.first else {
            Issue.record("Expected production parser table"); return
        }
        let restore = preservePasteboard()
        defer { restore() }
        #expect(MarkdownPlatformActions.copy(MarkdownReadingCopy.table(rows)))
        #expect(NSPasteboard.general.string(forType: .string)?.utf8.elementsEqual("A\tB\tC\ncafe\u{301}\t\t中🙂".utf8) == true)
    }
}
