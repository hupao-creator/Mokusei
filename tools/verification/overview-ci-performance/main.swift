import AppKit
import Darwin
import Foundation
import MokuseiCore
import MokuseiHarnessCodex
import MokuseiPluginAPI
import MokuseiPluginUI
import SwiftUI
@testable import MokuseiUI

private struct ExpectedCard: Decodable {
    let id: String
    let seq: Int
    let revision: Int
    let messageID: String
    let itemID: String
    let textSHA256: String
    let textLength: Int
}

private struct RuntimeReady: Decodable {
    struct Connection: Decodable {
        let port: Int
        let token: String
        let epoch: String
        let protocolVersion: Int
        let pid: Int
        let dataDir: String
        var runtime: RuntimeConnection {
            .init(port: port, token: token, epoch: epoch, protocolVersion: protocolVersion, pid: pid, dataDir: dataDir)
        }
    }
    let pid: Int
    let executable: String
    let parentPID: Int
    let connection: Connection
    let controlURL: String
    let controlToken: String
    let condition: String
    let n: Int
    let k: Int
    let expectedCards: [ExpectedCard]
}

private struct SourceSchedule: Decodable {
    let warmupStartUnixNano: Int64
    let formalStartUnixNano: Int64
    let formalEndUnixNano: Int64
    let warmupSeconds: Double
    let formalSeconds: Double
    let sourceIntervalNanoseconds: Int64

    var json: [String: Any] {
        ["warmupStartUnixNano": warmupStartUnixNano, "formalStartUnixNano": formalStartUnixNano,
         "formalEndUnixNano": formalEndUnixNano, "warmupSeconds": warmupSeconds,
         "formalSeconds": formalSeconds, "sourceIntervalNanoseconds": sourceIntervalNanoseconds]
    }
}

private struct FixtureConnectionSource: RuntimeConnectionSource {
    let connection: RuntimeConnection
    func start() async throws -> RuntimeConnection { connection }
    func status() async throws -> RuntimeConnection? { connection }
    // The owned Go process is shut down through its benchmark control endpoint.
    func stop(expectedEpoch: String?) async throws {}
    func setOutputLocale(_ locale: String) throws {
        guard locale == "zh-CN" else { throw ProbeFailure(description: "Fixture locale changed") }
    }
}

@MainActor
private final class CoreProcess {
    let process = Process()
    let readyURL: URL
    let outputURL: URL
    private let options: ProbeOptions
    private var logs: [FileHandle] = []
    private(set) var ready: RuntimeReady?
    private let session: URLSession

    init(options: ProbeOptions) {
        self.options = options
        let directory = options.output.deletingLastPathComponent()
        readyURL = directory.appendingPathComponent("runtime-ready.json")
        outputURL = directory.appendingPathComponent("core-result.json")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        session = URLSession(configuration: configuration)
    }

    func launch() async throws -> RuntimeReady {
        process.executableURL = options.runtime
        process.arguments = ["--ready-file", readyURL.path, "--output", outputURL.path,
            "--condition", options.condition, "--warmup", String(options.warmup),
            "--seconds", String(options.seconds), "--seed", String(options.seed),
            "--parent-pid", String(ProcessInfo.processInfo.processIdentifier)]
        for name in ["core-stdout.log", "core-stderr.log"] {
            let url = options.output.deletingLastPathComponent().appendingPathComponent(name)
            _ = FileManager.default.createFile(atPath: url.path, contents: nil)
            logs.append(try FileHandle(forWritingTo: url))
        }
        process.standardOutput = logs[0]; process.standardError = logs[1]
        try process.run()
        let deadline = monotonicNanoseconds() + 20_000_000_000
        while monotonicNanoseconds() < deadline {
            guard process.isRunning else { throw ProbeFailure(description: "Core exited before ready; inspect core-stderr.log") }
            if FileManager.default.fileExists(atPath: readyURL.path) {
                let value = try JSONDecoder().decode(RuntimeReady.self, from: Data(contentsOf: readyURL))
                guard value.pid == Int(process.processIdentifier), value.parentPID == Int(ProcessInfo.processInfo.processIdentifier),
                      value.condition == options.condition, value.n == 40, value.k == 4,
                      value.expectedCards.count == 4,
                      URL(fileURLWithPath: value.executable).resolvingSymlinksInPath() == options.runtime.resolvingSymlinksInPath(),
                      let endpoint = URL(string: value.controlURL), endpoint.scheme == "http", endpoint.host == "127.0.0.1",
                      !value.controlToken.isEmpty else {
                    throw ProbeFailure(description: "Owned Core ready identity does not match this invocation")
                }
                ready = value
                return value
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw ProbeFailure(description: "Core readiness timed out")
    }

    func request(_ path: String, method: String = "GET") async throws -> Data {
        guard let ready, let base = URL(string: ready.controlURL) else { throw ProbeFailure(description: "Core is not ready") }
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(ready.controlToken)", forHTTPHeaderField: "Authorization")
        if method == "POST" { request.httpBody = Data("{}".utf8) }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw ProbeFailure(description: "Core control \(path) failed with HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        return data
    }

    func stop() async -> [String] {
        var failures: [String] = []
        if process.isRunning, ready != nil {
            do { _ = try await request("finish", method: "POST") }
            catch { failures.append("Core finish request failed: \(error)") }
        }
        let deadline = monotonicNanoseconds() + 10_000_000_000
        while process.isRunning && monotonicNanoseconds() < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
        if process.isRunning {
            failures.append("Owned Core did not exit after finish; sent SIGTERM")
            process.terminate()
            let termination = monotonicNanoseconds() + 3_000_000_000
            while process.isRunning && monotonicNanoseconds() < termination { try? await Task.sleep(nanoseconds: 50_000_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        } else if process.processIdentifier > 0, process.terminationStatus != 0 {
            failures.append("Core exited with status \(process.terminationStatus)")
        }
        session.invalidateAndCancel()
        for log in logs { try? log.close() }
        // The ready file contains ephemeral bearer credentials. Keep only owned
        // process identity for timeout cleanup/evidence after the host has exited.
        if !process.isRunning, let ready {
            try? writeJSON(["pid": ready.pid, "executable": ready.executable,
                "parentPID": ready.parentPID, "credentialsRemovedAfterExit": true], to: readyURL)
        }
        return failures
    }
}

@MainActor
private final class OverviewProbe {
    let options: ProbeOptions
    let clock = ProbeClock()
    let tracker = InstallationTracker()
    let core: CoreProcess
    var workspace: NativeWorkspaceModel?
    var model: NativeOverviewWorkspaceModel?
    var window: NSWindow?
    var report: [String: Any]
    var invalid = Set<String>()
    var samples: [[String: Any]] = []
    var footprints: [UInt64] = []
    var formalStart: CPUSample?
    var formalEnd: CPUSample?
    var sampler: Task<Void, Never>?
    let cpuQueue = DispatchQueue(label: "com.mokusei.overview-ci.process-cpu", qos: .userInitiated)
    var cpuCaptures: [String: ScheduledCPUSample] = [:]
    var requestedCamera: NativeOverviewTransform?

    init(options: ProbeOptions) {
        self.options = options; core = CoreProcess(options: options)
        report = ["schemaVersion": 1, "condition": options.condition, "n": options.n, "k": 4,
            "warmupSeconds": options.warmup, "formalSeconds": options.seconds, "seed": options.seed,
            "valid": false, "invalidReasons": ["run-incomplete"], "stage": "initializing",
            "measurement": "Release product modules, production Overview and transport; process CPU as one-core percent",
            "unobserved": ["WindowServer pixels", "presented FPS and GPU time", "transport receive byte count",
                "event queue depth and oldest waiting event", "explicit consumer overflow counter"]]
    }

    func run() async -> Int32 {
        do {
            try FileManager.default.createDirectory(at: options.output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try writeJSON(report, to: options.output)
            try await measure()
        } catch { invalid.insert(String(describing: error)) }
        sampler?.cancel()
        await sampler?.value
        sampler = nil
        for capture in cpuCaptures.values { capture.cancel() }
        updateCPUClockReport()
        if let model { await model.stop() }
        if let workspace {
            do { try await workspace.stop() }
            catch { invalid.insert("Workspace cleanup failed: \(error)") }
        }
        for failure in await core.stop() { invalid.insert(failure) }
        if FileManager.default.fileExists(atPath: core.outputURL.path) {
            do {
                if let final = try JSONSerialization.jsonObject(with: Data(contentsOf: core.outputURL)) as? [String: Any] {
                    report["core"] = final
                    if final["valid"] as? Bool != true { invalid.insert("Core marked the source measurement invalid") }
                    validateDelivery(final)
                } else { invalid.insert("Core final report is not an object") }
            } catch { invalid.insert("Core final report could not be read: \(error)") }
        } else { invalid.insert("Core final report was not written") }
        report["windowSamples"] = samples
        let observations = samples.compactMap { sample -> [String: Any]? in
            guard let label = sample["label"] as? String, label.hasPrefix("formal"),
                  var timing = sample["observationTiming"] as? [String: Any] else { return nil }
            timing["label"] = label
            return timing
        }
        report["mainActorObservations"] = ["records": observations,
            "maximumLatenessMilliseconds": observations.compactMap { $0["latenessMilliseconds"] as? Double }.max() ?? 0,
            "meaning": "Window and footprint state at actual observation times; late checks do not move CPU boundaries or certify the unobserved interval"] as [String: Any]
        report["stage"] = "finished"
        report["valid"] = invalid.isEmpty
        report["invalidReasons"] = invalid.sorted()
        report["completedUnixNanoseconds"] = realtimeNanoseconds()
        do { try writeJSON(report, to: options.output) }
        catch { fputs("Could not write Overview result: \(error)\n", stderr); return 1 }
        window?.orderOut(nil)
        print("OVERVIEW_CI_PERFORMANCE_RESULT condition=\(options.condition) valid=\(invalid.isEmpty) output=\(options.output.path)")
        return invalid.isEmpty ? 0 : 1
    }

    private func measure() async throws {
        let ready = try await core.launch()
        report["runtimeProcess"] = ["pid": ready.pid, "executable": ready.executable, "parentPID": ready.parentPID] as [String: Any]
        let directory = options.output.deletingLastPathComponent().appendingPathComponent("swift-profile", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let preferences = DesktopPreferences(directory: directory)
        try preferences.setAppearance(.dark)
        try preferences.setLocale(.chinese)
        try preferences.setGlassWorld(true)
        let client = RuntimeClient(storageDirectory: directory, connectionSource: FixtureConnectionSource(connection: ready.connection.runtime))
        let workspace = NativeWorkspaceModel(client: client, preferences: preferences,
            plugins: try NativePluginComposition(harnesses: [AnyHarnessPlugin(CodexHarnessPlugin())], sidecards: [], applications: []))
        let model = NativeOverviewWorkspaceModel(workspace: workspace, applications: .init(
            projectionCapabilities: { _, _ in throw ProbeFailure(description: "Fixture has no application cards") },
            rendererContext: { _, _, _ in throw ProbeFailure(description: "Fixture has no application cards") }))
        self.workspace = workspace; self.model = model
        workspace.onCatalogChange = { [weak model, weak tracker = self.tracker, weak workspace] event in
            model?.receive(event)
            if let workspace { tracker?.record(event, catalog: workspace.catalog) }
        }
        workspace.onConnectionChange = { [weak model, weak tracker = self.tracker] status in
            model?.receive(.connection(status)); tracker?.connection(status)
        }
        workspace.onOverviewFilter = { [weak model] in model?.receiveFilter($0) }
        let view = NativeOverviewWorkspaceView(model: model,
            callbacks: .init(openThread: { _, _ in }, openApplication: { _, _ in }, onSettings: {}))
            .preferredColorScheme(.dark)
            .environment(\.scenePhase, .active)
        let hosting = NSHostingView(rootView: view)
        guard let screen = NSScreen.main else { throw ProbeFailure(description: "No screen is available to host Overview") }
        let style: NSWindow.StyleMask = [.titled, .closable, .resizable]
        let capacity = NSWindow.contentRect(forFrameRect: screen.visibleFrame, styleMask: style)
        let content = CGRect(x: 0, y: 0, width: min(1291, capacity.width), height: min(600, capacity.height))
        let window = NSWindow(contentRect: content, styleMask: style, backing: .buffered, defer: false)
        self.window = window
        window.title = "Mokusei Overview CI performance"
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate()
        workspace.start()
        let mountStart = monotonicNanoseconds()
        try await waitForStableLayout(model: model, workspace: workspace)
        try setFixedCamera(model)
        // A manual camera assignment must finish its actual hosted layout before
        // the independent source is allowed to begin its five-second warmup.
        try await waitForStableLayout(model: model, workspace: workspace)
        report["mountAndSettleMilliseconds"] = Double(monotonicNanoseconds() - mountStart) / 1e6
        let beforeEnvironment = environmentJSON()
        report["environment"] = ["start": beforeEnvironment]
        let beforeVisibility = visibilityJSON(model), beforeNative = nativeDecorationJSON(hosting)
        report["visibility"] = ["beforeWarmup": beforeVisibility]
        report["nativeDecoration"] = ["beforeWarmup": beforeNative]
        samples.append(try windowSample(label: "beforeWarmup", model: model, window: window, reject: true))
        guard beforeVisibility["allFull"] as? Bool == true else { throw ProbeFailure(description: "Four running cards are not fully visible in the real window") }
        guard beforeNative["nativePathActive"] as? Bool == true else { throw ProbeFailure(description: "Four active native clouds/scans are unavailable on this runner") }
        try validateCardShapes(model, workspace: workspace)
        guard NSWorkspace.shared.accessibilityDisplayShouldReduceMotion == false,
              NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency == false else {
            throw ProbeFailure(description: "Runner accessibility motion/transparency settings do not match the fixed scenario")
        }
        report["comparisonIdentity"] = try comparisonIdentity(model: model, window: window, expected: ready.expectedCards)
        report["stage"] = "mounted"
        try writeJSON(report, to: options.output)
        guard invalid.isEmpty else { throw ProbeFailure(description: "Foreground prerequisites failed before source start") }
        let schedule = try JSONDecoder().decode(SourceSchedule.self, from: await core.request("start", method: "POST"))
        guard schedule.warmupSeconds == options.warmup, schedule.formalSeconds == options.seconds,
              schedule.formalStartUnixNano - schedule.warmupStartUnixNano == 5_000_000_000,
              schedule.formalEndUnixNano - schedule.formalStartUnixNano == 20_000_000_000,
              schedule.sourceIntervalNanoseconds == 25_000_000 else {
            throw ProbeFailure(description: "Source schedule violates the fixed benchmark contract")
        }
        let warmupDeadline = try clock.deadline(unix: schedule.warmupStartUnixNano)
        let beginDeadline = try clock.deadline(unix: schedule.formalStartUnixNano)
        let endDeadline = try clock.deadline(unix: schedule.formalEndUnixNano)
        report["clock"] = ["anchor": clock.json, "schedule": schedule.json,
            "maximumAllowedBoundaryOffsetMilliseconds": 50,
            "samplingExecutor": "Dedicated serial Dispatch queue; no MainActor work inside CPU callbacks"] as [String: Any]
        guard monotonicNanoseconds() < warmupDeadline else {
            throw ProbeFailure(description: "Source warmup boundary passed before independent CPU captures could be armed")
        }
        // Enqueue all three deadlines before awaiting any result. In particular,
        // a delayed MainActor start observation cannot delay the formal end read.
        let warmupCapture = scheduleCPU("warmupStart", deadline: warmupDeadline)
        let beginCapture = scheduleCPU("formalStart", deadline: beginDeadline)
        let endCapture = scheduleCPU("formalEnd", deadline: endDeadline)
        let warmup = try await warmupCapture.value()
        validateCPUOffset(warmup, capture: warmupCapture)
        let begin = try await beginCapture.value()
        formalStart = begin
        validateCPUOffset(begin, capture: beginCapture)
        let startObservationBegan = monotonicNanoseconds()
        let countersBefore = countersJSON(model)
        samples.append(try windowSample(label: "formalStart", model: model, window: window, reject: true, plannedUptime: beginDeadline))
        let startObservationEnded = monotonicNanoseconds()
        sampler = Task { @MainActor [weak self, weak model, weak window] in
            guard let self, let model, let window else { return }
            for second in 1..<20 {
                do {
                    let planned = beginDeadline + UInt64(second) * 1_000_000_000
                    try await self.sleepUntil(planned)
                    guard !Task.isCancelled else { return }
                    self.samples.append(try self.windowSample(label: "formal-\(second)", model: model, window: window,
                        reject: true, plannedUptime: planned))
                } catch is CancellationError { return }
                catch { self.invalid.insert("Formal observation failed: \(error)"); return }
            }
        }
        let end = try await endCapture.value()
        formalEnd = end
        validateCPUOffset(end, capture: endCapture)
        sampler?.cancel(); await sampler?.value; sampler = nil
        let endObservationBegan = monotonicNanoseconds()
        let countersAfter = countersJSON(model)
        samples.append(try windowSample(label: "formalEnd", model: model, window: window, reject: true, plannedUptime: endDeadline))
        let endObservationEnded = monotonicNanoseconds()
        var formalCPU = try cpuInterval(from: begin, to: end,
            meaning: "Fixed source formal interval; actual independent process-CPU sample boundaries")
        formalCPU["footprintStartBytes"] = footprints.first ?? 0
        formalCPU["footprintEndBytes"] = footprints.last ?? 0
        formalCPU["footprintMaxSampledBytes"] = footprints.max() ?? 0
        formalCPU["footprintSampling"] = "TASK_VM_INFO at MainActor boundary observations and 1 Hz; timestamps may lag CPU boundaries; maximum is sampled, not continuous"
        report["ui"] = formalCPU
        let clockEnd = ProbeClock()
        let clockDrift = Double(clockEnd.unixNanoseconds - clock.unix(at: clockEnd.uptimeNanoseconds)) / 1e6
        var clockReport = report["clock"] as? [String: Any] ?? [:]
        clockReport["realtimeAnchorDriftMilliseconds"] = clockDrift
        report["clock"] = clockReport
        updateCPUClockReport()
        if abs(clockDrift) > 5 { invalid.insert("Realtime/monotonic clock mapping drifted more than 5 ms") }
        report["counters"] = ["formalStart": countersBefore, "formalEnd": countersAfter,
            "observationTiming": [
                "formalStart": observationTiming(planned: beginDeadline, started: startObservationBegan, finished: startObservationEnded),
                "formalEnd": observationTiming(planned: endDeadline, started: endObservationBegan, finished: endObservationEnded)],
            "meaning": "MainActor observations at their recorded times; not exact CPU-boundary snapshots"] as [String: Any]
        for name in ["layoutSolveCount", "repackCount", "structureRevision", "recoveryEpoch"] {
            if String(describing: countersBefore[name]!) != String(describing: countersAfter[name]!) {
                invalid.insert("\(name) changed inside the content-only formal window")
            }
        }
        report["visibility"] = ["beforeWarmup": beforeVisibility, "formalEnd": visibilityJSON(model)]
        let afterNative = nativeDecorationJSON(hosting)
        report["nativeDecoration"] = ["beforeWarmup": beforeNative, "formalEnd": afterNative]
        if afterNative["nativePathActive"] as? Bool != true { invalid.insert("Native decoration path was not active at formal end") }
        let tailObservationEnded = try await observeTail(model: model, workspace: workspace, expected: ready.expectedCards)
        let tailCapture = scheduleCPU("tailObservationEnd", deadline: tailObservationEnded)
        let tailEnd = try await tailCapture.value()
        validateCPUOffset(tailEnd, capture: tailCapture)
        updateCPUClockReport()
        report["uiWindows"] = ["tailObservation": try cpuInterval(from: end, to: tailEnd,
                meaning: "Formal CPU end through the existing final-model stability observation; includes pending UI work and observation overhead, not queue drain"),
            "sourceThroughTailObservation": try cpuInterval(from: warmup, to: tailEnd,
                meaning: "Source warmup start through the same final-model stability observation; includes warmup, formal and post-supply work; not a per-event cost or comparable to Core formal CPU")] as [String: Any]
        // Environment subprocesses, report fetch, hashes and full receipt encoding
        // belong after every CPU interval, including the post-supply interval.
        let result = try JSONSerialization.jsonObject(with: await core.request("result")) as? [String: Any]
        if let result { report["core"] = result }
        let afterEnvironment = environmentJSON()
        report["environment"] = ["start": beforeEnvironment, "end": afterEnvironment]
        if beforeEnvironment["powerSource"] as? String != afterEnvironment["powerSource"] as? String {
            invalid.insert("Power source changed during this run")
        }
        if beforeEnvironment["powerSource"] as? String == "unknown" { invalid.insert("Runner power source could not be identified") }
        report["perCard"] = finalCards(workspace: workspace, expected: ready.expectedCards)
        let formalReceipts = tracker.receipts.filter { $0.uptime >= begin.uptimeNanoseconds && $0.uptime <= end.uptimeNanoseconds }
        report["installations"] = ["observationBoundary": "After production catalog install and Overview.receive; not pixels",
            "formalCount": formalReceipts.count, "totalCount": tracker.receipts.count,
            "records": tracker.receipts.map { $0.json(clock: clock) },
            "connectionChanges": tracker.connections.map { value -> [String: Any] in
                ["unixNanoseconds": clock.unix(at: value.uptime), "status": value.status]
            }] as [String: Any]
        for connection in tracker.connections where connection.uptime >= begin.uptimeNanoseconds && connection.uptime <= end.uptimeNanoseconds {
            if connection.status != "connected" { invalid.insert("Runtime connection left connected state during formal measurement") }
        }
        try validateCardShapes(model, workspace: workspace)
        report["stage"] = "measured"
    }

    private func scheduleCPU(_ name: String, deadline: UInt64) -> ScheduledCPUSample {
        let capture = ScheduledCPUSample(name: name, deadline: deadline, queue: cpuQueue)
        cpuCaptures[name] = capture
        return capture
    }

    private func validateCPUOffset(_ sample: CPUSample, capture: ScheduledCPUSample) {
        let offset = Double(Int64(sample.uptimeNanoseconds) - Int64(capture.plannedUptimeNanoseconds)) / 1e6
        if offset < -1 || offset > 50 {
            invalid.insert("\(capture.name) CPU boundary missed its declared time: \(offset) ms")
        }
    }

    private func updateCPUClockReport() {
        guard !cpuCaptures.isEmpty else { return }
        var value = report["clock"] as? [String: Any] ?? ["anchor": clock.json]
        for (name, capture) in cpuCaptures { value[name] = capture.json(clock: clock) }
        report["clock"] = value
    }

    private func observationTiming(planned: UInt64, started: UInt64, finished: UInt64) -> [String: Any] {
        ["plannedUptimeNanoseconds": planned, "startedUptimeNanoseconds": started,
            "finishedUptimeNanoseconds": finished, "startedUnixNanoseconds": clock.unix(at: started),
            "finishedUnixNanoseconds": clock.unix(at: finished),
            "latenessMilliseconds": Double(Int64(started) - Int64(planned)) / 1e6,
            "durationMilliseconds": Double(finished - started) / 1e6,
            "executor": "MainActor"]
    }

    private func sleepUntil(_ deadline: UInt64) async throws {
        let now = monotonicNanoseconds()
        if deadline > now { try await Task.sleep(nanoseconds: deadline - now) }
        try Task.checkCancellation()
    }

    private func waitForStableLayout(model: NativeOverviewWorkspaceModel, workspace: NativeWorkspaceModel) async throws {
        let deadline = monotonicNanoseconds() + 30_000_000_000
        var stable = 0
        var last: [NativeOverviewPlacement] = []
        while monotonicNanoseconds() < deadline {
            if let error = model.error ?? model.canvasState.layoutError { throw ProbeFailure(description: "Overview failed: \(error)") }
            let state = model.canvasState
            if workspace.runtimeAvailable && workspace.catalog.threads.count == 40 && model.items.count == 40
                && state.mountedCardIDs.count == 40 && state.presentedPlacements.count == 40
                && !state.isLayingOut && state.camera.isInitialized && !state.camera.isAnimating
                && state.presentedPlacements == last {
                stable += 1
                if stable == 10 { return }
            } else { stable = 0 }
            last = state.presentedPlacements
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        report["startupCounters"] = countersJSON(model)
        report["startupConnection"] = workspace.connection.rawValue
        report["startupConnectionError"] = workspace.connectionError.map { $0 as Any } ?? NSNull()
        throw ProbeFailure(description: "Production Overview did not reach stable N40 geometry before timeout")
    }

    private func setFixedCamera(_ model: NativeOverviewWorkspaceModel) throws {
        let state = model.canvasState
        let active = state.presentedPlacements.filter { (0..<4).map { "card-\($0)" }.contains($0.id) }
        guard active.count == 4, let viewport = state.camera.viewport else { throw ProbeFailure(description: "Missing active card geometry") }
        let bounds = active.reduce(CGRect.null) { $0.union($1.cardFrame) }
        let region = NativeOverviewCameraGeometry.contentRegion(viewport)
        let scale = 0.85
        let transform = NativeOverviewTransform(scale: scale,
            x: region.left + region.width / 2 - bounds.midX * scale,
            y: region.top + region.height / 2 - bounds.midY * scale)
        state.camera.setManualTransform(transform)
        guard state.camera.liveTransform == transform, state.camera.manual else {
            throw ProbeFailure(description: "Production camera could not accept fixed scale 0.85")
        }
        requestedCamera = transform
    }

    private func validateCardShapes(_ model: NativeOverviewWorkspaceModel, workspace: NativeWorkspaceModel) throws {
        for index in 0..<40 {
            let id = "card-\(index)"
            guard let item = model.items.first(where: { $0.id == id }),
                  let thread = workspace.catalog.thread(JSONText(id)), item.rows == 1,
                  item.columns == (index < 4 ? 2 : 1),
                  thread.observation.latestExecution?.status == (index < 4 ? .running : .completed) else {
                throw ProbeFailure(description: "Production fixture footprint/status mismatch at \(id)")
            }
        }
    }

    private func windowSample(label: String, model: NativeOverviewWorkspaceModel, window: NSWindow, reject: Bool,
                              plannedUptime: UInt64? = nil) throws -> [String: Any] {
        let started = monotonicNanoseconds()
        let footprint = try physicalFootprint()
        if label != "beforeWarmup" { footprints.append(footprint) }
        let visibility = visibilityJSON(model)
        let insideScreen = window.screen.map { $0.visibleFrame.insetBy(dx: -0.5, dy: -0.5).contains(window.frame) } ?? false
        let state = model.canvasState
        var reasons: [String] = []
        if !window.isVisible { reasons.append("window-not-visible") }
        if !window.isKeyWindow { reasons.append("window-not-key") }
        if !window.isMainWindow { reasons.append("window-not-main") }
        if !NSApp.isActive { reasons.append("application-not-active") }
        if !window.occlusionState.contains(.visible) { reasons.append("window-occluded") }
        if !insideScreen { reasons.append("window-not-contained-in-visible-display") }
        if visibility["allFull"] as? Bool != true { reasons.append("active-card-not-fully-visible") }
        if !state.camera.manual || state.camera.isAnimating || state.camera.hasScheduledMotion || state.camera.liveTransform != requestedCamera {
            reasons.append("camera-not-fixed")
        }
        if state.isLayingOut || state.mountedCardIDs.count != 40 { reasons.append("geometry-not-stable-N40") }
        if model.workspace.connection != .connected || model.workspace.synchronizing { reasons.append("runtime-not-ready") }
        if ProcessInfo.processInfo.thermalState.rawValue != 0 { reasons.append("thermal-state-not-nominal") }
        if ProcessInfo.processInfo.isLowPowerModeEnabled { reasons.append("low-power-mode-enabled") }
        if reject { for reason in reasons { invalid.insert("\(label): \(reason)") } }
        let finished = monotonicNanoseconds()
        return ["label": label, "unixNanoseconds": clock.unix(at: started),
            "observationTiming": observationTiming(planned: plannedUptime ?? started, started: started, finished: finished),
            "visible": window.isVisible, "key": window.isKeyWindow, "main": window.isMainWindow,
            "active": NSApp.isActive, "occlusionVisible": window.occlusionState.contains(.visible),
            "insideVisibleScreen": insideScreen, "windowFrame": rectangleJSON(window.frame),
            "contentSize": rectangleJSON(window.contentView?.bounds ?? .zero),
            "visibility": visibility, "physicalFootprintBytes": footprint,
            "thermalState": ProcessInfo.processInfo.thermalState.rawValue,
            "lowPowerMode": ProcessInfo.processInfo.isLowPowerModeEnabled, "invalidReasons": reasons]
    }

    private func comparisonIdentity(model: NativeOverviewWorkspaceModel, window: NSWindow, expected: [ExpectedCard]) throws -> [String: Any] {
        let fixture = expected.sorted { $0.id < $1.id }.map {
            ["id": $0.id, "sequence": $0.seq, "textSHA256": $0.textSHA256, "textLength": $0.textLength] as [String: Any]
        }
        let fixtureHash = sha256(try JSONSerialization.data(withJSONObject: fixture, options: [.sortedKeys]))
        guard let screen = window.screen else { throw ProbeFailure(description: "Window is not attached to a real display") }
        let transform = model.canvasState.camera.liveTransform
        return ["condition": options.condition, "n": options.n, "k": 4, "seed": options.seed,
            "fixtureSHA256": fixtureHash, "contentSize": rectangleJSON(window.contentView?.bounds ?? .zero),
            "camera": ["scale": transform.scale, "x": transform.x, "y": transform.y],
            "activeCards": visibilityJSON(model)["activeCards"]!, "screen": screenJSON(screen),
            "appearance": "dark", "glass": true, "locale": "zh-CN",
            "reduceMotion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            "reduceTransparency": NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency]
    }

    private func observeTail(model: NativeOverviewWorkspaceModel, workspace: NativeWorkspaceModel, expected: [ExpectedCard]) async throws -> UInt64 {
        let started = monotonicNanoseconds(), deadline = started + 5_000_000_000
        var stable = 0, count = 0, previousRevision = -1
        var sourceComplete = false
        var convergenceUptime: UInt64?
        while monotonicNanoseconds() < deadline {
            if !sourceComplete {
                let status = try JSONSerialization.jsonObject(with: await core.request("status")) as? [String: Any]
                sourceComplete = status?["sourceComplete"] as? Bool == true
            }
            let converged = expected.allSatisfy { workspace.catalog.thread(JSONText($0.id))?.revision == $0.revision }
            if sourceComplete && converged && convergenceUptime == nil { convergenceUptime = monotonicNanoseconds() }
            let revision = workspace.catalog.revision
            if sourceComplete && converged && !model.canvasState.isLayingOut && revision == previousRevision { stable += 1 }
            else { stable = 0 }
            count += 1; previousRevision = revision
            if stable == 10 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let ended = monotonicNanoseconds()
        report["tailObservation"] = ["seconds": Double(ended - started) / 1e9,
            "startedUptimeNanoseconds": started, "endedUptimeNanoseconds": ended,
            "startedUnixNanoseconds": clock.unix(at: started), "endedUnixNanoseconds": clock.unix(at: ended),
            "observationBudgetSeconds": 5, "sampleIntervalMilliseconds": 50,
            "requiredStableSamples": 10, "stableSamples": stable, "sampleCount": count,
            "sourceComplete": sourceComplete,
            "firstObservedModelConvergenceUnixNanoseconds": convergenceUptime.map { clock.unix(at: $0) as Any } ?? NSNull(),
            "meaning": "Post-supply model stability observation, not queue drain duration or pixel presentation"] as [String: Any]
        if !sourceComplete || stable < 10 { invalid.insert("Source/final model did not converge within the tail observation budget") }
        return ended
    }

    private func finalCards(workspace: NativeWorkspaceModel, expected: [ExpectedCard]) -> [[String: Any]] {
        expected.map { expected in
            guard let thread = workspace.catalog.thread(JSONText(expected.id)) else {
                invalid.insert("Final card missing: \(expected.id)"); return ["id": expected.id, "valid": false]
            }
            let messages = (thread.sessionState["turns"]?.arrayValue ?? []).flatMap { $0["timeline"]?.arrayValue ?? [] }
            let message = messages.first { $0["kind"]?.stringValue == "assistant" && $0["itemId"]?.stringValue == expected.itemID }
            let text = message?["content"]?.stringValue ?? ""
            let hash = sha256(Data(text.utf8)), messageID = message?["id"]?.stringValue ?? ""
            let valid = thread.revision == expected.revision && hash == expected.textSHA256
                && text.utf8.count == expected.textLength && messageID == expected.messageID
            if !valid { invalid.insert("Final sequence/message/hash mismatch: \(expected.id)") }
            return ["id": expected.id, "seq": thread.revision - 1, "revision": thread.revision,
                "messageID": messageID, "itemID": expected.itemID, "textSHA256": hash, "textLength": text.utf8.count,
                "expectedSeq": expected.seq, "expectedTextSHA256": expected.textSHA256, "valid": valid]
        }
    }

    private func validateDelivery(_ coreResult: [String: Any]) {
        guard let start = formalStart, let end = formalEnd else { return }
        guard let publications = coreResult["publications"] as? [[String: Any]] else {
            invalid.insert("Core publication evidence is missing"); return
        }
        let first = clock.unix(at: start.uptimeNanoseconds), last = clock.unix(at: end.uptimeNanoseconds)
        var installs: [Int: InstallReceipt] = [:]
        for receipt in tracker.receipts where installs[receipt.revision] == nil { installs[receipt.revision] = receipt }
        var missing: [Int] = [], latency: [Double] = []
        var publicationCount = 0
        for publication in publications {
            guard let at = (publication["publishedUnixNano"] as? NSNumber)?.int64Value,
                  let revision = (publication["revision"] as? NSNumber)?.intValue else {
                invalid.insert("A Core publication lacks timestamp/revision"); continue
            }
            guard at >= first, at < last else { continue }
            publicationCount += 1
            if let install = installs[revision] {
                latency.append(Double(clock.unix(at: install.uptime) - at) / 1e6)
            } else { missing.append(revision) }
        }
        if !missing.isEmpty { invalid.insert("Formal publications were not installed by the model: \(missing)") }
        if options.condition != "R0" && publicationCount == 0 { invalid.insert("No content publications occurred during the formal window") }
        var cards: [[String: Any]] = []
        for card in 0..<4 {
            var previous = -2, times: [UInt64] = []
            for receipt in tracker.receipts {
                let next = receipt.sequences[card]
                if next != previous && receipt.uptime >= start.uptimeNanoseconds && receipt.uptime < end.uptimeNanoseconds {
                    times.append(receipt.uptime)
                }
                previous = next
            }
            let gaps = zip(times, times.dropFirst()).map { pair in Double(pair.1 - pair.0) / 1e6 }
            cards.append(["id": "card-\(card)", "formalSequenceChanges": times.count,
                "longestIntervalBetweenChangesMilliseconds": gaps.max() ?? 0])
        }
        let sorted = latency.sorted()
        func quantile(_ fraction: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            return sorted[min(sorted.count - 1, max(0, Int(ceil(Double(sorted.count) * fraction)) - 1))]
        }
        report["delivery"] = ["publicationWindow": "Published within the actual UI CPU boundaries; installed before tail completion",
            "publishedRevisions": publicationCount, "matchedInstalledRevisions": latency.count,
            "missingRevisions": missing, "publishToModelInstallMilliseconds": ["p50": quantile(0.5), "p95": quantile(0.95), "max": sorted.last ?? 0],
            "perCard": cards, "meaning": "Catalog admission, not display updates or pixels"] as [String: Any]
    }
}

@MainActor
private final class ProbeDelegate: NSObject, NSApplicationDelegate {
    let options: ProbeOptions
    var probe: OverviewProbe?
    init(options: ProbeOptions) { self.options = options }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let probe = OverviewProbe(options: options)
        self.probe = probe
        Task { @MainActor in exit(await probe.run()) }
    }
}

@main
struct OverviewCIPerformanceMain {
    @MainActor static func main() {
        do {
            try prepareIsolatedNativeReplay()
            let options = try ProbeOptions(arguments: Array(CommandLine.arguments.dropFirst()))
            let app = NSApplication.shared
            let delegate = ProbeDelegate(options: options)
            app.setActivationPolicy(.regular)
            app.delegate = delegate
            withExtendedLifetime(delegate) { app.run() }
        } catch { fputs("Overview CI probe failed: \(error)\n", stderr); exit(1) }
    }
}
