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
    let reading = NativeReadingPageMotion()
    var items: [NativeOverviewItem] = [.init(id: "first")]
    var scene = "replay"
    var selection: String? = "all"
    var detail = false
    var dark = false
    var query = String(repeating: "A long draft with a final visible line.\n", count: 24) + "FINAL LINE"
    var focus = 1
    var searches = false
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

    func clickNavigationBack() throws {
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "replay" }),
              let content = window.contentView else { throw Failure(message: "Replay window is missing") }
        // Click the visible chevron through AppKit's normal event dispatch,
        // including titlebar hit testing; invoking its action misses overlays.
        let top = NativeWindowNavigationGeometry.top + NativeWindowNavigationGeometry.height / 2
        let point = content.convert(CGPoint(x: NativeWindowNavigationGeometry.left + 104,
            y: content.isFlipped ? top : content.bounds.height - top), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else {
                throw Failure(message: "Could not create navigation click")
            }
            window.sendEvent(event)
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
    func verifyCardTransitions() async throws {
        try await wait("settled before filter") { !state.isLayingOut }
        let retained = frames["second"]!
        items = [.init(id: "second"), .init(id: "third")]
        scene = "transition-filter"; selection = "filtered"
        try await wait("filter entry") { state.isLayingOut && frames["third"] != nil }
        let camera = state.camera.liveTransform
        let placement = state.presentedPlacements.first { $0.id == "third" }!
        let target = placement.cardFrame
        try check(abs(frames["third"]!.width - target.width * camera.scale * 0.94) < 1,
                  "Filter entry lost its initial .94 scale")
        try check(abs(frames["third"]!.midY - (camera.y + target.midY * camera.scale + 12)) < 1,
                  "Filter entry lost its screen-space 12pt offset: frame=\(frames["third"]!), target=\(target), camera=\(camera)")
        try check(abs(frames["second"]!.minX - retained.minX) < 1,
                  "Filter survivor jumped at filter entry")
        try await Task.sleep(for: .milliseconds(95))
        let interrupted = frames["second"]!
        let sampledAt = frameTimes["second"]!
        let survivorTarget = state.presentedPlacements.first { $0.id == "second" }!.cardFrame
        let travel = abs(camera.x + survivorTarget.minX * camera.scale - retained.minX)
        items = [.init(id: "first"), .init(id: "second")]
        scene = "replay"; selection = "all"
        try await wait("filter reversal") { state.presentedPlacements.contains { $0.id == "first" } }
        let elapsed = (frameTimes["second"] ?? sampledAt) - sampledAt + 1.0 / 60
        try check(abs(frames["second"]!.minX - interrupted.minX) <= travel / 0.32 / 0.22 * elapsed + 2,
                  "Filter reversal snapped to a destination")
        try await wait("filter complete") { !state.isLayingOut && state.mountedCardIDs == ["first", "second"] }
        try await Task.sleep(for: .milliseconds(750))
        try check(abs(frames["second"]!.minX - retained.minX) < 1 && abs(frames["second"]!.minY - retained.minY) < 1,
                  "Compact filter reversal moved the shared visible card")
        try check(state.camera.liveTransform == camera, "Delayed refit moved the retained filter view")
        try check(appearances["second"] == 1, "Filter transition replaced survivor content")
        state.camera.setManualTransform(.init(scale: state.camera.minimumScale, x: 80, y: 120))
        try await wait("restored manual camera") { abs((frames["first"]?.minX ?? 0) - 80) < 1 }
    }

    func verifySearchCameraRestoration() async throws {
        let browsingItems = items, browsingScene = scene, browsingSelection = selection
        let initial = state.camera.liveTransform
        for results in [[browsingItems[0]], []] {
            // Keep every browse card offscreen so a nonempty query has to fit
            // its result. Otherwise both scenes retain the same manual camera
            // and a missing bookmark restoration is invisible to this replay.
            state.camera.setManualTransform(.init(scale: state.camera.minimumScale, x: -10_000, y: -10_000))
            guard let bookmark = state.camera.live else { throw Failure(message: "Browse camera is missing") }
            items = results; scene = browsingScene + "\u{0}search:camera-replay"; selection = nil
            let resultIDs = Set(results.map(\.id))
            try await wait("search result framing") {
                !state.isLayingOut && Set(state.presentedPlacements.map(\.id)) == resultIDs
            }
            try check(!state.camera.manual, "Search fixture did not enter automatic result framing")
            // This is the model-to-canvas restoration contract. The real canvas
            // must consume it on both a visible-survivor return and empty reentry.
            state.pendingSearchCameraRestoration = (browsingScene, bookmark)
            items = browsingItems; scene = browsingScene; selection = browsingSelection
            try await wait("browse return after search") {
                !state.isLayingOut && Set(state.presentedPlacements.map(\.id)) == Set(browsingItems.map(\.id))
            }
            try check(state.pendingSearchCameraRestoration == nil,
                      "Search return left the browse camera bookmark unconsumed")
            try check(state.camera.manual && state.camera.liveTransform == bookmark.transform,
                      "Search return lost the saved manual browse camera")
            try await Task.sleep(for: .milliseconds(750))
            try check(state.camera.manual && state.camera.liveTransform == bookmark.transform,
                      "Delayed search refit replaced the restored manual camera")
        }
        state.camera.setManualTransform(initial)
        try await wait("manual camera after search replay") { abs((frames["first"]?.minX ?? 0) - 80) < 1 }
    }

    func run() async {
        do {
            try await wait("initial card and viewport") {
                guard appearances["first"] == 1, let frame = frames["first"], state.camera.isInitialized,
                      !state.isLayingOut, viewport.width > 0 else { return false }
                let fit = NativeOverviewCameraGeometry.fit(.init(left: 0, top: 0, width: 360, height: 200),
                    viewport: .init(width: viewport.width, height: viewport.height, toolbarBottom: 58))
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
            let expected = NativeOverviewCameraGeometry.fit(.init(left: 0, top: 0, width: 360, height: 200),
                viewport: .init(width: viewport.width, height: viewport.height, toolbarBottom: 58))
            try check(abs(frames["first"]!.minX - expected.x) < 1, "First card not centered: frame=\(frames["first"]!), expected=\(expected), viewport=\(viewport), camera=\(state.camera.liveTransform)")
            guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "replay" }) else {
                throw Failure(message: "Gesture replay window is missing")
            }
            try await verifyOverviewGestures(state: state, window: window)
            try await wait("automatic framing after gestures") { !state.camera.manual && !state.camera.isAnimating }
            let manualScale = state.camera.minimumScale
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
            try await verifySearchCameraRestoration()
            let firstAppearances = appearances["first"]
            detail = true
            try await Task.sleep(for: .milliseconds(400))
            try verifyWindowChrome()
            try await verifyWindowResize()
            try clickNavigationBack()
            try await wait("reading return") { !detail }
            try check(appearances["first"] == firstAppearances && state.camera.manual, "Reading return lost overview state")
            for _ in 0..<2 {
                detail = true
                try await Task.sleep(for: .milliseconds(400))
                try clickNavigationBack()
                try await wait("repeated reading return") { !detail }
                try check(appearances["first"] == firstAppearances && state.camera.manual, "Repeated return lost overview state")
            }
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
        NativeReadingPageStack(open: replay.detail, identity: "detail", motion: replay.reading,
            focusBlur: true, stationaryParent: true, emphasizedOpening: true,
            onClose: { replay.detail = false }) {
            NativeOverviewCanvas(items: replay.items, sceneKey: replay.scene, state: replay.state,
                selectionID: replay.selection, visible: !replay.detail) { item in
                VStack {
                    Text("Conversation \(item.id)").font(.title2)
                    Button("Open conversation") { replay.detail = true }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background { NativeCloudLoading(palette: .blueIndigo, isAnimating: !replay.detail) }
                .overlay(alignment: .topTrailing) {
                    ThreadCardProviderStatus(label: "Completed conversation", brandKey: "codex", emoji: "📏",
                                             terminal: .completed, onFollowUp: { replay.detail = true })
                        .padding(.top, 12).padding(.trailing, 17)
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("replay-canvas")) } action: { replay.frames[item.id] = $0; replay.frameTimes[item.id] = ProcessInfo.processInfo.systemUptime }
                .onAppear { replay.appearances[item.id, default: 0] += 1 }
            }.coordinateSpace(name: "replay-canvas")
        } front: {
            VStack {
                Text("Conversation detail")
                NativeComposerTextInput(value: Binding(get: { replay.query }, set: { replay.query = $0 }), placeholder: "Draft",
                    automaticFocus: false, minHeight: 54, maxHeight: 180, onSubmit: {})
                    .frame(width: 480)
                Button("Back") { replay.reading.close() }
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(.background)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { replay.viewport = $0 }
        .overlay(alignment: .topLeading) {
            NativeWindowNavigationView(action: replay.detail ? .init(label: "Back to overview", onBack: { replay.reading.close() }) : nil)
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
