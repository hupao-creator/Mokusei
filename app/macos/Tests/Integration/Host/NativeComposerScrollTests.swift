import AppKit
import SwiftUI
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
import MokuseiPluginUI

@MainActor
@Suite(.serializedNative, .requiresDisplay, .serialized)
struct NativeComposerScrollTests {
    private func editor(in view: NSView) -> NSTextView? { SwiftUIReplay.editor(in: view) }

    @Test(arguments: ["", "Hello Moku", "你好 Moku"], [false, true])
    func singleLineFitsWithoutScrolling(sample: String, emphasized: Bool) async throws {
        let window = SwiftUIReplay.window(NativeComposerTextInput(value: .constant(sample), placeholder: "Ask Moku…",
            automaticFocus: false, minHeight: 58, maxHeight: 126, fontSize: 14, lineHeight: 20,
            insets: .init(top: 19, left: 6, bottom: 19, right: 6), onSubmit: {},
            emphasizedInsertionPoint: emphasized), width: 420, height: 58)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(150))
        let host = try #require(window.contentView)
        host.layoutSubtreeIfNeeded()
        let text = try #require(editor(in: host))
        let scroll = try #require(text.enclosingScrollView)
        let caret = text.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil)
        let bounds = window.convertToScreen(host.convert(host.bounds, to: nil))
        #expect(text.bounds.height <= scroll.contentView.bounds.height + 1)
        // A legacy scroller stays resident to keep its gutter stable; it must
        // still show no knob while the single line fits.
        #expect((scroll.verticalScroller?.knobProportion ?? 0) == 0)
        #expect(abs(caret.midY - bounds.midY) <= 0.5)
    }

    @Test(arguments: [false, true], [false, true])
    func lastLineRemainsReachableAfterNativeResize(compact: Bool, trailingNewline: Bool) async throws {
        _ = NSApplication.shared
        let insets = compact ? NativeComposerInsets(top: 13, left: 6, bottom: 13, right: 6)
            : NativeComposerInsets(top: 15, left: 16, bottom: 8, right: 16)
        let sample = String(repeating: "没有 transition，采用 https://developer.apple.com/tutorials/videos/com.apple.SwiftUI/liquid-glass-morph-views~dark.mp4，正好 tag filter 里的 tag 也都是 liquid glass。\n", count: 3)
            + "完成后先给我一个 demo 预览，然后我再决定。" + (trailingNewline ? "\n" : "")
        let host = NSHostingView(rootView: NativeComposerTextInput(value: .constant(sample), placeholder: "Composer",
            automaticFocus: false, minHeight: compact ? 46 : 54, maxHeight: compact ? 126 : 180,
            fontSize: compact ? 14 : 13.5, lineHeight: compact ? 20 : 20.925, insets: insets, onSubmit: {}, emphasizedInsertionPoint: true))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }

        for width: CGFloat in [320, 240, 560] {
            window.setContentSize(NSSize(width: width, height: 200))
            for _ in 0..<10 {
                try await Task.sleep(for: .milliseconds(10))
                host.layoutSubtreeIfNeeded()
            }
            let text = try #require(editor(in: host))
            #expect(text.string == sample)
            text.setSelectedRange(NSRange(location: sample.utf16.count, length: 0))
            text.scrollRangeToVisible(text.selectedRange())
            try await Task.sleep(for: .milliseconds(50))
            let range = trailingNewline ? text.selectedRange() : NSRange(location: sample.utf16.count - 1, length: 1)
            let caret = text.firstRect(forCharacterRange: range, actualRange: nil)
            let scroll = try #require(text.enclosingScrollView)
            #expect(scroll.hasVerticalScroller)
            let viewport = window.convertToScreen(scroll.convert(scroll.bounds, to: nil))
            #expect(caret.height > 0 && caret.midY >= viewport.minY - 1 && caret.midY <= viewport.maxY + 1)
            #expect(text.selectedRange().location == sample.utf16.count)
        }
    }
}
