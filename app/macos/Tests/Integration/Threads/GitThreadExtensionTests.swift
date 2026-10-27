import AppKit
import Observation
import SwiftUI
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import MokuseiHarnessCodex
import MokuseiHarnessPi
import MokuseiHarnessClaude
import MokuseiHarnessOpenCode
@testable import MokuseiUI

@MainActor @Observable private final class GitSummaryNumbers {
    var added = "128"
    var deleted = "42"
}
private struct GitSummaryNumberReplay: View {
    let numbers: GitSummaryNumbers
    var body: some View {
        HStack(spacing: 22) {
            RollingNumberText(value: numbers.added, fontSize: 17, color: .green)
            RollingNumberText(value: numbers.deleted, fontSize: 17, color: .red)
            RollingNumberText(value: numbers.added)
        }.padding(20).frame(width: 400, height: 90).background(Color.white)
    }
}

@MainActor @Suite(.serializedNative, .serialized)
struct GitThreadExtensionTests {
    private func status(changed: Int = 1, ahead: Int? = nil, behind: Int? = nil, additions: Int? = 0, deletions: Int? = 0,
                        staged: Int = 0, untracked: Int = 0, conflicts: Int = 0, lineStatsError: HarnessGitReadError? = nil,
                        error: String? = nil) -> HarnessGitStatus {
        .init(id: "worktree", root: "/workspace/repo", branch: "main", head: nil, upstream: nil,
              ahead: ahead, behind: behind, changed: changed, staged: staged, unstaged: changed - staged - untracked - conflicts,
              untracked: untracked, conflicts: conflicts, additions: additions, deletions: deletions,
              lineStatsError: lineStatsError, error: error)
    }
    private func thread(harness: JSONText, id: JSONText = "agent") throws -> HarnessThread {
        try .init(id: id, harnessID: harness, revision: 0, sessionState: .null,
            observation: .init(), cwd: "/workspace/repo", settings: .object([:]),
            createdAt: 1, updatedAt: 1, title: "Agent", tags: [], archived: false)
    }
    @Test func nativeHostAssociatesSharedProjectsWithTheirExecutionWorktrees() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = NativeWorkspaceModel(client: RuntimeClient(profile: try RuntimeProfile(dataDirectory: directory)),
            preferences: DesktopPreferences(directory: directory), plugins: try .init(harnesses: [], sidecards: [], applications: []))
        let host = NativeApplicationHost(workspace: workspace, navigationCallbacks: .init(
            openThread: { _, _ in }, openExecution: { _ in }, followUp: { _, _ in }, openExternal: { _ in }))
        defer { host.release() }
        func repository(_ id: String, cwd: String, branch: String, changed: Int,
                        ahead: Int = 0, behind: Int = 0, additions: Int? = 0, deletions: Int? = 0,
                        lineStatsError: HarnessGitReadError? = nil) throws -> NativeGitRepository {
            try .init(.object(["id": .text(id), "directories": .array([.text(cwd)]), "available": .bool(true),
                "sync": .object(["attemptedAt": .integer(1), "observedAt": .integer(1), "error": .null]),
                "snapshot": .object(["root": .text(cwd), "branch": .text(branch), "head": .null,
                    "upstream": .null, "ahead": .integer(ahead), "behind": .integer(behind),
                    "changed": .integer(changed), "additions": additions.map(JSONValue.integer) ?? .null,
                    "deletions": deletions.map(JSONValue.integer) ?? .null,
                    "lineStatsError": lineStatsError.map { .text($0.rawValue) } ?? .null,
                    "staged": .integer(0), "unstaged": .integer(changed), "untracked": .integer(0), "conflicts": .integer(0)])]))
        }
        func input(_ id: JSONText, worktree: JSONValue? = nil) throws -> HarnessThread {
            try .init(id: id, harnessID: "codex", revision: 0, sessionState: .null, observation: .init(),
                cwd: "/project", settings: .object([:]), createdAt: 1, updatedAt: 1, title: "Agent", tags: [], worktree: worktree)
        }
        let main = try repository("main-observation", cwd: "/project", branch: "main", changed: 82)
        let first = try repository("first-observation", cwd: "/worktrees/first", branch: "first", changed: 2)
        let second = try repository("second-observation", cwd: "/worktrees/second", branch: "second", changed: 1)
        host.git.install([main, first, second])
        let projectThread = try input("ordinary")
        let firstThread = try input("first", worktree: .object(["cwd": .text("/worktrees/first")]))
        let secondThread = try input("second", worktree: .object(["cwd": .text("/worktrees/second")]))
        let sharedThread = try input("shared", worktree: .object(["cwd": .text("/worktrees/first")]))
        let lookup = host.overviewFactories.gitStatus
        #expect(lookup(projectThread)?.id == "main-observation")
        #expect(lookup(firstThread)?.id == "first-observation")
        #expect(lookup(firstThread)?.changed == 2)
        #expect(lookup(secondThread)?.id == "second-observation")
        #expect(lookup(secondThread)?.branch == "second")
        #expect(lookup(firstThread) == lookup(sharedThread))
        #expect(lookup(try input("null-worktree", worktree: .null))?.id == "main-observation")
        #expect(lookup(try input("invalid-worktree", worktree: .object(["cwd": .text("")]))) == nil)
        host.git.install([main])
        #expect(lookup(firstThread) == nil)
        #expect(lookup(secondThread) == nil)
        #expect(lookup(projectThread)?.id == "main-observation")
        for (ahead, behind) in [(0, 0), (1, 0), (0, 1), (2, 3)] {
            host.git.install([try repository("main-observation", cwd: "/project", branch: "main", changed: 0,
                                            ahead: ahead, behind: behind)])
            #expect(lookup(projectThread) == nil)
        }
        // File-only changes (binary/rename/empty files or unavailable statistics)
        // and positive line counts both survive the production host's filter.
        for (changed, added, deleted): (Int, Int?, Int?) in [(1, 0, 0), (1, nil, nil), (0, 1, 0), (0, 0, 1)] {
            host.git.install([try repository("main-observation", cwd: "/project", branch: "main", changed: changed,
                                            additions: added, deletions: deleted)])
            #expect(lookup(projectThread)?.id == "main-observation")
        }
        for failure in HarnessGitReadError.allCases {
            let failed = try repository("main-observation", cwd: "/project", branch: "main", changed: 3163,
                                        additions: nil, deletions: nil, lineStatsError: failure)
            #expect(host.git.install([failed]))
            #expect(lookup(projectThread)?.changed == 3163)
            #expect(lookup(projectThread)?.lineStatsError == failure)
            #expect(lookup(projectThread)?.error == nil)
        }
        #expect(throws: PluginContractError.self) {
            try repository("invalid", cwd: "/project", branch: "main", changed: 1, additions: nil, deletions: 0)
        }
        #expect(throws: PluginContractError.self) {
            try repository("invalid", cwd: "/project", branch: "main", changed: 1, lineStatsError: .timeout)
        }
    }
    @Test func everyShippedHarnessReprojectsForGitWithoutChangingAgentIdentity() throws {
        let harnesses = [AnyHarnessPlugin(CodexHarnessPlugin()), AnyHarnessPlugin(PiHarnessPlugin()),
                         AnyHarnessPlugin(ClaudeHarnessPlugin()), AnyHarnessPlugin(OpenCodeHarnessPlugin())]
        for harness in harnesses {
            let thread = try thread(harness: harness.descriptor.id)
            let clean = try harness.projectOverview(input: .init(thread: thread), availableColumns: 3)
            let active = try harness.projectOverview(input: .init(thread: thread, git: status()), availableColumns: 3)
            #expect(clean.envelope.footprint.columns * clean.envelope.footprint.rows == 1)
            #expect(active.envelope.footprint.columns * active.envelope.footprint.rows == 2)
            #expect(active.envelope.structureKey.string.contains("git"))
            #expect(active.input.thread.id == clean.input.thread.id)
            let stale = try harness.projectOverview(input: .init(thread: thread, git: status(error: "timeout")), availableColumns: 3)
            #expect(stale.envelope.structureKey == active.envelope.structureKey)
            #expect(stale !== active)
            for hidden in [status(changed: 0, ahead: 1), status(changed: 0, behind: 1),
                           status(changed: 0, ahead: 2, behind: 3, additions: nil, deletions: nil)] {
                let projected = try harness.projectOverview(input: .init(thread: thread, git: hidden), availableColumns: 3)
                #expect(projected.envelope.structureKey == clean.envelope.structureKey)
                #expect(projected.envelope.footprint == clean.envelope.footprint)
            }
            for visible in [status(changed: 0, additions: 1), status(changed: 0, deletions: 1),
                            status(staged: 1), status(untracked: 1), status(conflicts: 1),
                            status(additions: nil, deletions: nil)] {
                let projected = try harness.projectOverview(input: .init(thread: thread, git: visible), availableColumns: 3)
                #expect(projected.envelope.structureKey == active.envelope.structureKey)
                #expect(projected.envelope.footprint == active.envelope.footprint)
            }
            let cleanAgain = try harness.projectOverview(input: .init(thread: thread, git: status(changed: 0)), availableColumns: 3)
            #expect(cleanAgain.envelope.structureKey == clean.envelope.structureKey)
        }
    }
    @Test func visibilityAndLayoutCoverDivergenceAndExistingExtensions() throws {
        #expect(!status(changed: 0).isActive)
        #expect(!status(changed: 0, ahead: 1).isActive)
        #expect(!status(changed: 0, behind: 1).isActive)
        let base: ThreadCardProjection = .standard(extensions: [
            .todo(steps: [.init(step: "Review", status: .pending)]),
            .derived(rows: [.init(id: "child", label: "Child", status: .running, kind: .agent)]),
            .intervention(.init(id: "ask", title: "Permission", actions: [.init(id: "yes", label: "Yes")]))])
        for columns in 1...3 {
            let presentation = try composeThreadCard(base, git: status(), layoutContext: .init(availableCols: columns))
            guard case .standard(_, _, let placements, _) = presentation.composition else { Issue.record("Expected standard card"); return }
            #expect(Set(placements.map(\.kind)) == [.todo, .derived, .intervention, .git])
            #expect(presentation.size.cols <= columns)
        }
    }
    @Test func sharedExtensionsChangeLayoutWithoutChangingCatalogMembershipOrCounts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = NativeWorkspaceModel(client: RuntimeClient(profile: try RuntimeProfile(dataDirectory: directory)),
            preferences: DesktopPreferences(directory: directory),
            plugins: try .init(harnesses: [AnyHarnessPlugin(CodexHarnessPlugin())], sidecards: [], applications: []))
        let threads = try [thread(harness: "codex", id: "first"), thread(harness: "codex", id: "second")]
        try workspace.catalog.install(.object(["revision": .integer(0), "settingsRevision": .integer(0),
            "defaultCwd": .text("/workspace/repo"), "settings": .object([:]), "threads": .array(threads.map(\.json)),
            "executions": .array([]), "applicationThreads": .array([])]))
        var current: HarnessGitStatus?
        let overview = NativeOverviewWorkspaceModel(workspace: workspace, applications: .init(
            projectionCapabilities: { _, _ in throw CancellationError() }, rendererContext: { _, _, _ in throw CancellationError() },
            gitStatus: { _ in current }))
        overview.refresh()
        let builds = overview.membershipBuildCount, filters = overview.filters
        #expect(overview.items.count == 2)
        #expect(overview.items.allSatisfy { $0.columns * $0.rows == 1 })
        current = status()
        overview.refreshCardExtensions()
        #expect(overview.items.count == 2)
        #expect(overview.items.allSatisfy { $0.columns * $0.rows == 2 })
        #expect(overview.revisions.count == 1)
        let previousIDs = overview.items.map(\.presentationID)
        current = status(changed: 2)
        overview.refreshCardExtensions()
        #expect(overview.items.map(\.presentationID) != previousIDs)
        #expect(overview.revisions.count == 1)
        current = nil
        overview.refreshCardExtensions()
        #expect(overview.items.allSatisfy { $0.columns * $0.rows == 1 })
        #expect(overview.revisions.count == 2)
        #expect(overview.membershipBuildCount == builds)
        #expect(overview.filters == filters)
    }
    @Test(.requiresDisplay) func sharedTokenFlipAnimationWorksAtSummaryAndOriginalSizes() async throws {
        let numbers = GitSummaryNumbers()
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 90), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
        let root = NSHostingView(rootView: GitSummaryNumberReplay(numbers: numbers))
        window.contentView = root; window.orderFront(nil)
        defer { window.close() }
        func pixels() throws -> Data {
            root.layoutSubtreeIfNeeded()
            let image = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: image)
            return try #require(image.representation(using: .png, properties: [:]))
        }
        try await Task.sleep(for: .milliseconds(100))
        let initial = try pixels()
        numbers.added = "957"; numbers.deleted = "26"
        try await Task.sleep(for: .milliseconds(90))
        let during = try pixels()
        try await Task.sleep(for: .milliseconds(300))
        let settled = try pixels()
        #expect(initial != during && during != settled && initial != settled)
        #expect(root.bounds.size == CGSize(width: 400, height: 90))
    }
    @Test(.requiresDisplay, arguments: ["known", "unknown", "too-large", "timeout", "unavailable", "inaccessible", "stale"], ["en-US", "zh-CN"])
    func extensionButtonShowsStatisticsStateAndOpensWorktree(state: String, locale: String) async throws {
        let known = state == "known" || state == "stale"
        let git = status(changed: 3163, additions: known ? 0 : nil, deletions: known ? 0 : nil,
                         lineStatsError: HarnessGitReadError(rawValue: state), error: state == "stale" ? "timeout" : nil)
        let presentation = try composeThreadCard(.standard(extensions: []), git: git, layoutContext: .init(availableCols: 3))
        var opened: [JSONText] = []
        var openedAgent = false
        let app = NSApplication.shared
        app.setActivationPolicy(.regular); app.unhide(nil); app.activate(ignoringOtherApps: true)
        let enableAX = NSSelectorFromString("accessibilitySetValue:forAttribute:")
        if app.responds(to: enableAX) { _ = app.perform(enableAX, with: true, with: "AXEnhancedUserInterface") }
        let content = HarnessThreadCard(identity: .init(title: "Agent", excerpt: ""), presentation: presentation)
            .environment(\.openGitWorktree, { opened.append($0) })
            .environment(\.locale, Locale(identifier: locale))
            .environment(\.colorScheme, .light)
            .background(NativePalette.overview.canvas.swiftUI)
            .onTapGesture { openedAgent = true }
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 736, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = NSHostingView(rootView: content.accessibilityElement(children: .contain))
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<20 { window.contentView?.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        let root = try #require(window.contentView)
        let text = accessibilityText(root)
        #expect(text.contains("3163"))
        #expect(!text.contains("+—") && !text.contains("−—"))
        let chinese = locale == "zh-CN"
        switch state {
        case "known": #expect(text.contains("+0, −0"))
        case "unknown": #expect(text.contains(chinese ? "行数未知" : "Line counts unknown"))
        case "too-large": #expect(text.contains(chinese ? "行数超出统计上限" : "Line count limit exceeded"))
        case "timeout": #expect(text.contains(chinese ? "行数统计超时" : "Line count timed out"))
        case "stale": #expect(text.contains(chinese ? "上次读取，可能已过期" : "Last read; may be stale"))
        default: #expect(text.contains(chinese ? "行数统计不可用" : "Line counts unavailable"))
        }
        let image = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: image)
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MOKUSEI_GIT_ARTIFACTS"] ?? "/tmp/mokusei-git-visual")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try #require(image.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("git-extension-\(state)-\(locale).png"))
        let point = root.convert(NSPoint(x: 550, y: 90), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            window.sendEvent(event)
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!openedAgent)
        #expect(opened == ["worktree"])
    }
    private func accessibilityText(_ root: NSView) -> String {
        var result: [String] = [], seen = Set<ObjectIdentifier>()
        func visit(_ object: AnyObject) {
            guard seen.insert(ObjectIdentifier(object)).inserted, seen.count < 10000,
                  let element = object as? NSObject else { return }
            for key in ["accessibilityLabel", "accessibilityValue"] {
                let selector = NSSelectorFromString(key)
                if element.responds(to: selector), let text = element.perform(selector)?.takeUnretainedValue() as? String { result.append(text) }
            }
            let selector = NSSelectorFromString("accessibilityChildren")
            if element.responds(to: selector), let children = element.perform(selector)?.takeUnretainedValue() as? [AnyObject] { children.forEach(visit) }
            if let view = element as? NSView { view.subviews.forEach(visit) }
        }
        _ = root.window?.accessibilityChildren(); visit(root.window ?? root)
        return result.joined(separator: "\n")
    }
}
