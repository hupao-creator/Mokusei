import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
import MokuseiCore
import MokuseiPluginAPI
@testable import MokuseiUI

@MainActor
@Suite(.serializedNative)
struct NativeThreadVisibilityTests {
    private func thread(_ id: JSONText, status: PublicExecution.Status? = nil,
                        archived: Bool? = nil, moku: Bool? = nil, revision: Int = 0,
                        tags: [JSONText] = []) throws -> HarnessThread {
        let execution = try status.map {
            try PublicExecution(executionID: revision == 0 ? "first" : "successor", status: $0,
                                startedAt: 1, finishedAt: $0 == .running ? nil : 2)
        }
        return try HarnessThread(id: id, harnessID: "codex", revision: revision,
            sessionState: .object(["retained": .text("private native history")]),
            observation: .init(latestExecution: execution), cwd: "/workspace/project",
            settings: .object([:]), createdAt: 1, updatedAt: 2, title: id, tags: tags,
            archived: archived, moku: moku, transcript: moku == true ? .array([]) : nil,
            tagEmojis: Dictionary(uniqueKeysWithValues: tags.map { ($0, JSONText("🔧")) }))
    }

    private func snapshot(_ threads: [HarnessThread], revision: Int = 0) -> JSONValue {
        .object(["revision": .number(Double(revision)), "settingsRevision": .number(0),
                 "defaultCwd": .text("/workspace/project"), "settings": .object([:]),
                 "threads": .array(threads.map(\.json)), "executions": .array([]),
                 "applicationThreads": .array([])])
    }

    @Test(arguments: [PublicExecution.Status.interrupted, .failed])
    func unsuccessfulExecutionOnlyChangesPresentationAndSuccessorsRestoreMembership(status: PublicExecution.Status) throws {
        let hidden = try thread("hidden", status: status, tags: ["Hidden only", "Shared"])
        let archivedHidden = try thread("archived-hidden", status: status,
                                        archived: true, tags: ["Archived hidden"])
        let completed = try thread("completed", status: .completed, tags: ["Shared"])
        let running = try thread("running", status: .running, tags: ["Shared"])
        let fresh = try thread("fresh")
        let archived = try thread("archived", status: .completed, archived: true, tags: ["Archive"])
        let moku = try thread("moku", status: status, moku: true)
        let catalog = NativeWorkspaceCatalog()
        try catalog.install(snapshot([hidden, archivedHidden, completed, running, fresh, archived, moku]))

        let current = NativeOverviewSelection.select(threads: catalog.threads, applications: [])
        #expect(current.threads.map(\.id) == ["completed", "running", "fresh"])
        let currentFilters = NativeOverviewSelection.filters(
            NativeOverviewSelection.candidates(threads: catalog.threads, applications: []))
        #expect(currentFilters.withChildren.first { $0.tag == "Shared" }?.count == 2)
        #expect(!currentFilters.withChildren.contains { $0.tag == "Hidden only" || $0.aliases.contains("Hidden only") })
        #expect(catalog.thread("hidden")?.json == hidden.json)
        #expect(catalog.thread("archived-hidden")?.json == archivedHidden.json)
        #expect(catalog.moku?.json == moku.json)
        #expect(!moku.isHiddenFromUser)

        let successor = try thread("hidden", status: .running, revision: 1, tags: ["Shared"])
        try catalog.install(snapshot([successor, archivedHidden, completed, running, fresh, archived, moku], revision: 1))
        let restored = NativeOverviewSelection.select(threads: catalog.threads, applications: [])
        #expect(restored.threads.map(\.id) == ["hidden", "completed", "running", "fresh"])
        #expect(NativeOverviewSelection.filters(restored).withChildren.first { $0.tag == "Shared" }?.count == 3)
        #expect(catalog.thread("hidden")?.archived == nil)
        #expect(catalog.moku?.json == moku.json)

        let stoppedAgain = try thread("hidden", status: status, revision: 2, tags: ["Shared"])
        try catalog.install(snapshot([stoppedAgain, archivedHidden, completed, running, fresh, archived, moku], revision: 2))
        let stopped = NativeOverviewSelection.select(threads: catalog.threads, applications: [])
        #expect(stopped.threads.map(\.id) == ["completed", "running", "fresh"])
        #expect(NativeOverviewSelection.filters(stopped).withChildren.first { $0.tag == "Shared" }?.count == 2)
        #expect(catalog.thread("hidden")?.json == stoppedAgain.json)
    }

    @Test
    func singleThreadSemanticTagsRemainAvailableAlongsideSharedTags() throws {
        let first = try thread("first", tags: ["Shared", "Specific"])
        let second = try thread("second", tags: ["Shared"])
        let collection = NativeOverviewSelection.candidates(threads: [first, second], applications: [])

        let filters = NativeOverviewSelection.filters(collection)
        #expect(filters.withChildren.first { $0.tag == "Shared" }?.count == 2)
        #expect(filters.withChildren.first { $0.tag == "Specific" }?.count == 1)
    }
}


private extension Array where Element == NativeOverviewFilter {
    var withChildren: [NativeOverviewFilter] { self + flatMap(\.children) }
}
