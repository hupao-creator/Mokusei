// Verification-only Overview scale harness support. Not part of the app target.
import AppKit
import CoreGraphics
import Darwin
import Foundation
import Observation
import SwiftUI
import Synchronization
import MokuseiPluginAPI
import MokuseiHarnessCodex
@testable import MokuseiCore
@testable import MokuseiUI

struct ScaleFailure: Error, CustomStringConvertible { let description: String }

func nowNs() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
func nsToMs(_ value: UInt64) -> Double { Double(value) / 1e6 }

func sysctlString(_ name: String) -> String {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "" }
    return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
}

struct ScaleArguments {
    var mode = ""
    var output: URL?
    var n = 40
    var hz = 10.0
    var seconds = 20.0
    var warmup = 5.0
    var target = "visible"
    var running = "none"
    var reps = 1
    var scenario = "remove-all"
    var updates = 200
    var label = ""
    var glass = true
    var appearance = "system"
    var sequence = "content"
    var supply = "coupled"
    var overviewVisible = true

    init() throws {
        var arguments = Array(CommandLine.arguments.dropFirst())
        var index = 0
        while index < arguments.count {
            let key = arguments[index]
            guard key.hasPrefix("--"), index + 1 < arguments.count else {
                throw ScaleFailure(description: "Expected --key value, got \(key)")
            }
            let value = arguments[index + 1]
            index += 2
            switch key {
            case "--mode": mode = value
            case "--output": output = URL(fileURLWithPath: value)
            case "--n":
                guard let parsed = Int(value) else { throw ScaleFailure(description: "--n must be an integer") }
                n = parsed
            case "--hz":
                guard let parsed = Double(value) else { throw ScaleFailure(description: "--hz must be a number") }
                hz = parsed
            case "--seconds":
                guard let parsed = Double(value) else { throw ScaleFailure(description: "--seconds must be a number") }
                seconds = parsed
            case "--warmup":
                guard let parsed = Double(value) else { throw ScaleFailure(description: "--warmup must be a number") }
                warmup = parsed
            case "--target": target = value
            case "--running": running = value
            case "--reps":
                guard let parsed = Int(value) else { throw ScaleFailure(description: "--reps must be an integer") }
                reps = parsed
            case "--scenario": scenario = value
            case "--updates":
                guard let parsed = Int(value) else { throw ScaleFailure(description: "--updates must be an integer") }
                updates = parsed
            case "--label": label = value
            case "--glass": glass = !(value == "0" || value.lowercased() == "false" || value.lowercased() == "off")
            case "--appearance": appearance = value
            case "--sequence":
                guard value == "content" || value == "no-change" else {
                    throw ScaleFailure(description: "--sequence must be content or no-change")
                }
                sequence = value
            case "--supply":
                guard value == "coupled" || value == "independent" else {
                    throw ScaleFailure(description: "--supply must be coupled or independent")
                }
                supply = value
            case "--overview-visible":
                overviewVisible = !(value == "0" || value.lowercased() == "false" || value.lowercased() == "off")
            default: throw ScaleFailure(description: "Unknown argument \(key)")
            }
        }
        guard !mode.isEmpty else { throw ScaleFailure(description: "--mode is required") }
    }
}

func writeJSON(_ value: [String: Any], to url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url)
}

func plain<T: Encodable>(_ value: T) -> Any {
    (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(value))) ?? [:]
}

func jsonOrNull<T>(_ value: T?) -> Any { value.map { $0 as Any } ?? NSNull() }

func percentile(_ values: [Double], _ fraction: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let position = fraction * Double(sorted.count - 1)
    let lower = Int(position.rounded(.down)), upper = Int(position.rounded(.up))
    if lower == upper { return sorted[lower] }
    return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - Double(lower))
}

func stats(_ values: [Double]) -> [String: Any] {
    guard !values.isEmpty else { return ["count": 0] }
    return ["count": values.count, "medianMs": percentile(values, 0.5), "p95Ms": percentile(values, 0.95),
            "minMs": values.min()!, "maxMs": values.max()!, "meanMs": values.reduce(0, +) / Double(values.count)]
}

struct ResourceSample {
    let unix: Double
    let uptimeNs: UInt64
    let userSeconds: Double
    let systemSeconds: Double
    let residentBytes: UInt64
    let physicalFootprintBytes: UInt64
    let threadCount: Int
    let interruptWakeups: UInt64
    let platformIdleWakeups: UInt64
    let timerWakeups: UInt64
    let hostCPUTicks: [UInt32]
    let thermalState: Int
    let lowPowerMode: Bool

    var json: [String: Any] {
        ["unix": unix, "userSeconds": userSeconds, "systemSeconds": systemSeconds,
         "residentBytes": Int(residentBytes), "physicalFootprintBytes": Int(physicalFootprintBytes),
         "threadCount": threadCount, "interruptWakeups": Int(interruptWakeups),
         "platformIdleWakeups": Int(platformIdleWakeups), "timerWakeups": Int(timerWakeups),
         "hostCPUTicks": hostCPUTicks.map(Int.init), "thermalState": thermalState,
         "lowPowerMode": lowPowerMode]
    }
}

func resourceSample() throws -> ResourceSample {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw ScaleFailure(description: "getrusage failed") }
    var vm = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let vmStatus = withUnsafeMutablePointer(to: &vm) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    guard vmStatus == KERN_SUCCESS else { throw ScaleFailure(description: "task_info failed: \(vmStatus)") }
    var power = task_power_info_data_t()
    var powerCount = mach_msg_type_number_t(MemoryLayout<task_power_info_data_t>.size / MemoryLayout<integer_t>.size)
    let powerStatus = withUnsafeMutablePointer(to: &power) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(powerCount)) {
            task_info(mach_task_self_, task_flavor_t(TASK_POWER_INFO), $0, &powerCount)
        }
    }
    guard powerStatus == KERN_SUCCESS else { throw ScaleFailure(description: "task_power_info failed: \(powerStatus)") }
    var threads: thread_act_array_t?
    var threadCount: mach_msg_type_number_t = 0
    var countThreads = 0
    if task_threads(mach_task_self_, &threads, &threadCount) == KERN_SUCCESS, let threads {
        countThreads = Int(threadCount)
        for index in 0..<Int(threadCount) {
            mach_port_deallocate(mach_task_self_, threads[index])
        }
        vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threads)),
                      vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.stride))
    }
    var cpu = host_cpu_load_info_data_t()
    var cpuCount = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
    let host = mach_host_self()
    defer { mach_port_deallocate(mach_task_self_, host) }
    let cpuStatus = withUnsafeMutablePointer(to: &cpu) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(cpuCount)) {
            host_statistics(host, HOST_CPU_LOAD_INFO, $0, &cpuCount)
        }
    }
    guard cpuStatus == KERN_SUCCESS else { throw ScaleFailure(description: "host_statistics failed: \(cpuStatus)") }
    return ResourceSample(unix: Date().timeIntervalSince1970, uptimeNs: nowNs(),
        userSeconds: Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6,
        systemSeconds: Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6,
        residentBytes: vm.resident_size, physicalFootprintBytes: vm.phys_footprint,
        threadCount: countThreads, interruptWakeups: power.task_interrupt_wakeups,
        platformIdleWakeups: power.task_platform_idle_wakeups,
        timerWakeups: power.task_timer_wakeups_bin_1 &+ power.task_timer_wakeups_bin_2,
        hostCPUTicks: [cpu.cpu_ticks.0, cpu.cpu_ticks.1, cpu.cpu_ticks.2, cpu.cpu_ticks.3],
        thermalState: ProcessInfo.processInfo.thermalState.rawValue,
        lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
}

final class ResourceSampler: @unchecked Sendable {
    private let samples = Mutex<[ResourceSample]>([])
    private var task: Task<Void, Never>?
    private let interval: Double

    init(interval: Double) { self.interval = interval }

    func start() {
        let interval = interval
        task = Task.detached { [weak self] in
            var next = nowNs()
            while !Task.isCancelled {
                if let self, let sample = try? resourceSample() {
                    self.samples.withLock { $0.append(sample) }
                }
                next &+= UInt64(interval * 1e9)
                let now = nowNs()
                if next > now { try? await Task.sleep(nanoseconds: next - now) }
                else { next = now }
            }
        }
    }

    func stop() async -> [ResourceSample] {
        task?.cancel()
        _ = await task?.value
        task = nil
        return samples.withLock { $0 }
    }
}

struct ReceiveTiming {
    private(set) var samples: [Double] = []
    private(set) var lastMs = 0.0
    mutating func record(_ value: Double) { lastMs = value; samples.append(value) }
}

final class ReceiveBox: @unchecked Sendable {
    var timing = ReceiveTiming()
    func record(_ value: Double) { timing.record(value) }
}

final class LatenessRecorder: @unchecked Sendable {
    private let values = Mutex<[Double]>([])
    func record(_ value: Double) { values.withLock { $0.append(value) } }
    func take() -> [Double] { values.withLock { $0 } }
}

final class OptionalTimeBox: @unchecked Sendable {
    private let stored = Mutex<UInt64?>(nil)
    var value: UInt64? {
        get { stored.withLock { $0 } }
        set { stored.withLock { $0 = newValue } }
    }
}

@MainActor
final class ScaleFixture {
    let n: Int
    let runningIndex: Int?
    let directory: URL
    let workspace: NativeWorkspaceModel
    let model: NativeOverviewWorkspaceModel
    let authority = UUID()
    private let receiveBox: ReceiveBox
    private(set) var baseThreads: [JSONValue] = []
    private(set) var baseSnapshot: JSONValue = .null
    private(set) var revision = 0

    init(n: Int, runningIndex: Int?) throws {
        self.n = n
        self.runningIndex = runningIndex
        let box = ReceiveBox()
        receiveBox = box
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("overview-scale-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let client = RuntimeClient(profile: try RuntimeProfile(dataDirectory: directory))
        let plugins = try NativePluginComposition(harnesses: [AnyHarnessPlugin(CodexHarnessPlugin())],
                                                   sidecards: [], applications: [])
        workspace = NativeWorkspaceModel(client: client,
            preferences: DesktopPreferences(directory: directory), plugins: plugins)
        model = NativeOverviewWorkspaceModel(workspace: workspace, applications: .init(
            projectionCapabilities: { _, _ in throw ScaleFailure(description: "No fixture applications") },
            rendererContext: { _, _, _ in throw ScaleFailure(description: "No fixture applications") }))
        baseThreads = try (0..<n).map { index in
            try Self.thread(index: index, revision: 0, suffix: 0, running: index == runningIndex)
        }
        baseSnapshot = Self.snapshot(threads: baseThreads, revision: 0)
        // installPrepared and model.receive both run on the main actor here.
        // Timing the callback separates model projection from catalog
        // preparation and the actor hop.
        let model = self.model
        workspace.onCatalogChange = { [weak model] event in
            MainActor.assumeIsolated {
                guard let model else { return }
                let start = nowNs()
                model.receive(event)
                box.record(nsToMs(nowNs() - start))
            }
        }
    }

    var receiveTiming: [Double] { receiveBox.timing.samples }
    func resetReceiveTiming() { receiveBox.timing = ReceiveTiming() }

    static func thread(index: Int, revision: Int, suffix: Int, running: Bool) throws -> JSONValue {
        let scope = index % 10, tag = (index / 10) % 5
        let name = "主题 \(tag)"
        return try HarnessThread(id: JSONText("card-\(index)"), harnessID: "codex", revision: revision,
            sessionState: .null,
            observation: .init(latestExecution: try PublicExecution(
                executionID: JSONText("execution-\(index)"),
                status: running ? .running : .completed,
                startedAt: 1, finishedAt: running ? nil : 2)),
            cwd: JSONText("/fixture/目录-\(scope)"), settings: .object([:]), createdAt: Double(index),
            updatedAt: Double(index + 2 + suffix),
            title: JSONText("Card \(index) — 界面设计 Café \(suffix)"),
            tags: [JSONText(name)], tagEmojis: [JSONText(name): "🔧"],
            directoryTag: JSONText("目录-\(scope)"), directoryScope: JSONText("/fixture/目录-\(scope)")).json
    }

    static func snapshot(threads: [JSONValue], revision: Int) -> JSONValue {
        .object(["revision": .integer(revision), "settingsRevision": .integer(0),
            "defaultCwd": .text("/fixture"), "settings": .object([:]), "threads": .array(threads),
            "applicationThreads": .array([]), "executions": .array([])])
    }

    static func mutation(upserts: [JSONValue], removed: [JSONText], base: Int, revision: Int) -> JSONValue {
        .object(["type": .text("state-patched"), "baseRevision": .integer(base), "revision": .integer(revision),
            "threads": .object(["upserts": .array(upserts), "removedIds": .array(removed.map(JSONValue.string))])])
    }

    func installBase() async throws {
        resetReceiveTiming()
        revision = 0
        try await workspace.installPrepared(baseSnapshot, event: .snapshot(baseSnapshot, authority: authority))
        guard model.error == nil else { throw ScaleFailure(description: model.error!) }
        guard model.items.count == n else {
            throw ScaleFailure(description: "Expected \(n) items after install, got \(model.items.count)")
        }
        guard workspace.catalog.revision == 0 else { throw ScaleFailure(description: "Catalog revision mismatch") }
    }

    func install(_ snapshot: JSONValue, _ mutation: JSONValue) async throws {
        try await workspace.installPrepared(snapshot, event: .mutation(mutation, state: snapshot, authority: authority))
        guard model.error == nil else { throw ScaleFailure(description: model.error!) }
        revision = snapshot["revision"]?.intValue ?? revision
    }

    func close() async {
        await model.stop()
        await workspace.client.close()
        try? FileManager.default.removeItem(at: directory)
    }
}

struct MutationSequence {
    let targetIndex: Int
    let targetID: String
    let targetThreads: [JSONValue]
    let snapshots: [JSONValue]
    let mutations: [JSONValue]
    let revisions: [Int]
}

@MainActor
func makeContentSequence(n: Int, target: Int, runningIndex: Int?, count: Int) throws -> MutationSequence {
    var threads = try (0..<n).map { index in
        try ScaleFixture.thread(index: index, revision: 0, suffix: 0, running: index == runningIndex)
    }
    var snapshots: [JSONValue] = []
    var mutations: [JSONValue] = []
    var targetThreads: [JSONValue] = []
    var revisions: [Int] = []
    for step in 1...count {
        let updated = try ScaleFixture.thread(index: target, revision: step, suffix: step,
                                              running: target == runningIndex)
        threads[target] = updated
        let snapshot = ScaleFixture.snapshot(threads: threads, revision: step)
        snapshots.append(snapshot)
        mutations.append(ScaleFixture.mutation(upserts: [updated], removed: [], base: step - 1, revision: step))
        targetThreads.append(updated)
        revisions.append(step)
    }
    return MutationSequence(targetIndex: target, targetID: "card-\(target)", targetThreads: targetThreads,
                            snapshots: snapshots, mutations: mutations, revisions: revisions)
}

@MainActor
func makeNoChangeSequence(n: Int, runningIndex: Int?, count: Int) throws -> MutationSequence {
    let threads = try (0..<n).map { index in
        try ScaleFixture.thread(index: index, revision: 0, suffix: 0, running: index == runningIndex)
    }
    var snapshots: [JSONValue] = []
    var mutations: [JSONValue] = []
    var revisions: [Int] = []
    for step in 1...count {
        snapshots.append(ScaleFixture.snapshot(threads: threads, revision: step))
        mutations.append(ScaleFixture.mutation(upserts: [], removed: [], base: step - 1, revision: step))
        revisions.append(step)
    }
    return MutationSequence(targetIndex: -1, targetID: "", targetThreads: [], snapshots: snapshots,
                            mutations: mutations, revisions: revisions)
}

@MainActor
func scaleEnvironment(window: NSWindow?) -> [String: Any] {
    let screen = window?.screen ?? NSScreen.main
    let model = sysctlString("hw.model"), chip = sysctlString("machdep.cpu.brand_string")
    var value: [String: Any] = [
        "pid": Int(ProcessInfo.processInfo.processIdentifier),
        "os": ProcessInfo.processInfo.operatingSystemVersionString,
        "hardwareModel": model, "chip": chip,
        "logicalCPU": ProcessInfo.processInfo.processorCount,
        "physicalMemoryBytes": Int(ProcessInfo.processInfo.physicalMemory),
        "thermalState": ProcessInfo.processInfo.thermalState.rawValue,
        "lowPowerMode": ProcessInfo.processInfo.isLowPowerModeEnabled,
        "reduceMotion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
        "reduceTransparency": NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
        "appearance": NSApplication.shared.effectiveAppearance.name.rawValue,
        "frontmostBundle": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "",
        "frontmostPID": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0,
    ]
    if let screen {
        value["screenFrame"] = NSStringFromRect(screen.frame)
        value["screenVisibleFrame"] = NSStringFromRect(screen.visibleFrame)
        value["backingScale"] = screen.backingScaleFactor
        value["maximumFramesPerSecond"] = screen.maximumFramesPerSecond
        value["localizedName"] = screen.localizedName
    }
    if let window {
        value["windowFrame"] = NSStringFromRect(window.frame)
        value["windowContentBounds"] = NSStringFromRect(window.contentView?.bounds ?? .zero)
        value["windowBackingScale"] = window.backingScaleFactor
        value["windowVisible"] = window.isVisible
        value["windowKey"] = window.isKeyWindow
        value["windowMain"] = window.isMainWindow
        value["windowOcclusionVisible"] = window.occlusionState.contains(.visible)
        value["appActive"] = NSApplication.shared.isActive
    }
    return value
}

func layoutViewport(width: Double = 1600, height: Double = 1000) -> NativeOverviewViewport {
    .init(width: width, height: height, toolbarBottom: 60, bottomReservedHeight: 0)
}

func readableFittingSize(_ viewport: NativeOverviewViewport) -> CGSize {
    let region = NativeOverviewCameraGeometry.framingRegion(viewport)
    let minimum = NativeOverviewCameraGeometry.minimumScale(in: viewport)
    return .init(width: region.width / minimum, height: region.height / minimum)
}

func placementRect(_ placement: NativeOverviewPlacement) -> CGRect {
    .init(x: Double(placement.column) * 376, y: Double(placement.row) * 216,
          width: Double(placement.columns) * 376 - 16, height: Double(placement.rows) * 216 - 16)
}

func visibleMetrics(_ placements: [NativeOverviewPlacement], camera: NativeOverviewTransform,
                    viewport: NativeOverviewViewport) -> (full: Int, partial: Int, area: Double) {
    let region = NativeOverviewCameraGeometry.framingRegion(viewport)
    let clip = CGRect(x: region.left, y: region.top, width: region.width, height: region.height)
    var full = 0, partial = 0
    var area = 0.0
    for placement in placements {
        let rect = placementRect(placement)
        let screen = CGRect(x: rect.minX * camera.scale + camera.x, y: rect.minY * camera.scale + camera.y,
                            width: rect.width * camera.scale, height: rect.height * camera.scale)
        let intersection = screen.intersection(clip)
        if intersection.isNull || intersection.isEmpty { continue }
        area += intersection.width * intersection.height
        if clip.insetBy(dx: -0.001, dy: -0.001).contains(screen) { full += 1 } else { partial += 1 }
    }
    return (full, partial, area)
}

func resetDiagnostics() {
    #if OVERVIEW_PERF_DIAGNOSTICS
    OverviewPerformanceDiagnostics.reset()
    #endif
}

func diagnosticsJSON() -> [String: Any] {
    #if OVERVIEW_PERF_DIAGNOSTICS
    let snapshot = OverviewPerformanceDiagnostics.snapshot()
    let events = OverviewPerformanceDiagnostics.takePresentEvents().map { event in
        ["at": Double(event.at) / 1e9, "items": event.items, "outgoing": event.outgoing,
         "animations": event.animations, "animated": event.animated, "repack": event.repack,
         "initial": event.initial, "replacesScene": event.replacesScene] as [String: Any]
    }
    return ["shellTicks": snapshot.shellTicks, "semanticTicks": snapshot.semanticTicks,
            "motionSamples": snapshot.motionSamples, "zeroTravelSamples": snapshot.zeroTravelSamples,
            "activeMotions": snapshot.activeMotions, "motionStarts": snapshot.motionStarts,
            "itemsChanges": snapshot.itemsChanges,
            "lastItemsChangeUptime": Double(snapshot.lastItemsChangeUptime) / 1e9,
            "canvasBodies": snapshot.canvasBodies,
            "shellCardBuilds": snapshot.shellCardBuilds,
            "semanticCardBuilds": snapshot.semanticCardBuilds,
            "shellFrameBodies": snapshot.shellFrameBodies,
            "semanticFrameBodies": snapshot.semanticFrameBodies,
            "swiftUICardBodies": snapshot.swiftUICardBodies,
            "workspaceCardBodies": snapshot.workspaceCardBodies,
            "layoutValidatePairs": snapshot.layoutValidatePairs,
            "layoutIntersectCalls": snapshot.layoutIntersectCalls,
            "layoutStraightPairs": snapshot.layoutStraightPairs,
            "harnessProjectionMisses": snapshot.harnessProjectionMisses,
            "harnessProjectionHits": snapshot.harnessProjectionHits,
            "snapshotCount": snapshot.snapshotCount, "harnessCacheCount": snapshot.harnessCacheCount,
            "layoutRevisionCount": snapshot.layoutRevisionCount, "pruneCalls": snapshot.pruneCalls,
            "presentEvents": events, "renderedCards": OverviewPerformanceDiagnostics.renderedCards()]
    #else
    return ["available": false]
    #endif
}
