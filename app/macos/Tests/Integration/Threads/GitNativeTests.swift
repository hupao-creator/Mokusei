import AppKit
import SwiftUI
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
@testable import MokuseiUI
import MokuseiCore
import MokuseiPluginAPI

private let patch = """
diff --git a/code.swift b/code.swift
index 1111111..2222222 100644
--- a/code.swift
+++ b/code.swift
@@ -1,2 +1,2 @@
 let unchanged = true
-let value = 1
+let value = 2
\\ No newline at end of file

"""

@MainActor
@Suite(.serializedNative, .serialized)
struct GitNativeTests {
    private func viewJSON() -> JSONValue {
        .object(["snapshot": .object([
            "root": .text("/tmp/native-git-fixture"), "branch": .text("main"), "head": .text(String(repeating: "a", count: 40)),
            "upstream": .null, "ahead": .null, "behind": .null,
            "lineStatsError": .null, "additions": .number(128), "deletions": .number(42), "changed": .number(2), "staged": .number(0), "unstaged": .number(2), "untracked": .number(0), "conflicts": .number(0)
        ]), "sync": .object(["attemptedAt": .number(1), "observedAt": .number(1), "error": .null]), "available": .bool(true)])
    }
    private func filesJSON() -> JSONValue {
        .object(["files": .array(["code.swift", "other.swift"].map { path in
            .object(["path": .text(path), "oldPath": .null, "status": .text("M"), "scope": .text("unstaged"), "submodule": .bool(false)])
        }), "readAt": .number(1)])
    }
    private func props(theme: PluginTheme = .light, domain: ApplicationDomainClient, lifetime: PluginLifetime = PluginLifetime()) throws -> NativeGitDetailProps {
        let reference = ApplicationThreadRef(threadID: "git-fixture", typeID: "git.worktree")
        let context = ApplicationRendererContext(theme: theme, locale: "en-US", lifetime: lifetime, domain: domain,
            capabilities: try .init(scope: .init(pluginID: "git", thread: reference), requires: [], registrations: []),
            openThread: { _, _ in }, openExecution: { _ in })
        return .init(entry: .init(ref: reference, title: "Native Git Fixture", view: try NativeGitView(json: viewJSON())), context: context)
    }
    private func fixtureDomain() -> ApplicationDomainClient {
        ApplicationDomainClient(pluginID: "git") { _, operation, _, _, _ in
            switch operation {
            case "git.list": .object(["items": .array([])])
            case "git.files": filesJSON()
            case "git.diff": .object(["patch": .text(patch), "notice": .null])
            default: throw PluginContractError("Unexpected Git query")
            }
        }
    }
    private func settle(_ window: NSWindow? = nil, until check: () -> Bool = { false }) async throws {
        for _ in 0..<80 {
            window?.contentView?.layoutSubtreeIfNeeded()
            if check() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private func texts(_ view: NSView) -> [NSTextView] {
        (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(texts)
    }

    @Test func realGitPatchParsingAndNativeAnnotations() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ arguments: String...) throws -> String {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", root.path] + arguments
            let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            #expect(process.terminationStatus == 0 || process.terminationStatus == 1)
            return String(decoding: data, as: UTF8.self)
        }
        _ = try git("init", "-b", "main")
        let name = "tab\tquote\"line\n中文.swift"
        try "let value = 1\n".write(to: root.appendingPathComponent(name), atomically: false, encoding: .utf8)
        _ = try git("add", "--", name)
        try "let value = 2".write(to: root.appendingPathComponent(name), atomically: false, encoding: .utf8)
        let actual = try git("diff", "--no-ext-diff", "--no-textconv", "--", name)
        let module = try NativeGitService.module()
        #expect(module.threads.isEmpty)
        let document = try NativeGitParsedDiff.parse(JSONText(actual))
        let file = try #require(document.files.first)
        #expect(file.path == name)
        #expect(file.additions == 1 && file.deletions == 1)
        #expect(file.rows.last?.new?.noNewline == true)
        #expect(file.rows.contains { !($0.new?.tokens.isEmpty ?? true) })
        #expect(file.rows.contains { !($0.new?.emphasis.isEmpty ?? true) })
        let staged = try git("diff", "--cached", "--", name)
        #expect(try NativeGitParsedDiff.parse(JSONText(staged)).files.first?.kind == .added)
        try FileManager.default.removeItem(at: root.appendingPathComponent(name))
        let deleted = try git("diff", "--", name)
        #expect(try NativeGitParsedDiff.parse(JSONText(deleted)).files.first?.kind == .deleted)
        #expect(try NativeGitParsedDiff.parse(JSONText("")).isEmpty)
        #expect(throws: (any Error).self) { try NativeGitParsedDiff.parse(JSONText("diff --git invalid\n@@ broken\n")) }
        #expect(throws: GitDisplayLimitError.self) { try NativeGitParsedDiff.parse(JSONText(String(repeating: "line\n", count: 12_001))) }
        #expect(throws: GitDisplayLimitError.self) { try NativeGitParsedDiff.parse(JSONText(String(repeating: "a", count: 32_769))) }
    }

    @Test func modeOnlyPathContainingHeaderDelimiter() throws {
        let patch = "diff --git a/space b/mode.txt b/space b/mode.txt\nold mode 100644\nnew mode 100755\n"
        let file = try #require(NativeGitParsedDiff.parse(JSONText(patch)).files.first)
        #expect(file.path == "space b/mode.txt")
        #expect(file.oldPath == file.path)
        #expect(file.rows.isEmpty)
    }

    // Opt-in bridge: generated by the real Go runtime query replay, rather
    // than a hand-maintained Swift fixture that could hide contract drift.
    @Test func runtimeQueryEvidenceDecodesAndParses() throws {
        guard let path = ProcessInfo.processInfo.environment["MOKUSEI_GIT_CONTRACT_EVIDENCE"] else { return }
        let json = try JSONValue(data: Data(contentsOf: URL(fileURLWithPath: path)))
        let view = try NativeGitView(json: #require(json["view"]))
        let repositories = try NativeGitRepositoryPage(#require(json["repositories"]))
        let files = try NativeGitFilesResult(#require(json["files"]))
        #expect(repositories.repositories.contains { $0.root == view.snapshot.root })
        #expect(view.snapshot.additions == 4 && view.snapshot.deletions == 2)
        #expect(view.snapshot.lineStatsError == nil)
        let failures = try #require(json["lineStatsFailures"]?.arrayValue).map { try NativeGitView(json: $0) }
        #expect(failures.map(\.snapshot.lineStatsError) == [.inaccessible, .timeout, .tooLarge])
        #expect(failures.map(\.snapshot.changed) == [4, 3, 260])
        #expect(failures.allSatisfy { $0.snapshot.additions == nil && $0.snapshot.deletions == nil && $0.sync.error == nil })
        #expect(Set(files.files.map(\.scope)) == [.staged, .unstaged, .untracked])
        let diffs = try #require(json["diffs"]?.arrayValue)
        var parsedPaths = Set<String>()
        for raw in diffs {
            let diff = try NativeGitDiffContent(raw)
            if diff.notice == nil {
                let document = try NativeGitParsedDiff.parse(diff.patch)
                #expect(!document.isEmpty)
                parsedPaths.formUnion(document.files.map(\.path))
            }
        }
        #expect(parsedPaths.contains("space b/mode.txt"))
        #expect(parsedPaths.contains("tab\tquote\"line\n中文.txt"))
        #expect(parsedPaths.contains(":(glob)*.txt"))
    }

    @Test func selectionRefreshCancellationAndStaleResultFence() async throws {
        var delayedCancelled = false
        var attempts = 0
        let domain = ApplicationDomainClient(pluginID: "git") { _, operation, input, _, lifetime in
            switch operation {
            case "git.list": return .object(["items": .array([])])
            case "git.files": return filesJSON()
            case "git.diff":
                attempts += 1
                if input["path"]?.stringValue == "code.swift" {
                    let token = lifetime.onCancel { delayedCancelled = true }
                    defer { lifetime.removeHandler(token) }
                    // Even a transport completing after cancellation must never
                    // overwrite the newer selection's patch.
                    try? await Task.sleep(for: .milliseconds(180))
                }
                return .object(["patch": .text(patch), "notice": .null])
            default: throw PluginContractError("Unexpected Git operation")
            }
        }
        let lifetime = PluginLifetime()
        let model = NativeGitDetailModel(props: try props(domain: domain, lifetime: lifetime))
        model.start()
        try await settle(until: { model.selectedPath != nil && attempts > 0 })
        model.select(path: "other.swift")
        try await settle(until: { model.loadedDiff?.document != nil })
        #expect(delayedCancelled)
        #expect(model.loadedDiff?.selection.path == "other.swift")
        model.refresh()
        try await settle(until: { !model.isRefreshing })
        #expect(model.loadedDiff?.selection.path == "other.swift")
        lifetime.cancel()
        #expect(model.closed)
    }

    @Test func errorRetryAndStagedOnlyInitialSelection() async throws {
        var fail = true
        let domain = ApplicationDomainClient(pluginID: "git") { _, operation, _, _, _ in
            if operation == "git.list" { return .object(["items": .array([])]) }
            if fail { throw PluginContractError("Fixture unavailable") }
            if operation == "git.files" {
                return .object(["files": .array([.object(["path": .text("staged.swift"), "oldPath": .null, "status": .text("A"), "scope": .text("staged"), "submodule": .bool(false)])]), "readAt": .number(1)])
            }
            return .object(["patch": .text(""), "notice": .text("binary")])
        }
        let model = NativeGitDetailModel(props: try props(domain: domain))
        defer { model.close() }
        model.start(); try await settle(until: { model.filesError != nil })
        #expect(model.files == nil)
        fail = false; model.refresh(); try await settle(until: { model.loadedDiff?.notice == .binary })
        #expect(model.filesError == nil)
        #expect(model.scope == .staged)
        #expect(model.loadedDiff?.notice == .binary)
    }

    @Test(.requiresDisplay, arguments: [false, true], [CGFloat(620), CGFloat(1180)])
    func nativeRenderedReaderAppearanceWidthAndCopy(dark: Bool, width: CGFloat) async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: 650), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let content = NativeGitDetail(props: try props(theme: dark ? .dark : .light, domain: fixtureDomain()))
            .environment(\.colorScheme, dark ? .dark : .light)
        let hosting = NSHostingView(rootView: content)
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.close() }
        try await settle(window, until: { texts(hosting).count == 2 })
        let columns = texts(hosting)
        #expect(columns.count == 2)
        let added = try #require(columns.first { $0.string.contains("let value = 2") })
        #expect(added.isSelectable && !added.isEditable)
        let savedClipboard: [NSPasteboardItem] = NSPasteboard.general.pasteboardItems?.map { source in
            let copy = NSPasteboardItem()
            for type in source.types { if let data = source.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        } ?? []
        defer {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(savedClipboard)
        }
        added.setSelectedRange(NSRange(location: 0, length: (added.string as NSString).length))
        added.copy(nil)
        #expect(NSPasteboard.general.string(forType: .string) == "let unchanged = true\nlet value = 2")
        added.setSelectedRange(NSRange(location: 0, length: 0))
        for column in columns {
            if let scroll = column.enclosingScrollView {
                scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MOKUSEI_GIT_ARTIFACTS"] ?? "/tmp/mokusei-git-visual")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        hosting.layoutSubtreeIfNeeded()
        let image = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: image)
        let data = try #require(image.representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent("git-\(dark ? "dark" : "light")-\(Int(width)).png"))
    }
}
