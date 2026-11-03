import Darwin
import Foundation
import Synchronization

struct NativeLayoutGeometry: Encodable, Equatable, Sendable {
    let frame: CGRect
    let bounds: CGRect

    private enum CodingKeys: String, CodingKey { case frame, bounds }

    func encode(to encoder: Encoder) throws {
        // Keep snapshots as value types on the layout path; allocate JSON arrays
        // only on the writer queue. No rounding hides small geometry changes.
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode([frame.origin.x, frame.origin.y, frame.width, frame.height], forKey: .frame)
        try container.encode([bounds.origin.x, bounds.origin.y, bounds.width, bounds.height], forKey: .bounds)
    }
}

struct NativeLayoutRecord: Encodable, Sendable {
    var sequence: UInt64 = 0
    let time: Date
    let uptimeNs: UInt64
    let kind: String
    let source: String
    let component: String
    let role: String
    var window: String? = nil
    var parent: String? = nil
    var sibling: Int? = nil
    var flipped: Bool? = nil
    var before: NativeLayoutGeometry? = nil
    var after: NativeLayoutGeometry? = nil
}

/// A separate diagnostic stream: performance aggregation cannot retain before/after
/// geometry or semantic component identities. Only the bounded mailbox is shared;
/// encoding, retention and IO belong to the utility queue.
final class NativeLayoutLogWriter: @unchecked Sendable {
    let directory: URL
    private struct Pending {
        var records: [NativeLayoutRecord] = []
        var sequence: UInt64 = 0
        var dropped = 0
        var closed = false
    }
    private let pending = Mutex(Pending())
    private let queue = DispatchQueue(label: "com.mokusei.layout.writer", qos: .utility)
    private var timer: DispatchSourceTimer?
    // The following state is confined to queue.
    private var file: FileHandle?
    private var lease: Int32 = -1
    private var bytes = 0
    private var segment = 0
    private var failed = false
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }()
    private static let segmentBytes = 8 * 1024 * 1024
    private static let retainedSegments = 4
    private static let maximumPending = 4096

    init(directory root: URL) {
        directory = root.appendingPathComponent("layout-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)", isDirectory: true)
        queue.async { [self] in
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                lease = open(directory.appendingPathComponent("owner.lock").path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW, 0o600)
                guard lease >= 0, flock(lease, LOCK_EX | LOCK_NB) == 0 else { throw CocoaError(.fileWriteUnknown) }
                prune(root)
                try openSegment()
            } catch { fail() }
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250), leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.drain() }
        timer.resume()
        self.timer = timer
    }

    func append(_ record: NativeLayoutRecord) {
        pending.withLock { state in
            guard !state.closed else { return }
            state.sequence &+= 1
            guard state.records.count < Self.maximumPending else { state.dropped += 1; return }
            var record = record
            record.sequence = state.sequence
            state.records.append(record)
        }
    }

    private func drain() {
        let batch = pending.withLock { state in
            let batch = (state.records, state.dropped, state.sequence)
            state.records = []; state.dropped = 0
            return batch
        }
        guard !failed else { return }
        do {
            // One write per batch/segment, rather than one syscall per view.
            var data = Data()
            for record in batch.0 {
                var line = try encoder.encode(record); line.append(10)
                if bytes + data.count + line.count > Self.segmentBytes {
                    try file?.write(contentsOf: data); data.removeAll(keepingCapacity: true)
                    try file?.close(); segment += 1; try openSegment()
                }
                data.append(line)
            }
            if batch.1 > 0 {
                data.append(try json(["kind": "dataLoss", "dropped": batch.1, "throughSequence": batch.2]))
            }
            try file?.write(contentsOf: data); bytes += data.count
        } catch { fail() }
    }

    private func json(_ value: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        data.append(10); return data
    }

    private func segmentURL(_ index: Int) -> URL { directory.appendingPathComponent("events-\(index).jsonl") }

    private func openSegment() throws {
        let descriptor = open(segmentURL(segment).path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let header = try json(["kind": "session", "schema": 1, "pid": ProcessInfo.processInfo.processIdentifier,
            "segment": segment, "overwrittenSegments": max(0, segment - Self.retainedSegments + 1),
            "startedAt": ISO8601DateFormatter().string(from: Date()),
            "rectOrder": ["x", "y", "width", "height"], "units": "points",
            "presentationSampling": false])
        try file?.write(contentsOf: header); bytes = header.count
        if segment >= Self.retainedSegments { try FileManager.default.removeItem(at: segmentURL(segment - Self.retainedSegments)) }
    }

    private func prune(_ root: URL) {
        // Coordinate pruning across dev generations; each active writer retains
        // its own lease, so another process never deletes a live recording.
        let coordination = open(root.appendingPathComponent("retention.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard coordination >= 0 else { return }
        defer { close(coordination) }
        guard flock(coordination, LOCK_EX | LOCK_NB) == 0 else { return }
        let files = (try? FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey, .isSymbolicLinkKey])) ?? []
        let candidates = files.filter {
            let values = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return $0 != directory && $0.lastPathComponent.hasPrefix("layout-")
                && values?.isDirectory == true && values?.isSymbolicLink != true
        }.sorted {
            ((try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast)
                > ((try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast)
        }
        var inactive = 0
        for candidate in candidates {
            let lock = open(candidate.appendingPathComponent("owner.lock").path, O_RDWR | O_NOFOLLOW)
            guard lock >= 0 else { continue }
            if flock(lock, LOCK_EX | LOCK_NB) == 0 {
                inactive += 1
                if inactive > 7 { try? FileManager.default.removeItem(at: candidate) }
            }
            close(lock)
        }
    }

    private func fail() {
        guard !failed else { return }
        failed = true
        pending.withLock { $0.closed = true; $0.records.removeAll() }
        FileHandle.standardError.write(Data("[layout-log] file output failed; recording stopped\n".utf8))
    }

    func finish() {
        let first = pending.withLock { state in
            guard !state.closed else { return false }; state.closed = true; return true
        }
        // Even an IO failure must release the session lease and file.
        timer?.cancel(); timer = nil
        queue.sync {
            if first { drain() }
            if !failed {
                do { try file?.write(contentsOf: json(["kind": "sessionEnd", "segment": segment])) }
                catch { fail() }
            }
            try? file?.close(); file = nil
            if lease >= 0 { close(lease); lease = -1 }
        }
    }
}
