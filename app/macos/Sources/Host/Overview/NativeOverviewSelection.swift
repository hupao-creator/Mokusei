import Darwin
import Foundation
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI

public struct NativeOverviewTagSelection: Equatable, Sendable {
    public let tag: String
    public let kind: NativeOverviewTagKind
    public let scope: String
    public init(tag: String, kind: NativeOverviewTagKind, scope: String = "") {
        self.tag = tag; self.kind = kind; self.scope = scope
    }
}

/// Only the host's documented mokusei.overview presentation is interpreted here.
/// Application view/session values remain opaque and are decoded by their plugin.
struct NativeOverviewApplicationEntry {
    let entry: ApplicationThreadCatalogEntry<JSONValue>
    let visible: Bool
    let directoryOnly: Bool
    let coveredExecutions: [ApplicationExecutionRef]
    init(json: JSONValue) throws {
        try self.init(entry: .init(json: json))
    }
    init(entry: ApplicationThreadCatalogEntry<JSONValue>) throws {
        self.entry = entry
        guard let presentation = entry.presentations.first(where: { $0.id == JSONText("mokusei.overview") }) else {
            visible = true; directoryOnly = false; coveredExecutions = []; return
        }
        guard presentation.apiVersion == 1, presentation.schemaVersion == 1,
              let covers = presentation.value["coversExecutions"]?.arrayValue else {
            throw PluginContractError("Incompatible mokusei.overview presentation")
        }
        if let value = presentation.value["visible"], value.boolValue == nil { throw PluginContractError("Invalid overview visibility") }
        if let value = presentation.value["tagFilter"], value.stringValue != "directory" { throw PluginContractError("Invalid overview tag filter") }
        visible = presentation.value["visible"]?.boolValue ?? true
        directoryOnly = presentation.value["tagFilter"]?.stringValue == "directory"
        coveredExecutions = try covers.map { value in
            guard case let .string(threadID) = value["thread"]?["threadId"],
                  case let .string(typeID) = value["thread"]?["typeId"],
                  case let .string(executionID) = value["executionId"] else { throw PluginContractError("Invalid overview execution reference") }
            return .init(thread: .init(threadID: threadID, typeID: typeID), executionID: executionID)
        }
    }
}

struct NativeOverviewCollection {
    let threads: [HarnessThread]
    let applications: [NativeOverviewApplicationEntry]
    var count: Int { threads.count + applications.count }
}

/// Directory labels depend only on cwd. Keep exact wire identities as keys,
/// and retain only paths present in the current catalog (including archives).
struct NativeOverviewDirectoryTagCache {
    private(set) var values: [JSONText: String] = [:]

    mutating func update(threads: [HarnessThread]) {
        var next: [JSONText: String] = [:]
        for thread in threads where next[thread.cwd] == nil {
            // Host projections include scope even for an empty display label.
            // Refresh their metadata rather than retaining a client-derived
            // value after the host changes its repository/worktree layout.
            next[thread.cwd] = thread.directoryScope.codeUnits.isEmpty
                ? values[thread.cwd] ?? NativeOverviewSelection.directoryTag(thread)
                : thread.directoryTag.string
        }
        values = next
    }

    mutating func removeAll() { values.removeAll() }
}

enum NativeOverviewSelection {
    static func key(_ text: String) -> String {
        let normalized = text.precomposedStringWithCompatibilityMapping.localizedLowercase
        return normalized.unicodeScalars.split(whereSeparator: { isJSWhitespace($0.value) })
            .map { String(String.UnicodeScalarView($0)) }.joined(separator: " ")
    }
    static func trim(_ text: String) -> String {
        let scalars = text.unicodeScalars
        var lower = scalars.startIndex
        var upper = scalars.endIndex
        while lower < upper, isJSWhitespace(scalars[lower].value) { scalars.formIndex(after: &lower) }
        while lower < upper {
            let previous = scalars.index(before: upper)
            guard isJSWhitespace(scalars[previous].value) else { break }
            upper = previous
        }
        if lower == scalars.startIndex, upper == scalars.endIndex { return text }
        return String(scalars[lower..<upper])
    }
    private static func isJSWhitespace(_ value: UInt32) -> Bool {
        switch value {
        case 0x9...0xD, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: true
        default: false
        }
    }
    static func directoryTag(_ thread: HarnessThread) -> String {
        thread.directoryScope.codeUnits.isEmpty ? directoryTag(cwd: thread.cwd.string) : thread.directoryTag.string
    }
    static func directoryTag(cwd raw: String) -> String {
        let cwd = trim(raw)
            .replacingOccurrences(of: #"[\\/]+$"#, with: "", options: .regularExpression)
        let normalized = cwd.replacingOccurrences(of: "\\", with: "/")
        guard !cwd.isEmpty, !MokuseiWorkspacePath.isTemporary(normalized) else { return "" }
        let repository = repositoryTag(normalized)
        if let tag = repository.tag { return tag }
        let parts = normalized.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let base = parts.last else { return "" }
        if !repository.found || generatedTaskName(base), let managed = managedWorktreeName(normalized) { return managed }
        if generatedTaskName(base), pathIsMissing(cwd) { return "" }
        return base
    }
    /// Resolves the Mokusei staging convention. Nested repositories include
    /// the relative slug, so prefer an existing sibling repository to avoid a
    /// second chip for the same repository. Prefix-sharing repositories make
    /// stripping at every dash ambiguous; only worktree metadata can settle
    /// that, otherwise the un-stripped slug is kept.
    private static func managedWorktreeName(_ path: String) -> String? {
        let suffix = "-mokusei-worktrees"
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        for (index, part) in parts.enumerated() {
            guard part.hasPrefix("."), part.hasSuffix(suffix) else { continue }
            let name = String(part.dropFirst().dropLast(suffix.count))
            guard !name.isEmpty else { continue }
            var parentParts = Array(parts.prefix(index))
            if parentParts == [""] { parentParts = [] }
            let parent = parentParts.isEmpty ? (path.hasPrefix("/") ? "/" : ".") : parentParts.joined(separator: "/")
            return siblingRepository(parent: parent, name: name, worktree: path)
        }
        return nil
    }
    private static func siblingRepository(parent: String, name: String, worktree: String) -> String? {
        if looksLikeRepository(repositoryPath(parent: parent, name: name)) { return name }
        var candidates: [String] = []
        var candidate = name
        while let index = candidate.lastIndex(of: "-"), index != candidate.startIndex {
            candidate = String(candidate[..<index])
            if looksLikeRepository(repositoryPath(parent: parent, name: candidate)) {
                candidates.append(candidate)
            }
        }
        if candidates.count == 1 { return candidates[0] }
        if candidates.count > 1 {
            if let owner = corroboratedOwner(parent: parent, worktree: worktree, candidates: candidates),
               candidates.contains(owner) {
                return owner
            }
            return name
        }
        return name
    }
    /// Reads the worktree's gitdir pointer and accepts a candidate whose .git
    /// directory owns it. A missing or corrupt pointer yields no owner.
    private static func corroboratedOwner(parent: String, worktree: String, candidates: [String]) -> String? {
        guard let gitdir = gitDirectoryPointer((worktree as NSString).appendingPathComponent(".git")) else { return nil }
        let normalizedGitdir = URL(fileURLWithPath: gitdir).standardizedFileURL.path
        for candidate in candidates {
            let git = URL(fileURLWithPath: repositoryPath(parent: parent, name: candidate) + "/.git").standardizedFileURL.path
            if normalizedGitdir == git || normalizedGitdir.hasPrefix(git + "/") { return candidate }
        }
        return nil
    }
    private static func repositoryPath(parent: String, name: String) -> String {
        parent == "/" ? "/" + name : (parent as NSString).appendingPathComponent(name)
    }
    private static func looksLikeRepository(_ path: String) -> Bool {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: (path as NSString).appendingPathComponent(".git")) { return true }
        return fileManager.fileExists(atPath: (path as NSString).appendingPathComponent("HEAD")) &&
            fileManager.fileExists(atPath: (path as NSString).appendingPathComponent("config"))
    }
    private static func pathIsMissing(_ path: String) -> Bool {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: path)
            return false
        } catch let error as NSError {
            let missing = [CocoaError.Code.fileNoSuchFile.rawValue, CocoaError.Code.fileReadNoSuchFile.rawValue]
            return error.domain == NSCocoaErrorDomain && missing.contains(error.code)
        }
    }
    private static func generatedTaskName(_ name: String) -> Bool {
        name.range(of: #"^task-([0-9a-f]{12}|[0-9a-f]{8}-[0-9a-f]{3}(-[0-9a-f]{32})?|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }
    /// Resolves a working directory inside a linked worktree to its owning
    /// repository. Ordinary repositories and their subdirectories return nil so
    /// the caller keeps the cwd basename. The check is metadata-only: no Git
    /// process is spawned.
    private static func repositoryTag(_ path: String) -> (tag: String?, found: Bool) {
        var directory = URL(fileURLWithPath: path).standardizedFileURL.path
        while true {
            let dotGit = (directory as NSString).appendingPathComponent(".git")
            var directoryFlag: ObjCBool = false
            if FileManager.default.fileExists(atPath: dotGit, isDirectory: &directoryFlag) {
                if directoryFlag.boolValue { return (nil, true) }
                return (linkedWorktreeTag(dotGit: dotGit, checkout: directory), true)
            }
            let parent = (directory as NSString).deletingLastPathComponent
            if parent.isEmpty || parent == directory { return (nil, false) }
            directory = parent
        }
    }
    /// A genuine linked worktree records a commondir that resolves to a real
    /// Git directory. Submodule pointers and separate-git-dir main checkouts do
    /// not, so they are treated as plain pointers and keep their own name.
    private static func linkedWorktreeTag(dotGit: String, checkout: String) -> String? {
        guard let gitdir = gitDirectoryPointer(dotGit),
              let data = FileManager.default.contents(atPath: (gitdir as NSString).appendingPathComponent("commondir")),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let common = URL(fileURLWithPath: value.hasPrefix("/") ? value
                         : (gitdir as NSString).appendingPathComponent(value)).standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard common != gitdir,
              FileManager.default.fileExists(atPath: common, isDirectory: &isDirectory), isDirectory.boolValue,
              isGitDirectory(common) else { return nil }
        if (common as NSString).lastPathComponent == ".git" {
            return ((common as NSString).deletingLastPathComponent as NSString).lastPathComponent
        }
        if let root = coreWorktree(common) { return (root as NSString).lastPathComponent }
        if let managed = managedWorktreeName(checkout.replacingOccurrences(of: "\\", with: "/")) { return managed }
        return (checkout as NSString).lastPathComponent
    }
    private static func gitDirectoryPointer(_ dotGit: String) -> String? {
        guard let data = FileManager.default.contents(atPath: dotGit),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let pointer = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard pointer.lowercased().hasPrefix("gitdir:") else { return nil }
        var target = String(pointer.dropFirst("gitdir:".count)).trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return nil }
        if !target.hasPrefix("/") {
            target = ((dotGit as NSString).deletingLastPathComponent as NSString).appendingPathComponent(target)
        }
        return URL(fileURLWithPath: target).standardizedFileURL.path
    }
    private static func isGitDirectory(_ path: String) -> Bool {
        if (path as NSString).lastPathComponent == ".git" { return true }
        let fileManager = FileManager.default
        return fileManager.fileExists(atPath: (path as NSString).appendingPathComponent("HEAD")) &&
            fileManager.fileExists(atPath: (path as NSString).appendingPathComponent("config"))
    }
    /// Reads core.worktree from a Git directory's config so separate-git-dir
    /// checkouts use the real checkout rather than the storage directory.
    private static func coreWorktree(_ common: String) -> String? {
        guard let data = FileManager.default.contents(atPath: (common as NSString).appendingPathComponent("config")),
              let text = String(data: data, encoding: .utf8) else { return nil }
        var section = ""
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if let index = section.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "\"" }) {
                    section = String(section[..<index])
                }
                continue
            }
            guard section == "core", let equals = line.firstIndex(of: "=") else { continue }
            guard line[..<equals].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "worktree" else { continue }
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            guard !value.isEmpty else { return nil }
            if !value.hasPrefix("/") { value = (common as NSString).appendingPathComponent(value) }
            return URL(fileURLWithPath: value).standardizedFileURL.path
        }
        return nil
    }
    static let inboxScope = "inbox"

    /// Stable scope identity matching the Go directorytag.Scope contract.
    /// Linked worktrees fold onto the owning repository root; ordinary
    /// directories and subdirectories keep their canonical path. Temporary and
    /// empty paths share the inbox scope.
    // NSCache is thread-safe; the annotation only silences Sendable checking.
    nonisolated(unsafe) private static let scopeCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 4096
        return cache
    }()
    static func scope(_ thread: HarnessThread) -> String {
        thread.directoryScope.codeUnits.isEmpty ? scope(cwd: thread.cwd.string) : thread.directoryScope.string
    }
    static func scope(cwd raw: String) -> String {
        let cwd = trim(raw).replacingOccurrences(of: #"[\\/]+$"#, with: "", options: .regularExpression)
        let normalized = cwd.replacingOccurrences(of: "\\", with: "/")
        guard !cwd.isEmpty, !MokuseiWorkspacePath.isTemporary(normalized) else { return inboxScope }
        if let cached = scopeCache.object(forKey: normalized as NSString) { return cached as String }
        let (resolved, exists) = canonicalPath(cwd)
        // Foundation's resolvingSymlinksInPath strips the /private prefix from
        // /tmp and /var, while Go's EvalSymlinks preserves it. Use realpath so
        // both languages derive the same scope identity.
        let scope = linkedWorktreeRoot(resolved) ?? resolved
        // Only cache a path that resolved on disk; a missing directory may
        // later appear with different symlink or worktree metadata.
        if exists { scopeCache.setObject(scope as NSString, forKey: normalized as NSString) }
        return scope
    }
    private static func canonicalPath(_ path: String) -> (path: String, exists: Bool) {
        if let resolved = path.withCString({ realpath($0, nil) }) {
            defer { free(resolved) }
            return (String(cString: resolved), true)
        }
        return (URL(fileURLWithPath: path).standardizedFileURL.path, false)
    }
    private static func linkedWorktreeRoot(_ checkout: String) -> String? {
        var directory = canonicalPath(checkout).path
        while true {
            let dotGit = (directory as NSString).appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDirectory) {
                if isDirectory.boolValue { return nil }
                guard let gitdir = gitDirectoryPointer(dotGit),
                      let data = FileManager.default.contents(atPath: (gitdir as NSString).appendingPathComponent("commondir")),
                      let text = String(data: data, encoding: .utf8) else { return nil }
                let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { return nil }
                let common = URL(fileURLWithPath: value.hasPrefix("/") ? value
                                 : (gitdir as NSString).appendingPathComponent(value))
                    .standardizedFileURL.path
                var commonIsDirectory: ObjCBool = false
                guard common != gitdir,
                      FileManager.default.fileExists(atPath: common, isDirectory: &commonIsDirectory), commonIsDirectory.boolValue,
                      isGitDirectory(common) else { return nil }
                if (common as NSString).lastPathComponent == ".git" {
                    let root = (common as NSString).deletingLastPathComponent
                    return canonicalPath(root).path
                }
                if let root = coreWorktree(common) {
                    return canonicalPath(root).path
                }
                return nil
            }
            let parent = (directory as NSString).deletingLastPathComponent
            if parent.isEmpty || parent == directory { return nil }
            directory = parent
        }
    }

    static func resolve(_ selection: NativeOverviewTagSelection?, redirects: JSONValue,
                        directoryTags: [String]) -> NativeOverviewTagSelection? {
        guard let selection, let redirects = redirects.objectValue else { return selection }
        let directory = directoryTags.first { key($0) == key(selection.tag) }
        if selection.kind == .directory, directory != nil { return selection }
        var tag = selection.tag
        var seen = Set<String>()
        while true {
            let tagKey = key(tag)
            let scopedKey = selection.scope.isEmpty ? tagKey : selection.scope + "\u{0}" + tagKey
            guard let target = redirects[JSONText(scopedKey)] ?? redirects[JSONText(tagKey)] else { break }
            if !seen.insert(scopedKey).inserted { break }
            if target == .null { return directory.map { .init(tag: $0, kind: .directory, scope: selection.scope) } }
            guard let name = target.stringValue else { break }
            tag = name
        }
        return selection.kind == .directory || tag == selection.tag ? selection
            : .init(tag: tag, kind: selection.kind, scope: selection.scope)
    }
    static func candidates(threads: [HarnessThread], applications: [NativeOverviewApplicationEntry]) -> NativeOverviewCollection {
        .init(threads: threads.filter { !$0.isHiddenFromUser && $0.archived != true },
              applications: applications.filter { !$0.entry.archived && $0.visible })
    }
    static func select(threads: [HarnessThread], applications: [NativeOverviewApplicationEntry],
                       tags: [String] = [], kind: NativeOverviewTagKind? = nil, scope selectedScope: String? = nil,
                       merge: Bool = true,
                       directoryTags: [JSONText: String] = [:],
                       key: (String) -> String = NativeOverviewSelection.key) -> NativeOverviewCollection {
        let keys = Set(tags.map(key).filter { !$0.isEmpty })
        let available = candidates(threads: threads, applications: applications)
        let visibleApplications = available.applications.enumerated().filter { _, item in
            if let selectedScope {
                if let ownerScope = item.entry.scope?.string {
                    if ownerScope != selectedScope { return false }
                    if kind == .directory { return true }
                } else if selectedScope != inboxScope && kind != .directory { return false }
            }
            if item.directoryOnly {
                return kind == .directory && item.entry.tags.directoryTags.contains { keys.contains(key($0.string)) }
            }
            return keys.isEmpty || item.entry.tags.tags.contains { keys.contains(key($0.string)) }
        }.sorted { a, b in a.element.entry.createdAt == b.element.entry.createdAt ? a.offset < b.offset : a.element.entry.createdAt < b.element.entry.createdAt }.map(\.element)
        let visibleThreads = available.threads.enumerated().filter { _, thread in
            if let selectedScope, scope(thread) != selectedScope { return false }
            // A directory label is presentation, not membership: a symlink or
            // linked checkout can have another label within the same scope.
            let matchesDirectoryScope = kind == .directory && selectedScope != nil
            guard matchesDirectoryScope || keys.isEmpty || ([directoryTags[thread.cwd] ?? directoryTag(thread)] + thread.tags.map(\.string)).contains(where: { keys.contains(key($0)) }) else { return false }
            return !merge || !visibleApplications.contains { item in item.coveredExecutions.contains { link in
                link.thread.typeID == JSONText("agent") && link.thread.threadID == thread.id && link.executionID == thread.observation.latestExecution?.executionID
            } }
        }.sorted { a, b in a.element.createdAt == b.element.createdAt ? a.offset < b.offset : a.element.createdAt < b.element.createdAt }.map(\.element)
        return .init(threads: visibleThreads, applications: visibleApplications)
    }
    static func filters(_ collection: NativeOverviewCollection, directoryTags: [JSONText: String] = [:],
                        key: (String) -> String = NativeOverviewSelection.key) -> [NativeOverviewFilter] {
        struct TagGroup { var tag: String; var emoji: String; var members: Set<String> }
        struct ScopeGroup { var label: String; var members: Set<String>; var tags: [String: TagGroup] }
        var scopes: [String: ScopeGroup] = [:]
        for thread in collection.threads {
            let scopeID = scope(thread)
            let label = directoryTags[thread.cwd] ?? directoryTag(thread)
            var group = scopes[scopeID] ?? ScopeGroup(label: label, members: [], tags: [:])
            if group.label.isEmpty { group.label = label }
            group.members.insert("thread:\(thread.id.string)")
            for tag in thread.tags.map(\.string) {
                let normalized = key(tag)
                guard !normalized.isEmpty else { continue }
                var existing = group.tags[normalized] ?? TagGroup(tag: tag, emoji: thread.tagEmojis[JSONText(tag)]!.string, members: [])
                existing.members.insert("thread:\(thread.id.string)")
                group.tags[normalized] = existing
            }
            scopes[scopeID] = group
        }
        // Scoped documents retain their directory and semantic filters even
        // when every source task has been archived or deleted.
        for item in collection.applications {
            guard let scopeID = item.entry.scope?.string else { continue }
            let label = item.entry.tags.directoryTags.first?.string ?? ""
            var group = scopes[scopeID] ?? ScopeGroup(label: label, members: [], tags: [:])
            if group.label.isEmpty { group.label = label }
            let member = "application:\(item.entry.ref.threadID.string)"
            group.members.insert(member)
            for tag in item.entry.tags.semanticTags.map(\.string) {
                let normalized = key(tag)
                guard !normalized.isEmpty else { continue }
                var existing = group.tags[normalized] ?? TagGroup(tag: tag, emoji: item.entry.tags.tagEmojis[JSONText(tag)]!.string, members: [])
                existing.members.insert(member)
                group.tags[normalized] = existing
            }
            scopes[scopeID] = group
        }
        var top: [NativeOverviewFilter] = []
        for (scopeID, group) in scopes {
            let labelKey = key(group.label)
            let children = group.tags.values.filter { key($0.tag) != labelKey }.map { value in
                NativeOverviewFilter(tag: value.tag, displayTag: SemanticTagLabel.display(name: value.tag, emoji: value.emoji), emoji: value.emoji, scope: scopeID, count: value.members.count,
                                     isDirectory: false, selectionKey: "scope:\(scopeID):tag:\(key(value.tag))")
            }.sorted { a, b in a.count != b.count ? a.count > b.count : compare(a.tag, b.tag) == .orderedAscending }
            let limited = Array(children.prefix(5))
            if scopeID == inboxScope {
                top.append(contentsOf: limited)
            } else if !group.label.isEmpty {
                top.append(NativeOverviewFilter(tag: group.label, scope: scopeID, count: group.members.count,
                                                isDirectory: true, selectionKey: "scope:\(scopeID):all", children: limited))
            }
        }
        var labelCounts: [String: Int] = [:]
        for filter in top where filter.isDirectory {
            labelCounts[key(filter.tag), default: 0] += 1
        }
        for index in top.indices where top[index].isDirectory && (labelCounts[key(top[index].tag)] ?? 0) > 1 {
            let parent = (top[index].scope as NSString).deletingLastPathComponent
            let hint = (parent as NSString).lastPathComponent
            if !hint.isEmpty { top[index].displayTag = "\(top[index].tag) — \(hint)" }
        }
        return top.sorted { a, b in
            if a.count != b.count { return a.count > b.count }
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return compare(a.tag, b.tag) == .orderedAscending
        }
    }
    static func compare(_ a: String, _ b: String) -> ComparisonResult { a.compare(b, locale: .current) }
    static func jsonString(_ value: JSONValue) -> String { (try? String(decoding: value.encodedData(), as: UTF8.self)) ?? "" }
}
