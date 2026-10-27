import Foundation
import OSLog
import Synchronization

/// Local performance observations. No business identifiers or content belong here.
/// CPU spans use a monotonic clock; visual metrics retain their source timestamps.
public enum NativePerformance {
    public enum Mode: String, Sendable { case off, summary, detailed }
    public enum Outcome: String, Sendable { case completed, cancelled, failed }
    public enum Metric: String, Sendable, CaseIterable {
        case startupShellReady = "startup.shellReady", startupDataReady = "startup.dataReady"
        case startupTimeToReady = "startup.timeToReady", startupFailed = "startup.failed", startupCancelled = "startup.cancelled"
        case threadVisit = "thread.visit", threadOpen = "thread.open", threadNavigate = "thread.navigate", surface = "surface"
        case contentReady = "content.ready", contentAck = "content.ack", contentPatch = "content.patch"
        case harnessRender = "harness.render"
        case markdownDelivery = "markdown.delivery", markdownParse = "markdown.parse", markdownCache = "markdown.cache"
        case textCreate = "text.create", textUpdate = "text.update", textAttributed = "text.attributed"
        case textReplace = "text.replace", textLayout = "text.layout", textCache = "text.cache"
        case readingPrepare = "reading.prepare", readingTransition = "reading.transition"
        case scrollGesture = "scroll.gesture", scrollGeometry = "scroll.geometry"
        case metalSurface = "metal.surface", metalActive = "metal.active", metalCallback = "metal.callback", metalCapture = "metal.capture"
        case metalUpload = "metal.upload", metalSubmit = "metal.submit", metalGPU = "metal.gpu"
        case metalPresented = "metal.presented", metalSkipped = "metal.skipped"
        case windowFlush = "window.flush", mainDelay = "main.delay", display = "display"
        case windowPresented = "window.presented"
        case voiceStartup = "voice.startup", voiceOwnership = "voice.ownership", voiceBeforeStart = "voice.beforeStart"
        case voicePrepare = "voice.prepare", voiceMicrophonePermission = "voice.microphonePermission"
        case voiceOffer = "voice.offer", voiceFactory = "voice.factory", voiceLocalSDP = "voice.localSDP", voiceICE = "voice.ice"
        case voiceRemoteSDP = "voice.remoteSDP", voiceConnect = "voice.connect", voicePeerReady = "voice.peerReady", voiceAudioReady = "voice.audioReady"
        case voiceMediaHealth = "voice.mediaHealth"
        case scenario = "scenario"
    }

    private struct Registry { var recorder: NativePerformanceRecorder?; var sequence: UInt64 = 0 }
    private static let registry = Mutex(Registry())
    @TaskLocal public static var context: UInt64?

    public static var defaultMode: Mode {
        #if DEBUG
        .detailed
        #else
        .off
        #endif
    }
    public static var mode: Mode { registry.withLock { $0.recorder?.mode ?? .off } }
    public static var recordingID: UUID? { registry.withLock { $0.recorder?.recordingID } }
    public static var outputURL: URL? { registry.withLock { $0.recorder?.currentURL } }

    /// Call once at application/probe startup. An explicit mode overrides the environment.
    @discardableResult
    public static func configure(directory: URL, mode: Mode? = nil) -> URL? {
        let environment = ProcessInfo.processInfo.environment
        let selected = mode ?? environment["MOKUSEI_PERFORMANCE"].flatMap(Mode.init(rawValue:)) ?? defaultMode
        let output = environment["MOKUSEI_PERFORMANCE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? directory
        let next = selected == .off ? nil : NativePerformanceRecorder(directory: output, mode: selected)
        let previous = registry.withLock { state in let previous = state.recorder; state.recorder = next; return previous }
        previous?.finish()
        return next?.currentURL
    }

    public static func nextID() -> UInt64 {
        registry.withLock { state in state.sequence &+= 1; return state.sequence }
    }
    public static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    public static func makeSurfaceContext(parent: UInt64?, execution: Bool) -> UInt64? {
        guard let recorder = registry.withLock({ $0.recorder }) else { return nil }
        let id = nextID()
        recorder.append(.init(kind: "context", metric: Metric.surface.rawValue, id: id, context: parent,
                              time: now(), values: ["execution": execution ? 1 : 0]))
        return id
    }

    public static func begin(_ metric: Metric, context: UInt64? = nil,
                             values: @autoclosure () -> [String: Double] = [:]) -> NativePerformanceSpan? {
        guard let recorder = registry.withLock({ $0.recorder }) else { return nil }
        return NativePerformanceSpan(recorder: recorder, metric: metric, id: nextID(),
                                     context: context ?? Self.context, values: bounded(values()))
    }
    public static func event(_ metric: Metric, context: UInt64? = nil, values: @autoclosure () -> [String: Double] = [:]) {
        guard let recorder = registry.withLock({ $0.recorder }) else { return }
        recorder.append(.init(kind: "event", metric: metric.rawValue, id: nextID(), context: context ?? Self.context,
                              time: now(), values: bounded(values())))
    }
    public static func sample(_ metric: Metric, milliseconds: Double, context: UInt64? = nil,
                              values: @autoclosure () -> [String: Double] = [:]) {
        guard milliseconds.isFinite, milliseconds >= 0,
              let recorder = registry.withLock({ $0.recorder }) else { return }
        recorder.append(.init(kind: "event", metric: metric.rawValue, id: nextID(), context: context ?? Self.context,
                              time: now(), durationMs: milliseconds, values: bounded(values())))
    }
    fileprivate static func bounded(_ values: [String: Double]) -> [String: Double] {
        Dictionary(uniqueKeysWithValues: values.lazy.filter { $0.key.utf8.count <= 48 && $0.value.isFinite }.prefix(24).map { ($0.key, $0.value) })
    }
    /// Normal shutdown only. Periodic drains are asynchronous and never write on the UI thread.
    public static func finish() {
        let recorder = registry.withLock { state in let result = state.recorder; state.recorder = nil; return result }
        recorder?.finish()
    }
}

public final class NativePerformanceSpan: @unchecked Sendable {
    public let id: UInt64
    public var recordingID: UUID { recorder.recordingID }
    public var hasEnded: Bool { ended.withLock { $0 } }
    private let recorder: NativePerformanceRecorder
    private let metric: NativePerformance.Metric
    private let context: UInt64?
    private let start: UInt64
    private let values: [String: Double]
    private let ended = Mutex(false)
    private let signpost: OSSignpostIntervalState?

    fileprivate init(recorder: NativePerformanceRecorder, metric: NativePerformance.Metric, id: UInt64,
                     context: UInt64?, values: [String: Double]) {
        self.recorder = recorder; self.metric = metric; self.id = id; self.context = context
        self.values = values; start = NativePerformance.now()
        signpost = recorder.mode == .detailed
            ? recorder.signposter.beginInterval("Native performance", id: OSSignpostID(id), "\(metric.rawValue, privacy: .public)") : nil
        recorder.append(.init(kind: "begin", metric: metric.rawValue, id: id, context: context, time: start, values: values))
    }
    public func end(_ outcome: NativePerformance.Outcome = .completed, values: [String: Double] = [:]) {
        guard ended.withLock({ value in if value { return false }; value = true; return true }) else { return }
        if let signpost { recorder.signposter.endInterval("Native performance", signpost) }
        let end = NativePerformance.now()
        recorder.append(.init(kind: "end", metric: metric.rawValue, id: id, context: context, time: end,
            durationMs: Double(end - start) / 1_000_000, outcome: outcome.rawValue,
            values: NativePerformance.bounded(self.values.merging(values) { _, new in new })))
    }
    deinit { end(.cancelled) }
}

private struct PerformanceRecord: Sendable {
    let kind: String
    let metric: String
    let id: UInt64
    let context: UInt64?
    let time: UInt64
    var durationMs: Double? = nil
    var outcome: String? = nil
    let values: [String: Double]
}

/// The bounded producer queue only holds numeric observations. JSON encoding,
/// aggregation and file IO run on one utility queue, including periodic drains.
private final class NativePerformanceRecorder: @unchecked Sendable {
    let recordingID = UUID()
    let mode: NativePerformance.Mode
    let url: URL
    private let currentFile = Mutex<URL?>(nil)
    var currentURL: URL { currentFile.withLock { $0 ?? url } }
    let signposter = OSSignposter(subsystem: "com.mokusei.desktop", category: "performance")
    private let origin = NativePerformance.now()
    private let session = UUID().uuidString
    private struct Pending { var records: [PerformanceRecord] = []; var dropped = 0; var closed = false }
    private let pending = Mutex(Pending())
    private let queue = DispatchQueue(label: "com.mokusei.performance.writer", qos: .utility)
    private var timer: DispatchSourceTimer?
    // Accessed only on queue, after initialization.
    private var file: FileHandle?
    private var bytes = 0
    private var truncated = false
    private var writeFailed = false
    private var dropped = 0
    private var active: [UInt64: PerformanceRecord] = [:]
    private var segment = 0
    private var header: [String: Any] = [:]
    private var lastSummary = NativePerformance.now()
    private struct Aggregate {
        var count = 0, failed = 0, cancelled = 0
        var durationCount = 0
        var totalMs = 0.0, maxMs = 0.0
        mutating func add(_ record: PerformanceRecord) {
            count += 1
            if record.outcome == "failed" { failed += 1 }
            if record.outcome == "cancelled" { cancelled += 1 }
            if let duration = record.durationMs { durationCount += 1; totalMs += duration; maxMs = max(maxMs, duration) }
        }
        var json: [String: Any] {
            ["count": count, "failed": failed, "cancelled": cancelled, "durationCount": durationCount,
             "totalMs": totalMs, "maxMs": maxMs]
        }
    }
    private var aggregates: [String: Aggregate] = [:]
    private static let maximumBytes = 32 * 1024 * 1024
    private static let maximumPending = 8192

    init?(directory: URL, mode: NativePerformance.Mode) {
        self.mode = mode
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        url = directory.appendingPathComponent("native-\(stamp)-\(ProcessInfo.processInfo.processIdentifier)-\(session).jsonl")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            // Retain at most 12 completed/abandoned sessions. Never remove an active process's file.
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("native-") && $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            for old in files.prefix(max(0, files.count - 11)) {
                let components = old.deletingPathExtension().lastPathComponent.split(separator: "-")
                if components.count >= 3, let pid = Int32(components[2]) {
                    let dead = kill(pid, 0) != 0 && errno == ESRCH
                    var closedHere = false
                    if pid == ProcessInfo.processInfo.processIdentifier, let handle = try? FileHandle(forReadingFrom: old) {
                        if let length = try? handle.seekToEnd() {
                            try? handle.seek(toOffset: length > 4096 ? length - 4096 : 0)
                            if let tail = try? handle.readToEnd(), let text = String(data: tail, encoding: .utf8) {
                                closedHere = text.contains("\"kind\":\"sessionEnd\"")
                            }
                        }
                        try? handle.close()
                    }
                    if dead || closedHere { try? FileManager.default.removeItem(at: old) }
                }
            }
            guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { return nil }
            file = try FileHandle(forWritingTo: url)
        } catch { return nil }
        var hardware = utsname(); uname(&hardware)
        let machine = withUnsafeBytes(of: &hardware.machine) { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        var modelSize = 0
        sysctlbyname("hw.model", nil, &modelSize, nil, 0)
        var model = [UInt8](repeating: 0, count: max(1, modelSize))
        let modelRead = sysctlbyname("hw.model", &model, &modelSize, nil, 0) == 0
        let modelName = modelRead ? String(decoding: model.prefix(while: { $0 != 0 }), as: UTF8.self) : "unknown"
        #if DEBUG
        let build = "debug"
        #else
        let build = "release"
        #endif
        header = ["kind": "session", "schema": 1, "session": session, "mode": mode.rawValue,
               "build": build, "startedAt": ISO8601DateFormatter().string(from: Date()), "originNs": String(origin),
               "os": ProcessInfo.processInfo.operatingSystemVersionString, "machine": machine, "model": modelName,
               "cpuCount": ProcessInfo.processInfo.processorCount, "memoryBytes": ProcessInfo.processInfo.physicalMemory,
               "pid": ProcessInfo.processInfo.processIdentifier, "segment": 0]
        write(header)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250), leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.drain() }
        timer.resume(); self.timer = timer
    }

    func append(_ record: PerformanceRecord) {
        pending.withLock { state in
            guard !state.closed else { return }
            guard state.records.count < Self.maximumPending else { state.dropped += 1; return }
            state.records.append(record)
        }
    }
    private func drain() {
        let batch = pending.withLock { state in
            let result = (state.records, state.dropped)
            state.records = []; state.dropped = 0
            return result
        }
        dropped += batch.1
        for record in batch.0 {
            if bytes >= Self.maximumBytes, !truncated { rotate() }
            if record.kind == "begin" {
                if active.count < Self.maximumPending { active[record.id] = record }
                else { dropped += 1 }
            } else if record.kind == "end" { active[record.id] = nil }
            if record.kind != "begin" { aggregates[record.metric, default: Aggregate()].add(record) }
            guard mode == .detailed, !truncated else { continue }
            writeRecord(record)
        }
        if mode == .summary, !truncated, NativePerformance.now() - lastSummary >= 5_000_000_000 {
            if bytes >= Self.maximumBytes, !truncated { rotate() }
            if !truncated { write(["kind": "summarySnapshot", "timeMs": Double(NativePerformance.now() - origin) / 1_000_000,
                                  "metrics": aggregates.mapValues(\.json), "dropped": dropped]) }
            lastSummary = NativePerformance.now()
        }
    }
    private func writeRecord(_ record: PerformanceRecord) {
        var value: [String: Any] = ["kind": record.kind, "metric": record.metric, "id": record.id,
                "timeMs": Double(record.time - origin) / 1_000_000,
                "values": record.values.filter { $0.value.isFinite }]
        if let context = record.context { value["context"] = context }
        if let duration = record.durationMs { value["durationMs"] = duration }
        if let outcome = record.outcome { value["outcome"] = outcome }
        write(value)
    }
    private func rotate() {
        let next = url.deletingPathExtension().appendingPathExtension("part\(segment + 1).jsonl")
        guard FileManager.default.createFile(atPath: next.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let opened = try? FileHandle(forWritingTo: next) else {
            truncated = true
            write(["kind": "dataLoss", "reason": "rotation-failed"])
            return
        }
        write(["kind": "sessionEnd", "continued": true, "dropped": dropped, "truncated": false, "writeFailed": writeFailed])
        try? file?.close()
        segment += 1; bytes = 0
        file = opened
        currentFile.withLock { $0 = next }
        header["segment"] = segment
        write(header)
        // Retained active intervals can have started in a previous segment.
        for record in active.values { writeRecord(record) }
        if segment >= 12 {
            let old = segment == 12 ? url : url.deletingPathExtension().appendingPathExtension("part\(segment - 12).jsonl")
            try? FileManager.default.removeItem(at: old)
        }
    }
    private func write(_ value: [String: Any]) {
        guard !writeFailed, let file else { return }
        do {
            var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            data.append(10); try file.write(contentsOf: data); bytes += data.count
        } catch {
            writeFailed = true
            Logger(subsystem: "com.mokusei.desktop", category: "performance").error("Performance output write failed")
        }
    }
    func finish() {
        let first = pending.withLock { state in if state.closed { return false }; state.closed = true; return true }
        guard first else { return }
        timer?.cancel(); timer = nil
        queue.sync {
            drain()
            let end = NativePerformance.now()
            for start in active.values {
                let record = PerformanceRecord(kind: "end", metric: start.metric, id: start.id, context: start.context,
                    time: end, durationMs: Double(end - start.time) / 1_000_000, outcome: "cancelled", values: start.values)
                aggregates[record.metric, default: Aggregate()].add(record)
                if mode == .detailed { writeRecord(record) }
            }
            active.removeAll()
            write(["kind": "summary", "metrics": aggregates.mapValues(\.json)])
            write(["kind": "sessionEnd", "timeMs": Double(NativePerformance.now() - origin) / 1_000_000,
                   "dropped": dropped, "truncated": truncated, "writeFailed": writeFailed,
                   "segment": segment, "overwrittenSegments": max(0, segment - 11)])
            try? file?.synchronize(); try? file?.close(); file = nil
        }
    }
}
