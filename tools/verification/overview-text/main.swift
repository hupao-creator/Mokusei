// Own-window, lossless rendering controls; no runtime or user conversations.
import AppKit
import Observation
import ScreenCaptureKit
import SwiftUI
import MokuseiPluginUI
import MokuseiUI

private let title = "诊断提及搜索卡顿"
private let excerpt = "正在分析 glass invalidation 的机制，并评估 discovery 的 EvalSymlinks 与顺序扫描是否比模拟估算的性能更差。"

@MainActor @Observable private final class Fixture {
    let state = NativeOverviewCanvasState()
    let reading = NativeReadingPageMotion()
    var scale: CGFloat = 1
    var windowScale: CGFloat = 1
    var boost = false
    var method = "scale"
    var direct = false
    var useGlassContainer = true
    var reference = false
    var ready = false
    var frame = CGRect.zero
    let presentation = try! composeThreadCard(.standard(identity: .init(usage: .init(parts: [.init(id: "tokens", value: "110400", numericValue: 110400)])), extensions: []), layoutContext: .init(availableCols: 4))
}

private struct ResolutionControl: ViewModifier {
    let reference: Bool
    @Environment(\.threadCardTextRasterScale) private var resolution
    func body(content: Content) -> some View {
        content.environment(\.threadCardTextRasterScale, reference ? 1 : resolution)
    }
}

private struct VectorText: TextRenderer {
    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout { context.draw(line, options: .disablesSubpixelQuantization) }
    }
}

private struct Probe: View {
    var scale: CGFloat
    var body: some View {
        VStack(alignment: .leading, spacing: 5 * scale) {
            Text(title).font(NativeTypography.inter(size: 15 * scale, weight: 620))
                .foregroundStyle(NativePalette.overview.ink.swiftUI)
            Text("xai/grok-4.7 · 高").font(NativeTypography.inter(size: 11 * scale, weight: 580))
                .foregroundStyle(NativePalette.pair(0x10110f, 0xe0e5da, alpha: 0.58).swiftUI)
            Text("00:06:02 | 110.4K").font(NativeTypography.mono(size: 11 * scale))
                .foregroundStyle(NativePalette.overview.muted.swiftUI)
            Text(excerpt).font(NativeTypography.inter(size: 11.5 * scale))
                .lineSpacing(3 * scale)
                .foregroundStyle(NativePalette.pair(0x10110f, 0xe0e5da, alpha: 0.56).swiftUI)
                .padding(.top, 5 * scale)
        }.padding(18 * scale).frame(width: 360 * scale, height: 200 * scale, alignment: .topLeading)
    }
}

private struct Surface: View {
    let fixture: Fixture
    @Environment(\.displayScale) private var displayScale
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(red: 0.12, green: 0.12, blue: 0.13)
            NativeReadingPageStack(open: false, identity: "text", motion: fixture.reading,
                                   focusBlur: true, stationaryParent: true, onClose: {}) {
            NativeOverviewCanvas(items: [.init(id: "text")], sceneKey: "text", state: fixture.state, selectionID: "all") { _ in
                HarnessThreadCard(identity: .init(title: title, model: "xai/grok-4.7", effort: "高",
                                  runtime: .init(startedAt: 0, endedAt: 362000), excerpt: excerpt),
                                  presentation: fixture.presentation, emoji: "🔎")
                    .modifier(ResolutionControl(reference: fixture.reference))
                    .environment(\.displayScale, fixture.boost ? displayScale * fixture.scale * fixture.windowScale : displayScale)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("capture")) } action: { fixture.frame = $0 }
                    .onAppear { fixture.ready = true }
            }
            } front: { Color.clear }
            .environment(\.nativeWindowContentScale, fixture.windowScale)
            .frame(width: 1000 / fixture.windowScale, height: 470 / fixture.windowScale)
            .scaleEffect(fixture.windowScale, anchor: .topLeading)
            // Same final font size and layout, isolating transform from font rasterization.
            Group {
                if fixture.useGlassContainer {
                    GlassEffectContainer(spacing: 0) { probe }
                } else { probe }
            }
            .offset(x: 80, y: 485)
        }.coordinateSpace(name: "capture").preferredColorScheme(.dark)
    }
    private var probe: some View {
        Group {
            switch fixture.method {
            case "supersample":
                Probe(scale: 2).scaleEffect(fixture.scale / 2, anchor: .topLeading)
            case "renderer":
                Probe(scale: 1).textRenderer(VectorText()).scaleEffect(fixture.scale, anchor: .topLeading)
            case "affine":
                Probe(scale: 1).transformEffect(CGAffineTransform(scaleX: fixture.scale, y: fixture.scale))
            case "drawing":
                Probe(scale: 1).drawingGroup().scaleEffect(fixture.scale, anchor: .topLeading)
            case "geometry":
                Probe(scale: 1).geometryGroup().scaleEffect(fixture.scale, anchor: .topLeading)
            default:
                Probe(scale: fixture.direct ? fixture.scale : 1)
                    .scaleEffect(fixture.direct ? 1 : fixture.scale, anchor: .topLeading)
            }
        }.environment(\.displayScale, fixture.boost ? displayScale * fixture.scale : displayScale)
    }
}

private struct Failure: Error { let description: String }

@MainActor private func run() async throws {
    let directory = URL(fileURLWithPath: Bundle.main.object(forInfoDictionaryKey: "OutputDirectory") as! String)
    let fixture = Fixture()
    let window = NSWindow(contentRect: .init(x: 100, y: 100, width: 1000, height: 850),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: Surface(fixture: fixture))
    window.level = .floating; window.makeKeyAndOrderFront(nil); NSApp.activate()
    defer { fixture.state.camera.dispose(); window.close() }
    for _ in 0..<500 {
        if fixture.ready && !fixture.state.isLayingOut { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    guard fixture.ready && !fixture.state.isLayingOut else { throw Failure(description: "Canvas not ready") }
    let content = try await SCShareableContent.currentProcess
    guard let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
        throw Failure(description: "Own window unavailable")
    }
    let filter = SCContentFilter(desktopIndependentWindow: target)
    let backingScale = window.backingScaleFactor
    let config = SCStreamConfiguration()
    config.width = Int(1000 * backingScale); config.height = Int(850 * backingScale)
    config.ignoreShadowsSingleWindow = true; config.showsCursor = false
    config.colorSpaceName = CGColorSpace.sRGB
    var results: [[String: Any]] = []
    let cases: [(String, CGFloat, CGFloat, Bool, Bool, Bool)] = [
        ("100", 1, 1, false, false, true),
        ("100-reference", 1, 1, false, false, true),
        ("125-reference", 1.25, 1, false, false, true),
        ("170-reference", 1.7, 1, false, false, true),
        ("125-window-reference", 1, 1.25, false, false, true),
        ("125-supersample", 1.25, 1, false, false, true),
        ("170-supersample", 1.7, 1, false, false, true),
        ("125-renderer", 1.25, 1, false, false, true),
        ("125-affine", 1.25, 1, false, false, true),
        ("125-drawing", 1.25, 1, false, false, true),
        ("125-drawing-boost", 1.25, 1, true, false, true),
        ("125-geometry", 1.25, 1, false, false, true),
        ("125-transform", 1.25, 1, false, false, true),
        ("125-direct-font", 1.25, 1, false, true, true),
        ("125-display-scale", 1.25, 1, true, false, true),
        ("125-no-container", 1.25, 1, false, false, false),
        ("125-window", 1, 1.25, false, false, true),
        ("170-transform", 1.7, 1, false, false, true),
        ("170-direct-font", 1.7, 1, false, true, true),
    ]
    for (name, scale, windowScale, boost, direct, glass) in cases {
        fixture.reference = name.contains("reference")
        fixture.method = name.contains("supersample") ? "supersample" : name.contains("renderer") ? "renderer" : name.contains("affine") ? "affine" : name.contains("drawing") ? "drawing" : name.contains("geometry") ? "geometry" : "scale"
        fixture.scale = scale; fixture.windowScale = windowScale; fixture.boost = boost
        fixture.direct = direct; fixture.useGlassContainer = glass
        try await Task.sleep(for: .milliseconds(250))
        fixture.state.camera.setManualTransform(.init(scale: scale, x: 80 / windowScale, y: 100 / windowScale))
        try await Task.sleep(for: .milliseconds(650))
        let actual = fixture.state.camera.liveTransform
        guard abs(actual.scale - scale) < 0.001 else { throw Failure(description: "Unexpected camera scale: \(actual.scale)") }
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        guard image.width == config.width && image.height == config.height else { throw Failure(description: "Capture size mismatch") }
        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
            .write(to: directory.appendingPathComponent(name + ".png"))
        results.append(["name": name, "cameraScale": actual.scale, "windowScale": windowScale,
                        "backingScale": backingScale, "reference": fixture.reference, "displayScaleBoost": boost,
                        "cardFrame": NSStringFromRect(fixture.frame), "pixels": [image.width, image.height]])
    }
    try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
        .write(to: directory.appendingPathComponent("captures.json"))
}

@MainActor private final class Delegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do { try await run(); print("PASS overview text capture"); exit(0) }
            catch { print("FAIL \(error)"); exit(1) }
        }
    }
}

@main private enum Main {
    static func main() {
        let delegate = Delegate(), app = NSApplication.shared
        app.setActivationPolicy(.accessory); app.delegate = delegate; app.run()
    }
}
