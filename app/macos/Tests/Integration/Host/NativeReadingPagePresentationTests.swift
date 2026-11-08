import AppKit
import Observation
import ScreenCaptureKit
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
    @ObservationIgnored var renderedText = ""
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
                .onChange(of: fixture.text, initial: true) { _, text in fixture.renderedText = text }
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

    @Test func retainedOverviewReturnsWithLatestContent() async throws {
        try #require(NSApp?.isRunning == true,
            "Run this method through native-capture/tag-glass-captures; a real NSApplication event loop is required")
        let fixture = ReadingFixture()
        fixture.duration = 1.2
        let requestedSize = CGSize(width: 1180, height: 780)
        let window = SwiftUIReplay.window(ReadingReplay(fixture: fixture), width: requestedSize.width, height: requestedSize.height)
        defer { window.close() }
        let root = try #require(window.contentView)
        let diagnosticStart = ProcessInfo.processInfo.systemUptime
        var setupSamples: [[String: Any]] = [], openingSamples: [[String: Any]] = [], returnSamples: [[String: Any]] = []
        var openSet: [String: Any] = [:], closeSet: [String: Any] = [:], closeGeometry: [String: Any] = [:]
        var beforeReturnSample: [String: Any] = [:], duringReturnSample: [String: Any] = [:]
        let diagnosticLimit = 2048
        var progressWrites: [NativeReadingPageMotion.ProgressWrite] = []
        progressWrites.reserveCapacity(diagnosticLimit)
        openingSamples.reserveCapacity(diagnosticLimit)
        var droppedProgressWrites = 0, droppedOpeningSamples = 0
        var latestOpeningSample: [String: Any] = [:], failureState: [String: Any] = [:], failureImage: [String: Any] = [:]
        weak var sampledRootAnchor: NativeReadingPageAnchorView?
        weak var sampledFrontAnchor: NativeReadingPageAnchorView?
        fixture.motion.progressWriteObserver = { sample in
            if progressWrites.count < diagnosticLimit { progressWrites.append(sample) }
            else { droppedProgressWrites += 1 }
        }
        @MainActor func observe(anchors: Bool = false) -> (x: CGFloat?, size: CGSize, tolerance: CGFloat, active: Bool, record: [String: Any]) {
            let x = fixture.frontProbe.map { $0.convert($0.bounds, to: root).minX }
            let size = root.bounds.size
            let tolerance = 1 / max(1, window.backingScaleFactor)
            let active = fixture.motion.active
            let now = ProcessInfo.processInfo.systemUptime
            var record: [String: Any] = ["uptime": now, "elapsedMilliseconds": (now - diagnosticStart) * 1000,
                "x": x.map { $0 as Any } ?? NSNull(), "rootWidth": size.width, "rootHeight": size.height,
                "pixelTolerance": tolerance, "motionActive": active, "open": fixture.open,
                "renderedText": fixture.renderedText, "parentAppearances": fixture.parentAppearances,
                "frontAppearances": fixture.frontAppearances, "AppKitRunning": NSApp.isRunning,
                "applicationActive": NSApp.isActive, "windowVisible": window.isVisible, "windowKey": window.isKeyWindow,
                "currentRoot": window.contentView === root, "rootInWindow": root.window === window,
                "probeInWindow": fixture.frontProbe?.window === window]
            if anchors {
                // Read the same native surfaces on the existing display callback;
                // progress-write callbacks only append their small value sample.
                record["anchorReadStartUptime"] = ProcessInfo.processInfo.systemUptime
                if sampledRootAnchor?.window !== window || sampledFrontAnchor?.window !== window {
                    var pending = [root]
                    while let view = pending.popLast() {
                        if let anchor = view as? NativeReadingPageAnchorView, let owner = anchor.owner {
                            if owner.owns(anchor, role: .root) { sampledRootAnchor = anchor }
                            if owner.owns(anchor, role: .front) { sampledFrontAnchor = anchor }
                        }
                        pending.append(contentsOf: view.subviews)
                    }
                }
                for (name, anchor) in [("rootAnchorFrame", sampledRootAnchor), ("frontAnchorFrame", sampledFrontAnchor)] {
                    if let anchor {
                        let frame = anchor.convert(anchor.bounds, to: root)
                        record[name] = ["x": Double(frame.minX), "y": Double(frame.minY),
                                        "width": Double(frame.width), "height": Double(frame.height)]
                    } else { record[name] = NSNull() }
                }
                record["anchorsShareOwner"] = sampledRootAnchor?.owner != nil && sampledRootAnchor?.owner === sampledFrontAnchor?.owner
                record["anchorReadEndUptime"] = ProcessInfo.processInfo.systemUptime
            }
            return (x, size, tolerance, active, record)
        }
        defer {
            fixture.motion.progressWriteObserver = nil
            let writes: [[String: Any]] = progressWrites.map { ["uptime": $0.uptime,
                "elapsedMilliseconds": ($0.uptime - diagnosticStart) * 1000, "progress": $0.progress,
                "reason": $0.reason, "generation": $0.generation] }
            let diagnostic: [String: Any] = ["clock": "ProcessInfo.systemUptime", "diagnosticStartUptime": diagnosticStart,
                "driveLayout": false, "requestedWidth": requestedSize.width, "requestedHeight": requestedSize.height,
                "setupChecks": setupSamples.count, "setupSamples": setupSamples,
                "openSet": openSet, "openingChecks": openingSamples.count + droppedOpeningSamples, "openingSamples": openingSamples,
                "latestOpeningSample": latestOpeningSample, "beforeReturn": beforeReturnSample,
                "diagnosticLimit": diagnosticLimit, "progressWrites": writes, "droppedProgressWrites": droppedProgressWrites,
                "droppedOpeningSamples": droppedOpeningSamples, "failureState": failureState, "failureImage": failureImage,
                "closeSet": closeSet, "closeGeometry": closeGeometry, "duringReturn": duringReturnSample,
                "returnChecks": returnSamples.count, "returnSamples": returnSamples, "finalState": observe().record]
            if let data = try? JSONSerialization.data(withJSONObject: diagnostic, options: [.sortedKeys]),
               let text = String(data: data, encoding: .utf8) {
                print("OVERVIEW_RETAINED_RETURN_DIAGNOSTICS \(text)")
            }
        }
        try await SwiftUIReplay.wait(driveLayout: false) {
            let sample = observe()
            setupSamples.append(sample.record)
            return fixture.parentAppearances == 1 && fixture.renderedText == "Initial overview" && !sample.active
                && abs(sample.size.width - requestedSize.width) <= sample.tolerance
                && abs(sample.size.height - requestedSize.height) <= sample.tolerance
        }
        let count = fixture.parentAppearances
        enum FrameFailure: Error { case invalidGeometry(String) }
        var observedReturn: Result<(probe: NSView, position: CGFloat), Error>?
        let openingObserver = SwiftUIReplay.FrameObserver(view: root) {
            let sample = observe(anchors: true)
            latestOpeningSample = sample.record
            if openingSamples.count < diagnosticLimit { openingSamples.append(sample.record) }
            else { droppedOpeningSamples += 1 }
            guard let x = sample.x,
                  x > sample.size.width * 0.4 && x < sample.size.width * 0.6 else { return false }
            // Qualify and reverse this same committed pose. Resuming an async
            // test task first would admit a different, potentially settled frame.
            do {
                guard let probe = fixture.frontProbe else {
                    throw FrameFailure.invalidGeometry("The admitted front probe disappeared")
                }
                let beforeReturn = probe.convert(probe.bounds, to: root).minX
                let returnWidth = root.bounds.width
                let motionActive = fixture.motion.active
                let currentRoot = window.contentView === root
                let rootInWindow = root.window === window
                let probeInWindow = probe.window === window
                let currentProbe = fixture.frontProbe === probe
                beforeReturnSample = observe().record
                beforeReturnSample["x"] = beforeReturn
                beforeReturnSample["qualifiedWidth"] = returnWidth
                beforeReturnSample["qualifiedMotionActive"] = motionActive
                beforeReturnSample["currentProbe"] = currentProbe
                guard currentRoot && rootInWindow && probeInWindow && currentProbe && motionActive
                    && beforeReturn > returnWidth * 0.4 && beforeReturn < returnWidth * 0.6 else {
                    throw FrameFailure.invalidGeometry("The current front must still be in the original opening midpoint before returning")
                }
                let textSetBefore = ProcessInfo.processInfo.systemUptime
                fixture.text = "Latest overview"
                // Establish that this return has a usable production geometry pair;
                // a passing direction assertion alone could also use the model fallback.
                let geometryReadStart = ProcessInfo.processInfo.systemUptime
                var pendingViews = [root], anchors: [NativeReadingPageAnchorView] = []
                while let view = pendingViews.popLast() {
                    if let anchor = view as? NativeReadingPageAnchorView { anchors.append(anchor) }
                    pendingViews.append(contentsOf: view.subviews)
                }
                closeGeometry = ["sampleStartUptime": geometryReadStart, "textSetBeforeUptime": textSetBefore, "anchorCount": anchors.count,
                    "identity": fixture.identity.string, "axis": fixture.axis == .horizontal ? "horizontal" : "vertical",
                    "direction": Double(fixture.direction)]
                guard let owner = anchors.first?.owner else {
                    throw FrameFailure.invalidGeometry("The admitted native anchors have no geometry owner")
                }
                var rootAnchors: [NativeReadingPageAnchorView] = [], frontAnchors: [NativeReadingPageAnchorView] = []
                var sameOwner = true
                for anchor in anchors {
                    if anchor.owner !== owner { sameOwner = false }
                    if owner.owns(anchor, role: .root) { rootAnchors.append(anchor) }
                    if owner.owns(anchor, role: .front) { frontAnchors.append(anchor) }
                }
                closeGeometry["sameOwner"] = sameOwner
                closeGeometry["rootCount"] = rootAnchors.count
                closeGeometry["frontCount"] = frontAnchors.count
                guard anchors.count == 2 && sameOwner && rootAnchors.count == 1 && frontAnchors.count == 1 else {
                    throw FrameFailure.invalidGeometry("The current stack must own one root and one front geometry anchor")
                }
                let nativeRoot = rootAnchors[0], nativeFront = frontAnchors[0]
                let nativeRootFrame = nativeRoot.convert(nativeRoot.bounds, to: root)
                let nativeFrontFrame = nativeFront.convert(nativeFront.bounds, to: root)
                let sampledProgress = owner.progress(identity: fixture.identity, direction: fixture.direction)
                closeGeometry["rootFrame"] = ["x": Double(nativeRootFrame.minX), "y": Double(nativeRootFrame.minY),
                    "width": Double(nativeRootFrame.width), "height": Double(nativeRootFrame.height)]
                closeGeometry["frontFrame"] = ["x": Double(nativeFrontFrame.minX), "y": Double(nativeFrontFrame.minY),
                    "width": Double(nativeFrontFrame.width), "height": Double(nativeFrontFrame.height)]
                closeGeometry["progress"] = sampledProgress.map { $0 as Any } ?? NSNull()
                closeGeometry["sampleEndUptime"] = ProcessInfo.processInfo.systemUptime
                guard sampledProgress != nil && abs(nativeFrontFrame.minX - beforeReturn) <= 1 else {
                    throw FrameFailure.invalidGeometry("The production return sample must match the currently qualified front, without driving layout")
                }
                let closeSetBefore = ProcessInfo.processInfo.systemUptime
                fixture.motion.close()
                let closeSetAfter = ProcessInfo.processInfo.systemUptime
                closeSet = ["textSetBeforeUptime": textSetBefore, "beforeUptime": closeSetBefore, "afterUptime": closeSetAfter]
                observedReturn = .success((probe: probe, position: beforeReturn))
            } catch {
                observedReturn = .failure(error)
            }
            return true
        }
        defer { openingObserver.stop() }
        let openSetBefore = ProcessInfo.processInfo.systemUptime
        fixture.open = true
        let openSetAfter = ProcessInfo.processInfo.systemUptime
        openSet = ["beforeUptime": openSetBefore, "afterUptime": openSetAfter]
        do { try await SwiftUIReplay.wait(driveLayout: false) { observedReturn != nil } }
        catch {
            failureState = observe().record
            openingObserver.stop()
            fixture.motion.progressWriteObserver = nil
            failureImage = await captureRetainedOverviewFailure(window)
            throw error
        }
        let admittedReturn = try #require(observedReturn).get()
        let probe = admittedReturn.probe
        let beforeReturn = admittedReturn.position
        try await Task.sleep(for: .milliseconds(100))
        let duringReturn = probe.convert(probe.bounds, to: root).minX
        duringReturnSample = observe().record
        duringReturnSample["x"] = duringReturn
        duringReturnSample["currentProbe"] = fixture.frontProbe === probe
        #expect(duringReturn >= beforeReturn - 1, "Returning during opening must not jump toward the open position")
        try await SwiftUIReplay.wait(driveLayout: false) {
            returnSamples.append(observe().record)
            return !fixture.open && fixture.renderedText == "Latest overview"
        }
        #expect(fixture.parentAppearances == count)
        print("OVERVIEW_RETAINED_RETURN_CONFIRMED AppKit=true latestContent=true preservedParent=true")
    }

    private func captureRetainedOverviewFailure(_ window: NSWindow) async -> [String: Any] {
        // The failed interval is already over. This single WindowServer image is
        // post-failure context, never evidence of the missed opening midpoint.
        var record: [String: Any] = ["stage": "post-failure; not the opening midpoint",
            "source": "WindowServer/ScreenCaptureKit", "requestedUptime": ProcessInfo.processInfo.systemUptime]
        do {
            let shareable = try await SCShareableContent.currentProcess
            guard let target = shareable.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
                record["error"] = "The failed replay window is not shareable"
                return record
            }
            let configuration = SCStreamConfiguration()
            configuration.width = Int(target.frame.width * window.backingScaleFactor)
            configuration.height = Int(target.frame.height * window.backingScaleFactor)
            configuration.showsCursor = false
            configuration.ignoreShadowsSingleWindow = true
            record["captureStartUptime"] = ProcessInfo.processInfo.systemUptime
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: configuration)
            record["captureEndUptime"] = ProcessInfo.processInfo.systemUptime
            guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                record["error"] = "WindowServer image could not be encoded as PNG"
                return record
            }
            let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MOKUSEI_READING_MOTION_ARTIFACTS"]
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("reading-presentation").path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent("retained-overview-post-failure.png")
            try png.write(to: destination)
            record["path"] = destination.path
            record["pixelWidth"] = image.width
            record["pixelHeight"] = image.height
        } catch {
            record["error"] = String(describing: error)
            record["captureEndUptime"] = ProcessInfo.processInfo.systemUptime
        }
        return record
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
