// Appended to the existing production-counter helpers in the disposable build.
@MainActor private func runResearchTrial() async throws {
    let directory = performanceDirectory
    unsetenv("MOKUSEI_PERFORMANCE_DIR")
    NativePerformance.configure(directory: directory.appendingPathComponent("native"), mode: .summary)
    defer { NativePerformance.finish() }
    let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState,
        eventType: CGEventType(rawValue: UInt32.max)!)
    guard idle.isFinite, idle >= 30 else { throw PerformanceFailure(description: "Recent session input; no window shown") }
    let fixture = GlassFixture()
    let stage = Bundle.main.object(forInfoDictionaryKey: "ResearchStage") as? String ?? "baseline"
    guard ["baseline", "extended"].contains(stage) else { throw PerformanceFailure(description: "Unknown research stage") }
    let size = CGSize(width: 1800, height: 1000)
    guard NSScreen.main.map({ $0.visibleFrame.width >= size.width && $0.visibleFrame.height >= size.height }) == true else {
        throw PerformanceFailure(description: "No main display fitting the fixed 1800x1000pt window")
    }
    let window = PerformanceWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: GlassSurface(fixture: fixture))
    window.center(); window.makeKeyAndOrderFront(nil)
    defer { fixture.state.camera.dispose(); window.close() }
    for _ in 0..<500 {
        if !fixture.state.isLayingOut && fixture.state.mountedCardIDs.count == fixture.cardCount && fixture.frames.count == fixture.cardCount { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    guard fixture.state.mountedCardIDs.count == fixture.cardCount, fixture.frames.count == fixture.cardCount else {
        throw PerformanceFailure(description: "Production layout did not mount all requested cards; no capacity override")
    }
    let viewport = CGRect(origin: .zero, size: size)
    let fullyInside = fixture.frames.values.filter { viewport.contains($0) }.count
    let intersecting = fixture.frames.values.filter { viewport.intersects($0) }.count
    // Large collections naturally extend beyond the readable viewport. Retain
    // the production camera and all mounted cards, rather than shrinking them
    // or rejecting the very scrolling scenario whose cost we want to inspect.
    if fixture.cardCount <= 5 && fullyInside != fixture.cardCount {
        throw PerformanceFailure(description: "Small reference scene did not fully fit")
    }
    fixture.state.camera.setManualTransform(fixture.state.camera.liveTransform)
    let origin = fixture.state.camera.liveTransform
    let metadata: [String: Any] = ["schema": 2, "count": fixture.cardCount, "stage": stage,
        "pid": ProcessInfo.processInfo.processIdentifier, "cpuCount": ProcessInfo.processInfo.processorCount,
        "windowPoints": [1800, 1000], "backingScale": window.backingScaleFactor,
        "camera": cameraJSON(fixture), "frames": fixture.frames.mapValues { NSStringFromRect($0) },
        "geometricFullyInWindow": fullyInside, "geometricIntersectingWindow": intersecting,
        "framing": "production readable camera; large collections may be partially outside the viewport",
        "reduceMotion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
        "reduceTransparency": NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
        "comparison": "all-on; shell-off retains inner glass; all-off uses inner Glass.identity; opaque replacements change occlusion/compositing",
        "cloud": "production harness palettes supplied; autonomous animation paused equally in all conditions",
        "missingMetrics": ["GPU", "rendered frame time/FPS", "WindowServer allocations", "energy"],
        "repetitions": 6, "sampleSeconds": 12, "appearance": "light"]
    try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
        .write(to: directory.appendingPathComponent("metadata.json"))
    guard !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency else {
        throw PerformanceFailure(description: "Reduce Transparency is enabled; glass-on may be a fallback")
    }
    try await awaitStableWindow(window, directory: directory)
    let warmups = directory.appendingPathComponent("warmups")
    try FileManager.default.createDirectory(at: warmups, withIntermediateDirectories: true)
    let conditions = [
        ["all-on", "shell-off", "all-off"], ["all-off", "shell-off", "all-on"],
        ["shell-off", "all-on", "all-off"], ["all-off", "all-on", "shell-off"],
        ["shell-off", "all-off", "all-on"], ["all-on", "all-off", "shell-off"],
    ]
    let scenarios = stage == "baseline" ? ["idle", "pan"] : ["zoom", "refresh"]
    for repetition in 0..<6 {
        for scenario in repetition.isMultiple(of: 2) ? scenarios : Array(scenarios.reversed()) {
            for condition in conditions[repetition] {
                let name = "r\(repetition + 1)-\(scenario)-\(condition)"
                fixture.cardGlassCondition = condition
                fixture.glassWorld = condition == "all-on"
                fixture.refreshTick = 0
                fixture.state.camera.setManualTransform(origin)
                try await Task.sleep(for: .seconds(2))
                let dynamic = scenario == "pan" || scenario == "zoom"
                let zoom = scenario == "zoom", refresh = scenario == "refresh"
                let warmup = try await measure(fixture: fixture, window: window, dynamic: dynamic, zoom: zoom, refresh: refresh, seconds: 4)
                try retainMeasurement(warmup, at: warmups.appendingPathComponent(name + ".json"))
                fixture.state.camera.setManualTransform(origin)
                fixture.refreshTick = 0
                try await Task.sleep(for: .milliseconds(250))
                var data = try await measure(fixture: fixture, window: window, dynamic: dynamic, zoom: zoom, refresh: refresh, seconds: 12)
                data["name"] = name; data["scenario"] = scenario
                data["repetition"] = repetition + 1; data["condition"] = condition
                try retainMeasurement(data, at: directory.appendingPathComponent(name + ".json"))
                print("Measured \(name)")
            }
        }
    }
}

@MainActor private final class ResearchDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            let result = URL(fileURLWithPath: Bundle.main.object(forInfoDictionaryKey: "MokuseiReplayResult") as! String)
            do {
                try await runResearchTrial()
                try Data("PASS research sampling completed\n".utf8).write(to: result)
                exit(0)
            } catch {
                try? Data("FAIL \(error)\n".utf8).write(to: result)
                exit(1)
            }
        }
    }
}

@main private enum ResearchMain {
    static func main() {
        prepareReplayEnvironment()
        let delegate = ResearchDelegate(), app = NSApplication.shared
        app.setActivationPolicy(.regular); app.delegate = delegate; app.run()
    }
}
