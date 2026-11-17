import AppKit
import Observation
import SwiftUI
import Testing
import WebKit
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
@testable import MokuseiApplications

@MainActor @Observable private final class CoverReplay {
    var playback = NativeReportCoverPlayback.reset
    var replayID = 0
    var initiallyFinished = false
    var redraw = false
    var active = true
    var dark = false
    var identity = UUID()
    var ready = 0
    var panelRevision = "first"
    var panelVisible = true
    var selections: [ApplicationThreadRef] = []
    let visibility = ThreadCardAnimationVisibility()
    let cache = NativeReportCoverCache()

    static func props(_ id: String, revision: String? = nil, duration: Double = 2, delay: Double = 0,
                      loadDelay: Duration = .zero, infinite: Bool = false, fails: Bool = false) throws -> ApplicationThreadProps<NativeReportView> {
        let revision = revision ?? id
        let ref = ApplicationThreadRef(threadID: JSONText(id), typeID: "report.document")
        let view = try NativeReportView(json: .object([
            "coverRevision": .text(revision), "contentRevision": .text(revision), "emoji": .text("📖"),
            "shortDescription": .text("Animated cover fixture"), "previewText": .text("Animated cover fixture"),
            "relatedExecutions": .array([])
        ]))
        let capabilities = try ApplicationCapabilityAccess<ApplicationRendererPhase>(scope: .init(pluginID: "report", thread: ref),
            requires: [ApplicationCapabilities.executionReferencesUI.requirement], registrations: [
                .init(ApplicationCapabilities.executionReferencesUI, value: .init(read: { _ in [] }, subscribe: { _, _ in {} },
                    logo: { _, _ in AnyView(EmptyView()) }, execution: { _ in throw PluginContractError("No fixture execution") }))
            ])
        let html = """
        <!doctype html><html><head><meta name="color-scheme" content="light dark"><style>
        html,body{margin:0;width:100%;height:100%;overflow:hidden;background:#123456}
        @media(prefers-color-scheme:dark){html,body{background:#234567}}
        #marker{position:absolute;left:20px;top:140px;width:24px;height:24px;background:#ff0000;
          animation:travel \(duration)s \(delay)s linear \(infinite ? "infinite" : "1") both}
        #short{opacity:0;animation:appear .2s linear both}
        @keyframes travel{from{transform:translateX(0)}to{transform:translateX(200px)}}
        @keyframes appear{to{opacity:1}}
        </style></head><body data-cover="\(id)"><div id="marker"></div><div id="short">Result</div>
        <script>document.body.dataset.authorScript='ran'</script></body></html>
        """
        return .init(entry: .init(ref: ref, revision: 1, createdAt: 0, updatedAt: 0, title: JSONText(id), archived: false,
            tags: .init(tags: [], semanticTags: [], directoryTags: [], tagEmojis: [:]), presentations: [], view: view),
            context: .init(theme: .light, locale: "en", lifetime: PluginLifetime(),
                domain: .init(pluginID: "report", invoke: { _, operation, _, _, _ in
                    guard operation == "report.cover" else { throw PluginContractError("Unexpected cover operation") }
                    try await Task.sleep(for: loadDelay)
                    if fails { throw PluginContractError("Cover fixture query failed") }
                    return .object(["html": .text(html), "contentRevision": .text(revision)])
                }), capabilities: capabilities, openThread: { _, _ in }, openExecution: { _ in }))
    }
}

private struct CoverReplayView: View {
    let model: CoverReplay
    let props: [ApplicationThreadProps<NativeReportView>]
    var body: some View {
        Group {
            if props.count == 1 {
                NativeReportCover(props: props[0], playback: model.playback, replayID: model.replayID,
                    initiallyFinished: model.initiallyFinished, onReady: { model.ready += 1 })
            } else {
                NativeReportCollection(props: props, active: model.active,
                    onSelection: { model.selections.append($0) }, openThread: { _ in })
            }
        }
        .opacity(model.redraw ? 0.99 : 1)
        .id(model.identity)
        .environment(\.nativeReportCoverCache, model.cache)
        .environment(\.threadCardAnimationVisibility, model.visibility)
        .environment(\.threadCardCloudAnimationsEnabled, model.active)
        .environment(\.colorScheme, model.dark ? .dark : .light)
    }
}

private struct CoverGridReplayView: View {
    let model: CoverReplay
    let first: ApplicationThreadProps<NativeReportView>
    let second: ApplicationThreadProps<NativeReportView>
    var body: some View {
        NativeReportCollectionMembers(props: model.panelVisible ? [model.panelRevision == "first" ? first : second] : [],
            locale: "en", close: {}, allowsActions: { _ in true }, openThread: { _ in })
            .environment(\.nativeReportCoverCache, model.cache)
            .environment(\.colorScheme, model.dark ? .dark : .light)
    }
}

@MainActor @Suite struct CoverInitialPoseTests {
    @Test func newerReplaySurvivesStaleInitializationCallback() {
        let coordinator = ReportCoverHTML.Coordinator()
        coordinator.updateReplay(0, initiallyFinished: true)
        let oldGeneration = coordinator.replayID
        coordinator.updateReplay(1, initiallyFinished: false)
        coordinator.admitInitialPose(.finished, replayID: oldGeneration)
        #expect(coordinator.ready)
        #expect(coordinator.appliedPlayback == nil)
        #expect(!coordinator.completedOnce)
    }
}

@MainActor @Suite(.serializedNative, .requiresDisplay, .serialized)
struct NativeReportCoverTests {
    private func webViews(_ root: NSView) -> [WKWebView] {
        if let web = root as? WKWebView { return [web] }
        return root.subviews.flatMap(webViews)
    }
    private func read(_ web: WKWebView, _ expression: String) async throws -> Any? {
        try await web.callAsyncJavaScript("return \(expression)", arguments: [:], in: nil,
            contentWorld: .world(name: "Mokusei.Cover.Verification"))
    }
    private func x(_ web: WKWebView) async throws -> Double {
        try #require(try await read(web, "document.getElementById('marker').getBoundingClientRect().x") as? Double)
    }
    private func wait(timeout: Duration = .seconds(12), sourceLocation: SourceLocation = #_sourceLocation,
                      _ predicate: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            for window in NSApp?.windows ?? [] { window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded() }
            if try await predicate() { return }
            try await Task.sleep(for: .milliseconds(40))
        }
        for window in NSApp?.windows ?? [] {
            guard let root = window.contentView else { continue }
            for web in webViews(root) {
                let state = try? await read(web, "({id:document.body?.dataset.cover,hidden:document.hidden,time:document.timeline.currentTime,animations:document.getAnimations().map(a=>({name:a.animationName,time:a.currentTime,state:a.playState,pending:a.pending}))})")
                print("COVER TIMEOUT alpha=\(web.alphaValue) state=\(String(describing: state))")
            }
        }
        try #require(Bool(false), "Production cover did not reach the expected rendered state", sourceLocation: sourceLocation)
    }
    private func capture(_ web: WKWebView, name: String) async throws -> Double {
        let image = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NSImage, Error>) in
            web.takeSnapshot(with: nil) { image, error in
                if let image { continuation.resume(returning: image) }
                else { continuation.resume(throwing: error ?? PluginContractError("No rendered cover snapshot")) }
            }
        }
        let data = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: data))
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MOKUSEI_COVER_ARTIFACTS"]
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("mokusei-cover-evidence").path)
            .appendingPathComponent("report-covers")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
        var sum = 0.0, count = 0.0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                // Inspect the snapshot's own RGB components. Converting its
                // calibrated bitmap through the display profile changes pure red.
                if let color = bitmap.colorAt(x: x, y: y),
                   color.redComponent > 0.9, color.greenComponent < 0.1, color.blueComponent < 0.1 {
                    sum += Double(x); count += 1
                }
            }
        }
        try #require(count > 100, "Cover snapshot lost its authored marker: \(name)")
        return sum / count * 360 / Double(bitmap.pixelsWide)
    }

    @Test func liveCoverHoldsReplaysAndPauses() async throws {
        let model = CoverReplay(), props = try CoverReplay.props("cycle")
        let window = SwiftUIReplay.window(CoverReplayView(model: model, props: [props]), width: 360, height: 308)
        defer { window.contentView = nil; window.close() }
        let root = try #require(window.contentView)
        try await wait { model.ready == 1 }
        let web = try #require(webViews(root).first)
        try await Task.sleep(for: .milliseconds(2300))
        #expect(try await x(web) == 20, "Preloading must not consume the animation")
        #expect(try await read(web, "document.body.dataset.authorScript === undefined") as? Bool == true)
        #expect(web.configuration.defaultWebpagePreferences.allowsContentJavaScript == false)
        let first = try await capture(web, name: "cycle-first")
        model.playback = .playing
        try await wait { let position = try await x(web); return position > 65 && position < 180 }
        let middle = try await capture(web, name: "cycle-middle")
        #expect(middle > first + 20 && middle < 225)
        try await wait { try await x(web) >= 219.9 }
        let finished = ContinuousClock.now
        let final = try await capture(web, name: "cycle-final")
        #expect(final > middle + 20)
        try await Task.sleep(until: finished + .milliseconds(4400), clock: .continuous)
        #expect(try await x(web) >= 219.9, "Final composition must remain during the five-second hold")
        try await wait { try await x(web) < 100 }
        #expect(ContinuousClock.now - finished >= .milliseconds(4900), "Replay started before its five-second hold")
        let restarted = try await capture(web, name: "cycle-restarted")
        #expect(restarted < final - 100)
        model.visibility.isVisible = false
        try await Task.sleep(for: .milliseconds(150))
        let paused = try await x(web)
        try await Task.sleep(for: .milliseconds(550))
        #expect(abs(try await x(web) - paused) < 0.1)
        model.visibility.isVisible = true
        try await wait { abs(try await x(web) - paused) > 5 }
        #expect(try await read(web, "Number(getComputedStyle(document.getElementById('short')).opacity)") as? Double == 1,
            "An already completed shorter effect must not rewind on resume")
        model.active = false
        try await Task.sleep(for: .milliseconds(150))
        let inactive = try await x(web)
        try await Task.sleep(for: .milliseconds(300))
        #expect(abs(try await x(web) - inactive) < 0.1)
        print("REPORT_COVER_RENDERED_CYCLE_CONFIRMED")
    }

    @Test func singlePlaybackStaysFinishedAcrossRedrawAndReplaysOnce() async throws {
        let model = CoverReplay(), props = try CoverReplay.props("once", duration: 0.8)
        model.playback = .playingOnce
        let window = SwiftUIReplay.window(CoverReplayView(model: model, props: [props]), width: 360, height: 308)
        defer { window.contentView = nil; window.close() }
        try await wait { model.ready == 1 }
        let root = try #require(window.contentView)
        let web = try #require(webViews(root).first)
        try await wait { try await x(web) >= 219.9 }
        model.redraw.toggle()
        try await Task.sleep(for: .milliseconds(1100))
        #expect(try await x(web) >= 219.9, "Redraw must retain the final frame")
        model.replayID += 1
        try await wait { try await x(web) < 180 }
        try await wait { try await x(web) >= 219.9 }
        try await Task.sleep(for: .milliseconds(5500))
        #expect(try await x(web) >= 219.9, "A hover replay must not loop")
        model.replayID += 1
        try await wait { try await x(web) < 180 }
        print("REPORT_COVER_SINGLE_PLAY_CONFIRMED")
    }

    @Test func gridRetainsCompletedRevisionAcrossThemeAndPlaysNewRevision() async throws {
        let model = CoverReplay()
        let first = try CoverReplay.props("grid", revision: "first", duration: 0.8)
        let second = try CoverReplay.props("grid", revision: "second", duration: 0.8)
        let window = SwiftUIReplay.window(CoverGridReplayView(model: model, first: first, second: second), width: 500, height: 700)
        defer { window.contentView = nil; window.close() }
        let root = try #require(window.contentView)
        try await wait { webViews(root).contains { $0.alphaValue == 1 } }
        let firstWeb = try #require(webViews(root).first { $0.alphaValue == 1 })
        try await wait { try await x(firstWeb) >= 219.9 }
        try await Task.sleep(for: .milliseconds(250))
        model.dark = true
        try await wait { webViews(root).contains { $0 !== firstWeb && $0.alphaValue == 1 } }
        let darkWeb = try #require(webViews(root).first { $0 !== firstWeb && $0.alphaValue == 1 })
        #expect(try await x(darkWeb) >= 219.9)
        try await Task.sleep(for: .milliseconds(1000))
        #expect(try await x(darkWeb) >= 219.9, "Theme changes must retain the completed pose")
        model.panelVisible = false
        // LazyVGrid may retain offscreen native views. Visibility, rather than
        // physical removal from AppKit's tree, owns suspension and reentry.
        try await wait {
            for web in webViews(root) {
                if try await read(web, "document.hidden") as? Bool != true { return false }
            }
            return true
        }
        model.panelVisible = true
        var visibleWeb: WKWebView?
        try await wait {
            for web in webViews(root) where web.alphaValue == 1 {
                if try await read(web, "document.hidden") as? Bool == false {
                    visibleWeb = web
                    return true
                }
            }
            return false
        }
        let returnedWeb = try #require(visibleWeb)
        #expect(try await x(returnedWeb) >= 219.9, "Reentry must retain the completed revision")
        // Replace the revision while the panel and its completion history stay
        // mounted, so a thread-only completion key cannot pass this assertion.
        model.panelRevision = "second"
        try await wait { webViews(root).contains { $0 !== returnedWeb && $0.alphaValue == 1 } }
        let newWeb = try #require(webViews(root).first { $0 !== returnedWeb && $0.alphaValue == 1 })
        try await wait { let position = try await x(newWeb); return position > 25 && position < 200 }
        try await wait { try await x(newWeb) >= 219.9 }
        print("REPORT_COVER_REVISION_RETENTION_CONFIRMED")
    }

    @Test func replayRequestedDuringCoverLoadIsAdmitted() async throws {
        let model = CoverReplay(), props = try CoverReplay.props("loading", duration: 1, loadDelay: .seconds(1))
        model.playback = .playingOnce
        model.initiallyFinished = true
        let window = SwiftUIReplay.window(CoverReplayView(model: model, props: [props]), width: 360, height: 308)
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.ready == 0)
        model.replayID += 1
        model.initiallyFinished = false
        try await wait { model.ready == 1 }
        let root = try #require(window.contentView)
        let web = try #require(webViews(root).first)
        try await wait { let position = try await x(web); return position > 25 && position < 200 }
        try await wait { try await x(web) >= 219.9 }
        print("REPORT_COVER_LOADING_REPLAY_CONFIRMED")
    }

    @Test func oversizedInfiniteAuthorMotionStillCompletesWithinSixSeconds() async throws {
        let model = CoverReplay(), props = try CoverReplay.props("bounded", duration: 12, delay: 1, infinite: true)
        let window = SwiftUIReplay.window(CoverReplayView(model: model, props: [props]), width: 360, height: 308)
        defer { window.contentView = nil; window.close() }
        try await wait { model.ready == 1 }
        let root = try #require(window.contentView)
        let web = try #require(webViews(root).first)
        model.playback = .playing
        try await wait { try await x(web) > 20 }
        let began = ContinuousClock.now
        try await wait { try await x(web) >= 219.9 }
        #expect(ContinuousClock.now - began < .seconds(6))
        try await Task.sleep(for: .milliseconds(1200))
        #expect(try await x(web) >= 219.9)
        print("REPORT_COVER_BOUND_CONFIRMED")
    }

    @Test func carouselWaitsForReadinessAndEntranceAndReplaysSelectedCovers() async throws {
        let model = CoverReplay()
        let props = try [CoverReplay.props("first", duration: 6, loadDelay: .seconds(2)),
                         CoverReplay.props("second", duration: 6)]
        let window = SwiftUIReplay.window(CoverReplayView(model: model, props: props), width: 360, height: 456)
        defer { window.contentView = nil; window.close() }
        let root = try #require(window.contentView)
        try await wait { webViews(root).filter { $0.alphaValue == 1 }.count == 2 }
        let readyAt = ContinuousClock.now
        var documents: [String: WKWebView] = [:]
        for web in webViews(root) { documents[try #require(try await read(web, "document.body.dataset.cover") as? String)] = web }
        let first = try #require(documents["first"]), second = try #require(documents["second"])
        try await Task.sleep(until: readyAt + .seconds(10), clock: .continuous)
        #expect(model.selections.last?.threadID == "first", "Loading must not consume the eleven-second dwell")
        #expect(try await x(second) == 20, "Neighbor animation ran while hidden")
        try await wait { model.selections.last?.threadID == "second" }
        #expect(ContinuousClock.now - readyAt >= .milliseconds(10800))
        try await Task.sleep(for: .milliseconds(180))
        #expect(try await x(second) == 20, "Incoming cover ran during its native entrance")
        try await wait { try await x(second) > 35 }
        model.active = false
        try await Task.sleep(for: .milliseconds(150))
        let held = try await x(second)
        try await Task.sleep(for: .milliseconds(500))
        #expect(abs(try await x(second) - held) < 0.1)
        #expect(try await x(first) == 20)
        model.active = true
        try await wait { model.selections.last?.threadID == "first" }
        try await Task.sleep(for: .milliseconds(180))
        #expect(try await x(first) == 20)
        try await wait { let position = try await x(first); return position > 35 && position < 180 }
        #expect(try await capture(first, name: "carousel-reselected") < 200)
        print("REPORT_COVER_CAROUSEL_ADMISSION_CONFIRMED")
    }

    @Test func carouselAdvancesPastCoverThatFailsAfterSelection() async throws {
        let model = CoverReplay()
        let props = try [CoverReplay.props("available", duration: 1),
                         CoverReplay.props("unavailable", loadDelay: .seconds(13), fails: true)]
        let window = SwiftUIReplay.window(CoverReplayView(model: model, props: props), width: 360, height: 456)
        defer { window.contentView = nil; window.close() }
        try await wait { model.selections.last?.threadID == "unavailable" }
        // Include the pending preload failure and the full eleven-second dwell.
        try await wait(timeout: .seconds(15)) { model.selections.last?.threadID == "available" }
        print("REPORT_COVER_FAILURE_ADVANCE_CONFIRMED")
    }
}
