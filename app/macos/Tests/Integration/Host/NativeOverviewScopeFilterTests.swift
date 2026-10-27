import Foundation
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
import MokuseiCore
import MokuseiPluginAPI
@testable import MokuseiUI

@MainActor
@Suite(.serializedNative)
struct NativeOverviewScopeFilterTests {
    private func thread(_ id: String, cwd: String, tags: [String]) throws -> HarnessThread {
        try HarnessThread(id: JSONText(id), harnessID: "codex", revision: 0, sessionState: .object([:]),
            observation: .init(latestExecution: nil), cwd: JSONText(cwd), settings: .object([:]),
            createdAt: 1, updatedAt: 2, title: JSONText(id), tags: tags.map { JSONText($0) },
            tagEmojis: Dictionary(uniqueKeysWithValues: tags.map { (JSONText($0), JSONText("🔧")) }))
    }

    private var inboxPath: String { "/tmp/mokusei-scope-filter-fixture" }

    @Test func filtersGroupSessionTagsUnderDirectoryAndKeepInboxTopLevel() throws {
        let first = try thread("first", cwd: "/workspace/a/RepoA", tags: ["Alpha"])
        let second = try thread("second", cwd: "/workspace/a/RepoA", tags: ["Beta"])
        let other = try thread("other", cwd: "/workspace/b/RepoA", tags: ["Gamma"])
        let inbox = try thread("inbox", cwd: inboxPath, tags: ["InboxTag"])
        let collection = NativeOverviewSelection.candidates(threads: [first, second, other, inbox], applications: [])
        let filters = NativeOverviewSelection.filters(collection)

        let directories = filters.filter(\.isDirectory)
        #expect(directories.count == 2)
        #expect(directories.allSatisfy { $0.tag == "RepoA" })
        #expect(Set(directories.map(\.scope)).count == 2)
        let scopes = Dictionary(uniqueKeysWithValues: directories.map { ($0.scope, $0) })
        let scopeA = try #require(directories.first { $0.scope == NativeOverviewSelection.scope(cwd: "/workspace/a/RepoA") })
        let scopeB = try #require(directories.first { $0.scope == NativeOverviewSelection.scope(cwd: "/workspace/b/RepoA") })
        #expect(scopeA.children.map(\.tag).sorted() == ["Alpha", "Beta"])
        #expect(scopeB.children.map(\.tag) == ["Gamma"])
        #expect(directories.flatMap(\.children).allSatisfy { $0.emoji == "🔧" })
        #expect(directories.allSatisfy { $0.emoji == nil })
        #expect(scopes.values.allSatisfy { $0.count == ($0.scope == scopeA.scope ? 2 : 1) })
        let inboxTag = try #require(filters.first { !$0.isDirectory && $0.tag == "InboxTag" })
        #expect(inboxTag.scope == NativeOverviewSelection.inboxScope)
        #expect(inboxTag.count == 1)
    }

    @Test func directoryAllAndNestedTagSelectionStayInsideTheirScope() throws {
        let root = URL(fileURLWithPath: "/private/tmp")
            .appendingPathComponent("overview-scope-filter-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directoryA = root.appendingPathComponent("a/RepoA")
        let directoryB = root.appendingPathComponent("b/RepoA")
        for directory in [directoryA, directoryB] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let alias = root.appendingPathComponent("project-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directoryA)
        let first = try thread("first", cwd: directoryA.path, tags: ["Alpha"])
        let second = try thread("second", cwd: directoryA.path, tags: ["Beta"])
        let symlink = try thread("symlink", cwd: alias.path, tags: ["Beta"])
        let other = try thread("other", cwd: directoryB.path, tags: ["Gamma"])
        let threads = [first, second, symlink, other]
        let scopeA = NativeOverviewSelection.scope(first)
        let scopeB = NativeOverviewSelection.scope(other)
        #expect(NativeOverviewSelection.scope(symlink) == scopeA)
        #expect(NativeOverviewSelection.directoryTag(symlink) == "project-alias")
        let filters = NativeOverviewSelection.filters(.init(threads: threads, applications: []))
        let parent = try #require(filters.first { $0.isDirectory && $0.scope == scopeA })
        #expect(parent.count == 3)
        #expect(parent.children.first { $0.tag == "Alpha" }?.count == 1)
        #expect(parent.children.first { $0.tag == "Beta" }?.count == 2)

        // Every display label for the same scope must include the same members.
        for label in [parent.tag, "project-alias"] {
            let allA = NativeOverviewSelection.select(threads: threads, applications: [], tags: [label],
                                                      kind: .directory, scope: scopeA)
            #expect(allA.threads.map(\.id.string) == ["first", "second", "symlink"])
            #expect(allA.count == parent.count)
        }
        let alphaA = NativeOverviewSelection.select(threads: threads, applications: [], tags: ["Alpha"],
                                                    kind: .semantic, scope: scopeA)
        #expect(alphaA.threads.map(\.id.string) == ["first"])
        let betaA = NativeOverviewSelection.select(threads: threads, applications: [], tags: ["Beta"],
                                                   kind: .semantic, scope: scopeA)
        #expect(betaA.threads.map(\.id.string) == ["second", "symlink"])
        let alphaB = NativeOverviewSelection.select(threads: threads, applications: [], tags: ["Alpha"],
                                                    kind: .semantic, scope: scopeB)
        #expect(alphaB.threads.isEmpty)
        let allB = NativeOverviewSelection.select(threads: threads, applications: [], tags: ["RepoA"],
                                                  kind: .directory, scope: scopeB)
        #expect(allB.threads.map(\.id.string) == ["other"])
        #expect(NativeOverviewTagSelection(tag: "Alpha", kind: .semantic, scope: scopeA)
            != NativeOverviewTagSelection(tag: "Alpha", kind: .semantic, scope: scopeB))
    }

    @Test func inboxTagsSelectWithoutADirectoryWrapper() throws {
        let inbox = try thread("inbox", cwd: inboxPath, tags: ["InboxTag"])
        let selected = NativeOverviewSelection.select(threads: [inbox], applications: [], tags: ["InboxTag"],
                                                      kind: .semantic, scope: NativeOverviewSelection.inboxScope)
        #expect(selected.threads.map(\.id.string) == ["inbox"])
    }

    @Test func directoryScopeWithNoTagsStillProvidesItsAllView() throws {
        let untagged = try thread("untagged", cwd: "/workspace/plain/Repo", tags: [])
        let filters = NativeOverviewSelection.filters(
            NativeOverviewSelection.candidates(threads: [untagged], applications: []))
        let directory = try #require(filters.first { $0.isDirectory })
        #expect(directory.tag == "Repo")
        #expect(directory.count == 1)
        #expect(directory.children.isEmpty)
    }

    @Test func sameNamedScopesHaveDistinctFilterIdentity() throws {
        let first = try thread("first", cwd: "/workspace/a/RepoA", tags: ["Alpha"])
        let second = try thread("second", cwd: "/workspace/b/RepoA", tags: ["Alpha"])
        let directories = NativeOverviewSelection.filters(
            NativeOverviewSelection.candidates(threads: [first, second], applications: [])).filter(\.isDirectory)
        #expect(directories.count == 2)
        #expect(Set(directories.map(\.id)).count == 2)
        #expect(Set(directories.map(\.displayTag)).count == 2)
    }

    @Test func reportScopeSurvivesWithoutSourceThreadsAndFiltersByIdentity() throws {
        func report(_ id: String, scope: String, tagged: Bool = true, label: String = "Project", directoryOnly: Bool = false) throws -> NativeOverviewApplicationEntry {
            let directory: [JSONValue] = scope == "inbox" ? [] : [.text(label)]
            let semantic: [JSONValue] = tagged ? [.text("Derived")] : []
            return try NativeOverviewApplicationEntry(json: .object([
                "id": .text(id), "scope": .text(scope),
                "ref": ApplicationThreadRef(threadID: JSONText(id), typeID: "report.document").json,
                "revision": .number(0), "createdAt": .number(1), "updatedAt": .number(3),
                "title": .text("Report"), "archived": .bool(false),
                "tags": .object(["tags": .array(directory + semantic), "semanticTags": .array(semantic),
                                 "directoryTags": .array(directory), "tagEmojis": .object(tagged ? ["Derived": .text("🔧")] : [:])]),
                "presentations": .array(directoryOnly ? [.object([
                    "id": .text("mokusei.overview"), "apiVersion": .integer(1), "schemaVersion": .integer(1),
                    "value": .object(["coversExecutions": .array([]), "tagFilter": .text("directory")])])] : []),
                "view": .object([:])]))
        }
        let a = try report("a", scope: "/workspace/a/Project")
        let b = try report("b", scope: "/workspace/b/Project")
        let inbox = try report("inbox", scope: "inbox")
        let plain = try report("plain", scope: "/workspace/plain/Project", tagged: false)
        let applications = [a, b, inbox, plain]
        let filters = NativeOverviewSelection.filters(.init(threads: [], applications: applications))
        #expect(filters.filter(\.isDirectory).count == 3)
        #expect(filters.contains { $0.scope == "inbox" && !$0.isDirectory && $0.tag == "Derived" })
        #expect(filters.first { $0.scope == "/workspace/plain/Project" }?.children.isEmpty == true)
        #expect(a.entry.mapView { _ in "decoded" }.scope == "/workspace/a/Project")
        for (scope, id) in [("/workspace/a/Project", "a"), ("/workspace/b/Project", "b"), ("inbox", "inbox")] {
            let selected = NativeOverviewSelection.select(threads: [], applications: applications,
                tags: ["Derived"], kind: .semantic, scope: scope)
            #expect(selected.applications.map(\.entry.ref.threadID.string) == [id])
            if scope != "inbox" {
                let directory = NativeOverviewSelection.select(threads: [], applications: applications,
                    tags: ["Project"], kind: .directory, scope: scope)
                #expect(directory.applications.map(\.entry.ref.threadID.string) == [id])
            }
        }
        #expect(NativeOverviewSelection.select(threads: [], applications: applications).applications.count == 4)

        let alias = try report("alias", scope: "/workspace/a/Project", label: "project-alias", directoryOnly: true)
        let aliasedApplications = applications + [alias]
        for label in ["Project", "project-alias"] {
            let directory = NativeOverviewSelection.select(threads: [], applications: aliasedApplications,
                tags: [label], kind: .directory, scope: "/workspace/a/Project")
            #expect(directory.applications.map(\.entry.ref.threadID.string) == ["a", "alias"])
        }
        let semantic = NativeOverviewSelection.select(threads: [], applications: aliasedApplications,
            tags: ["Derived"], kind: .semantic, scope: "/workspace/a/Project")
        #expect(semantic.applications.map(\.entry.ref.threadID.string) == ["a"])
        #expect(NativeOverviewSelection.select(threads: [], applications: aliasedApplications).applications.count == 4)
    }

}

extension NativeOverviewScopeFilterTests {
    @Test func scopedRedirectKeepsTheSelectionInsideItsScope() {
        let scope = "/workspace/a/RepoA"
        let redirects = JSONValue.object([JSONText(scope + "\u{0}" + "old"): .text("new")])
        let selection = NativeOverviewSelection.resolve(
            NativeOverviewTagSelection(tag: "Old", kind: .semantic, scope: scope),
            redirects: redirects, directoryTags: [])
        #expect(selection?.tag == "new")
        #expect(selection?.scope == scope)
    }
}
