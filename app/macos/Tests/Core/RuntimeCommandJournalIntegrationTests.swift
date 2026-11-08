import Darwin
import Foundation
import Network
import XCTest
@testable import MokuseiCore

private extension RuntimeClient {
    func useCommandJournalFixture(_ value: RuntimeConnection) {
        connection = value
        status = .connected
        streamID = UUID()
    }

    func finishCommandJournalFixture() async {
        close()
        for task in activeCommands.values { _ = try? await task.value }
    }
}

/// Use two real clients, their production HTTP transport and the same profile.
/// The peer controls response order, not journal mutations or client settlement.
final class RuntimeCommandJournalIntegrationTests: XCTestCase {
    func testTwoClientsKeepIndependentReceiptsThroughInterleavedCompletion() async throws {
        try await withCommandJournalReplay { replay in
            let first = try await replay.client(), second = try await replay.client()
            let initialFirst = await first.commandOutcomes(), initialSecond = await second.commandOutcomes()
            XCTAssertTrue(initialFirst.isEmpty && initialSecond.isEmpty)
            let firstID = UUID().uuidString, secondID = UUID().uuidString
            let firstSend = Task { try await first.invoke("thread:send", args: [.text("first")], receiptID: firstID, retainingReceipt: true) }
            let secondSend = Task { try await second.invoke("thread:send", args: [.text("second")], receiptID: secondID, retainingReceipt: true) }
            let firstRequest = try await replay.peer.take("/invoke/thread:send", id: firstID)
            let secondRequest = try await replay.peer.take("/invoke/thread:send", id: secondID)
            try secondRequest.reply(.success(.text("second")))
            _ = try await secondSend.value
            try firstRequest.reply(.success(.text("first")))
            _ = try await firstSend.value

            let reopened = try await replay.client()
            let outcomes = await reopened.commandOutcomes()
            XCTAssertEqual(Set(outcomes.map(\.commandID)), Set([firstID, secondID]))
            XCTAssertTrue(outcomes.allSatisfy { $0.status == .accepted })
            try await first.acknowledgeCommandOutcome(firstID, allowResubmission: true)
            let remaining = await second.commandOutcomes()
            XCTAssertEqual(remaining.map(\.commandID), [secondID])
            XCTAssertEqual(remaining.first?.status, .accepted)
        }
    }

    func testRecoveryCannotRestoreReceiptAnotherClientForgot() async throws {
        try await withCommandJournalReplay { replay in
            let first = try await replay.client(), recovering = try await replay.client()
            let id = UUID().uuidString
            let send = Task { try await first.invoke("thread:send", args: [.text("one admission")], receiptID: id) }
            let request = try await replay.peer.take("/invoke/thread:send", id: id)
            let seen = await recovering.commandOutcomes()
            XCTAssertEqual(seen.map(\.commandID), [id])
            let recovery = Task { await recovering.reconcileCommandReceipts() }
            let lookup = try await replay.peer.take("/commands/receipt", id: id)

            try request.reply(.success(.text("accepted")))
            _ = try await send.value // The first client has now forgotten its receipt.
            try lookup.reply(.complete(.text("accepted")))
            await recovery.value

            let reopened = try await replay.client()
            let outcomes = await reopened.commandOutcomes(), recovered = await recovering.commandOutcomes()
            XCTAssertTrue(outcomes.isEmpty && recovered.isEmpty)
            let unresolved = await recovering.unresolvedCommands, fingerprints = await recovering.explicitReceipts
            XCTAssertTrue(unresolved.isEmpty && fingerprints.isEmpty)
            XCTAssertEqual(replay.peer.count("/invoke/thread:send"), 1)
        }
    }

    func testReadOnlyReceiptDoesNotDeleteAnotherClientsRetainedWrite() async throws {
        for responseStatus in [200, 400] {
            try await withCommandJournalReplay { replay in
                let writer = try await replay.client(), reader = try await replay.client()
                _ = await reader.commandOutcomes()
                let id = UUID().uuidString
                let send = Task { try await writer.invoke("thread:send", args: [.text("retained input")], receiptID: id, retainingReceipt: true) }
                let request = try await replay.peer.take("/invoke/thread:send", id: id)
                try request.reply(.success(.null))
                _ = try await send.value

                // The reader restored its empty snapshot before this write.
                // Its ephemeral receipt must never remove a shared journal row.
                let read = Task { try await reader.invoke("search:status", receiptID: id) }
                let query = try await replay.peer.take("/invoke/search:status", id: id)
                if responseStatus == 200 { try query.reply(.success(.null)) }
                else {
                    try query.reply(.object(["error": .object(["code": .text("QUERY_REJECTED"), "message": .text("Rejected read")])]), status: responseStatus)
                }
                do {
                    _ = try await read.value
                    XCTAssertEqual(responseStatus, 200)
                } catch { XCTAssertEqual((error as? RuntimeError)?.code, "QUERY_REJECTED") }
                let reopened = try await replay.client()
                let outcomes = await reopened.commandOutcomes()
                XCTAssertEqual(outcomes.map(\.commandID), [id])
                XCTAssertEqual(outcomes.first?.status, .accepted)
            }
        }
    }

    func testLateCompletionCannotForgetAReusedIDWithDifferentArguments() async throws {
        try await withCommandJournalReplay { replay in
            let first = try await replay.client(), second = try await replay.client()
            let id = UUID().uuidString
            let original = Task { try await first.invoke("thread:send", args: [.text("original")], receiptID: id) }
            let originalRequest = try await replay.peer.take("/invoke/thread:send", id: id)
            // Explicit acknowledgement can consume an unresolved identity. A
            // completion that was already in flight must still own its original
            // immutable request, even if that ID is then reused incorrectly.
            try await second.acknowledgeCommandOutcome(id, allowResubmission: true)
            let reused = Task { try await second.invoke("thread:send", args: [.text("different")], receiptID: id, retainingReceipt: true) }
            let reusedRequest = try await replay.peer.take("/invoke/thread:send", id: id)
            try originalRequest.reply(.success(.null))
            _ = try await original.value
            let reopened = try await replay.client()
            let pending = await reopened.commandOutcomes()
            XCTAssertEqual(pending.map(\.commandID), [id])
            XCTAssertEqual(pending.first?.status, .awaitingReceipt)
            try reusedRequest.reply(.object(["ok": .bool(false), "error": .object([
                "code": .text("RECEIPT_CONFLICT"), "message": .text("The ID already belongs to the original input")
            ])]))
            do { _ = try await reused.value; XCTFail("Reusing the host receipt with different arguments succeeded") }
            catch { XCTAssertEqual((error as? RuntimeError)?.code, "RECEIPT_CONFLICT") }
            let rejected = await reopened.commandOutcomes()
            XCTAssertEqual(rejected.map(\.commandID), [id])
            XCTAssertEqual(rejected.first?.status, .rejected)
        }
    }

    func testStalePendingCannotOverwriteAcceptedReceiptOrDismissDraft() async throws {
        try await withCommandJournalReplay { replay in
            let first = try await replay.client(), recovering = try await replay.client()
            let id = UUID().uuidString
            let send = Task { try await first.invoke("moku:submit", args: [.text("keep my draft protected")], receiptID: id, retainingReceipt: true) }
            let request = try await replay.peer.take("/invoke/moku:submit", id: id)
            _ = await recovering.commandOutcomes()
            let recovery = Task { await recovering.reconcileCommandReceipts() }
            let lookup = try await replay.peer.take("/commands/receipt", id: id)

            try request.reply(.success(.null))
            _ = try await send.value
            // This client has not observed acceptance. Acknowledge must inspect
            // the latest locked record instead of trusting its local status.
            do {
                try await recovering.acknowledgeCommandOutcome(id)
                XCTFail("A stale client dismissed another client's accepted draft")
            } catch { XCTAssertEqual((error as? RuntimeError)?.code, "ACCEPTED_DRAFT_PROTECTED") }
            try lookup.reply(.object(["status": .text("pending")]))
            await recovery.value

            let reopened = try await replay.client()
            let outcomes = await reopened.commandOutcomes()
            XCTAssertEqual(outcomes.map(\.commandID), [id])
            XCTAssertEqual(outcomes.first?.status, .accepted)
            XCTAssertEqual(outcomes.first?.protectsSavedDraft, true)
        }
    }

    func testHandoffHasOneDurableSuccessorBeforeItsRequestCompletes() async throws {
        try await withCommandJournalReplay { replay in
            let first = try await replay.client()
            let forkID = UUID().uuidString, followUpID = UUID().uuidString
            let attachmentID = "7f3ac760-5b32-4ad0-9b4d-468c4b280ac1"
            let input: JSONValue = .object(["threadId": .text("forked-thread"), "input": .object([
                "parts": .array([.object(["kind": .text("local-file"), "file": .object(["id": .text(attachmentID)])])])
            ])])
            let fork = Task { try await first.invoke("thread:fork", args: [.text("source")], receiptID: forkID, retainingReceipt: true) }
            let forkRequest = try await replay.peer.take("/invoke/thread:fork", id: forkID)
            try forkRequest.reply(.success(.text("forked-thread")))
            _ = try await fork.value
            do {
                try await first.acknowledgeCommandOutcome(forkID)
                XCTFail("Default acknowledgement forgot an already-created fork")
            } catch { XCTAssertEqual((error as? RuntimeError)?.code, "CONTINUATION_RECEIPT_REQUIRED") }
            let followUp = Task {
                try await first.invoke("thread:follow-up", args: [input],
                    receiptID: followUpID, retainingReceipt: true, replacingReceipt: forkID)
            }
            let followUpRequest = try await replay.peer.take("/invoke/thread:follow-up", id: followUpID)
            // The successor's exact input already owns its files when HTTP
            // arrives, even though the runtime has not retained that input yet.
            let admitted = try RuntimeCommandJournal(storageDirectory: replay.directory).read()
            XCTAssertNil(admitted[forkID])
            XCTAssertEqual(admitted[followUpID]?.attachmentIDs, [attachmentID])

            let reopened = try await replay.client()
            let outcomes = await reopened.commandOutcomes()
            XCTAssertEqual(outcomes.map(\.commandID), [followUpID])
            XCTAssertEqual(outcomes.first?.status, .awaitingReceipt)
            XCTAssertEqual(outcomes.first?.forkReceiptID, forkID)
            do {
                _ = try await reopened.invoke("thread:fork", args: [.text("source")], receiptID: UUID().uuidString, retainingReceipt: true)
                XCTFail("A reopened client admitted a new fork during the handoff")
            } catch { XCTAssertEqual((error as? RuntimeError)?.code, "CONTINUATION_RECEIPT_REQUIRED") }
            XCTAssertEqual(replay.peer.count("/invoke/thread:fork"), 1)
            try followUpRequest.reply(.success(.text("execution")))
            _ = try await followUp.value
            let accepted = await reopened.commandOutcomes()
            XCTAssertEqual(accepted.map(\.commandID), [followUpID])
            XCTAssertEqual(accepted.first?.status, .accepted)
            XCTAssertEqual(accepted.first?.forkReceiptID, forkID)
        }
    }

    func testRejectedFollowUpKeepsForkLineageUntilExplicitReplacement() async throws {
        for responseStatus in [401, 200] {
            try await withCommandJournalReplay { replay in
                let first = try await replay.client()
                let forkID = UUID().uuidString, followUpID = UUID().uuidString, replacementID = UUID().uuidString
                let rejectedAttachment = "7f3ac760-5b32-4ad0-9b4d-468c4b280ac2"
                let replacementAttachment = "7f3ac760-5b32-4ad0-9b4d-468c4b280ac3"
                let originalInput: JSONValue = .object(["input": .object(["parts": .array([
                    .object(["kind": .text("local-file"), "file": .object(["id": .text(rejectedAttachment)])])
                ])])])
                let replacementInput: JSONValue = .object(["input": .object(["parts": .array([
                    .object(["kind": .text("local-file"), "file": .object(["id": .text(replacementAttachment)])])
                ])])])
                let fork = Task { try await first.invoke("thread:fork", args: [.text("source")], receiptID: forkID, retainingReceipt: true) }
                let forkRequest = try await replay.peer.take("/invoke/thread:fork", id: forkID)
                try forkRequest.reply(.success(.text("forked-thread")))
                _ = try await fork.value
                let followUp = Task {
                    try await first.invoke("thread:follow-up", args: [originalInput],
                        receiptID: followUpID, retainingReceipt: true, replacingReceipt: forkID)
                }
                let request = try await replay.peer.take("/invoke/thread:follow-up", id: followUpID)
                try request.reply(.object(["ok": .bool(false), "error": .object([
                    "code": .text(responseStatus == 401 ? "UNAUTHORIZED" : "FOLLOW_UP_REJECTED"),
                    "message": .text("Rejected before accepting input")
                ])]), status: responseStatus)
                do { _ = try await followUp.value; XCTFail("The peer's rejection was ignored") }
                catch { XCTAssertEqual((error as? RuntimeError)?.kind, responseStatus == 401 ? .requestRejected : .commandRejected) }

                let reopened = try await replay.client()
                let rejected = await reopened.commandOutcomes()
                let rejectedRecords = try RuntimeCommandJournal(storageDirectory: replay.directory).read()
                XCTAssertEqual(rejectedRecords[followUpID]?.attachmentIDs, [rejectedAttachment])
                XCTAssertEqual(rejected.map(\.commandID), [followUpID])
                XCTAssertEqual(rejected.first?.status, .rejected)
                XCTAssertEqual(rejected.first?.forkReceiptID, forkID)
                XCTAssertEqual(rejected.first?.requiresContinuationContext, true)
                do {
                    try await reopened.acknowledgeCommandOutcome(followUpID)
                    XCTFail("Default acknowledgement removed a rejected follow-up's fork lineage")
                } catch { XCTAssertEqual((error as? RuntimeError)?.code, "CONTINUATION_RECEIPT_REQUIRED") }
                let retained = await reopened.commandOutcomes()
                XCTAssertEqual(retained.map(\.commandID), [followUpID])
                do {
                    _ = try await reopened.invoke("thread:fork", args: [.text("source")], receiptID: UUID().uuidString, retainingReceipt: true)
                    XCTFail("A rejected follow-up erased the already-created fork")
                } catch { XCTAssertEqual((error as? RuntimeError)?.code, "CONTINUATION_RECEIPT_REQUIRED") }
                XCTAssertEqual(replay.peer.count("/invoke/thread:fork"), 1)

                let retry = Task {
                    try await reopened.invoke("thread:follow-up", args: [replacementInput],
                        receiptID: replacementID, retainingReceipt: true, replacingReceipt: followUpID)
                }
                let replacement = try await replay.peer.take("/invoke/thread:follow-up", id: replacementID)
                let replacedRecords = try RuntimeCommandJournal(storageDirectory: replay.directory).read()
                XCTAssertNil(replacedRecords[followUpID])
                XCTAssertEqual(replacedRecords[replacementID]?.attachmentIDs, [replacementAttachment])
                let pending = await first.commandOutcomes()
                XCTAssertEqual(pending.map(\.commandID), [replacementID])
                XCTAssertEqual(pending.first?.forkReceiptID, forkID)
                XCTAssertEqual(pending.first?.status, .awaitingReceipt)
                try replacement.reply(.success(.text("execution")))
                _ = try await retry.value
                let accepted = await first.commandOutcomes()
                XCTAssertEqual(accepted.first?.status, .accepted)
                XCTAssertEqual(accepted.first?.forkReceiptID, forkID)
                try await reopened.acknowledgeCommandOutcome(replacementID, allowResubmission: true)
                let consumed = await first.commandOutcomes()
                XCTAssertTrue(consumed.isEmpty)
            }
        }
    }

    func testFailedHandoffWriteKeepsForkAndPreventsTransmission() async throws {
        // Owner directory permissions must actually deny temporary-file creation.
        // CI runs its native suite as an ordinary user, not as root.
        XCTAssertNotEqual(geteuid(), 0, "This disk-failure replay requires the native CI user")
        guard geteuid() != 0 else { return }
        try await withCommandJournalReplay { replay in
            let first = try await replay.client()
            let forkID = UUID().uuidString, followUpID = UUID().uuidString
            let fork = Task { try await first.invoke("thread:fork", args: [.text("source")], receiptID: forkID, retainingReceipt: true) }
            let request = try await replay.peer.take("/invoke/thread:fork", id: forkID)
            try request.reply(.success(.text("forked-thread")))
            _ = try await fork.value

            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: replay.directory.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: replay.directory.path) }
            do {
                _ = try await first.invoke("thread:follow-up", args: [.text("forked-thread"), .text("input")],
                    receiptID: followUpID, retainingReceipt: true, replacingReceipt: forkID)
                XCTFail("A handoff proceeded without a durable successor")
            } catch { XCTAssertEqual((error as? RuntimeError)?.code, "COMMAND_JOURNAL_UNAVAILABLE") }
            XCTAssertEqual(replay.peer.count("/invoke/thread:follow-up"), 0)

            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: replay.directory.path)
            let reopened = try await replay.client()
            let outcomes = await reopened.commandOutcomes()
            XCTAssertEqual(outcomes.map(\.commandID), [forkID])
            XCTAssertEqual(outcomes.first?.status, .accepted)
            do {
                _ = try await first.invoke("thread:send", args: [.text("must remain blocked")])
                XCTFail("The client resumed writes after an ambiguous persistence failure")
            } catch { XCTAssertEqual((error as? RuntimeError)?.code, "COMMAND_JOURNAL_UNAVAILABLE") }
            XCTAssertEqual(replay.peer.count("/invoke/thread:send"), 0)
        }
    }

    func testNewWorkFailsClosedWhenAnotherWriterLeavesInvalidJournal() async throws {
        try await withCommandJournalReplay { replay in
            let first = try await replay.client()
            _ = await first.commandOutcomes()
            let journal = replay.directory.appendingPathComponent("client-command-journal.json")
            try RuntimePrivateFile.write(Data("invalid JSON".utf8), to: journal)
            do {
                _ = try await first.invoke("thread:send", args: [.text("must not be sent")])
                XCTFail("A previously restored client ignored the invalid shared journal")
            } catch { XCTAssertEqual((error as? RuntimeError)?.code, "COMMAND_JOURNAL_INVALID") }
            XCTAssertEqual(replay.peer.count("/invoke/thread:send"), 0)
        }
    }

    func testTwoClientsCannotAdmitDifferentCommandsInTheSameProtectedGroup() async throws {
        for channel in ["moku:submit", "thread:fork"] {
            try await withCommandJournalReplay { replay in
                let first = try await replay.client(), second = try await replay.client()
                _ = await first.commandOutcomes(); _ = await second.commandOutcomes()
                let path = "/invoke/" + channel
                replay.peer.automaticallyReply(to: path, with: .success(.null))
                let firstID = UUID().uuidString, secondID = UUID().uuidString
                let firstSend = Task { try await first.invoke(channel, args: [.text("first")], receiptID: firstID, retainingReceipt: true) }
                let secondSend = Task { try await second.invoke(channel, args: [.text("second")], receiptID: secondID, retainingReceipt: true) }
                let results = [await firstSend.result, await secondSend.result]
                let successes = results.filter { if case .success = $0 { return true }; return false }
                let errors = results.compactMap { result -> RuntimeError? in
                    if case .failure(let error) = result { return error as? RuntimeError }; return nil
                }
                XCTAssertEqual(successes.count, 1)
                XCTAssertEqual(errors.count, 1)
                XCTAssertEqual(errors.first?.code, channel == "moku:submit" ? "MOKU_SUBMISSION_RECEIPT_REQUIRED" : "CONTINUATION_RECEIPT_REQUIRED")
                XCTAssertTrue([firstID, secondID].contains(errors.first?.receiptID ?? ""))
                XCTAssertEqual(replay.peer.count(path), 1)
                let reopened = try await replay.client()
                let outcomes = await reopened.commandOutcomes()
                XCTAssertEqual(outcomes.count, 1)
                XCTAssertEqual(outcomes.first?.status, .accepted)
            }
        }
    }
}

private extension JSONValue {
    static func success(_ value: JSONValue) -> JSONValue { .object(["ok": .bool(true), "value": value]) }
    static func complete(_ value: JSONValue) -> JSONValue { .object(["status": .text("complete"), "result": .success(value)]) }
}

private func withCommandJournalReplay(_ run: (CommandJournalReplay) async throws -> Void) async throws {
    let replay = try CommandJournalReplay()
    do { try await run(replay) }
    catch { await replay.close(); throw error }
    await replay.close()
}

private final class CommandJournalReplay: @unchecked Sendable {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let peer: CommandJournalPeer
    private let lock = NSLock()
    private var clients: [RuntimeClient] = []

    init() throws { peer = try CommandJournalPeer() }
    func client() async throws -> RuntimeClient {
        let profile = try RuntimeProfile(dataDirectory: directory)
        let client = RuntimeClient(profile: profile)
        let connection = try await peer.connection(directory: profile.dataDirectory)
        await client.useCommandJournalFixture(connection)
        lock.withLock { clients.append(client) }
        return client
    }
    func close() async {
        peer.close()
        let current = lock.withLock { clients }
        for client in current { await client.finishCommandJournalFixture() }
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class CommandJournalRequest: @unchecked Sendable {
    let path: String
    let body: JSONValue
    private let connection: NWConnection
    init(path: String, body: JSONValue, connection: NWConnection) {
        self.path = path; self.body = body; self.connection = connection
    }
    func reply(_ value: JSONValue, status: Int = 200) throws {
        let bytes = try value.encodedData()
        let headers = Data("HTTP/1.1 \(status) \(status == 200 ? "OK" : "Rejected")\r\nContent-Type: application/json\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n".utf8)
        connection.send(content: headers + bytes, completion: .contentProcessed { [connection] _ in connection.cancel() })
    }
}

private final class CommandJournalPeer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "command-journal-peer")
    private let lock = NSLock()
    private var port: Int?
    private var failure: Error?
    private var pending: [CommandJournalRequest] = []
    private var received: [CommandJournalRequest] = []
    private var connections: [NWConnection] = []
    private var replies: [String: JSONValue] = [:]

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            lock.withLock {
                if case .ready = state { port = listener.port.map { Int($0.rawValue) } }
                if case .failed(let error) = state { failure = error }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            lock.withLock { connections.append(connection) }
            connection.start(queue: queue)
            receive(connection, bytes: Data())
        }
        listener.start(queue: queue)
    }

    func connection(directory: URL) async throws -> RuntimeConnection {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            let (port, failure) = lock.withLock { (self.port, self.failure) }
            if let failure { throw failure }
            if let port {
                return RuntimeConnection(port: port, token: "journal-fixture", epoch: "journal-fixture",
                    protocolVersion: RuntimeProtocol.version, pid: Int(getpid()), dataDir: directory.path)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw RuntimeError("JOURNAL_REPLAY_TIMEOUT", "Loopback journal peer did not start")
    }

    func take(_ path: String, id: String) async throws -> CommandJournalRequest {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            let request = lock.withLock { () -> CommandJournalRequest? in
                guard let index = pending.firstIndex(where: { $0.path == path && $0.body["commandId"]?.stringValue == id }) else { return nil }
                return pending.remove(at: index)
            }
            if let request { return request }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw RuntimeError("JOURNAL_REPLAY_TIMEOUT", "Expected command did not reach \(path)")
    }

    func count(_ path: String) -> Int { lock.withLock { received.filter { $0.path == path }.count } }
    func automaticallyReply(to path: String, with value: JSONValue) { lock.withLock { replies[path] = value } }
    func close() {
        listener.cancel()
        let current = lock.withLock { connections }
        for connection in current { connection.cancel() }
    }

    private func receive(_ connection: NWConnection, bytes: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self, error == nil, let data, !data.isEmpty else { connection.cancel(); return }
            let accumulated = bytes + data
            guard accumulated.count <= 65_536 else { connection.cancel(); return }
            let separator = Data("\r\n\r\n".utf8)
            if let end = accumulated.range(of: separator),
               let headers = String(data: accumulated[..<end.lowerBound], encoding: .utf8) {
                let lines = headers.components(separatedBy: "\r\n")
                let path = lines.first?.split(separator: " ").dropFirst().first.map(String.init)
                let length = lines.first(where: { $0.lowercased().hasPrefix("content-length:") })
                    .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) }
                if let path, let length, accumulated.count - end.upperBound >= length,
                   let body = try? JSONValue(data: accumulated.subdata(in: end.upperBound..<(end.upperBound + length))) {
                    let request = CommandJournalRequest(path: path.removingPercentEncoding ?? path, body: body, connection: connection)
                    let reply = lock.withLock {
                        pending.append(request); received.append(request)
                        return replies[request.path]
                    }
                    if let reply { try? request.reply(reply) }
                    return
                }
            }
            if complete { connection.cancel() }
            else { receive(connection, bytes: accumulated) }
        }
    }
}
