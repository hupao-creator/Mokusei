import AppKit
import Foundation
import Observation
import SwiftUI
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

    @Test(.requiresDisplay)
    func mountedContentUpdatesAvoidCanvasInvalidationAndRetainLatestExitSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try model(directory), authority = UUID()
        var threads = try (0..<10).map { index in
            try thread(JSONText("mounted-\(index)"), title: JSONText("Mounted initial \(index)"), status: .completed)
        }
        try deliver(threads, to: model, authority: authority)
        let window = SwiftUIReplay.window(NativeOverviewWorkspaceView(model: model,
            callbacks: .init(openThread: { _, _ in }, openApplication: { _, _ in }, onSettings: {})))
        defer { window.close(); model.canvasState.camera.dispose() }
        let root = try #require(window.contentView)
        try await SwiftUIReplay.wait {
            !model.canvasState.isLayingOut && !model.canvasState.camera.isAnimating && model.canvasState.mountedCardIDs.count == 10
                && SwiftUIReplay.text(in: root).contains("Mounted initial 0")
        }
        try await Task.sleep(for: .milliseconds(800))
        let updates = model.canvasState.bodyEvaluationCount
        let solves = model.canvasState.layoutSolveCount
        for revision in 1...3 {
            threads[0] = try thread("mounted-0", title: JSONText("Mounted latest \(revision)"), revision: revision, status: .completed)
            try deliver(threads, to: model, authority: authority)
            try await SwiftUIReplay.wait { SwiftUIReplay.text(in: root).contains("Mounted latest \(revision)") }
            #expect(model.canvasState.bodyEvaluationCount == updates)
            #expect(model.canvasState.layoutSolveCount == solves)
        }
        let exiting = try #require(model.items.first { $0.id == "mounted-0" })
        let stage = try await model.canvasState.motionStages.acquire(owner: "retain-latest-exit")
        defer { stage.release() }
        threads.removeFirst()
        try deliver(threads, to: model, authority: authority)
        // The model prunes synchronously, before SwiftUI can start the exit.
        // The mounted slot, rather than the oldest rendered array, pins this.
        #expect(model.snapshot(for: exiting) != nil)
        try await SwiftUIReplay.wait { model.canvasState.isLayingOut }
        #expect(SwiftUIReplay.text(in: root).contains("Mounted latest 3"))
        stage.release()
        try await SwiftUIReplay.wait {
            !model.canvasState.isLayingOut && !model.canvasState.mountedCardIDs.contains(exiting.id)
        }
        #expect(model.snapshot(for: exiting) == nil)
        await model.stop(); await model.workspace.client.close()
    }

    @Test func availabilityObservesPresenceAndNotCatalogPayloads() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try model(directory), workspace = model.workspace, authority = UUID()
        func snapshot(_ revision: Int, includeMoku: Bool, title: String) throws -> JSONValue {
            var moku = try thread("moku", title: JSONText(title), revision: revision, status: .completed).json.objectValue!
            moku.removeValue(forKey: "archived")
            moku["moku"] = .bool(true); moku["transcript"] = .array([])
            return .object(["revision": .integer(revision), "settingsRevision": .integer(0),
                "defaultCwd": .text("/fixture"), "settings": .object([:]),
                "threads": .array(includeMoku ? [.object(moku)] : []),
                "executions": .array([]), "applicationThreads": .array([])])
        }
        #expect(!workspace.hasInitialContent && !workspace.catalog.hasMoku)
        let first = try snapshot(0, includeMoku: true, title: "Initial")
        await workspace.installPrepared(first, event: .snapshot(first, authority: authority))
        #expect(workspace.hasInitialContent && workspace.catalog.hasMoku)
        let changes = OverviewAvailabilityChanges()
        withObservationTracking {
            _ = workspace.hasInitialContent
            _ = workspace.catalog.hasMoku
        } onChange: {
            MainActor.assumeIsolated { changes.count += 1 }
        }
        let updated = try snapshot(1, includeMoku: true, title: "Unrelated payload update")
        await workspace.installPrepared(updated, event: .mutation(.object([:]), state: updated, authority: authority))
        #expect(changes.count == 0 && workspace.hasInitialContent && workspace.catalog.hasMoku)
        // A direct catalog installation must have the same availability
        // semantics as the asynchronous workspace installation boundary.
        try workspace.catalog.install(snapshot(2, includeMoku: false, title: "Absent"))
        #expect(changes.count == 1 && !workspace.hasInitialContent && !workspace.catalog.hasMoku)
        try workspace.catalog.install(snapshot(3, includeMoku: true, title: "Restored"))
        #expect(workspace.hasInitialContent && workspace.catalog.hasMoku)
        await model.stop(); await workspace.client.close()
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


@MainActor private final class OverviewAvailabilityChanges { var count = 0 }
