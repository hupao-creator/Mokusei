import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
import MokuseiCore
import MokuseiPluginAPI
@testable import MokuseiUI

@MainActor
@Suite(.serializedNative)
struct NativeArchivedThreadsTests {
    private func agent(_ id: JSONText, archived: Bool = false, status: PublicExecution.Status = .completed) throws -> HarnessThread {
        try HarnessThread(id: id, harnessID: "codex", revision: 0, sessionState: .object([:]),
            observation: .init(latestExecution: try PublicExecution(executionID: "execution", status: status,
                startedAt: 1, finishedAt: 2)), cwd: "/workspace/project", settings: .object([:]),
            createdAt: 1, updatedAt: 2, title: id, tags: ["Shared"], archived: archived, tagEmojis: ["Shared": "🔧"])
    }

    private func application(_ id: JSONText, archived: Bool, directoryOnly: Bool = false) -> JSONValue {
        .object(["id": .string(id), "ref": ApplicationThreadRef(threadID: id, typeID: "report").json, "revision": .number(0),
            "createdAt": .number(1), "updatedAt": .number(3), "title": .string(id), "archived": .bool(archived),
            "tags": .object(["tags": .array([.text("Shared"), .text("project")]),
                             "semanticTags": .array([.text("Shared")]), "tagEmojis": .object(["Shared": .text("🔧")]), "directoryTags": .array([.text("project")])]),
            "presentations": .array([.object(["id": .text("mokusei.overview"), "apiVersion": .number(1), "schemaVersion": .number(1),
                "value": .object(directoryOnly ? ["coversExecutions": .array([]), "tagFilter": .text("directory")] : ["coversExecutions": .array([])])])]),
            "view": .object([:])])
    }

    @Test func overviewExcludesArchivesWithAllSemanticAndDirectoryFilters() throws {
        let agents = try [agent("active"), agent("archived", archived: true)]
        let applications = try [application("active-report", archived: false), application("archived-report", archived: true),
                                application("directory-report", archived: false, directoryOnly: true)].map(NativeOverviewApplicationEntry.init)
        let all = NativeOverviewSelection.select(threads: agents, applications: applications)
        #expect(all.threads.map(\.id) == ["active"])
        #expect(all.applications.map { $0.entry.ref.threadID } == ["active-report"])
        let semantic = NativeOverviewSelection.select(threads: agents, applications: applications, tags: ["Shared"], kind: .semantic)
        #expect(semantic.count == 2)
        let directory = NativeOverviewSelection.select(threads: agents, applications: applications, tags: ["project"], kind: .directory)
        #expect(directory.threads.map(\.id) == ["active"])
        #expect(directory.applications.map { $0.entry.ref.threadID } == ["active-report", "directory-report"])
        let filters = NativeOverviewSelection.filters(NativeOverviewSelection.candidates(threads: agents, applications: applications))
        #expect(filters.allSatisfy { $0.count == 1 })
        #expect(filters.withChildren.allSatisfy { $0.count == 1 })
    }

}


private extension Array where Element == NativeOverviewFilter {
    var withChildren: [NativeOverviewFilter] { self + flatMap(\.children) }
}
