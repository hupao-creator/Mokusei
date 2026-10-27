import Foundation
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
import MokuseiCore
import MokuseiPluginAPI
import MokuseiHarnessCodex
import MokuseiApplications
@testable import MokuseiUI

@MainActor @Suite(.serializedNative, .serialized)
struct NativeOverviewMembershipTests {
    private func thread(_ id: JSONText = "a", title: JSONText = "Initial", revision: Int = 0,
                        status: PublicExecution.Status = .running, execution: JSONText = "e1",
                        tag: JSONText = "Shared", emoji: JSONText = "🔧", scope: JSONText = "/fixture/A",
                        archived: Bool = false) throws -> HarnessThread {
        try .init(id: id, harnessID: "codex", revision: revision, sessionState: .null,
            observation: .init(latestExecution: try .init(executionID: execution, status: status,
                startedAt: 1, finishedAt: status == .running ? nil : 2)),
            cwd: scope, settings: .object([:]), createdAt: 1, updatedAt: Double(revision + 2),
            title: title, tags: [tag], archived: archived, tagEmojis: [tag: emoji],
            directoryTag: "Project", directoryScope: scope)
    }

    private func report(title: String = "Report", scope: String = "/fixture/A", directoryOnly: Bool = false,
                        visible: Bool = true, archived: Bool = false, covers: String = "e1") -> JSONValue {
        var presentation: [JSONText: JSONValue] = ["visible": .bool(visible), "coversExecutions": .array([
            .object(["thread": ApplicationThreadRef(threadID: "a", typeID: "agent").json, "executionId": .text(covers)])])]
        if directoryOnly { presentation["tagFilter"] = .text("directory") }
        return .object(["id": .text("report"), "ref": ApplicationThreadRef(threadID: "report", typeID: "report.document").json,
            "revision": .integer(0), "createdAt": .number(2), "updatedAt": .number(2), "title": .text(title),
            "scope": .text(scope), "archived": .bool(archived),
            "tags": .object(["tags": .array([.text("Project"), .text("Shared")]),
                "semanticTags": .array([.text("Shared")]), "directoryTags": .array([.text("Project")]),
                "tagEmojis": .object(["Shared": .text("🔧")])]),
            "presentations": .array([.object(["id": .text("mokusei.overview"), "apiVersion": .integer(1), "schemaVersion": .integer(1),
                "value": .object(presentation)])]),
            "view": .object(["previewText": .text(title), "contentRevision": .text(title), "relatedExecutions": .array([])])])
    }

    private func model(_ directory: URL) throws -> NativeOverviewWorkspaceModel {
        let workspace = NativeWorkspaceModel(client: RuntimeClient(profile: try RuntimeProfile(dataDirectory: directory)),
            preferences: DesktopPreferences(directory: directory), plugins: try .init(
                harnesses: [AnyHarnessPlugin(CodexHarnessPlugin())], sidecards: [], applications: NativeApplicationModules.make()))
        return .init(workspace: workspace, applications: .init(projectionCapabilities: { plugin, entry in
            try .init(scope: .init(pluginID: plugin.ownerPluginID, thread: entry.ref), requires: plugin.requires, registrations: [])
        }, rendererContext: { _, _, _ in throw CancellationError() }))
    }

    private func deliver(_ threads: [HarnessThread], applications: [JSONValue] = [],
                         to model: NativeOverviewWorkspaceModel, authority: UUID) throws {
        let first = model.workspace.catalog.revision < 0
        let snapshot: JSONValue = .object(["revision": .integer(model.workspace.catalog.revision + 1),
            "settingsRevision": .integer(0), "defaultCwd": .text("/fixture"), "settings": .object([:]),
            "threads": .array(threads.map(\.json)), "executions": .array([]), "applicationThreads": .array(applications)])
        try model.workspace.catalog.install(snapshot)
        model.receive(first ? .snapshot(snapshot, authority: authority) : .mutation(.object([:]), state: snapshot, authority: authority))
        #expect(model.error == nil)
    }

    @Test func streamingKeepsMembershipButAlwaysUsesCurrentCardAndSearchContent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try model(directory), authority = UUID()
        try deliver([thread(), thread("b")], to: model, authority: authority)
        let filter = try #require(model.filters.first?.children.first)
        model.selectTag(filter)
        let builds = model.membershipBuildCount, facts = model.filterContextFacts
        for revision in 1...10 {
            try deliver([thread(title: JSONText("Updated \(revision)"), revision: revision, status: .completed), thread("b")],
                        to: model, authority: authority)
        }
        #expect(model.membershipBuildCount == builds && model.filterContextFacts == facts)
        let item = try #require(model.items.first { $0.id == "a" })
        guard case .harness(let snapshot) = model.snapshot(for: item) else { Issue.record("Missing card"); return }
        #expect(snapshot.input.thread.title == "Updated 10" && item.completed && !item.carouselEligible)
        model.beginSearch(); model.updateSearch("Updated 10")
        #expect(model.items.map(\.id) == ["a"])
        model.endSearch()
        #expect(model.items.map(\.id) == ["a", "b"])
        #expect(model.membershipBuildCount == builds)
        await model.stop(); await model.workspace.client.close()
    }

    @Test func visibilityTagsScopeOrderingAndAuthorityInvalidateMembership() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try model(directory), authority = UUID()
        try deliver([thread(), thread("b", scope: "/fixture/B")], to: model, authority: authority)
        let initialFilter = try #require(model.filters.first { $0.scope == "/fixture/A" }?.children.first)
        model.selectTag(initialFilter)
        try deliver([thread(status: .failed), thread("b", scope: "/fixture/B")], to: model, authority: authority)
        #expect(model.items.map(\.id) == ["b"] && model.selectedTag.isEmpty)
        try deliver([thread(tag: "New", emoji: "🎨", scope: "/fixture/C"), thread("b", archived: true)], to: model, authority: authority)
        let child = try #require(model.filters.first?.children.first)
        #expect(child.tag == "New" && child.emoji == "🎨" && child.scope == "/fixture/C" && child.count == 1)
        try deliver([thread("b"), thread()], to: model, authority: authority)
        #expect(model.items.map(\.id) == ["b", "a"])
        try deliver([thread(), thread("b")], to: model, authority: authority)
        #expect(model.items.map(\.id) == ["a", "b"])
        let builds = model.membershipBuildCount
        try deliver([thread(), thread("b")], to: model, authority: UUID())
        #expect(model.membershipBuildCount == builds + 1)
        try deliver([], to: model, authority: authority)
        #expect(model.items.isEmpty && model.filters.isEmpty && model.filterContextFacts.isEmpty)
        await model.stop(); await model.workspace.client.close()
    }

    @Test func reportContentCoverageAndPresentationResolveAgainstLatestCatalog() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try model(directory), authority = UUID()
        try deliver([thread()], applications: [report()], to: model, authority: authority)
        #expect(model.items.map(\.id) == ["report"])
        let builds = model.membershipBuildCount
        try deliver([thread()], applications: [report(title: "Updated")], to: model, authority: authority)
        let item = try #require(model.items.first)
        guard case .application(_, let snapshot) = model.snapshot(for: item) else { Issue.record("Missing report"); return }
        #expect(snapshot.entry.title == "Updated" && snapshot.envelope.excerpt == "Updated")
        #expect(model.membershipBuildCount == builds)
        try deliver([thread(execution: "e2")], applications: [report()], to: model, authority: authority)
        #expect(model.items.map(\.id) == ["a", "report"])
        try deliver([thread(execution: "e2")], applications: [report(covers: "e2")], to: model, authority: authority)
        #expect(model.items.map(\.id) == ["report"])
        try deliver([thread()], applications: [report(scope: "/fixture/B", directoryOnly: true)], to: model, authority: authority)
        #expect(model.items.map(\.id) == ["a"])
        let reportFilter = try #require(model.filters.first { $0.scope == "/fixture/B" })
        model.selectTag(reportFilter)
        #expect(model.items.map(\.id) == ["report"])
        try deliver([thread()], applications: [report(scope: "/fixture/B", visible: false)], to: model, authority: authority)
        #expect(model.items.map(\.id) == ["a"] && model.selectedTag.isEmpty)
        try deliver([thread()], applications: [report(archived: true)], to: model, authority: authority)
        #expect(model.items.map(\.id) == ["a"])
        await model.stop(); await model.workspace.client.close()
    }

    @Test func repeatedUnicodeLabelsKeepCanonicalMembershipAndFreshDecoration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try model(directory), authority = UUID()
        try deliver([thread(tag: "Shared"), thread("b", tag: "Ｓｈａｒｅｄ")], to: model, authority: authority)
        let children = try #require(model.filters.first?.children)
        #expect(children.count == 1 && children.first?.count == 2)
        let shared = try #require(children.first)
        model.selectTag(shared)
        #expect(model.items.map(\.id) == ["a", "b"])
        try deliver([thread(tag: "Shared", emoji: "🎨"), thread("b", tag: "Other")], to: model, authority: authority)
        #expect(model.items.map(\.id) == ["a"])
        let changed = try #require(model.filters.first?.children.first { $0.tag == "Shared" })
        #expect(changed.emoji == "🎨" && changed.count == 1)
        let other = try #require(model.filters.first?.children.first { $0.tag == "Other" })
        model.selectTag(other)
        #expect(model.items.map(\.id) == ["b"])
        await model.stop(); await model.workspace.client.close()
    }
}
