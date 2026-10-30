// Verification-only Overview card-count scale harness. Build with -O against
// this worktree's Release production objects; see run.py.
import AppKit
import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import Observation
import ScreenCaptureKit
import SwiftUI
import Synchronization
import MokuseiPluginAPI
import MokuseiHarnessCodex
@testable import MokuseiCore
@testable import MokuseiUI

private func stderr(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }

@main
struct OverviewScaleMain {
    @MainActor static func main() async {
        do {
            let arguments = try ScaleArguments()
            switch arguments.mode {
            case "layout": try runLayout(arguments)
            case "model": try await runModel(arguments)
            case "runtime": try await runRuntime(arguments)
            case "gui-idle": try await runGUI(arguments)
            case "gui-update": try await runGUI(arguments)
            case "gui-motion": try await runGUI(arguments)
            case "gui-first-load": try await runGUI(arguments)
            case "gui-correctness": try await runGUI(arguments)
            default: throw ScaleFailure(description: "Unknown mode \(arguments.mode)")
            }
        } catch {
            stderr("FAIL \(error)")
            exit(1)
        }
    }
}

// MARK: - Layout

@MainActor private func runLayout(_ arguments: ScaleArguments) throws {
    guard let output = arguments.output else { throw ScaleFailure(description: "--output is required") }
    let viewport = layoutViewport()
    var records: [[String: Any]] = []
    var diagnosticsChecks: [String: Any] = [:]
    #if OVERVIEW_PERF_DIAGNOSTICS
    OverviewPerformanceDiagnostics.reset()
    #endif

    func measure(_ scenario: String, n: Int, members: [NativeOverviewMember],
                 previous: [NativeOverviewPlacement], fitting: CGSize?, preferred: CGSize? = nil,
                 preserve: Bool = true, warmups: Int = 2, iterations: Int = 7) throws -> [NativeOverviewPlacement] {
        var last: NativeOverviewLayoutResult?
        var lastError = ""
        for _ in 0..<warmups {
            do {
                last = try NativeOverviewLayout.plan(previous: previous, next: members, fittingSize: fitting,
                    preferredSize: preferred, preservePositions: preserve)
            } catch { lastError = String(describing: error) }
        }
        var times: [Double] = []
        var work: [String: Any] = [:]
        var checks: [String: Any] = [:]
        for _ in 0..<iterations {
            #if OVERVIEW_PERF_DIAGNOSTICS
            OverviewPerformanceDiagnostics.reset()
            #endif
            let start = nowNs()
            do {
                let result = try NativeOverviewLayout.plan(previous: previous, next: members, fittingSize: fitting,
                    preferredSize: preferred, preservePositions: preserve)
                times.append(nsToMs(nowNs() - start))
                last = result; lastError = ""
                #if OVERVIEW_PERF_DIAGNOSTICS
                let snapshot = OverviewPerformanceDiagnostics.snapshot()
                checks = ["validatePairs": snapshot.layoutValidatePairs,
                          "intersectCalls": snapshot.layoutIntersectCalls,
                          "straightPairs": snapshot.layoutStraightPairs]
                #endif
                work = ["steps": result.work.steps, "candidateSteps": result.work.candidateSteps,
                        "searchComplete": result.searchComplete, "requiresRepack": result.requiresRepack,
                        "moveOrder": result.moveOrder.count, "shifted": result.shiftedIDs.count,
                        "totalShiftDistance": result.totalShiftDistance, "boundsColumns": result.bounds.columns,
                        "boundsRows": result.bounds.rows]
            } catch {
                times.append(nsToMs(nowNs() - start))
                lastError = String(describing: error)
                work["error"] = lastError
            }
        }
        guard let last else {
            records.append(["scenario": scenario, "n": n, "elapsedMs": times, "timeStats": stats(times),
                            "error": lastError, "work": work,
                            "fitting": fitting.map { ["width": $0.width, "height": $0.height] }.map { $0 as Any } ?? NSNull()])
            return previous
        }
        guard Set(last.placements.map(\.member)) == Set(members) else {
            throw ScaleFailure(description: "\(scenario): membership mismatch")
        }
        for (index, a) in last.placements.enumerated() {
            for b in last.placements.dropFirst(index + 1) where placementRect(a).intersects(placementRect(b)) {
                throw ScaleFailure(description: "\(scenario): overlap")
            }
        }
        let camera = NativeOverviewCameraGeometry.fit(.init(left: 0, top: 0,
            width: last.bounds.width, height: last.bounds.height), viewport: viewport)
        let visible = visibleMetrics(last.placements, camera: camera, viewport: viewport)
        records.append(["scenario": scenario, "n": n, "viewport": ["width": viewport.width, "height": viewport.height,
            "toolbarBottom": viewport.toolbarBottom], "fitting": fitting.map { ["width": $0.width, "height": $0.height] }.map { $0 as Any } ?? NSNull(),
            "elapsedMs": times, "timeStats": stats(times), "result": plain(last),
            "work": work, "diagnostics": checks, "camera": plain(camera),
            "visibleFull": visible.full, "visiblePartial": visible.partial, "visibleArea": visible.area,
            "visibleAreaFill": visible.area / (NativeOverviewCameraGeometry.framingRegion(viewport).width
                * NativeOverviewCameraGeometry.framingRegion(viewport).height)])
        diagnosticsChecks[scenario] = checks
        return last.placements
    }

    let fitting = readableFittingSize(viewport)
    for n in [10, 40, 100, 500] {
        let members = (0..<n).map { NativeOverviewMember(id: String(format: "c%04d", $0), columns: 1, rows: 1) }
        let initial = try measure("initial-\(n)", n: n, members: members, previous: [], fitting: fitting)
        let stable = try measure("content-same-\(n)", n: n, members: members, previous: initial, fitting: fitting)
        _ = stable
        let inserted = members + [NativeOverviewMember(id: String(format: "c%04d", n), columns: 1, rows: 1)]
        _ = try measure("insert-1-\(n)", n: n + 1, members: inserted, previous: initial, fitting: fitting)
        var removed = members
        removed.remove(at: removed.count / 2)
        _ = try measure("delete-1-\(n)", n: n - 1, members: removed, previous: initial, fitting: fitting)
        var grown = members
        grown[0] = .init(id: grown[0].id, columns: 2, rows: 1)
        let grownPlacements = try measure("grow-1-\(n)", n: n, members: grown, previous: initial, fitting: fitting)
        _ = try measure("shrink-back-\(n)", n: n, members: members, previous: grownPlacements, fitting: fitting)
        var mixed = members
        for index in mixed.indices where index % 7 == 3 { mixed[index] = .init(id: mixed[index].id, columns: 2, rows: 1) }
        for index in mixed.indices where index % 11 == 5 { mixed[index] = .init(id: mixed[index].id, columns: 1, rows: 2) }
        _ = try measure("mixed-\(n)", n: n, members: mixed, previous: [], fitting: fitting)
        let narrow = layoutViewport(width: 900, height: 750)
        let narrowFitting = readableFittingSize(narrow)
        _ = try measure("resize-narrow-\(n)", n: n, members: members, previous: initial, fitting: narrowFitting)
        let capacity = CGSize(width: 800, height: 500)
        _ = try measure("capacity-\(n)", n: n, members: members, previous: initial, fitting: capacity)
        var current = initial
        var resizeTimes: [Double] = []
        var resizeSteps: [Int] = []
        for step in 0..<10 {
            let target = step.isMultiple(of: 2) ? CGSize(width: 900, height: 750) : fitting
            let start = nowNs()
            let result = try NativeOverviewLayout.plan(previous: current, next: members, fittingSize: target)
            resizeTimes.append(nsToMs(nowNs() - start))
            resizeSteps.append(result.work.steps)
            current = result.placements
        }
        records.append(["scenario": "resize-repeated-\(n)", "n": n, "elapsedMs": resizeTimes,
                        "timeStats": stats(resizeTimes), "steps": resizeSteps])
    }
    let value: [String: Any] = ["schema": 1, "mode": "layout", "label": arguments.label,
        "environment": scaleEnvironment(window: nil),
        "records": records, "diagnostics": diagnosticsChecks]
    try writeJSON(value, to: output)
}

// MARK: - Model

@MainActor private func runModel(_ arguments: ScaleArguments) async throws {
    guard let output = arguments.output else { throw ScaleFailure(description: "--output is required") }
    let n = arguments.n
    var records: [[String: Any]] = []
    let runningIndex: Int? = nil

    for attempt in 0..<3 {
        let fixture = try ScaleFixture(n: n, runningIndex: runningIndex)
        var installMs: [Double] = []
        var installReceive: [Double] = []
        let installStart = nowNs()
        try await fixture.installBase()
        installMs.append(nsToMs(nowNs() - installStart))
        installReceive = fixture.receiveTiming
        let installCounters = diagnosticsJSON()
        records.append(["scenario": "first-install", "attempt": attempt, "n": n,
                        "elapsedMs": installMs, "receiveMs": installReceive,
                        "membershipBuilds": fixture.model.membershipBuildCount,
                        "items": fixture.model.items.count, "diagnostics": installCounters])
        // A valid warm transaction with an unchanged catalog exercises model
        // projection and catalog admission without new provider content.
        let warm = try makeNoChangeSequence(n: n, runningIndex: nil, count: 6)
        var warmMs: [Double] = []
        var warmReceive: [Double] = []
        for step in 0..<5 {
            fixture.resetReceiveTiming()
            let start = nowNs()
            try await fixture.install(warm.snapshots[step], warm.mutations[step])
            warmMs.append(nsToMs(nowNs() - start))
            warmReceive.append(contentsOf: fixture.receiveTiming)
        }
        records.append(["scenario": "warm-install", "attempt": attempt, "n": n,
                        "elapsedMs": warmMs, "receiveMs": warmReceive,
                        "membershipBuilds": fixture.model.membershipBuildCount, "items": fixture.model.items.count])
        await fixture.close()
    }

    let conditionTargets: [(String, Int)] = n == 0 ? [] : [("visible-role", 0), ("offscreen-role", n - 1)]
    for (role, target) in conditionTargets {
        for attempt in 0..<3 {
            let fixture = try ScaleFixture(n: n, runningIndex: nil)
            try await fixture.installBase()
            let sequence = try makeContentSequence(n: n, target: target, runningIndex: nil, count: 60)
            let baselineIdentities = fixture.model.items.map(\.structuralIdentity)
            // Warm up the provider cache and SwiftUI-independent model path.
            for step in 0..<5 { try await fixture.install(sequence.snapshots[step], sequence.mutations[step]) }
            fixture.resetReceiveTiming()
            var elapsed: [Double] = []
            var receives: [Double] = []
            var changedPresentations: [Int] = []
            var identityChanged = false
            var previousItems = fixture.model.items
            for step in 5..<55 {
                let start = nowNs()
                try await fixture.install(sequence.snapshots[step], sequence.mutations[step])
                elapsed.append(nsToMs(nowNs() - start))
                receives.append(contentsOf: fixture.receiveTiming)
                fixture.resetReceiveTiming()
                let items = fixture.model.items
                if items.map(\.structuralIdentity) != baselineIdentities { identityChanged = true }
                changedPresentations.append(zip(previousItems, items).filter { $0.0.presentationID != $0.1.presentationID }.count)
                previousItems = items
            }
            guard fixture.model.items[target].id == "card-\(target)" else {
                throw ScaleFailure(description: "Target item mismatch")
            }
            guard fixture.model.revisions.isEmpty else {
                throw ScaleFailure(description: "Content update unexpectedly created a layout revision")
            }
            records.append(["scenario": "k1-latency-\(role)", "attempt": attempt, "n": n, "target": target,
                            "elapsedMs": elapsed, "timeStats": stats(elapsed), "receiveMs": receives,
                            "receiveStats": stats(receives), "changedPresentations": changedPresentations,
                            "structuralIdentityChanged": identityChanged,
                            "membershipBuilds": fixture.model.membershipBuildCount,
                            "diagnostics": diagnosticsJSON()])
            await fixture.close()
        }
    }

    if n > 0 {
        let fixture = try ScaleFixture(n: n, runningIndex: nil)
        try await fixture.installBase()
        let sequence = try makeContentSequence(n: n, target: 0, runningIndex: nil, count: 25)
        for step in 0..<5 { try await fixture.install(sequence.snapshots[step], sequence.mutations[step]) }
        fixture.resetReceiveTiming()
        var elapsed: [Double] = []
        for step in 5..<25 {
            let start = nowNs()
            try await fixture.install(sequence.snapshots[step], sequence.mutations[step])
            elapsed.append(nsToMs(nowNs() - start))
        }
        records.append(["scenario": "k0-latency", "attempt": 0, "n": n, "elapsedMs": elapsed,
                        "timeStats": stats(elapsed), "receiveMs": fixture.receiveTiming,
                        "membershipBuilds": fixture.model.membershipBuildCount,
                        "diagnostics": diagnosticsJSON()])
        await fixture.close()
    }

    if n > 0 {
        let fixture = try ScaleFixture(n: n, runningIndex: nil)
        try await fixture.installBase()
        let sequence = try makeContentSequence(n: n, target: 0, runningIndex: nil, count: 140)
        let updates = 120
        let hz = arguments.hz
        let start = nowNs()
        var lateness: [Double] = []
        var elapsed: [Double] = []
        for step in 0..<updates {
            let deadline = start + UInt64(Double(step) / hz * 1e9)
            let now = nowNs()
            if deadline > now { try await Task.sleep(nanoseconds: deadline - now) }
            let wake = nowNs()
            lateness.append(max(0, Double(wake > deadline ? wake - deadline : 0) / 1e6))
            let updateStart = nowNs()
            try await fixture.install(sequence.snapshots[step], sequence.mutations[step])
            elapsed.append(nsToMs(nowNs() - updateStart))
        }
        records.append(["scenario": "k1-clock", "attempt": 0, "n": n, "hz": hz, "updates": updates,
                        "elapsedMs": elapsed, "timeStats": stats(elapsed), "latenessMs": lateness,
                        "latenessStats": stats(lateness), "diagnostics": diagnosticsJSON()])
        await fixture.close()
    }

    if n > 0 {
        let fixture = try ScaleFixture(n: n, runningIndex: nil)
        try await fixture.installBase()
        let filters = fixture.model.filters + fixture.model.filters.flatMap(\.children)
        let selected = filters.first { $0.count > 0 }
        var filterMs: [Double] = []
        for _ in 0..<20 {
            let start = nowNs()
            fixture.model.selectTag(selected)
            filterMs.append(nsToMs(nowNs() - start))
        }
        fixture.model.selectTag(nil)
        var searchMs: [Double] = []
        fixture.model.beginSearch()
        for index in 0..<20 {
            let start = nowNs()
            fixture.model.updateSearch(index.isMultiple(of: 2) ? "Café" : "no-match")
            searchMs.append(nsToMs(nowNs() - start))
        }
        fixture.model.endSearch()
        var leaveMs: [Double] = []
        for _ in 0..<20 {
            let start = nowNs()
            fixture.model.setPresentation(.init(overviewVisible: false))
            fixture.model.setPresentation(.init(overviewVisible: true))
            leaveMs.append(nsToMs(nowNs() - start))
        }
        records.append(["scenario": "filters-search-leave", "attempt": 0, "n": n,
                        "filterMs": filterMs, "searchMs": searchMs, "leaveMs": leaveMs,
                        "filterCount": filters.count, "selectedFilterCount": selected?.count ?? -1,
                        "diagnostics": diagnosticsJSON()])
        await fixture.close()
    }

    let value: [String: Any] = ["schema": 1, "mode": "model", "label": arguments.label, "n": n,
        "environment": scaleEnvironment(window: nil), "records": records]
    try writeJSON(value, to: output)
}

// MARK: - Runtime delivery

extension RuntimeClient {
    func scaleSeed(_ value: JSONValue) { state = value }
}

@MainActor private func runRuntime(_ arguments: ScaleArguments) async throws {
    guard let output = arguments.output else { throw ScaleFailure(description: "--output is required") }
    let n = arguments.n
    var records: [[String: Any]] = []
    guard n > 0 else {
        try writeJSON(["schema": 1, "mode": "runtime", "n": n, "environment": scaleEnvironment(window: nil),
                       "records": records], to: output)
        return
    }
    for attempt in 0..<3 {
        let fixture = try ScaleFixture(n: n, runningIndex: nil)
        await fixture.workspace.client.scaleSeed(fixture.baseSnapshot)
        let stream = await fixture.workspace.client.events()
        var iterator = stream.makeAsyncIterator()
        var initialEvent: RuntimeClientEvent?
        while let event = await iterator.next() {
            switch event {
            case .snapshot, .mutation: initialEvent = event
            case .failure(let error): throw ScaleFailure(description: error.message)
            default: continue
            }
            break
        }
        guard let initialEvent else { throw ScaleFailure(description: "Runtime stream did not emit the seeded snapshot") }
        try await fixture.workspace.installPrepared(fixture.baseSnapshot, event: initialEvent)
        guard fixture.model.items.count == n else { throw ScaleFailure(description: "Runtime install membership mismatch") }

        let snapshotData = try fixture.baseSnapshot.encodedData()
        let sequence = try makeContentSequence(n: n, target: 0, runningIndex: nil, count: 80)
        let mutationData = try sequence.mutations[0].encodedData()
        var snapshotParse: [Double] = []
        var mutationParse: [Double] = []
        for _ in 0..<20 {
            let start = nowNs(); _ = try JSONValue.parse(data: snapshotData)
            snapshotParse.append(nsToMs(nowNs() - start))
        }
        for _ in 0..<200 {
            let start = nowNs(); _ = try JSONValue.parse(data: mutationData)
            mutationParse.append(nsToMs(nowNs() - start))
        }
        var state = fixture.baseSnapshot
        var applyTimes: [Double] = []
        for index in 0..<60 {
            let start = nowNs()
            state = try RuntimeState.applying(sequence.mutations[index], to: state)
            applyTimes.append(nsToMs(nowNs() - start))
        }
        var acceptTimes: [Double] = []
        var waitTimes: [Double] = []
        var installTimes: [Double] = []
        var receiveTimes: [Double] = []
        var totalTimes: [Double] = []
        for index in 0..<60 {
            let start = nowNs()
            try await fixture.workspace.client.acceptMutation(sequence.mutations[index])
            let accepted = nowNs()
            var event: RuntimeClientEvent?
            while let next = await iterator.next() {
                switch next {
                case .snapshot, .mutation: event = next
                case .failure(let error): throw ScaleFailure(description: error.message)
                default: continue
                }
                break
            }
            let waited = nowNs()
            guard let event else { throw ScaleFailure(description: "Runtime stream ended early") }
            fixture.resetReceiveTiming()
            let installation = nowNs()
            try await fixture.workspace.installPrepared(sequence.snapshots[index], event: event)
            let installed = nowNs()
            acceptTimes.append(nsToMs(accepted - start))
            waitTimes.append(nsToMs(waited - accepted))
            installTimes.append(nsToMs(installed - installation))
            receiveTimes.append(contentsOf: fixture.receiveTiming)
            totalTimes.append(nsToMs(installed - start))
            guard fixture.workspace.catalog.revision == index + 1 else {
                throw ScaleFailure(description: "Runtime delivery revision mismatch")
            }
        }
        records.append(["scenario": "runtime-delivery", "attempt": attempt, "n": n,
            "snapshotBytes": snapshotData.count, "mutationBytes": mutationData.count,
            "snapshotParseMs": snapshotParse, "snapshotParseStats": stats(snapshotParse),
            "mutationParseMs": mutationParse, "mutationParseStats": stats(mutationParse),
            "applyMs": applyTimes, "applyStats": stats(applyTimes),
            "acceptMs": acceptTimes, "waitMs": waitTimes, "installMs": installTimes,
            "receiveMs": receiveTimes, "totalMs": totalTimes, "totalStats": stats(totalTimes),
            "diagnostics": diagnosticsJSON()])
        await fixture.close()
    }
    try writeJSON(["schema": 1, "mode": "runtime", "label": arguments.label, "n": n,
                   "environment": scaleEnvironment(window: nil), "records": records], to: output)
}

// MARK: - GUI

private final class CallbackLog: @unchecked Sendable {
    private let values = Mutex<[String]>([])
    func append(_ tag: String) { values.withLock { $0.append(tag) } }
    func snapshot() -> [String] { values.withLock { $0 } }
}

/// Thread-safe record for an independently supplied update run. The sender and
/// the main-actor consumer write from different isolation domains; snapshots
/// are taken only after both have stopped.
private final class IndependentUpdateRecorder: @unchecked Sendable {
    private let sent = Mutex<[Int: UInt64]>([:])
    private let received = Mutex<[Int: UInt64]>([:])
    private let applied = Mutex<[Int: UInt64]>([:])
    private let installMs = Mutex<[Double]>([])
    private let titleOK = Mutex<Int>(0)
    private let errors = Mutex<[String]>([])
    private(set) var measureStart: UInt64 = 0

    func start(_ at: UInt64) { measureStart = at }
    func sent(_ revision: Int, at time: UInt64) { sent.withLock { $0[revision] = time } }
    func received(_ revision: Int, at time: UInt64) { received.withLock { $0[revision] = time } }
    func applied(_ revision: Int, at time: UInt64, install: Double) {
        applied.withLock { $0[revision] = time }
        installMs.withLock { $0.append(install) }
    }
    func noteTitle() { titleOK.withLock { $0 += 1 } }
    func error(_ text: String) { errors.withLock { $0.append(text) } }

    func snapshot() -> [String: Any] {
        let sent = sent.withLock { $0 }, received = received.withLock { $0 }, applied = applied.withLock { $0 }
        let installs = installMs.withLock { $0 }
        let revisions = applied.keys.sorted()
        let finalRevision = revisions.last ?? 0
        let latestApply = revisions.last.flatMap { applied[$0] }
        let latestSend = revisions.last.flatMap { sent[$0] }
        let lagPairs: [Double] = revisions.compactMap { revision in
            guard let a = applied[revision], let s = sent[revision], a >= s else { return nil }
            return nsToMs(a - s)
        }
        let receiveLag: [Double] = revisions.compactMap { revision in
            guard let r = received[revision], let s = sent[revision], r >= s else { return nil }
            return nsToMs(r - s)
        }
        return ["sent": sent.count, "received": received.count, "applied": applied.count,
                "coalesced": max(0, sent.count - received.count),
                "firstRevision": revisions.first ?? 0, "finalRevision": finalRevision,
                "latestApplyAt": latestApply.map { Double($0) / 1e9 } ?? 0,
                "latestSendAt": latestSend.map { Double($0) / 1e9 } ?? 0,
                "latestStateLagMs": latestApply.flatMap { a in latestSend.flatMap { s in a >= s ? nsToMs(a - s) : nil } } ?? 0,
                "applyLagMs": lagPairs, "receiveLagMs": receiveLag,
                "installMs": installs, "titleChecks": titleOK.withLock { $0 },
                "errors": errors.withLock { $0 },
                "sentRevisions": sent.keys.sorted(), "receivedRevisions": received.keys.sorted(),
                "appliedRevisions": revisions]
    }
}

@MainActor private final class GUIRunner: NSObject, NSApplicationDelegate {
    private let arguments: ScaleArguments
    private var fixture: ScaleFixture?
    private var window: NSWindow?
    private var hosting: NSHostingView<NativeOverviewWorkspaceView>?
    private var result: [String: Any] = [:]
    private var windowNumber = 0
    private var invalidReasons = Set<String>()
    private var captureError = ""
    private let callbackLog = CallbackLog()

    init(arguments: ScaleArguments) { self.arguments = arguments }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in await self.start() }
    }

    private func start() async {
        do {
            try await setup()
            try await drive()
        } catch {
            result["error"] = String(describing: error)
            result["invalidReasons"] = Array(invalidReasons).sorted()
            await finish(exitCode: 1)
            return
        }
        await finish(exitCode: 0)
    }

    private func makeCallbacks(tag: String) -> NativeOverviewWorkspaceCallbacks {
        let log = callbackLog
        return NativeOverviewWorkspaceCallbacks(openThread: { _, _ in log.append(tag) },
            openApplication: { _, _ in log.append(tag) }, onSettings: { log.append(tag) },
            onFollowUp: { _, _ in log.append(tag) }, onRestart: { log.append(tag) })
    }

    private func setup() async throws {
        NSApp.setActivationPolicy(.regular)
        let fixture = try ScaleFixture(n: arguments.n,
            runningIndex: arguments.running == "visible" ? 0 : arguments.running == "offscreen" ? max(0, arguments.n - 1) : nil)
        self.fixture = fixture
        try fixture.workspace.preferences.setGlassWorld(arguments.glass)
        switch arguments.appearance {
        case "dark": try fixture.workspace.preferences.setAppearance(.dark)
        case "light": try fixture.workspace.preferences.setAppearance(.light)
        default: break
        }
        let callbacks = makeCallbacks(tag: "mount")
        let root = NativeOverviewWorkspaceView(model: fixture.model, callbacks: callbacks)
        let hosting = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1600, height: 1000),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Mokusei Overview Scale Harness"
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.setContentSize(NSSize(width: 1600, height: 1000))
        let screen = NSScreen.screens.max {
            $0.visibleFrame.width * $0.visibleFrame.height < $1.visibleFrame.width * $1.visibleFrame.height
        } ?? NSScreen.main
        if let screen {
            let frame = window.frame, visible = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2,
                                          y: visible.midY - frame.height / 2))
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        self.window = window
        self.hosting = hosting
        windowNumber = window.windowNumber
        // Give LaunchServices/AppKit one run-loop turn to install the hosting
        // view before the first model transaction is admitted.
        try await Task.sleep(for: .milliseconds(250))
    }

    private var viewport: NativeOverviewViewport {
        NativeOverviewWorkspaceView.viewport(in: hosting?.bounds.size ?? NSSize(width: 1600, height: 1000),
            hasFilters: !(fixture?.model.filters.isEmpty ?? true), hasDock: false)
    }

    private func checkWindow() {
        guard let window else { invalidReasons.insert("missing-window"); return }
        if !window.isVisible { invalidReasons.insert("window-not-visible") }
        if !window.isKeyWindow { invalidReasons.insert("window-not-key") }
        if !NSApp.isActive { invalidReasons.insert("application-inactive") }
        if !window.occlusionState.contains(.visible) { invalidReasons.insert("window-occluded") }
    }

    private func settle(timeout: Double = 90, expected: Int? = nil) async throws -> [String: Any] {
        guard let fixture else { throw ScaleFailure(description: "Missing fixture") }
        let targetCount = expected ?? arguments.n
        let start = nowNs()
        var firstLayout: UInt64?
        var allMounted: UInt64?
        var stable = 0
        var lastPlacements: [NativeOverviewPlacement] = []
        while nsToMs(nowNs() - start) < timeout * 1000 {
            try await Task.sleep(for: .milliseconds(50))
            let state = fixture.model.canvasState
            if targetCount == 0, firstLayout == nil, !state.isLayingOut,
               state.layoutSolveCount > 0 || nsToMs(nowNs() - start) > 500 {
                firstLayout = nowNs()
            }
            let placed = state.presentedPlacements
            if firstLayout == nil, state.layoutSolveCount > 0, !state.isLayingOut,
               placed.count == targetCount, state.layoutError == nil { firstLayout = nowNs() }
            let expectedMounted = Set(fixture.model.items.map(\.id))
            if allMounted == nil, !expectedMounted.isEmpty,
               state.mountedCardIDs == expectedMounted { allMounted = nowNs() }
            let sceneStable = !state.isLayingOut && !state.camera.isAnimating && placed == lastPlacements
            if firstLayout != nil, allMounted != nil || targetCount == 0,
               sceneStable, state.layoutError == nil {
                stable += 1
                if stable >= 10 { break }
            } else { stable = 0 }
            lastPlacements = placed
        }
        guard stable >= 10 else { throw ScaleFailure(description: "Overview did not settle within \(timeout)s") }
        let state = fixture.model.canvasState
        return ["firstLayoutMs": firstLayout.map { nsToMs($0 - start) }.map { $0 as Any } ?? NSNull(),
                "allMountedMs": allMounted.map { nsToMs($0 - start) }.map { $0 as Any } ?? NSNull(),
                "settleMs": nsToMs(nowNs() - start), "placements": state.presentedPlacements.count,
                "mounted": state.mountedCardIDs.count, "layoutSolveCount": state.layoutSolveCount,
                "geometryReuseCount": state.geometryReuseCount, "repackCount": state.repackCount,
                "camera": ["scale": state.camera.liveTransform.scale, "x": state.camera.liveTransform.x,
                           "y": state.camera.liveTransform.y, "manual": state.camera.manual]]
    }

    private func fixedCameraBlock() -> [String: Any] {
        guard let fixture else { return [:] }
        let state = fixture.model.canvasState
        let placements = state.presentedPlacements
        let cells = Dictionary(uniqueKeysWithValues: placements.map { ("\($0.column),\($0.row)", $0) })
        guard cells["0,0"] != nil else { return ["available": false] }
        var width = 0, height = 0
        while width < 4, cells["\(width),0"] != nil { width += 1 }
        while height < 2, cells["0,\(height)"] != nil { height += 1 }
        guard width >= 1, height >= 1 else { return ["available": false] }
        let rect = NativeOverviewContentRect(left: 0, top: 0,
            width: Double(width) * 376 - 16, height: Double(height) * 216 - 16)
        let transform = NativeOverviewCameraGeometry.fit(rect, viewport: viewport)
        state.camera.setManualTransform(transform)
        let metrics = visibleMetrics(placements, camera: transform, viewport: viewport)
        return ["available": true, "blockColumns": width, "blockRows": height,
                "camera": ["scale": transform.scale, "x": transform.x, "y": transform.y],
                "visibleFull": metrics.full, "visiblePartial": metrics.partial, "visibleArea": metrics.area,
                "visibleAreaFill": metrics.area / (NativeOverviewCameraGeometry.framingRegion(viewport).width
                    * NativeOverviewCameraGeometry.framingRegion(viewport).height)]
    }

    private func targetIndex(role: String) -> Int {
        guard let fixture else { return 0 }
        let placements = fixture.model.canvasState.presentedPlacements
        let origin = placements.filter { $0.column < 4 && $0.row < 2 }
        let originIDs = Set(origin.map(\.id))
        switch role {
        case "offscreen":
            let candidate = placements.max { a, b in
                (a.column + a.row) < (b.column + b.row)
            }
            let id = candidate?.id ?? "card-0"
            return Int(String(id.split(separator: "-").last ?? "0")) ?? max(0, arguments.n - 1)
        case "running":
            return fixturesRunningIndex
        default:
            if let id = originIDs.sorted().first,
               let index = Int(String(id.split(separator: "-").last ?? "0")) { return index }
            return 0
        }
    }

    private var fixturesRunningIndex: Int {
        arguments.running == "visible" ? 0 : arguments.running == "offscreen" ? max(0, arguments.n - 1) : 0
    }

    private func drive() async throws {
        let activated = NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        NSApp.activate(ignoringOtherApps: true)
        result["activation"] = ["returned": activated, "active": NSApp.isActive,
                                "key": window?.isKeyWindow ?? false,
                                "frontmostBundle": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "",
                                "frontmostPID": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0]
        if !NSApp.isActive {
            try await Task.sleep(for: .milliseconds(500))
            NSApp.activate(ignoringOtherApps: true)
            _ = NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            result["activation"] = ["returned": activated, "active": NSApp.isActive,
                                    "key": window?.isKeyWindow ?? false,
                                    "frontmostBundle": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "",
                                    "frontmostPID": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0]
        }
        switch arguments.mode {
        case "gui-first-load": try await firstLoad()
        case "gui-idle": try await idle()
        case "gui-update": try await updates()
        case "gui-motion": try await motion()
        case "gui-correctness": try await correctness()
        default: throw ScaleFailure(description: "Unknown GUI mode")
        }
        if let output = arguments.output {
            result["schema"] = 1
            result["mode"] = arguments.mode
            result["label"] = arguments.label
            result["n"] = arguments.n
            result["environment"] = scaleEnvironment(window: window)
            result["windowNumber"] = windowNumber
            result["glassWorld"] = fixture.map { $0.workspace.preferences.glassWorld as Any } ?? NSNull()
            result["appearancePreference"] = fixture.map { $0.workspace.preferences.appearance.rawValue as Any } ?? NSNull()
            result["invalidReasons"] = Array(invalidReasons).sorted()
            result["captureError"] = captureError
            try writeJSON(result, to: output)
        }
    }

    private func firstLoad() async throws {
        guard let fixture else { throw ScaleFailure(description: "Missing fixture") }
        guard let window, let hosting else { throw ScaleFailure(description: "Missing window") }
        var emptyCapture: Data?
        do { emptyCapture = try await capturePNG() }
        catch { captureError = String(describing: error) }
        let installStart = nowNs()
        try await fixture.installBase()
        let installMs = nsToMs(nowNs() - installStart)
        let receiveMs = fixture.receiveTiming
        let firstChange = OptionalTimeBox()
        var captureTask: Task<Void, Never>?
        if arguments.scenario == "capture", let empty = emptyCapture {
            let emptyHash = sha256(empty)
            captureTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    if let self, let data = try? await self.capturePNG(), sha256(data) != emptyHash {
                        firstChange.value = nowNs()
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        }
        let settleInfo = try await settle(timeout: 120)
        captureTask?.cancel()
        _ = await captureTask?.value
        let settleEnd = nowNs()
        var captures: [[String: Any]] = []
        if let empty = emptyCapture {
            captures.append(["kind": "empty", "bytes": empty.count, "sha256": sha256(empty)])
            try? empty.write(to: outputDirectory.appendingPathComponent("first-load-empty.png"))
        }
        do {
            let loaded = try await capturePNG()
            captures.append(["kind": "loaded", "bytes": loaded.count, "sha256": sha256(loaded)])
            try? loaded.write(to: outputDirectory.appendingPathComponent("first-load-loaded.png"))
        } catch { captureError = String(describing: error) }
        result["firstLoad"] = ["installMs": installMs, "receiveMs": receiveMs,
            "settle": settleInfo, "settleAfterInstallMs": nsToMs(settleEnd - installStart),
            "firstPixelChangeAfterInstallMs": firstChange.value.map { nsToMs($0 - installStart) }.map { $0 as Any } ?? NSNull(),
            "windowContentSize": NSStringFromRect(hosting.bounds), "captures": captures,
            "resource": try resourceSample().json]
        result["fixedCamera"] = fixedCameraBlock()
        result["diagnostics"] = diagnosticsJSON()
        result["page"] = pageJSON()
    }

    private func idle() async throws {
        guard let fixture else { throw ScaleFailure(description: "Missing fixture") }
        try await fixture.installBase()
        _ = try await settle()
        let fixed = fixedCameraBlock()
        try await Task.sleep(for: .seconds(2))
        resetDiagnostics()
        let start = try resourceSample()
        let diagnosticsBefore = diagnosticsJSON()
        let sampler = ResourceSampler(interval: 1)
        sampler.start()
        var windowStates: [[String: Any]] = []
        let seconds = max(1, Int(arguments.seconds))
        for _ in 0..<seconds {
            try await Task.sleep(for: .seconds(1))
            checkWindow()
            if let window {
                windowStates.append(["visible": window.isVisible, "key": window.isKeyWindow,
                    "active": NSApp.isActive, "occlusionVisible": window.occlusionState.contains(.visible),
                    "frame": NSStringFromRect(window.frame)])
            }
        }
        let samples = await sampler.stop()
        let end = try resourceSample()
        let elapsed = end.unix - start.unix
        let cpuSeconds = (end.userSeconds + end.systemSeconds) - (start.userSeconds + start.systemSeconds)
        result["idle"] = ["seconds": elapsed, "processCPUSeconds": cpuSeconds,
            "processCPUPercent": elapsed > 0 ? cpuSeconds / elapsed * 100 : 0,
            "wakeups": ["interrupt": Int(end.interruptWakeups - start.interruptWakeups),
                        "platformIdle": Int(end.platformIdleWakeups - start.platformIdleWakeups),
                        "timer": Int(end.timerWakeups - start.timerWakeups)],
            "start": start.json, "end": end.json, "samples": samples.map(\.json),
            "windowStates": windowStates, "fixedCamera": fixed,
            "diagnosticsBefore": diagnosticsBefore, "diagnostics": diagnosticsJSON(),
            "page": pageJSON()]
    }

    private func updates() async throws {
        guard let fixture else { throw ScaleFailure(description: "Missing fixture") }
        try await fixture.installBase()
        _ = try await settle()
        let fixed = fixedCameraBlock()
        if arguments.supply == "independent" {
            try await independentUpdates(fixture: fixture, fixed: fixed)
            return
        }
        let target = arguments.sequence == "content" ? targetIndex(role: arguments.target) : 0
        let total = max(arguments.updates, Int((arguments.warmup + arguments.seconds) * arguments.hz) + 8)
        let sequence = arguments.sequence == "no-change"
            ? try makeNoChangeSequence(n: arguments.n, runningIndex: fixture.runningIndex, count: total)
            : try makeContentSequence(n: arguments.n, target: target,
                runningIndex: fixture.runningIndex, count: total)
        let warmupCount = max(1, Int(arguments.warmup * arguments.hz))
        for step in 0..<warmupCount {
            try await fixture.install(sequence.snapshots[step], sequence.mutations[step])
        }
        try await Task.sleep(for: .milliseconds(500))
        fixture.resetReceiveTiming()
        let diagnosticsBefore = diagnosticsJSON()
        let countersBefore: [String: Any] = ["layoutSolveCount": fixture.model.canvasState.layoutSolveCount,
            "geometryReuseCount": fixture.model.canvasState.geometryReuseCount,
            "repackCount": fixture.model.canvasState.repackCount,
            "mounted": fixture.model.canvasState.mountedCardIDs.count,
            "revision": fixture.workspace.catalog.revision]
        let start = try resourceSample()
        let sampler = ResourceSampler(interval: 0.25)
        sampler.start()
        let measureCount = max(1, Int(arguments.seconds * arguments.hz))
        let measureStart = nowNs()
        var lateness: [Double] = []
        var elapsed: [Double] = []
        var receive: [Double] = []
        var changed: [Int] = []
        var revisionChecks = 0
        var titleChecks = 0
        var previousItems = fixture.model.items
        let baselineIdentities = previousItems.map(\.structuralIdentity)
        for step in 0..<measureCount {
            let index = warmupCount + step
            let deadline = measureStart + UInt64(Double(step) / arguments.hz * 1e9)
            let now = nowNs()
            if deadline > now { try await Task.sleep(nanoseconds: deadline - now) }
            let wake = nowNs()
            lateness.append(max(0, Double(wake > deadline ? wake - deadline : 0) / 1e6))
            checkWindow()
            let updateStart = nowNs()
            try await fixture.install(sequence.snapshots[index], sequence.mutations[index])
            elapsed.append(nsToMs(nowNs() - updateStart))
            receive.append(contentsOf: fixture.receiveTiming)
            fixture.resetReceiveTiming()
            // Yield one main-loop turn so SwiftUI can observe the model change.
            await Task.yield()
            if fixture.workspace.catalog.revision == index + 1 { revisionChecks += 1 }
            let items = fixture.model.items
            changed.append(zip(previousItems, items).filter { $0.0.presentationID != $0.1.presentationID }.count)
            if items.map(\.structuralIdentity) != baselineIdentities {
                invalidReasons.insert("structural-identity-changed")
            }
            previousItems = items
            if arguments.sequence == "content",
               let item = items.first(where: { $0.id == "card-\(target)" }),
               case .harness(let snapshot)? = fixture.model.snapshot(for: item),
               snapshot.input.thread.title.string.hasSuffix(" \(index + 1)") { titleChecks += 1 }
        }
        let samples = await sampler.stop()
        let end = try resourceSample()
        let countersAfter: [String: Any] = ["layoutSolveCount": fixture.model.canvasState.layoutSolveCount,
            "geometryReuseCount": fixture.model.canvasState.geometryReuseCount,
            "repackCount": fixture.model.canvasState.repackCount,
            "mounted": fixture.model.canvasState.mountedCardIDs.count,
            "revision": fixture.workspace.catalog.revision]
        let elapsedSeconds = end.unix - start.unix
        let cpuSeconds = (end.userSeconds + end.systemSeconds) - (start.userSeconds + start.systemSeconds)
        if revisionChecks != measureCount { invalidReasons.insert("revision-check-mismatch") }
        if arguments.sequence == "content", titleChecks != measureCount {
            invalidReasons.insert("title-check-mismatch")
        }
        if arguments.sequence == "no-change", changed.contains(where: { $0 != 0 }) {
            invalidReasons.insert("no-change-changed-presentation")
        }
        result["update"] = ["target": arguments.target, "targetIndex": target, "sequence": arguments.sequence,
            "hz": arguments.hz,
            "seconds": arguments.seconds, "warmupUpdates": warmupCount, "measuredUpdates": measureCount,
            "elapsedMs": elapsed, "timeStats": stats(elapsed), "receiveMs": receive,
            "receiveStats": stats(receive), "latenessMs": lateness, "latenessStats": stats(lateness),
            "changedPresentationCounts": changed, "revisionChecks": revisionChecks, "titleChecks": titleChecks,
            "processCPUSeconds": cpuSeconds, "processCPUPercent": elapsedSeconds > 0 ? cpuSeconds / elapsedSeconds * 100 : 0,
            "start": start.json, "end": end.json, "samples": samples.map(\.json),
            "fixedCamera": fixed, "countersBefore": countersBefore, "countersAfter": countersAfter,
            "diagnosticsBefore": diagnosticsBefore, "diagnostics": diagnosticsJSON(), "page": pageJSON()]
    }

    /// Exercise the boundaries that an Equatable outer card could freeze:
    /// offscreen content, completed tint, locale, the cloud-animation switch,
    /// visibility and callback replacement. Each step records what the mounted
    /// production card actually rendered, not only the model snapshot.
    private func correctness() async throws {
        guard let fixture, let hosting, let window else { throw ScaleFailure(description: "Missing GUI fixture") }
        try await fixture.installBase()
        _ = try await settle()
        let fixed = fixedCameraBlock()
        #if OVERVIEW_PERF_DIAGNOSTICS
        OverviewPerformanceDiagnostics.reset()
        #endif
        func rendered<Value>(_ key: String, as: Value.Type) -> [String: Value] {
            #if OVERVIEW_PERF_DIAGNOSTICS
            return (OverviewPerformanceDiagnostics.renderedCards()[key] as? [String: Value]) ?? [:]
            #else
            return [:]
            #endif
        }
        func bodyCounts(_ key: String) -> [String: Int] { rendered(key, as: Int.self) }
        func strings(_ key: String) -> [String: String] { rendered(key, as: String.self) }
        func bools(_ key: String) -> [String: Bool] { rendered(key, as: Bool.self) }
        var threads = fixture.baseThreads
        var revision = 0
        var steps: [[String: Any]] = []
        func apply(_ upserts: [JSONValue], _ next: [JSONValue]) async throws {
            revision += 1
            let snapshot = ScaleFixture.snapshot(threads: next, revision: revision)
            let mutation = ScaleFixture.mutation(upserts: upserts, removed: [], base: revision - 1, revision: revision)
            try await fixture.install(snapshot, mutation)
            try await Task.sleep(for: .milliseconds(450))
        }

        // 1. A title-only update on an offscreen card must still reach its
        // mounted semantic body; the outer shell must not be invalidated.
        let offscreen = targetIndex(role: "offscreen")
        let offscreenID = "card-\(offscreen)"
        let offscreenThread = try ScaleFixture.thread(index: offscreen, revision: revision + 1, suffix: revision + 1, running: false)
        threads[offscreen] = offscreenThread
        try await apply([offscreenThread], threads)
        let offscreenTitle = strings("renderedTitles")[offscreenID] ?? ""
        let offscreenSemantic = bodyCounts("semanticBodiesByCard")[offscreenID] ?? 0
        let offscreenShell = bodyCounts("shellBodiesByCard")[offscreenID] ?? 0
        var offscreenPixel: [String: Any] = [:]
        if let placement = fixture.model.canvasState.presentedPlacements.first(where: { $0.id == offscreenID }) {
            let frame = placement.cardFrame
            let rect = NativeOverviewContentRect(left: Double(frame.minX), top: Double(frame.minY),
                                                 width: Double(frame.width), height: Double(frame.height))
            let transform = NativeOverviewCameraGeometry.fit(rect, viewport: viewport)
            fixture.model.canvasState.camera.setManualTransform(transform)
            try await Task.sleep(for: .milliseconds(700))
            do {
                let data = try selfCapturePNG()
                let path = arguments.output?.deletingPathExtension().appendingPathExtension("offscreen.png")
                if let path { try data.write(to: path) }
                offscreenPixel = ["bytes": data.count, "sha256": sha256(data), "path": path?.path ?? "",
                                  "camera": ["scale": transform.scale, "x": transform.x, "y": transform.y]]
            } catch { offscreenPixel = ["error": String(describing: error)] }
            _ = fixedCameraBlock()
            try await Task.sleep(for: .milliseconds(500))
        }
        steps.append(["step": "offscreen-content", "id": offscreenID,
                      "renderedTitle": offscreenTitle,
                      "titleContainsRevision": offscreenTitle.hasSuffix(" \(revision)"),
                      "presentationID": strings("renderedPresentationIDs")[offscreenID] ?? "",
                      "semanticBodies": offscreenSemantic, "shellBodies": offscreenShell,
                      "mounted": fixture.model.canvasState.mountedCardIDs.count,
                      "pixel": offscreenPixel])

        // 2. completed=false -> true -> false must rebuild the shell each time
        // and change the recorded glass tint input.
        let visible = targetIndex(role: "visible")
        let visibleID = "card-\(visible)"
        let visibleThread = try ScaleFixture.thread(index: visible, revision: revision + 1, suffix: revision + 1, running: true)
        threads[visible] = visibleThread
        try await apply([visibleThread], threads)
        let runningCompleted = bools("renderedCompleted")[visibleID]
        let runningShell = bodyCounts("shellBodiesByCard")[visibleID] ?? 0
        let doneThread = try ScaleFixture.thread(index: visible, revision: revision + 1, suffix: revision + 1, running: false)
        threads[visible] = doneThread
        try await apply([doneThread], threads)
        let doneCompleted = bools("renderedCompleted")[visibleID]
        let doneShell = bodyCounts("shellBodiesByCard")[visibleID] ?? 0
        steps.append(["step": "completed-toggle", "id": visibleID,
                      "runningCompleted": runningCompleted.map { $0 as Any } ?? NSNull(),
                      "completedAfterRunning": doneCompleted.map { $0 as Any } ?? NSNull(),
                      "shellBodiesAfterRunning": runningShell, "shellBodiesAfterDone": doneShell])

        // 3. Locale must invalidate all semantic wrappers and reach the card.
        let localeBefore = strings("renderedLocales")
        try fixture.workspace.preferences.setLocale(.english)
        try await Task.sleep(for: .milliseconds(700))
        let localeAfter = strings("renderedLocales")
        let semanticAfterLocale = bodyCounts("semanticBodiesByCard")
        let semanticBeforeLocale = localeBefore.isEmpty ? semanticAfterLocale : semanticAfterLocale
        let englishCards = localeAfter.values.filter { $0 == "en-US" || $0.hasPrefix("en") }.count
        steps.append(["step": "locale", "englishCards": englishCards,
                      "totalCards": localeAfter.count, "renderedLocale": localeAfter[visibleID] ?? "",
                      "semanticBodiesTotal": semanticAfterLocale.values.reduce(0, +)])
        try fixture.workspace.preferences.setLocale(.chinese)
        try await Task.sleep(for: .milliseconds(500))

        // 4. The cloud-animation switch is part of the semantic key.
        let semanticBeforeAnimation = bodyCounts("semanticBodiesByCard").values.reduce(0, +)
        fixture.model.setPresentation(.init(settingsOpen: true))
        try await Task.sleep(for: .milliseconds(700))
        let semanticAfterAnimation = bodyCounts("semanticBodiesByCard").values.reduce(0, +)
        steps.append(["step": "animation-switch",
                      "semanticBodyDelta": semanticAfterAnimation - semanticBeforeAnimation])
        fixture.model.setPresentation(.init(settingsOpen: false))
        try await Task.sleep(for: .milliseconds(500))

        // 5. Visibility is part of both wrapper keys.
        let semanticBeforeVisibility = bodyCounts("semanticBodiesByCard").values.reduce(0, +)
        fixture.model.setPresentation(.init(overviewVisible: false))
        try await Task.sleep(for: .milliseconds(700))
        let semanticAfterVisibility = bodyCounts("semanticBodiesByCard").values.reduce(0, +)
        steps.append(["step": "visibility",
                      "semanticBodyDelta": semanticAfterVisibility - semanticBeforeVisibility])
        fixture.model.setPresentation(.init(overviewVisible: true))
        try await Task.sleep(for: .milliseconds(700))

        // 6. Replace the callbacks and tap a mounted card. The stable store must
        // route the action to the replacement receiver even if the card wrapper
        // does not rebuild.
        let bodiesBeforeCallback = bodyCounts("semanticBodiesByCard").values.reduce(0, +)
        hosting.rootView = NativeOverviewWorkspaceView(model: fixture.model, callbacks: makeCallbacks(tag: "replacement"))
        try await Task.sleep(for: .milliseconds(400))
        hosting.layoutSubtreeIfNeeded()
        let bodiesAfterCallback = bodyCounts("semanticBodiesByCard").values.reduce(0, +)
        let clickTarget = fixture.model.canvasState.presentedPlacements.first(where: { $0.id == visibleID })
            ?? fixture.model.canvasState.presentedPlacements.first
        if let placement = clickTarget {
            let transform = fixture.model.canvasState.camera.liveTransform
            let frame = placement.cardFrame
            let point = CGPoint(x: transform.x + frame.midX * transform.scale,
                                y: transform.y + frame.midY * transform.scale)
            let hostingPoint = NSPoint(x: point.x, y: hosting.isFlipped ? point.y : hosting.bounds.height - point.y)
            let windowPoint = hosting.convert(hostingPoint, to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: windowPoint, modifierFlags: [],
                                                  timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil,
                                                  eventNumber: 0, clickCount: 1, pressure: 1) {
                    window.sendEvent(event)
                }
            }
        }
        try await Task.sleep(for: .milliseconds(600))
        let callbackLog = callbackLog.snapshot()
        steps.append(["step": "callback-replacement",
                      "semanticBodyDeltaDuringCallbackSwap": bodiesAfterCallback - bodiesBeforeCallback,
                      "callbackLog": callbackLog,
                      "clicked": clickTarget?.id ?? ""])
        var pixel: [String: Any] = [:]
        do {
            let data = try selfCapturePNG()
            let path = arguments.output?.deletingPathExtension().appendingPathExtension("png")
            if let path { try data.write(to: path) }
            pixel = ["bytes": data.count, "sha256": sha256(data),
                     "path": path?.path ?? "", "kind": "NSView.cacheDisplay self-render"]
        } catch { pixel = ["error": String(describing: error)] }
        #if OVERVIEW_PERF_DIAGNOSTICS
        let renderedCards = OverviewPerformanceDiagnostics.renderedCards()
        #else
        let renderedCards: [String: Any] = [:]
        #endif
        result["correctness"] = ["steps": steps, "fixedCamera": fixed,
                                 "callbackLog": callbackLog, "pixel": pixel,
                                 "rendered": renderedCards]
        checkWindow()
    }

    /// Deliver mutations from a detached sender at fixed deadlines while the
    /// main actor consumes the Runtime event stream. Unlike the coupled loop,
    /// a blocked main thread cannot slow the supply; coalesced events and the
    /// resulting revision gap remain visible in the result.
    private func independentUpdates(fixture: ScaleFixture, fixed: [String: Any]) async throws {
        let target = arguments.sequence == "content" ? targetIndex(role: arguments.target) : 0
        let total = max(arguments.updates, Int((arguments.warmup + arguments.seconds) * arguments.hz) + 8)
        let sequence = arguments.sequence == "no-change"
            ? try makeNoChangeSequence(n: arguments.n, runningIndex: fixture.runningIndex, count: total)
            : try makeContentSequence(n: arguments.n, target: target,
                runningIndex: fixture.runningIndex, count: total)
        let warmupCount = max(1, Int(arguments.warmup * arguments.hz))
        let measureCount = max(1, Int(arguments.seconds * arguments.hz))
        for step in 0..<warmupCount {
            try await fixture.install(sequence.snapshots[step], sequence.mutations[step])
        }
        try await Task.sleep(for: .milliseconds(500))
        await fixture.workspace.client.scaleSeed(sequence.snapshots[warmupCount - 1])
        fixture.resetReceiveTiming()
        let diagnosticsBefore = diagnosticsJSON()
        let countersBefore: [String: Any] = ["layoutSolveCount": fixture.model.canvasState.layoutSolveCount,
            "geometryReuseCount": fixture.model.canvasState.geometryReuseCount,
            "repackCount": fixture.model.canvasState.repackCount,
            "mounted": fixture.model.canvasState.mountedCardIDs.count,
            "revision": fixture.workspace.catalog.revision]
        let recorder = IndependentUpdateRecorder()
        let measureStart = nowNs()
        recorder.start(measureStart)
        let start = try resourceSample()
        let sampler = ResourceSampler(interval: 0.25)
        sampler.start()
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                checkWindow()
            }
        }
        let stream = await fixture.workspace.client.events()
        let targetRevision = warmupCount + measureCount
        let consumer = Task { @MainActor in
            var iterator = stream.makeAsyncIterator()
            while let event = await iterator.next() {
                guard case .mutation(_, let state, _) = event else { continue }
                let revision = state["revision"]?.intValue ?? -1
                recorder.received(revision, at: nowNs())
                let installStart = nowNs()
                try await fixture.workspace.installPrepared(state, event: event)
                recorder.applied(revision, at: nowNs(), install: nsToMs(nowNs() - installStart))
                if arguments.sequence == "content",
                   let item = fixture.model.items.first(where: { $0.id == "card-\(target)" }),
                   case .harness(let snapshot)? = fixture.model.snapshot(for: item),
                   snapshot.input.thread.title.string.hasSuffix(" \(revision)") {
                    recorder.noteTitle()
                }
                checkWindow()
                if revision >= targetRevision { break }
            }
        }
        let mutations = sequence.mutations
        let client = fixture.workspace.client
        let offeredHz = arguments.hz
        let sender = Task.detached(priority: .high) {
            var lateness: [Double] = []
            for step in 0..<measureCount {
                let revision = warmupCount + step + 1
                let deadline = measureStart + UInt64(Double(step) / offeredHz * 1e9)
                let now = nowNs()
                if deadline > now { try? await Task.sleep(nanoseconds: deadline - now) }
                let wake = nowNs()
                lateness.append(max(0, Double(wake > deadline ? wake - deadline : 0) / 1e6))
                recorder.sent(revision, at: wake)
                do { try await client.acceptMutation(mutations[warmupCount + step]) }
                catch { recorder.error("send \(revision): \(error)"); break }
            }
            return lateness
        }
        let sendLateness = await sender.value
        let drainStart = nowNs()
        while nsToMs(nowNs() - drainStart) < 30_000 {
            if let latest = recorder.snapshot()["finalRevision"] as? Int, latest >= targetRevision { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        consumer.cancel()
        _ = try? await consumer.value
        heartbeat.cancel()
        _ = await heartbeat.value
        let samples = await sampler.stop()
        let end = try resourceSample()
        let snapshot = recorder.snapshot()
        let finalRevision = snapshot["finalRevision"] as? Int ?? 0
        let appliedCount = snapshot["applied"] as? Int ?? 0
        let applyLag = snapshot["applyLagMs"] as? [Double] ?? []
        let receiveLag = snapshot["receiveLagMs"] as? [Double] ?? []
        let installs = snapshot["installMs"] as? [Double] ?? []
        let latestApplyAt = snapshot["latestApplyAt"] as? Double ?? 0
        let latestSendAt = snapshot["latestSendAt"] as? Double ?? 0
        let wallSeconds = max(0.001, latestApplyAt - Double(measureStart) / 1e9)
        let elapsedSeconds = end.unix - start.unix
        let cpuSeconds = (end.userSeconds + end.systemSeconds) - (start.userSeconds + start.systemSeconds)
        if finalRevision < targetRevision { invalidReasons.insert("independent-supply-lag") }
        if arguments.sequence == "content", (snapshot["titleChecks"] as? Int ?? 0) != appliedCount {
            invalidReasons.insert("title-check-mismatch")
        }
        if arguments.sequence == "no-change" {
            // No content delta means every accepted event must leave the card
            // presentation identities unchanged.
            let items = fixture.model.items
            if items.count != arguments.n { invalidReasons.insert("membership-mismatch") }
        }
        let countersAfter: [String: Any] = ["layoutSolveCount": fixture.model.canvasState.layoutSolveCount,
            "geometryReuseCount": fixture.model.canvasState.geometryReuseCount,
            "repackCount": fixture.model.canvasState.repackCount,
            "mounted": fixture.model.canvasState.mountedCardIDs.count,
            "revision": fixture.workspace.catalog.revision]
        result["update"] = ["target": arguments.target, "targetIndex": target, "sequence": arguments.sequence,
            "supply": "independent", "hz": arguments.hz, "seconds": arguments.seconds,
            "warmupUpdates": warmupCount, "measuredUpdates": measureCount,
            "planned": measureCount,
            "sent": snapshot["sent"] as? Int ?? 0,
            "received": snapshot["received"] as? Int ?? 0,
            "applied": appliedCount,
            "coalesced": snapshot["coalesced"] as? Int ?? 0,
            "targetRevision": targetRevision, "finalRevision": finalRevision,
            "backlogRevisions": targetRevision - finalRevision,
            "effectiveHz": wallSeconds > 0 ? Double(appliedCount) / wallSeconds : 0,
            "wallSeconds": wallSeconds,
            "latestStateLagMs": snapshot["latestStateLagMs"] as? Double ?? 0,
            "latestApplyAt": latestApplyAt, "latestSendAt": latestSendAt,
            "sendLatenessMs": sendLateness, "sendLatenessStats": stats(sendLateness),
            "receiveLagMs": receiveLag, "receiveLagStats": stats(receiveLag),
            "applyLagMs": applyLag, "applyLagStats": stats(applyLag),
            "installMs": installs, "timeStats": stats(installs),
            "titleChecks": snapshot["titleChecks"] as? Int ?? 0,
            "sendErrors": snapshot["errors"] as? [String] ?? [],
            "sentRevisions": snapshot["sentRevisions"] as? [Int] ?? [],
            "receivedRevisions": snapshot["receivedRevisions"] as? [Int] ?? [],
            "appliedRevisions": snapshot["appliedRevisions"] as? [Int] ?? [],
            "processCPUSeconds": cpuSeconds, "processCPUPercent": elapsedSeconds > 0 ? cpuSeconds / elapsedSeconds * 100 : 0,
            "start": start.json, "end": end.json, "samples": samples.map(\.json),
            "fixedCamera": fixed, "countersBefore": countersBefore, "countersAfter": countersAfter,
            "diagnosticsBefore": diagnosticsBefore, "diagnostics": diagnosticsJSON(), "page": pageJSON()]
    }

    private func motion() async throws {
        guard let fixture else { throw ScaleFailure(description: "Missing fixture") }
        try await fixture.installBase()
        _ = try await settle()
        let fixed = fixedCameraBlock()
        if !arguments.overviewVisible {
            // Negative control: the same membership change without a visible
            // canvas must not run presentation policy waits.
            fixture.model.setPresentation(.init(overviewVisible: false))
            try await Task.sleep(for: .milliseconds(250))
        }
        switch arguments.scenario {
        case "remove-all", "remove-to-one", "insert-one":
            let empty = arguments.scenario == "remove-all"
            let keep = arguments.scenario == "remove-to-one"
            var nextThreads = fixture.baseThreads
            var removed: [JSONText] = []
            if empty {
                removed = fixture.baseThreads.compactMap { value in value["id"]?.stringValue.map { JSONText($0) } }
                nextThreads = []
            } else if keep {
                removed = fixture.baseThreads.dropFirst().compactMap { value in value["id"]?.stringValue.map { JSONText($0) } }
                nextThreads = Array(fixture.baseThreads.prefix(1))
            } else {
                let inserted = try ScaleFixture.thread(index: arguments.n, revision: 0, suffix: 0, running: false)
                nextThreads.append(inserted)
            }
            let snapshot = ScaleFixture.snapshot(threads: nextThreads, revision: 1)
            let mutation = ScaleFixture.mutation(upserts: arguments.scenario == "insert-one" ? [nextThreads.last!] : [],
                removed: removed, base: 0, revision: 1)
            resetDiagnostics()
            let start = try resourceSample()
            let startNs = nowNs()
            let lateness = LatenessRecorder()
            let measure = Task { @MainActor in
                // A 50 Hz probe records responsiveness while the production
                // layout task runs its serial policy waits.
                while !Task.isCancelled {
                    let deadline = nowNs() + 20_000_000
                    try? await Task.sleep(nanoseconds: 20_000_000)
                    let now = nowNs()
                    lateness.record(max(0, Double(now > deadline ? now - deadline : 0) / 1e6))
                }
            }
            try await fixture.install(snapshot, mutation)
            let modelReturned = nowNs()
            var firstLayingOut: UInt64?
            var settled: UInt64?
            while nsToMs(nowNs() - startNs) < 30_000 {
                if fixture.model.canvasState.isLayingOut, firstLayingOut == nil { firstLayingOut = nowNs() }
                if !fixture.model.canvasState.isLayingOut, firstLayingOut != nil {
                    settled = nowNs(); break
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            measure.cancel()
            _ = await measure.value
            try await Task.sleep(for: .milliseconds(250))
            let end = try resourceSample()
            let expected = !arguments.overviewVisible ? 0
                : arguments.scenario == "remove-all" ? Double(arguments.n) * 0.16
                : arguments.scenario == "remove-to-one" ? Double(arguments.n - 1) * 0.16 : 0.32
            result["motion"] = ["scenario": arguments.scenario, "n": arguments.n,
                "overviewVisible": arguments.overviewVisible,
                "modelReturnedMs": nsToMs(modelReturned - startNs),
                "firstLayingOutMs": firstLayingOut.map { nsToMs($0 - startNs) }.map { $0 as Any } ?? NSNull(),
                "settledMs": settled.map { nsToMs($0 - startNs) }.map { $0 as Any } ?? NSNull(),
                "expectedPolicyWaitSeconds": expected, "wakeLatenessMs": lateness.take(),
                "cpuSeconds": (end.userSeconds + end.systemSeconds) - (start.userSeconds + start.systemSeconds),
                "mountedAfter": fixture.model.canvasState.mountedCardIDs.count,
                "placementsAfter": fixture.model.canvasState.presentedPlacements.count,
                "fixedCamera": fixed, "diagnostics": diagnosticsJSON(), "page": pageJSON()]
        case "filter-clear":
            guard let filter = fixture.model.filters.first(where: { $0.count > 0 && $0.count < arguments.n }) else {
                throw ScaleFailure(description: "No non-empty strict filter available for filter-clear")
            }
            fixture.model.selectTag(filter)
            _ = try await settle(timeout: 60, expected: filter.count)
            try await Task.sleep(for: .seconds(1))
            resetDiagnostics()
            let start = try resourceSample()
            let startNs = nowNs()
            let lateness = LatenessRecorder()
            let measure = Task { @MainActor in
                while !Task.isCancelled {
                    let deadline = nowNs() + 20_000_000
                    try? await Task.sleep(nanoseconds: 20_000_000)
                    let now = nowNs()
                    lateness.record(max(0, Double(now > deadline ? now - deadline : 0) / 1e6))
                }
            }
            fixture.model.selectTag(nil)
            let modelReturned = nowNs()
            var firstLayingOut: UInt64?
            var settled: UInt64?
            while nsToMs(nowNs() - startNs) < 30_000 {
                if fixture.model.canvasState.isLayingOut, firstLayingOut == nil { firstLayingOut = nowNs() }
                if !fixture.model.canvasState.isLayingOut, firstLayingOut != nil {
                    settled = nowNs(); break
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            measure.cancel()
            _ = await measure.value
            let end = try resourceSample()
            result["motion"] = ["scenario": "filter-clear", "n": arguments.n,
                "overviewVisible": arguments.overviewVisible, "filteredCount": filter.count,
                "expectedPolicyWaitSeconds": arguments.overviewVisible ? 0.39 : 0,
                "modelReturnedMs": nsToMs(modelReturned - startNs),
                "firstLayingOutMs": firstLayingOut.map { nsToMs($0 - startNs) }.map { $0 as Any } ?? NSNull(),
                "settledMs": settled.map { nsToMs($0 - startNs) }.map { $0 as Any } ?? NSNull(),
                "wakeLatenessMs": lateness.take(),
                "cpuSeconds": (end.userSeconds + end.systemSeconds) - (start.userSeconds + start.systemSeconds),
                "mountedAfter": fixture.model.canvasState.mountedCardIDs.count,
                "placementsAfter": fixture.model.canvasState.presentedPlacements.count,
                "fixedCamera": fixed, "diagnostics": diagnosticsJSON(), "page": pageJSON()]
        case "pan":
            guard let window else { throw ScaleFailure(description: "Missing window") }
            let camera = fixture.model.canvasState.camera
            let origin = camera.liveTransform
            let submissions = Mutex<Int>(0)
            camera.onSubmission = { _ in submissions.withLock { $0 += 1 } }
            resetDiagnostics()
            let start = try resourceSample()
            let startNs = nowNs()
            let steps = Int(5 * 60)
            var lateness: [Double] = []
            for step in 0..<steps {
                let deadline = startNs + UInt64(Double(step) / 60 * 1e9)
                let now = nowNs()
                if deadline > now { try await Task.sleep(nanoseconds: deadline - now) }
                let wake = nowNs()
                lateness.append(max(0, Double(wake > deadline ? wake - deadline : 0) / 1e6))
                let phase = Double(step) / 60 * .pi / 2
                camera.setManualTransform(.init(scale: origin.scale, x: origin.x + 24 * sin(phase),
                                                y: origin.y + 16 * sin(2 * phase)))
            }
            camera.setManualTransform(origin)
            camera.onSubmission = nil
            let end = try resourceSample()
            result["motion"] = ["scenario": "pan", "n": arguments.n, "steps": steps,
                "cameraSubmissions": submissions.withLock { $0 }, "latenessMs": lateness,
                "processCPUPercent": (end.userSeconds + end.systemSeconds - start.userSeconds - start.systemSeconds)
                    / (end.unix - start.unix) * 100,
                "window": NSStringFromRect(window.frame), "fixedCamera": fixed,
                "diagnostics": diagnosticsJSON(), "page": pageJSON()]
        default:
            throw ScaleFailure(description: "Unknown motion scenario \(arguments.scenario)")
        }
    }

    private var outputDirectory: URL {
        arguments.output?.deletingLastPathComponent() ?? FileManager.default.temporaryDirectory
    }

    private func pageJSON() -> [String: Any] {
        guard let fixture else { return [:] }
        let state = fixture.model.canvasState
        return ["items": fixture.model.items.count, "mounted": state.mountedCardIDs.count,
                "placements": state.presentedPlacements.count, "outgoing": 0,
                "layoutSolveCount": state.layoutSolveCount, "geometryReuseCount": state.geometryReuseCount,
                "repackCount": state.repackCount, "sceneSnapshotCount": state.sceneSnapshotCount,
                "isLayingOut": state.isLayingOut, "layoutError": state.layoutError ?? "",
                "camera": ["scale": state.camera.liveTransform.scale, "x": state.camera.liveTransform.x,
                           "y": state.camera.liveTransform.y, "manual": state.camera.manual,
                           "isAnimating": state.camera.isAnimating],
                "membershipBuilds": fixture.model.membershipBuildCount,
                "revisions": fixture.model.revisions.count,
                "globalConversationCount": fixture.model.globalConversationCount ?? -1,
                "filters": fixture.model.filters.count,
                "glassWorld": fixture.workspace.preferences.glassWorld,
                "appearance": fixture.workspace.preferences.appearance.rawValue,
                "viewport": ["width": viewport.width, "height": viewport.height,
                             "toolbarBottom": viewport.toolbarBottom,
                             "bottomReservedHeight": viewport.bottomReservedHeight]]
    }

    /// Self-render of the hosting view. This proves the SwiftUI tree contains
    /// the new content without requiring Screen Recording permission; it is not
    /// a WindowServer pixel comparison.
    private func selfCapturePNG() throws -> Data {
        guard let hosting else { throw ScaleFailure(description: "Missing hosting view") }
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw ScaleFailure(description: "No bitmap rep for hosting view")
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw ScaleFailure(description: "PNG encoding failed")
        }
        return data
    }

    private func capturePNG() async throws -> Data {
        guard let window else { throw ScaleFailure(description: "Missing window") }
        // Preflight only: never trigger a TCC prompt during an unattended run.
        guard CGPreflightScreenCaptureAccess() else {
            throw ScaleFailure(description: "Screen recording permission not granted to the probe bundle")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let windowID = CGWindowID(window.windowNumber)
        guard let shareable = content.windows.first(where: { $0.windowID == windowID }) else {
            throw ScaleFailure(description: "Window \(windowID) is not shareable")
        }
        let filter = SCContentFilter(desktopIndependentWindow: shareable)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(window.frame.width * window.backingScaleFactor)
        configuration.height = Int(window.frame.height * window.backingScaleFactor)
        configuration.showsCursor = false
        configuration.capturesAudio = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw ScaleFailure(description: "PNG encoding failed")
        }
        return data
    }

    private func finish(exitCode: Int32) async {
        if let output = arguments.output, result["schema"] == nil {
            result["schema"] = 1
            result["mode"] = arguments.mode
            result["n"] = arguments.n
            result["environment"] = scaleEnvironment(window: window)
            result["invalidReasons"] = Array(invalidReasons).sorted()
            try? writeJSON(result, to: output)
        }
        await fixture?.close()
        exit(exitCode)
    }
}

@MainActor private func runGUI(_ arguments: ScaleArguments) async throws {
    guard arguments.output != nil else { throw ScaleFailure(description: "--output is required for GUI modes") }
    let application = NSApplication.shared
    application.setActivationPolicy(.regular)
    let runner = GUIRunner(arguments: arguments)
    application.delegate = runner
    application.finishLaunching()
    withExtendedLifetime(runner) { application.run() }
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
