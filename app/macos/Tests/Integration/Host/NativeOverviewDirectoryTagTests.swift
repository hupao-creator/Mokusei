import Darwin
import Foundation
import Testing
@testable import MokuseiUI

private struct DirectoryTagParityFixture: Decodable {
    struct Case: Decodable {
        let name: String
        let directories: [String]?
        let files: [String: String]?
        let cwd: String
        let relative: Bool?
        let want: String
    }
    let version: Int
    let cases: [Case]
}

/// Directory labels must attribute linked worktrees to their owning repository
/// instead of leaking the private worktree directory name.
@Suite struct NativeOverviewDirectoryTagTests {
    private func temporaryRoot() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("directorytag-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test func linkedWorktreeUsesRepositoryTag() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let main = root.appendingPathComponent("Mokusei")
        let worktree = root.appendingPathComponent(".Mokusei-mokusei-worktrees")
            .appendingPathComponent("task-fd71335e-bfa-1c13e467e2e6e0adf36974155175c5fb")
        let gitdir = main.appendingPathComponent(".git/worktrees/task-fd71335e-bfa")
        try write("../..\n", to: gitdir.appendingPathComponent("commondir"))
        try write("gitdir: \(gitdir.path)\n", to: worktree.appendingPathComponent(".git"))
        #expect(NativeOverviewSelection.directoryTag(cwd: worktree.path) == "Mokusei")
        let nested = worktree.appendingPathComponent("internal/core/runtime")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        #expect(NativeOverviewSelection.directoryTag(cwd: nested.path) == "Mokusei")
    }

    @Test func plainGitWorktreeUsesRepositoryTag() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let main = root.appendingPathComponent("PlainRepo")
        let worktree = root.appendingPathComponent("plain-checkout")
        let gitdir = main.appendingPathComponent(".git/worktrees/plain-checkout")
        try write("../..\n", to: gitdir.appendingPathComponent("commondir"))
        try write("gitdir: \(gitdir.path)\n", to: worktree.appendingPathComponent(".git"))
        #expect(NativeOverviewSelection.directoryTag(cwd: worktree.path) == "PlainRepo")
    }

    @Test func managedConventionFallsBackWithoutMetadata() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let worktree = root.appendingPathComponent(".FallbackRepo-mokusei-worktrees")
            .appendingPathComponent("task-abcdef012345")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        #expect(NativeOverviewSelection.directoryTag(cwd: worktree.path) == "FallbackRepo")
    }

    @Test func differentRepositoriesStayDistinct() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["RepoA", "RepoB"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name).appendingPathComponent(".git"),
                                                    withIntermediateDirectories: true)
        }
        #expect(NativeOverviewSelection.directoryTag(cwd: root.appendingPathComponent("RepoA").path) == "RepoA")
        #expect(NativeOverviewSelection.directoryTag(cwd: root.appendingPathComponent("RepoB").path) == "RepoB")
    }

    @Test func existingTaskNamedDirectoryKeepsTag() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let name = "task-fd71335e-bfa-1c13e467e2e6e0adf36974155175c5fb"
        let directory = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #expect(NativeOverviewSelection.directoryTag(cwd: directory.path) == name)
    }

    @Test func vanishedGeneratedTaskHasNoTag() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("task-fd71335e-bfa-1c13e467e2e6e0adf36974155175c5fb")
        #expect(NativeOverviewSelection.directoryTag(cwd: missing.path) == "")
    }

    @Test func unreadableGeneratedTaskKeepsTag() throws {
        guard geteuid() != 0 else { return }
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("locked")
        let name = "task-fd71335e-bfa-1c13e467e2e6e0adf36974155175c5fb"
        let directory = parent.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { _ = chmod(parent.path, 0o700) }
        guard chmod(parent.path, 0) == 0 else { return }
        #expect(NativeOverviewSelection.directoryTag(cwd: directory.path) == name)
    }

    @Test func ordinarySubdirectoryKeepsBasename() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = root.appendingPathComponent("Repo")
        let subdirectory = repository.appendingPathComponent("app")
        try FileManager.default.createDirectory(at: repository.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
        #expect(NativeOverviewSelection.directoryTag(cwd: subdirectory.path) == "app")
    }

    /// The same corpus drives the Go resolver, so the two metadata-only twins
    /// cannot drift on submodules, separate git directories or false positives.
    @Test func sharedParityFixtureCorpus() throws {
        let corpus = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // NativeOverviewDirectoryTagTests.swift
            .deletingLastPathComponent() // Host
            .deletingLastPathComponent() // Integration
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // macos
            .deletingLastPathComponent() // app
            .appendingPathComponent("testdata/directorytag/parity.json")
        let fixture = try JSONDecoder().decode(DirectoryTagParityFixture.self, from: Data(contentsOf: corpus))
        #expect(fixture.version == 1 && !fixture.cases.isEmpty)
        let working = FileManager.default.currentDirectoryPath
        for item in fixture.cases {
            let root = try temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            for directory in item.directories ?? [] {
                let path = fixturePath(directory, root: root)
                try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            }
            for (path, contents) in item.files ?? [:] {
                let full = fixturePath(path, root: root)
                try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent,
                                                        withIntermediateDirectories: true)
                try expand(contents, root: root).write(toFile: full, atomically: true, encoding: .utf8)
            }
            let target = expand(item.cwd, root: root)
            let cwd = item.relative == true ? relativePath(from: working, to: target) : target
            #expect(NativeOverviewSelection.directoryTag(cwd: cwd) == item.want,
                    "fixture \(item.name): \(cwd)")
        }
    }

    private func expand(_ value: String, root: URL) -> String {
        value.replacingOccurrences(of: "$ROOT", with: root.path)
    }

    private func fixturePath(_ value: String, root: URL) -> String {
        let path = expand(value, root: root)
        return path.hasPrefix("/") ? path : root.appendingPathComponent(path).path
    }

    private func relativePath(from base: String, to target: String) -> String {
        let baseParts = URL(fileURLWithPath: base).standardizedFileURL.pathComponents
        let targetParts = URL(fileURLWithPath: target).standardizedFileURL.pathComponents
        var common = 0
        while common < baseParts.count, common < targetParts.count, baseParts[common] == targetParts[common] {
            common += 1
        }
        let up = Array(repeating: "..", count: baseParts.count - common)
        return (up + Array(targetParts[common...])).joined(separator: "/")
    }
}

extension NativeOverviewDirectoryTagTests {
    private func canonical(_ path: String) -> String {
        if let resolved = path.withCString({ realpath($0, nil) }) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    @Test func scopeFoldsLinkedWorktreeOntoRepositoryRoot() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let main = root.appendingPathComponent("Mokusei")
        let worktree = root.appendingPathComponent(".Mokusei-mokusei-worktrees")
            .appendingPathComponent("task-fd71335e-bfa-1c13e467e2e6e0adf36974155175c5fb")
        let gitdir = main.appendingPathComponent(".git/worktrees/task-fd71335e-bfa")
        try write("../..\n", to: gitdir.appendingPathComponent("commondir"))
        try write("gitdir: \(gitdir.path)\n", to: worktree.appendingPathComponent(".git"))
        #expect(NativeOverviewSelection.scope(cwd: worktree.path) == canonical(main.path))
        let nested = worktree.appendingPathComponent("internal/core/runtime")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        #expect(NativeOverviewSelection.scope(cwd: nested.path) == canonical(main.path))
    }

    @Test func scopeKeepsOrdinaryDirectoriesAndSubdirectories() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = root.appendingPathComponent("Repo")
        let subdirectory = repository.appendingPathComponent("app")
        try FileManager.default.createDirectory(at: repository.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
        #expect(NativeOverviewSelection.scope(cwd: repository.path) == canonical(repository.path))
        #expect(NativeOverviewSelection.scope(cwd: subdirectory.path) == canonical(subdirectory.path))
    }

    @Test func scopeUsesInboxForEmptyAndTemporaryPaths() {
        #expect(NativeOverviewSelection.scope(cwd: "") == NativeOverviewSelection.inboxScope)
        #expect(NativeOverviewSelection.scope(cwd: "/tmp/mokusei-scope-fixture") == NativeOverviewSelection.inboxScope)
    }

    @Test func scopeDistinguishesSameNamedDirectories() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("one/Mokusei")
        let second = root.appendingPathComponent("two/Mokusei")
        for path in [first, second] {
            try FileManager.default.createDirectory(at: path.appendingPathComponent(".git"), withIntermediateDirectories: true)
        }
        #expect(NativeOverviewSelection.scope(cwd: first.path) != NativeOverviewSelection.scope(cwd: second.path))
    }
}
