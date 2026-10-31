import AppKit
import CoreMedia
import CoreVideo
import Metal
import QuartzCore
import ScreenCaptureKit
import SwiftUI
import Testing
import MokuseiCore
import MokuseiPluginAPI
import MokuseiHarnessCodex
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
@testable import MokuseiPluginUI
@testable import MokuseiUI

/// A static catalog is sufficient for this rendering observation. The separate
/// Release performance replay owns real transport and never takes screenshots.
private struct DecorationNoService: RuntimeConnectionSource {
    func start() async throws -> RuntimeConnection { throw CancellationError() }
    func status() async throws -> RuntimeConnection? { nil }
    func stop(expectedEpoch: String?) async throws {}
    func setOutputLocale(_ locale: String) throws {}
}

@MainActor private final class DecorationCaptureFixture {
    let directory: URL
    let client: RuntimeClient
    let workspace: NativeWorkspaceModel
    let overview: NativeOverviewWorkspaceModel

    init() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("overview-decoration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var installed = false
        defer { if !installed { try? FileManager.default.removeItem(at: directory) } }
        let preferences = DesktopPreferences(directory: directory)
        try preferences.setAppearance(.dark)
        try preferences.setLocale(.english)
        try preferences.setGlassWorld(true)
        let client = RuntimeClient(storageDirectory: directory, connectionSource: DecorationNoService())
        let workspace = NativeWorkspaceModel(client: client, preferences: preferences,
            plugins: try NativePluginComposition(harnesses: [AnyHarnessPlugin(CodexHarnessPlugin())], sidecards: [], applications: []))
        let overview = NativeOverviewWorkspaceModel(workspace: workspace, applications: .init(
            projectionCapabilities: { _, _ in throw CancellationError() },
            rendererContext: { _, _, _ in throw CancellationError() }))
        let at = Date().timeIntervalSince1970 * 1000 - 2_000
        let state: JSONValue = .object([
            "schema": .text("mokusei.harness.codex.thread.v1"), "updatedAt": .number(at + 2),
            "initialResponseScope": .bool(false), "backgroundTerminals": .array([]),
            "turns": .array([.object([
                "executionId": .text("decoration-execution"), "status": .text("running"),
                "createdAt": .number(at), "updatedAt": .number(at + 2),
                "answer": .text("Stable overview content."), "reasoning": .text(""),
                "messages": .array([]), "plan": .array([]), "notices": .array([]), "interactions": .array([]),
                "timeline": .array([.object([
                    "id": .text("decoration-message"), "itemId": .text("decoration-message"),
                    "kind": .text("assistant"), "status": .text("complete"),
                    "createdAt": .number(at + 1), "content": .text("Stable overview content.")
                ])]),
                "activities": .array([.object([
                    "id": .text("decoration-child"), "kind": .text("subagent"),
                    "label": .text("Inspect overview"), "status": .text("running")
                ])])
            ])])
        ])
        let thread = try HarnessThread(id: "decoration-card", harnessID: "codex", revision: 0,
            sessionState: state, observation: .init(latestExecution: try .init(
                executionID: "decoration-execution", status: .running, startedAt: at)),
            cwd: "/overview-workspace", settings: .object([:]), createdAt: at, updatedAt: at + 2,
            title: "Native Overview decorations", tags: [], archived: false)
        // Admission, Codex projection, shared card, canvas and glass are production.
        try workspace.catalog.install(.object([
            "revision": .integer(0), "settingsRevision": .integer(0), "settings": .object([:]),
            "defaultCwd": .text("/overview-workspace"), "threads": .array([thread.json]),
            "executions": .array([]), "applicationThreads": .array([])
        ]))
        self.directory = directory
        self.client = client
        self.workspace = workspace
        self.overview = overview
        overview.refresh()
        installed = true
    }

    func close() async {
        await overview.stop()
        await client.close()
        overview.canvasState.camera.dispose()
        try? FileManager.default.removeItem(at: directory)
    }
}

private struct DecorationCaptureBackdrop: View {
    var body: some View {
        Canvas { context, size in
            for row in 0..<Int(ceil(size.height / 48)) {
                for column in 0..<Int(ceil(size.width / 48)) {
                    let shade = (row + column).isMultiple(of: 2) ? 0.12 : 0.23
                    context.fill(Path(CGRect(x: CGFloat(column * 48), y: CGFloat(row * 48), width: 48, height: 48)),
                        with: .color(Color(.sRGB, red: shade, green: shade + 0.025, blue: shade + 0.05, opacity: 1)))
                }
            }
        }
    }
}

@MainActor private struct DecorationNodes {
    let cloud: NativeOverviewCloudSurface
    let metal: CAMetalLayer
    let scan: NativeCardScanView
    let gradient: CAGradientLayer
}

@MainActor @Suite(.serializedNative, .requiresDisplay, .serialized)
struct NativeOverviewDecorationCaptureTests {
    @Test func nativeCloudAndScanMoveInComposedOverview() async throws {
        try #require(!NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                     && !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
                     "Observation incomplete: native decorations require the ordinary motion/transparency environment")
        let fixture = try DecorationCaptureFixture()
        let window = SwiftUIReplay.window(
            NativeOverviewWorkspaceView(model: fixture.overview,
                callbacks: .init(openThread: { _, _ in }, openApplication: { _, _ in }, onSettings: {}))
                .background(DecorationCaptureBackdrop())
                .preferredColorScheme(.dark).environment(\.scenePhase, .active),
            width: 840, height: 420)
        window.appearance = NSAppearance(named: .darkAqua)
        window.animationBehavior = .none
        // A pointer resting over the card can add unrelated hover ink.
        if let screen = window.screen {
            let frame = screen.visibleFrame
            window.setFrameOrigin(CGPoint(x: frame.minX,
                y: NSEvent.mouseLocation.y < frame.midY ? frame.maxY - window.frame.height : frame.minY))
        }
        defer { window.close() }
        var evidence: [(String, [TagGlassFrames.Sample])] = []
        var report: [String: Any] = [
            "assertionsPassed": false, "captureKind": "WindowServer/ScreenCaptureKit complete BGRA frames",
            "fixture": "One static public Codex thread; production workspace/projector/card/canvas; one running subagent",
            "appearance": "dark", "glass": true, "formalCPU": "not measured by this capture test",
            "limitations": [
                "Transparency, glass colors and rounded corners require manual review of retained real PNGs.",
                "A single retained surface preserves its private seed; different processes need not have the same random seed.",
                "WindowServer samples and pixel displacement do not measure physical-display FPS or GPU duration."
            ]
        ]
        defer {
            do { try save(evidence, report: report) }
            catch { Issue.record(Comment(rawValue: "Could not retain native decoration evidence: \(error)")) }
        }
        do {
            let root = try #require(window.contentView)
            try await SwiftUIReplay.wait(timeout: .seconds(10)) {
                let state = fixture.overview.canvasState
                return fixture.overview.items.count == 1 && state.mountedCardIDs.count == 1
                    && state.presentedPlacements.count == 1 && !state.isLayingOut
                    && state.camera.isInitialized && !state.camera.isAnimating
            }
            let item = try #require(fixture.overview.items.first)
            try #require(item.id == "decoration-card" && item.columns == 2 && item.rows == 1,
                         "The production Codex projection must be a running 2×1 card")
            let firstCamera = try setCamera(fixture.overview, scale: 0.90)
            try await SwiftUIReplay.wait { nativeNodes(root) != nil }
            try await Task.sleep(for: .milliseconds(350))
            let nodes = try #require(nativeNodes(root), "Native Metal/CA decorations unavailable; fallback does not satisfy this test")
            try requireForeground(window)
            report["native"] = ["cloudClass": String(describing: type(of: nodes.cloud)),
                "scanClass": String(describing: type(of: nodes.scan)), "device": nodes.metal.device?.name ?? "",
                "surfaceIdentity": String(describing: ObjectIdentifier(nodes.cloud)),
                "metalIdentity": String(describing: ObjectIdentifier(nodes.metal)),
                "scanIdentity": String(describing: ObjectIdentifier(nodes.scan)),
                "opaque": nodes.metal.isOpaque, "drawable": [nodes.metal.drawableSize.width, nodes.metal.drawableSize.height],
                "scanAnimation": nodes.gradient.animationKeys() ?? []] as [String: Any]
            let firstGeometry = try geometry(window, nodes: nodes, overview: fixture.overview)
            report["fixedGeometry"] = firstGeometry.json
            let solveCount = fixture.overview.canvasState.layoutSolveCount
            let first = try await capture(window, seconds: 3.9)
            evidence.append(("fixed", first))
            try #require(fixture.overview.canvasState.camera.liveTransform == firstCamera
                         && !fixture.overview.canvasState.isLayingOut
                         && fixture.overview.canvasState.layoutSolveCount == solveCount
                         && fixture.workspace.catalog.revision == 0,
                         "Observation incomplete: content, layout or manual camera changed during the fixed capture")
            let measurements = try motion(first, geometry: firstGeometry)
            report["motion"] = measurements.report

            // One geometry change, on the same mounted card and native layers.
            // Its actual PNGs and coordinate map are retained for alignment,
            // clear background and rounded-corner inspection, without goldens.
            let zoomCamera = try setCamera(fixture.overview, scale: 1.0)
            try await Task.sleep(for: .milliseconds(300))
            let after = try #require(nativeNodes(root), "Native decoration disappeared after the camera change")
            try #require(after.cloud === nodes.cloud && after.metal === nodes.metal
                         && after.scan === nodes.scan && after.gradient === nodes.gradient,
                         "Camera zoom remounted a native decoration and changed its animation identity")
            try #require(fixture.overview.canvasState.camera.liveTransform == zoomCamera)
            report["zoomGeometry"] = try geometry(window, nodes: after, overview: fixture.overview).json
            let zoom = try await capture(window, seconds: 0.55)
            evidence.append(("zoom", zoom))
            try requireFullFrames(zoom, size: CGSize(width: window.frame.width * window.backingScaleFactor,
                                                   height: window.frame.height * window.backingScaleFactor))
            try requireForeground(window)
            try #require(measurements.cloudMoved,
                         "Observation incomplete or stopped cloud: quiet card pixels did not move above the static-background control")
            try #require(measurements.scanMoved,
                         "Observation incomplete or stopped scan: no ordered narrow-band pixel motion crossed the derived row")
            report["assertionsPassed"] = true
            print("NATIVE_OVERVIEW_DECORATION_MOTION_CONFIRMED native=true cloudPixels=true scanPixels=true retained=true appearanceReviewPending=true")
            await fixture.close()
        } catch {
            await fixture.close()
            throw error
        }
    }

    private func setCamera(_ overview: NativeOverviewWorkspaceModel, scale: Double) throws -> NativeOverviewTransform {
        let state = overview.canvasState
        let placement = try #require(state.presentedPlacements.first)
        let viewport = try #require(state.camera.viewport)
        try #require(scale >= state.camera.minimumScale && scale <= state.camera.maximumScale,
                     "Requested observation scale is outside the production camera range")
        let region = NativeOverviewCameraGeometry.contentRegion(viewport)
        let frame = placement.cardFrame
        let transform = NativeOverviewTransform(scale: scale,
            x: region.left + region.width / 2 - frame.midX * scale,
            y: region.top + region.height / 2 - frame.midY * scale)
        state.camera.setManualTransform(transform)
        try #require(state.camera.liveTransform == transform && state.camera.manual && !state.camera.isAnimating,
                     "Production camera did not accept the requested manual transform")
        return transform
    }

    private func nativeNodes(_ root: NSView) -> DecorationNodes? {
        var clouds: [NativeOverviewCloudSurface] = [], scans: [NativeCardScanView] = []
        var legacy = false
        @MainActor func visit(_ view: NSView) {
            if let cloud = view as? NativeOverviewCloudSurface { clouds.append(cloud) }
            if let scan = view as? NativeCardScanView { scans.append(scan) }
            let name = String(describing: type(of: view))
            legacy = legacy || name.contains("NativeCardDecorationContainer") || name.contains("NativeCardDecorationHostingView")
            for child in view.subviews { visit(child) }
        }
        @MainActor func layers(_ layer: CALayer) -> [CALayer] {
            var result = [layer]
            for child in layer.sublayers ?? [] { result.append(contentsOf: layers(child)) }
            return result
        }
        visit(root)
        guard !legacy, clouds.count == 1, scans.count == 1, let cloud = clouds.first, let scan = scans.first,
              !cloud.isHiddenOrHasHiddenAncestor, !scan.isHiddenOrHasHiddenAncestor,
              let cloudLayer = cloud.layer, let scanLayer = scan.layer,
              let metal = layers(cloudLayer).compactMap({ $0 as? CAMetalLayer }).first,
              let gradient = layers(scanLayer).compactMap({ $0 as? CAGradientLayer }).first,
              metal.device != nil, !metal.isHidden, !metal.isOpaque, metal.drawableSize.width > 0,
              metal.drawableSize.height > 0, gradient.animation(forKey: "overview.scan.position") != nil else { return nil }
        return DecorationNodes(cloud: cloud, metal: metal, scan: scan, gradient: gradient)
    }

    private func requireForeground(_ window: NSWindow) throws {
        try #require(NSApp.isActive && window.isVisible && window.isKeyWindow
                     && window.occlusionState.contains(.visible),
                     "Observation incomplete: Overview capture lost foreground visibility")
    }

    private func geometry(_ window: NSWindow, nodes: DecorationNodes,
                          overview: NativeOverviewWorkspaceModel) throws -> DecorationGeometry {
        let scale = window.backingScaleFactor
        @MainActor func pixelFrame(_ view: NSView) -> CGRect {
            let rect = view.convert(view.bounds, to: nil)
            return CGRect(x: rect.minX * scale, y: (window.frame.height - rect.maxY) * scale,
                          width: rect.width * scale, height: rect.height * scale)
        }
        let card = pixelFrame(nodes.cloud), scan = pixelFrame(nodes.scan)
        let camera = overview.canvasState.camera.liveTransform
        let multiplier = CGFloat(camera.scale) * scale
        // The left 360pt identity cell owns the ticking duration. Use only the
        // right derived cell, below its single static 21pt row plus 5/6pt inner
        // and 16pt outer padding. This excludes every identity glyph and scan.
        let cloud = CGRect(x: card.minX + 400 * multiplier, y: card.minY + 106 * multiplier,
                           width: 312 * multiplier, height: 70 * multiplier).integral
        let control = CGRect(x: 8 * scale, y: (window.frame.height - 32) * scale,
                             width: 48 * scale, height: 16 * scale).integral
        let result = DecorationGeometry(card: card, scan: scan, cloud: cloud, control: control,
            scale: scale, multiplier: multiplier, imageSize: CGSize(width: window.frame.width * scale, height: window.frame.height * scale),
            camera: camera)
        try #require(abs(card.width - 736 * multiplier) <= 2 && abs(card.height - 200 * multiplier) <= 2,
                     "Native cloud geometry did not follow the actual manual camera")
        try #require(card.insetBy(dx: -1, dy: -1).contains(scan) && !cloud.intersects(scan.insetBy(dx: -4 * scale, dy: -4 * scale)),
                     "The scan or quiet cloud observation region is outside its intended production card region")
        let image = CGRect(origin: .zero, size: result.imageSize)
        let scanSampling = scan.integral.insetBy(dx: 0, dy: -CGFloat(max(3, Int(4 * scale)) + 1))
        try #require(image.contains(card) && image.contains(cloud) && image.contains(control)
                     && image.contains(scanSampling) && !cloud.intersects(control),
                     "The native observation or scan-control samples extend outside the complete captured window")
        return result
    }

    private func capture(_ window: NSWindow, seconds: Double) async throws -> [TagGlassFrames.Sample] {
        try requireForeground(window)
        let available = try await SCShareableContent.currentProcess
        let target = try #require(available.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
        let configuration = SCStreamConfiguration()
        configuration.width = Int(window.frame.width * window.backingScaleFactor)
        configuration.height = Int(window.frame.height * window.backingScaleFactor)
        configuration.ignoreShadowsSingleWindow = true
        configuration.showsCursor = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        // Fifteen capture samples per second resolve this 3.4s scan. This is a
        // sampling request, not a renderer or physical-display rate assertion.
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 15)
        configuration.queueDepth = 3
        let frames = TagGlassFrames()
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: target), configuration: configuration, delegate: nil)
        try stream.addStreamOutput(frames, type: .screen,
                                   sampleHandlerQueue: DispatchQueue(label: "overview-decoration-capture"))
        try await stream.startCapture()
        var samples: [TagGlassFrames.Sample] = []
        do {
            try await SwiftUIReplay.wait { frames.ready }
            let deadline = ProcessInfo.processInfo.systemUptime + seconds
            while ProcessInfo.processInfo.systemUptime < deadline {
                samples.append(contentsOf: frames.takeSamples())
                try await Task.sleep(for: .milliseconds(40))
            }
            try await stream.stopCapture()
            samples.append(contentsOf: frames.takeSamples())
        } catch {
            try? await stream.stopCapture()
            throw error
        }
        return samples
    }

    private func requireFullFrames(_ samples: [TagGlassFrames.Sample], size: CGSize) throws {
        try #require(!samples.isEmpty && samples.allSatisfy {
            $0.image.width == Int(size.width) && $0.image.height == Int(size.height)
        }, "Observation incomplete: no complete full-window frames at the actual backing scale")
    }

    private func motion(_ samples: [TagGlassFrames.Sample], geometry: DecorationGeometry) throws -> DecorationMotion {
        try requireFullFrames(samples, size: geometry.imageSize)
        let first = try #require(samples.first), last = try #require(samples.last)
        try #require(samples.count >= 25 && last.presentationTime - first.presentationTime >= 3.2,
                     "Observation incomplete: insufficient WindowServer samples to cover one scan cycle")
        let bitmaps = try samples.map { try DecorationPixels($0.image) }
        let baseline = bitmaps[0]
        var cloudRows: [[String: Any]] = [], profiles: [[Double]] = []
        let scan = geometry.scan.integral
        let columns = Int(scan.width)
        for (index, pixels) in bitmaps.enumerated() {
            let cloud = pixels.change(from: baseline, in: geometry.cloud)
            let control = pixels.change(from: baseline, in: geometry.control)
            cloudRows.append(["index": index, "presentationTime": samples[index].presentationTime,
                "receivedAt": samples[index].receivedAt, "meanAbsoluteRGB": cloud.mean,
                "changedFraction": cloud.fraction, "controlMeanAbsoluteRGB": control.mean])
            profiles.append((0..<columns).map { x in
                let column = Int(scan.minX) + x
                let line = pixels.meanLuma(x: column, from: Int(scan.minY), to: Int(scan.maxY))
                let distance = max(3, Int(4 * geometry.scale))
                let above = pixels.meanLuma(x: column, from: Int(scan.minY) - distance, to: Int(scan.minY) - distance + 1)
                let below = pixels.meanLuma(x: column, from: Int(scan.maxY) + distance, to: Int(scan.maxY) + distance + 1)
                return line - (above + below) / 2
            })
        }
        // A first drawable arriving after capture starts must not pass as
        // movement. Compare two disjoint later intervals to one another, not
        // only every frame against a possibly empty initial cloud frame.
        var cloudIntervals: [[String: Any]] = []
        var movingCloudIntervals = 0
        for (start, end) in [(0.5, 1.5), (1.7, 2.7)] {
            let lower = try #require(samples.firstIndex { $0.presentationTime - first.presentationTime >= start })
            let upper = try #require(samples.firstIndex { $0.presentationTime - first.presentationTime >= end })
            let cloud = bitmaps[upper].change(from: bitmaps[lower], in: geometry.cloud)
            let control = bitmaps[upper].change(from: bitmaps[lower], in: geometry.control)
            let moved = cloud.mean > max(0.25, control.mean * 4 + 0.1) && cloud.fraction > 0.02
            if moved { movingCloudIntervals += 1 }
            cloudIntervals.append(["fromIndex": lower, "toIndex": upper,
                "fromPresentationTime": samples[lower].presentationTime, "toPresentationTime": samples[upper].presentationTime,
                "meanAbsoluteRGB": cloud.mean, "changedFraction": cloud.fraction,
                "controlMeanAbsoluteRGB": control.mean, "moved": moved])
        }
        let cloudMoved = movingCloudIntervals == 2
        // Remove static row/background edges independently at each column. The
        // adjacent rows suppress the cloud's broad field; the scan is 1.5pt high.
        let floor = (0..<columns).map { x in profiles.map { $0[x] }.min() ?? 0 }
        var scanRows: [[String: Any]] = []
        var visible: [(index: Int, time: Double, x: Double)] = []
        for (index, profile) in profiles.enumerated() {
            let values = profile.enumerated().map { max(0, $0.element - floor[$0.offset]) }
            let peak = values.max() ?? 0
            let selected = values.enumerated().filter { $0.element >= max(2, peak * 0.35) }
            let energy = selected.reduce(0) { $0 + $1.element }
            let center: Double? = energy > 0 ? selected.reduce(0) { $0 + Double($1.offset) * $1.element } / energy : nil
            scanRows.append(["index": index, "presentationTime": samples[index].presentationTime,
                "peakContrast": peak, "centroidPixels": center.map { $0 as Any } ?? NSNull(), "profile": values])
            if peak >= 4, energy >= 40 * Double(geometry.scale), let center {
                visible.append((index, samples[index].presentationTime, center))
            }
        }
        var scanMoved = false
        for start in visible.indices {
            var end = start
            while end + 1 < visible.count, visible[end + 1].index - visible[end].index <= 2,
                  visible[end + 1].x >= visible[end].x - 2 * Double(geometry.scale) { end += 1 }
            let elapsed = visible[end].time - visible[start].time
            let distance = visible[end].x - visible[start].x
            if end - start >= 4, elapsed > 0.35, distance > Double(columns) * 0.25 {
                let normalizedVelocity = distance / elapsed / Double(columns)
                if normalizedVelocity > 0.20 && normalizedVelocity < 0.65 { scanMoved = true }
            }
        }
        return DecorationMotion(cloudMoved: cloudMoved, scanMoved: scanMoved,
            report: ["cloudMoved": cloudMoved, "scanMoved": scanMoved, "cloud": cloudRows, "cloudIntervals": cloudIntervals, "scan": scanRows,
                "scanExpectedNormalizedVelocity": 1.34 / 3.4,
                "cloudRegion": "Right derived cell below its only static row; entire left identity/runtime cell and scan excluded",
                "scanMethod": "Narrow-row contrast minus neighboring rows and per-column temporal floor; ordered pixel centroid movement"])
    }

    private func save(_ evidence: [(String, [TagGlassFrames.Sample])], report: [String: Any]) throws {
        let base: URL
        if let root = ProcessInfo.processInfo.environment["MOKUSEI_READING_MOTION_ARTIFACTS"] {
            base = URL(fileURLWithPath: root, isDirectory: true)
        } else {
            var repository = URL(fileURLWithPath: #filePath)
            for _ in 0..<6 { repository.deleteLastPathComponent() }
            base = repository.appendingPathComponent(".scratch/reading-presentation", isDirectory: true)
        }
        let directory = base.appendingPathComponent("native-decoration", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (stage, frames) in evidence {
            let stageDirectory = directory.appendingPathComponent(stage, isDirectory: true)
            try FileManager.default.createDirectory(at: stageDirectory, withIntermediateDirectories: true)
            for (index, frame) in frames.enumerated() {
                let png = try #require(NSBitmapImageRep(cgImage: frame.image).representation(using: .png, properties: [:]))
                try png.write(to: stageDirectory.appendingPathComponent(String(format: "%03d.png", index)))
            }
        }
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("measurements.json"))
    }
}

private struct DecorationGeometry {
    let card: CGRect, scan: CGRect, cloud: CGRect, control: CGRect
    let scale: CGFloat, multiplier: CGFloat
    let imageSize: CGSize
    let camera: NativeOverviewTransform
    var json: [String: Any] {
        func rect(_ value: CGRect) -> [CGFloat] { [value.minX, value.minY, value.width, value.height] }
        return ["imagePixels": [imageSize.width, imageSize.height], "backingScale": scale,
            "cardPixels": rect(card), "scanPixels": rect(scan), "cloudObservationPixels": rect(cloud),
            "staticControlPixels": rect(control), "roundedCornerRadiusPixels": 22 * multiplier,
            "camera": ["scale": camera.scale, "x": camera.x, "y": camera.y],
            "coordinateConvention": "Full-window image, top-left origin; native view frames converted through NSWindow"]
    }
}

private struct DecorationMotion {
    let cloudMoved: Bool, scanMoved: Bool
    let report: [String: Any]
}

private struct DecorationPixels {
    let bytes: [UInt8]
    let stride: Int
    init(_ image: CGImage) throws {
        try #require(image.bitsPerPixel == 32 && image.bitsPerComponent == 8)
        let data = try #require(image.dataProvider?.data)
        try #require(CFDataGetLength(data) >= image.bytesPerRow * image.height)
        let pointer = try #require(CFDataGetBytePtr(data))
        bytes = Array(UnsafeBufferPointer(start: pointer, count: image.bytesPerRow * image.height))
        stride = image.bytesPerRow
    }
    func meanLuma(x: Int, from: Int, to: Int) -> Double {
        var sum = 0.0
        for y in from..<to {
            let offset = y * stride + x * 4
            sum += Double(bytes[offset]) * 0.0722 + Double(bytes[offset + 1]) * 0.7152 + Double(bytes[offset + 2]) * 0.2126
        }
        return sum / Double(max(1, to - from))
    }
    func change(from other: Self, in rect: CGRect) -> (mean: Double, fraction: Double) {
        var sum = 0, changed = 0, count = 0
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                let offset = y * stride + x * 4, reference = y * other.stride + x * 4
                let differences = (0..<3).map { abs(Int(bytes[offset + $0]) - Int(other.bytes[reference + $0])) }
                sum += differences.reduce(0, +)
                if (differences.max() ?? 0) >= 3 { changed += 1 }
                count += 1
            }
        }
        return (Double(sum) / Double(max(1, count * 3)), Double(changed) / Double(max(1, count)))
    }
}
