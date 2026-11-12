import Darwin
import Foundation
import Synchronization

/// Kept separately from geometry traffic. Byte ranges refer to the original,
/// append-only launch stderr, not to the incident journal's encoded bytes.
struct NativeLayoutIncident: Encodable, Sendable {
    var sequence: UInt64 = 0
    let kind: String
    var time = Date()
    var uptimeNs = DispatchTime.now().uptimeNanoseconds
    var observedAfter: Date?
    var observedAfterUptimeNs: UInt64?
    var byteStart: Int64?
    var byteEnd: Int64?
    var attribute: String?
    var operation: String?
    var component: String?
    var location: String?
    var threadID: UInt64?
    var boundaryStack: [String]?
    var status: String?
}

/// Observe the existing regular file without redirecting stderr, intercepting
/// framework functions, or sampling a running thread. No raw stderr is copied:
/// only an exact AttributeGraph warning is admitted to the private journal.
final class NativeAttributeGraphDiagnostics: @unchecked Sendable {
    private let writer: NativeLayoutLogWriter
    private let descriptor: Int32
    private let device: dev_t
    private let inode: ino_t
    private struct SourceState {
        var active = true
        var highWatermark: Int64
    }
    private let source: Mutex<SourceState>
    private let queue = DispatchQueue(label: "com.mokusei.attributegraph.reader", qos: .utility)
    // The remaining state belongs to queue, including close and final polling.
    private var timer: DispatchSourceTimer?
    private var stopped = false
    private var offset: Int64
    private var observedAt = Date()
    private var observedUptime = DispatchTime.now().uptimeNanoseconds
    private var line = Data()
    private var lineStart: Int64 = 0
    private var lineAfter = Date()
    private var lineAfterUptime: UInt64 = 0
    private var oversized = false

    init?(writer: NativeLayoutLogWriter) {
        var info = stat()
        guard fstat(STDERR_FILENO, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            writer.appendIncident(.init(kind: "captureStatus", status: "stderr-not-regular-file"))
            return nil
        }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(STDERR_FILENO, F_GETPATH, &path) == 0 else {
            writer.appendIncident(.init(kind: "captureStatus", status: "stderr-path-unavailable"))
            return nil
        }
        let reader = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        var opened = stat()
        guard reader >= 0, fstat(reader, &opened) == 0,
              opened.st_dev == info.st_dev, opened.st_ino == info.st_ino else {
            if reader >= 0 { close(reader) }
            writer.appendIncident(.init(kind: "captureStatus", status: "stderr-reader-unavailable"))
            return nil
        }
        self.writer = writer; descriptor = reader; device = info.st_dev; inode = info.st_ino
        source = Mutex(SourceState(highWatermark: info.st_size))
        // Startup before admission has no bounded observation time. Do not
        // relabel old file contents as warnings emitted in this session.
        offset = info.st_size
        writer.appendIncident(.init(kind: "captureStatus", byteStart: offset, status: "watching-stderr"))
        queue.async { [self] in
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .milliseconds(200), repeating: .milliseconds(200),
                           leeway: .milliseconds(50))
            timer.setEventHandler { [weak self] in self?.poll() }
            self.timer = timer
            timer.resume()
        }
    }

    /// A caller stack and byte enclosure are evidence of the application
    /// boundary, not the framework's cycle stack or proof of the emitter thread.
    @MainActor
    func operation<T>(_ name: StaticString, component: UUID, file: StaticString, line: UInt,
                      _ body: () throws -> T) rethrows -> T {
        guard let before = stderrSize() else { return try body() }
        let started = Date(), uptime = DispatchTime.now().uptimeNanoseconds
        defer {
            if let after = stderrSize(), after > before {
                var thread: UInt64 = 0
                pthread_threadid_np(nil, &thread)
                writer.appendIncident(.init(kind: "operation", observedAfter: started,
                    observedAfterUptimeNs: uptime, byteStart: before, byteEnd: after,
                    operation: "\(name)", component: component.uuidString, location: "\(file):\(line)",
                    threadID: thread, boundaryStack: Thread.callStackSymbols.prefix(40).map { String($0.prefix(1024)) }))
            }
        }
        return try body()
    }

    private func stderrSize() -> Int64? {
        // Serialize metadata observations too: an older fstat result must not
        // look like truncation after a newer observation on another thread.
        source.withLock { state in
            guard state.active else { return nil }
            var info = stat()
            guard fstat(STDERR_FILENO, &info) == 0, info.st_dev == device, info.st_ino == inode,
                  info.st_size >= state.highWatermark else {
                state.active = false
                return nil
            }
            state.highWatermark = info.st_size
            return info.st_size
        }
    }

    private func poll() {
        guard !stopped else { return }
        let snapshotAt = Date(), snapshotUptime = DispatchTime.now().uptimeNanoseconds
        defer { observedAt = snapshotAt; observedUptime = snapshotUptime }
        guard let size = stderrSize(), size >= offset else {
            stop(status: "stderr-replaced-or-truncated")
            return
        }
        guard size > offset else { return }
        // Bound each turn even if another subsystem floods stderr. A skipped
        // region is an explicit evidence gap, never a zero-warning result.
        let budget: Int64 = 256 * 1024
        if size - offset > budget {
            writer.appendIncident(.init(kind: "captureGap", byteStart: offset, byteEnd: size - budget,
                                        status: "stderr-read-budget"))
            offset = size - budget; line.removeAll(keepingCapacity: true); oversized = true
        }
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while offset < size {
            let count = pread(descriptor, &buffer, min(buffer.count, Int(size - offset)), off_t(offset))
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { stop(status: "stderr-read-failed"); return }
            let now = Date(), uptime = DispatchTime.now().uptimeNanoseconds
            for byte in buffer.prefix(count) {
                if line.isEmpty && !oversized {
                    lineStart = offset; lineAfter = observedAt; lineAfterUptime = observedUptime
                }
                offset += 1
                if byte == 10 {
                    if !oversized { admitLine(end: offset, now: now, uptime: uptime) }
                    line.removeAll(keepingCapacity: true); oversized = false
                } else if !oversized {
                    if line.count < 160 { line.append(byte) }
                    else { line.removeAll(keepingCapacity: true); oversized = true }
                }
            }
        }
    }

    private func admitLine(end: Int64, now: Date, uptime: UInt64) {
        let prefix = Data("=== AttributeGraph: cycle detected through attribute ".utf8)
        let suffix = Data(" ===".utf8)
        guard line.starts(with: prefix), line.count > prefix.count + suffix.count,
              line.suffix(suffix.count) == suffix else { return }
        let digits = line.dropFirst(prefix.count).dropLast(suffix.count)
        guard digits.count <= 20, digits.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return }
        writer.appendIncident(.init(kind: "cycle", time: now, uptimeNs: uptime,
            observedAfter: lineAfter, observedAfterUptimeNs: lineAfterUptime,
            byteStart: lineStart, byteEnd: end, attribute: String(decoding: digits, as: UTF8.self)))
    }

    private func stop(status: String? = nil) {
        guard !stopped else { return }
        stopped = true; timer?.cancel(); timer = nil
        source.withLock { $0.active = false }
        if let status { writer.appendIncident(.init(kind: "captureStatus", status: status)) }
        close(descriptor)
    }

    func finish(completion: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            poll()
            if !line.isEmpty || oversized {
                writer.appendIncident(.init(kind: "captureStatus", status: "incomplete-stderr-line-at-finish"))
            }
            stop(); completion()
        }
    }
}
