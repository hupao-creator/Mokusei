import Foundation
import Testing
@testable import MokuseiCore

struct RuntimeAppliedDeliveryTests {
    static let snapshot: JSONValue = .object(["revision": .integer(1), "defaultCwd": .text("/tmp"),
        "threads": .array([]), "applicationThreads": .array([]), "executions": .array([]),
        "settings": .object([:]), "settingsRevision": .integer(0)])
    static func mutation(_ base: Int, _ revision: Int, _ phase: String) -> JSONValue {
        .object(["type": .text("state-patched"), "baseRevision": .integer(base), "revision": .integer(revision),
                 "agentRuns": .array([.text(phase)]), "settingsRevision": .integer(revision)])
    }

    @Test func bufferedHydrationPairsEveryRevisionAndRejectsGaps() throws {
        let first = Self.mutation(1, 2, "running"), last = Self.mutation(2, 3, "completed")
        let commits = try #require(try RuntimeState.replaying([Self.mutation(0, 1, "old"), first, last], over: Self.snapshot))
        #expect(commits.map(\.mutation) == [first, last])
        #expect(commits.map { $0.state["revision"] } == [.integer(2), .integer(3)])
        #expect(commits[0].state["agentRuns"] == .array([.text("running")]))
        #expect(commits[1].state["agentRuns"] == .array([.text("completed")]))
        #expect(try RuntimeState.replaying([last], over: Self.snapshot) == nil)
    }

    @Test func slowConsumerReceivesExactStatesWithOriginalMutationsAndAuthority() async throws {
        let client = RuntimeClient(profile: try RuntimeProfile(dataDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        await client.seedAppliedDelivery(Self.snapshot)
        let stream = await client.events()
        let authority = await client.deliveryAuthority()
        let mutations = [Self.mutation(1, 2, "running"), Self.mutation(2, 3, "completed")]
        for mutation in mutations { try await client.acceptMutation(mutation) }
        // Duplicate is ignored. Actor has already advanced to revision 3 before
        // this deliberately slow observer begins draining its queue.
        try await client.acceptMutation(mutations[0])
        var received: [JSONValue] = []
        for await event in stream {
            if case .mutation(let mutation, let state, let owner) = event {
                let index = received.count
                #expect(mutation == mutations[index])
                #expect(state["revision"] == mutation["revision"])
                #expect(state["agentRuns"] == mutation["agentRuns"])
                #expect(owner == authority)
                received.append(mutation)
                if received.count == 2 { break }
            }
        }
        let recovery = await client.currentSnapshotEvent()
        if case .snapshot(let state, let owner) = recovery {
            #expect(state["revision"] == .integer(3)); #expect(owner == authority)
        } else { Issue.record("Missing recovery snapshot") }
        await client.close()
    }
}

extension RuntimeClient {
    func seedAppliedDelivery(_ value: JSONValue) { state = value }
    func deliveryAuthority() -> UUID { stateAuthority }
}

extension RuntimeAppliedDeliveryTests {
    @Test func overflowReattachmentKeepsAuthorityAndInstallsCurrentState() async throws {
        let client = RuntimeClient(profile: try RuntimeProfile(dataDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        await client.seedAppliedDelivery(Self.snapshot)
        let stream = await client.events(), authority = await client.deliveryAuthority()
        for revision in 2...140 { try await client.acceptMutation(Self.mutation(revision - 1, revision, "phase-\(revision)")) }
        var overflow = false
        for await event in stream {
            if case .failure(let error) = event { overflow = error.code == "CONSUMER_OVERFLOW" }
        }
        #expect(overflow)
        let recovered = await client.events()
        for await event in recovered {
            if case .snapshot(let state, let owner) = event {
                #expect(owner == authority && state["revision"] == .integer(140))
                break
            }
        }
        await client.close()
    }
}
