// Production glass fixture benchmark. Counters measure this process, not the renderer/GPU.
import AppKit
import Darwin
import SwiftUI
import MokuseiCore
@testable import MokuseiUI

private struct PerformanceFailure: Error, CustomStringConvertible { let description: String }

private func resourceSample() throws -> [String: Any] {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw PerformanceFailure(description: "getrusage failed") }
    var vm = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &vm) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    guard status == KERN_SUCCESS else { throw PerformanceFailure(description: "task_info failed: \(status)") }
    var cpu = host_cpu_load_info_data_t()
    var cpuCount = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
    let host = mach_host_self()
    defer { mach_port_deallocate(mach_task_self_, host) }
    let cpuStatus = withUnsafeMutablePointer(to: &cpu) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(cpuCount)) {
            host_statistics(host, HOST_CPU_LOAD_INFO, $0, &cpuCount)
        }
    }
    guard cpuStatus == KERN_SUCCESS else { throw PerformanceFailure(description: "host_statistics failed: \(cpuStatus)") }
    return ["uptimeNs": String(NativePerformance.now()), "unix": Date().timeIntervalSince1970,
        "userSeconds": Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6,
        "systemSeconds": Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6,
        "residentBytes": vm.resident_size, "physicalFootprintBytes": vm.phys_footprint,
        "hostCPUTicks": [cpu.cpu_ticks.0, cpu.cpu_ticks.1, cpu.cpu_ticks.2, cpu.cpu_ticks.3],
        "thermalState": ProcessInfo.processInfo.thermalState.rawValue]
}

@MainActor private func cameraJSON(_ fixture: GlassFixture) -> [String: Double] {
    let value = fixture.state.camera.liveTransform
    return ["scale": value.scale, "x": value.x, "y": value.y]
}

@MainActor private func measure(fixture: GlassFixture, window: NSWindow, dynamic: Bool, seconds: Int) async throws -> [String: Any] {
    let origin = fixture.state.camera.liveTransform
    let initialAppearances = fixture.appearances
    let initialPlacements = fixture.state.presentedPlacements
    let snapshots = fixture.state.sceneSnapshotCount
    let screen = window.screen
    let windowFrame = window.frame
    let pointer = NSEvent.mouseLocation
    let startCamera = cameraJSON(fixture)
    var resources: [[String: Any]] = [try resourceSample()]
    var wakeLatenessMs: [Double] = []
    var actualCameras: [[String: Double]] = []
    var invalid = Set<String>()
    var firstFocusLoss: [String: Any] = [:]
    // 20 Hz static heartbeat quantifies scheduling responsiveness, not rendered
    // frames. Dynamic input is a fixed 60 Hz sequence, not a display-link/FPS probe.
    let frequency = dynamic ? 60 : 20
    let steps = seconds * frequency
    let start = NativePerformance.now()
    for step in 1...steps {
        let deadline = start + UInt64(Double(step) / Double(frequency) * 1e9)
        let now = NativePerformance.now()
        if deadline > now { try await Task.sleep(nanoseconds: deadline - now) }
        let wake = NativePerformance.now()
        wakeLatenessMs.append(Double(wake > deadline ? wake - deadline : 0) / 1e6)
        let key = window.isKeyWindow, active = NSApp.isActive
        if !key { invalid.insert("key-window-lost") }
        if !active { invalid.insert("application-inactive") }
        if (!key || !active) && firstFocusLoss.isEmpty {
            let frontmost = NSWorkspace.shared.frontmostApplication
            firstFocusLoss = ["unix": Date().timeIntervalSince1970, "step": step, "key": key, "active": active,
                "frontmostPID": frontmost?.processIdentifier ?? 0, "frontmostBundle": frontmost?.bundleIdentifier ?? ""]
        }
        if !window.occlusionState.contains(.visible) { invalid.insert("window-occluded") }
        let currentPointer = NSEvent.mouseLocation
        if currentPointer != pointer && (windowFrame.contains(pointer) || windowFrame.contains(currentPointer)) {
            invalid.insert("pointer-moved-over-window")
        }
        if window.frame != windowFrame || window.screen !== screen { invalid.insert("window-or-display-changed") }
        if dynamic {
            // Exact action count/path shared by both materials, ending at origin.
            // This is the production manual camera path used by pan/zoom input.
            let phase = Double(step) / Double(frequency) * .pi / 2
            fixture.state.camera.setManualTransform(.init(
                scale: origin.scale * (1 + 0.035 * sin(phase)),
                x: origin.x + 24 * sin(phase), y: origin.y + 16 * sin(2 * phase)))
        }
        if step % (frequency / 4) == 0 || step == steps {
            resources.append(try resourceSample())
            actualCameras.append(cameraJSON(fixture))
        }
    }
    let end = NativePerformance.now()
    let first = resources[0], last = resources[resources.count - 1]
    let before = first["hostCPUTicks"] as! [UInt32], after = last["hostCPUTicks"] as! [UInt32]
    let ticks = zip(before, after).map { pair in pair.1 &- pair.0 }
    let total = ticks.reduce(UInt64(0)) { $0 + UInt64($1) }
    if total == 0 || 100 * Double(total - UInt64(ticks[2])) / Double(total) > 40 {
        invalid.insert("host-busy-over-40-percent")
    }
    if resources.contains(where: { ($0["thermalState"] as! Int) >= 2 }) { invalid.insert("serious-thermal-pressure") }
    let late = wakeLatenessMs.filter { $0 > 1000 / Double(frequency) }.count
    if (wakeLatenessMs.max() ?? 0) > 250 || Double(late) / Double(steps) > 0.05 { invalid.insert("disrupted-scheduling") }
    // The external monitor cannot safely stop a foreign process. It asks only
    // this fixture to retire after preserving the current complete segment.
    if FileManager.default.fileExists(atPath: performanceDirectory.appendingPathComponent("external-interference.json").path) {
        invalid.insert("external-interference")
    }
    if fixture.appearances != initialAppearances || fixture.state.presentedPlacements != initialPlacements ||
        fixture.state.sceneSnapshotCount != snapshots || fixture.state.mountedCardIDs != Set(fixture.items.map(\.id)) {
        invalid.insert("mounted-or-layout-state-changed")
    }
    if !dynamic && fixture.state.camera.liveTransform != origin { invalid.insert("static-camera-changed") }
    return ["seconds": Double(end - start) / 1e9, "expectedActions": dynamic ? steps : 0,
        "deliveredActions": dynamic ? steps : 0, "heartbeatHz": frequency,
        "wakeLatenessMs": wakeLatenessMs, "resources": resources,
        "cameraStart": startCamera, "cameraEnd": cameraJSON(fixture), "sampledCameras": actualCameras,
        "appearances": fixture.appearances, "mounted": fixture.state.mountedCardIDs.sorted(),
        "sceneSnapshotCount": snapshots, "windowFrame": NSStringFromRect(windowFrame),
        "pointerStart": NSStringFromPoint(pointer), "pointerEnd": NSStringFromPoint(NSEvent.mouseLocation),
        "invalidReasons": invalid.sorted(), "firstFocusLoss": firstFocusLoss]
}

@MainActor private func awaitStableWindow(_ window: NSWindow, directory: URL) async throws {
    var previous = try resourceSample(), pointer = NSEvent.mouseLocation
    var stableSeconds = 0
    var observations: [[String: Any]] = []
    var heldFocus = false
    for attempt in 0..<180 {
        try await Task.sleep(for: .seconds(1))
        let current = try resourceSample(), currentPointer = NSEvent.mouseLocation
        let before = previous["hostCPUTicks"] as! [UInt32], after = current["hostCPUTicks"] as! [UInt32]
        let ticks = zip(before, after).map { pair in pair.1 &- pair.0 }
        let total = ticks.reduce(UInt64(0)) { $0 + UInt64($1) }
        let busy = total == 0 ? 100 : 100 * Double(total - UInt64(ticks[2])) / Double(total)
        let stable = window.isKeyWindow && NSApp.isActive && window.occlusionState.contains(.visible) &&
            pointer == currentPointer && busy <= 40 && ProcessInfo.processInfo.thermalState.rawValue < 2
        stableSeconds = stable ? stableSeconds + 1 : 0
        let frontmost = NSWorkspace.shared.frontmostApplication
        observations.append(["resources": current, "hostBusyPercent": busy, "key": window.isKeyWindow,
            "active": NSApp.isActive, "visible": window.occlusionState.contains(.visible),
            "frontmostPID": frontmost?.processIdentifier ?? 0, "frontmostBundle": frontmost?.bundleIdentifier ?? "",
            "pointer": NSStringFromPoint(currentPointer), "consecutiveStableSeconds": stableSeconds])
        try JSONSerialization.data(withJSONObject: observations, options: [.sortedKeys])
            .write(to: directory.appendingPathComponent("readiness.json"))
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("external-interference.json").path) {
            throw PerformanceFailure(description: "External build/replay interference during readiness; evidence retained")
        }
        if heldFocus && (!window.isKeyWindow || !NSApp.isActive) {
            throw PerformanceFailure(description: "Foreground lost during readiness; no reactivation or retry")
        }
        heldFocus = heldFocus || (window.isKeyWindow && NSApp.isActive)
        if !heldFocus && attempt >= 4 {
            throw PerformanceFailure(description: "Initial foreground ownership was not granted; no activation retry")
        }
        if stableSeconds >= 30 { return }
        previous = current; pointer = currentPointer
    }
    throw PerformanceFailure(description: "No continuous 30-second stable window/load interval within 180 seconds; readiness.json retained")
}

@MainActor private final class PerformanceWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private var performanceDirectory: URL {
    URL(fileURLWithPath: Bundle.main.object(forInfoDictionaryKey: "MokuseiGlassPerformanceDirectory") as! String)
}

private func retainMeasurement(_ data: [String: Any], at url: URL) throws {
    try JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]).write(to: url)
    let invalid = data["invalidReasons"] as! [String]
    guard invalid.isEmpty else {
        throw PerformanceFailure(description: "Contaminated \(url.lastPathComponent): \(invalid.joined(separator: ", ")); retained without retry")
    }
}

@MainActor private func runPerformance() async throws {
    let directory = performanceDirectory
    // An inherited diagnostic override must not write outside this private run.
    unsetenv("MOKUSEI_PERFORMANCE_DIR")
    NativePerformance.configure(directory: directory.appendingPathComponent("native"), mode: .summary)
    defer { NativePerformance.finish() }
    let smoke = Bundle.main.object(forInfoDictionaryKey: "MokuseiGlassPerformanceSmoke") as? Bool ?? false
    let repetitions = smoke ? 1 : 4, sampleSeconds = smoke ? 2 : 12, warmupSeconds = smoke ? 1 : 4
    // Recheck the driver's idle gate before showing content. LaunchServices
    // owns the sole initial activation; this app never forces or restores it.
    let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState,
        eventType: CGEventType(rawValue: UInt32.max)!)
    let foreground = NSWorkspace.shared.frontmostApplication
    try JSONSerialization.data(withJSONObject: ["inputIdleSeconds": idle,
        "frontmostPID": foreground?.processIdentifier ?? 0,
        "frontmostBundle": foreground?.bundleIdentifier ?? ""], options: [.sortedKeys])
        .write(to: directory.appendingPathComponent("startup-environment.json"))
    guard idle.isFinite, idle >= 30 else { throw PerformanceFailure(description: "Recent user/session input; no window activation") }
    let fixture = GlassFixture()
    let size = CGSize(width: 1200, height: 760)
    let window = PerformanceWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: GlassSurface(fixture: fixture))
    window.center(); window.makeKeyAndOrderFront(nil)
    defer { fixture.state.camera.dispose(); window.close() }
    for _ in 0..<500 {
        if !fixture.state.isLayingOut && fixture.state.mountedCardIDs.count == 5 && fixture.frames.count == 5 { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    guard fixture.state.mountedCardIDs.count == 5, fixture.frames.count == 5,
          window.contentView?.bounds.size == size else { throw PerformanceFailure(description: "Fixture did not mount at fixed size") }
    fixture.state.camera.setManualTransform(fixture.state.camera.liveTransform)
    let origin = fixture.state.camera.liveTransform
    let placements = fixture.state.presentedPlacements
    let appearances = fixture.appearances
    let snapshots = fixture.state.sceneSnapshotCount
    guard origin.scale >= 0.8, fixture.frames.values.allSatisfy({ CGRect(origin: .zero, size: size).contains($0) }) else {
        throw PerformanceFailure(description: "Five cards must fit at readable scale")
    }
    let screenNumber = window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
    let mode = screenNumber.flatMap { CGDisplayCopyDisplayMode($0) }
    let metadata: [String: Any] = ["schema": 2, "pid": ProcessInfo.processInfo.processIdentifier,
        "startedAt": ISO8601DateFormatter().string(from: Date()), "cpuCount": ProcessInfo.processInfo.processorCount,
        "memoryBytes": ProcessInfo.processInfo.physicalMemory, "os": ProcessInfo.processInfo.operatingSystemVersionString,
        "windowPoints": [1200, 760], "backingScale": window.backingScaleFactor,
        "screenFrame": NSStringFromRect(window.screen?.frame ?? .zero),
        "displayModePixels": [mode?.pixelWidth ?? 0, mode?.pixelHeight ?? 0],
        "nominalDisplayRefreshHzNotFPS": mode?.refreshRate ?? 0,
        "reduceMotion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
        "reduceTransparency": NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
        "camera": cameraJSON(fixture), "frames": fixture.frames.mapValues { NSStringFromRect($0) },
        "repetitions": repetitions, "sampleSeconds": sampleSeconds, "warmupSecondsPerCondition": warmupSeconds, "smoke": smoke,
        "missingMetrics": ["GPU time/utilization attributable to fixture", "rendered frame times/FPS", "presentation hitches", "energy"],
        "sampling": "getrusage and TASK_VM_INFO; host CPU tick deltas; main-actor Task.sleep wake lateness is only a responsiveness proxy"]
    try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
        .write(to: directory.appendingPathComponent("metadata.json"))
    try await awaitStableWindow(window, directory: directory)
    let warmups = directory.appendingPathComponent("warmups")
    try FileManager.default.createDirectory(at: warmups, withIntermediateDirectories: true)
    // Warm both material pipelines, then alternate first condition within each
    // adjacent pair; appearance/scenario order reverses on alternate repetitions.
    for glass in [true, false] {
        fixture.glassWorld = glass
        let data = try await measure(fixture: fixture, window: window, dynamic: true, seconds: 4)
        try retainMeasurement(data, at: warmups.appendingPathComponent("initial-\(glass ? "on" : "off").json"))
        fixture.state.camera.setManualTransform(origin)
    }
    for repetition in 0..<repetitions {
        for dark in repetition.isMultiple(of: 2) ? [false, true] : [true, false] {
            fixture.dark = dark
            for dynamic in repetition.isMultiple(of: 2) ? [false, true] : [true, false] {
                for glass in repetition.isMultiple(of: 2) ? [true, false] : [false, true] {
                    let name = "r\(repetition + 1)-\(dark ? "dark" : "light")-\(dynamic ? "pan-zoom" : "static")-\(glass ? "on" : "off")"
                    fixture.glassWorld = glass
                    fixture.state.camera.setManualTransform(origin)
                    try await Task.sleep(for: .seconds(2))
                    let warmup = try await measure(fixture: fixture, window: window, dynamic: dynamic, seconds: warmupSeconds)
                    try retainMeasurement(warmup, at: warmups.appendingPathComponent(name + ".json"))
                    fixture.state.camera.setManualTransform(origin)
                    try await Task.sleep(for: .milliseconds(250))
                    let span = NativePerformance.begin(.scenario, values: ["glassWorld": glass ? 1 : 0, "dynamic": dynamic ? 1 : 0, "dark": dark ? 1 : 0])
                    var data = try await measure(fixture: fixture, window: window, dynamic: dynamic, seconds: sampleSeconds)
                    span?.end()
                    data["name"] = name; data["repetition"] = repetition + 1
                    data["dark"] = dark; data["dynamic"] = dynamic; data["glassWorld"] = glass
                    if fixture.appearances != appearances || fixture.state.presentedPlacements != placements || fixture.state.sceneSnapshotCount != snapshots {
                        data["invalidReasons"] = (data["invalidReasons"] as! [String]) + ["material-changed-mounting-or-layout"]
                    }
                    try retainMeasurement(data, at: directory.appendingPathComponent(name + ".json"))
                    print("Measured \(name)")
                }
            }
        }
    }
}

@MainActor private final class PerformanceDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            let result = URL(fileURLWithPath: Bundle.main.object(forInfoDictionaryKey: "MokuseiReplayResult") as! String)
            do {
                try await runPerformance()
                try Data("PASS glass-world performance sampling completed; inspect invalidReasons before analysis\n".utf8).write(to: result)
                exit(0)
            } catch {
                try? Data("FAIL \(error)\n".utf8).write(to: result)
                exit(1)
            }
        }
    }
}

@main private enum PerformanceMain {
    static func main() {
        prepareReplayEnvironment()
        let delegate = PerformanceDelegate(), app = NSApplication.shared
        app.setActivationPolicy(.regular); app.delegate = delegate; app.run()
    }
}
