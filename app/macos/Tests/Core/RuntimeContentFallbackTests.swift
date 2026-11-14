import Foundation
import Testing
@testable import MokuseiCore

struct RuntimeContentFallbackTests {
    @Test func denseSnapshotReplacesExistingValueAndResumesPatchChain() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let client = RuntimeClient(profile: try RuntimeProfile(dataDirectory: directory))
        await client.seedContentForTest(id: "content", wire: "wire", value: .array([.integer(0), .integer(0), .integer(0)]), revision: 1)

        // A dense update arrives as another snapshot on the same resource.
        try await client.receiveContentForTest(.object([
            "type": .text("snapshot"), "subscriptionId": .text("wire"), "revision": .integer(2),
            "value": .array([.integer(1), .integer(1), .integer(1)])
        ]))
        // The next update is a patch whose base is the replacement snapshot.
        try await client.receiveContentForTest(.object([
            "type": .text("patch"), "subscriptionId": .text("wire"), "baseRevision": .integer(2),
            "revision": .integer(3),
            "patch": .array([.object([
                "op": .text("replace"), "path": .array([.integer(0)]), "value": .integer(2)
            ])])
        ]))

        let state = await client.contentForTest("content")
        #expect(state.value == .array([.integer(2), .integer(1), .integer(1)]))
        #expect(state.revision == 3)
        await client.close()
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func replacementSnapshotClearsHistoricalRecoveryState() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let client = RuntimeClient(profile: try RuntimeProfile(dataDirectory: directory))
        await client.seedContentForTest(id: "content", wire: "wire", value: .array([.integer(0)]), revision: 1,
                                        recoveries: 3, isRecovering: true)

        try await client.receiveContentForTest(.object([
            "type": .text("snapshot"), "subscriptionId": .text("wire"), "revision": .integer(2),
            "value": .array([.integer(1)])
        ]))

        let state = await client.contentForTest("content")
        #expect(state.value == .array([.integer(1)]))
        #expect(state.revision == 2)
        #expect(state.recoveries == 0)
        #expect(!state.isRecovering)
        await client.close()
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func goPublishedFallbackSequenceReachesRuntimeReceiver() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let client = RuntimeClient(profile: try RuntimeProfile(dataDirectory: directory))
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["MOKUSEI_GO_CONTENT_EVENTS"] {
            let fixture = try JSONValue(data: Data(contentsOf: URL(fileURLWithPath: path)))
            let events = try #require(fixture["events"]?.arrayValue)
            let expected = try #require(fixture["expected"])
            let epoch = try #require(events.first?["epoch"]?.stringValue)
            let transport = await client.seedTransportForContentTest(epoch: epoch)
            await client.seedPendingContentForTest(id: "content", wire: "wire")
            for event in events { try await client.receiveOuterForTest(event, connection: transport.connection, stream: transport.stream) }
            let state = await client.contentForTest("content")
            #expect(state.value == expected)
            #expect(state.revision == events.count)
            print("PASS Go content fallback events: \(events.count)")
        } else {
            // The complete native suite runs the same outer-envelope dispatch
            // with a hand-authored sequence when the Go fixture is absent.
            let epoch = "test-epoch"
            let transport = await client.seedTransportForContentTest(epoch: epoch)
            await client.seedPendingContentForTest(id: "content", wire: "wire")
            let empty = JSONValue.array([.integer(0), .integer(0), .integer(0)])
            let dense = JSONValue.array([.integer(1), .integer(1), .integer(1)])
            let events = [
                Self.outer(epoch, .object(["type": .text("snapshot"), "subscriptionId": .text("wire"), "revision": .integer(1), "value": empty])),
                Self.outer(epoch, .object(["type": .text("snapshot"), "subscriptionId": .text("wire"), "revision": .integer(2), "value": dense])),
                Self.outer(epoch, .object([
                    "type": .text("patch"), "subscriptionId": .text("wire"), "baseRevision": .integer(2),
                    "revision": .integer(3),
                    "patch": .array([.object(["op": .text("replace"), "path": .array([.integer(0)]), "value": .integer(2)])])
                ]))
            ]
            for event in events { try await client.receiveOuterForTest(event, connection: transport.connection, stream: transport.stream) }
            let state = await client.contentForTest("content")
            #expect(state.value == .array([.integer(2), .integer(1), .integer(1)]))
            #expect(state.revision == 3)
        }
        await client.close()
        try? FileManager.default.removeItem(at: directory)
    }

    private static func outer(_ epoch: String, _ event: JSONValue) -> JSONValue {
        .object(["type": .text("thread-content"), "epoch": .text(epoch), "event": event])
    }
}

extension RuntimeClient {
    func seedContentForTest(id: String, wire: String, value: JSONValue, revision: Int,
                            recoveries: Int = 0, isRecovering: Bool = false) {
        var resource = ContentResource(threadID: "thread", scope: .thread)
        resource.wireID = wire
        resource.value = value
        resource.revision = revision
        resource.acknowledged = true
        resource.recoveries = recoveries
        resource.isRecovering = isRecovering
        contentResources[id] = resource
    }
    func seedPendingContentForTest(id: String, wire: String) {
        var resource = ContentResource(threadID: "thread", scope: .thread)
        resource.wireID = wire
        contentResources[id] = resource
    }
    func seedTransportForContentTest(epoch: String) -> (connection: RuntimeConnection, stream: UUID) {
        let connection = RuntimeConnection(port: 0, token: "fixture", epoch: epoch, protocolVersion: RuntimeProtocol.version, pid: 0, dataDir: "")
        self.connection = connection
        let stream = UUID()
        streamID = stream
        generation = 0
        clientID = "fixture-client"
        return (connection, stream)
    }
    func receiveContentForTest(_ event: JSONValue) async throws { try await receiveContent(event) }
    func receiveOuterForTest(_ event: JSONValue, connection: RuntimeConnection, stream: UUID) async throws {
        try await receive(event, connection: connection, stream: stream, generation: 0)
    }
    func contentForTest(_ id: String) -> (value: JSONValue?, revision: Int?, recoveries: Int, isRecovering: Bool) {
        (contentResources[id]?.value, contentResources[id]?.revision,
         contentResources[id]?.recoveries ?? 0, contentResources[id]?.isRecovering ?? false)
    }
}
