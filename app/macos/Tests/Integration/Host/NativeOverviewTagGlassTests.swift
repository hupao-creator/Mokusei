import AppKit
import CoreMedia
import CoreVideo
import Observation
import MokuseiPluginUI
import ScreenCaptureKit
import SwiftUI
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
@testable import MokuseiUI

/// Copy complete WindowServer frames off the main actor. Retaining the capture
/// pool's pixel buffers would stall delivery; PNG conversion belongs after stop.
private final class TagGlassFrames: NSObject, SCStreamOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [CGImage] = []
    var ready: Bool { lock.withLock { !frames.isEmpty } }
    func take() -> [CGImage] { lock.withLock { let result = frames; frames = []; return result } }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sample.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              attachments.first?[.status] as? Int == SCFrameStatus.complete.rawValue,
              let buffer = sample.imageBuffer,
              CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              lock.withLock({ frames.count < 60 }) else { return }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        // Desktop/window transitions can briefly return a transformed thumbnail.
        // Its transparent border is unrelated to the glass inside our opaque app.
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        guard [0.02, 0.5, 0.98].allSatisfy({ x in
            [0.1, 0.5, 0.9].allSatisfy { y in
                bytes[Int(Double(height) * y) * stride + Int(Double(width) * x) * 4 + 3] > 250
            }
        }) else { return }
        let data = Data(bytes: base, count: stride * height)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: stride, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue).union(.byteOrder32Little),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return }
        lock.withLock { frames.append(image) }
    }
}

@MainActor private func captureTagWindow(_ window: NSWindow, filter: SCContentFilter,
                                        configuration: SCStreamConfiguration) async throws -> CGImage {
    var complete: CGImage?
    for _ in 0..<20 {
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        let bitmap = NSBitmapImageRep(cgImage: image)
        if [0.02, 0.5, 0.98].allSatisfy({ x in
            [0.1, 0.5, 0.9].allSatisfy { y in
                (bitmap.colorAt(x: Int(Double(bitmap.pixelsWide) * x),
                                y: Int(Double(bitmap.pixelsHigh) * y))?.alphaComponent ?? 0) > 0.99
            }
        }) { complete = image; break }
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        try await Task.sleep(for: .milliseconds(100))
    }
    return try #require(complete, "WindowServer did not provide an untransformed full-window capture")
}

@MainActor private func captureGlassMotion(filter: SCContentFilter, configuration: SCStreamConfiguration,
                                         action: () throws -> Void) async throws -> [CGImage] {
    configuration.pixelFormat = kCVPixelFormatType_32BGRA
    configuration.colorSpaceName = CGColorSpace.sRGB
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
    let frames = TagGlassFrames()
    let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
    try stream.addStreamOutput(frames, type: .screen, sampleHandlerQueue: DispatchQueue(label: "tag-glass-capture"))
    try await stream.startCapture()
    do {
        try await SwiftUIReplay.wait { frames.ready }
        _ = frames.take()
        try action()
        try await Task.sleep(for: .milliseconds(400))
        try await stream.stopCapture()
        return frames.take()
    } catch {
        try? await stream.stopCapture()
        throw error
    }
}

@MainActor @Observable private final class TagGlassFixture {
    let children: Bool
    let longNames: Bool
    var selected: NativeOverviewFilter?
    var suppliedFilters: [NativeOverviewFilter]?
    let canvas = NativeOverviewCanvasState()
    let regions = NativeCanvasInputRegions()
    let interactions = NativeOverviewChromeInteractions()
    @ObservationIgnored var bounds: [String: CGRect] = [:]
    init(children: Bool, longNames: Bool = false) { self.children = children; self.longNames = longNames }
    var filters: [NativeOverviewFilter] {
        if let suppliedFilters { return suppliedFilters }
        let names = longNames
            ? ["Very long product development directory Alpha", "Very long design and engineering directory Beta", "Very long integration verification directory Gamma"]
            : ["Alpha", "Beta"]
        return names.map { name in
            .init(tag: name, scope: "/\(name)", count: 3, isDirectory: true, children: children ? [
                .init(tag: "\(name) plan", scope: "/\(name)", count: 2),
                .init(tag: "\(name) review", scope: "/\(name)", count: 1)] : [])
        } + [.init(tag: "Inbox task", count: 2)]
    }
}

private struct TagGlassReplay: View {
    let fixture: TagGlassFixture
    var includeCanvas = false
    var showActions = false
    var captureBounds = true
    var toolbarBottom = OverviewTagMetrics.wideToolbarClearance
    var body: some View {
        ZStack(alignment: .top) {
            if includeCanvas {
                NativeOverviewCanvas(items: [.init(id: "card")], sceneKey: "tag-menu", state: fixture.canvas,
                    toolbarBottom: toolbarBottom, inputRegions: fixture.regions) { _ in Color.blue.frame(width: 360, height: 200) }
            }
            VStack {
                NativeOverviewChrome(filters: fixture.filters, selectedTag: fixture.selected?.tag ?? "",
                    selectedScope: fixture.selected?.scope ?? "",
                    selectedKind: fixture.selected.map { $0.isDirectory ? .directory : .semantic },
                    cameraManual: showActions,
                    onTagChange: { fixture.selected = $0 },
                    onReturnToAuto: showActions ? {} : nil,
                    onSettings: showActions ? {} : nil, onRestart: showActions ? {} : nil,
                    interactions: fixture.interactions)
                Spacer()
            }
        }
        .environment(\.nativeCanvasInputRegions, fixture.regions)
        .modifier(TagGlassBounds(fixture: fixture, enabled: captureBounds))
    }
}

private struct TagGlassBounds: ViewModifier {
    let fixture: TagGlassFixture
    var enabled = true
    func body(content: Content) -> some View {
        content.overlayPreferenceValue(OverviewSearchTagBounds.self) { anchors in
            GeometryReader { reader in
                let resolved = anchors.mapValues { reader[$0] }
                Color.clear
                    .onGeometryChange(for: [String: CGRect].self) { _ in resolved } action: { if enabled { fixture.bounds = $0 } }
                    .allowsHitTesting(false)
            }
        }
    }
}

@MainActor @Suite(.serializedNative, .requiresDisplay, .serialized)
struct NativeOverviewTagGlassTests {
    /// Compare the production prefix with unconstrained native glyph layout,
    /// then capture it in the real glass/scroll hierarchy at compact widths.
    @Test func prefixesKeepNativeGlyphBoundsInCompactChips() async throws {
        let directory = ProcessInfo.processInfo.environment["MOKUSEI_TAG_ICON_ARTIFACTS"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        if let directory { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        func save(_ bitmap: NSBitmapImageRep, _ name: String) throws {
            if let directory {
                try #require(bitmap.representation(using: .png, properties: [:]))
                    .write(to: directory.appendingPathComponent(name + ".png"))
            }
        }
        func glyph<Content: View>(_ content: Content, _ name: String) throws -> (pixels: Int, height: Int) {
            let renderer = ImageRenderer(content: content.frame(width: 48, height: 48))
            renderer.scale = 2
            let bitmap = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
            try save(bitmap, name)
            var pixels = 0, firstY = bitmap.pixelsHigh, lastY = -1
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                    pixels += 1; firstY = min(firstY, y); lastY = max(lastY, y)
                }
            }
            return (pixels, lastY - firstY + 1)
        }
        let emojis: [String?] = ["🛠", "🛠️", "🎨", "👩🏽‍💻", nil]
        var measurements: [[String: String]] = []
        for (index, emoji) in emojis.enumerated() {
            let actual = try glyph(OverviewTagPrefix(emoji: emoji), "prefix-\(index)")
            let expected: (pixels: Int, height: Int)
            if let emoji {
                expected = try glyph(Text(emoji).font(.system(size: OverviewTagMetrics.folderIcon)).fixedSize(), "reference-\(index)")
            } else {
                expected = try glyph(NativeIcon(name: "Folder", size: OverviewTagMetrics.folderIcon).opacity(0.72), "reference-\(index)")
            }
            #expect(expected.pixels > 20 && expected.height > 10, "Native glyph reference did not render")
            #expect(actual.height >= expected.height - 1, "Prefix \(emoji ?? "Folder") lost native glyph height: \(actual) vs \(expected)")
            #expect(Double(actual.pixels) >= Double(expected.pixels) * 0.95, "Prefix \(emoji ?? "Folder") lost native glyph pixels: \(actual) vs \(expected)")
            measurements.append(["icon": emoji ?? "Folder", "actual": "\(actual)", "reference": "\(expected)"])
        }
        if let directory {
            try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("glyphs.json"))
        }
        for scheme in [ColorScheme.light, .dark] {
            for width in [360.0, 540.0, 1000.0] {
                let fixture = TagGlassFixture(children: true)
                let window = SwiftUIReplay.window(TagGlassReplay(fixture: fixture, showActions: true)
                    .background(Color.cyan.gradient).preferredColorScheme(scheme), width: width, height: 260,
                    offscreen: directory == nil)
                window.animationBehavior = .none
                // Geometry-only runs must not inherit native glass hover from
                // the runner's pointer as each replacement chip is mounted.
                // WindowServer captures still need an on-screen window.
                if directory != nil, let screen = window.screen {
                    let visible = screen.visibleFrame
                    window.setFrameOrigin(CGPoint(x: visible.minX,
                        y: NSEvent.mouseLocation.y < visible.midY ? visible.maxY - window.frame.height : visible.minY))
                }
                defer { window.close() }
                for (index, emoji) in emojis.enumerated() {
                    let child = NativeOverviewFilter(tag: index == 2 ? "很长的功能改进与原生图标排版验证" : "功能改进", emoji: emoji, scope: "/OpenAgent", count: 3)
                    let parent = NativeOverviewFilter(tag: index == 1 ? "非常长的 OpenAgent 项目目录" : "OpenAgent", scope: "/OpenAgent", count: index == 1 ? 123 : 3, isDirectory: true, children: [child])
                    window.makeKeyAndOrderFront(nil)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    fixture.suppliedFilters = [parent, .init(tag: "🎨 界面设计", count: 12)]
                    fixture.selected = child
                    try await SwiftUIReplay.wait { fixture.bounds[parent.id] != nil && fixture.bounds["__actions__"] != nil }
                    try await Task.sleep(for: .milliseconds(500))
                    let bar = try #require(fixture.bounds["__bar__"])
                    let actions = try #require(fixture.bounds["__actions__"])
                    let parentBounds = try #require(fixture.bounds[parent.id])
                    #expect(bar.minX >= 0 && bar.maxX <= width && !bar.intersects(actions))
                    #expect(abs(parentBounds.height - OverviewTagMetrics.chipHeight) < 0.5)
                    if directory != nil {
                        let shareable = try await SCShareableContent.currentProcess
                        let target = try #require(shareable.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
                        let configuration = SCStreamConfiguration()
                        configuration.width = Int(window.frame.width * 2)
                        configuration.height = Int(window.frame.height * 2)
                        configuration.scalesToFit = true
                        configuration.ignoreShadowsSingleWindow = true
                        configuration.showsCursor = false
                        // WindowServer may briefly return a system window
                        // transition. Retain evidence only once this window
                        // fills its capture instead of accepting a thumbnail.
                        var complete = false
                        for _ in 0..<20 {
                            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: configuration)
                            let bitmap = NSBitmapImageRep(cgImage: image)
                            complete = [0.1, 0.5, 0.9].allSatisfy { x in
                                [0.25, 0.5, 0.75].allSatisfy { y in
                                    (bitmap.colorAt(x: Int(Double(bitmap.pixelsWide) * x), y: Int(Double(bitmap.pixelsHigh) * y))?.alphaComponent ?? 0) > 0.99
                                }
                            }
                            if complete {
                                try save(bitmap, "\(scheme)-\(Int(width))-\(index)")
                                break
                            }
                            window.makeKeyAndOrderFront(nil)
                            NSApplication.shared.activate(ignoringOtherApps: true)
                            try await Task.sleep(for: .milliseconds(100))
                        }
                        #expect(complete, "WindowServer did not provide a complete window capture")
                    }
                }
            }
        }
    }

    /// Drive the recorded child-to-inbox switch through production controls and
    /// retain moving WindowServer frames, not just settled layout anchors.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MOKUSEI_READING_PRESENTATION_NATIVE_REPLAY"] == "1", "Requires isolated native glass/window capture: python3 tools/verification/reading-presentation/run.py --tag-glass"))
    func directorySelectionResizeKeepsRoundedGlass() async throws {
        let app = NSApplication.shared
        let enableAX = NSSelectorFromString("accessibilitySetValue:forAttribute:")
        if app.responds(to: enableAX) { _ = app.perform(enableAX, with: true, with: "AXEnhancedUserInterface") }
        let child = NativeOverviewFilter(tag: "功能改进", emoji: "🛠", scope: "/OpenAgent", count: 5)
        let parent = NativeOverviewFilter(tag: "OpenAgent", scope: "/OpenAgent", count: 5, isDirectory: true, children: [child])
        let design = NativeOverviewFilter(tag: "🎨 界面设计", count: 1)
        let fixture = TagGlassFixture(children: true)
        fixture.suppliedFilters = [parent, design, .init(tag: "📈 金融研究", count: 1)]
        fixture.selected = child
        let window = SwiftUIReplay.window(TagGlassReplay(fixture: fixture)
            .background(Color.black).preferredColorScheme(.dark), width: 720, height: 260)
        window.animationBehavior = .none
        if let screen = window.screen {
            let visible = screen.visibleFrame
            window.setFrameOrigin(CGPoint(x: visible.minX,
                y: NSEvent.mouseLocation.y < visible.midY ? visible.maxY - window.frame.height : visible.minY))
        }
        defer { window.close() }
        let root = try #require(window.contentView)
        try await SwiftUIReplay.wait { fixture.bounds[parent.id] != nil }
        try await Task.sleep(for: .milliseconds(600))
        let shareable = try await SCShareableContent.currentProcess
        let target = try #require(shareable.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
        let filter = SCContentFilter(desktopIndependentWindow: target)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(window.frame.width * 2)
        configuration.height = Int(window.frame.height * 2)
        // The pixel oracle uses two pixels per point on both 1x and 2x
        // screens. Without upscaling, ScreenCaptureKit pads a 1x image.
        configuration.scalesToFit = true
        configuration.ignoreShadowsSingleWindow = true
        configuration.showsCursor = false
        let parentBounds = try #require(fixture.bounds[parent.id])
        let titlebar = window.frame.height - root.bounds.height
        var measurements: [[String: String]] = []
        func snapshot(_ name: String, image supplied: CGImage? = nil) async throws -> NSBitmapImageRep {
            let image: CGImage
            if let supplied { image = supplied }
            else { image = try await captureTagWindow(window, filter: filter, configuration: configuration) }
            let bitmap = NSBitmapImageRep(cgImage: image)
            if let directory = ProcessInfo.processInfo.environment["MOKUSEI_TAG_SWITCH_ARTIFACTS"] {
                let url = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try bitmap.representation(using: .png, properties: [:])!
                    .write(to: url.appendingPathComponent(name + ".png"))
            }
            return bitmap
        }
        @discardableResult
        func capture(_ name: String, image: CGImage? = nil, requiresSeparateGlass: Bool = true) async throws -> Int? {
            let bitmap = try await snapshot(name, image: image)
            // On black, the settled real glass forms four continuous spans.
            // Compare the second span's upper edge and equator, independently
            // of the layout anchors (which already describe the animation endpoint).
            func spans(at y: Int) -> [ClosedRange<Int>] {
                var result: [ClosedRange<Int>] = [], start: Int?
                for x in 0..<bitmap.pixelsWide {
                    let painted = (bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)?.greenComponent ?? 0) > 0.025
                    if painted && start == nil { start = x }
                    if !painted, let first = start {
                        if x - first > 15 { result.append(first...(x - 1)) }
                        start = nil
                    }
                }
                return result
            }
            let top = spans(at: Int((parentBounds.minY + titlebar + 2) * 2))
            let middle = spans(at: Int((parentBounds.midY + titlebar) * 2))
            guard top.count == 4 && middle.count == 4 else {
                // GlassEffectContainer blends adjacent glass while a morph moves
                // it across the container spacing, so a moving chip can share a
                // span with its neighbour and reduce the equator count. Only a
                // blend (still four caps at the top edge, fewer at the equator)
                // is expected; any other count is an unexpected capture.
                try #require(!requiresSeparateGlass && top.count == 4 && middle.count < 4,
                             "Incomplete glass capture: \(name): top=\(top.count) middle=\(middle.count)")
                measurements.append(["frame": name, "merged": "true"])
                try writeMeasurements()
                return nil
            }
            let leftInset = top[1].lowerBound - middle[1].lowerBound
            let rightInset = middle[1].upperBound - top[1].upperBound
            #expect(leftInset >= 12 && rightInset >= 12,
                "Directory capsule cut during \(name): left=\(leftInset), right=\(rightInset)")
            measurements.append(["frame": name, "width": "\(middle[1].count)",
                "leftInset": "\(leftInset)", "rightInset": "\(rightInset)"])
            try writeMeasurements()
            return middle[1].count
        }
        func writeMeasurements() throws {
            guard let directory = ProcessInfo.processInfo.environment["MOKUSEI_TAG_SWITCH_ARTIFACTS"] else { return }
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys])
                .write(to: url.appendingPathComponent("pixels.json"))
        }
        let expandedWidth = try #require(try await capture("before"))
        // Arm continuous capture before input: separate screenshot requests can
        // miss a short resize even when their pixel analysis is deferred.
        let shrinkingFrames = try await captureGlassMotion(filter: filter, configuration: configuration) {
            _ = try #require(Self.element(id: design.id, in: root)).perform(NSSelectorFromString("accessibilityPerformPress"))
        }
        var shrinkingWidths: [Int] = []
        var shrinkingSawMergedGlass = false
        for (index, image) in shrinkingFrames.enumerated() {
            let width = try await capture("shrinking-\(index)", image: image, requiresSeparateGlass: false)
            if let width { shrinkingWidths.append(width) } else { shrinkingSawMergedGlass = true }
        }
        try await Task.sleep(for: .milliseconds(350))
        let compactWidth = try #require(try await capture("after"))
        #expect(expandedWidth > compactWidth + 40)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            // Settled chips never touch. A merged moving span therefore proves
            // the glass travelled across the container spacing; a separated
            // moving frame proves the same through an intermediate width.
            #expect(shrinkingSawMergedGlass
                || shrinkingWidths.contains { $0 > compactWidth + 8 && $0 < expandedWidth - 8 },
                "Capture must include moving glass, not only the two endpoints")
        }
        #expect(fixture.selected == design)
        try Self.action("按标签筛选", id: parent.id, in: root)
        try await SwiftUIReplay.wait { Self.element(id: child.id, in: root) != nil }
        try await Task.sleep(for: .milliseconds(400))
        let expandingFrames = try await captureGlassMotion(filter: filter, configuration: configuration) {
            _ = try #require(Self.element(id: child.id, in: root)).perform(NSSelectorFromString("accessibilityPerformPress"))
        }
        for (index, image) in expandingFrames.enumerated() {
            try await capture("expanding-\(index)", image: image, requiresSeparateGlass: false)
        }
        try await Task.sleep(for: .milliseconds(350))
        _ = try #require(try await capture("restored"))
        #expect(fixture.selected == child)

        // Real horizontal scrolling must still cut the source at the viewport,
        // instead of manufacturing a rounded end or letting glass escape it.
        let finance = NativeOverviewFilter(tag: "📈 金融研究", count: 1)
        let longTag = NativeOverviewFilter(tag: "Long directory filter deliberately filling most of the available toolbar width", count: 1)
        for leading in [true, false] {
            fixture.suppliedFilters = leading ? [parent, design, finance, longTag] : [longTag, parent, design, finance]
            try await Task.sleep(for: .milliseconds(600))
            try fixture.interactions.scrollTo(leading ? finance.id : longTag.id)
            try await Task.sleep(for: .milliseconds(400))
            let source = try #require(fixture.bounds[parent.id])
            let viewport = try #require(fixture.bounds["__scroll__"])
            let visible = source.intersection(viewport)
            try #require(visible.width > 30 && visible.width < source.width - 10)
            #expect(leading ? source.minX < viewport.minX : source.maxX > viewport.maxX)
            let bitmap = try await snapshot(leading ? "scrolled-leading" : "scrolled-trailing")
            let edge = leading ? viewport.minX : viewport.maxX
            let y = Int((source.minY + titlebar + 2) * 2)
            let inside = Int((edge + (leading ? 2 : -2)) * 2)
            let outside = Int((edge + (leading ? -2 : 2)) * 2)
            #expect((bitmap.colorAt(x: inside, y: y)?.usingColorSpace(.sRGB)?.greenComponent ?? 0) > 0.025)
            #expect((bitmap.colorAt(x: outside, y: y)?.usingColorSpace(.sRGB)?.greenComponent ?? 1) < 0.025)
        }
    }

    /// Sample the real glass while it returns to a wider parent. Checking the
    /// settled row alone misses the rectangular clipping in the reported video.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MOKUSEI_READING_PRESENTATION_NATIVE_REPLAY"] == "1", "Requires isolated native glass/window capture: python3 tools/verification/reading-presentation/run.py --tag-glass"))
    func shortChildMorphKeepsBothCapsuleEnds() async throws {
        let app = NSApplication.shared
        let enableAX = NSSelectorFromString("accessibilitySetValue:forAttribute:")
        if app.responds(to: enableAX) { _ = app.perform(enableAX, with: true, with: "AXEnhancedUserInterface") }
        let child = NativeOverviewFilter(tag: "配置修复", scope: "/OpenAgent", count: 1)
        let parent = NativeOverviewFilter(tag: "OpenAgent", scope: "/OpenAgent", count: 1, isDirectory: true, children: [child])
        let fixture = TagGlassFixture(children: true)
        fixture.suppliedFilters = [parent]
        fixture.selected = child
        let window = SwiftUIReplay.window(TagGlassReplay(fixture: fixture)
            .background(Color.black).preferredColorScheme(.dark), width: 720, height: 260)
        defer { window.close() }
        let root = try #require(window.contentView)
        try await SwiftUIReplay.wait { fixture.bounds[parent.id] != nil }
        try await Task.sleep(for: .milliseconds(450))
        try Self.action("按标签筛选", id: parent.id, in: root)
        try await SwiftUIReplay.wait { fixture.bounds[child.id] != nil }
        try await Task.sleep(for: .milliseconds(450))
        let childBounds = try #require(fixture.bounds[child.id])
        let parentBounds = try #require(fixture.bounds[parent.id])
        #expect(parentBounds.width > childBounds.width + 30)
        let shareable = try await SCShareableContent.currentProcess
        let target = try #require(shareable.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
        let filter = SCContentFilter(desktopIndependentWindow: target)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(window.frame.width * 2)
        configuration.height = Int(window.frame.height * 2)
        configuration.scalesToFit = true
        configuration.ignoreShadowsSingleWindow = true
        configuration.showsCursor = false
        let titlebar = window.frame.height - root.bounds.height
        func capture(_ name: String, image supplied: CGImage? = nil) async throws -> NSBitmapImageRep {
            let image: CGImage
            if let supplied { image = supplied }
            else { image = try await captureTagWindow(window, filter: filter, configuration: configuration) }
            let bitmap = NSBitmapImageRep(cgImage: image)
            if let directory = ProcessInfo.processInfo.environment["MOKUSEI_TAG_MORPH_ARTIFACTS"] {
                let url = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try bitmap.representation(using: .png, properties: [:])!.write(to: url.appendingPathComponent(name + ".png"))
            }
            return bitmap
        }
        let baseline = try await capture("settled")
        let closingFrames = try await captureGlassMotion(filter: filter, configuration: configuration) {
            try Self.action("关闭子标签菜单", id: parent.id, in: root)
        }
        var leftPixels = 0, rightPixels = 0
        for (index, image) in closingFrames.enumerated() {
            let bitmap = try await capture("closing-\(index)", image: image)
            var left = 0, right = 0
            // Stay below the parent and outside the settled child viewport.
            // A clipped morph cannot paint either of these strips.
            for y in Int((parentBounds.maxY + 4 + titlebar) * 2)..<Int((childBounds.maxY + titlebar) * 2) {
                for x in Int(parentBounds.minX * 2)..<Int(parentBounds.maxX * 2) {
                    let isLeft = CGFloat(x) / 2 < childBounds.minX - 2
                    let isRight = CGFloat(x) / 2 > childBounds.maxX + 2
                    guard isLeft || isRight,
                          let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                          let before = baseline.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                          color.greenComponent > before.greenComponent + 0.04 else { continue }
                    if isLeft { left += 1 } else { right += 1 }
                }
            }
            leftPixels = max(leftPixels, left); rightPixels = max(rightPixels, right)
        }
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            #expect(leftPixels > 20, "Left capsule end never rendered outside the short child viewport: \(leftPixels)")
            #expect(rightPixels > 20, "Right capsule end never rendered outside the short child viewport: \(rightPixels)")
        }
        try await SwiftUIReplay.wait { Self.element(id: child.id, in: root) == nil }
        // Optional timing evidence uses the same production AX opening path.
        // Record capture intervals: WindowServer readback is not instantaneous.
        if let directory = ProcessInfo.processInfo.environment["MOKUSEI_TAG_MORPH_ARTIFACTS"] {
            let clock = ContinuousClock()
            let start = clock.now
            try Self.action("按标签筛选", id: parent.id, in: root)
            var samples: [[String: Double]] = []
            for milliseconds in [0, 50, 100, 150, 220, 320, 450] {
                try await clock.sleep(until: start.advanced(by: .milliseconds(milliseconds)))
                let before = start.duration(to: clock.now)
                _ = try await capture("opening-\(milliseconds)")
                let after = start.duration(to: clock.now)
                func seconds(_ duration: Duration) -> Double {
                    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
                }
                samples.append(["targetMs": Double(milliseconds), "captureStartMs": seconds(before) * 1000,
                                "captureEndMs": seconds(after) * 1000])
            }
            try JSONSerialization.data(withJSONObject: samples, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("opening-times.json"))
        }
    }

    @Test func closedChildSelectionUpdatesDirectoryLabelAndClears() async throws {
        let fixture = TagGlassFixture(children: true)
        let window = SwiftUIReplay.window(TagGlassReplay(fixture: fixture), width: 1000, height: 300)
        defer { window.close() }
        let parent = fixture.filters[0]
        try await SwiftUIReplay.wait { fixture.bounds[parent.id] != nil }
        try await Task.sleep(for: .milliseconds(400))
        let baseline = try #require(fixture.bounds[parent.id]).width
        fixture.selected = parent.children[0]
        try await SwiftUIReplay.wait { (fixture.bounds[parent.id]?.width ?? 0) > baseline + 10 }
        #expect(fixture.bounds["__selection__"] == nil)
        for selected in [parent, nil] {
            fixture.selected = selected
            try await SwiftUIReplay.wait { abs((fixture.bounds[parent.id]?.width ?? 0) - baseline) < 0.5 }
        }
    }

    /// Exercise the production glass menu, actions, labels and canvas input
    /// regions. The title must remain frozen while the retiring row is drawn.
    @Test func childSelectionSemanticsAndMenuInputSurviveOpenAndClose() async throws {
        let app = NSApplication.shared
        let enableAX = NSSelectorFromString("accessibilitySetValue:forAttribute:")
        if app.responds(to: enableAX) {
            _ = app.perform(enableAX, with: true, with: "AXEnhancedUserInterface")
        }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for width in [1000.0, 540.0] {
            let fixture = TagGlassFixture(children: true)
            // This case drives AX actions and direct scroll snapshots, not
            // physical pointer input. A visible desktop window can receive a
            // genuine hover exit during the 300ms observation and close its menu.
            let window = SwiftUIReplay.window(TagGlassReplay(fixture: fixture, includeCanvas: true,
                toolbarBottom: width <= 620 ? OverviewTagMetrics.narrowToolbarClearance : OverviewTagMetrics.wideToolbarClearance), width: width, height: 400, offscreen: true)
            #expect(NSScreen.screens.allSatisfy { !window.frame.intersects($0.frame) })
            defer { window.close(); fixture.canvas.camera.dispose() }
            let root = try #require(window.contentView)
            let parent = fixture.filters[0]
            try await SwiftUIReplay.wait { fixture.bounds[parent.id] != nil && fixture.canvas.camera.isInitialized && !fixture.canvas.isLayingOut }
            try await Task.sleep(for: .milliseconds(450))
            let bridge = try #require(Self.monitor(in: root))
            for selected in parent.children {
                try Self.action("按标签筛选", id: parent.id, in: root)
                try await SwiftUIReplay.wait { Self.element(id: selected.id, in: root) != nil && fixture.bounds[selected.id] != nil }
                try await Task.sleep(for: .milliseconds(300))
                let before = try #require(fixture.bounds[parent.id])
                let oldTitle = Self.string("accessibilityValue", on: try #require(Self.element(id: parent.id, in: root)))
                let rect = try #require(fixture.bounds[selected.id])
                let point = root.convert(CGPoint(x: rect.midX, y: root.isFlipped ? rect.midY : root.bounds.height - rect.midY), to: nil)
                let camera = fixture.canvas.camera.liveTransform
                #expect(bridge.handle(TagMenuScrollSample(target: window, point: point)) != nil)
                #expect(fixture.canvas.camera.liveTransform == camera)
                #expect(!bridge.canStart(at: bridge.canvasPoint(point)))
                let canvasPoint = bridge.windowPoint(CGPoint(x: 60, y: 300))
                // A sequence beginning in the submenu remains native
                // after crossing onto the canvas, including momentum.
                for event in [
                    TagMenuScrollSample(target: window, point: point, phase: .began),
                    TagMenuScrollSample(target: window, point: canvasPoint, phase: .changed),
                    TagMenuScrollSample(target: window, point: canvasPoint, phase: .ended, x: 0, y: 0),
                    TagMenuScrollSample(target: window, point: canvasPoint, momentum: .began),
                    TagMenuScrollSample(target: window, point: canvasPoint, momentum: .changed),
                    TagMenuScrollSample(target: window, point: canvasPoint, momentum: .ended, x: 0, y: 0)
                ] {
                    #expect(bridge.handle(event) === event)
                    #expect(fixture.canvas.camera.liveTransform == camera)
                }
                // Reverse direction: visible chrome cannot steal an
                // already canvas-owned sequence or its inertia.
                var expected = camera
                for event in [
                    TagMenuScrollSample(target: window, point: canvasPoint, phase: .began),
                    TagMenuScrollSample(target: window, point: point, phase: .changed),
                    TagMenuScrollSample(target: window, point: point, phase: .ended, x: 0, y: 0),
                    TagMenuScrollSample(target: window, point: point, momentum: .began),
                    TagMenuScrollSample(target: window, point: point, momentum: .changed),
                    TagMenuScrollSample(target: window, point: point, momentum: .ended, x: 0, y: 0)
                ] {
                    #expect(bridge.handle(event) == nil)
                    expected = NativeOverviewCameraGeometry.pan(expected, deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY)
                    #expect(fixture.canvas.camera.liveTransform == expected)
                }
                // Separate real menu state from AX lookup failures. The
                // fixture must stay beyond physical hover throughout the case.
                try #require(NSScreen.screens.allSatisfy { !window.frame.intersects($0.frame) })
                try #require(fixture.interactions.openScope == parent.scope)
                try #require(fixture.interactions.mountedMenuIDs.contains(parent.id))
                let childElement = try #require(Self.element(id: selected.id, in: root))
                _ = childElement.perform(NSSelectorFromString("accessibilityPerformPress"))
                if !reduceMotion {
                    try await Task.sleep(for: .milliseconds(30))
                    let during = try #require(fixture.bounds[parent.id])
                    #expect(abs(during.minX - before.minX) < 0.5 && abs(during.width - before.width) < 0.5)
                    #expect(Self.string("accessibilityValue", on: try #require(Self.element(id: parent.id, in: root))) == oldTitle)
                }
                let title = "\(parent.displayTag) / \(selected.displayTag) · \(parent.count)"
                try await SwiftUIReplay.wait {
                    guard let element = Self.element(id: parent.id, in: root) else { return false }
                    return fixture.selected == selected && Self.element(id: selected.id, in: root) == nil
                        && Self.string("accessibilityValue", on: element) == title
                }
                #expect(Self.element(id: "overview-current-filter", in: root) == nil)
                #expect(fixture.bounds["__selection__"] == nil)
                #expect(bridge.handle(TagMenuScrollSample(target: window, point: point)) == nil)
            }
            // Interrupt one exit by reopening, then replace the selection.
            // The retired completion must not resize the newly open source.
            if !reduceMotion {
                try Self.action("按标签筛选", id: parent.id, in: root)
                try await SwiftUIReplay.wait { Self.element(id: parent.children[0].id, in: root) != nil }
                let title = Self.string("accessibilityValue", on: try #require(Self.element(id: parent.id, in: root)))
                _ = try #require(Self.element(id: parent.children[0].id, in: root)).perform(NSSelectorFromString("accessibilityPerformPress"))
                try await SwiftUIReplay.wait { Self.element(id: parent.children[0].id, in: root) == nil }
                try Self.action("按标签筛选", id: parent.id, in: root)
                fixture.selected = parent.children[0]
                try await Task.sleep(for: .milliseconds(350))
                #expect(Self.element(id: parent.children[1].id, in: root) != nil)
                #expect(Self.string("accessibilityValue", on: try #require(Self.element(id: parent.id, in: root))) == title)
                try Self.action("关闭子标签菜单", id: parent.id, in: root)
                try await SwiftUIReplay.wait {
                    guard let element = Self.element(id: parent.id, in: root) else { return false }
                    return Self.element(id: parent.children[1].id, in: root) == nil
                        && Self.string("accessibilityValue", on: element) == "Alpha / Alpha plan · 3"
                }
            }
            let ordinary = try #require(fixture.filters.last)
            fixture.selected = ordinary
            try await SwiftUIReplay.wait {
                guard let element = Self.element(id: parent.id, in: root) else { return false }
                return Self.string("accessibilityValue", on: element) == "Alpha · 3"
            }
            #expect(Self.string("accessibilityValue", on: try #require(Self.element(id: ordinary.id, in: root))) == "Inbox task · 2")
            fixture.selected = parent
            try await SwiftUIReplay.wait {
                guard let element = Self.element(id: parent.id, in: root) else { return false }
                return Self.string("accessibilityValue", on: element) == "Alpha · 3"
            }
            fixture.selected = nil
            try await SwiftUIReplay.wait { fixture.selected == nil }
        }
    }

    @Test func longChildTitleStaysInFilterBarAtNarrowWidthsAndWindowZoom() async throws {
        for (width, scale) in [(620.0, 1.0), (540.0, 1.0), (360.0, 1.0), (1000.0, 2.0), (720.0, 2.0), (1242.0, 2.0), (1000.0, 1.0)] {
            let fixture = TagGlassFixture(children: true, longNames: true)
            let logicalWidth = width / scale
            let content = TagGlassReplay(fixture: fixture, showActions: true, captureBounds: false)
                .frame(width: logicalWidth, height: 500 / scale, alignment: .topLeading)
                .environment(\.nativeWindowContentScale, scale)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: width, height: 500, alignment: .topLeading)
                .modifier(TagGlassBounds(fixture: fixture))
            let window = SwiftUIReplay.window(content, width: width, height: 500)
            defer { window.close() }
            try await SwiftUIReplay.wait { fixture.bounds["__bar__"] != nil && fixture.bounds["__actions__"] != nil }
            for selected in [fixture.filters[0].children[0], fixture.filters[0], nil] {
                fixture.selected = selected
                try await Task.sleep(for: .milliseconds(100))
                let bar = try #require(fixture.bounds["__bar__"])
                let actions = try #require(fixture.bounds["__actions__"])
                #expect(!bar.intersects(actions))
                #expect(bar.minX >= 0 && bar.maxX <= width)
                #expect(fixture.bounds["__selection__"] == nil)
            }
        }
    }

    private static func monitor(in view: NSView) -> NativeOverviewScrollInput.MonitorView? {
        if let monitor = view as? NativeOverviewScrollInput.MonitorView { return monitor }
        return view.subviews.lazy.compactMap { monitor(in: $0) }.first
    }
    private static func string(_ property: String, on element: NSObject) -> String? {
        let selector = NSSelectorFromString(property)
        guard element.responds(to: selector) else { return nil }
        if let value = element.perform(selector)?.takeUnretainedValue() as? String, !value.isEmpty { return value }
        let legacy = NSSelectorFromString("accessibilityAttributeValue:")
        let key = property == "accessibilityIdentifier" ? "AXIdentifier" : property == "accessibilityValue" ? "AXValue" : "AXDescription"
        guard element.responds(to: legacy) else { return nil }
        return element.perform(legacy, with: key)?.takeUnretainedValue() as? String
    }
    private static func element(id: String, in root: NSView) -> NSObject? {
        var seen = Set<ObjectIdentifier>()
        func visit(_ object: AnyObject) -> NSObject? {
            guard seen.insert(ObjectIdentifier(object)).inserted, seen.count < 10000, let element = object as? NSObject else { return nil }
            if string("accessibilityIdentifier", on: element) == id { return element }
            let children = NSSelectorFromString("accessibilityChildren")
            if element.responds(to: children), let values = element.perform(children)?.takeUnretainedValue() as? [AnyObject] {
                for child in values { if let found = visit(child) { return found } }
            }
            let legacy = NSSelectorFromString("accessibilityAttributeValue:")
            if element.responds(to: legacy), let values = element.perform(legacy, with: "AXChildren")?.takeUnretainedValue() as? [AnyObject] {
                for child in values { if let found = visit(child) { return found } }
            }
            if let view = element as? NSView {
                for child in view.subviews { if let found = visit(child) { return found } }
            }
            return nil
        }
        _ = root.window?.accessibilityChildren()
        return visit(root.window ?? root)
    }
    private static func action(_ name: String, id: String, in root: NSView) throws {
        let element = try #require(Self.element(id: id, in: root))
        let selector = NSSelectorFromString("accessibilityCustomActions")
        let actions = element.perform(selector)?.takeUnretainedValue() as? [NSAccessibilityCustomAction]
        let action = try #require(actions?.first { $0.name == name })
        if let handler = action.handler { #expect(handler()) }
        else if let target = action.target as? NSObject, let selector = action.selector { _ = target.perform(selector, with: action) }
        else { Issue.record("Missing executable accessibility action") }
    }

    /// Populated directories no longer reserve a disclosure glyph or its gap.
    /// Compare live layouts in independent hosts so a delayed update cannot
    /// accidentally compare the previous frame against itself.
    @Test func childAvailabilityDoesNotChangeDirectoryButtonWidth() async throws {
        let populated = TagGlassFixture(children: true)
        let empty = TagGlassFixture(children: false)
        let populatedWindow = SwiftUIReplay.window(TagGlassReplay(fixture: populated), width: 1000, height: 300)
        let emptyWindow = SwiftUIReplay.window(TagGlassReplay(fixture: empty), width: 1000, height: 300)
        defer { populatedWindow.close(); emptyWindow.close() }
        let ids = populated.filters.map(\.id)
        try await SwiftUIReplay.wait {
            ids.allSatisfy { populated.bounds[$0] != nil && empty.bounds[$0] != nil }
        }
        for id in ids {
            let withChildren = try #require(populated.bounds[id])
            let withoutChildren = try #require(empty.bounds[id])
            #expect(withChildren.width > 42 && withoutChildren.width > 42)
            #expect(abs(withChildren.width - withoutChildren.width) < 0.5)
        }
    }
}

/// Snapshots remain outside AppKit dispatch, as in the Overview input replay.
private final class TagMenuScrollSample: NSEvent {
    let target: NSWindow
    let point: CGPoint
    let direct: NSEvent.Phase
    let inertia: NSEvent.Phase
    let x: CGFloat
    let y: CGFloat
    init(target: NSWindow, point: CGPoint, phase: NSEvent.Phase = [], momentum: NSEvent.Phase = [], x: CGFloat = 5, y: CGFloat = -7) {
        self.target = target; self.point = point; direct = phase; inertia = momentum; self.x = x; self.y = y
        super.init()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var type: NSEvent.EventType { .scrollWheel }
    override var window: NSWindow? { target }
    override var locationInWindow: NSPoint { point }
    override var scrollingDeltaX: CGFloat { x }
    override var scrollingDeltaY: CGFloat { y }
    override var hasPreciseScrollingDeltas: Bool { true }
    override var phase: NSEvent.Phase { direct }
    override var momentumPhase: NSEvent.Phase { inertia }
    override var modifierFlags: NSEvent.ModifierFlags { [] }
    override var timestamp: TimeInterval { ProcessInfo.processInfo.systemUptime }
}
