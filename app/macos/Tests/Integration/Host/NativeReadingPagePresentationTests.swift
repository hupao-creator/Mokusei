import AppKit
import Observation
import SwiftUI
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
import MokuseiCore
@testable import MokuseiPluginUI
import MokuseiUI

@MainActor @Observable private final class ReadingFixture {
    var open = false
    var axis: Axis = .horizontal
    var identity: JSONText = "detail"
    var direction: CGFloat = 1
    var scrollParent = false
    var enabled = true
    var text = "Initial overview"
    var duration = NativeReadingPageTiming.duration
    var viewport: CGSize?
    var phase: ScenePhase?
    var parentPresentationActive = true
    var prepareEnabled = false
    @ObservationIgnored var preparation: CheckedContinuation<Void, Never>?
    let motion = NativeReadingPageMotion()
    @ObservationIgnored var parentAppearances = 0
    @ObservationIgnored var frontAppearances = 0
    @ObservationIgnored var historyContentTop: CGFloat?
    @ObservationIgnored weak var frontProbe: NSView?
    @ObservationIgnored weak var parentProbe: NSView?
    @ObservationIgnored var parentEnabled = true
    func prepareReturn() async {
        await withCheckedContinuation { preparation = $0 }
    }
}
private struct ReadingFrontProbe: NSViewRepresentable {
    let fixture: ReadingFixture
    var parent = false
    @Environment(\.isEnabled) private var enabled
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        if parent { fixture.parentProbe = view }
        else { fixture.frontProbe = view }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { if parent { fixture.parentEnabled = enabled } }
}
private struct ReadingReplay: View {
    let fixture: ReadingFixture
    var body: some View {
        NativeReadingPageStack(open: fixture.open, identity: fixture.identity, motion: fixture.motion,
            enabled: fixture.enabled, focusBlur: true, stationaryParent: fixture.axis == .horizontal, emphasizedOpening: true, duration: fixture.duration, axis: fixture.axis, direction: fixture.direction,
            onParentPresentationChange: { fixture.parentPresentationActive = $0 },
            prepareParent: fixture.prepareEnabled ? { await fixture.prepareReturn() } : nil,
            onClose: { fixture.open = false }) {
            Group {
                if fixture.scrollParent {
                    NativeScrollView { Text(fixture.text).frame(height: 1400).frame(maxWidth: .infinity) }
                } else { Text(fixture.text) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(ReadingFrontProbe(fixture: fixture, parent: true))
                .background(Color(.sRGB, red: 1, green: 0, blue: 0))
                .onAppear { fixture.parentAppearances += 1 }
        } front: { Text("Conversation detail").frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(.sRGB, red: 0, green: 0, blue: 1))
                .background(ReadingFrontProbe(fixture: fixture)).onAppear { fixture.frontAppearances += 1 } }
            .frame(width: fixture.viewport?.width, height: fixture.viewport?.height)
            .transformEnvironment(\.scenePhase) { if let phase = fixture.phase { $0 = phase } }
    }
}
@MainActor @Suite(.serializedNative, .requiresDisplay, .serialized)
struct NativeReadingPagePresentationTests {
    @Test func parentPreparationWaitsAndCannotCloseAReplacementRoute() async throws {
        let fixture = ReadingFixture()
        fixture.prepareEnabled = true
        let window = SwiftUIReplay.window(ReadingReplay(fixture: fixture))
        defer { window.close(); fixture.preparation?.resume(); fixture.preparation = nil }
        try await SwiftUIReplay.wait { fixture.parentAppearances == 1 }
        fixture.open = true
        try await SwiftUIReplay.wait { !fixture.parentPresentationActive && !fixture.motion.active }
        fixture.motion.close()
        try await SwiftUIReplay.wait { fixture.preparation != nil }
        #expect(fixture.open && fixture.motion.active && fixture.parentPresentationActive)
        fixture.identity = "replacement"
        try await SwiftUIReplay.wait { !fixture.motion.active && !fixture.parentPresentationActive }
        fixture.preparation?.resume(); fixture.preparation = nil
        try await Task.sleep(for: .milliseconds(100))
        #expect(fixture.open && !fixture.motion.active)
        fixture.motion.close()
        try await SwiftUIReplay.wait { fixture.preparation != nil }
        fixture.preparation?.resume(); fixture.preparation = nil
        try await SwiftUIReplay.wait { !fixture.open && !fixture.motion.active && fixture.parentPresentationActive }
        #expect(fixture.parentAppearances == 1)
    }

    @Test func focusLossFinishesAcceptedCloseDuringParentPreparation() async throws {
        let fixture = ReadingFixture()
        fixture.prepareEnabled = true
        let window = SwiftUIReplay.window(ReadingReplay(fixture: fixture))
        defer { window.close(); fixture.preparation?.resume(); fixture.preparation = nil }
        try await SwiftUIReplay.wait { fixture.parentAppearances == 1 }
        fixture.open = true
        try await SwiftUIReplay.wait { !fixture.parentPresentationActive && !fixture.motion.active }
        fixture.motion.close()
        try await SwiftUIReplay.wait { fixture.preparation != nil }
        fixture.phase = .inactive
        try await SwiftUIReplay.wait { !fixture.open && !fixture.motion.active && fixture.parentPresentationActive }
        fixture.preparation?.resume(); fixture.preparation = nil
        fixture.phase = .active
        fixture.open = true
        try await SwiftUIReplay.wait { !fixture.parentPresentationActive && !fixture.motion.active }
        #expect(fixture.open && fixture.parentAppearances == 1)
    }

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

    @Test func verticalPagesKeepTheirHorizontalPositionAndCancelObsoleteReturns() async throws {
        let fixture = ReadingFixture()
        fixture.axis = .vertical
        fixture.duration = 1.2
        let window = SwiftUIReplay.window(ReadingReplay(fixture: fixture), offscreen: true)
        defer { window.close() }
        try await SwiftUIReplay.wait { fixture.parentAppearances == 1 }
        let root = try #require(window.contentView)
        fixture.open = true
        try await SwiftUIReplay.wait {
            guard fixture.motion.active, let probe = fixture.frontProbe else { return false }
            let frame = probe.convert(probe.bounds, to: root)
            return abs(frame.minY) > root.bounds.height * 0.3 && abs(frame.minY) < root.bounds.height * 0.7
        }
        let probe = try #require(fixture.frontProbe)
        #expect(abs(probe.convert(probe.bounds, to: root).minX) < 1)
        if let path = ProcessInfo.processInfo.environment["MOKUSEI_READING_MOTION_ARTIFACTS"] {
            let image = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: image)
            let directory = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try #require(image.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("vertical-middle.png"))
        }
        let parent = try #require(fixture.parentProbe)
        let parentFrame = parent.convert(parent.bounds, to: root)
        let frontFrame = probe.convert(probe.bounds, to: root)
        #expect(abs(parentFrame.maxY - frontFrame.minY) < 1, "Pages must share one edge without overlap")
        #expect(abs(parentFrame.minX) < 1 && abs(frontFrame.minX) < 1)
        fixture.motion.cancel()
        for (identity, direction) in [("earlier", CGFloat(-1)), ("later", CGFloat(1))] {
            let outgoing = try #require(fixture.frontProbe)
            fixture.direction = direction
            fixture.identity = JSONText(identity)
            try await SwiftUIReplay.wait {
                guard fixture.motion.active, let probe = fixture.frontProbe else { return false }
                let frame = probe.convert(probe.bounds, to: root)
                return frame.minY * direction > root.bounds.height * 0.25
                    && frame.minY * direction < root.bounds.height * 0.75
            }
            let incoming = try #require(fixture.frontProbe)
            let incomingFrame = incoming.convert(incoming.bounds, to: root)
            let outgoingFrame = outgoing.convert(outgoing.bounds, to: root)
            #expect(abs(incomingFrame.minX) < 1 && abs(outgoingFrame.minX) < 1)
            let gap = direction > 0 ? incomingFrame.minY - outgoingFrame.maxY : outgoingFrame.minY - incomingFrame.maxY
            #expect(abs(gap) < 1, "Replacement pages must travel together without overlap or a gap")
            let image = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: image)
            let scan = (image.pixelsHigh / 20)..<(image.pixelsHigh * 19 / 20)
            let covered = scan.allSatisfy { y in
                guard let pixel = image.colorAt(x: image.pixelsWide / 4, y: y)?.usingColorSpace(.sRGB) else { return false }
                return pixel.alphaComponent > 0.99 && pixel.blueComponent > 0.8 && pixel.redComponent < 0.1
            }
            #expect(covered, "History replacement must cover the full column without exposing the current document or an empty seam")
            if let path = ProcessInfo.processInfo.environment["MOKUSEI_READING_MOTION_ARTIFACTS"] {
                try #require(image.representation(using: .png, properties: [:])).write(to:
                    URL(fileURLWithPath: path).appendingPathComponent(identity + "-middle.png"))
            }
            try await SwiftUIReplay.wait { !fixture.motion.active }
        }
        fixture.direction = 0
        fixture.identity = "same-target"
        try await SwiftUIReplay.wait { fixture.frontAppearances == 4 }
        #expect(!fixture.motion.active)
        let stationary = try #require(fixture.frontProbe)
        #expect(abs(stationary.convert(stationary.bounds, to: root).minY) < 1)
        fixture.direction = 1
        fixture.motion.cancel()
        fixture.motion.close()
        try await SwiftUIReplay.wait {
            let frame = stationary.convert(stationary.bounds, to: root)
            return frame.minY > root.bounds.height * 0.3 && frame.minY < root.bounds.height * 0.7
        }
        let returningParent = parent.convert(parent.bounds, to: root)
        let returningFront = stationary.convert(stationary.bounds, to: root)
        #expect(abs(returningParent.maxY - returningFront.minY) < 1, "Return must also keep the pages edge to edge")
        #expect(abs(returningParent.minX) < 1 && abs(returningFront.minX) < 1)
        fixture.motion.cancel()
        try await Task.sleep(for: .milliseconds(1250))
        #expect(fixture.open && !fixture.motion.active)
        fixture.motion.close()
        try await SwiftUIReplay.wait { !fixture.open && !fixture.motion.active }
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
        fixture.open = true
        try await SwiftUIReplay.wait { fixture.frontAppearances == 2 && !fixture.motion.active }
        fixture.motion.close()
        NativeReadingPageMotion.cancelAll()
        #expect(fixture.open && !fixture.motion.active)
        NativeReadingPageMotion.cancelAll(finishingClose: true)
        #expect(fixture.open, "A cancelled return must not be revived by recovery")
        fixture.motion.close()
        NativeReadingPageMotion.cancelAll(finishingClose: true)
        #expect(!fixture.open && !fixture.motion.active)
    }

    @Test func interruptedNavigationKeepsCloseActionAvailable() async throws {
        let fixture = ReadingFixture()
        fixture.phase = .active
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

        // A layout or activation interruption settles the accepted return, rather
        // than restoring the detail and silently discarding the Close request.
        for (index, interruption) in ["resize", "inactive"].enumerated() {
            fixture.open = true
            try await SwiftUIReplay.wait { fixture.frontAppearances == 6 + index && !fixture.motion.active }
            fixture.motion.close()
            #expect(fixture.open && fixture.motion.active)
            if interruption == "resize" { fixture.viewport = CGSize(width: 1000, height: 700) }
            else { fixture.phase = .inactive }
            try await SwiftUIReplay.wait { !fixture.open && !fixture.motion.active }
        }

        fixture.phase = .active
        fixture.open = true
        try await SwiftUIReplay.wait { fixture.frontAppearances == 8 && !fixture.motion.active }
        fixture.motion.close()
        fixture.identity = "replacement"
        fixture.viewport = CGSize(width: 940, height: 680)
        try await SwiftUIReplay.wait { fixture.frontAppearances == 9 && !fixture.motion.active }
        try await Task.sleep(for: .milliseconds(450))
        #expect(fixture.open, "An interrupted old return must not close a replacement visit")
        fixture.motion.close()
        try await SwiftUIReplay.wait { !fixture.open && !fixture.motion.active }
    }
}

/// Unmounted production stack: no NSWindow, display link, focus stealing or
/// preference writes. Intermediate rendered motion remains display-gated above.
@MainActor @Suite(.serializedNative, .serialized)
struct NativeReadingPageHeadlessTests {
    @Test func horizontalReturnGeometryUsesTheCurrentViewportForEitherDirection() throws {
        let size = CGSize(width: 400, height: 260)
        let root = CGRect(x: 17, y: 23, width: size.width, height: size.height)
        for direction in [CGFloat(-1), CGFloat(1)] {
            let context = NativeReadingPageGeometry.Context(identity: "detail", axis: .horizontal,
                direction: direction, size: size)
            let front = root.offsetBy(dx: 300 * direction, dy: 0)
            let progress = try #require(NativeReadingPageGeometry.progress(rootBounds: root, frontFrame: front,
                rootContext: context, frontContext: context, identity: "detail", direction: direction, tolerance: 0.5))
            #expect(abs(progress - 0.25) < 1e-12)
            let roundedEndpoint = root.offsetBy(dx: 400.25 * direction, dy: 0)
            #expect(NativeReadingPageGeometry.progress(rootBounds: root, frontFrame: roundedEndpoint,
                rootContext: context, frontContext: context, identity: "detail", direction: direction, tolerance: 0.5) == 0)
            let outside = root.offsetBy(dx: 402 * direction, dy: 0)
            #expect(NativeReadingPageGeometry.progress(rootBounds: root, frontFrame: outside,
                rootContext: context, frontContext: context, identity: "detail", direction: direction, tolerance: 0.5) == nil)
        }
    }

    @Test func horizontalReturnRejectsStaleOrInvalidGeometry() {
        let size = CGSize(width: 400, height: 260)
        let root = CGRect(origin: .zero, size: size)
        let front = root.offsetBy(dx: 300, dy: 0)
        let context = NativeReadingPageGeometry.Context(identity: "detail", axis: .horizontal, direction: 1, size: size)
        @MainActor func measured(rootBounds: CGRect? = nil, frontFrame: CGRect? = nil,
                      frontContext: NativeReadingPageGeometry.Context? = nil,
                      identity: JSONText = "detail", direction: CGFloat = 1) -> Double? {
            NativeReadingPageGeometry.progress(rootBounds: rootBounds ?? root, frontFrame: frontFrame ?? front,
                rootContext: context, frontContext: frontContext ?? context, identity: identity, direction: direction, tolerance: 0.5)
        }
        #expect(measured(identity: "replacement") == nil)
        #expect(measured(direction: -1) == nil)
        for changed in [
            NativeReadingPageGeometry.Context(identity: "replacement", axis: .horizontal, direction: 1, size: size),
            .init(identity: "detail", axis: .vertical, direction: 1, size: size),
            .init(identity: "detail", axis: .horizontal, direction: -1, size: size),
            .init(identity: "detail", axis: .horizontal, direction: 1, size: CGSize(width: 401, height: 260))
        ] { #expect(measured(frontContext: changed) == nil) }
        #expect(measured(rootBounds: CGRect(x: 0, y: 0, width: 420, height: 260)) == nil)
        #expect(measured(frontFrame: CGRect(x: 300, y: 0, width: 400, height: 240)) == nil)
        #expect(measured(frontFrame: front.offsetBy(dx: 0, dy: 2)) == nil)
        #expect(measured(rootBounds: .zero) == nil)
        #expect(measured(frontFrame: CGRect(x: CGFloat.nan, y: 0, width: 400, height: 260)) == nil)
        for direction in [CGFloat(0), CGFloat(0.5), CGFloat.infinity] {
            let invalid = NativeReadingPageGeometry.Context(identity: "detail", axis: .horizontal, direction: direction, size: size)
            #expect(NativeReadingPageGeometry.progress(rootBounds: root, frontFrame: front,
                rootContext: invalid, frontContext: invalid, identity: "detail", direction: direction, tolerance: 0.5) == nil)
        }
    }

    @Test func detachedAnchorsAndObsoleteOwnersCannotSupplyAReturnPose() throws {
        let geometry = NativeReadingPageGeometry()
        let other = NativeReadingPageGeometry()
        let context = NativeReadingPageGeometry.Context(identity: "detail", axis: .horizontal,
            direction: 1, size: CGSize(width: 400, height: 260))
        let root = NativeReadingPageAnchorView(frame: CGRect(origin: .zero, size: context.size))
        let oldFront = NativeReadingPageAnchorView(frame: CGRect(x: 300, y: 0, width: 400, height: 260))
        let front = NativeReadingPageAnchorView(frame: oldFront.frame)
        geometry.install(root, role: .root, context: context)
        geometry.install(oldFront, role: .front, context: context)
        #expect(geometry.owns(root, role: .root) && geometry.owns(oldFront, role: .front))
        geometry.install(front, role: .front, context: context)
        geometry.remove(oldFront)
        #expect(geometry.owns(front, role: .front), "Dismantling an old anchor must not clear its replacement")
        root.addSubview(front)
        #expect(geometry.progress(identity: "detail", direction: 1) == nil, "A detached hierarchy is not a displayed viewport")
        other.install(front, role: .front, context: context)
        #expect(!geometry.owns(front, role: .front) && other.owns(front, role: .front))
        geometry.remove(front)
        #expect(other.owns(front, role: .front), "An obsolete owner must not remove another stack's anchor")
        front.removeFromSuperview()
        #expect(other.progress(identity: "detail", direction: 1) == nil)
        #expect(!front.isOpaque && !front.acceptsFirstResponder && front.hitTest(.zero) == nil)
        #expect(!front.isAccessibilityElement() && front.accessibilityChildren()?.isEmpty == true)
        weak var released: NativeReadingPageAnchorView?
        var temporary: NativeReadingPageAnchorView? = NativeReadingPageAnchorView()
        released = temporary
        other.install(try #require(temporary), role: .front, context: context)
        temporary = nil
        #expect(released == nil, "The geometry owner must not retain a dismantled surface")
    }

    @Test func verticalPreparationPreservesTheScrollerAndRetainedDocument() async throws {
        for width: CGFloat in [360, 1180] {
            let fixture = ReadingFixture()
            fixture.axis = .vertical
            fixture.duration = 0.2
            fixture.scrollParent = true
            let host = NSHostingView(rootView: ReadingReplay(fixture: fixture).environment(\.scenePhase, .active))
            host.frame = CGRect(x: 0, y: 0, width: width, height: 700)
            for _ in 0..<8 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
            let parent = try #require(fixture.parentProbe)
            func scroll(in view: NSView) -> NSScrollView? {
                (view as? NSScrollView) ?? view.subviews.lazy.compactMap { scroll(in: $0) }.first
            }
            let retainedScroll = try #require(scroll(in: host))
            #expect(retainedScroll.hasVerticalScroller)
            let initial = parent.convert(parent.bounds, to: host)
            fixture.open = true
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
            host.layoutSubtreeIfNeeded()
            #expect(host.window == nil)
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                #expect(!fixture.motion.active)
                fixture.motion.close()
                #expect(!fixture.open)
                continue
            }
            #expect(fixture.motion.active)
            #expect(retainedScroll.hasVerticalScroller)
            #expect(scroll(in: host) === retainedScroll)
            #expect(fixture.parentEnabled, "Retiring the document must not change its scroll gutter or control metrics")
            #expect(fixture.parentAppearances == 1 && fixture.frontAppearances == 1)
            let retained = parent.convert(parent.bounds, to: host)
            #expect(retained.minX == initial.minX && retained.width == initial.width)
            fixture.motion.cancel()
            for _ in 0..<8 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
            #expect(!fixture.parentEnabled, "The offscreen document must retain its keyboard input gate")
            fixture.motion.close()
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
            host.layoutSubtreeIfNeeded()
            #expect(retainedScroll.hasVerticalScroller && fixture.parentEnabled)
            // Without a display SwiftUI does not deliver animation removal.
            // Exercise host cancellation/teardown instead of claiming completion.
            fixture.open = false
            for _ in 0..<8 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
            #expect(!fixture.motion.active)
            #expect(fixture.parentAppearances == 1)
            #expect(fixture.parentEnabled && retainedScroll.hasVerticalScroller)
            #expect(parent.convert(parent.bounds, to: host).width == initial.width)
        }
    }

    @Test(arguments: [CGFloat(-1), CGFloat(1)])
    func historyReplacementKeepsTheHiddenCurrentDocumentDisabled(direction: CGFloat) async throws {
        let fixture = ReadingFixture()
        fixture.axis = .vertical
        fixture.open = true
        fixture.direction = direction
        fixture.duration = 0.2
        fixture.scrollParent = true
        let host = NSHostingView(rootView: ReadingReplay(fixture: fixture).environment(\.scenePhase, .active))
        host.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        for _ in 0..<8 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        #expect(!fixture.parentEnabled && !fixture.motion.active)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        fixture.identity = "replacement"
        // The replacement timer starts in the identity change itself. Observe it
        // instead of assuming eight layout passes finish inside its duration;
        // a slow runner would otherwise read the already-settled state.
        if reduceMotion { #expect(!fixture.motion.active) }
        else { try await SwiftUIReplay.wait { fixture.motion.active } }
        for _ in 0..<8 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
            #expect(!fixture.parentEnabled, "History-only motion must not admit keyboard input into the hidden current document")
        }
        #expect(fixture.frontAppearances == 2)
        // Replacement has a cancellable timer, so its completion is observable
        // without a window, unlike opening/return animation removal.
        try await SwiftUIReplay.wait { !fixture.motion.active }
        host.layoutSubtreeIfNeeded()
        #expect(!fixture.motion.active && !fixture.parentEnabled)
        fixture.identity = "interrupted-replacement"
        if !reduceMotion { try await SwiftUIReplay.wait { fixture.motion.active } }
        for _ in 0..<4 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
            #expect(!fixture.parentEnabled)
        }
        fixture.motion.cancel()
        try await SwiftUIReplay.wait { !fixture.motion.active }
        host.layoutSubtreeIfNeeded()
        #expect(!fixture.motion.active && !fixture.parentEnabled)
        #expect(fixture.open && fixture.parentAppearances == 1 && host.window == nil)
    }

    @Test func cancellationFencesAnObsoleteReturnWithoutAWindow() async throws {
        let fixture = ReadingFixture()
        fixture.axis = .vertical
        fixture.duration = 0.15
        let host = NSHostingView(rootView: ReadingReplay(fixture: fixture).environment(\.scenePhase, .active))
        host.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        for _ in 0..<8 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        fixture.open = true
        for _ in 0..<8 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        fixture.motion.cancel()
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            fixture.motion.close()
            #expect(!fixture.open && !fixture.motion.active && host.window == nil)
            return
        }
        fixture.motion.close()
        #expect(fixture.open && fixture.motion.active)
        fixture.motion.cancel()
        try await Task.sleep(for: .milliseconds(250))
        #expect(fixture.open && !fixture.motion.active)
        fixture.enabled = false
        for _ in 0..<8 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        fixture.motion.close()
        #expect(!fixture.open && !fixture.motion.active)
        #expect(host.window == nil && fixture.parentAppearances == 1)
    }
}
