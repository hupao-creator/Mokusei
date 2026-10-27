import Foundation
import MokuseiCore

public enum HarnessGitReadError: String, Sendable, CaseIterable {
    case unavailable, timeout, tooLarge = "too-large", inaccessible
}

/// Shared worktree observation supplied by the host to every Harness card.
public struct HarnessGitStatus: Hashable, Sendable {
    public let id: JSONText
    public let root: JSONText
    public let branch: JSONText?
    public let head: JSONText?
    public let upstream: JSONText?
    public let ahead: Int?
    public let behind: Int?
    public let additions: Int?
    public let deletions: Int?
    public let lineStatsError: HarnessGitReadError?
    public let changed: Int
    public let staged: Int
    public let unstaged: Int
    public let untracked: Int
    public let conflicts: Int
    public let error: String?
    public let observedAt: Double
    public init(id: JSONText, root: JSONText, branch: JSONText?, head: JSONText?, upstream: JSONText?,
                ahead: Int?, behind: Int?, changed: Int, staged: Int, unstaged: Int, untracked: Int,
                conflicts: Int, additions: Int? = nil, deletions: Int? = nil, lineStatsError: HarnessGitReadError? = nil,
                error: String? = nil, observedAt: Double = 0) {
        self.id = id; self.root = root; self.branch = branch; self.head = head; self.upstream = upstream
        self.ahead = ahead; self.behind = behind; self.changed = changed; self.staged = staged
        self.unstaged = unstaged; self.untracked = untracked; self.conflicts = conflicts
        self.additions = additions; self.deletions = deletions
        self.lineStatsError = lineStatsError
        self.error = error; self.observedAt = observedAt
    }
    /// `changed` counts unique paths across all file scopes, including conflicts.
    /// File-only changes remain visible even when net line counts are zero or unavailable.
    public var isActive: Bool { changed > 0 || (additions ?? 0) > 0 || (deletions ?? 0) > 0 }
}
