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

@MainActor @Observable private final class ReadingRouteFixture {
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
    @ObservationIgnored weak var frontProbe: NSView?
    @ObservationIgnored weak var parentProbe: NSView?
    @ObservationIgnored var parentEnabled = true
    func prepareReturn() async {
        await withCheckedContinuation { preparation = $0 }
    }
}
private struct ReadingRouteProbe: NSViewRepresentable {
    let fixture: ReadingRouteFixture
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
private struct ReadingRouteReplay: View {
    let fixture: ReadingRouteFixture
    var body: some View {
        NativeReadingPageStack(open: fixture.open, identity: fixture.identity, motion: fixture.motion,
            enabled: fixture.enabled, focusBlur: true, stationaryParent: fixture.axis == .horizontal, emphasizedOpening: true, panel: fixture.axis == .horizontal, duration: fixture.duration, axis: fixture.axis, direction: fixture.direction,
            onParentPresentationChange: { fixture.parentPresentationActive = $0 },
            prepareParent: fixture.prepareEnabled ? { await fixture.prepareReturn() } : nil,
            onClose: { fixture.open = false }) {
            Group {
                if fixture.scrollParent {
                    NativeScrollView { Text(fixture.text).frame(height: 1400).frame(maxWidth: .infinity) }
                } else { Text(fixture.text) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(ReadingRouteProbe(fixture: fixture, parent: true))
                .background(Color(.sRGB, red: 1, green: 0, blue: 0))
                .onAppear { fixture.parentAppearances += 1 }
        } front: { Text("Conversation detail").frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(.sRGB, red: 0, green: 0, blue: 1))
                .background(ReadingRouteProbe(fixture: fixture)).onAppear { fixture.frontAppearances += 1 } }
            .frame(width: fixture.viewport?.width, height: fixture.viewport?.height)
            .transformEnvironment(\.scenePhase) { if let phase = fixture.phase { $0 = phase } }
    }
}
@MainActor @Suite(.serializedNative, .requiresDisplay, .serialized)
struct NativeReadingRouteLifecycleTests {
    @Test func parentPreparationWaitsAndCannotCloseAReplacementRoute() async throws {
        let fixture = ReadingRouteFixture()
        fixture.prepareEnabled = true
        let window = SwiftUIReplay.window(ReadingRouteReplay(fixture: fixture))
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
        let fixture = ReadingRouteFixture()
        fixture.prepareEnabled = true
        let window = SwiftUIReplay.window(ReadingRouteReplay(fixture: fixture))
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

    @Test func verticalPagesKeepTheirHorizontalPositionAndCancelObsoleteReturns() async throws {
        let fixture = ReadingRouteFixture()
        fixture.axis = .vertical
        fixture.duration = 1.2
        let window = SwiftUIReplay.window(ReadingRouteReplay(fixture: fixture), offscreen: true)
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
        let fixture = ReadingRouteFixture()
        let window = SwiftUIReplay.window(ReadingRouteReplay(fixture: fixture))
        defer { window.close() }
        try await SwiftUIReplay.wait { fixture.parentAppearances == 1 }
        fixture.open = true
        // Panels without an identity handoff admit the reader only after native
        // opening completes. The retired full-page route mounted it in flight.
        try await SwiftUIReplay.wait { fixture.motion.active }
        #expect(fixture.frontAppearances == 0)
        try await SwiftUIReplay.wait { fixture.frontAppearances == 1 && !fixture.motion.active }
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
        let fixture = ReadingRouteFixture()
        fixture.phase = .active
        let window = SwiftUIReplay.window(ReadingRouteReplay(fixture: fixture))
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

