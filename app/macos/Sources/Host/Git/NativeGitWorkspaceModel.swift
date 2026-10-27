import Foundation
import Observation
import MokuseiCore
import MokuseiPluginAPI

/// Only current execution directories are supplied by the runtime. This cache never
/// resolves paths itself or infers membership from directory-name prefixes.
@MainActor @Observable
final class NativeGitWorkspaceModel {
    private(set) var repositories: [NativeGitRepository] = []
    private(set) var error: String?
    @ObservationIgnored private unowned let host: NativeApplicationHost
    @ObservationIgnored private let lifetime = PluginLifetime()
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var byDirectory: [JSONText: NativeGitRepository] = [:]
    init(host: NativeApplicationHost) { self.host = host }
    func repository(_ id: JSONText) -> NativeGitRepository? { repositories.first { $0.id == id } }
    func status(thread: HarnessThread) -> HarnessGitStatus? {
        let cwd: JSONText
        if let worktree = thread.worktree, worktree != .null {
            guard case .string(let path)? = worktree["cwd"], !path.codeUnits.isEmpty else { return nil }
            cwd = path
        } else { cwd = thread.cwd }
        guard let repository = byDirectory[cwd], repository.available else { return nil }
        let view = repository.view, s = view.snapshot
        let result = HarnessGitStatus(id: repository.id, root: s.root, branch: s.branch, head: s.head,
            upstream: s.upstream, ahead: s.ahead, behind: s.behind, changed: s.changed,
            staged: s.staged, unstaged: s.unstaged, untracked: s.untracked, conflicts: s.conflicts,
            additions: s.additions, deletions: s.deletions, lineStatsError: s.lineStatsError,
            error: error ?? view.sync.error?.rawValue, observedAt: view.sync.observedAt)
        return result.isActive ? result : nil
    }
    /// Install one complete metadata read before notifying the overview.
    @discardableResult func install(_ next: [NativeGitRepository]) -> Bool {
        guard next != repositories || error != nil else { return false }
        repositories = next; error = nil
        byDirectory = [:]
        for repository in next { for cwd in repository.directories { byDirectory[cwd] = repository } }
        return true
    }
    func start(onChange: @escaping () -> Void) {
        guard timer == nil else { return }
        timer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    let domain = try host.domain(pluginID: "git", viewLifetime: lifetime)
                    var next: [NativeGitRepository] = [], cursor: JSONText?
                    repeat {
                        let page = try await domain.query(NativeGitContracts.repositories, input: cursor, lifetime: lifetime)
                        next += page.repositories; cursor = page.nextCursor
                    } while cursor != nil
                    try lifetime.checkCancellation()
                    if install(next) { onChange() }
                } catch {
                    guard !Task.isCancelled, !lifetime.isCancelled else { return }
                    if self.error == nil { self.error = "inaccessible"; onChange() }
                }
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }
    func stop() { lifetime.cancel(); timer?.cancel(); timer = nil }
}
