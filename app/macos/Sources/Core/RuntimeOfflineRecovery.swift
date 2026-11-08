import Foundation

private let draftSubmissionChannels: Set<String> = ["moku:submit", "thread:send", "thread:create", "thread:follow-up"]

public struct RuntimeCommandOutcome: Sendable, Equatable {
    public enum Status: String, Sendable { case awaitingReceipt, pending, accepted, rejected, indeterminate, unknown }
    public let commandID: String
    public let channel: String
    public let status: Status
    public var protectsSavedDraft: Bool { status == .accepted && draftSubmissionChannels.contains(channel) }
}

struct RuntimeCommandRecord: Sendable {
    let key: String
    let id: String
    let fingerprint: String
    let channel: String
    let attachmentIDs: [String]
    var status: RuntimeCommandOutcome.Status = .awaitingReceipt

    var json: JSONValue {
        runtimeObject(["key": .text(key), "id": .text(id), "fingerprint": .text(fingerprint),
            "channel": .text(channel), "status": .text(status.rawValue),
            "attachmentIDs": .array(attachmentIDs.map(JSONValue.text))])
    }
    init(key: String, id: String, fingerprint: String, channel: String, attachmentIDs: [String]) {
        self.key = key; self.id = id; self.fingerprint = fingerprint; self.channel = channel
        self.attachmentIDs = attachmentIDs
    }
    init?(_ value: JSONValue) {
        guard let key = value["key"]?.stringValue, key.count <= 256,
              let id = value["id"]?.stringValue, (16...128).contains(id.count),
              id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }),
              let fingerprint = value["fingerprint"]?.stringValue, fingerprint.count == 64,
              fingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let channel = value["channel"]?.stringValue, !channel.isEmpty, channel.count <= 128,
              let references = value["attachmentIDs"]?.arrayValue, references.count <= 20,
              let rawStatus = value["status"]?.stringValue, let status = RuntimeCommandOutcome.Status(rawValue: rawStatus) else { return nil }
        let attachmentIDs = references.compactMap(Self.attachmentID)
        guard attachmentIDs.count == references.count else { return nil }
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
}

extension RuntimeClient {
    var offlineStore: RuntimeOfflineStore { .init(storageDirectory: storageDirectory, hostID: nil) }
    private var receiptJournalURL: URL {
        storageDirectory.appendingPathComponent("client-command-journal.json")
    }

    func restoreOfflineState() {
        guard !offlineRestored else { return }
        offlineRestored = true
        if state == nil { state = offlineStore.state() }
        do {
            let restored = try readCommandJournal()
            commandRecords = restored
            for record in restored.values {
                unresolvedCommands[record.key] = record.id
                explicitReceipts[record.id] = record.fingerprint
            }
        } catch {
            commandJournalFailure = error as? RuntimeError ?? RuntimeError("COMMAND_JOURNAL_INVALID", "The saved command outcomes could not be read; new work is disabled to avoid duplicate execution")
        }
    }

    private func readCommandJournal() throws -> [String: RuntimeCommandRecord] {
        do { _ = try FileManager.default.attributesOfItem(atPath: receiptJournalURL.path) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [:] }
        let data = try RuntimePrivateFile.read(receiptJournalURL, maximumBytes: 256 * 1024)
        let document = try JSONValue(data: data)
        guard document["version"]?.intValue == 1, document["hostID"]?.stringValue == "local",
              let records = document["records"]?.arrayValue, records.count <= 128 else {
            throw RuntimeError("COMMAND_JOURNAL_INVALID", "The saved command outcomes require recovery before sending new work")
        }
        var restored: [String: RuntimeCommandRecord] = [:]
        var keys = Set<String>()
        for value in records {
            guard let record = RuntimeCommandRecord(value), restored[record.id] == nil, keys.insert(record.key).inserted else {
                throw RuntimeError("COMMAND_JOURNAL_INVALID", "The saved command outcomes require recovery before sending new work")
            }
            restored[record.id] = record
        }
        return restored
    }

    @discardableResult
    func persistCommandJournal(upserting record: RuntimeCommandRecord? = nil, creating: Bool = false,
                               removing id: String? = nil) throws -> Bool {
        do {
            // Other clients may have admitted writes since this actor restored
            // its cache. Change only this receipt under the collector's gate.
            return try RuntimeAttachmentLease.withExclusiveOwnership(in: storageDirectory) {
                var current = try readCommandJournal()
                if let record {
                    let previous = current[record.id]
                    if let previous, previous.key != record.key || previous.fingerprint != record.fingerprint {
                        throw RuntimeError("RECEIPT_CONFLICT", "A receipt cannot be retried with different command arguments")
                    }
                    if creating, let previous {
                        commandRecords[record.id] = previous
                        return true
                    }
                    if !creating, previous == nil {
                        // A different client consumed this receipt while a
                        // lookup or command result was suspended. It is final.
                        commandRecords.removeValue(forKey: record.id)
                        unresolvedCommands = unresolvedCommands.filter { $0.value != record.id }
                        explicitReceipts.removeValue(forKey: record.id)
                        return false
                    }
                    if let previous = current.values.first(where: { $0.key == record.key && $0.id != record.id }) {
                        throw RuntimeError("RECEIPT_CONFLICT", "A saved command already owns this input; resolve its receipt before sending",
                            receiptID: previous.id)
                    }
                    current[record.id] = record
                }
                if let id { current.removeValue(forKey: id) }
                guard current.count <= 128 else {
                    throw RuntimeError("TOO_MANY_UNRESOLVED_COMMANDS", "Inspect pending command outcomes before submitting more work")
                }
                let records = current.values.sorted { $0.id < $1.id }.map(\.json)
                let data = try runtimeObject(["version": .integer(1), "hostID": .text("local"), "records": .array(records)]).encodedData()
                try RuntimePrivateFile.write(data, to: receiptJournalURL)
                return false
            }
        }
        catch let error as RuntimeError { throw error }
        catch { throw RuntimeError("COMMAND_JOURNAL_UNAVAILABLE", "The command could not be tracked on this device; check available storage before sending") }
    }

    func rememberCommand(key: String, id: String, fingerprint: String, channel: String, attachmentIDs: [String]) throws -> Bool {
        if let commandJournalFailure { throw commandJournalFailure }
        guard commandRecords[id] == nil else { return true }
        // A disconnected write can still be waiting before RetainInput. The
        // receipt, including its files, must outlive the submitting draft.
        let record = RuntimeCommandRecord(key: key, id: id, fingerprint: fingerprint,
            channel: channel, attachmentIDs: attachmentIDs)
        commandRecords[id] = record
        do { return try persistCommandJournal(upserting: record, creating: true) }
        catch { commandRecords[id] = nil; throw error }
    }

    func forgetCommand(_ id: String) {
        guard let previous = commandRecords.removeValue(forKey: id) else { return }
        do { try persistCommandJournal(removing: id) }
        catch {
            // Retaining an already-settled ID is safe; dropping an untracked ID
            // would allow a relaunch to issue duplicate work with a new ID.
            commandRecords[id] = previous
            commandJournalFailure = error as? RuntimeError
            if let commandJournalFailure { emit(.failure(commandJournalFailure)) }
        }
    }

    /// Results belong to the local runtime profile. Querying never queues or resends work.
    public func commandOutcomes() -> [RuntimeCommandOutcome] {
        restoreOfflineState()
        return commandRecords.values.map { .init(commandID: $0.id, channel: $0.channel, status: $0.status) }
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
        let expected = generation
        let result = try await transport.request(connection: owner, path: "/commands/receipt", method: "POST",
            body: runtimeObject(["commandId": .text(id)]).encodedData(), timeout: 15)
        guard generation == expected, connection?.epoch == owner.epoch, !closed else { throw RuntimeError.uncertain(id) }
        guard var record = commandRecords[id] else { return nil }
        guard let receiptStatus = result["status"]?.stringValue else {
            throw RuntimeError("INVALID_RECEIPT", "Runtime returned an invalid command receipt")
        }
        let outcome: JSONValue?
        switch receiptStatus {
        case "pending": record.status = .pending; outcome = nil
        case "unknown": record.status = .unknown; outcome = nil
        case "complete":
            guard let value = result["result"], let ok = value["ok"]?.boolValue else {
                throw RuntimeError("INVALID_RECEIPT", "Runtime returned an incomplete command receipt")
            }
            if ["COMMAND_OUTCOME_INDETERMINATE", "COMMAND_OUTCOME_UNCERTAIN"].contains(value["error"]?["code"]?.stringValue ?? "") {
                record.status = .indeterminate
            } else { record.status = ok ? .accepted : .rejected }
            outcome = value
        default: throw RuntimeError("INVALID_RECEIPT", "Runtime returned an unknown command receipt status")
        }
        commandRecords[id] = record
        try persistCommandJournal(upserting: record)
        return outcome
    }

    /// The user may dismiss a settled receipt after reviewing current host state.
    /// Unknown/indeterminate entries deliberately remain until explicitly acknowledged.
    public func acknowledgeCommandOutcome(_ id: String, allowResubmission: Bool = false) throws {
        guard let previous = commandRecords[id], activeCommands[previous.key] == nil else { return }
        // Unrelated reads/writes cannot hold a settled receipt after its draft
        // is consumed. Its own active command still owns journal settlement.
        // A successful send may still be in a persisted draft. Keep its
        // fingerprint until the original action consumes the receipt and clears
        // that draft. Dismissing a status must not turn it into a new execution.
        if previous.status == .accepted && draftSubmissionChannels.contains(previous.channel) && !allowResubmission {
            throw RuntimeError("ACCEPTED_DRAFT_PROTECTED", "This input was accepted; consume its receipt from the draft or explicitly confirm a new submission")
        }
        commandRecords.removeValue(forKey: id)
        do { try persistCommandJournal(removing: id) }
        catch { commandRecords[id] = previous; throw error }
        unresolvedCommands = unresolvedCommands.filter { $0.value != id }
        explicitReceipts.removeValue(forKey: id)
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
