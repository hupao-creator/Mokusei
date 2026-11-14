import AppKit
import ScreenCaptureKit
import Vision
import ImageIO
import UniformTypeIdentifiers

// This executable knows only OS processes/windows, input and external pixels.
// It never imports product code, attaches to its objects or reads its database.
typealias Record = [String: Any]
func now() -> UInt64 { bench_now_ns() }
func readJSON(_ path: String) throws -> Record {
    if path != "-", let size = try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber,
       size.intValue > 32 * 1024 * 1024 { throw fail("JSON input exceeds size limit") }
    var input = Data()
    if path == "-" {
        while let block = try FileHandle.standardInput.read(upToCount: 65536), !block.isEmpty {
            input.append(block)
            guard input.count <= 32 * 1024 * 1024 else { throw fail("JSON input exceeds size limit") }
        }
    } else { input = try Data(contentsOf: URL(fileURLWithPath: path)) }
    guard input.count <= 32 * 1024 * 1024 else { throw fail("JSON input exceeds size limit") }
    guard let value = try JSONSerialization.jsonObject(with: input) as? Record else {
        throw NSError(domain: "benchmark", code: 1, userInfo: [NSLocalizedDescriptionKey: "expected JSON object"])
    }
    return value
}
func data(_ value: Any) throws -> Data {
    guard JSONSerialization.isValidJSONObject(value) else { throw fail("nonfinite or invalid JSON output") }
    return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
}
func write(_ value: Any, _ path: String) throws { try data(value).write(to: URL(fileURLWithPath: path), options: .atomic) }
func emit(_ value: Any) throws { FileHandle.standardOutput.write(try data(value)); print("") }
func fail(_ text: String) -> NSError { NSError(domain: "benchmark", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
func launchConfiguration(_ value: Any?) throws -> Record {
    guard let value = value as? Record, let app = value["app"] as? String, app.hasPrefix("/"),
          let arguments = value["arguments"] as? [String], arguments.count <= 100,
          value["environment"] == nil || value["environment"] is [String: String] else { throw fail("invalid application launch configuration") }
    return value
}
func validatePlan(_ plan: Record) throws {
    func number(_ value: Any?, _ name: String, _ range: ClosedRange<Double>) throws {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite, range.contains(value.doubleValue) else { throw fail("invalid plan \(name)") }
    }
    guard plan["version"] as? Int == 1, plan["kind"] as? String == "plan",
          plan["clock"] as? String == "macos.mach_absolute_time.nanoseconds",
          ["observed", "minimal"].contains(plan["mode"] as? String ?? ""),
          let identity = plan["processIdentity"] as? String, !identity.isEmpty,
          let events = plan["events"] as? [Record], events.count <= 20_000,
          let roots = plan["processRoots"] as? [Record], !roots.isEmpty, roots.count <= 256 else { throw fail("invalid plan envelope") }
    try number(plan["version"], "version", 1...1)
    for key in ["pid", "windowID", "startNS"] {
        try number(plan[key], key, 1...Double(Int64.max))
        let value = (plan[key] as! NSNumber).doubleValue
        guard value.rounded(.towardZero) == value, key == "startNS" || value <= Double(Int32.max) else { throw fail("invalid integral plan identity") }
    }
    for key in ["warmupSeconds", "formalSeconds", "tailSeconds"] { try number(plan[key], key, 0.05...120) }
    for key in ["sampleHz", "captureHz"] { try number(plan[key], key, 1...60) }
    let duration = (plan["formalSeconds"] as! Double) + (plan["tailSeconds"] as! Double)
    var previous = -1.0, down = false
    var pressedKey: Int?
    var scrollDirection: Int?
    for event in events {
        guard let kind = event["kind"] as? String, ["move", "down", "drag", "up", "keyDown", "keyUp", "scroll"].contains(kind) else { throw fail("unsupported plan input") }
        try number(event["atSeconds"], "input time", 0...duration)
        let at = event["atSeconds"] as! Double
        guard at > previous else { throw fail("input deadlines out of order") }; previous = at
        for axis in ["x", "y"] { try number(event[axis], axis, -100_000...100_000) }
        if kind == "down" { guard !down else { throw fail("duplicate down") }; down = true }
        if kind == "drag" || kind == "up" { guard down else { throw fail("unowned drag/up") } }
        if kind == "up" { down = false }
        if kind == "keyDown" || kind == "keyUp" {
            try number(event["keyCode"], "navigation key", 0...127)
            guard let key = event["keyCode"] as? Int, [40, 115, 36].contains(key) else { throw fail("unsupported navigation key") }
            if kind == "keyDown" {
                guard pressedKey == nil else { throw fail("overlapping navigation keys") }
                pressedKey = key
            } else {
                guard pressedKey == key else { throw fail("navigation key release mismatch") }
                pressedKey = nil
            }
        }
        if kind == "scroll" {
            try number(event["deltaY"], "scroll delta", -20...20)
            try number(event["phase"], "scroll phase", 1...4)
            guard let delta = event["deltaY"] as? Int, let phase = event["phase"] as? Int else { throw fail("integral scroll input required") }
            switch phase {
            case 1:
                guard scrollDirection == nil, delta != 0 else { throw fail("invalid scroll begin") }
                scrollDirection = delta > 0 ? 1 : -1
            case 2:
                guard let direction = scrollDirection, delta * direction > 0 else { throw fail("invalid scroll change") }
            case 4:
                guard scrollDirection != nil, delta == 0 else { throw fail("invalid scroll ending") }
                scrollDirection = nil
            default: throw fail("unsupported scroll phase")
            }
        }
    }
    guard !down, pressedKey == nil, scrollDirection == nil else { throw fail("gesture lacks release") }
    let keys = events.compactMap { $0["kind"] as? String }.filter { $0 == "keyDown" || $0 == "keyUp" }
    guard keys.isEmpty || keys == ["keyDown", "keyUp"] || keys == ["keyDown", "keyUp", "keyDown", "keyUp"] else { throw fail("unsupported navigation sequence") }
    var rootPIDs = Set<Int>()
    for root in roots {
        try number(root["pid"], "root pid", 1...Double(Int32.max))
        let value = (root["pid"] as! NSNumber).doubleValue
        guard value.rounded(.towardZero) == value, rootPIDs.insert(Int(value)).inserted,
              let identity = root["identity"] as? String, !identity.isEmpty, let role = root["role"] as? String,
              ["application", "runtime", "helper", "collector", "source"].contains(role) else { throw fail("invalid process root") }
    }
}

func process(_ pid: Int32) -> Record? {
    var p = BenchProcess()
    guard bench_process(pid, &p) == 0 else { return nil }
    let path = withUnsafePointer(to: &p.path) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: 4096) { String(cString: $0) }
    }
    return ["pid": Int(p.pid), "ppid": Int(p.ppid), "birthUS": p.birth_us,
            "identity": "\(pid):\(p.birth_us)", "cpuNS": p.user_ns + p.system_ns,
            "footprintBytes": p.footprint_bytes, "path": path]
}
func ax(_ item: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(item, key as CFString, &value) == .success ? value : nil
}
func axRecord(_ item: AXUIElement) -> Record {
    var row: Record = [:]
    for key in ["AXRole", "AXIdentifier", "AXTitle", "AXDescription", "AXValue"] {
        if let text = ax(item, key) as? String { row[key] = text }
    }
    if let p = ax(item, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
       let s = ax(item, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID() {
        var point = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &point)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        if [point.x, point.y, size.width, size.height].allSatisfy(\.isFinite) {
            row["bounds"] = ["x": point.x, "y": point.y, "width": size.width, "height": size.height]
        } else { row["boundsUnavailable"] = "AX returned nonfinite geometry" }
    }
    return row
}
func axTree(_ item: AXUIElement, _ depth: Int = 0, budget: inout Int) -> [Record] {
    guard depth < 35, budget > 0 else { return [] }
    budget -= 1
    var result = [axRecord(item)]
    for child in ax(item, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
        result += axTree(child, depth + 1, budget: &budget)
    }
    return result
}
func window(_ pid: Int32) async throws -> SCWindow {
    let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
    guard let found = content.windows.filter({ $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width > 200 })
        .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else { throw fail("target has no on-screen window") }
    return found
}
func windowBounds(_ id: CGWindowID) throws -> Record {
    guard let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [Record],
          let bounds = rows.first?[kCGWindowBounds as String] as? Record,
          let x = bounds["X"] as? Double, let y = bounds["Y"] as? Double,
          let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double else {
        throw fail("WindowServer bounds unavailable")
    }
    return ["x": x, "y": y, "width": width, "height": height]
}
func capture(_ target: SCWindow, _ path: String) async throws -> Record {
    let filter = SCContentFilter(desktopIndependentWindow: target)
    let config = SCStreamConfiguration()
    config.width = Int(target.frame.width * CGFloat(filter.pointPixelScale))
    config.height = Int(target.frame.height * CGFloat(filter.pointPixelScale))
    config.showsCursor = false
    config.ignoreShadowsSingleWindow = true
    let start = now()
    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    let end = now()
    guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw fail("PNG destination unavailable") }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw fail("PNG write failed") }
    return ["atNS": end, "requestNS": start, "width": image.width, "height": image.height,
            "pointsWidth": target.frame.width, "pointsHeight": target.frame.height, "windowBounds": try windowBounds(target.windowID), "image": URL(fileURLWithPath: path).lastPathComponent]
}
func recognize(_ path: String) throws -> Record {
    let url = URL(fileURLWithPath: path)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw fail("invalid input image") }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    request.recognitionLanguages = ["en-US"]
    try VNImageRequestHandler(cgImage: image).perform([request])
    let texts: [Record] = (request.results ?? []).compactMap { item in
        guard let candidate = item.topCandidates(1).first else { return nil }
        let raw = item.boundingBox
        let r = raw.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !r.isNull, !r.isEmpty else { return nil }
        return ["edgeClipped": raw.minX < -0.000001 || raw.minY < -0.000001 || raw.maxX > 1.000001 || raw.maxY > 1.000001,
                "text": candidate.string, "confidence": candidate.confidence,
                "x": max(0, r.minX * Double(image.width)), "y": max(0, (1 - r.maxY) * Double(image.height)),
                "width": r.width * Double(image.width), "height": r.height * Double(image.height)]
    }
    return ["width": image.width, "height": image.height, "texts": texts]
}
func post(_ event: Record) throws {
    guard let kind = event["kind"] as? String, let x = event["x"] as? Double, let y = event["y"] as? Double,
          x.isFinite, y.isFinite, abs(x) <= 100_000, abs(y) <= 100_000 else { throw fail("invalid input event") }
    let point = CGPoint(x: x, y: y)
    let source = CGEventSource(stateID: .hidSystemState)
    let mouse: CGEvent?
    switch kind {
    case "keyDown", "keyUp":
        guard let key = event["keyCode"] as? Int, [40, 115, 36].contains(key) else { throw fail("unsupported navigation key") }
        mouse = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: kind == "keyDown")
        mouse?.flags = key == 40 && kind == "keyDown" ? .maskCommand : []
    case "scroll":
        guard let delta = event["deltaY"] as? Int, (-20...20).contains(delta),
              let phase = event["phase"] as? Int, [1, 2, 4].contains(phase) else { throw fail("invalid pixel scroll input") }
        mouse = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1,
                        wheel1: Int32(delta), wheel2: 0, wheel3: 0)
        mouse?.location = point
        mouse?.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        mouse?.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase))
        mouse?.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
    case "move": mouse = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)
    case "down": mouse = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
    case "drag": mouse = CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left)
    case "up": mouse = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
    case "zoom": throw fail("no validated public system magnification injector")
    default: throw fail("unsupported input kind")
    }
    guard let mouse else { throw fail("cannot create HID event") }
    mouse.post(tap: .cghidEventTap)
}
func sleepUntil(_ deadline: UInt64) {
    while now() < deadline {
        let remaining = deadline - min(deadline, now())
        if remaining > 1_000_000 { usleep(useconds_t(min(remaining / 1000, 10_000))) }
    }
}

final class Sampler: @unchecked Sendable {
    var roots: [Int32: String]
    let output: String
    var samples: [Record] = [], gaps: [String] = [], watches: [Int32: Int32] = [:]
    var identities: [Int32: String] = [:]
    var owner: Record
    var runtimeConnection: String?
    var runtimePath: String?
    init(roots: [Int32: String], output: String, owner: Record) { self.roots = roots; self.output = output; self.owner = owner }
    func sample() {
        let start = now()
        var pids = [Int32](repeating: 0, count: 32768)
        let count = Int(bench_pids(&pids, Int32(pids.count)))
        if count <= 0 || count >= pids.count { gaps.append("process enumeration failed or truncated") }
        let all = pids.prefix(max(0, min(count, pids.count))).compactMap(process)
        if let connection = runtimeConnection, let expected = runtimePath,
           let value = try? readJSON(connection), let runtimePID = value["pid"] as? Int,
           let row = all.first(where: { $0["pid"] as? Int == runtimePID }), row["path"] as? String == expected {
            roots[Int32(runtimePID)] = "runtime"
        }
        for row in all {
            let pid = Int32(row["pid"] as! Int)
            if let expected = identities[pid], expected != row["identity"] as? String {
                gaps.append("declared PID identity changed: \(pid)"); roots.removeValue(forKey: pid)
            }
        }
        // Keep known descendants after reparenting. Birth identity fences PID reuse.
        var changed = true
        while changed {
            changed = false
            for row in all {
                let pid = Int32(row["pid"] as! Int), parent = Int32(row["ppid"] as! Int)
                if roots[pid] == nil, let role = roots[parent], !["collector", "source"].contains(role) {
                    roots[pid] = "helper"; changed = true
                }
            }
        }
        var rows: [Record] = []
        for row in all {
            let pid = Int32(row["pid"] as! Int)
            guard let role = roots[pid] else { continue }
            let identity = row["identity"] as! String
            if let old = identities[pid], old != identity { gaps.append("PID reused: \(pid)"); continue }
            identities[pid] = identity
            if watches[pid] == nil {
                let fd = bench_watch(pid)
                if fd < 0 { gaps.append("cannot watch process \(pid)") } else { watches[pid] = fd }
            }
            rows.append(row.merging(["role": role], uniquingKeysWith: { _, new in new }))
        }
        for (pid, fd) in watches {
            let flags = bench_events(fd)
            if flags != 0 { gaps.append("lifecycle note \(flags) for \(pid); descendant/exit CPU is not guaranteed") }
        }
        for pid in identities.keys where !rows.contains(where: { ($0["pid"] as? Int) == Int(pid) }) { gaps.append("lost process \(pid) without exit CPU") }
        let appPID = Int32(owner["pid"] as! Int)
        let same = process(appPID)?["identity"] as? String == owner["identity"] as? String
        samples.append(["atNS": start, "endNS": now(), "processes": rows,
                        "ownerAlive": same, "frontmostPID": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1])
    }
    func finish() -> Record {
        for fd in watches.values { close(fd) }
        // macOS unprivileged proc polling cannot prove absence of a child that
        // forks/exits before observation, nor obtain its cumulative exit cost.
        gaps.append("unprivileged process sampling has no complete descendant lifecycle/exit-CPU ledger")
        return ["samples": samples, "coverage": ["complete": false, "gaps": Array(Set(gaps)).sorted()]]
    }
}

@main struct Collector {
    static func main() async {
        do { try await run() } catch {
            try? emit(["error": String(describing: error)])
            exit(1)
        }
    }
    static func run() async throws {
        _ = await MainActor.run { NSApplication.shared.setActivationPolicy(.prohibited) }
        let args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else { throw fail("command required") }
        let counts = ["launch": 2, "startup": 3, "quit": 3, "probe": 1, "process": 2,
                      "inspect": 2, "prepare": 2, "hit-test": 4, "capture": 3, "ocr": 2, "input": 2, "collect": 3]
        guard command == "tree" ? args.count > 1 : (counts[command] == args.count || (command == "prepare" && args.count == 3)) else { throw fail("invalid command arguments") }
        switch command {
        case "launch":
            let config = try launchConfiguration(readJSON(args[1]))
            let options = NSWorkspace.OpenConfiguration()
            options.createsNewApplicationInstance = true
            options.arguments = config["arguments"] as? [String] ?? []
            options.environment = config["environment"] as? [String: String] ?? [:]
            let app = try await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: config["app"] as! String), configuration: options)
            try emit(["process": process(app.processIdentifier) ?? [:], "launchDate": app.launchDate?.timeIntervalSince1970 as Any? ?? NSNull()])
        case "quit":
            guard let pid = Int32(args[1]), let app = NSRunningApplication(processIdentifier: pid),
                  process(pid)?["identity"] as? String == args[2] else { throw fail("quit owner mismatch") }
            try emit(["accepted": app.terminate()])
        case "probe":
            var info = mach_timebase_info_data_t(); mach_timebase_info(&info)
            let raw = mach_absolute_time(), a = now()
            let converted = UInt64(Double(raw) * Double(info.numer) / Double(info.denom))
            try emit(["clock": "macos.mach_absolute_time.nanoseconds", "nowNS": a,
                      "machNS": converted, "timebaseNumer": info.numer, "timebaseDenom": info.denom,
                      "accessibility": AXIsProcessTrusted(), "capture": CGPreflightScreenCaptureAccess(),
                      "input": CGPreflightPostEventAccess(), "pid": ProcessInfo.processInfo.processIdentifier,
                      "os": ProcessInfo.processInfo.operatingSystemVersionString,
                      "screens": await MainActor.run { NSScreen.screens.map { screen -> Record in
                          let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
                          return ["id": id, "x": screen.frame.minX, "y": screen.frame.minY,
                              "width": screen.frame.width, "height": screen.frame.height, "scale": screen.backingScaleFactor,
                              "maximumFPS": screen.maximumFramesPerSecond, "modeHz": CGDisplayCopyDisplayMode(id)?.refreshRate ?? 0]
                      } }])
        case "tree":
            var roots = Set(args.dropFirst().compactMap(Int32.init))
            var pids = [Int32](repeating: 0, count: 32768)
            let count = Int(bench_pids(&pids, Int32(pids.count)))
            guard count > 0, count < pids.count else { throw fail("process enumeration failed") }
            let all = pids.prefix(count).compactMap(process)
            var changed = true
            while changed {
                changed = false
                for row in all where roots.contains(Int32(row["ppid"] as! Int)) {
                    if roots.insert(Int32(row["pid"] as! Int)).inserted { changed = true }
                }
            }
            try emit(["processes": all.filter { roots.contains(Int32($0["pid"] as! Int)) }, "complete": false])
        case "process":
            guard let pid = Int32(args[1]), let row = process(pid) else { throw fail("process unavailable") }; try emit(row)
        case "hit-test":
            guard let pid = Int32(args[1]), let x = Double(args[2]), let y = Double(args[3]),
                  x.isFinite, y.isFinite, abs(x) <= 100_000, abs(y) <= 100_000,
                  let owner = process(pid), AXIsProcessTrusted() else { throw fail("invalid hit-test owner or point") }
            let before = now()
            var leaf: AXUIElement?
            guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(x), Float(y), &leaf) == .success,
                  var element = leaf else { throw fail("system accessibility hit-test unavailable") }
            var elements: [Record] = [], complete = false
            for _ in 0..<35 {
                var actualPID: pid_t = 0
                guard AXUIElementGetPid(element, &actualPID) == .success, actualPID == pid else { throw fail("hit-test belongs to another process") }
                let row = axRecord(element); elements.append(row)
                if row["AXRole"] as? String == "AXApplication" { complete = true; break }
                guard let parent = ax(element, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
                element = parent as! AXUIElement
            }
            let target = try await window(pid)
            guard process(pid)?["identity"] as? String == owner["identity"] as? String else { throw fail("hit-test owner changed") }
            try emit(["beforeNS": before, "afterNS": now(), "processIdentity": owner["identity"]!,
                      "windowID": target.windowID, "bounds": try windowBounds(target.windowID),
                      "active": NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                      "point": ["x": x, "y": y], "elements": elements, "complete": complete])
        case "inspect", "prepare":
            guard let pid = Int32(args[1]), let running = NSRunningApplication(processIdentifier: pid) else { throw fail("application missing") }
            var expectedBounds: CGRect?
            if command == "prepare" {
                guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else { throw fail("input/accessibility permission missing") }
                var requested: CGRect?
                if args.count == 3 {
                    let bounds = try readJSON(args[2])
                    func coordinate(_ key: String, _ limits: ClosedRange<Double>) throws -> Double {
                        guard let value = bounds[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                              value.doubleValue.isFinite, limits.contains(value.doubleValue) else { throw fail("invalid requested window " + key) }
                        return value.doubleValue
                    }
                    requested = try CGRect(x: coordinate("x", -100_000...100_000), y: coordinate("y", -100_000...100_000),
                        width: coordinate("width", 100...16384), height: coordinate("height", 100...16384))
                }
                running.activate(options: [.activateAllWindows])
                let app = AXUIElementCreateApplication(pid)
                if let first = (ax(app, kAXWindowsAttribute) as? [AXUIElement])?.first {
                    var point = CGPoint(x: 50, y: 60)
                    let screen = await MainActor.run { NSScreen.screens.first?.visibleFrame ?? .zero }
                    var size = CGSize(width: min(1280, screen.width - 100), height: min(820, screen.height - 100))
                    if let requested { point = requested.origin; size = requested.size }
                    expectedBounds = CGRect(origin: point, size: size)
                    AXUIElementSetAttributeValue(first, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &point)!)
                    AXUIElementSetAttributeValue(first, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &size)!)
                    AXUIElementPerformAction(first, kAXRaiseAction as CFString)
                }
            }
            var target = try await window(pid)
            if let expected = expectedBounds {
                let deadline = now() + 2_000_000_000
                while target.frame != expected, now() < deadline {
                    try await Task.sleep(nanoseconds: 25_000_000)
                    target = try await window(pid)
                }
                guard target.frame == expected else { throw fail("window did not reach requested OS bounds: requested \(expected), observed \(target.frame)") }
            }
            var budget = 8000
            try emit(["process": process(pid) ?? [:], "launchDate": running.launchDate?.timeIntervalSince1970 as Any? ?? NSNull(),
                      "active": running.isActive, "windowID": target.windowID,
                      "bounds": ["x": target.frame.minX, "y": target.frame.minY, "width": target.frame.width, "height": target.frame.height],
                      "accessibility": ((ax(AXUIElementCreateApplication(pid), kAXWindowsAttribute) as? [AXUIElement]) ?? []).flatMap { axTree($0, budget: &budget) }, "axTruncated": budget == 0])
        case "capture":
            guard let pid = Int32(args[1]), pid > 0 else { throw fail("invalid capture PID") }
            let target = try await window(pid)
            try emit(try await capture(target, args[2]))
        case "ocr": try emit(try recognize(args[1]))
        case "input": try post(try readJSON(args[1])); try emit(["postedNS": now()])
        case "startup":
            let config = try readJSON(args[1])
            let directory = args[2]
            guard var plan = config["plan"] as? Record else { throw fail("startup plan missing") }
            let launch = try launchConfiguration(config["launch"])
            let start = now()
            plan["startNS"] = start
            // Startup has no owner/window yet; validate its input schedule before
            // launching, then validate the complete OS identity before collection.
            var pending = plan
            pending["pid"] = 1; pending["windowID"] = 1; pending["processIdentity"] = "pending"
            try validatePlan(pending)
            let deadline = start + UInt64((plan["warmupSeconds"] as! Double) * 1e9)
            if deadline > now() { try await Task.sleep(nanoseconds: deadline - min(deadline, now())) }
            let options = NSWorkspace.OpenConfiguration()
            options.createsNewApplicationInstance = true
            options.arguments = launch["arguments"] as? [String] ?? []
            options.environment = launch["environment"] as? [String: String] ?? [:]
            let requested = now()
            let requestedWallUS = UInt64(Date().timeIntervalSince1970 * 1_000_000)
            let app = try await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: launch["app"] as! String), configuration: options)
            guard let owner = process(app.processIdentifier) else { throw fail("startup owner missing") }
            let returned = now(), returnedWallUS = UInt64(Date().timeIntervalSince1970 * 1_000_000)
            try write(["requestedNS": requested, "returnedNS": returned, "process": owner,
                       "requestedWallUS": requestedWallUS, "returnedWallUS": returnedWallUS,
                       "launchDate": app.launchDate?.timeIntervalSince1970 as Any? ?? NSNull()], directory + "/launch.json")
            plan["pid"] = Int(app.processIdentifier); plan["processIdentity"] = owner["identity"]
            var roots = plan["processRoots"] as! [Record]
            roots.append(owner.merging(["role": "application"], uniquingKeysWith: { _, new in new }))
            plan["processRoots"] = roots
            // Process accounting does not depend on the existence/settling of a
            // capturable window. Start as soon as the OS returns the new owner.
            let resources = startSampling(plan, directory, owner)
            defer { resources.cancel() }
            let windowDeadline = now() + 10_000_000_000
            var target: SCWindow?
            while now() < windowDeadline {
                target = try? await window(app.processIdentifier)
                if target != nil { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            guard target != nil else { throw fail("startup window deadline exceeded") }
            var stable = 0
            while stable < 3, now() < windowDeadline {
                try await Task.sleep(nanoseconds: 50_000_000)
                let latest = try await window(app.processIdentifier)
                stable = latest.frame == target?.frame ? stable + 1 : 0
                target = latest
            }
            guard let target, stable == 3 else { throw fail("startup OS window did not settle") }
            plan["windowID"] = target.windowID
            plan["windowBounds"] = ["x": target.frame.minX, "y": target.frame.minY, "width": target.frame.width, "height": target.frame.height]
            let events = (plan["events"] as! [Record]).map { event -> Record in
                var row = event
                row["x"] = target.frame.maxX - 70 + (event["x"] as! Double)
                row["y"] = target.frame.maxY - 110 + (event["y"] as! Double)
                return row
            }
            plan["events"] = events
            try write(plan, directory + "/plan.json")
            try await collect(directory + "/plan.json", directory, resources: resources)
        case "collect": try await collect(args[1], args[2])
        default: throw fail("unknown command")
        }
    }
    static func startSampling(_ plan: Record, _ directory: String, _ owner: Record) -> Task<Record, Never> {
        var roots: [Int32: String] = [:]
        for row in plan["processRoots"] as! [Record] { roots[Int32(row["pid"] as! Int)] = row["role"] as? String }
        roots[ProcessInfo.processInfo.processIdentifier] = "collector"
        let sampler = Sampler(roots: roots, output: directory, owner: owner)
        for row in plan["processRoots"] as! [Record] { sampler.identities[Int32(row["pid"] as! Int)] = row["identity"] as? String }
        sampler.runtimeConnection = plan["runtimeConnection"] as? String
        sampler.runtimePath = plan["runtimePath"] as? String
        return Task.detached {
            let start = (plan["startNS"] as! NSNumber).uint64Value
            let end = start + UInt64(((plan["warmupSeconds"] as! Double) + (plan["formalSeconds"] as! Double) + (plan["tailSeconds"] as! Double)) * 1e9)
            let step = UInt64(1e9 / (plan["sampleHz"] as! Double))
            let attached = now()
            let formalStart = start + UInt64((plan["warmupSeconds"] as! Double) * 1e9)
            let formalEnd = formalStart + UInt64((plan["formalSeconds"] as! Double) * 1e9)
            var deadlines = Set(stride(from: start, through: end, by: Int(step)).filter { $0 >= attached })
            deadlines.formUnion([max(start, attached), formalStart, formalEnd, end].filter { $0 >= attached && $0 <= end })
            for deadline in deadlines.sorted() {
                if Task.isCancelled { break }
                sleepUntil(deadline); sampler.sample()
            }
            return sampler.finish()
        }
    }
    static func collect(_ planPath: String, _ directory: String, resources earlyResources: Task<Record, Never>? = nil) async throws {
        let plan = try readJSON(planPath)
        try validatePlan(plan)
        let pid = Int32(plan["pid"] as! Int)
        guard let owner = process(pid) else { throw fail("target unavailable") }
        guard owner["identity"] as? String == plan["processIdentity"] as? String else { throw fail("target identity changed") }
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else { throw fail("system input capability missing") }
        let observed = plan["mode"] as? String == "observed"
        if observed && !CGPreflightScreenCaptureAccess() { throw fail("capture capability missing") }
        let target = try await window(pid)
        guard Int(target.windowID) == plan["windowID"] as? Int else { throw fail("window identity changed") }
        let actualBounds: Record = ["x": Double(target.frame.minX), "y": Double(target.frame.minY), "width": Double(target.frame.width), "height": Double(target.frame.height)]
        if let expected = plan["windowBounds"] as? Record {
            guard ["x", "y", "width", "height"].allSatisfy({ (expected[$0] as? Double) == (actualBounds[$0] as? Double) }) else { throw fail("prepared window bounds changed before collection") }
        }
        let start = (plan["startNS"] as! NSNumber).uint64Value
        let warmup = UInt64((plan["warmupSeconds"] as! Double) * 1e9)
        let formal = UInt64((plan["formalSeconds"] as! Double) * 1e9)
        let tail = UInt64((plan["tailSeconds"] as! Double) * 1e9)
        let formalStart = start + warmup, formalEnd = formalStart + formal, end = formalEnd + tail
        let startup = plan["scenario"] as? String == "first-render"
        guard startup || start > now() + 200_000_000 else { throw fail("collector missed start deadline") }
        let resourceTask = earlyResources ?? startSampling(plan, directory, owner)
        defer { resourceTask.cancel() }
        let inputTask = Task.detached { () -> [Record] in
            var receipts: [Record] = []
            var held: Record?
            defer {
                // Releasing our own pressed button is cleanup even if focus was
                // lost. No subsequent planned gesture is sent to another app.
                if var release = held { release["kind"] = "up"; try? post(release) }
            }
            for event in plan["events"] as! [Record] {
                let deadline = formalStart + UInt64((event["atSeconds"] as! Double) * 1e9)
                sleepUntil(deadline)
                var row = event; row["plannedNS"] = deadline
                if process(pid)?["identity"] as? String != owner["identity"] as? String { row["error"] = "target exited or changed" }
                else if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
                    row["error"] = "target lost foreground; input suppressed"
                } else {
                    do {
                        try post(event)
                        if event["kind"] as? String == "down" { held = event }
                        if event["kind"] as? String == "up" { held = nil }
                    } catch { row["error"] = String(describing: error) }
                }
                row["postedNS"] = now(); receipts.append(row)
            }
            return receipts
        }
        var frames: [Record] = [], errors: [String] = []
        if observed {
            let step = UInt64(1e9 / (plan["captureHz"] as! Double))
            var deadline = max(start, now()), sequence = 0
            while deadline <= end {
                let wait = deadline > now() ? deadline - now() : 0
                if wait > 0 { try await Task.sleep(nanoseconds: wait) }
                do {
                    var frame = try await capture(target, directory + "/frame-\(sequence).png")
                    frame["plannedNS"] = deadline; frames.append(frame)
                } catch { errors.append(String(describing: error)) }
                sequence += 1; deadline += step
                // Do not fabricate samples for deadlines that were missed.
                while deadline < now() { deadline += step }
            }
        }
        let resources = await resourceTask.value, inputs = await inputTask.value
        let bounds: Record = ["warmupStart": start, "formalStart": formalStart, "formalEnd": formalEnd, "tailEnd": end]
        try write(["version": 1, "kind": "observation", "clock": "macos.mach_absolute_time.nanoseconds", "cpuTimeUnit": "nanoseconds",
                   "boundaries": bounds, "windowBounds": actualBounds, "inputs": inputs, "resources": resources["samples"]!,
                   "processCoverage": resources["coverage"]!, "frames": frames, "captureErrors": errors,
                   "owner": owner, "productExited": process(pid)?["identity"] as? String != owner["identity"] as? String], directory + "/observation.json")
        try emit(["completed": true, "frames": frames.count, "inputs": inputs.count])
    }
}
