import AppKit
import CryptoKit
import Darwin
import Foundation
import Metal
import MokuseiCore
import MokuseiPluginAPI
import QuartzCore
import Synchronization
@testable import MokuseiUI

struct ProbeFailure: Error, CustomStringConvertible {
    let description: String
}

struct ProbeOptions {
    let condition: String
    let n: Int
    let warmup: Double
    let seconds: Double
    let seed: Int
    let runtime: URL
    let output: URL

    init(arguments: [String]) throws {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            guard arguments[index].hasPrefix("--"), index + 1 < arguments.count,
                  values[arguments[index]] == nil else {
                throw ProbeFailure(description: "Expected unique --name value arguments")
            }
            values[arguments[index]] = arguments[index + 1]
            index += 2
        }
        let names: Set<String> = ["--condition", "--n", "--warmup", "--seconds", "--seed", "--runtime", "--output"]
        guard Set(values.keys).isSubset(of: names),
              let condition = values["--condition"], ["R0", "S4", "A4"].contains(condition),
              let n = Int(values["--n"] ?? "40"), n == 40,
              let warmup = Double(values["--warmup"] ?? "5"), warmup == 5,
              let seconds = Double(values["--seconds"] ?? "20"), seconds == 20,
              let seed = Int(values["--seed"] ?? "198"), seed >= 0,
              let runtime = values["--runtime"], runtime.hasPrefix("/"),
              let output = values["--output"], output.hasPrefix("/") else {
            throw ProbeFailure(description: "Requires R0|S4|A4, N40, 5s warmup, 20s formal, and absolute runtime/output paths")
        }
        self.condition = condition; self.n = n; self.warmup = warmup
        self.seconds = seconds; self.seed = seed
        self.runtime = URL(fileURLWithPath: runtime)
        self.output = URL(fileURLWithPath: output)
    }
}

func monotonicNanoseconds() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

func realtimeNanoseconds() -> Int64 {
    var value = timespec()
    clock_gettime(CLOCK_REALTIME, &value)
    return Int64(value.tv_sec) * 1_000_000_000 + Int64(value.tv_nsec)
}

struct ProbeClock: Sendable {
    let unixNanoseconds: Int64
    let uptimeNanoseconds: UInt64
    let uncertaintyNanoseconds: UInt64

    init() {
        let before = monotonicNanoseconds()
        unixNanoseconds = realtimeNanoseconds()
        let after = monotonicNanoseconds()
        uptimeNanoseconds = before + (after - before) / 2
        uncertaintyNanoseconds = (after - before) / 2
    }

    func unix(at uptime: UInt64) -> Int64 {
        unixNanoseconds + Int64(uptime) - Int64(uptimeNanoseconds)
    }

    func deadline(unix: Int64) throws -> UInt64 {
        let value = Int64(uptimeNanoseconds) + unix - unixNanoseconds
        guard value >= 0 else { throw ProbeFailure(description: "Scheduled boundary predates the monotonic clock") }
        return UInt64(value)
    }

    var json: [String: Any] {
        ["unixNanoseconds": unixNanoseconds, "uptimeNanoseconds": uptimeNanoseconds,
         "uncertaintyNanoseconds": uncertaintyNanoseconds]
    }
}

struct CPUSample: Sendable {
    let userSeconds: Double
    let systemSeconds: Double
    let uptimeNanoseconds: UInt64
    let readNanoseconds: UInt64
    var cpuSeconds: Double { userSeconds + systemSeconds }

    static func capture() throws -> CPUSample {
        let before = monotonicNanoseconds()
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else {
            throw ProbeFailure(description: "getrusage failed with errno \(errno)")
        }
        let after = monotonicNanoseconds()
        return CPUSample(userSeconds: Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6,
            systemSeconds: Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6,
            uptimeNanoseconds: before + (after - before) / 2, readNanoseconds: after - before)
    }

    func json(clock: ProbeClock, expectedUnix: Int64) -> [String: Any] {
        ["userSeconds": userSeconds, "systemSeconds": systemSeconds,
         "uptimeNanoseconds": uptimeNanoseconds, "unixNanoseconds": clock.unix(at: uptimeNanoseconds),
         "readNanoseconds": readNanoseconds,
         "boundaryOffsetMilliseconds": Double(clock.unix(at: uptimeNanoseconds) - expectedUnix) / 1e6]
    }
}

/// A scheduled read owns its completion independently of the MainActor waiter.
/// All fixed boundaries are enqueued before source warmup; UI stalls can delay
/// consuming the result, but cannot move the next process-CPU boundary.
final class ScheduledCPUSample: Sendable {
    private struct State: Sendable {
        var started: UInt64?
        var finished: UInt64?
        var cancelled: UInt64?
        var result: Result<CPUSample, ProbeFailure>?
        var waiters: [CheckedContinuation<CPUSample, any Error>] = []
    }

    let name: String
    let plannedUptimeNanoseconds: UInt64
    let requestedUptimeNanoseconds: UInt64
    private let state = Mutex(State())
    private let timer: any DispatchSourceTimer

    init(name: String, deadline: UInt64, queue: DispatchQueue) {
        self.name = name
        plannedUptimeNanoseconds = deadline
        requestedUptimeNanoseconds = monotonicNanoseconds()
        // asyncAfter has deadline-dependent coalescing. A long pre-scheduled
        // formal interval must not inherit that implicit timing allowance.
        timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.setEventHandler { [weak self] in self?.capture() }
        timer.schedule(deadline: DispatchTime(uptimeNanoseconds: deadline), repeating: .never, leeway: .nanoseconds(0))
        timer.activate()
    }

    deinit { timer.cancel() }

    func value() async throws -> CPUSample {
        try Task.checkCancellation()
        let sample = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CPUSample, any Error>) in
                let completed = state.withLock { value -> Result<CPUSample, ProbeFailure>? in
                    if let result = value.result { return result }
                    value.waiters.append(continuation)
                    return nil
                }
                if let completed {
                    switch completed {
                    case let .success(sample): continuation.resume(returning: sample)
                    case let .failure(error): continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: { cancel() }
        try Task.checkCancellation()
        return sample
    }

    func cancel() {
        timer.cancel()
        let result: Result<CPUSample, ProbeFailure> = .failure(.init(description: "CPU capture \(name) cancelled"))
        let waiters = state.withLock { value -> [CheckedContinuation<CPUSample, any Error>] in
            guard value.result == nil else { return [] }
            value.cancelled = monotonicNanoseconds()
            value.result = result
            let waiters = value.waiters
            value.waiters.removeAll()
            return waiters
        }
        for waiter in waiters { waiter.resume(throwing: ProbeFailure(description: "CPU capture \(name) cancelled")) }
    }

    private func capture() {
        defer { timer.cancel() }
        let shouldCapture = state.withLock { value in
            guard value.result == nil, value.started == nil else { return false }
            value.started = monotonicNanoseconds()
            return true
        }
        guard shouldCapture else { return }
        let result: Result<CPUSample, ProbeFailure>
        do { result = .success(try CPUSample.capture()) }
        catch { result = .failure(.init(description: "CPU capture \(name) failed: \(error)")) }
        let finished = monotonicNanoseconds()
        let waiters = state.withLock { value -> [CheckedContinuation<CPUSample, any Error>] in
            // Cancellation may win while getrusage is in progress. It resolves
            // each waiter once and prevents the late read replacing a failure.
            guard value.result == nil else { return [] }
            value.finished = finished
            value.result = result
            let waiters = value.waiters
            value.waiters.removeAll()
            return waiters
        }
        for waiter in waiters {
            switch result {
            case let .success(sample): waiter.resume(returning: sample)
            case let .failure(error): waiter.resume(throwing: error)
            }
        }
    }

    func json(clock: ProbeClock) -> [String: Any] {
        let snapshot = state.withLock { ($0.started, $0.finished, $0.cancelled, $0.result) }
        let expectedUnix = clock.unix(at: plannedUptimeNanoseconds)
        var value: [String: Any] = ["name": name, "executor": "dedicated-dispatch-queue",
            "timerFlags": "strict", "timerLeewayNanoseconds": 0,
            "plannedUptimeNanoseconds": plannedUptimeNanoseconds, "plannedUnixNanoseconds": expectedUnix,
            "requestedUptimeNanoseconds": requestedUptimeNanoseconds,
            "callbackStartedUptimeNanoseconds": snapshot.0.map { $0 as Any } ?? NSNull(),
            "callbackFinishedUptimeNanoseconds": snapshot.1.map { $0 as Any } ?? NSNull(),
            "cancelledUptimeNanoseconds": snapshot.2.map { $0 as Any } ?? NSNull()]
        if let started = snapshot.0 {
            value["callbackLatenessMilliseconds"] = Double(Int64(started) - Int64(plannedUptimeNanoseconds)) / 1e6
        }
        switch snapshot.3 {
        case let .some(.success(sample)):
            value.merge(sample.json(clock: clock, expectedUnix: expectedUnix)) { _, sample in sample }
            value["status"] = "captured"
        case let .some(.failure(error)):
            value["status"] = snapshot.2 == nil ? "failed" : "cancelled"
            value["error"] = error.description
        case nil:
            value["status"] = snapshot.0 == nil ? "scheduled" : "capturing"
        }
        return value
    }
}

func cpuInterval(from start: CPUSample, to end: CPUSample, meaning: String) throws -> [String: Any] {
    guard end.uptimeNanoseconds > start.uptimeNanoseconds,
          end.userSeconds >= start.userSeconds, end.systemSeconds >= start.systemSeconds else {
        throw ProbeFailure(description: "Process CPU samples are not monotonic")
    }
    let elapsed = Double(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
    return ["cpuSeconds": end.cpuSeconds - start.cpuSeconds,
        "userSeconds": end.userSeconds - start.userSeconds, "systemSeconds": end.systemSeconds - start.systemSeconds,
        "wallSeconds": elapsed, "cpuPercent": 100 * (end.cpuSeconds - start.cpuSeconds) / elapsed,
        "startUptimeNanoseconds": start.uptimeNanoseconds, "endUptimeNanoseconds": end.uptimeNanoseconds,
        "meaning": meaning]
}

func physicalFootprint() throws -> UInt64 {
    var vm = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &vm) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    guard status == KERN_SUCCESS else { throw ProbeFailure(description: "TASK_VM_INFO failed: \(status)") }
    return vm.phys_footprint
}

func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func writeJSON(_ value: [String: Any], to url: URL) throws {
    try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        .write(to: url, options: .atomic)
}

func rectangleJSON(_ value: CGRect) -> [String: Double] {
    ["x": value.minX, "y": value.minY, "width": value.width, "height": value.height]
}

private func systemString(_ name: String) -> String {
    var count = 0
    guard sysctlbyname(name, nil, &count, nil, 0) == 0, count > 0 else { return "unavailable" }
    var bytes = [UInt8](repeating: 0, count: count)
    guard sysctlbyname(name, &bytes, &count, nil, 0) == 0 else { return "unavailable" }
    return String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
}

@MainActor
func screenJSON(_ screen: NSScreen) -> [String: Any] {
    ["displayID": (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0,
     "frame": rectangleJSON(screen.frame), "visibleFrame": rectangleJSON(screen.visibleFrame),
     "backingScale": screen.backingScaleFactor, "maximumFramesPerSecond": screen.maximumFramesPerSecond]
}

@MainActor
func environmentJSON() -> [String: Any] {
    // These subprocesses run before warmup and after the formal CPU boundary.
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    process.arguments = ["-g", "batt"]
    process.standardOutput = pipe; process.standardError = pipe
    var power = "unavailable"
    if (try? process.run()) != nil {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        power = String(decoding: data, as: UTF8.self)
    }
    let powerSource = power.contains("'AC Power'") ? "AC Power"
        : (power.contains("'Battery Power'") ? "Battery Power" : "unknown")
    return ["unixNanoseconds": realtimeNanoseconds(), "machineModel": systemString("hw.model"),
        "cpuModel": systemString("machdep.cpu.brand_string"),
        "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
        "logicalCPUCount": ProcessInfo.processInfo.processorCount,
        "physicalMemoryBytes": ProcessInfo.processInfo.physicalMemory,
        "thermalState": ProcessInfo.processInfo.thermalState.rawValue,
        "lowPowerMode": ProcessInfo.processInfo.isLowPowerModeEnabled,
        "reduceMotion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
        "reduceTransparency": NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
        "screens": NSScreen.screens.map { screenJSON($0) }, "powerSource": powerSource, "powerDetails": power,
        "gpuName": MTLCreateSystemDefaultDevice()?.name ?? "unavailable"]
}

@MainActor
func cameraJSON(_ camera: NativeOverviewCamera) -> [String: Any] {
    let transform = camera.liveTransform
    return ["scale": transform.scale, "x": transform.x, "y": transform.y,
        "manual": camera.manual, "isAnimating": camera.isAnimating,
        "minimumScale": camera.minimumScale, "hasScheduledMotion": camera.hasScheduledMotion,
        "hasPendingAutomaticFit": camera.hasPendingAutomaticFit]
}

@MainActor
func countersJSON(_ model: NativeOverviewWorkspaceModel) -> [String: Any] {
    let state = model.canvasState
    return ["catalogRevision": model.workspace.catalog.revision,
        "membershipBuildCount": model.membershipBuildCount, "recoveryEpoch": model.recoveryEpoch,
        "bodyEvaluationCount": state.bodyEvaluationCount, "sceneSnapshotCount": state.sceneSnapshotCount,
        "layoutSolveCount": state.layoutSolveCount, "geometryReuseCount": state.geometryReuseCount,
        "repackCount": state.repackCount, "structureRevision": model.content.structureRevision,
        "itemCount": model.items.count, "mountedCount": state.mountedCardIDs.count,
        "placementCount": state.presentedPlacements.count, "isLayingOut": state.isLayingOut,
        "layoutError": state.layoutError.map { $0 as Any } ?? NSNull(), "modelError": model.error.map { $0 as Any } ?? NSNull()]
}

@MainActor
func visibilityJSON(_ model: NativeOverviewWorkspaceModel) -> [String: Any] {
    guard let viewport = model.canvasState.camera.viewport else {
        return ["allFull": false, "reason": "No camera viewport", "activeCards": []]
    }
    let region = NativeOverviewCameraGeometry.contentRegion(viewport)
    let clip = CGRect(x: region.left, y: region.top, width: region.width, height: region.height)
    let transform = model.canvasState.camera.liveTransform
    let activeIDs = Set((0..<4).map { "card-\($0)" })
    var active: [[String: Any]] = []
    var fullIDs: [String] = [], partialIDs: [String] = []
    for placement in model.canvasState.presentedPlacements {
        // Use the same production placement geometry as the mounted canvas.
        let world = placement.cardFrame
        let screen = CGRect(x: world.minX * transform.scale + transform.x,
            y: world.minY * transform.scale + transform.y,
            width: world.width * transform.scale, height: world.height * transform.scale)
        let full = clip.insetBy(dx: -0.25, dy: -0.25).contains(screen)
        if full { fullIDs.append(placement.id) }
        else if clip.intersects(screen) { partialIDs.append(placement.id) }
        if activeIDs.contains(placement.id) {
            active.append(["id": placement.id, "worldFrame": rectangleJSON(world),
                "screenFrame": rectangleJSON(screen), "columns": placement.columns, "rows": placement.rows,
                "structureKey": model.items.first(where: { $0.id == placement.id })?.structureKey ?? "missing",
                "full": full])
        }
    }
    active.sort { ($0["id"] as? String ?? "") < ($1["id"] as? String ?? "") }
    return ["allFull": active.count == 4 && active.allSatisfy { $0["full"] as? Bool == true },
        "activeCards": active, "fullIDs": fullIDs.sorted(), "partialIDs": partialIDs.sorted(),
        "contentRegion": rectangleJSON(clip), "camera": cameraJSON(model.canvasState.camera)]
}

@MainActor
func nativeDecorationJSON(_ root: NSView) -> [String: Any] {
    var clouds = 0, scans = 0, legacy = 0, activeMetal = 0, scanAnimations = 0
    var surfaces: [[String: Any]] = []
    @MainActor
    func inspectLayer(_ layer: CALayer, cloud: Bool, scan: Bool) {
        if cloud, let metal = layer as? CAMetalLayer {
            // Keep the layer out of Boolean operators' implicit autoclosures.
            let hidden = metal.isHidden
            let drawableSize = metal.drawableSize
            let hasDevice = metal.device != nil
            if !hidden, drawableSize.width > 0, drawableSize.height > 0, hasDevice {
                activeMetal += 1
            }
            surfaces.append(["hidden": hidden, "drawableWidth": drawableSize.width,
                "drawableHeight": drawableSize.height, "device": metal.device?.name ?? "unavailable",
                "opaque": metal.isOpaque, "presentsWithTransaction": metal.presentsWithTransaction])
        }
        if scan, layer.animation(forKey: "overview.scan.position") != nil { scanAnimations += 1 }
        for child in layer.sublayers ?? [] { inspectLayer(child, cloud: cloud, scan: scan) }
    }
    @MainActor
    func visit(_ view: NSView) {
        let name = String(describing: type(of: view))
        let cloud = name.contains("NativeOverviewCloudSurface")
        let scan = name.contains("NativeCardScanView")
        if cloud { clouds += 1 }
        if scan { scans += 1 }
        if name.contains("NativeCardDecorationContainer") || name.contains("NativeCardDecorationHostingView") { legacy += 1 }
        if (cloud || scan), let layer = view.layer { inspectLayer(layer, cloud: cloud, scan: scan) }
        for child in view.subviews { visit(child) }
    }
    visit(root)
    return ["nativeCloudSurfaceCount": clouds, "nativeScanViewCount": scans,
        "legacyDecorationHostCount": legacy, "activeMetalLayerCount": activeMetal,
        "scanAnimationCount": scanAnimations, "metalSurfaces": surfaces,
        "nativePathActive": clouds == 40 && scans == 4 && activeMetal == 4 && scanAnimations == 4 && legacy == 0,
        "evidenceKind": "Mounted native classes, drawable geometry and live CA animation keys; no presented-frame or pixel claim"]
}

struct InstallReceipt {
    let uptime: UInt64
    let revision: Int
    let sequences: [Int]
    let kind: String
    func json(clock: ProbeClock) -> [String: Any] {
        ["uptimeNanoseconds": uptime, "unixNanoseconds": clock.unix(at: uptime),
         "catalogRevision": revision, "sequences": sequences, "kind": kind]
    }
}

@MainActor
final class InstallationTracker {
    let ids = (0..<4).map { JSONText("card-\($0)") }
    var receipts: [InstallReceipt] = []
    var connections: [(uptime: UInt64, status: String)] = []

    init() { receipts.reserveCapacity(1200); connections.reserveCapacity(16) }

    func record(_ event: RuntimeClientEvent, catalog: NativeWorkspaceCatalog) {
        let kind: String
        switch event {
        case .snapshot: kind = "snapshot"
        case .mutation: kind = "mutation"
        default: return
        }
        receipts.append(.init(uptime: monotonicNanoseconds(), revision: catalog.revision,
            sequences: ids.map { catalog.thread($0).map { $0.revision - 1 } ?? -2 }, kind: kind))
    }

    func connection(_ status: RuntimeConnectionStatus) {
        guard connections.last?.status != status.rawValue else { return }
        connections.append((monotonicNanoseconds(), status.rawValue))
    }
}
