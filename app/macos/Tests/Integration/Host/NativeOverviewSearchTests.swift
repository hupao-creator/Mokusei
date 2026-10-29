import AppKit
import SwiftUI
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
@testable import MokuseiUI

@MainActor private final class SearchTagGeometry {
    var bounds: [String: CGRect] = [:]
    var size = CGSize.zero
}

/// In-memory public catalog and real production model/chrome/canvas. No runtime
/// is started, no provider is loaded and no user preferences/history are read.
@MainActor private struct SearchHarnessFixture: HarnessPlugin {
    let descriptor = HarnessPluginDescriptor(id: "fixture", displayName: "Fixture",
        threadCapabilities: .init(instructions: false, threadContext: false, sendContext: false, toolModes: []))
    let logoSource = ""
    var threadSettingsCodec: PluginValueCodec<JSONValue> { .json }
    var harnessSettingsCodec: PluginValueCodec<JSONValue> { .json }
    var settingsPresentationCodec: PluginValueCodec<JSONValue> { .json }
    func logo(size: CGFloat) -> some View { Text("F") }
    func projectOverview(input: HarnessThreadInput, availableColumns: Int) throws -> HarnessOverviewProjection<String> {
        .init(footprint: .init(columns: 1, rows: 1), structureKey: "fixture", excerpt: "", view: input.thread.title.string)
    }
    func threadView(input: HarnessThreadInput, actions: HarnessThreadActions, context: HarnessRenderContext) -> some View { EmptyView() }
    func overviewCard(input: HarnessThreadInput, projection: String, actions: HarnessThreadActions,
                      openThread: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(projection).font(.system(size: 18, weight: .semibold))
            Text(input.thread.cwd.string).font(.system(size: 12)).foregroundStyle(.secondary)
            Text(input.thread.tags.map(\.string).joined(separator: " · ")).font(.system(size: 12))
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    func threadSettings(input: HarnessThreadInput, resource: HarnessSettingsResource<JSONValue>,
                        update: @escaping (JSONValue) async throws -> Void) -> some View { EmptyView() }
    func harnessSettings(props: HarnessSettingsProps<JSONValue, JSONValue>) -> some View { EmptyView() }
}

@MainActor @Suite(.serializedNative, .serialized)
struct NativeOverviewSearchTests {
    private func thread(_ id: String, title: String = "修复 Glass Focus", tags: [JSONText] = ["界面设计"],
                        revision: Int = 0, archived: Bool = false, status: PublicExecution.Status? = nil,
                        cwd: String = "/workspace/项目/Café") throws -> HarnessThread {
        try HarnessThread(id: JSONText(id), harnessID: "fixture", revision: revision,
            sessionState: .object(["privateBody": .text("secret-body-needle")]),
            observation: .init(latestExecution: try status.map {
                try PublicExecution(executionID: "execution", status: $0, startedAt: 1,
                    finishedAt: $0 == .running || $0 == .waitingForUser ? nil : 2,
                    interactions: $0 == .waitingForUser ? [.init(id: "permission", kind: .permission, title: "Allow?",
                        actions: [.init(id: "allow", intent: .allow, label: "Allow")], questions: [])] : [])
            }), cwd: JSONText(cwd), settings: .object([:]), createdAt: 1, updatedAt: 2,
            title: JSONText(title), tags: tags, archived: archived,
            tagEmojis: Dictionary(uniqueKeysWithValues: tags.map { ($0, JSONText("🔧")) }))
    }
    private func application(archived: Bool = false, directoryOnly: Bool = false,
                             covers: [JSONValue] = []) throws -> NativeOverviewApplicationEntry {
        try .init(json: .object([
            "ref": ApplicationThreadRef(threadID: "report", typeID: "report").json, "revision": .integer(0),
            "createdAt": .number(1), "updatedAt": .number(2), "title": .text("中文 Release Plan"), "archived": .bool(archived),
            "tags": .object(["tags": .array([.text("Shared"), .text("Café")]),
                             "semanticTags": .array([.text("Shared")]), "tagEmojis": .object(["Shared": .text("🔧")]), "directoryTags": .array([.text("Café")])]),
            "presentations": .array([.object(["id": .text("mokusei.overview"), "apiVersion": .integer(1), "schemaVersion": .integer(1),
                "value": .object(["coversExecutions": .array(covers), "tagFilter": directoryOnly ? .text("directory") : .null].filter { $0.value != .null })])]),
            "view": .object(["privateBody": .text("secret-body-needle")])]))
    }
    private func install(_ threads: [HarnessThread], in workspace: NativeWorkspaceModel) throws {
        try workspace.catalog.install(.object(["revision": .integer(workspace.catalog.revision + 1),
            "settingsRevision": .integer(0), "defaultCwd": .text("/workspace/fixture"), "settings": .object([:]),
            "threads": .array(threads.map(\.json)), "executions": .array([]), "applicationThreads": .array([])]))
    }
    private func workspace(_ directory: URL) throws -> NativeWorkspaceModel {
        NativeWorkspaceModel(client: RuntimeClient(profile: try RuntimeProfile(dataDirectory: directory)),
            preferences: DesktopPreferences(directory: directory),
            plugins: try .init(harnesses: [AnyHarnessPlugin(SearchHarnessFixture())], sidecards: [], applications: []))
    }
    private func model(_ workspace: NativeWorkspaceModel,
                       searchRequest: ((JSONValue) async throws -> JSONValue)? = nil) -> NativeOverviewWorkspaceModel {
        .init(workspace: workspace, applications: .init(projectionCapabilities: { _, _ in throw CancellationError() },
                                                       rendererContext: { _, _, _ in throw CancellationError() }), searchRequest: searchRequest)
    }


    private func wait(sourceLocation: SourceLocation = #_sourceLocation, _ predicate: () -> Bool) async throws {
        for _ in 0..<300 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Search fixture did not settle", sourceLocation: sourceLocation)
        throw CancellationError()
    }


    @Test func publicMetadataTermsAndExistingVisibilityContract() throws {
        let threads = try [thread("visible"), thread("archived", archived: true), thread("failed", status: .failed),
                           thread("interrupted", status: .interrupted), thread("running", status: .running)]
        let collection = NativeOverviewSelection.select(threads: threads, applications: [try application()])
        #expect(NativeOverviewSearch("  GLASS\n修复 cafe  ").filter(collection).threads.map(\.id) == ["visible", "running"])
        #expect(NativeOverviewSearch("项目").filter(collection).threads.count == 2)
        #expect(NativeOverviewSearch("界面").filter(collection).threads.count == 2)
        #expect(NativeOverviewSearch("ＣＡＦＥ").filter(collection).threads.count == 2)
        #expect(NativeOverviewSearch("中文 shared").filter(collection).applications.count == 1)
        #expect(NativeOverviewSearch("  \n\u{3000}").filter(collection).count == collection.count)
        #expect(NativeOverviewSearch("secret-body-needle").filter(collection).count == 0)
        #expect(NativeOverviewSearch("unknown").filter(collection).count == 0)
        #expect(NativeOverviewSearch("a\" OR *").filter(collection).count == 0)
        let archive = NativeOverviewSelection.select(threads: [], applications: [try application(archived: true)])
        #expect(NativeOverviewSearch("Release").filter(archive).count == 0)
        let directory = try application(directoryOnly: true)
        #expect(NativeOverviewSearch("Release").filter(NativeOverviewSelection.select(threads: [], applications: [directory])).count == 0)
        #expect(NativeOverviewSearch("Release").filter(NativeOverviewSelection.select(threads: [], applications: [directory], tags: ["Café"], kind: .directory)).count == 1)
        let covered = try application(covers: [.object(["thread": ApplicationThreadRef(threadID: "running", typeID: "agent").json, "executionId": .text("execution")])])
        let merged = NativeOverviewSelection.select(threads: threads, applications: [covered])
        #expect(NativeOverviewSearch("Glass").filter(merged).threads.map(\.id) == ["visible"])
    }

    @Test func searchUsesCachedDirectoryTagWithoutWalkingTheFileSystem() throws {
        let threads = try [thread("cached")]
        let collection = NativeOverviewSelection.select(threads: threads, applications: [])
        #expect(NativeOverviewSearch("CachedOnly").filter(collection).count == 0)
        let cache = [threads[0].cwd: "CachedOnly"]
        #expect(NativeOverviewSearch("CachedOnly").filter(collection, directoryTags: cache).count == 1)
    }

    @Test func modelSearchIntersectsTagAndReconcilesLatestCatalogWithoutStaleResults() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = try workspace(directory), model = model(workspace)
        let all = try [thread("a"), thread("b", title: "Other title", tags: ["Other"]), thread("c", title: "Stable member")]
        try install(all, in: workspace)
        model.refresh()
        let filter = try #require(model.filters.withChildren.first { $0.matches("界面设计") })
        model.selectTag(filter)
        let selected = model.tagSelection
        let browseScene = model.sceneKey
        model.beginSearch()
        #expect(model.sceneKey == browseScene)
        model.updateSearch("Other")
        #expect(model.items.isEmpty && model.tagSelection == selected)
        model.updateSearch("glass")
        #expect(model.items.map(\.id) == ["a"])
        let previousScene = model.sceneKey
        model.updateSearch("impossible")
        model.updateSearch("glass")
        #expect(model.sceneKey == previousScene && model.items.map(\.id) == ["a"])
        try install([thread("a", title: "Renamed")], in: workspace)
        model.refresh()
        #expect(model.items.isEmpty)
        model.updateSearch("")
        #expect(!model.sceneKey.contains("\u{0}search:"))
        #expect(model.items.map(\.id) == ["a"])
        try install([], in: workspace)
        model.refresh()
        #expect(model.items.isEmpty && model.tagSelection == nil && model.selectedTag.isEmpty)
        model.endSearch()
        #expect(!model.isSearching && model.searchQuery.isEmpty)
        model.updateSearch("late edit")
        #expect(model.searchQuery.isEmpty)
        try install(all, in: workspace)
        model.refresh()
        #expect(model.tagSelection == nil && model.items.map(\.id) == ["a", "b", "c"])
        let restoredFilter = try #require(model.visibleFilters.withChildren.first { $0.matches("界面设计") && $0.count > 0 })
        model.selectTag(restoredFilter)
        #expect(model.tagSelection == selected && model.items.map(\.id) == ["a", "c"])
        model.beginSearch(); model.requestFilterFocus()
        #expect(!model.isSearching && model.focusFilterRequestKey > 0)
    }

    @Test func morphUsesOnlyVisibleTagsAndKeepsTheCarrierAndContentsInsideTheViewport() throws {
        let filters: [NativeOverviewFilter] = [.init(tag: "Visible", count: 3), .init(tag: "Offscreen", count: 2)]
        let bounds: [String: CGRect] = [
            "__bar__": .init(x: 14, y: 60, width: 332, height: 44),
            "__all__": .init(x: 20, y: 66, width: 52, height: 32),
            "__scroll__": .init(x: 76, y: 66, width: 264, height: 32),
            filters[0].id: .init(x: 40, y: 66, width: 130, height: 32),
            filters[1].id: .init(x: 360, y: 66, width: 130, height: 32)]
        let sources = OverviewSearchMorphGeometry.sources(bounds: bounds, filters: filters,
            all: "全部", selectedTag: "Visible", selectedKind: nil)
        #expect(sources.map(\.id) == ["__all__", filters[0].id])
        #expect(sources[1].frame.minX == 76 && sources[1].labelFrame.minX == 40)
        let target = CGRect(x: 14, y: 60, width: 332, height: 44)
        let first = try #require(OverviewSearchMorphGeometry.carrier(in: sources)).frame
        #expect(OverviewSearchMorphGeometry.frame(source: first, target: target, progress: 0) == first)
        #expect(OverviewSearchMorphGeometry.frame(source: first, target: target, progress: 1) == target)
        for progress in stride(from: CGFloat(0), through: 1, by: 0.02) {
            let rect = OverviewSearchMorphGeometry.frame(source: first, target: target, progress: progress)
            #expect(rect.minX >= 0 && rect.maxX <= 360 && rect.minY >= 60 && rect.maxY <= 104)
        }
    }

    @Test func selectedTagExpandsWhileNeighborsMoveAsideAndFadeWithoutShrinking() throws {
        let filters: [NativeOverviewFilter] = [.init(tag: "Left", count: 1), .init(tag: "Selected", count: 2), .init(tag: "Right", count: 3)]
        let bounds: [String: CGRect] = [
            "__bar__": .init(x: 0, y: 0, width: 460, height: 40),
            "__all__": .init(x: 10, y: 4, width: 52, height: 32),
            "__scroll__": .init(x: 70, y: 4, width: 380, height: 32),
            filters[0].id: .init(x: 76, y: 4, width: 80, height: 32),
            filters[1].id: .init(x: 164, y: 4, width: 110, height: 32),
            filters[2].id: .init(x: 282, y: 4, width: 100, height: 32)]
        let sources = OverviewSearchMorphGeometry.sources(bounds: bounds, filters: filters,
            all: "All", selectedTag: "Selected", selectedKind: nil)
        let selected = try #require(OverviewSearchMorphGeometry.carrier(in: sources))
        #expect(selected.id == filters[1].id)
        let target = CGRect(x: 0, y: 4, width: 460, height: 32)
        #expect(OverviewSearchMorphGeometry.frame(source: selected.frame, target: target, progress: 0) == selected.frame)
        #expect(OverviewSearchMorphGeometry.frame(source: selected.frame, target: target, progress: 1) == target)
        for neighbor in sources where neighbor.id != selected.id {
            var previous = neighbor.frame
            for progress in stride(from: CGFloat(0), through: 1, by: 0.05) {
                let rect = OverviewSearchMorphGeometry.displacedFrame(source: neighbor.frame,
                    origin: selected.frame, target: target, progress: progress)
                #expect(rect.size == neighbor.frame.size && rect.minY == neighbor.frame.minY)
                #expect(neighbor.frame.midX < selected.frame.midX ? rect.minX <= previous.minX : rect.minX >= previous.minX)
                previous = rect
            }
            #expect(neighbor.frame.midX < selected.frame.midX ? previous.maxX < target.minX : previous.minX > target.maxX)
            #expect(OverviewSearchMorphGeometry.displacedFrame(source: neighbor.frame,
                origin: selected.frame, target: target, progress: 0) == neighbor.frame)
        }
        #expect(OverviewSearchMorphGeometry.neighborOpacity(progress: 0) == 1)
        #expect(OverviewSearchMorphGeometry.neighborOpacity(progress: 0.4) > 0)
        #expect(OverviewSearchMorphGeometry.neighborOpacity(progress: 0.75) == 0)
        #expect(OverviewSearchMorphGeometry.neighborOpacity(progress: 1) == 0)
        let offscreen = OverviewSearchMorphGeometry.sources(bounds: bounds, filters: filters,
            all: "All", selectedTag: "Offscreen", selectedKind: nil)
        #expect(OverviewSearchMorphGeometry.carrier(in: offscreen)?.id == "__all__")
        #expect(OverviewSearchMorphGeometry.carrier(in: Array(offscreen.dropFirst()))?.id == filters[0].id)
        #expect(OverviewSearchMorphGeometry.carrier(in: []) == nil)
    }

    @Test func activeKeywordSearchRefreshesAfterAutomaticPreparation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = try workspace(directory)
        try install([thread("a", title: "First")], in: workspace)
        var calls = 0
        let model = model(workspace, searchRequest: { _ in
            calls += 1
            if calls == 1 {
                return .object(["mode": .text("keyword"), "reason": .text("model-missing"), "hits": .array([])])
            }
            return .object(["mode": .text("hybrid"), "hits": .array([.object([
                "ref": ApplicationThreadRef(threadID: "a", typeID: "agent").json
            ])])])
        })
        defer { model.endSearch() }
        model.refresh(); model.beginSearch(); model.updateSearch("maintenance")
        try await wait { calls == 1 && model.searchReason == "model-missing" }
        #expect(model.items.isEmpty)
        try await Task.sleep(for: .seconds(3))
        try await wait { model.searchMode == "hybrid" && model.items.map(\.id) == ["a"] }
        #expect(calls == 2)
    }









    private func capture(_ window: NSWindow, name: String) async throws {
        // Animation assertions need a committed initial frame even when no
        // screenshot is requested. Keep rendering independent of evidence IO.
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        guard let path = ProcessInfo.processInfo.environment["MOKUSEI_OVERVIEW_SEARCH_EVIDENCE"] else { return }
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        // WindowServer may not have published a newly resized hosting view yet.
        // Capture only this fixture window, with bounded compositor retries.
        for attempt in 0..<3 {
            if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
            window.orderFrontRegardless()
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(attempt == 0 ? 200 : 250))
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-o", "-l", String(window.windowNumber), path + "/" + name + ".png"]
            try process.run(); process.waitUntilExit()
            if process.terminationStatus == 0,
               let bitmap = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: path + "/" + name + ".png"))),
               bitmap.pixelsWide >= Int(window.frame.width * window.backingScaleFactor * 0.95),
               bitmap.pixelsHigh >= Int(window.frame.height * window.backingScaleFactor * 0.95) { return }
        }
        Issue.record("Window-only fixture screenshot failed: \(name), window \(window.windowNumber)")
    }


    @Test func hybridQueriesKeepTagScopeAndRejectCancelledOrLateResponses() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = try workspace(directory)
        try install([thread("a", title: "First"), thread("b", title: "Second")], in: workspace)
        var pending: [(JSONValue, CheckedContinuation<JSONValue, Error>)] = []
        let model = model(workspace, searchRequest: { request in
            try await withCheckedThrowingContinuation { continuation in pending.append((request, continuation)) }
        })
        func response(_ id: String) -> JSONValue {
            .object(["mode": .text("hybrid"), "hits": .array([.object([
                "ref": ApplicationThreadRef(threadID: JSONText(id), typeID: "agent").json, "score": .number(0.9)
            ])])])
        }
        model.refresh(); model.beginSearch(); model.updateSearch("alpha")
        try await wait { pending.count == 1 }
        #expect(pending[0].0["threads"]?.arrayValue?.count == 2)
        #expect(pending[0].0["keywordMatches"]?.arrayValue?.isEmpty == true)
        model.updateSearch("beta")
        try await wait { pending.count == 2 }
        pending[1].1.resume(returning: response("b"))
        try await wait { model.items.map(\.id) == ["b"] }
        pending[0].1.resume(returning: response("a"))
        try await Task.sleep(for: .milliseconds(30))
        #expect(model.items.map(\.id) == ["b"] && model.searchMode == "hybrid" && model.searchRank(for: "b") == 0)
        model.updateSearch("gamma")
        try await wait { pending.count == 3 }
        model.endSearch()
        pending[2].1.resume(returning: response("a"))
        try await Task.sleep(for: .milliseconds(30))
        #expect(!model.isSearching && model.items.count == 2 && model.searchMode == "keyword")
    }

    @Test func liveRevisionsAndRefreshesKeepCommittedSemanticCards() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = try workspace(directory)
        try install([thread("a", title: "First"), thread("b", title: "Second")], in: workspace)
        var pending: [CheckedContinuation<JSONValue, Error>] = []
        let model = model(workspace, searchRequest: { _ in
            try await withCheckedThrowingContinuation { pending.append($0) }
        })
        defer { model.endSearch() }
        func response(_ id: String) -> JSONValue {
            .object(["mode": .text("hybrid"), "hits": .array([.object([
                "ref": ApplicationThreadRef(threadID: JSONText(id), typeID: "agent").json
            ])])])
        }
        model.refresh(); model.beginSearch(); model.updateSearch("maintenance")
        try await wait { pending.count == 1 }
        pending[0].resume(returning: response("a"))
        try await wait { model.items.map(\.id) == ["a"] }
        for revision in 1...4 {
            try install([thread("a", title: "First", revision: revision), thread("b", title: "Second")], in: workspace)
            model.refresh()
            #expect(model.items.map(\.id) == ["a"] && model.searchRank(for: "a") == 0)
        }
        model.beginSearch() // Focusing an existing query must preserve results too.
        try await Task.sleep(for: .milliseconds(400))
        #expect(pending.count == 1 && model.searchMode == "hybrid")
        // A keyword membership change needs a new request, but keeps the
        // committed semantic result visible until the replacement arrives.
        try install([thread("a", title: "First", revision: 5), thread("b", title: "maintenance")], in: workspace)
        model.refresh()
        #expect(model.items.map(\.id) == ["a", "b"] && model.searchRank(for: "a") == 0)
        try await wait { pending.count == 2 }
        pending[1].resume(throwing: RuntimeError("UNAVAILABLE", "Fixture unavailable"))
        try await wait { model.searchReason == "local-unavailable" }
        #expect(model.items.map(\.id) == ["a", "b"] && model.searchMode == "hybrid")
        // Deleted members must disappear immediately despite retained ranks.
        try install([thread("b", title: "maintenance")], in: workspace)
        model.refresh()
        #expect(model.items.map(\.id) == ["b"])
        model.updateSearch("different")
        #expect(model.items.isEmpty && model.searchRank(for: "a") == nil)
    }

    @Test func activeHybridSearchRefreshesAfterIndexUpdatesWithoutCatalogChanges() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = try workspace(directory)
        try install([thread("a", title: "First"), thread("b", title: "Second")], in: workspace)
        var calls = 0
        let model = model(workspace, searchRequest: { _ in
            calls += 1
            return .object(["mode": .text("hybrid"), "indexing": .bool(false), "hits": .array([.object([
                "ref": ApplicationThreadRef(threadID: calls == 1 ? "a" : "b", typeID: "agent").json, "score": .number(0.9)
            ])])])
        })
        defer { model.endSearch() }
        model.refresh(); model.beginSearch(); model.updateSearch("maintenance")
        try await wait { model.items.map(\.id) == ["a"] }
        // The runtime can finish an automatic index update without changing
        // any catalog source revision. The active query must still see it.
        try await Task.sleep(for: .seconds(3))
        try await wait { model.items.map(\.id) == ["b"] }
        #expect(calls == 2)
    }

    @Test(.requiresDisplay, .enabled(if: ProcessInfo.processInfo.environment["MOKUSEI_OVERVIEW_SEARCH_NATIVE_REPLAY"] == "1", "Requires the native search replay: python3 tools/verification/reading-presentation/run.py --overview-search"))
    func nativeSelectedTagSearchTransitionAndInterruptedReturn() async throws {
        _ = NSApplication.shared
        NSApp.activate(ignoringOtherApps: true)
        NativeTypography.registerFonts()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = try workspace(directory)
        // Inbox tags stay top-level so this replay can anchor the selected chip.
        let inboxCwd = "/tmp/mokusei-overview-search-replay"
        // Distinct membership prevents canonical filters from merging these
        // tags into aliases, leaving visible neighbors on both sides.
        try install([thread("left", tags: ["Alpha"], cwd: inboxCwd), thread("a", tags: ["Selected"], cwd: inboxCwd),
                     thread("right", tags: ["Zulu"], cwd: inboxCwd)], in: workspace)
        let model = model(workspace)
        model.refresh()
        let selected = try #require(model.visibleFilters.withChildren.first { $0.matches("Selected") })
        #expect(selected.tag == "Selected" && model.visibleFilters.withChildren.filter { !$0.isDirectory }.count == 3)
        model.selectTag(selected)
        let window = NSWindow(contentRect: .init(x: 40, y: 40, width: 1100, height: 480),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.animationBehavior = .none; window.isReleasedWhenClosed = false
        window.title = "Selected tag search · Synthetic fixture"
        defer { model.endSearch(); window.close() }
        for dark in [false, true] {
            for width in [1100, 540, 360] {
                let name = "selected-tag-\(width)-\(dark ? "dark" : "light")"
                let geometry = SearchTagGeometry()
                window.contentView = NSHostingView(rootView: NativeOverviewWorkspaceView(model: model,
                    callbacks: .init(openThread: { _, _ in }, openApplication: { _, _ in }, onSettings: {}))
                    .environment(\.overviewSearchMorphDuration, 1.6).preferredColorScheme(dark ? .dark : .light)
                    // Keep the component's logical viewport exact when AppKit constrains
                    // the host window to a smaller CI display.
                    .frame(width: CGFloat(width), height: 480)
                    .overlayPreferenceValue(OverviewSearchTagBounds.self) { anchors in
                        GeometryReader { reader in
                            Color.clear.onChange(of: anchors.mapValues { reader[$0] }, initial: true) { _, bounds in
                                geometry.bounds = bounds
                                geometry.size = reader.size
                            }
                        }.allowsHitTesting(false)
                    })
                window.setContentSize(.init(width: width, height: 480))
                window.makeKeyAndOrderFront(nil)
                try await Task.sleep(for: .milliseconds(300))
                try await capture(window, name: name + "-tags")
                #expect(geometry.size == CGSize(width: width, height: 480))
                let selectedFrame = try #require(geometry.bounds[selected.id])
                #expect(geometry.bounds["__all__"] != nil && geometry.bounds["__scroll__"] != nil)
                model.beginSearch()
                try await Task.sleep(for: .milliseconds(250))
                try await capture(window, name: name + "-opening")
                let carrier = try #require(geometry.bounds["__search_carrier__"])
                let targetWidth = min(CGFloat(460), CGFloat(width) - (width <= 620 ? 28 : 336))
                let target = CGRect(x: (CGFloat(width) - targetWidth) / 2, y: selectedFrame.minY,
                                    width: targetWidth, height: OverviewTagMetrics.buttonHeight)
                let sources = OverviewSearchMorphGeometry.sources(bounds: geometry.bounds, filters: model.visibleFilters,
                    all: "全部", selectedTag: model.selectedTag, selectedScope: model.selectedScope,
                    selectedKind: model.selectedFilter?.isDirectory == true ? .directory : .semantic)
                let origin = try #require(OverviewSearchMorphGeometry.carrier(in: sources)).frame
                #expect(sources.contains { $0.id == selected.id } && origin.intersects(selectedFrame))
                let progress = (carrier.width - origin.width) / (target.width - origin.width)
                #expect(progress > 0 && progress < 1)
                let expected = OverviewSearchMorphGeometry.frame(source: origin, target: target, progress: progress)
                #expect(abs(carrier.minX - expected.minX) < 2)
                for source in sources where source.id != selected.id {
                    let neighbor = try #require(geometry.bounds["__search_neighbor__\(source.id)"])
                    #expect(abs(neighbor.width - source.frame.width) < 1)
                    #expect(source.frame.midX < origin.midX ? neighbor.minX < source.frame.minX : neighbor.minX > source.frame.minX)
                }
                try await Task.sleep(for: .milliseconds(1400))
                #expect(model.isSearching && model.selectedTag == "Selected" && model.items.map(\.id) == ["a"])
                #expect(SwiftUIReplay.editor(in: try #require(window.contentView)) != nil)
                try await capture(window, name: name + "-search")
                // Reverse an incomplete close, then finish closing. The real
                // Chrome must cancel its stale closing task and retain scope.
                model.endSearch()
                try await Task.sleep(for: .milliseconds(100))
                model.beginSearch()
                try await Task.sleep(for: .milliseconds(1700))
                #expect(model.isSearching && model.selectedTag == "Selected")
                #expect(SwiftUIReplay.editor(in: try #require(window.contentView)) != nil)
                try await capture(window, name: name + "-reversed")
                model.endSearch()
                try await Task.sleep(for: .milliseconds(250))
                try await capture(window, name: name + "-closing")
                try await Task.sleep(for: .milliseconds(1400))
                #expect(!model.isSearching && model.selectedTag == "Selected" && model.items.map(\.id) == ["a"])
                #expect(SwiftUIReplay.editor(in: try #require(window.contentView)) == nil)
                try await capture(window, name: name + "-restored")
            }
        }
    }

    @Test(.requiresDisplay, .enabled(if: ProcessInfo.processInfo.environment["MOKUSEI_OVERVIEW_SEARCH_NATIVE_REPLAY"] == "1", "Requires the native search replay: python3 tools/verification/reading-presentation/run.py --overview-search"))
    func nativeChineseHybridSearchWithoutManualSetup() async throws {
        _ = NSApplication.shared
        NSApp.activate(ignoringOtherApps: true)
        NativeTypography.registerFonts()
        let window = NSWindow(contentRect: .init(x: 40, y: 40, width: 1100, height: 720), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.animationBehavior = .none; window.isReleasedWhenClosed = false; window.title = "Search · Synthetic fixture"
        defer { window.close() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = try workspace(directory)
        try install([thread("a", title: "Maintenance", tags: ["Storage"]), thread("b", title: "Interface", tags: ["Glass"])], in: workspace)
        let model = model(workspace, searchRequest: { request in
            #expect(request["query"] == .text("清空历史"))
            return .object(["mode": .text("hybrid"), "hits": .array([.object([
                "ref": ApplicationThreadRef(threadID: "a", typeID: "agent").json, "score": .number(0.9)
            ])])])
        })
        model.refresh()
        window.setContentSize(.init(width: 1100, height: 720))
        window.contentView = NSHostingView(rootView: NativeOverviewWorkspaceView(model: model,
            callbacks: .init(openThread: { _, _ in }, openApplication: { _, _ in }, onSettings: {})).preferredColorScheme(.dark))
        window.makeKeyAndOrderFront(nil); window.makeKey()
        model.beginSearch(); model.updateSearch("清空历史")
        try await wait { model.searchMode == "hybrid" && model.items.map(\.id) == ["a"] && !model.canvasState.isLayingOut }
        try await Task.sleep(for: .milliseconds(450))
        try await capture(window, name: "semantic-chinese-hybrid")
        model.endSearch()
    }

}

extension NativeOverviewSearchTests {
    @Test(arguments: [false, true])
    func zeroCountTagsHideAndRecoverWithoutChangingSearchCounts(searching: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = try workspace(directory), overview = model(workspace)
        func installTags(_ tags: [JSONText]) throws {
            try install([thread("a", tags: tags, status: .running),
                         thread("b", title: "Other result", tags: ["Other"], status: .completed)], in: workspace)
            overview.refresh()
        }
        try installTags(["Target"])
        let target = try #require(overview.visibleFilters.withChildren.first { $0.matches("Target") && $0.count > 0 })
        overview.selectTag(target)
        if searching { overview.beginSearch(); overview.updateSearch("Other result") }
        // Search misses do not hide a tag with positive canonical membership.
        #expect(overview.visibleFilters.withChildren.contains { $0.matches("Target") && $0.count == 1 })
        if searching { #expect(overview.items.isEmpty) }
        // Archiving/removing the last assignment must also clear the selection.
        try install([thread("a", tags: ["Target"], archived: true),
                     thread("b", title: "Other result", tags: ["Other"], status: .completed)], in: workspace)
        overview.refresh()
        #expect(!overview.visibleFilters.withChildren.contains { $0.matches("Target") && $0.count > 0 })
        #expect(overview.tagSelection == nil && overview.selectedTag.isEmpty)
        #expect(overview.items.map(\.id) == ["b"])
        try installTags(["Target"])
        #expect(overview.visibleFilters.withChildren.contains { $0.matches("Target") && $0.count == 1 })
        #expect(overview.isSearching == searching && overview.searchQuery == (searching ? "Other result" : ""))
        overview.selectTag(target)
        try installTags([])
        #expect(overview.selectedTag.isEmpty && overview.tagSelection == nil)
    }

    @Test func queryEditsReuseCanonicalFilterMembership() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = try workspace(directory), overview = model(workspace)
        try install([thread("a", tags: ["Shared"], status: .running), thread("b", tags: ["Shared"])], in: workspace)
        overview.refresh()
        let counts = overview.filters.map(\.count), builds = overview.membershipBuildCount
        let facts = overview.filterContextFacts
        for (filter, fact) in zip(overview.filters, facts) {
            #expect(fact["count"]?.intValue == filter.count)
            #expect(fact["threads"]?.arrayValue?.count == filter.count)
        }
        overview.beginSearch()
        for query in ["G", "Gl", "Glass", "", "Focus"] { overview.updateSearch(query) }
        #expect(overview.membershipBuildCount == builds)
        #expect(overview.filterContextFacts == facts)
        #expect(overview.filters.map(\.count) == counts)
    }
}

extension NativeOverviewSearchTests {
    @Test(.requiresDisplay, .enabled(if: ProcessInfo.processInfo.environment["MOKUSEI_OVERVIEW_SEARCH_NATIVE_REPLAY"] == "1", "Requires the native search replay: python3 tools/verification/reading-presentation/run.py --overview-search"))
    func continuousNativeSearchDoesNotCaptureExitCards() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let workspace = try workspace(directory), overview = model(workspace)
        try install([thread("a", title: "Glass"), thread("b", title: "Focus"), thread("c", title: "Glass Focus")], in: workspace)
        overview.refresh()
        let window = SwiftUIReplay.window(NativeOverviewWorkspaceView(model: overview,
            callbacks: .init(openThread: { _, _ in }, openApplication: { _, _ in }, onSettings: {})), width: 1100, height: 720)
        defer { window.close() }
        try await SwiftUIReplay.wait { !overview.canvasState.isLayingOut && !overview.canvasState.presentedPlacements.isEmpty }
        try await Task.sleep(for: .milliseconds(300))
        let snapshots = overview.canvasState.sceneSnapshotCount
        overview.beginSearch()
        for query in ["G", "Gl", "Glass", "Focus", "", "Gl"] {
            overview.updateSearch(query)
            try await Task.sleep(for: .milliseconds(100))
            #expect(overview.canvasState.sceneSnapshotCount == snapshots)
        }
        overview.endSearch()
        try await wait { !overview.canvasState.isLayingOut }
        #expect(overview.canvasState.sceneSnapshotCount == snapshots)
    }
}


private extension Array where Element == NativeOverviewFilter {
    var withChildren: [NativeOverviewFilter] { self + flatMap(\.children) }
}
