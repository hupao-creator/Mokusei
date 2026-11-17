// Isolated SwiftUI scene replay. No runtime, user preferences, or global input.
import Foundation
import AppKit // Test-only inspection of the real SwiftUI-created window.
import Darwin
import Observation
import SwiftUI
import MokuseiPluginUI
@testable import MokuseiUI

@MainActor @Observable private final class Replay {
    let state = NativeOverviewCanvasState()
    var items: [NativeOverviewItem] = [.init(id: "first")]
    var scene = "replay"
    var selection: String? = "all"
    var dark = false
    @ObservationIgnored var frames: [String: CGRect] = [:]
    @ObservationIgnored var frameTimes: [String: TimeInterval] = [:]
    @ObservationIgnored var appearances: [String: Int] = [:]
    var viewport = CGSize.zero
    func verifyWindowChrome() throws {
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "replay" }),
              let content = window.contentView else { throw Failure(message: "Replay window is missing") }
        try check(window.titleVisibility == .hidden, "Window title is visible")
        try check(window.backgroundColor?.alphaComponent == 0, "Window has an opaque background behind its material")
        try check(abs(viewport.height - content.bounds.height) < 1, "A header or blank strip consumes content height")
        let capsule = CGRect(x: NativeWindowNavigationGeometry.left, y: NativeWindowNavigationGeometry.top,
            width: NativeWindowNavigationGeometry.openWidth, height: NativeWindowNavigationGeometry.height)
        for (index, type) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            guard let button = window.standardWindowButton(type) else { throw Failure(message: "Missing system window control") }
            var rect = button.convert(button.bounds, to: content)
            if !content.isFlipped { rect.origin.y = content.bounds.height - rect.maxY }
            // These are the historical coordinates, not system-default placement.
            try check(abs(rect.minX - CGFloat(24 + 20 * index)) < 0.5 && abs(rect.minY - 31) < 0.5,
                "System control moved from its historical position: \(rect)")
            try check(capsule.contains(rect), "System control is outside the navigation capsule: \(rect)")
            try check(button.isEnabled && !button.isHidden && button.action != nil,
                "Positioned system control lost its native action")
        }
    }

    func verifyWindowResize() async throws {
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "replay" }) else {
            throw Failure(message: "Replay window is missing")
        }
        let original = window.frame
        let available = window.screen?.visibleFrame ?? original
        for requested in [CGSize(width: 850, height: 620), CGSize(width: 1300, height: 860), original.size] {
            // AppKit constrains windows to the screen's usable height (858 pt
            // on some laptop setups). Request attainable sizes, then still
            // require the actual SwiftUI viewport to match them exactly.
            let size = CGSize(width: min(requested.width, available.width), height: min(requested.height, available.height))
            let origin = CGPoint(x: min(max(original.minX, available.minX), available.maxX - size.width),
                                 y: min(max(original.minY, available.minY), available.maxY - size.height))
            window.setFrame(CGRect(origin: origin, size: size), display: true)
            try await wait("resized viewport") { abs(viewport.width - size.width) < 1 && abs(viewport.height - size.height) < 1 }
            // AppKit may restore its default button frames during the resize;
            // wait for the coalesced placement bridge before asserting geometry.
            try await wait("resized window chrome") {
                do { try verifyWindowChrome(); return true } catch { return false }
            }
            try verifyWindowChrome()
        }
    }

    func wait(_ description: String, _ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw Failure(message: "Timed out: \(description); viewport=\(viewport), layout=\(state.presentedPlacements.map(\.id)), frames=\(frames), appearances=\(appearances), error=\(state.layoutError ?? "none")")
    }
    func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }
    private var resultURL: URL { URL(fileURLWithPath: Bundle.main.object(forInfoDictionaryKey: "MokuseiReplayResult") as? String ?? "/tmp/mokusei-overview-swiftui-replay-result.txt") }
    func verifyFitAll() throws {
        let usable = NativeOverviewCameraGeometry.framingRegion(
            .init(width: viewport.width, height: viewport.height, toolbarBottom: NativeOverviewViewportDefaults.toolbarBottom))
        let placements = state.presentedPlacements
        guard !placements.isEmpty else { return }
        let world = placements.map(\.cardFrame).reduce(CGRect.null) { $0.union($1) }
        let raw = min(usable.width / world.width, usable.height / world.height)
        let expected = min(NativeOverviewCameraGeometry.scaleCap, raw)
        let transform = state.camera.liveTransform
        try check(abs(transform.scale - expected) < 1e-6,
                  "Camera is not FitAll: scale=\(transform.scale) expected=\(expected)")
        let screen = placements.map { placement -> CGRect in
            let frame = placement.cardFrame
            return CGRect(x: transform.x + frame.minX * transform.scale,
                          y: transform.y + frame.minY * transform.scale,
                          width: frame.width * transform.scale,
                          height: frame.height * transform.scale)
        }.reduce(CGRect.null) { $0.union($1) }
        try check(abs(screen.midX - (usable.left + usable.width / 2)) < 1
                  && abs(screen.midY - (usable.top + usable.height / 2)) < 1,
                  "Rendered collection is not centered: \(screen), usable=\(usable)")
    }

    func settleCameraAndLayout() async throws {
        try await wait("camera and layout settled") {
            !state.isLayingOut && !state.camera.isAnimating && !state.camera.hasPendingAutomaticFit
        }
    }

    func verifyCardTransitions() async throws {
        try await wait("settled before filter") { !state.isLayingOut }
        let survivorAppearances = appearances["second"]
        items = [.init(id: "second"), .init(id: "third")]
        scene = "transition-filter"; selection = "filtered"
        try await wait("filter complete") { !state.isLayingOut && state.mountedCardIDs == ["second", "third"] }
        try await settleCameraAndLayout()
        try verifyFitAll()
        items = [.init(id: "first"), .init(id: "second")]
        scene = "replay"; selection = "all"
        try await wait("filter reversal complete") { !state.isLayingOut && state.mountedCardIDs == ["first", "second"] }
        try await settleCameraAndLayout()
        try verifyFitAll()
        try check(appearances["second"] == survivorAppearances, "Filter transition replaced survivor content")
        state.camera.setManualTransform(.init(scale: 0.9, x: 80, y: 120))
        try await wait("restored manual camera") { abs((frames["first"]?.minX ?? 0) - 80) < 1 }
        state.camera.returnToAuto()
        try await settleCameraAndLayout()
        try verifyFitAll()
    }


    func run() async {
        do {
            try await wait("initial card and viewport") {
                guard appearances["first"] == 1, let frame = frames["first"], state.camera.isInitialized,
                      !state.isLayingOut, viewport.width > 0 else { return false }
                guard let fit = NativeOverviewCameraGeometry.fit(.init(left: 0, top: 0, width: NativeOverviewLayout.columnWidth, height: NativeOverviewLayout.rowHeight),
                    viewport: .init(width: viewport.width, height: viewport.height, toolbarBottom: NativeOverviewViewportDefaults.toolbarBottom)) else { return false }
                return abs(frame.minX - fit.x) < 1
            }
            // Placement is coalesced onto the next main-queue turn. A background
            // CU launch can expose card geometry before that window work runs.
            NSApp.setActivationPolicy(.regular)
            NSApp.unhide(nil)
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first(where: { $0.identifier?.rawValue == "replay" })?.makeKeyAndOrderFront(nil)
            try await wait("initial window chrome") {
                do { try verifyWindowChrome(); return true } catch { return false }
            }
            try verifyWindowChrome()
            guard let expected = NativeOverviewCameraGeometry.fit(.init(left: 0, top: 0, width: NativeOverviewLayout.columnWidth, height: NativeOverviewLayout.rowHeight),
                viewport: .init(width: viewport.width, height: viewport.height, toolbarBottom: NativeOverviewViewportDefaults.toolbarBottom)) else {
                throw Failure(message: "Initial FitAll camera is unavailable")
            }
            try check(abs(frames["first"]!.minX - expected.x) < 1, "First card not centered: frame=\(frames["first"]!), expected=\(expected), viewport=\(viewport), camera=\(state.camera.liveTransform)")
            guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "replay" }) else {
                throw Failure(message: "Gesture replay window is missing")
            }
            try await verifyOverviewGestures(state: state, window: window)
            try await wait("automatic framing after gestures") { !state.camera.manual && !state.camera.isAnimating }
            let manualScale = 0.9
            state.camera.setManualTransform(.init(scale: manualScale, x: 80, y: 120))
            try await wait("manual camera") { abs((frames["first"]?.minX ?? 0) - 80) < 1 }
            items.append(.init(id: "second")); scene = "members:first,second"
            try await wait("membership") { !state.isLayingOut && state.presentedPlacements.count == 2 && frames["second"] != nil }
            try check(state.camera.manual && appearances["first"] == 1, "Membership replaced camera or card identity")
            items[0].columns = 2
            try await wait("card grows") { abs((frames["first"]?.width ?? 0) - 736 * manualScale) < 1 }
            items[0].columns = 1
            try await wait("card shrinks") { abs((frames["first"]?.width ?? 0) - 360 * manualScale) < 1 }
            try await verifyCardTransitions()
            let firstAppearances = appearances["first"]
            try await verifyWindowResize()
            state.camera.returnToAuto()
            try await wait("automatic framing") { !state.camera.manual && !state.camera.returning && !state.camera.isAnimating }
            try verifyWindowChrome()
            dark = true
            try await Task.sleep(for: .milliseconds(100))
            try check(appearances["first"] == firstAppearances, "Theme replaced card content")
            items = []; scene = "empty"; selection = nil
            try await wait("empty") { !state.isLayingOut && state.presentedPlacements.isEmpty }
            try check(state.memory.current == nil, "Empty overview retained camera memory")
            items = [.init(id: "new")]
            try await wait("reentry") { !state.isLayingOut && abs((frames["new"]?.minX ?? -1000) - expected.x) < 1 }
            try check(abs(frames["new"]!.minX - expected.x) < 1, "Reentry not centered")
            try Data("PASS Overview SwiftUI replay completed\n".utf8).write(to: resultURL)
            print("PASS Overview SwiftUI replay completed")
            exit(0)
        } catch {
            let message = "FAIL \(error)\n"
            try? Data(message.utf8).write(to: resultURL)
            FileHandle.standardError.write(Data(message.utf8)); exit(1)
        }
    }
    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }
}

private struct ReplaySurface: View {
    let replay: Replay
    var body: some View {
        NativeOverviewCanvas(items: replay.items, sceneKey: replay.scene, state: replay.state,
            selectionID: replay.selection, visible: true) { item in
            Text("Conversation \(item.id)").font(.title2)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { NativeCloudLoading(palette: .blueIndigo, isAnimating: true) }
            .overlay(alignment: .topTrailing) {
                ThreadCardProviderStatus(label: "Completed conversation", brandKey: "codex", emoji: "📏",
                                         terminal: .completed)
                    .padding(.top, 12).padding(.trailing, 17)
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("replay-canvas")) } action: { replay.frames[item.id] = $0; replay.frameTimes[item.id] = ProcessInfo.processInfo.systemUptime }
            .onAppear { replay.appearances[item.id, default: 0] += 1 }
        }.coordinateSpace(name: "replay-canvas")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { replay.viewport = $0 }
        .overlay(alignment: .topLeading) {
            NativeWindowNavigationView(action: nil)
        }
        .modifier(NativeWorkspaceWindowSurface())
        .coordinateSpace(name: "replay")
        .preferredColorScheme(replay.dark ? .dark : .light)
        .task { if !CommandLine.arguments.contains("--interactive") && Bundle.main.object(forInfoDictionaryKey: "MokuseiReplayInteractive") as? Bool != true { await replay.run() } }
    }
}

@main @MainActor private struct OverviewReplayApp: App {
    init() { prepareReplayEnvironment() }
    @State private var replay = Replay()
    var body: some Scene {
        Window("Overview SwiftUI Replay", id: "replay") {
            ReplaySurface(replay: replay)
        }.nativeWorkspaceWindowStyle().defaultLaunchBehavior(.presented).defaultSize(width: 1100, height: 700)
        .commands {
            CommandMenu("Replay") {
                Button("Toggle appearance") { replay.dark.toggle() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
            }
        }
    }
}
