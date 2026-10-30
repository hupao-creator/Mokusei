import AppKit
import Observation
import SwiftUI
import Testing
import MokuseiCore
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
@testable import MokuseiPluginUI
@testable import MokuseiUI

@MainActor @Observable private final class SearchInputFixture {
    var text = ""
    var request = 1
    var exits = 0
}
private struct SearchInputReplay: View {
    let fixture: SearchInputFixture
    var body: some View {
        OverviewThreadSearchField(text: fixture.text, placeholder: "搜索会话", focusRequest: fixture.request,
            onChange: { fixture.text = $0 }, onExit: { fixture.exits += 1 })
            .padding(20)
    }
}

@MainActor @Suite(.serializedNative, .serialized)
struct SwiftUIOverviewInteractionTests {
    private func field(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        return view.subviews.lazy.compactMap { field(in: $0) }.first
    }

    @Test(.requiresDisplay) func searchEditsChineseAndRepeatedFocusSelectsCurrentText() async throws {
        let fixture = SearchInputFixture()
        let window = SwiftUIReplay.window(SearchInputReplay(fixture: fixture), width: 500, height: 100)
        defer { window.close() }
        let root = try #require(window.contentView)
        try await SwiftUIReplay.wait { SwiftUIReplay.editor(in: root) != nil }
        let editor = try #require(SwiftUIReplay.editor(in: root))
        // AppKit can retain a negative clip origin after the document grows
        // from its initial, shorter height during the search morph.
        let scroll = try #require(editor.enclosingScrollView)
        editor.setFrameSize(NSSize(width: editor.frame.width, height: 25))
        let constrained = scroll.contentView.constrainBoundsRect(scroll.contentView.bounds)
        #expect(constrained.origin.y == 0)
        scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: -15))
        scroll.needsLayout = true
        scroll.layoutSubtreeIfNeeded()
        #expect(scroll.contentView.bounds.origin.y == 0)
        editor.setMarkedText("ni", selectedRange: .init(location: 2, length: 0), replacementRange: .init(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
        scroll.contentView.scroll(to: NSPoint(x: 0, y: -15))
        #expect(scroll.contentView.bounds.origin.y == 0 && editor.hasMarkedText())
        editor.insertText("你好世界", replacementRange: .init(location: NSNotFound, length: 0))
        try await SwiftUIReplay.wait { fixture.text == "你好世界" }
        #expect(!editor.hasMarkedText())
        fixture.request += 1
        try await SwiftUIReplay.wait { editor.selectedRange() == NSRange(location: 0, length: 4) }
        editor.insertText("SwiftUI", replacementRange: .init(location: NSNotFound, length: 0))
        try await SwiftUIReplay.wait { fixture.text == "SwiftUI" }
        #expect(fixture.exits == 0)
        let longQuery = String(repeating: "long query ", count: 30)
        editor.insertText(longQuery, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        try await SwiftUIReplay.wait { fixture.text == longQuery }
        editor.scrollRangeToVisible(NSRange(location: longQuery.utf16.count, length: 0))
        let horizontalOrigin = scroll.contentView.bounds.origin.x
        #expect(horizontalOrigin > 0)
        scroll.contentView.scroll(to: NSPoint(x: horizontalOrigin, y: -15))
        #expect(scroll.contentView.bounds.origin.y == 0)
        #expect(scroll.contentView.bounds.origin.x == horizontalOrigin)
        scroll.needsLayout = true
        scroll.layoutSubtreeIfNeeded()
        #expect(scroll.contentView.bounds.origin.x == horizontalOrigin)
        #expect(scroll.contentView.bounds.origin.y == 0)
    }

    @Test(.requiresDisplay) func focusedCardPausesCameraUntilFocusLeaves() async throws {
        let state = NativeOverviewCanvasState()
        let input = SearchInputFixture()
        let items = (0..<20).map { NativeOverviewItem(id: "focus-\($0)", carouselEligible: $0 == 0) }
        let window = SwiftUIReplay.window(NativeOverviewCanvas(items: items, sceneKey: "focus", state: state) { item in
            if item.id == "focus-0" {
                TextField("Card input", text: Binding(get: { input.text }, set: { input.text = $0 }))
                    .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { Text(item.id).frame(maxWidth: .infinity, maxHeight: .infinity) }
        })
        defer { window.close() }
        let root = try #require(window.contentView)
        try await SwiftUIReplay.wait { !state.isLayingOut && state.camera.carouselTargetID != nil && field(in: root) != nil }
        let editor = try #require(SwiftUIReplay.editor(in: root))
        #expect(window.firstResponder === editor)
        try await SwiftUIReplay.wait { state.camera.carouselPaused }
        state.beginInteraction(cardID: "focus-0"); state.endInteraction(cardID: "focus-0")
        #expect(state.camera.carouselPaused && !state.camera.manual)
        window.makeFirstResponder(nil)
        try await SwiftUIReplay.wait { !state.camera.carouselPaused }
    }

    @Test func adaptivePaletteRendersBothAppearancesWithoutNativeColors() throws {
        for (scheme, expected) in [(ColorScheme.light, 0xf8f7f4), (.dark, 0x20211f)] {
            let renderer = ImageRenderer(content: Rectangle().fill(NativePalette.overview.canvas.swiftUI)
                .frame(width: 8, height: 8).environment(\.colorScheme, scheme))
            let image = try #require(renderer.cgImage)
            let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 8, height: 8))
            let bytes = try #require(context.data?.assumingMemoryBound(to: UInt8.self))
            let offset = (4 * 8 + 4) * 4
            #expect(abs(Int(bytes[offset]) - ((expected >> 16) & 255)) < 2)
            #expect(abs(Int(bytes[offset + 1]) - ((expected >> 8) & 255)) < 2)
            #expect(abs(Int(bytes[offset + 2]) - (expected & 255)) < 2)
        }
    }
}

@MainActor @Observable private final class OverviewTextFixture {
    let visibility = ThreadCardAnimationVisibility()
    let presentation = try! composeThreadCard(.standard(extensions: []), layoutContext: .init(availableCols: 1))
    var title = "Title A"
    var content = "Initial excerpt"
    var message = "Initial excerpt"
    var messageID: JSONText = "message"
    var scenePhase = ScenePhase.active
    var reduceMotion = false
    var suppliesVisibility = true
    @ObservationIgnored var appearances = 0
    @ObservationIgnored var disappearances = 0
    @ObservationIgnored var identities: [UUID] = []

    func setMessage(_ text: String, id: JSONText = "message", excerpt: String? = nil) {
        message = text; messageID = id; content = excerpt ?? String(text.suffix(600))
    }
}

private struct OverviewTextReplay: View {
    let fixture: OverviewTextFixture
    var titleOnly = false
    @State private var identity = UUID()
    var body: some View {
        Group {
            if titleOnly {
                HarnessThreadCard(identity: .init(title: fixture.title, excerpt: ""), presentation: fixture.presentation)
            } else {
                ThreadCardExcerpt(content: fixture.content, messageId: fixture.messageID, messageText: fixture.message)
                    .padding(18)
            }
        }
        .frame(width: 360, height: 200)
        .background(Color.white)
        .environment(\.locale, Locale(identifier: "en"))
        .environment(\.colorScheme, .light)
        .environment(\.scenePhase, fixture.scenePhase)
        .environment(\.accessibilityReduceMotion, fixture.reduceMotion)
        .environment(\.threadCardAnimationVisibility, fixture.suppliesVisibility ? fixture.visibility : nil)
        .environment(\.threadCardCloudAnimationsEnabled, false)
        .onAppear { fixture.appearances += 1; fixture.identities.append(identity) }
        .onDisappear { fixture.disappearances += 1 }
    }
}

extension SwiftUIOverviewInteractionTests {
    @Test(.requiresDisplay) func streamingTitlesMakeProgressBeforeInputStops() async throws {
        let fixture = OverviewTextFixture()
        let window = SwiftUIReplay.window(OverviewTextReplay(fixture: fixture, titleOnly: true), width: 360, height: 200)
        defer { window.close() }
        let root = try #require(window.contentView)
        try await SwiftUIReplay.wait { SwiftUIReplay.text(in: root).contains("Title A") }
        var displayedDuringStream = Set<String>()
        for index in 1...12 {
            fixture.title = "Streaming title \(index)"
            try await Task.sleep(for: .milliseconds(100))
            // The helper reads AX label/value, never the outer card's .help
            // text, so observing a title means its displayed Text was replaced.
            displayedDuringStream.formUnion(SwiftUIReplay.text(in: root).filter { $0.hasPrefix("Streaming title ") })
        }
        #expect(displayedDuringStream.count >= 2)
        try await SwiftUIReplay.wait { SwiftUIReplay.text(in: root).contains("Streaming title 12") }
        #expect(fixture.appearances == 1)
    }

    @Test(.requiresDisplay) func titleReversalAndVisibilityCancellationSettlePixels() async throws {
        let fixture = OverviewTextFixture()
        let window = SwiftUIReplay.window(OverviewTextReplay(fixture: fixture, titleOnly: true), width: 360, height: 200)
        defer { window.close() }
        let root = try #require(window.contentView)
        try await SwiftUIReplay.wait { SwiftUIReplay.text(in: root).contains("Title A") }
        try await Task.sleep(for: .milliseconds(350))
        let original = try textPixels(in: root)
        fixture.title = "Title B"
        try await Task.sleep(for: .milliseconds(50))
        fixture.title = "Title A"
        try await Task.sleep(for: .milliseconds(500))
        #expect(try textPixels(in: root) == original)

        fixture.title = "Cancelled title"
        try await Task.sleep(for: .milliseconds(40))
        fixture.visibility.isVisible = false
        fixture.title = "Hidden latest"
        try await SwiftUIReplay.wait { SwiftUIReplay.text(in: root).contains("Hidden latest") }
        let hidden = try textPixels(in: root)
        fixture.visibility.isVisible = true
        try await Task.sleep(for: .milliseconds(20))
        fixture.visibility.isVisible = false
        try await Task.sleep(for: .milliseconds(350))
        #expect(try textPixels(in: root) == hidden)

        fixture.visibility.isVisible = true
        fixture.scenePhase = .background
        fixture.title = "Background latest"
        try await SwiftUIReplay.wait { SwiftUIReplay.text(in: root).contains("Background latest") }
        let background = try textPixels(in: root)
        fixture.scenePhase = .inactive
        try await Task.sleep(for: .milliseconds(350))
        #expect(try textPixels(in: root) == background)
        fixture.reduceMotion = true
        fixture.title = "Reduced motion latest"
        try await SwiftUIReplay.wait { SwiftUIReplay.text(in: root).contains("Reduced motion latest") }
        let reduced = try textPixels(in: root)
        try await Task.sleep(for: .milliseconds(350))
        #expect(try textPixels(in: root) == reduced)
        #expect(fixture.appearances == 1)
    }

    @Test(.requiresDisplay) func retainedExcerptsPauseHiddenBacklogAndResumeLatestInput() async throws {
        let fixture = OverviewTextFixture()
        fixture.visibility.isVisible = false
        let window = SwiftUIReplay.window(OverviewTextReplay(fixture: fixture), width: 360, height: 200)
        defer { window.close() }
        let root = try #require(window.contentView)
        fixture.setMessage("First hidden replacement")
        fixture.setMessage("Latest before first appearance")
        try await Task.sleep(for: .milliseconds(100))
        fixture.visibility.isVisible = true
        try await SwiftUIReplay.wait { SwiftUIReplay.text(in: root).contains("Latest before first appearance") }

        let first = String(repeating: "A", count: 600), second = String(repeating: "B", count: 600)
        fixture.setMessage(first + second + "old tail")
        try await SwiftUIReplay.wait { SwiftUIReplay.text(in: root).contains(first) }
        fixture.visibility.isVisible = false
        try await Task.sleep(for: .milliseconds(100))
        let hidden = SwiftUIReplay.text(in: root), hiddenPixels = try textPixels(in: root)
        fixture.setMessage(first + second + "latest hidden tail", excerpt: "latest hidden tail")
        try await Task.sleep(for: .milliseconds(1_200))
        #expect(SwiftUIReplay.text(in: root) == hidden)
        #expect(try textPixels(in: root) == hiddenPixels)
        fixture.visibility.isVisible = true
        try await SwiftUIReplay.wait { SwiftUIReplay.text(in: root).contains("latest hidden tail") }
        let resumed = try textPixels(in: root)
        try await Task.sleep(for: .milliseconds(350))
        #expect(try textPixels(in: root) == resumed)

        fixture.scenePhase = .background
        try await Task.sleep(for: .milliseconds(50))
        fixture.setMessage("new background message", id: "replacement")
        try await Task.sleep(for: .milliseconds(100))
        #expect(SwiftUIReplay.text(in: root).contains("latest hidden tail"))
        fixture.scenePhase = .inactive
        try await SwiftUIReplay.wait { SwiftUIReplay.text(in: root).contains("new background message") }
        #expect(fixture.appearances == 1)
    }

    @Test(.requiresDisplay) func excerptWindowsAdvanceDuringAppendsAndRespectCurrentMotionPolicy() async throws {
        let fixture = OverviewTextFixture()
        fixture.suppliesVisibility = false
        fixture.visibility.isVisible = false
        fixture.setMessage("A")
        let window = SwiftUIReplay.window(OverviewTextReplay(fixture: fixture), width: 360, height: 200)
        defer { window.close() }
        let root = try #require(window.contentView)
        try await SwiftUIReplay.wait { SwiftUIReplay.text(in: root).contains("A") }
        fixture.setMessage("AB")
        try await SwiftUIReplay.wait { SwiftUIReplay.text(in: root).contains("AB") }
        let first = "AB" + String(repeating: "A", count: 598), second = String(repeating: "B", count: 600)
        fixture.setMessage(first)
        try await SwiftUIReplay.wait { SwiftUIReplay.text(in: root).contains(first) }
        try await Task.sleep(for: .milliseconds(180))
        // Crossing 600 characters changes `more`, but later appends must not
        // reset the hold while the current window and its Markdown context match.
        fixture.setMessage(first + second)
        var advancedDuringInput = false
        for index in 1...9 {
            if index == 2 { fixture.reduceMotion = true }
            fixture.setMessage(first + second + String(repeating: "c", count: index))
            try await Task.sleep(for: .milliseconds(100))
            if SwiftUIReplay.text(in: root).contains(second) {
                advancedDuringInput = true
                let settled = try textPixels(in: root)
                try await Task.sleep(for: .milliseconds(60))
                #expect(try textPixels(in: root) == settled)
                break
            }
        }
        #expect(advancedDuringInput)
        // A rewrite must invalidate the reused full-window preview, even at the
        // same offset; changing message identity must do so as well.
        fixture.setMessage("**rewritten** text")
        try await SwiftUIReplay.wait { SwiftUIReplay.text(in: root).contains("rewritten text") }
        fixture.setMessage("**replacement** text", id: "new-message")
        try await SwiftUIReplay.wait { SwiftUIReplay.text(in: root).contains("replacement text") }

        // Keep a full displayed window while the transport drops its consumed
        // prefix. Its absolute hold boundary must still advance to the next one.
        fixture.scenePhase = .background
        try await Task.sleep(for: .milliseconds(50))
        fixture.setMessage(first + second, id: "shifted-message", excerpt: second)
        fixture.scenePhase = .active
        try await SwiftUIReplay.wait { SwiftUIReplay.text(in: root).contains(second) }
        let third = String(repeating: "C", count: 600)
        fixture.setMessage(first + second + third, id: "shifted-message")
        try await Task.sleep(for: .milliseconds(100))
        fixture.setMessage(second + third, id: "shifted-message")
        try await SwiftUIReplay.wait { SwiftUIReplay.text(in: root).contains(third) }
        #expect(fixture.appearances == 1)
    }

    @Test(.requiresDisplay) func retainedExcerptRestartsAfterHostingViewReattachmentWithoutInputChange() async throws {
        let fixture = OverviewTextFixture()
        fixture.reduceMotion = true
        let window = SwiftUIReplay.window(OverviewTextReplay(fixture: fixture), width: 360, height: 200)
        defer { window.close() }
        let root = try #require(window.contentView)
        try await SwiftUIReplay.wait { SwiftUIReplay.text(in: root).contains("Initial excerpt") }
        let first = String(repeating: "A", count: 600), second = String(repeating: "B", count: 600)
        fixture.setMessage(first + second + "retained latest tail", excerpt: "retained latest tail")
        try await SwiftUIReplay.wait { SwiftUIReplay.text(in: root).contains(first) }

        // Retain this exact NSHostingView and its SwiftUI state. No source,
        // visibility or motion-policy property changes across the lifecycle edge.
        window.contentView = nil
        try await SwiftUIReplay.wait { fixture.disappearances == 1 }
        window.contentView = root
        window.makeKeyAndOrderFront(nil)
        try await SwiftUIReplay.wait {
            fixture.appearances == 2 && SwiftUIReplay.text(in: root).contains("retained latest tail")
        }
        #expect(window.contentView === root)
        #expect(Set(fixture.identities).count == 1)
        fixture.setMessage("content after reattachment")
        try await SwiftUIReplay.wait { SwiftUIReplay.text(in: root).contains("content after reattachment") }
        #expect(fixture.appearances == 2)
    }

    private func textPixels(in root: NSView) throws -> Data {
        root.layoutSubtreeIfNeeded(); root.window?.displayIfNeeded()
        let image = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: image)
        return try #require(image.representation(using: .png, properties: [:]))
    }
}
