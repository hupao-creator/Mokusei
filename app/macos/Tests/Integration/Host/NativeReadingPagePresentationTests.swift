import AppKit
import Observation
import SwiftUI
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
import MokuseiCore
import MokuseiPluginUI
import MokuseiUI

@MainActor @Observable private final class ReadingFixture {
    var open = false
    var text = "Initial overview"
    var duration = NativeReadingPageTiming.duration
    let motion = NativeReadingPageMotion()
    @ObservationIgnored var parentAppearances = 0
    @ObservationIgnored var frontAppearances = 0
    @ObservationIgnored var renderedText = ""
    @ObservationIgnored var historyContentTop: CGFloat?
    @ObservationIgnored weak var frontProbe: NSView?
}
private struct ReadingFrontProbe: NSViewRepresentable {
    let fixture: ReadingFixture
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        fixture.frontProbe = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
}
private struct ReadingReplay: View {
    let fixture: ReadingFixture
    var body: some View {
        NativeReadingPageStack(open: fixture.open, identity: "detail", motion: fixture.motion,
            focusBlur: true, stationaryParent: true, emphasizedOpening: true, duration: fixture.duration,
            onClose: { fixture.open = false }) {
            Text(fixture.text).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(.sRGB, red: 1, green: 0, blue: 0)).onAppear { fixture.parentAppearances += 1 }
                .onChange(of: fixture.text, initial: true) { _, text in fixture.renderedText = text }
        } front: { Text("Conversation detail").frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(.sRGB, red: 0, green: 0, blue: 1))
                .background(ReadingFrontProbe(fixture: fixture)).onAppear { fixture.frontAppearances += 1 } }
    }
}
@MainActor @Suite(.serializedNative, .requiresDisplay, .serialized)
struct NativeReadingPagePresentationTests {
    @Test func historicalPromptKeepsContentBelowATwoLineHeading() async throws {
        for width: CGFloat in [420, 1180] {
            var twoLineContentTop: CGFloat?
            for prompt in ["第一行\n第二行", String(repeating: "历史轮次的超长标题包含中文与 /Users/example/project 路径。", count: 30),
                           (1...20).map { "第 \($0) 段需求" }.joined(separator: "\n\n")] {
                let fixture = ReadingFixture()
                let rows = [ThreadConversationRow(id: "old", createdAt: 1,
                    execution: .init(id: "old", prompt: prompt, answer: ""),
                    node: AnyView(Text("History answer").onGeometryChange(for: CGFloat.self) {
                        $0.frame(in: .global).minY
                    } action: { fixture.historyContentTop = $0 })),
                    ThreadConversationRow(id: "latest", createdAt: 2,
                        execution: .init(id: "latest", prompt: "Latest", answer: ""), node: AnyView(Text("Latest answer")))]
                let window = SwiftUIReplay.window(ThreadConversation(threadId: "title-replay", title: "Thread", rows: rows,
                    readingTarget: .init(requestId: "history", mode: .history, executionId: "old")), width: width)
                defer { window.close() }
                try await SwiftUIReplay.wait { fixture.historyContentTop != nil }
                // Check the production history route's rendered geometry. A full
                // multiline prompt pushes the answer far below the viewport.
                let top = try #require(fixture.historyContentTop)
                if let twoLineContentTop { #expect(abs(top - twoLineContentTop) < 1) }
                else { twoLineContentTop = top }
            }
        }
    }

    @Test func retainedOverviewReturnsWithLatestContent() async throws {
        let fixture = ReadingFixture()
        let window = SwiftUIReplay.window(ReadingReplay(fixture: fixture))
        defer { window.close() }
        try await SwiftUIReplay.wait { fixture.parentAppearances == 1 && fixture.renderedText == "Initial overview" }
        let count = fixture.parentAppearances
        fixture.open = true
        try await SwiftUIReplay.wait { fixture.frontAppearances == 1 }
        fixture.text = "Latest overview"
        fixture.motion.close()
        try await SwiftUIReplay.wait { !fixture.open && fixture.renderedText == "Latest overview" }
        #expect(fixture.parentAppearances == count)
    }
    private func pixels(_ window: NSWindow) throws -> (left: NSColor, right: NSColor) {
        let root = try #require(window.contentView)
        let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: bitmap)
        return try (#require(bitmap.colorAt(x: Int(Double(bitmap.pixelsWide) * 0.1),
            y: bitmap.pixelsHigh / 3)?.usingColorSpace(.sRGB)),
            #require(bitmap.colorAt(x: Int(Double(bitmap.pixelsWide) * 0.95),
            y: bitmap.pixelsHigh / 3)?.usingColorSpace(.sRGB)))
    }

    @Test func ordinaryDetailSlidesOpaqueOverTheVisibleOverview() async throws {
        let fixture = ReadingFixture()
        fixture.duration = 1.2
        let window = SwiftUIReplay.window(ReadingReplay(fixture: fixture))
        defer { window.close() }
        try await SwiftUIReplay.wait { fixture.parentAppearances == 1 }
        let baseline = try pixels(window).left
        let root = try #require(window.contentView)
        fixture.open = true
        try await SwiftUIReplay.wait { fixture.motion.active && fixture.frontAppearances == 1 }
        // active precedes asynchronous animation preparation. Measure the real
        // AppKit front before reading both pixels from one coherent frame.
        try await SwiftUIReplay.wait {
            guard fixture.motion.active, let probe = fixture.frontProbe else { return false }
            let frame = probe.convert(probe.bounds, to: root)
            return frame.minX > root.bounds.width * 0.4 && frame.minX < root.bounds.width * 0.75
        }
        let (left, right) = try pixels(window)
        // Compare with the rendered baseline to accommodate display color
        // management. Fading exposes the gray window and loses red contrast.
        #expect(left.redComponent - left.greenComponent >
            0.85 * (baseline.redComponent - baseline.greenComponent), "Overview pixel: \(left), baseline: \(baseline)")
        #expect(right.blueComponent > 0.9 && right.redComponent < 0.1, "Detail pixel: \(right)")
        fixture.motion.cancel()
    }

    @Test func closeRetainsDestinationUntilReturnFinishesAndCanBeCancelled() async throws {
        let fixture = ReadingFixture()
        let window = SwiftUIReplay.window(ReadingReplay(fixture: fixture))
        defer { window.close() }
        try await SwiftUIReplay.wait { fixture.parentAppearances == 1 }
        fixture.open = true
        try await SwiftUIReplay.wait { fixture.frontAppearances == 1 && fixture.motion.active }
        try await SwiftUIReplay.wait { !fixture.motion.active }
        fixture.motion.close()
        #expect(fixture.open && fixture.motion.active)
        try await Task.sleep(for: .milliseconds(100))
        #expect(fixture.open && fixture.motion.active)
        fixture.motion.cancel()
        #expect(fixture.open && !fixture.motion.active)
        try await Task.sleep(for: .milliseconds(450))
        #expect(fixture.open) // An obsolete completion must not close this route.
        fixture.motion.close()
        try await SwiftUIReplay.wait { !fixture.open && !fixture.motion.active }
        #expect(fixture.frontAppearances == 1)
        #expect(fixture.parentAppearances == 1)
    }

    @Test func interruptedNavigationKeepsCloseActionAvailable() async throws {
        let fixture = ReadingFixture()
        let window = SwiftUIReplay.window(ReadingReplay(fixture: fixture))
        defer { window.close() }
        try await SwiftUIReplay.wait { fixture.parentAppearances == 1 }
        for _ in 0..<5 {
            fixture.open = true
            try await Task.sleep(for: .milliseconds(30))
            NativeReadingPageMotion.cancelAll()
            fixture.motion.close()
            #expect(fixture.open)
            try await SwiftUIReplay.wait { !fixture.open && !fixture.motion.active }
        }
        #expect(fixture.parentAppearances == 1)
    }
}
