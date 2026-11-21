import AppKit
import ScreenCaptureKit
import SwiftUI
import ChiefCore
import ChiefHarnessCodex
import ChiefPluginAPI
@testable import ChiefPluginUI
@testable import ChiefUI

private struct ReplayError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

// Deliver a window-local wheel sample directly to the mounted event monitor.
private final class WheelSample: NSEvent {
    let target: NSWindow
    let point: CGPoint
    init(window: NSWindow, point: CGPoint) {
        target = window
        self.point = point
        super.init()
    }
    required init?(coder: NSCoder) { nil }
    override var window: NSWindow? { target }
    override var locationInWindow: CGPoint { point }
    override var type: NSEvent.EventType { .scrollWheel }
    override var hasPreciseScrollingDeltas: Bool { true }
    override var scrollingDeltaX: CGFloat { 0 }
    override var scrollingDeltaY: CGFloat { 12 }
    override var phase: NSEvent.Phase { .began }
    override var momentumPhase: NSEvent.Phase { [] }
    override var modifierFlags: NSEvent.ModifierFlags { [] }
    override var timestamp: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

@main @MainActor private struct NestedHeaderReplay: App {
    @State private var zoom = 5.0
    private let workspace: NativeWorkspaceModel
    private let presentation: NativeWorkspacePresentation

    init() {
        do {
            try prepareIsolatedNativeReplay()
            let directory = URL(filePath: FileManager.default.currentDirectoryPath)
            let preferences = DesktopPreferences(directory: directory)
            try preferences.setOnboardingCompleted(true)
            workspace = NativeWorkspaceModel(client: RuntimeClient(profile: try RuntimeProfile(dataDirectory: directory)),
                preferences: preferences, plugins: try .init(harnesses: [AnyHarnessPlugin(CodexHarnessPlugin())], sidecards: [], applications: []))
            presentation = NativeWorkspacePresentation(workspace: workspace)
        } catch { fatalError(String(describing: error)) }
    }

    var body: some Scene {
        Window("Overview header replay", id: "header-replay") {
            GeometryReader { geometry in
                NativeWorkspaceView(model: workspace, presentation: presentation)
                    .frame(width: geometry.size.width / zoom, height: geometry.size.height / zoom)
                    .environment(\.nativeWindowContentScale, zoom)
                    .scaleEffect(zoom, anchor: .topLeading)
            }
            .modifier(NativeWorkspaceWindowSurface())
            .task {
                do { try await replay(); exit(0) }
                catch { print(error); exit(1) }
            }
        }
        .nativeWorkspaceWindowStyle().defaultSize(width: 860, height: 640)
        .restorationBehavior(.disabled)
    }

    private func replay() async throws {
        let threads = try ["task", "moku"].map { id in
            try HarnessThread(id: JSONText(id), harnessID: "codex", revision: 0, sessionState: .null,
                observation: .init(), cwd: "/fixture", settings: .object([:]), createdAt: 1, updatedAt: 2,
                title: JSONText(id), tags: [], moku: id == "moku" ? true : nil, transcript: id == "moku" ? .array([]) : nil,
                directoryTag: "Fixture", directoryScope: "/fixture").json
        }
        let snapshot: JSONValue = .object(["revision": .integer(1), "settingsRevision": .integer(0),
            "defaultCwd": .text("/fixture"), "settings": .object([:]), "threads": .array(threads),
            "executions": .array([]), "applicationThreads": .array([])])
        await workspace.installPrepared(snapshot, event: .snapshot(snapshot, authority: UUID()))
        guard workspace.hasInitialContent, let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "header-replay" }),
              let screen = NSScreen.screens.first else { throw ReplayError("Workspace did not mount") }
        NSApp.setActivationPolicy(.accessory)
        window.collectionBehavior = [.auxiliary, .canJoinAllSpaces]
        window.orderFrontRegardless()

        let directory = URL(filePath: FileManager.default.currentDirectoryPath).appending(path: "evidence")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var records: [[String: Any]] = []
        // Filter tops are logical points. Settings probes use actual-size window points.
        let cases: [(size: CGSize, scale: CGFloat, filterTop: CGFloat, settingsProbe: CGPoint?, captureName: String?)] = [
            (CGSize(width: 860, height: 640), 5, 76, nil, "maximum"),
            (CGSize(width: 1100, height: 760), 1, 16, CGPoint(x: 1061, y: 22), "wide"),
            (CGSize(width: 600, height: 480), 1, 76, CGPoint(x: 565, y: 16), "narrow"),
            (CGSize(width: 1100, height: 760), 1.44, 16, nil, "menu"),
            (CGSize(width: 860, height: 640), 2.5, 76, nil, nil),
            (CGSize(width: 860, height: 640), 5, 76, nil, nil),
            (CGSize(width: 860, height: 600), 5, 68, nil, nil),
        ]
        for (size, scale, filterTop, settingsProbe, captureName) in cases {
            zoom = scale
            window.setContentSize(size)
            window.setFrameTopLeftPoint(CGPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.midY + size.height / 2))
            try await Task.sleep(for: .seconds(2))
            var result = try inspect(window, scale: scale, filterTop: filterTop)
            if CommandLine.arguments.contains("--capture"), let captureName {
                try await capture(window, to: directory.appending(path: captureName + ".png"))
            }
            if let settingsProbe {
                let opened = try await clickSettings(window, at: settingsProbe)
                result["settingsProbeFromTopLeft"] = [settingsProbe.x, settingsProbe.y]
                result["settingsOpened"] = opened
                result["passed"] = opened && result["passed"] as? Bool == true
            }
            records.append(result)
            if result["passed"] as? Bool != true { print("Failed geometry: \(result)") }
        }
        try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appending(path: "nested-header.json"))
        guard records.allSatisfy({ $0["passed"] as? Bool == true }) else { throw ReplayError("Nested header replay failed") }
    }

    private func capture(_ window: NSWindow, to url: URL) async throws {
        let ownWindows = try await SCShareableContent.currentProcess
        guard let target = ownWindows.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            throw ReplayError("Cannot capture replay window")
        }
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width * 2)
        config.height = Int(window.frame.height * 2)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.ignoreGlobalClipSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: config)
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw ReplayError("Cannot encode replay window")
        }
        try png.write(to: url)
    }

    private func descendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for child in view.subviews { if let match = descendant(type, in: child) { return match } }
        return nil
    }

    private func clickSettings(_ window: NSWindow, at point: CGPoint) async throws -> Bool {
        let location = CGPoint(x: point.x, y: window.frame.height - point.y)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else {
                throw ReplayError("Cannot create the window-local Settings click")
            }
            window.sendEvent(event)
        }
        try await Task.sleep(for: .milliseconds(400))
        let opened = presentation.scene.settingsOpen
        if opened { presentation.scene.closeSettings() }
        return opened
    }

    private func inspect(_ window: NSWindow, scale: CGFloat, filterTop: CGFloat) throws -> [String: Any] {
        guard let content = window.contentView, let frame = content.superview,
              let host = descendant(NativeReadingParentView.self, in: content),
              let monitor = descendant(NativeOverviewScrollInput.MonitorView.self, in: host),
              let filter = descendant(NSScrollView.self, in: host), let input = monitor.input else {
            throw ReplayError("Missing nested Overview, its directory scroller or its input monitor")
        }
        let size = monitor.configuration.size
        let filterFrame = filter.convert(filter.bounds, to: nil)
        let boundary = monitor.configuration.toolbarBottom
        let below = CGPoint(x: size.width - 8, y: size.height - 4)
        let above = CGPoint(x: below.x, y: boundary - 1)
        let camera = presentation.overview.canvasState.camera
        let rejectsHeader = !monitor.canStart(at: above)
        let wheel = WheelSample(window: window, point: monitor.windowPoint(below))
        let before = camera.liveTransform
        let scrolled = monitor.handle(wheel) == nil && camera.manual && camera.liveTransform.y != before.y
        camera.returnToAuto()
        input.pinch(magnification: 1.1, anchor: below, camera: camera)
        let pinched = camera.manual
        input.endPinch()
        camera.returnToAuto()

        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap(window.standardWindowButton)
        let rects = buttons.map { $0.convert($0.bounds, to: nil) }
        let hits = zip(buttons, rects).allSatisfy { button, rect in
            [-6.5, 0, 6.5].allSatisfy { dy in
                let point = CGPoint(x: rect.midX, y: rect.midY + dy)
                return frame.hitTest(frame.superview?.convert(point, from: nil) ?? point) === button
            }
        }
        let buttonCenters = rects.map { CGPoint(x: $0.midX, y: window.frame.height - $0.midY) }
        let positioned = zip(buttonCenters, [31.0, 51.0, 71.0]).allSatisfy { center, x in
            abs(center.x - x) <= 0.5 && abs(center.y - 38) <= 0.5
        }
        let renderedFilterTop = window.frame.height - filterFrame.maxY
        let filterPositioned = abs(renderedFilterTop - filterTop * scale) <= 0.5
        let filterBottom = window.frame.height - filterFrame.minY
        let filterInside = filterFrame.minY >= 0 && filterFrame.maxY <= window.frame.height
        let filterExcluded = filterBottom <= boundary * scale
        let strip = size.height - boundary
        let inputPoint = monitor.windowPoint(below)
        let pointInside = CGRect(origin: .zero, size: window.frame.size).contains(inputPoint)
        return ["windowSize": [window.frame.width, window.frame.height], "scale": scale,
                "logicalViewport": [size.width, size.height], "filterTopInWindow": renderedFilterTop,
                "expectedFilterTopInWindow": filterTop * scale, "filterBottomInWindow": filterBottom,
                "buttonCentersFromTopLeft": buttonCenters.map { [$0.x, $0.y] }, "buttonHits": hits,
                "headerInputBottom": boundary, "canvasStripHeight": strip, "inputPointInWindow": [inputPoint.x, inputPoint.y],
                "rejectsHeader": rejectsHeader, "wheelPanned": scrolled, "pinchEnteredManual": pinched,
                "passed": buttons.count == 3 && hits && positioned && filterPositioned && filterInside && filterExcluded
                    && strip >= 8 && pointInside && rejectsHeader && scrolled && pinched]
    }
}
