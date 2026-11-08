import Darwin
import Foundation

/// Each transaction reads the current profile journal while holding the same
/// kernel lock. A client's restored snapshot is never a replacement document.
struct RuntimeCommandJournal: Sendable {
    typealias Records = [String: RuntimeCommandRecord]
    struct Admission {
        let records: Records
        let alreadySubmitted: Bool
    }
    let storageDirectory: URL
    private var file: URL { storageDirectory.appendingPathComponent("client-command-journal.json") }

    func read() throws -> Records { try withLock { try readLocked() } }

    func insert(_ record: RuntimeCommandRecord) throws -> Admission {
        guard record.forkReceiptID == nil else { throw Self.conflict() }
        var alreadySubmitted = false
        let records = try transaction { records in
            alreadySubmitted = records[record.id] != nil
            try Self.insert(record, into: &records)
        }
        return Admission(records: records, alreadySubmitted: alreadySubmitted)
    }

    func remove(_ id: String, matching expected: RuntimeCommandRecord? = nil,
                when permitted: (RuntimeCommandRecord) throws -> Bool = { _ in true }) throws -> Records {
        try transaction { records in
            guard let record = records[id] else { return }
            if let expected {
                guard Self.sameRequest(record, expected), record.forkReceiptID == expected.forkReceiptID else { throw Self.conflict() }
            }
            if try permitted(record) { records.removeValue(forKey: id) }
        }
    }

    func updateStatus(of expected: RuntimeCommandRecord, to status: RuntimeCommandOutcome.Status) throws -> Records {
        try transaction { records in
            // Another client may have consumed this receipt during HTTP I/O.
            // Observation cannot recreate a command that no longer exists.
            guard var record = records[expected.id] else { return }
            guard Self.sameRequest(record, expected), record.forkReceiptID == expected.forkReceiptID else { throw Self.conflict() }
            if record.status == .accepted || record.status == .rejected {
                if (status == .accepted || status == .rejected), status != record.status {
                    throw RuntimeError("COMMAND_RECEIPT_CONFLICT", "The host returned conflicting outcomes for the same command")
                }
                return
            }
            if record.status == .indeterminate, [.awaitingReceipt, .pending, .unknown].contains(status) { return }
            record.status = status
            records[record.id] = record
        }
    }

    func replace(predecessorID: String, successor: RuntimeCommandRecord) throws -> Admission {
        var alreadySubmitted = false
        let records = try transaction { records in
            guard successor.channel == "thread:follow-up",
                  successor.id != predecessorID, successor.forkReceiptID == nil, successor.status == .awaitingReceipt else {
                throw Self.missingPredecessor(predecessorID)
            }
            // A concurrent admission may already have transferred the
            // predecessor. The transaction decides whether to query or send.
            if records[successor.id] != nil {
                try Self.insert(successor, into: &records)
                alreadySubmitted = true
                return
            }
            guard let predecessor = records[predecessorID] else { throw Self.missingPredecessor(predecessorID) }
            let forkReceiptID: String
            if predecessor.channel == "thread:fork", predecessor.status == .accepted { forkReceiptID = predecessor.id }
            else if predecessor.channel == "thread:follow-up", predecessor.status == .rejected, let fork = predecessor.forkReceiptID { forkReceiptID = fork }
            else { throw Self.missingPredecessor(predecessorID) }
            var next = successor
            next.forkReceiptID = forkReceiptID
            records.removeValue(forKey: predecessorID)
            try Self.insert(next, into: &records)
        }
        return Admission(records: records, alreadySubmitted: alreadySubmitted)
    }

    static func checkAdmission(channel: String, key: String, records: Records, excluding: String? = nil) throws {
        let channels: Set<String>
        let code: String
        if channel == "moku:submit" {
            channels = ["moku:submit"]
            code = "MOKU_SUBMISSION_RECEIPT_REQUIRED"
        } else if channel == "thread:fork" || channel == "thread:follow-up" {
            channels = ["thread:fork", "thread:follow-up"]
            code = "CONTINUATION_RECEIPT_REQUIRED"
        } else { return }
        if let held = records.values.sorted(by: { $0.id < $1.id }).first(where: {
            $0.id != excluding && channels.contains($0.channel) && $0.key != key
                && (channel == "moku:submit" ? $0.status != .rejected : $0.outcome.requiresContinuationContext)
        }) {
            throw RuntimeError(code, "A previous command still owns receipt \(held.id). Resolve and consume it before submitting different work.", receiptID: held.id)
        }
    }

    private static func insert(_ record: RuntimeCommandRecord, into records: inout Records) throws {
        guard RuntimeCommandRecord(record.json) != nil else {
            throw RuntimeError("INVALID_COMMAND_RECEIPT", "The command identity cannot be retained safely", kind: .requestRejected)
        }
        if let previous = records[record.id] {
            guard sameRequest(previous, record), record.forkReceiptID == nil || record.forkReceiptID == previous.forkReceiptID else { throw conflict() }
        }
        try checkAdmission(channel: record.channel, key: record.key, records: records)
        if records[record.id] != nil { return }
        guard !records.values.contains(where: { $0.key == record.key }) else { throw conflict() }
        guard records.count < 128 else {
            throw RuntimeError("TOO_MANY_UNRESOLVED_COMMANDS", "Inspect pending command outcomes before submitting more work")
        }
        records[record.id] = record
    }

    private static func sameRequest(_ lhs: RuntimeCommandRecord, _ rhs: RuntimeCommandRecord) -> Bool {
        lhs.id == rhs.id && lhs.key == rhs.key && lhs.fingerprint == rhs.fingerprint && lhs.channel == rhs.channel
            && lhs.attachmentIDs == rhs.attachmentIDs
    }
    private static func missingPredecessor(_ id: String) -> RuntimeError {
        RuntimeError("CONTINUATION_RECEIPT_REQUIRED", "The fork or rejected follow-up receipt is no longer available for this continuation", receiptID: id)
    }
    private static func conflict() -> RuntimeError {
        RuntimeError("RECEIPT_CONFLICT", "A retained command already owns this receipt or request identity")
    }
    private static func invalid() -> RuntimeError {
        RuntimeError("COMMAND_JOURNAL_INVALID", "The saved command outcomes require recovery before sending new work")
    }
    private static func unavailable() -> RuntimeError {
        RuntimeError("COMMAND_JOURNAL_UNAVAILABLE", "The command journal could not be locked, read or saved; new work is disabled to avoid duplicate execution")
    }

    private func transaction(_ mutate: (inout Records) throws -> Void) throws -> Records {
        try withLock {
            var records = try readLocked()
            let previous = records
            try mutate(&records)
            if records != previous {
                let data = try runtimeObject(["version": .integer(1), "hostID": .text("local"),
                    "records": .array(records.values.sorted { $0.id < $1.id }.map(\.json))]).encodedData()
                guard data.count <= 256 * 1024 else { throw Self.invalid() }
                do { try RuntimePrivateFile.write(data, to: file) }
                catch { throw Self.unavailable() }
            }
            return records
        }
    }

    private func readLocked() throws -> Records {
        var metadata = stat()
        if file.path.withCString({ Darwin.lstat($0, &metadata) }) != 0 {
            if errno == ENOENT { return [:] }
            throw Self.unavailable()
        }
        guard Self.privateFile(metadata), metadata.st_size >= 0, metadata.st_size <= 256 * 1024 else { throw Self.invalid() }
        let data: Data
        do { data = try RuntimePrivateFile.read(file, maximumBytes: 256 * 1024) }
        catch { throw Self.unavailable() }
        guard let document = try? JSONValue(data: data), document["version"]?.intValue == 1,
              document["hostID"]?.stringValue == "local",
              let values = document["records"]?.arrayValue, values.count <= 128 else { throw Self.invalid() }
        var records: Records = [:]
        var keys = Set<String>()
        for value in values {
            guard let record = RuntimeCommandRecord(value), records[record.id] == nil,
                  keys.insert(record.key).inserted else { throw Self.invalid() }
            records[record.id] = record
        }
        return records
    }

    private func withLock<Value>(_ operation: () throws -> Value) throws -> Value {
        do {
            try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        } catch { throw Self.unavailable() }
        var directory = stat()
        guard storageDirectory.path.withCString({ Darwin.lstat($0, &directory) }) == 0,
              directory.st_mode & S_IFMT == S_IFDIR, directory.st_uid == getuid(), directory.st_mode & 0o022 == 0 else {
            throw Self.unavailable()
        }
        // One stable gate serializes journal changes with draft read-and-pin
        // and Go collection; a separate journal lock cannot fence that handoff.
        do {
            return try RuntimeAttachmentLease.withExclusiveOwnership(in: storageDirectory) {
                var currentDirectory = stat()
                guard storageDirectory.path.withCString({ Darwin.lstat($0, &currentDirectory) }) == 0,
                      currentDirectory.st_dev == directory.st_dev, currentDirectory.st_ino == directory.st_ino else { throw Self.unavailable() }
                return try operation()
            }
        } catch let failure as RuntimeError {
            if ["UNSAFE_ATTACHMENT_LEASE", "ATTACHMENT_LEASE_IO", "ATTACHMENT_LEASE_BUSY"].contains(failure.code) {
                throw Self.unavailable()
            }
            throw failure
        } catch { throw Self.unavailable() }
    }
    private static func privateFile(_ value: stat) -> Bool {
        value.st_mode & S_IFMT == S_IFREG && value.st_uid == getuid() && value.st_mode & 0o077 == 0 && value.st_nlink == 1
    }
}
