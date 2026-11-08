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

/// Replays the production admission and mutation path. A fresh full snapshot on
/// every update would bypass the exact changed identities these assertions cover.
@MainActor @Suite(.serializedNative, .serialized)
struct NativeLocalChangeFanoutTests {
    @Test func retainedCatalogsPreserveOrderAndSameRevisionReplacement() async throws {
        try await withFixture(threads: [thread("a"), thread("b"), thread("c")],
                              applications: [report("r1"), report("r2")]) { fixture in
            let original = fixture.state
            let originalThreads = try #require(original["threads"]?.catalogValue)
            let originalApplications = try #require(original["applicationThreads"]?.catalogValue)
            let wireThreads = JSONValue.array(Array(originalThreads))
            #expect(original["threads"] == wireThreads)
            #expect(Set([original["threads"]!, wireThreads]).count == 1)

            try await fixture.patch(["threads": patch(upserts: [try thread("b", title: "Changed", revision: 1).json])])
            #expect(fixture.state["threads"]?.catalogValue?.ids == ["a", "b", "c"])
            #expect(fixture.workspace.catalog.thread("b")?.title == "Changed")
            #expect(originalThreads["b"]?["title"] == .text("Initial"))
            #expect(originalThreads.ids == ["a", "b", "c"])
            let unchangedApplications = try #require(fixture.state["applicationThreads"]?.catalogValue)
            #expect(unchangedApplications.sharesStorage(with: originalApplications))

            try await fixture.patch(["threads": patch(order: ["c", "a", "b"])])
            let ordered = fixture.state
            #expect(fixture.workspace.catalog.threads.map(\.id) == ["c", "a", "b"])
            try await fixture.patch(["threads": patch(upserts: [try thread("d").json], removed: ["a"])])
            #expect(fixture.workspace.catalog.threads.map(\.id) == ["c", "b", "d"])
            #expect(ordered["threads"]?.catalogValue?.ids == ["c", "a", "b"])
            #expect(original["threads"]?.catalogValue?.ids == ["a", "b", "c"])

            // An ordinary duplicate revision is stale; remove+upsert is a new
            // incarnation even when its application-owned revision starts at zero.
            try await fixture.patch(["applicationThreads": patch(upserts: [report("r1", title: "Stale")])])
            let reference = ApplicationThreadRef(threadID: "r1", typeID: "report.document")
            let unchangedApplication = try fixture.workspace.catalog.applicationEntry(reference)
            #expect(unchangedApplication.title == "Report")
            try await fixture.patch(["applicationThreads": patch(
                upserts: [report("r1", title: "Replacement", introduction: "New incarnation")],
                removed: ["r1"], order: ["r1", "r2"])])
            let replacement = try fixture.workspace.catalog.applicationEntry(reference)
            #expect(replacement.revision == 0 && replacement.title == "Replacement")
            #expect(replacement.view["shortDescription"] == .text("New incarnation"))
            #expect(fixture.state["applicationThreads"]?.catalogValue?.ids == ["r1", "r2"])
            #expect(originalApplications["r1"]?["title"] == .text("Report"))
            let item = try #require(fixture.model.items.first { $0.id == "r1" })
            guard case .application(_, let snapshot) = fixture.model.snapshot(for: item) else {
                Issue.record("Replacement application has no current card"); return
            }
            #expect(snapshot.entry.title == "Replacement" && snapshot.envelope.excerpt == "New incarnation")
        }
    }

    @Test(arguments: [8, 128], [false, true])
    func contentAndActivityVisitOnlyChangedOwners(unrelatedCount: Int, replacement: Bool) async throws {
        let threads = try [thread("target")] + (0..<unrelatedCount).map { try thread(JSONText("thread-\($0)")) }
        let applications = [report("report-target")] + (0..<unrelatedCount).map { report("report-\($0)") }
        try await withFixture(threads: threads, applications: applications) { fixture in
            let model = fixture.model
            let originalItems = model.items
            let projections = model.projectionVisitCount, visits = model.catalogChangeVisitCount
            let selections = model.membershipSelectionCount
            let candidates = model.membershipApplicationCandidateVisits
            let admissions = fixture.workspace.catalog.applicationAdmissionCount
            let revision = replacement ? 0 : 1
            try await fixture.patch(["threads": patch(
                upserts: [try thread("target", title: "Latest thread", revision: revision).json],
                removed: replacement ? ["target"] : [])])
            #expect(model.projectionVisitCount == projections + 1)
            #expect(model.catalogChangeVisitCount == visits + 1)
            #expect(model.membershipSelectionCount == selections)
            #expect(model.membershipApplicationCandidateVisits == candidates)
            #expect(model.items.map(\.id) == originalItems.map(\.id))
            #expect(fixture.workspace.catalog.applicationAdmissionCount == admissions)
            #expect(model.items.filter { $0.id != "target" } == originalItems.filter { $0.id != "target" })
            let threadItem = try #require(model.items.first { $0.id == "target" })
            guard case .harness(let threadSnapshot) = model.snapshot(for: threadItem) else {
                Issue.record("Changed thread has no current card"); return
            }
            #expect(threadSnapshot.input.thread.title == "Latest thread")

            let beforeApplication = model.items
            try await fixture.patch(["applicationThreads": patch(upserts: [
                report("report-target", title: "Latest report", introduction: "Latest introduction", revision: revision)
            ], removed: replacement ? ["report-target"] : [])])
            #expect(model.projectionVisitCount == projections + 2)
            #expect(model.catalogChangeVisitCount == visits + 2)
            #expect(model.membershipSelectionCount == selections)
            #expect(model.membershipApplicationCandidateVisits == candidates)
            #expect(model.items.map(\.id) == originalItems.map(\.id))
            #expect(fixture.workspace.catalog.applicationAdmissionCount == admissions + 1)
            #expect(model.items.filter { $0.id != "report-target" } == beforeApplication.filter { $0.id != "report-target" })
            let reportItem = try #require(model.items.first { $0.id == "report-target" })
            guard case .application(_, let reportSnapshot) = model.snapshot(for: reportItem) else {
                Issue.record("Changed application has no current card"); return
            }
            #expect(reportSnapshot.entry.title == "Latest report" && reportSnapshot.envelope.excerpt == "Latest introduction")

            let beforeActivity = fixture.state, retainedItems = model.items
            try await fixture.patch(["activities": activity("target")])
            #expect(model.projectionVisitCount == projections + 2)
            #expect(model.catalogChangeVisitCount == visits + 2)
            #expect(model.membershipSelectionCount == selections && model.items == retainedItems)
            let currentThreads = try #require(fixture.state["threads"]?.catalogValue)
            let currentApplications = try #require(fixture.state["applicationThreads"]?.catalogValue)
            let previousThreads = try #require(beforeActivity["threads"]?.catalogValue)
            let previousApplications = try #require(beforeActivity["applicationThreads"]?.catalogValue)
            #expect(currentThreads.sharesStorage(with: previousThreads))
            #expect(currentApplications.sharesStorage(with: previousApplications))
            print("LOCAL_CHANGE_FANOUT unrelated=\(unrelatedCount) replacement=\(replacement) contentVisits=1 contentProjections=1 activityVisits=0")
        }
    }

    @Test(arguments: [8, 128])
    func membershipChangeReselectsOnlyItsScope(unrelatedCount: Int) async throws {
        let threads = try [thread("a")] + (0..<unrelatedCount).map {
            try thread(JSONText("b-\($0)"), scope: "/fixture/B")
        }
        let covered = ApplicationExecutionRef(thread: .init(threadID: "a", typeID: "agent"), executionID: "e1")
        try await withFixture(threads: threads, applications: [report("report-a", covers: [covered]),
            report("report-b", scope: "/fixture/B")]) { fixture in
            let model = fixture.model
            let selected = try #require(model.filters.first { $0.scope == "/fixture/B" }?.children.first)
            model.selectTag(selected)
            let retainedItems = model.items
            let retainedFilter = try #require(model.filters.first { $0.scope == "/fixture/B" })
            let projections = model.projectionVisitCount, visits = model.catalogChangeVisitCount
            let selections = model.membershipSelectionCount, candidates = model.membershipApplicationCandidateVisits
            #expect(model.filters.first { $0.scope == "/fixture/A" }?.count == 1)

            try await fixture.patch(["threads": patch(upserts: [try thread("a", revision: 1, execution: "e2").json])])
            #expect(model.catalogChangeVisitCount == visits + 1)
            #expect(model.membershipSelectionCount == selections + 2)
            #expect(model.membershipApplicationCandidateVisits == candidates + 2)
            #expect(model.projectionVisitCount == projections)
            #expect(model.selectedScope == "/fixture/B" && model.items == retainedItems)
            #expect(model.filters.first { $0.scope == "/fixture/B" } == retainedFilter)
            #expect(model.filters.first { $0.scope == "/fixture/A" }?.count == 2)
            print("LOCAL_SCOPE_FANOUT unrelated=\(unrelatedCount) selections=2 applicationCandidates=2 selectedScopeProjections=0")
        }
    }

    @Test(arguments: [false, true])
    func mokuRemovalRetiresOperationsWithoutReprojectingCards(hidden: Bool) async throws {
        try await withFixture(threads: [thread("a"), moku()]) { fixture in
            let model = fixture.model
            #expect(model.operations == [.init(id: "moku-operation", kind: .send, phase: .running, threadID: "a")])
            if hidden { model.setPresentationActive(false) }
            let retainedItems = model.items, projections = model.projectionVisitCount
            let selections = model.membershipSelectionCount

            try await fixture.patch(["threads": patch(removed: ["moku"])])
            #expect(fixture.workspace.catalog.moku == nil && !fixture.workspace.catalog.hasMoku)
            #expect(model.operations.isEmpty)
            #expect(model.items == retainedItems && model.projectionVisitCount == projections)
            #expect(model.membershipSelectionCount == selections)

            try await fixture.patch(["threads": patch(upserts: [
                try moku("replacement-moku", operationID: "replacement-operation").json
            ])])
            #expect(fixture.workspace.catalog.moku?.id == "replacement-moku")
            #expect(model.operations == [.init(id: "replacement-operation", kind: .send, phase: .running, threadID: "a")])
            #expect(model.items == retainedItems && model.projectionVisitCount == projections)
            #expect(model.membershipSelectionCount == selections)
        }
    }

    @Test func creationTimeChangesReorderVisibleOwnersWithStableCatalogSlots() async throws {
        try await withFixture(threads: [thread("a", createdAt: 1), thread("b", createdAt: 2), thread("c", createdAt: 3)],
                              applications: [report("r1", createdAt: 1.5), report("r2", createdAt: 2.5)]) { fixture in
            let model = fixture.model
            model.selectTag(try #require(model.filters.first?.children.first))
            #expect(model.items.map(\.id) == ["a", "r1", "b", "r2", "c"])

            try await fixture.patch(["threads": patch(upserts: [try thread("a", revision: 1, createdAt: 4).json])])
            #expect(fixture.state["threads"]?.catalogValue?.ids == ["a", "b", "c"])
            #expect(model.items.map(\.id) == ["r1", "b", "r2", "c", "a"])
            try await fixture.patch(["applicationThreads": patch(upserts: [report("r2", revision: 1, createdAt: 0.5)])])
            #expect(fixture.state["applicationThreads"]?.catalogValue?.ids == ["r1", "r2"])
            #expect(model.items.map(\.id) == ["r2", "r1", "b", "c", "a"])
            model.selectTag(nil)
            #expect(model.items.map(\.id) == ["r2", "r1", "b", "c", "a"])
        }
    }

    @Test func scopeMovesAndRecreatedOwnersKeepMembershipOrder() async throws {
        try await withFixture(threads: [thread("a1"), thread("b1", scope: "/fixture/B"),
            thread("a2"), thread("b2", scope: "/fixture/B")], applications: [report("ra1"),
            report("rb1", scope: "/fixture/B"), report("ra2"), report("rb2", scope: "/fixture/B")]) { fixture in
            let model = fixture.model
            model.selectTag(try #require(model.filters.first { $0.scope == "/fixture/A" }?.children.first))
            #expect(model.items.map(\.id) == ["a1", "a2", "ra1", "ra2"])

            try await fixture.patch([
                "threads": patch(upserts: [try thread("a1", revision: 1, scope: "/fixture/B").json]),
                "applicationThreads": patch(upserts: [report("ra1", revision: 1, scope: "/fixture/B")])
            ])
            #expect(model.items.map(\.id) == ["a2", "ra2"])
            #expect(model.filters.first { $0.scope == "/fixture/A" }?.count == 2)
            #expect(model.filters.first { $0.scope == "/fixture/B" }?.count == 6)
            model.selectTag(try #require(model.filters.first { $0.scope == "/fixture/B" }?.children.first))
            #expect(model.items.map(\.id) == ["a1", "b1", "b2", "ra1", "rb1", "rb2"])

            try await fixture.patch(["threads": patch(removed: ["b1"]), "applicationThreads": patch(removed: ["rb1"])])
            #expect(model.items.map(\.id) == ["a1", "b2", "ra1", "rb2"])
            try await fixture.patch([
                "threads": patch(upserts: [try thread("b1", scope: "/fixture/B").json]),
                "applicationThreads": patch(upserts: [report("rb1", scope: "/fixture/B")])
            ])
            #expect(model.items.map(\.id) == ["a1", "b2", "b1", "ra1", "rb2", "rb1"])

            // Same-transaction replacement keeps its slot while resetting the
            // first revision fence. A duplicate upsert cannot reset it again.
            try await fixture.patch([
                "threads": patch(upserts: [try thread("b2", title: "Recreated", scope: "/fixture/B").json,
                    try thread("b2", title: "Late duplicate", scope: "/fixture/B").json], removed: ["b2"]),
                "applicationThreads": patch(upserts: [report("rb2", title: "Recreated", scope: "/fixture/B"),
                    report("rb2", title: "Late duplicate", scope: "/fixture/B")], removed: ["rb2"])
            ])
            #expect(fixture.workspace.catalog.thread("b2")?.title == "Recreated")
            let replacedApplications = try #require(fixture.state["applicationThreads"]?.catalogValue)
            #expect(replacedApplications["rb2"]?["title"] == .text("Recreated"))
            #expect(model.items.map(\.id) == ["a1", "b2", "b1", "ra1", "rb2", "rb1"])
            model.selectTag(nil)
            #expect(model.items.map(\.id) == ["a1", "a2", "b2", "b1", "ra1", "ra2", "rb2", "rb1"])
            // Each order detector must force reconciliation independently;
            // updating both collections together could hide a missed reorder.
            try await fixture.patch([
                "threads": patch(upserts: [try thread("b2", title: "Recreated", scope: "/fixture/B").json],
                    removed: ["b2"], order: ["a1", "a2", "b1", "b2"])
            ])
            #expect(model.items.map(\.id) == ["a1", "a2", "b1", "b2", "ra1", "ra2", "rb2", "rb1"])
            try await fixture.patch([
                "applicationThreads": patch(upserts: [report("rb2", title: "Recreated", scope: "/fixture/B")],
                    removed: ["rb2"], order: ["ra1", "ra2", "rb1", "rb2"])
            ])
            #expect(model.items.map(\.id) == ["a1", "a2", "b1", "b2", "ra1", "ra2", "rb1", "rb2"])

            // Changed-ID sets cannot define insertion order for a batch.
            try await fixture.patch([
                "threads": patch(upserts: [try thread("b4", scope: "/fixture/B").json,
                    try thread("b3", scope: "/fixture/B").json]),
                "applicationThreads": patch(upserts: [report("rb4", scope: "/fixture/B"), report("rb3", scope: "/fixture/B")])
            ])
            #expect(model.items.map(\.id) == ["a1", "a2", "b1", "b2", "b4", "b3", "ra1", "ra2", "rb1", "rb2", "rb4", "rb3"])
            model.selectTag(try #require(model.filters.first { $0.scope == "/fixture/B" }?.children.first))
            #expect(model.items.map(\.id) == ["a1", "b1", "b2", "b4", "b3", "ra1", "rb1", "rb2", "rb4", "rb3"])
        }
    }

    @Test func executionReferenceSubscriptionsIgnoreUnrelatedChangesAndCancel() async throws {
        try await withFixture(threads: [thread("a"), thread("b")]) { fixture in
            let host = NativeApplicationHost(workspace: fixture.workspace, navigationCallbacks: .init(
                openThread: { _, _ in }, openExecution: { _ in }, followUp: { _, _ in }, openExternal: { _ in }))
            defer { host.release() }
            let reference = ApplicationExecutionRef(thread: .init(threadID: "a", typeID: "agent"), executionID: "e1")
            let lifetime = PluginLifetime()
            var callbacks = 0
            let unsubscribe = host.subscribeReferences([reference], listener: { callbacks += 1 }, lifetime: lifetime)
            #expect(callbacks == 0)
            try await fixture.patch(["threads": patch(upserts: [try thread("b", revision: 1).json])])
            try await fixture.patch(["activities": activity("a")])
            #expect(callbacks == 0)
            try await fixture.patch(["threads": patch(upserts: [try thread("a", revision: 1).json])])
            #expect(callbacks == 1)
            lifetime.cancel()
            try await fixture.patch(["threads": patch(upserts: [try thread("a", revision: 2).json])])
            #expect(callbacks == 1)
            unsubscribe(); unsubscribe()

            let secondLifetime = PluginLifetime()
            let stop = host.subscribeReferences([reference], listener: { callbacks += 1 }, lifetime: secondLifetime)
            stop(); stop()
            try await fixture.patch(["threads": patch(upserts: [try thread("a", revision: 3).json])])
            #expect(callbacks == 1)
            secondLifetime.cancel()
        }
    }

    private func withFixture(threads: [HarnessThread], applications: [JSONValue] = [],
                             _ run: @MainActor (NativeLocalChangeFixture) async throws -> Void) async throws {
        let fixture = try NativeLocalChangeFixture(threads: threads, applications: applications)
        do { try await fixture.start(); try await run(fixture) }
        catch { await fixture.close(); throw error }
        await fixture.close()
    }

    private func thread(_ id: JSONText, title: JSONText = "Initial", revision: Int = 0,
                        execution: JSONText = "e1", scope: JSONText = "/fixture/A", createdAt: Double = 1) throws -> HarnessThread {
        try .init(id: id, harnessID: "codex", revision: revision, sessionState: .null,
            observation: .init(latestExecution: try .init(executionID: execution, status: .running, startedAt: 1)),
            cwd: scope, settings: .object([:]), createdAt: createdAt, updatedAt: max(createdAt, Double(revision + 2)),
            title: title, tags: ["Shared"], archived: false, tagEmojis: ["Shared": "🔧"],
            directoryTag: "Project", directoryScope: scope)
    }

    private func moku(_ id: JSONText = "moku", operationID: JSONText = "moku-operation") throws -> HarnessThread {
        let operation: JSONValue = .object(["type": .text("tool-operation"), "id": .string(operationID),
            "executionId": .text("moku-execution"), "name": .text("send_to_thread"),
            "arguments": .object(["threadId": .text("a"), "prompt": .text("Continue")])])
        return try .init(id: id, harnessID: "codex", revision: 0, sessionState: .null,
            observation: .init(latestExecution: try .init(executionID: "moku-execution", status: .running, startedAt: 1)),
            cwd: "/fixture/A", settings: .object([:]), createdAt: 0, updatedAt: 2,
            title: "Moku", tags: [], moku: true, transcript: .array([operation]))
    }

    private func report(_ id: String, title: String = "Report", introduction: String = "Report introduction",
                        revision: Int = 0, scope: String = "/fixture/A", createdAt: Double = 2,
                        covers: [ApplicationExecutionRef] = []) -> JSONValue {
        .object(["id": .text(id), "ref": ApplicationThreadRef(threadID: JSONText(id), typeID: "report.document").json,
            "revision": .integer(revision), "createdAt": .number(createdAt), "updatedAt": .number(max(createdAt, Double(revision + 2))),
            "title": .text(title), "scope": .text(scope), "archived": .bool(false),
            "tags": .object(["tags": .array([.text("Project"), .text("Shared")]),
                "semanticTags": .array([.text("Shared")]), "directoryTags": .array([.text("Project")]),
                "tagEmojis": .object(["Shared": .text("🔧")])]),
            "presentations": .array([.object(["id": .text("mokusei.overview"), "apiVersion": .integer(1), "schemaVersion": .integer(1),
                "value": .object(["visible": .bool(true), "coversExecutions": .array(covers.map {
                    .object(["thread": $0.thread.json, "executionId": .string($0.executionID)])
                })])])]),
            "view": .object(["coverRevision": .text(""), "emoji": .text("📊"), "shortDescription": .text(introduction),
                "previewText": .text(title), "contentRevision": .text(Data((title + "\u{0}" + introduction).utf8).base64EncodedString()), "relatedExecutions": .array([])])])
    }

    private func patch(upserts: [JSONValue] = [], removed: [JSONText] = [], order: [JSONText]? = nil) -> JSONValue {
        var fields: [JSONText: JSONValue] = ["upserts": .array(upserts), "removedIds": .array(removed.map(JSONValue.string))]
        if let order { fields["order"] = .array(order.map(JSONValue.string)) }
        return .object(fields)
    }

    private func activity(_ id: JSONText) -> JSONValue {
        .array([.object(["threadId": .string(id), "harnessId": .text("codex"), "activity": .object([
            "executionId": .text("e1"), "sequence": .integer(1), "kind": .text("text"), "text": .text("Streaming")])])])
    }
}

@MainActor
private final class NativeLocalChangeFixture {
    let directory: URL
    let authority = UUID()
    let model: NativeOverviewWorkspaceModel
    var state: JSONValue
    var workspace: NativeWorkspaceModel { model.workspace }

    init(threads: [HarnessThread], applications: [JSONValue]) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let workspace = NativeWorkspaceModel(client: RuntimeClient(profile: try RuntimeProfile(dataDirectory: directory)),
            preferences: DesktopPreferences(directory: directory), plugins: try .init(
                harnesses: [AnyHarnessPlugin(CodexHarnessPlugin())], sidecards: [], applications: NativeApplicationModules.make()))
        model = .init(workspace: workspace, applications: .init(projectionCapabilities: { plugin, entry in
            try .init(scope: .init(pluginID: plugin.ownerPluginID, thread: entry.ref), requires: plugin.requires, registrations: [])
        }, rendererContext: { _, _, _ in throw CancellationError() }))
        state = try RuntimeState.admittingSnapshot(.object(["revision": .integer(0), "settingsRevision": .integer(0),
            "defaultCwd": .text("/fixture"), "settings": .object([:]), "threads": .array(threads.map(\.json)),
            "executions": .array([]), "applicationThreads": .array(applications)]))
    }

    func start() async throws { try await deliver(.snapshot(state, authority: authority)) }

    func patch(_ changes: [JSONText: JSONValue]) async throws {
        let revision = try #require(state["revision"]?.intValue)
        var fields = changes
        fields["type"] = .text("state-patched")
        fields["baseRevision"] = .integer(revision)
        fields["revision"] = .integer(revision + 1)
        let mutation = JSONValue.object(fields)
        state = try RuntimeState.applying(mutation, to: state)
        try await deliver(.mutation(mutation, state: state, authority: authority))
    }

    private func deliver(_ event: RuntimeClientEvent) async throws {
        await workspace.installPrepared(state, event: event)
        try #require(workspace.connectionError == nil)
        model.receive(event)
        try #require(model.error == nil)
        #expect(workspace.catalog.revision == state["revision"]?.intValue)
    }

    func close() async {
        await model.stop()
        await workspace.client.close()
        model.canvasState.camera.dispose()
        try? FileManager.default.removeItem(at: directory)
    }
}
