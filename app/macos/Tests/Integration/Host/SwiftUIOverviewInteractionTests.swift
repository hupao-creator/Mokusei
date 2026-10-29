import AppKit
import Observation
import SwiftUI
import Testing
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
        editor.setMarkedText("ni", selectedRange: .init(location: 2, length: 0), replacementRange: .init(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
        editor.insertText("你好世界", replacementRange: .init(location: NSNotFound, length: 0))
        try await SwiftUIReplay.wait { fixture.text == "你好世界" }
        #expect(!editor.hasMarkedText())
        fixture.request += 1
        try await SwiftUIReplay.wait { editor.selectedRange() == NSRange(location: 0, length: 4) }
        editor.insertText("SwiftUI", replacementRange: .init(location: NSNotFound, length: 0))
        try await SwiftUIReplay.wait { fixture.text == "SwiftUI" }
        #expect(fixture.exits == 0)
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
