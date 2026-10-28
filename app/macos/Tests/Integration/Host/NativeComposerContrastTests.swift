import AppKit
import Observation
import QuartzCore
import SwiftUI
import Testing
import MokuseiCore
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

    private struct HostPickerFixture: View {
        let draft: NativeComposerDraft
        @State private var presented = true
        var body: some View {
            Text("Host directory picker fixture")
                .sheet(isPresented: $presented) {
                    NativeComposerHostFilePicker(draft: draft, mode: .directory)
                        .environment(\.locale, Locale(identifier: "en-US"))
                }
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

    @Test func hostDirectoryPickerShowsLimitAndChoosesAfterRemovingOneReference() async throws {
        let app = NSApplication.shared
        let enableAX = NSSelectorFromString("accessibilitySetValue:forAttribute:")
        if app.responds(to: enableAX) { _ = app.perform(enableAX, with: true, with: "AXEnhancedUserInterface") }
        let root = try JSONDecoder().decode(RuntimeHostDirectory.self, from: Data(#"""
            {"reference":{"hostID":"fixture-host","path":"/fixture"},"parent":null,"entries":[
              {"reference":{"hostID":"fixture-host","path":"/fixture/dir-50"},"name":"dir-50","isDirectory":true,"size":0,"mimeType":"inode/directory"}
            ]}
            """#.utf8))
        let target = try JSONDecoder().decode(RuntimeHostDirectory.self, from: Data(#"""
            {"reference":{"hostID":"fixture-host","path":"/fixture/dir-50"},
             "parent":{"hostID":"fixture-host","path":"/fixture"},"entries":[]}
            """#.utf8))
        var browsed: [String] = []
        let draft = NativeComposerDraft(services: .init(stageFiles: { _, _ in
            Issue.record("Directory selection must not stage a file attachment")
            return []
        }, hostDirectory: { reference, lifetime in
            try lifetime.checkCancellation()
            let path = reference?.path ?? "/fixture"
            browsed.append(path)
            return path == target.reference.path ? target : root
        }, discardAttachments: { _ in }))
        for index in 0..<50 {
            let name = String(format: "dir-%02d", index)
            try #require(draft.insertDirectory(.init(name: JSONText(name), path: JSONText("/fixture/\(name)"), hostID: "fixture-host")))
        }
        let window = SwiftUIReplay.window(HostPickerFixture(draft: draft), width: 700, height: 700)
        defer { window.close() }
        try await SwiftUIReplay.wait { window.attachedSheet != nil }
        let sheet = try #require(window.attachedSheet)
        let host = try #require(sheet.contentView)
        func string(_ property: String, on element: NSObject) -> String? {
            let selector = NSSelectorFromString(property)
            guard element.responds(to: selector) else { return nil }
            return element.perform(selector)?.takeUnretainedValue() as? String
        }
        func labels(_ element: NSObject) -> [String] {
            ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].compactMap { string($0, on: element) }
        }
        func elements(in root: AnyObject) -> [NSObject] {
            var seen = Set<ObjectIdentifier>()
            var found: [NSObject] = []
            func visit(_ object: AnyObject) {
                guard seen.insert(ObjectIdentifier(object)).inserted, seen.count < 10_000,
                      let element = object as? NSObject else { return }
                found.append(element)
                let children = NSSelectorFromString("accessibilityChildren")
                if element.responds(to: children), let values = element.perform(children)?.takeUnretainedValue() as? [AnyObject] {
                    values.forEach(visit)
                }
                let legacy = NSSelectorFromString("accessibilityAttributeValue:")
                if element.responds(to: legacy), let values = element.perform(legacy, with: "AXChildren")?.takeUnretainedValue() as? [AnyObject] {
                    values.forEach(visit)
                }
                if let view = object as? NSView { view.subviews.forEach(visit) }
            }
            visit(root)
            return found
        }
        func button(named name: String) -> NSObject? {
            _ = sheet.accessibilityChildren()
            return elements(in: sheet).first { element in
                guard string("accessibilityRole", on: element) == NSAccessibility.Role.button.rawValue else { return false }
                return labels(element).contains(name) || elements(in: element).dropFirst().contains { labels($0).contains(name) }
            }
        }
        func enabled(_ element: NSObject?) -> Bool? {
            guard let element else { return nil }
            if let accessible = element as? any NSAccessibilityProtocol { return accessible.isAccessibilityEnabled() }
            let legacy = NSSelectorFromString("accessibilityAttributeValue:")
            if element.responds(to: legacy), let value = element.perform(legacy, with: "AXEnabled")?.takeUnretainedValue() as? Bool { return value }
            guard element.responds(to: NSSelectorFromString("isAccessibilityEnabled")) else { return nil }
            return element.value(forKey: "accessibilityEnabled") as? Bool
        }
        func press(_ name: String) throws {
            let element = try #require(button(named: name))
            let selector = NSSelectorFromString("accessibilityPerformPress")
            try #require(element.responds(to: selector))
            _ = element.perform(selector)
        }
        do {
            try await SwiftUIReplay.wait { enabled(button(named: "dir-50")) == true }
        } catch {
            let snapshot = elements(in: sheet).map { element in
                "\(type(of: element)) role=\(string("accessibilityRole", on: element) ?? "none") labels=\(labels(element)) enabled=\(String(describing: enabled(element)))"
            }
            print("Host picker AX diagnostics; browsed=\(browsed):\n" + snapshot.joined(separator: "\n"))
            throw error
        }
        try press("dir-50")
        let message = "You can reference up to 50 directories. Remove one before choosing another."
        try await SwiftUIReplay.wait {
            browsed.contains("/fixture/dir-50") && SwiftUIReplay.text(in: host).contains("/fixture/dir-50")
                && SwiftUIReplay.text(in: host).contains(message)
        }
        let choose = try #require(button(named: "Choose"))
        #expect(enabled(choose) == false)
        #expect(draft.directories.count == 50 && window.attachedSheet === sheet)
        #expect(!draft.directories.contains { $0.path == "/fixture/dir-50" })

        draft.removeDirectory("/fixture/dir-00")
        try await SwiftUIReplay.wait { enabled(button(named: "Choose")) == true }
        #expect(!SwiftUIReplay.text(in: host).contains(message))
        try press("Choose")
        try await SwiftUIReplay.wait {
            window.attachedSheet == nil && draft.directories.count == 50
                && draft.directories.contains { $0.path == "/fixture/dir-50" && $0.hostID == "fixture-host" }
        }
        #expect(!draft.directories.contains { $0.path == "/fixture/dir-00" })
        await draft.dispose()
    }

}
