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
}

extension RuntimeClient {
    func seedContentForTest(id: String, wire: String, value: JSONValue, revision: Int) {
        var resource = ContentResource(threadID: "thread", scope: .thread)
        resource.wireID = wire
        resource.value = value
        resource.revision = revision
        resource.acknowledged = true
        contentResources[id] = resource
    }
    func receiveContentForTest(_ event: JSONValue) async throws { try await receiveContent(event) }
    func contentForTest(_ id: String) -> (value: JSONValue?, revision: Int?) {
        (contentResources[id]?.value, contentResources[id]?.revision)
    }
}
