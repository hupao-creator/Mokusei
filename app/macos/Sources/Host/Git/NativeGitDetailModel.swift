import Foundation
import Observation
import MokuseiCore
import MokuseiPluginAPI

struct NativeGitDetailIdentity: Hashable {
    let reference: ApplicationThreadRef
    let root: JSONText
    let lifetime: ObjectIdentifier
    @MainActor init(_ props: NativeGitDetailProps) {
        reference = props.entry.ref; root = props.entry.view.snapshot.root; lifetime = ObjectIdentifier(props.context.lifetime)
    }
}

struct NativeGitLoadedDiff {
    let selection: NativeGitDiffSelection
    let patch: JSONText?
    let document: NativeGitParsedDiff?
    let notice: NativeGitDiffNotice?
    var error: String?
}

/// Narrow resources retain the last successful file/diff read while refreshes
/// run. A changed selection or owner fences every later completion.
@MainActor @Observable
final class NativeGitDetailModel {
    let identity: NativeGitDetailIdentity
    private(set) var scope: NativeGitDiffScope = .unstaged
    private(set) var selectedPath: JSONText?
    private(set) var files: [NativeGitChangedFile]?
    private(set) var repositories: [NativeGitRepository] = []
    private(set) var isRefreshing = false
    private(set) var filesError: String?
    private(set) var diff: NativeGitLoadedDiff?
    private(set) var closed = false
    @ObservationIgnored private var context: ApplicationRendererContext
    @ObservationIgnored private var knownSnapshot: NativeGitView
    @ObservationIgnored private var visible = true
    @ObservationIgnored private var queuedRefresh = false
    @ObservationIgnored private var pending: [UUID: NativeGitRead] = [:]
    @ObservationIgnored private var fileRequest: NativeGitRead?
    @ObservationIgnored private var diffRequest: NativeGitRead?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var parentCancellation: UUID?

    init(props: NativeGitDetailProps) {
        identity = NativeGitDetailIdentity(props); context = props.context; knownSnapshot = props.entry.view
    }
    var visibleFiles: [NativeGitChangedFile] { files?.filter { $0.scope == scope } ?? [] }
    var selection: NativeGitDiffSelection? {
        guard let selectedPath else { return nil }
        return .init(activityID: identity.reference.threadID, path: selectedPath, scope: scope)
    }
    var loadedDiff: NativeGitLoadedDiff? { diff?.selection == selection ? diff : nil }

    func start() {
        guard timer == nil, !closed, !context.lifetime.isCancelled else { return }
        parentCancellation = context.lifetime.onCancel { [weak self] in self?.close() }
        refresh()
        timer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard let self, !closed else { return }
                if visible { refresh() }
            }
        }
    }
    func update(_ props: NativeGitDetailProps) {
        guard NativeGitDetailIdentity(props) == identity, !closed else { return }
        context = props.context
        if props.entry.view.snapshot != knownSnapshot.snapshot || props.entry.view.available != knownSnapshot.available { refresh() }
        knownSnapshot = props.entry.view
    }
    func setVisible(_ value: Bool) {
        guard visible != value else { return }
        visible = value
        if value { refresh() }
    }
    func select(scope: NativeGitDiffScope) {
        guard !closed, self.scope != scope else { return }
        self.scope = scope; selectedPath = nil
        reconcileSelection()
    }
    func select(path: JSONText) {
        guard !closed, path != selectedPath, visibleFiles.contains(where: { $0.path == path }) else { return }
        selectedPath = path; beginDiff()
    }
    func refresh() {
        guard !closed, !context.lifetime.isCancelled else { return }
        queuedRefresh = true; drainRefresh()
    }
    func close() {
        guard !closed else { return }
        closed = true; queuedRefresh = false
        timer?.cancel(); timer = nil
        if let parentCancellation { context.lifetime.removeHandler(parentCancellation); self.parentCancellation = nil }
        for request in pending.values { request.cancel() }
        pending.removeAll(); fileRequest = nil; diffRequest = nil
    }

    private func drainRefresh() {
        guard !closed, visible, !context.lifetime.isCancelled, queuedRefresh, pending.isEmpty else { return }
        queuedRefresh = false
        beginFiles()
        if selection != nil { beginDiff() }
    }
    private func beginFiles() {
        cancel(fileRequest)
        let request = NativeGitRead(); fileRequest = request; pending[request.id] = request
        isRefreshing = true
        let domain = context.domain, activityID = identity.reference.threadID
        request.task = Task { @MainActor [weak self] in
            do {
                var all: [NativeGitRepository] = []
                var cursor: JSONText?
                repeat {
                    let page = try await domain.query(NativeGitContracts.repositories, input: cursor, lifetime: request.lifetime)
                    all.append(contentsOf: page.repositories); cursor = page.nextCursor
                } while cursor != nil
                guard let self, current(request, file: true) else { return }
                repositories = all
                let result = try await domain.query(NativeGitContracts.files, input: activityID, lifetime: request.lifetime)
                guard current(request, file: true) else { return }
                if files == nil, !result.files.contains(where: { $0.scope == scope }), let first = result.files.first {
                    scope = first.scope
                }
                if files != result.files { files = result.files }
                filesError = nil
                reconcileSelection()
            } catch {
                if let self, current(request, file: true) { filesError = error.localizedDescription }
            }
            self?.finish(request, file: true)
        }
    }
    private func reconcileSelection() {
        let next = visibleFiles.first(where: { $0.path == selectedPath })?.path ?? visibleFiles.first?.path
        if selectedPath != next {
            selectedPath = next
            beginDiff()
        } else if selection != nil, loadedDiff == nil, diffRequest == nil { beginDiff() }
        else if selection == nil { cancel(diffRequest); diffRequest = nil }
    }
    private func beginDiff() {
        cancel(diffRequest); diffRequest = nil
        guard !closed, let selected = selection else { return }
        let request = NativeGitRead(); diffRequest = request; pending[request.id] = request
        let domain = context.domain
        request.task = Task { @MainActor [weak self] in
            do {
                let result = try await domain.query(NativeGitContracts.diff, input: selected, lifetime: request.lifetime)
                guard let self, current(request, file: false), selection == selected else { return }
                let previous = loadedDiff
                if previous?.patch == result.patch,
                   result.notice != nil ? previous?.notice == result.notice : previous?.document != nil || previous?.notice == .empty || previous?.notice == .tooLarge {
                    if previous?.error != nil { diff?.error = nil }
                } else if let notice = result.notice {
                    diff = .init(selection: selected, patch: result.patch, document: nil, notice: notice, error: nil)
                } else {
                    let document: NativeGitParsedDiff
                    try request.lifetime.checkCancellation()
                    do { document = try await parseGitPatch(result.patch) }
                    catch is GitDisplayLimitError {
                        guard current(request, file: false), selection == selected else { return }
                        diff = .init(selection: selected, patch: result.patch, document: nil, notice: .tooLarge, error: nil)
                        finish(request, file: false)
                        return
                    }
                    catch is CancellationError { throw CancellationError() }
                    catch { throw GitParseFailure() }
                    guard current(request, file: false), selection == selected else { return }
                    diff = .init(selection: selected, patch: result.patch,
                                 document: document.isEmpty ? nil : document, notice: document.isEmpty ? .empty : nil, error: nil)
                }
            } catch {
                if let self, current(request, file: false), selection == selected {
                    let message = error is GitParseFailure ? "parse" : error.localizedDescription
                    if loadedDiff?.document != nil || loadedDiff?.notice != nil { diff?.error = message }
                    else { diff = .init(selection: selected, patch: nil, document: nil, notice: nil, error: message) }
                }
            }
            self?.finish(request, file: false)
        }
    }
    private func current(_ request: NativeGitRead, file: Bool) -> Bool {
        !closed && !context.lifetime.isCancelled && !request.lifetime.isCancelled
            && (file ? fileRequest?.id : diffRequest?.id) == request.id
    }
    private func cancel(_ request: NativeGitRead?) {
        guard let request else { return }; request.cancel(); pending[request.id] = nil
        Task { @MainActor [weak self] in await Task.yield(); self?.drainRefresh() }
    }
    private func finish(_ request: NativeGitRead, file: Bool) {
        pending[request.id] = nil
        if file, fileRequest?.id == request.id { fileRequest = nil; isRefreshing = false }
        if !file, diffRequest?.id == request.id { diffRequest = nil }
        Task { @MainActor [weak self] in await Task.yield(); self?.drainRefresh() }
    }
}

@MainActor private final class NativeGitRead {
    let id = UUID()
    let lifetime = PluginLifetime()
    var task: Task<Void, Never>?
    func cancel() { lifetime.cancel(); task?.cancel(); task = nil }
}
private struct GitParseFailure: Error {}

private func parseGitPatch(_ patch: JSONText) async throws -> NativeGitParsedDiff {
    try await withThrowingTaskGroup(of: NativeGitParsedDiff.self) { group in
        group.addTask { try NativeGitParsedDiff.parse(patch) }
        group.addTask { try await Task.sleep(for: .seconds(10)); throw GitParseFailure() }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw CancellationError() }
        return result
    }
}
