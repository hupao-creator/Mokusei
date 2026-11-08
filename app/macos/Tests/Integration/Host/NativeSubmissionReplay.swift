import Foundation
import Network
import Synchronization
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
@testable import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
@testable import MokuseiUI

/// Exercise the production Host senders, composer, journal and URLSession. Only
/// connection admission and the peer's HTTP outcomes are controlled here.
@MainActor @Suite(.serializedNative, .serialized)
struct NativeSubmissionReplay {
    @Test func acceptedMokuReceiptSurvivesUntilTheCapturedDraftIsConsumed() async throws {
        try await NativeSubmissionFixture.run { fixture in
            fixture.draft.text = "Send once"
            let input = NativeComposerSubmission(text: fixture.draft.text, directories: [], attachments: [])
            try await fixture.presentation.sendMoku(input)
            let accepted = await fixture.client.commandOutcomes()
            #expect(accepted.count == 1 && accepted.first?.status == .accepted)
            #expect(try fixture.persistedText() == "Send once")

            // Recreate both client and presentation at the former crash gap.
            let reopened = try await fixture.reopen()
            await reopened.draft.submit({ try await reopened.sendMoku($0) }, didConsume: {
                await reopened.didConsumeMokuDraft($0, source: .object([:]))
            })
            #expect(reopened.draft.text == "Send once" && reopened.draft.error != nil)
            #expect(fixture.server.invocations("moku:submit").count == 1)
            #expect(await reopened.workspace.client.commandOutcomes() == accepted)
            await reopened.draft.dispose(discardRemoteAttachments: false)

            await fixture.draft.submit({ try await fixture.presentation.sendMoku($0) }, didConsume: {
                #expect((try? fixture.persistedText()) == "")
                #expect(await fixture.client.commandOutcomes().first?.status == .accepted)
                await fixture.presentation.didConsumeMokuDraft($0, source: .object([:]))
            })
            #expect(fixture.draft.error == nil && fixture.draft.text.isEmpty)
            #expect(try fixture.persistedText() == "")
            #expect(await fixture.client.commandOutcomes().isEmpty)
            #expect(fixture.server.invocations("moku:submit").count == 1)
        }
    }

    @Test func failedDraftConsumptionKeepsAnAcceptedReceiptAcrossReopen() async throws {
        try await NativeSubmissionFixture.run { fixture in
            fixture.draft.text = "Keep the accepted input recoverable"
            let drafts = fixture.directory.appendingPathComponent("client-drafts")
            let saved = fixture.directory.appendingPathComponent("saved-drafts")
            fixture.server.onInvoke = { request in
                guard request.channel == "moku:submit" else { return }
                try FileManager.default.moveItem(at: drafts, to: saved)
                try Data("storage unavailable".utf8).write(to: drafts)
            }
            var consumed = false
            await fixture.draft.submit({ try await fixture.presentation.sendMoku($0) }, didConsume: {
                consumed = true
                await fixture.presentation.didConsumeMokuDraft($0, source: .object([:]))
            })
            #expect(fixture.draft.error != nil && !consumed)
            #expect(await fixture.client.commandOutcomes().first?.status == .accepted)
            // Retire the old owner while storage is still unavailable, as a
            // process exit would, before making the original bytes readable.
            await fixture.draft.dispose(discardRemoteAttachments: false)
            try FileManager.default.removeItem(at: drafts)
            try FileManager.default.moveItem(at: saved, to: drafts)
            fixture.server.onInvoke = nil

            let reopened = try await fixture.reopen()
            #expect(reopened.draft.text == "Keep the accepted input recoverable")
            await reopened.draft.submit({ try await reopened.sendMoku($0) }, didConsume: {
                await reopened.didConsumeMokuDraft($0, source: .object([:]))
            })
            #expect(reopened.draft.error != nil)
            #expect(try fixture.persistedText() == "Keep the accepted input recoverable")
            #expect(fixture.server.invocations("moku:submit").count == 1)
            #expect(await reopened.workspace.client.commandOutcomes().first?.status == .accepted)
        }
    }

    @Test func changedDirectoryOrReportCannotConsumeAnUncertainSubmission() async throws {
        try await NativeSubmissionFixture.run { fixture in
            fixture.server.dropReplyChannels = ["moku:submit"]
            let sender = NativeMokuSubmission(workspace: fixture.workspace)
            let input = NativeComposerSubmission(text: "Same text", directories: [], attachments: []).input
            let original: JSONValue = .object(["directoryScopeId": .text("scope-A")])
            var captures = 0
            @MainActor func send(_ source: JSONValue) async throws {
                try await sender.send(input: input, source: source) {
                    captures += 1
                    var request = source.objectValue!
                    request["input"] = input
                    return .object(request)
                }
            }
            await #expect(throws: RuntimeError.self) { try await send(original) }
            let changedSources: [JSONValue] = [.object(["directoryScopeId": .text("scope-B")]),
                                             .object(["superThreadId": .text("report-B")])]
            for changed in changedSources {
                await #expect(throws: RuntimeError.self) { try await send(changed) }
                await sender.didConsumeDraft(input: input, source: changed)
                #expect(await fixture.client.commandOutcomes().count == 1)
            }
            try await send(original)
            #expect(captures == 1 && fixture.server.invocations("moku:submit").count == 1)
            #expect(!fixture.server.receiptRequests.isEmpty)
            await sender.didConsumeDraft(input: input, source: original)
            #expect(await fixture.client.commandOutcomes().isEmpty)
        }
    }

    @Test func failureBeforeAdmissionDoesNotStrandTheNextMokuDraft() async throws {
        try await NativeSubmissionFixture.run { fixture in
            let sender = NativeMokuSubmission(workspace: fixture.workspace)
            let source: JSONValue = .object([:])
            var captures = 0
            @MainActor func send(_ text: String) async throws {
                let input = NativeComposerSubmission(text: text, directories: [], attachments: []).input
                try await sender.send(input: input, source: source) {
                    captures += 1
                    return .object(["input": input])
                }
            }
            fixture.source.failPreparation = true
            await #expect(throws: RuntimeError.self) { try await send("Never admitted") }
            #expect(captures == 0 && fixture.server.invocations("moku:submit").isEmpty)
            #expect(await fixture.client.commandOutcomes().isEmpty)
            fixture.source.failPreparation = false
            fixture.server.results["moku:submit"] = .object(["ok": .bool(false),
                "error": .object(["code": .text("INPUT_REJECTED"), "message": .text("Rejected before admission")])])
            await #expect(throws: RuntimeError.self) { try await send("Rejected") }
            #expect(await fixture.client.commandOutcomes().isEmpty)
            fixture.server.results["moku:submit"] = NativeSubmissionHTTPFixture.success(.null)
            try await send("Edited after rejection")
            #expect(captures == 2 && fixture.server.invocations("moku:submit").count == 2)
            let input = NativeComposerSubmission(text: "Edited after rejection", directories: [], attachments: []).input
            await sender.didConsumeDraft(input: input, source: source)
            #expect(await fixture.client.commandOutcomes().isEmpty)
        }
    }

    @Test func historicalForkRetainsItsBranchWhenFollowUpPreparationFails() async throws {
        try await NativeSubmissionFixture.run { fixture in
            let thread = try HarnessThread(id: "source", harnessID: "codex", revision: 1, sessionState: .null,
                observation: .init(latestExecution: try .init(executionID: "latest", status: .completed, startedAt: 1, finishedAt: 2)),
                cwd: JSONText(fixture.directory.path), settings: .object([:]), createdAt: 1, updatedAt: 2, title: "Source", tags: [])
            try await fixture.install([thread])
            fixture.server.results["thread:fork"] = NativeSubmissionHTTPFixture.success(.object(["threadId": .text("branch-B")]))
            fixture.server.results["thread:follow-up"] = NativeSubmissionHTTPFixture.success(.object(["executionId": .text("branch-run")]))
            fixture.server.onInvoke = { request in
                if request.channel == "thread:fork" { fixture.source.failPreparation = true }
            }
            let sender = NativeExecutionContinuation(workspace: fixture.workspace)
            let input = NativeComposerSubmission(text: "Historical follow-up", directories: [], attachments: []).input
            await #expect(throws: RuntimeError.self) {
                try await sender.send(threadID: "source", executionID: "history", input: input)
            }
            let held = await fixture.client.commandOutcomes()
            #expect(held.count == 1 && held.first?.channel == "thread:fork" && held.first?.status == .accepted)
            #expect(fixture.server.invocations("thread:fork").count == 1)
            #expect(fixture.server.invocations("thread:follow-up").isEmpty)

            fixture.source.failPreparation = false
            let reopened = NativeExecutionContinuation(workspace: fixture.workspace)
            await #expect(throws: RuntimeError.self) {
                try await reopened.send(threadID: "source", executionID: "history", input: input)
            }
            let accepted = try await sender.send(threadID: "source", executionID: "history", input: input)
            #expect(accepted.thread.threadID == "branch-B" && accepted.executionID == "branch-run")
            #expect(fixture.server.invocations("thread:fork").count == 1)
            let followUps = fixture.server.invocations("thread:follow-up")
            #expect(followUps.count == 1 && followUps.first?.body["args"]?.arrayValue?.first?["threadId"] == .text("branch-B"))
            let successor = await fixture.client.commandOutcomes()
            #expect(successor.count == 1 && successor.first?.channel == "thread:follow-up")
            #expect(successor.first?.commandID != held.first?.commandID)
            await sender.didConsumeDraft(threadID: "source", executionID: "history", input: input)
            #expect(await fixture.client.commandOutcomes().isEmpty)
        }
    }

    @Test(arguments: [false, true])
    func rejectedForkFollowUpKeepsItsBranchForAnEditedRetry(requestRejected: Bool) async throws {
        try await NativeSubmissionFixture.run { fixture in
            let thread = try HarnessThread(id: "source", harnessID: "codex", revision: 1, sessionState: .null,
                observation: .init(latestExecution: try .init(executionID: "latest", status: .completed, startedAt: 1, finishedAt: 2)),
                cwd: JSONText(fixture.directory.path), settings: .object([:]), createdAt: 1, updatedAt: 2, title: "Source", tags: [])
            try await fixture.install([thread])
            fixture.server.results["thread:fork"] = NativeSubmissionHTTPFixture.success(.object(["threadId": .text("branch-B")]))
            fixture.server.results["thread:follow-up"] = .object(["ok": .bool(false),
                "error": .object(["code": .text("INPUT_REJECTED"), "message": .text("Input was not admitted")])])
            fixture.server.statusCodes["thread:follow-up"] = requestRejected ? 400 : 200
            let sender = NativeExecutionContinuation(workspace: fixture.workspace)
            let original = NativeComposerSubmission(text: "Rejected original input", directories: [], attachments: []).input
            await #expect(throws: RuntimeError.self) {
                try await sender.send(threadID: "source", executionID: "history", input: original)
            }
            let held = await fixture.client.commandOutcomes()
            #expect(held.count == 1 && held.first?.channel == "thread:follow-up" && held.first?.status == .rejected)
            #expect(fixture.server.invocations("thread:fork").count == 1)
            #expect(fixture.server.invocations("thread:follow-up").count == 1)

            // Even a rejected input still owns the already-created branch.
            // A fresh client's receipt lookup may report unknown for an HTTP
            // rejection; that must not erase the durable fork association.
            let replacement = try await fixture.reopen()
            let reopened = NativeExecutionContinuation(workspace: replacement.workspace)
            let edited = NativeComposerSubmission(text: "Corrected input", directories: [], attachments: []).input
            await #expect(throws: RuntimeError.self) {
                try await reopened.send(threadID: "source", executionID: "history", input: edited)
            }
            fixture.server.statusCodes["thread:follow-up"] = 200
            fixture.server.results["thread:follow-up"] = NativeSubmissionHTTPFixture.success(.object(["executionId": .text("branch-run")]))
            let accepted = try await sender.send(threadID: "source", executionID: "history", input: edited)
            #expect(accepted.thread.threadID == "branch-B" && accepted.executionID == "branch-run")
            #expect(fixture.server.invocations("thread:fork").count == 1)
            let followUps = fixture.server.invocations("thread:follow-up")
            #expect(followUps.count == 2)
            #expect(followUps.allSatisfy { $0.body["args"]?.arrayValue?.first?["threadId"] == .text("branch-B") })
            #expect(followUps.last?.body["args"]?.arrayValue?.first?["input"] == edited)
            #expect(followUps.first?.body["commandId"] != followUps.last?.body["commandId"])
            let acceptedReceipts = await replacement.workspace.client.commandOutcomes()
            #expect(acceptedReceipts.count == 1 && acceptedReceipts.first?.status == .accepted)
            await sender.didConsumeDraft(threadID: "source", executionID: "history", input: edited)
            #expect(await replacement.workspace.client.commandOutcomes().isEmpty)
        }
    }
}

private extension RuntimeClient {
    func connectSubmissionFixture(_ endpoint: RuntimeConnection, snapshot: JSONValue) {
        connection = endpoint; state = snapshot; streamID = UUID()
        setStatus(.connected)
    }
}

final class NativeSubmissionConnectionSource: RuntimeConnectionSource {
    private let failure = Mutex(false)
    var failPreparation: Bool {
        get { failure.withLock { $0 } }
        set { failure.withLock { $0 = newValue } }
    }
    func start() async throws -> RuntimeConnection { throw CancellationError() }
    func status() async throws -> RuntimeConnection? { nil }
    func stop(expectedEpoch: String?) async throws {}
    func setOutputLocale(_ locale: String) throws {
        if failPreparation { throw RuntimeError("FIXTURE_PREPARATION_FAILED", "Command preparation failed") }
    }
}

@MainActor
final class NativeSubmissionFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("native-submission-" + UUID().uuidString)
    let source = NativeSubmissionConnectionSource()
    let server: NativeSubmissionHTTPFixture
    let client: RuntimeClient
    let workspace: NativeWorkspaceModel
    let presentation: NativeWorkspacePresentation
    var draft: NativeComposerDraft { presentation.draft }
    private var reopened: [NativeWorkspacePresentation] = []
    private var snapshot: JSONValue

    private init() throws {
        client = RuntimeClient(storageDirectory: directory, connectionSource: source)
        let preferences = DesktopPreferences(directory: directory)
        try preferences.setOnboardingCompleted(true)
        workspace = NativeWorkspaceModel(client: client, preferences: preferences,
            plugins: try .init(harnesses: [], sidecards: [], applications: []))
        presentation = NativeWorkspacePresentation(workspace: workspace)
        snapshot = .object(["revision": .integer(1), "settingsRevision": .integer(0),
            "defaultCwd": .text(directory.path), "settings": .object([:]),
            "threads": .array([]), "executions": .array([]), "applicationThreads": .array([])])
        server = try NativeSubmissionHTTPFixture()
    }

    static func run(_ body: @MainActor (NativeSubmissionFixture) async throws -> Void) async throws {
        let fixture = try NativeSubmissionFixture()
        do {
            try await fixture.connect(fixture.workspace)
            try await body(fixture)
            await fixture.close()
        } catch {
            await fixture.close()
            throw error
        }
    }

    private func connect(_ workspace: NativeWorkspaceModel) async throws {
        try await wait { self.server.port != nil }
        let endpoint = RuntimeConnection(port: Int(try #require(server.port)), token: "fixture", epoch: "fixture",
            protocolVersion: RuntimeProtocol.version, pid: Int(getpid()), dataDir: directory.path)
        await workspace.client.connectSubmissionFixture(endpoint, snapshot: snapshot)
        workspace.start()
        try await wait { workspace.runtimeAvailable }
    }

    func install(_ threads: [HarnessThread]) async throws {
        var fields = snapshot.objectValue!
        fields["revision"] = .integer((snapshot["revision"]?.intValue ?? 0) + 1)
        fields["threads"] = .array(threads.map(\.json))
        snapshot = .object(fields)
        await workspace.installPrepared(snapshot, event: .snapshot(snapshot, authority: UUID()))
        try #require(workspace.runtimeAvailable, "Fixture catalog failed: \(workspace.connectionError ?? "unknown")")
    }

    func reopen() async throws -> NativeWorkspacePresentation {
        let next = NativeWorkspaceModel(client: RuntimeClient(storageDirectory: directory, connectionSource: source),
            preferences: DesktopPreferences(directory: directory), plugins: try .init(harnesses: [], sidecards: [], applications: []))
        let presentation = NativeWorkspacePresentation(workspace: next)
        reopened.append(presentation)
        try await connect(next)
        return presentation
    }

    func persistedText() throws -> String? {
        try NativeComposerDraftPersistence(storageDirectory: directory, scope: "moku").loadText()?.textValue.string
    }

    private func wait(_ ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !ready() {
            guard ContinuousClock.now < deadline else { throw PluginContractError("Submission fixture did not become ready") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func close() async {
        for owner in reopened + [presentation] {
            await owner.draft.dispose(discardRemoteAttachments: false)
            await owner.overview.stop()
            try? await owner.workspace.stop()
        }
        server.close()
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
final class NativeSubmissionHTTPFixture {
    struct Request {
        let path: String
        let body: JSONValue
        var channel: String? { path.hasPrefix("/invoke/") ? String(path.dropFirst(8)) : nil }
    }
    private let listener: NWListener
    private var connections: [NWConnection] = []
    private var closed = false
    private(set) var port: UInt16?
    private(set) var requests: [Request] = []
    private(set) var receiptRequests: [String] = []
    private var receipts: [String: JSONValue] = [:]
    var results: [String: JSONValue] = [:]
    var statusCodes: [String: Int] = [:]
    var dropReplyChannels = Set<String>()
    var onInvoke: (@MainActor (Request) throws -> Void)?

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                if case .ready = state { self?.port = self?.listener.port?.rawValue }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self, !self.closed else { connection.cancel(); return }
                self.connections.append(connection)
                connection.start(queue: .main)
                self.receive(connection, buffered: Data())
            }
        }
        listener.start(queue: .main)
    }

    static func success(_ value: JSONValue) -> JSONValue { .object(["ok": .bool(true), "value": value]) }
    func invocations(_ channel: String) -> [Request] { requests.filter { $0.channel == channel } }

    private func receive(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, !self.closed, error == nil, let data else { connection.cancel(); return }
                let bytes = buffered + data
                guard bytes.count <= 1024 * 1024 else { connection.cancel(); return }
                guard let boundary = bytes.range(of: Data("\r\n\r\n".utf8)) else {
                    if complete { connection.cancel() } else { self.receive(connection, buffered: bytes) }
                    return
                }
                let headers = String(decoding: bytes[..<boundary.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
                let length = headers.dropFirst().first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.dropFirst(15).trimmingCharacters(in: .whitespaces)) } ?? 0
                guard bytes.count - boundary.upperBound >= length else {
                    if complete { connection.cancel() } else { self.receive(connection, buffered: bytes) }
                    return
                }
                do {
                    let target = try #require(headers.first?.split(separator: " ").dropFirst().first)
                    let path = String(target).removingPercentEncoding ?? String(target)
                    let body = try JSONValue(data: Data(bytes[boundary.upperBound..<(boundary.upperBound + length)]))
                    try self.respond(to: Request(path: path, body: body), connection: connection)
                } catch {
                    Issue.record("Submission HTTP fixture failed: \(error)")
                    connection.cancel()
                }
            }
        }
    }

    private func respond(to request: Request, connection: NWConnection) throws {
        requests.append(request)
        let response: JSONValue
        var statusCode = 200
        if let channel = request.channel {
            let id = try #require(request.body["commandId"]?.stringValue)
            response = results[channel] ?? Self.success(.null)
            statusCode = statusCodes[channel] ?? 200
            if statusCode == 200 { receipts[id] = response }
            try onInvoke?(request)
            if dropReplyChannels.remove(channel) != nil {
                // Start a response before dropping it, so URLSession cannot
                // treat a pre-response connection loss as a transport retry.
                let partial = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 128\r\nConnection: close\r\n\r\n{\"ok\":".utf8)
                connection.send(content: partial, completion: .contentProcessed { _ in connection.cancel() })
                return
            }
        } else if request.path == "/commands/receipt" {
            let id = try #require(request.body["commandId"]?.stringValue)
            receiptRequests.append(id)
            response = receipts[id].map { .object(["status": .text("complete"), "result": $0]) }
                ?? .object(["status": .text("unknown")])
        } else {
            Issue.record("Unexpected submission fixture path: \(request.path)")
            connection.cancel(); return
        }
        let body = try response.encodedData()
        let header = Data("HTTP/1.1 \(statusCode) \(statusCode == 200 ? "OK" : "Rejected")\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        connection.send(content: header + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    func close() {
        closed = true; listener.cancel()
        onInvoke = nil
        connections.forEach { $0.cancel() }
        connections.removeAll()
    }
}
