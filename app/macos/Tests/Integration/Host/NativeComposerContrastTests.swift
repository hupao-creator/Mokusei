import AppKit
import Observation
import QuartzCore
import SwiftUI
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
@testable import MokuseiPluginUI

@MainActor
@Suite(.serializedNative, .requiresDisplay, .serialized)
struct NativeComposerContrastTests {
    @MainActor @Observable final class Draft { var text = "Existing draft 草稿" }

    private struct Fixture: View {
        let draft: Draft
        let scheme: ColorScheme
        var disabled = false
        var body: some View {
            NativeComposerTextInput(value: Binding(get: { draft.text }, set: { draft.text = $0 }),
                placeholder: "Ask Moku…", disabled: disabled, automaticFocus: false,
                minHeight: 58, maxHeight: 126, fontSize: 14, lineHeight: 20,
                insets: .init(top: 19, left: 6, bottom: 19, right: 6), onSubmit: {})
                .frame(width: 420, height: 58)
                .background(scheme == .dark ? Color.black : Color.white)
                .preferredColorScheme(scheme)
        }
    }

    private func editor(in view: NSView) -> NSTextView? { SwiftUIReplay.editor(in: view) }

    private func settle(_ host: NSView) async throws {
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(10))
            host.layoutSubtreeIfNeeded()
        }
    }

    private func luminance(_ color: NSColor) throws -> Double {
        let rgb = try #require(color.usingColorSpace(.sRGB))
        func linear(_ value: CGFloat) -> Double {
            let value = Double(value)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
    }

    private func contrast(_ color: NSColor, onDark: Bool) throws -> Double {
        var resolved: Double?
        NSAppearance(named: onDark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance { resolved = try? luminance(color) }
        let ink = try #require(resolved)
        return onDark ? (ink + 0.05) / 0.05 : 1.05 / (ink + 0.05)
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func themeChangesUpdateExistingTextAndTypingDespiteOppositeHost(initial: ColorScheme) async throws {
        _ = NSApplication.shared
        let draft = Draft()
        let host = NSHostingView(rootView: Fixture(draft: draft, scheme: initial))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 58),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        try await settle(host)
        let text = try #require(editor(in: host))
        try await settle(host)
        text.setSelectedRange(NSRange(location: 4, length: 2))

        for scheme in [initial, initial == .dark ? .light : .dark] {
            host.rootView = Fixture(draft: draft, scheme: scheme)
            try await settle(host)
            #expect(editor(in: host) === text)
            #expect(text.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == (scheme == .dark ? .darkAqua : .aqua))
            #expect(text.string == draft.text)
            #expect(text.selectedRange() == NSRange(location: 4, length: 2))
            let foreground = try #require(text.textColor)
            let typing = try #require(text.typingAttributes[.foregroundColor] as? NSColor)
            #expect(try contrast(foreground, onDark: scheme == .dark) >= 4.5)
            #expect(try contrast(typing, onDark: scheme == .dark) >= 4.5)
            #expect(try contrast(text.insertionPointColor, onDark: scheme == .dark) >= 3)

        }

        // Recoloring must leave the input method's marked text and selection intact.
        text.setMarkedText("拼音", selectedRange: NSRange(location: 1, length: 0), replacementRange: text.selectedRange())
        text.didChangeText() // Deliver the editing notification as an input session does.
        try await settle(host)
        let marked = text.markedRange()
        let selection = text.selectedRange()
        let composing = text.string
        host.rootView = Fixture(draft: draft, scheme: initial)
        try await settle(host)
        #expect(text.hasMarkedText())
        #expect(text.markedRange() == marked)
        #expect(text.selectedRange() == selection)
        #expect(text.string == composing)
        text.unmarkText()

        host.rootView = Fixture(draft: draft, scheme: initial, disabled: true)
        try await settle(host)
        #expect(window.firstResponder !== text)
        #expect(try contrast(try #require(text.textColor), onDark: initial == .dark) >= 4.5)
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func drawnPlaceholderHasReadableContrast(scheme: ColorScheme) async throws {
        _ = NSApplication.shared
        let draft = Draft()
        draft.text = ""
        let host = NSHostingView(rootView: Fixture(draft: draft, scheme: scheme))
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 58)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        try await settle(host)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        var strongestContrast = 1.0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                if let color = bitmap.colorAt(x: x, y: y) {
                    strongestContrast = max(strongestContrast, try contrast(color, onDark: scheme == .dark))
                }
            }
        }
        #expect(strongestContrast >= 4.5)
    }

}
