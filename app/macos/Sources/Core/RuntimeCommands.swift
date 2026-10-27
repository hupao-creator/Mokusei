import Foundation
import CryptoKit

extension RuntimeClient {
    public func currentConnection() -> RuntimeConnection? { connection }

    /// Writes require a live authoritative connection. Persisting an ID tracks
    /// one submitted operation; it is never an offline queue or a replay payload.
    public func invoke(_ channel: String, args: [JSONValue] = [], receiptID: String? = nil) async throws -> JSONValue {
        try assertOpen()
        restoreOfflineState()
        if explicitlyStopped { throw RuntimeError("SERVICE_STOPPING", "Runtime service was stopped") }
        let encodedArgs = try JSONValue.array(args).encodedData()
        var fingerprintInput = Data(channel.utf8); fingerprintInput.append(0); fingerprintInput.append(encodedArgs)
        let fingerprint = SHA256.hash(data: fingerprintInput).map { String(format: "%02x", $0) }.joined()
        let readOnly = Set(["search:status", "search:query", "attachment:preview", "moku:voice-events", "thread:voice-events", "thread:read", "workspace:list-known-directories", "harness:settings-presentation", "harness:detect-installation", "state:load", "application:query", "settings:diagnostics"]).contains(channel)
        if !readOnly {
            guard status == .connected, hydration == nil else {
                throw RuntimeError("OFFLINE_COMMAND_DISABLED", "Connect and synchronize with the host before submitting this action; the draft is saved on this device")
            }
            if let commandJournalFailure { throw commandJournalFailure }
        }
        // A state load that starts the client must not coalesce with the handshake's
        // hydration load, which would wait recursively for its own startup.
        let key = receiptID.map { "receipt:\($0)" } ?? (readOnly ? UUID().uuidString : fingerprint)
        if let receiptID, let previous = explicitReceipts[receiptID], previous != fingerprint {
            throw RuntimeError("RECEIPT_CONFLICT", "A receipt cannot be retried with different command arguments")
        }
        if let active = activeCommands[key] { return try await active.value }
        guard readOnly ? activeCommands.count < 128 : (unresolvedCommands[key] != nil || activeCommands.count + unresolvedCommands.count < 128) else {
            throw RuntimeError("TOO_MANY_UNRESOLVED_COMMANDS", "Inspect pending command outcomes before submitting more work")
        }
        let id = receiptID ?? unresolvedCommands[key] ?? "\(Int64(Date().timeIntervalSince1970 * 1000))_\(UUID().uuidString.lowercased())"
        let alreadySubmitted = commandRecords[id] != nil
        explicitReceipts[id] = fingerprint
        let body = try runtimeObject(["commandId": .text(id), "args": .array(args)]).encodedData()
        guard body.count <= RuntimeProtocol.maxRequestBytes else {
            explicitReceipts.removeValue(forKey: id)
            throw RuntimeError("REQUEST_TOO_LARGE", "Runtime request exceeds the 144 MiB limit")
        }
        if !readOnly {
            try rememberCommand(key: key, id: id, fingerprint: fingerprint, channel: channel)
            unresolvedCommands[key] = id
        }
        // Receipt settlement is part of the shared operation, so no coalesced
        // waiter can return (and issue another command) before it is complete.
        let observed = channel == "app:update-settings" || channel == "harness:settings-presentation" || channel == "harness:detect-installations"
        let flowID = SettingsDiagnosticContext.flowID ?? UUID().uuidString
        let started = Date()
        if observed { reportSettingsDiagnostic(SettingsDiagnostic(.command, .started, flowID: flowID, operationID: id,
            revision: args.first?["expectedSettingsRevision"]?.intValue)) }
        let task = Task { () throws -> JSONValue in
            do {
                let value: JSONValue
                if readOnly { value = try await self.deliverRead(channel: channel, args: args, body: body, receiptID: id) }
                else { value = try await self.deliverWrite(channel: channel, body: body, receiptID: id,
                    alreadySubmitted: alreadySubmitted, explicitRetry: receiptID != nil) }
                if observed { self.reportSettingsDiagnostic(SettingsDiagnostic(.command,
                    value["status"]?.stringValue == "conflict" ? .conflict : .completed, flowID: flowID, operationID: id,
                    revision: value["settingsRevision"]?.intValue, durationMs: Date().timeIntervalSince(started) * 1000)) }
                self.activeCommands.removeValue(forKey: key)
                self.unresolvedCommands = self.unresolvedCommands.filter { $0.value != id }
                self.explicitReceipts.removeValue(forKey: id)
                self.forgetCommand(id)
                return value
            } catch {
                if observed { self.reportSettingsDiagnostic(SettingsDiagnostic(.command, .failed, flowID: flowID, operationID: id,
                    durationMs: Date().timeIntervalSince(started) * 1000)) }
                self.activeCommands.removeValue(forKey: key)
                if !readOnly, let error = error as? RuntimeError,
                   error.kind == .uncertain || error.code == "COMMAND_OUTCOME_INDETERMINATE" || error.code == "COMMAND_OUTCOME_UNCERTAIN" {
                    self.unresolvedCommands[key] = id
                    if self.status == .connected { self.scheduleReceiptRecovery() }
                } else if (error as? RuntimeError)?.kind == .commandRejected {
                    self.unresolvedCommands = self.unresolvedCommands.filter { $0.value != id }
                    self.explicitReceipts.removeValue(forKey: id)
                    self.forgetCommand(id)
                } else if (error as? RuntimeError)?.kind == .requestRejected || readOnly {
                    self.unresolvedCommands = self.unresolvedCommands.filter { $0.value != id }
                    self.explicitReceipts.removeValue(forKey: id)
                    self.forgetCommand(id)
                }
                throw error
            }
        }
        activeCommands[key] = task
        if readOnly {
            // A read has no durable receipt work to preserve. Propagate the
            // renderer's cancellation through this unstructured task to HTTP,
            // so abandoned Git reads release the host's process gate promptly.
            return try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
        }
        return try await task.value
    }

    private func deliverWrite(channel: String, body: Data, receiptID: String,
                              alreadySubmitted: Bool, explicitRetry: Bool) async throws -> JSONValue {
        guard !closed, status == .connected, let owner = connection else { throw RuntimeError.uncertain(receiptID) }
        if alreadySubmitted {
            do {
                if let result = try await lookupCommand(receiptID, owner: owner) { return try settledResult(result, id: receiptID) }
            } catch let failure as RuntimeError where failure.kind == .commandRejected || failure.kind == .uncertain { throw failure }
            catch { throw RuntimeError.uncertain(receiptID) }
            // Only a caller explicitly carrying the old receipt can request a
            // same-ID retry. A repeated click with the same draft queries only.
            guard explicitRetry, commandRecords[receiptID]?.status == .unknown else { throw RuntimeError.uncertain(receiptID) }
        }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let escaped = channel.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw RuntimeError("INVALID_REQUEST", "Invalid command channel", kind: .requestRejected)
        }
        do {
            let result = try await transport.request(connection: owner, path: "/invoke/\(escaped)", method: "POST", body: body, timeout: 120)
            return try settledResult(result, id: receiptID)
        } catch let failure as RuntimeError where failure.kind == .commandRejected || failure.kind == .uncertain { throw failure }
        catch let failure as RuntimeError where failure.kind == .requestRejected && failure.code != "RESPONSE_TOO_LARGE" { throw failure }
        catch {
            // No automatic resend, even with the same ID. The host may still be
            // accepting this request after its response connection disappeared.
            throw RuntimeError.uncertain(receiptID)
        }
    }

    private func settledResult(_ result: JSONValue, id: String) throws -> JSONValue {
        do { return try runtimeResult(result) }
        catch let failure as RuntimeError where ["COMMAND_OUTCOME_INDETERMINATE", "COMMAND_OUTCOME_UNCERTAIN"].contains(failure.code) {
            throw RuntimeError(failure.code, failure.message, kind: .uncertain, receiptID: id)
        }
    }

    private func deliverRead(channel: String, args: [JSONValue], body: Data, receiptID: String) async throws -> JSONValue {
        let settingsKey: String?
        switch channel {
        case "harness:settings-presentation":
            settingsKey = (args.first?["harnessId"]?.stringValue).map { "harness:\($0)" }
                ?? "thread:\(args.first?["threadId"]?.stringValue ?? "unknown")"
        case "harness:detect-installation": settingsKey = "harness:\(args.first?.stringValue ?? "unknown")"
        default: settingsKey = nil
        }
        if let settingsKey { try await acquireSettingsRead(key: settingsKey) }
        defer { if let settingsKey { releaseSettingsRead(key: settingsKey) } }
        try Task.checkCancellation()
        // Select connection authority only after admission; queued reads may
        // outlive a stream or saved-source replacement.
        if connection == nil { try await start() }
        var uncertain = false
        for attempt in 0...1 {
            if uncertain && (closed || explicitlyStopped || connection == nil) { throw RuntimeError.uncertain(receiptID) }
            try assertOpen()
            if explicitlyStopped { throw RuntimeError("SERVICE_STOPPING", "Runtime service was stopped") }
            guard let owner = connection else { throw RuntimeError("SERVICE_NOT_RUNNING", "Runtime service is not running") }
            let expected = generation
            let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
            guard let escaped = channel.addingPercentEncoding(withAllowedCharacters: allowed) else { throw RuntimeError("INVALID_REQUEST", "Invalid command channel") }
            do {
                let value = try await transport.request(connection: owner, path: "/invoke/\(escaped)", method: "POST", body: body, timeout: 120)
                return try runtimeResult(value)
            } catch {
                try Task.checkCancellation()
                if let error = error as? RuntimeError, error.kind == .commandRejected {
                    if ["COMMAND_OUTCOME_INDETERMINATE", "COMMAND_OUTCOME_UNCERTAIN"].contains(error.code) {
                        throw RuntimeError(error.code, error.message, kind: .uncertain, receiptID: receiptID)
                    }
                    throw error
                }
                let failure = error as? RuntimeError
                if let failure, failure.kind == .requestRejected, !["STALE_EPOCH", "RESPONSE_TOO_LARGE"].contains(failure.code) {
                    if uncertain { throw RuntimeError.uncertain(receiptID) }
                    throw failure
                }
                if failure?.kind != .requestRejected || failure?.code == "RESPONSE_TOO_LARGE" { uncertain = true }
                guard attempt == 0, !closed, !explicitlyStopped, retryable(error) else {
                    if uncertain { throw RuntimeError.uncertain(receiptID) }; throw error
                }
                let refreshed = try? await manager.status()
                if generation != expected || connection?.epoch != owner.epoch { continue }
                guard let refreshed else {
                    if uncertain { throw RuntimeError.uncertain(receiptID) }; throw error
                }
                connection = refreshed
            }
        }
        throw RuntimeError.uncertain(receiptID)
    }

    private func retryable(_ error: Error) -> Bool {
        if let failure = error as? RuntimeError { return ["TRANSPORT_TIMEOUT", "STALE_EPOCH", "STREAM_CLOSED"].contains(failure.code) }
        guard let error = error as? URLError else { return false }
        return [.timedOut, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet].contains(error.code)
    }
}
