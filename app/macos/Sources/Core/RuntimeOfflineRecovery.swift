import Foundation

private let draftSubmissionChannels: Set<String> = ["moku:submit", "thread:send", "thread:create", "thread:follow-up"]

public struct RuntimeCommandOutcome: Sendable, Equatable {
    public enum Status: String, Sendable { case awaitingReceipt, pending, accepted, rejected, indeterminate, unknown }
    public let commandID: String
    public let channel: String
    public let status: Status
    public let forkReceiptID: String?
    public var protectsSavedDraft: Bool { status == .accepted && draftSubmissionChannels.contains(channel) }
    public var requiresContinuationContext: Bool {
        ["thread:fork", "thread:follow-up"].contains(channel) && (status != .rejected || forkReceiptID != nil)
    }
    public init(commandID: String, channel: String, status: Status, forkReceiptID: String? = nil) {
        self.commandID = commandID; self.channel = channel; self.status = status; self.forkReceiptID = forkReceiptID
    }
}

struct RuntimeCommandRecord: Sendable, Equatable {
    let key: String
    let id: String
    let fingerprint: String
    let channel: String
    let attachmentIDs: [String]
    var status: RuntimeCommandOutcome.Status = .awaitingReceipt
    var forkReceiptID: String?

    var json: JSONValue {
        var fields: [String: JSONValue] = ["key": .text(key), "id": .text(id), "fingerprint": .text(fingerprint),
            "channel": .text(channel), "status": .text(status.rawValue),
            "attachmentIDs": .array(attachmentIDs.map(JSONValue.text))]
        if let forkReceiptID { fields["forkReceiptID"] = .text(forkReceiptID) }
        return runtimeObject(fields)
    }
    var outcome: RuntimeCommandOutcome {
        .init(commandID: id, channel: channel, status: status, forkReceiptID: forkReceiptID)
    }
    init(key: String, id: String, fingerprint: String, channel: String, attachmentIDs: [String], forkReceiptID: String? = nil) {
        self.key = key; self.id = id; self.fingerprint = fingerprint; self.channel = channel
        self.attachmentIDs = attachmentIDs
        self.forkReceiptID = forkReceiptID
    }
    init?(_ value: JSONValue) {
        guard let key = value["key"]?.stringValue, key.count <= 256,
              let id = value["id"]?.stringValue, Self.validID(id),
              let fingerprint = value["fingerprint"]?.stringValue, fingerprint.count == 64,
              fingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let channel = value["channel"]?.stringValue, !channel.isEmpty, channel.count <= 128,
              let references = value["attachmentIDs"]?.arrayValue, references.count <= 20,
              let rawStatus = value["status"]?.stringValue, let status = RuntimeCommandOutcome.Status(rawValue: rawStatus) else { return nil }
        let attachmentIDs = references.compactMap(Self.attachmentID)
        guard attachmentIDs.count == references.count else { return nil }
        if let fork = value["forkReceiptID"] {
            guard let forkID = fork.stringValue, Self.validID(forkID), forkID != id, channel == "thread:follow-up" else { return nil }
            forkReceiptID = forkID
        }
        self.key = key; self.id = id; self.fingerprint = fingerprint; self.channel = channel; self.status = status
        self.attachmentIDs = attachmentIDs
    }

    static func attachmentIDs(for channel: String, args: [JSONValue]) throws -> [String] {
        guard draftSubmissionChannels.contains(channel) else { return [] }
        var references = Set<String>()
        for part in args.first?["input"]?["parts"]?.arrayValue ?? [] {
            guard let file = part["file"] else { continue }
            guard let value = file["id"], let id = attachmentID(value) else {
                throw RuntimeError("INVALID_ATTACHMENT_REFERENCE", "The input contains an invalid managed attachment reference")
            }
            references.insert(id)
        }
        guard references.count <= 20 else {
            throw RuntimeError("INVALID_ATTACHMENT_REFERENCE", "The input contains too many managed attachments")
        }
        return references.sorted()
    }

    private static func attachmentID(_ value: JSONValue) -> String? {
        guard let id = value.stringValue, let uuid = UUID(uuidString: id),
              uuid.uuidString.lowercased() == id,
              (1...5).contains(uuid.uuid.6 >> 4), uuid.uuid.8 & 0xc0 == 0x80 else { return nil }
        return id
    }

    private static func validID(_ value: String) -> Bool {
        (16...128).contains(value.count)
            && value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }
    }
}

extension RuntimeClient {
    var offlineStore: RuntimeOfflineStore { .init(storageDirectory: storageDirectory, hostID: nil) }
    private var commandJournal: RuntimeCommandJournal { .init(storageDirectory: storageDirectory) }

    func restoreOfflineState() {
        guard !offlineRestored else { return }
        offlineRestored = true
        if state == nil { state = offlineStore.state() }
        try? refreshCommandJournal()
    }

    func refreshCommandJournal() throws {
        try transactCommandJournal { try $0.read() }
    }

    func rememberCommand(key: String, id: String, fingerprint: String, channel: String, attachmentIDs: [String]) throws -> Bool {
        var alreadySubmitted = false
        try transactCommandJournal {
            // A disconnected write may still be waiting before RetainInput.
            // Publish its files with the receipt before any HTTP can start.
            let admitted = try $0.insert(RuntimeCommandRecord(key: key, id: id, fingerprint: fingerprint,
                channel: channel, attachmentIDs: attachmentIDs))
            alreadySubmitted = admitted.alreadySubmitted
            return admitted.records
        }
        return alreadySubmitted
    }

    func replaceCommand(predecessorID: String, successor: RuntimeCommandRecord) throws -> Bool {
        var alreadySubmitted = false
        try transactCommandJournal {
            let admitted = try $0.replace(predecessorID: predecessorID, successor: successor)
            alreadySubmitted = admitted.alreadySubmitted
            return admitted.records
        }
        return alreadySubmitted
    }

    func updateCommandStatus(_ id: String, status: RuntimeCommandOutcome.Status,
                             matching expected: RuntimeCommandRecord? = nil) throws {
        guard let record = expected ?? commandRecords[id] else { try refreshCommandJournal(); return }
        try transactCommandJournal { try $0.updateStatus(of: record, to: status) }
    }

    private func transactCommandJournal(_ operation: (RuntimeCommandJournal) throws -> RuntimeCommandJournal.Records) throws {
        if let commandJournalFailure { throw commandJournalFailure }
        do {
            let records = try operation(commandJournal)
            // Read-only commands have no journal row, but an explicit ID still
            // owns its fingerprint while its active task can be coalesced.
            let activeReceipts = explicitReceipts.filter { activeCommands["receipt:\($0.key)"] != nil }
            commandRecords = records
            unresolvedCommands = Dictionary(uniqueKeysWithValues: records.values.map { ($0.key, $0.id) })
            explicitReceipts = Dictionary(uniqueKeysWithValues: records.values.map { ($0.id, $0.fingerprint) })
            for (id, fingerprint) in activeReceipts { explicitReceipts[id] = fingerprint }
        } catch {
            if let failure = error as? RuntimeError,
               ["COMMAND_JOURNAL_INVALID", "COMMAND_JOURNAL_UNAVAILABLE", "COMMAND_RECEIPT_CONFLICT"].contains(failure.code) {
                // A failed durable write may have published before fsync failed.
                // Keep the previous local snapshot and stop new admission; an
                // in-memory rollback cannot establish what survived on disk.
                commandJournalFailure = failure
                emit(.failure(failure))
            }
            throw error
        }
    }

    func forgetCommand(_ id: String, matching expected: RuntimeCommandRecord?) {
        // Removal reads the current file even if this client's cache is stale.
        // On failure transactCommandJournal retains the cache and fails closed.
        guard let expected else { try? refreshCommandJournal(); return }
        try? transactCommandJournal { try $0.remove(id, matching: expected) }
    }

    /// Results belong to the local runtime profile. Querying never queues or resends work.
    public func commandOutcomes() -> [RuntimeCommandOutcome] {
        restoreOfflineState()
        try? refreshCommandJournal()
        return commandRecords.values.map(\.outcome)
            .sorted { $0.commandID < $1.commandID }
    }

    func scheduleReceiptRecovery() {
        receiptRecoveryTask?.cancel()
        let expected = generation
        receiptRecoveryTask = Task {
            var delay = 1
            while !Task.isCancelled, !closed, generation == expected, status == .connected {
                await reconcileCommandReceipts()
                guard commandRecords.values.contains(where: { [.awaitingReceipt, .pending, .unknown].contains($0.status) }) else { return }
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                delay = min(15, delay * 2)
            }
        }
    }

    public func reconcileCommandReceipts() async {
        guard status == .connected, let owner = connection, let stream = streamID else { return }
        do { try refreshCommandJournal() } catch { return }
        let expected = generation
        for record in commandRecords.values.sorted(by: { $0.id < $1.id }) {
            guard activeCommands[record.key] == nil else { continue }
            do {
                _ = try await lookupCommand(record.id, owner: owner)
                try assertCurrent(stream, generation: expected)
            } catch {
                guard status == .connected, streamID == stream, generation == expected else { return }
                // A failed receipt lookup preserves the unresolved identity. It
                // must not turn a healthy snapshot into an execution retry.
                if let failure = error as? RuntimeError,
                   ["UNAUTHORIZED", "HOST_IDENTITY_CHANGED", "PROTOCOL_MISMATCH"].contains(failure.code) {
                    invalidateSession(failure, stream: stream)
                    return
                }
            }
        }
    }

    func lookupCommand(_ id: String, owner: RuntimeConnection) async throws -> JSONValue? {
        try refreshCommandJournal()
        guard let record = commandRecords[id] else { return nil }
        let expected = generation
        let result = try await transport.request(connection: owner, path: "/commands/receipt", method: "POST",
            body: runtimeObject(["commandId": .text(id)]).encodedData(), timeout: 15)
        guard generation == expected, connection?.epoch == owner.epoch, !closed else { throw RuntimeError.uncertain(id) }
        guard let receiptStatus = result["status"]?.stringValue else {
            throw RuntimeError("INVALID_RECEIPT", "Runtime returned an invalid command receipt")
        }
        let outcome: JSONValue?
        let status: RuntimeCommandOutcome.Status
        switch receiptStatus {
        case "pending": status = .pending; outcome = nil
        case "unknown": status = .unknown; outcome = nil
        case "complete":
            guard let value = result["result"], let ok = value["ok"]?.boolValue else {
                throw RuntimeError("INVALID_RECEIPT", "Runtime returned an incomplete command receipt")
            }
            if ["COMMAND_OUTCOME_INDETERMINATE", "COMMAND_OUTCOME_UNCERTAIN"].contains(value["error"]?["code"]?.stringValue ?? "") {
                status = .indeterminate
            } else { status = ok ? .accepted : .rejected }
            outcome = value
        default: throw RuntimeError("INVALID_RECEIPT", "Runtime returned an unknown command receipt status")
        }
        try updateCommandStatus(id, status: status, matching: record)
        return commandRecords[id] == nil ? nil : outcome
    }

    /// The user may dismiss a settled receipt after reviewing current host state.
    /// Unknown/indeterminate entries deliberately remain until explicitly acknowledged.
    public func acknowledgeCommandOutcome(_ id: String, allowResubmission: Bool = false) throws {
        // Unrelated reads/writes cannot hold a settled receipt after its draft
        // is consumed. Its own active command still owns journal settlement.
        // A successful send may still be in a persisted draft. Keep its
        // fingerprint until the original action consumes the receipt and clears
        // that draft. Dismissing a status must not turn it into a new execution.
        try transactCommandJournal { journal in
            try journal.remove(id) { record in
                guard activeCommands[record.key] == nil else { return false }
                if !allowResubmission, record.forkReceiptID != nil || (record.channel == "thread:fork" && record.status == .accepted) {
                    throw RuntimeError("CONTINUATION_RECEIPT_REQUIRED", "This fork already exists; finish its continuation or explicitly confirm a new submission before dismissing its receipt", receiptID: id)
                }
                if record.status == .accepted && draftSubmissionChannels.contains(record.channel) && !allowResubmission {
                    throw RuntimeError("ACCEPTED_DRAFT_PROTECTED", "This input was accepted; consume its receipt from the draft or explicitly confirm a new submission")
                }
                return true
            }
        }
    }

    func scheduleReadingCache() {
        guard readingCacheTask == nil else { return }
        readingCacheTask = Task {
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            self.flushReadingCache()
        }
    }

    func flushReadingCache() {
        readingCacheTask?.cancel(); readingCacheTask = nil
        do {
            if readingStateDirty, let state { try offlineStore.saveState(state); readingStateDirty = false }
            for id in Array(readingContentDirty) {
                if let resource = contentResources[id], let value = resource.value {
                    try offlineStore.saveContent(value, thread: resource.threadID, scope: resource.scope)
                }
                readingContentDirty.remove(id)
            }
        } catch {
            // Cache pressure does not prevent live work or touch persisted drafts.
            emit(.failure(RuntimeError("READING_CACHE_UNAVAILABLE", "Recent content could not be saved for offline reading")))
        }
    }
}
