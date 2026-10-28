import Foundation
import Observation
import MokuseiCore
import MokuseiPluginAPI

/// Client-owned draft shared by the Dock and full Moku conversation. Keep this
/// object above those views; disappearing from one surface must not clear it.
@MainActor @Observable
public final class NativeComposerDraft {
    private final class WeakDraft { weak var value: NativeComposerDraft?; init(_ value: NativeComposerDraft) { self.value = value } }
    private final class AttachmentImport {
        var retired = false
        var attachments: [NativeComposerAttachment] = []
    }
    private static var owners: [WeakDraft] = []
    nonisolated public static let maximumAttachments = 20
    nonisolated public static let maximumDirectories = 50
    nonisolated public static let maximumClipboardBytes = 20 * 1024 * 1024
    public var text = "" { didSet { editRevision &+= 1; persist() } }
    public private(set) var directories: [NativeComposerDirectory] = [] { didSet { persist(semanticChange: directories != oldValue) } }
    public private(set) var attachments: [NativeComposerAttachment] = [] { didSet { persist(semanticChange: attachments != oldValue) } }
    public var importing: Bool { staging || pastePreparation != nil }
    private var staging = false
    private var pastePreparation: NativeComposerPastePreparation?
    public private(set) var submitting = false
    public private(set) var clearing = false
    public private(set) var error: String?
    public private(set) var isDisposed = false
    @ObservationIgnored private var editRevision: UInt64 = 0
    @ObservationIgnored private var activeImport: AttachmentImport?
    @ObservationIgnored private let lifetime = PluginLifetime()
    @ObservationIgnored private let services: NativeComposerServices
    @ObservationIgnored private let persistence: NativeComposerDraftPersistence?
    @ObservationIgnored private var restoring = false
    @ObservationIgnored private var savedRevision: String?
    @ObservationIgnored private var protectedAttachmentIDs: Set<JSONText> = []
    @ObservationIgnored private var retiredAttachmentIDs: Set<JSONText> = []
    @ObservationIgnored private var remoteDiscardEnabled = true
    @ObservationIgnored private var directoryRevisions: [JSONText: UUID] = [:]

    public init(services: NativeComposerServices, persistence: NativeComposerDraftPersistence? = nil) {
        self.services = services; self.persistence = persistence
        restoring = true
        do {
            if let saved = try persistence?.load() {
                text = saved.text; directories = saved.directories; attachments = saved.attachments
                savedRevision = saved.revision
                directoryRevisions = Dictionary(uniqueKeysWithValues: directories.map { ($0.path, UUID()) })
            }
        } catch { self.error = error.localizedDescription }
        restoring = false
        Self.owners.removeAll { $0.value == nil }
        Self.owners.append(WeakDraft(self))
        loadPreviews(attachments)
    }
    public var canSubmit: Bool {
        !isDisposed && !importing && !submitting && !clearing && NativeComposerSubmissionPolicy.canSubmit(text: text, attachments: attachments, directories: directories)
    }
    public func clearError() { error = nil }

    public var supportsHostFiles: Bool { services.hostDirectory != nil }
    public var canPreviewHostFiles: Bool { services.openHostFile != nil }
    public func openHostFile(_ reference: RuntimeHostFileReference) async throws {
        guard !isDisposed, let open = services.openHostFile else { throw PluginContractError("主机文件预览不可用") }
        try Task.checkCancellation(); try lifetime.checkCancellation()
        try await open(reference, lifetime)
        try Task.checkCancellation(); try lifetime.checkCancellation()
    }
    public func hostDirectory(_ reference: RuntimeHostFileReference? = nil) async throws -> RuntimeHostDirectory {
        guard !isDisposed, let browse = services.hostDirectory else { throw PluginContractError("主机文件选择不可用") }
        return try await browse(reference, lifetime)
    }
    public func chooseHostFiles(_ entries: [RuntimeHostFileEntry]) async {
        guard entries.allSatisfy({ !$0.isDirectory }) else { error = "请选择文件"; return }
        await importFiles(entries.map { .init(hostFile: $0.reference, name: $0.name, size: $0.size, mimeType: $0.mimeType) })
    }

    @discardableResult
    public func insertDirectory(_ directory: NativeComposerDirectory) -> Bool {
        guard !isDisposed, !directory.path.codeUnits.isEmpty else { return false }
        if directories.contains(where: { $0.path == directory.path }) { return true }
        guard directories.count < Self.maximumDirectories else { return false }
        directories.append(directory)
        directoryRevisions[directory.path] = UUID()
        return true
    }

    public func preparePaste() -> NativeComposerPastePreparation? {
        guard !isDisposed, !importing, !submitting, !clearing else { return nil }
        let preparation = NativeComposerPastePreparation()
        preparation.onFinish = { [weak self, weak preparation] in
            guard let self, self.pastePreparation === preparation else { return }
            self.pastePreparation = nil
        }
        pastePreparation = preparation
        return preparation
    }
    public func removeDirectory(_ path: JSONText) {
        directories.removeAll { $0.path == path }; directoryRevisions[path] = nil
    }

    public func removeAttachment(_ id: JSONText) async {
        let removed = attachments.filter { $0.id == id }.compactMap(\.attachment).map(\.id)
        attachments.removeAll { $0.id == id }
        await discard(removed)
    }

    /// Called on the main actor once a background preview decode finishes. Only
    /// a still-present, non-failed draft receives the preview; a removed chip or
    /// a failed import simply drops it (and its `Data`).
    func fillPreview(_ preview: NativeComposerPreview?, for id: JSONText) {
        guard !isDisposed else { return }
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        let draft = attachments[index]
        if case .failed = draft.status { return }
        guard draft.preview != preview else { return }
        attachments[index] = NativeComposerAttachment(id: draft.id, name: draft.name, status: draft.status, preview: preview)
    }

    public func chooseFiles(cwd: JSONText) async {
        guard let operation = beginImport(count: nil) else { return }
        defer { finishImport(operation) }
        do {
            let selected = try await services.chooseFiles(cwd, Self.maximumAttachments - attachments.count, lifetime)
            guard !isDisposed, !operation.retired else { await discard(selected.map(\.id), from: operation); return }
            let existing = Set(attachments.compactMap(\.attachment).map(\.id))
            let additions = selected.filter { !existing.contains($0.id) }
            guard attachments.count + additions.count <= Self.maximumAttachments else {
                await discard(additions.map(\.id), from: operation)
                throw PluginContractError("附件数量不能超过 20 个")
            }
            operation.attachments = additions.map(NativeComposerAttachment.init(attachment:))
            attachments += operation.attachments
            loadPreviews(attachments)
        } catch { if !operation.retired { record(error) } }
    }

    public func importFiles(_ files: [NativeComposerFile]) async {
        // TIFF can fail admission just as the old synchronous pasteboard
        // decoder did. Count only admitted files; invalid TIFF must not turn a
        // mixed text paste into an attachment error or consume an attachment slot.
        let knownCount = files.filter { !$0.clipboardTIFF }.count
        guard !files.isEmpty, let operation = beginImport(count: knownCount) else { return }
        defer { finishImport(operation) }
        var pending: [NativeComposerAttachment] = []
        do {
            // A pending chip is persisted immediately. Prepare TIFF before
            // publishing any chips so even an interrupted import stays within
            // the same attachment bound used when restoring the draft.
            try validateFiles(files, policy: nil, excluding: [])
            let policy = try await services.attachmentPolicy?(lifetime)
            guard !isDisposed, !operation.retired else { return }
            try validateFiles(files.filter { !$0.clipboardTIFF }, policy: policy, excluding: [])
            let results = try await NativeRasterPreparation.shared.prepare(files)
            try Task.checkCancellation(); try lifetime.checkCancellation()
            guard !isDisposed, !operation.retired else { return }
            let prepared = results.compactMap { $0 }
            guard !prepared.isEmpty else { return }
            guard attachments.count + prepared.count <= Self.maximumAttachments else {
                throw PluginContractError("附件数量不能超过 20 个")
            }
            try validateFiles(prepared, policy: policy, excluding: [])
            pending = prepared.map { file in
                NativeComposerAttachment(id: JSONText("pending:\(UUID().uuidString)"), name: JSONText(file.name),
                    status: .pending(size: file.size, mimeType: file.mimeType))
            }
            operation.attachments = pending
            attachments += pending
            // Each admitted image fills its preview independently during staging.
            for (file, draft) in zip(prepared, pending) where file.mimeType.hasPrefix("image/") {
                Task { [weak self] in
                    let preview = await NativeComposerPreviewGenerator.make(file)
                    self?.fillPreview(preview, for: draft.id)
                }
            }
            let staged = try await services.stageFiles(prepared, lifetime)
            guard !isDisposed, !operation.retired else { await discard(staged.map(\.id), from: operation); return }
            guard staged.count == pending.count else {
                await discard(staged.map(\.id), from: operation)
                throw PluginContractError("Attachment import returned an incomplete result")
            }
            var unused: [JSONText] = []
            for (draft, attachment) in zip(pending, staged) {
                if let index = attachments.firstIndex(where: { $0.id == draft.id && $0.pending }) {
                    // Preserve the preview already decoded at import time so the
                    // pending → ready swap does not re-decode the same image.
                    attachments[index] = NativeComposerAttachment(id: draft.id, name: attachment.name,
                        status: .ready(attachment), preview: attachments[index].preview)
                } else { unused.append(attachment.id) }
            }
            await discard(unused, from: operation)
            loadPreviews(attachments)
        } catch {
            guard !operation.retired else { return }
            let ids = Set(pending.map(\.id))
            attachments = attachments.map { draft in
                guard draft.pending, ids.contains(draft.id) else { return draft }
                return NativeComposerAttachment(id: draft.id, name: draft.name, status: .failed(error.localizedDescription))
            }
            record(error)
        }
    }

    /// Clearing a successful send compares its captured revision and contents.
    /// Edits and files added while the runtime admits the input remain intact.
    public func submit(_ send: (NativeComposerSubmission) async throws -> Void) async {
        guard canSubmit else { return }
        let revision = editRevision, persistedRevision = savedRevision
        let sentAttachments = attachments.filter { $0.attachment != nil }
        let sentDirectories = directories
        let mentionedRevisions = directoryRevisions
        let submission = NativeComposerSubmission(text: text, directories: sentDirectories,
                                                   attachments: sentAttachments.compactMap(\.attachment))
        submitting = true; error = nil
        protectedAttachmentIDs = Set(submission.attachments.map(\.id))
        defer { submitting = false }
        var accepted = false
        do {
            try await send(submission)
            accepted = true
            if !isDisposed {
                _ = clearSubmitted(revision: revision, attachments: sentAttachments, directories: mentionedRevisions)
            } else {
                try consumePersisted(revision: persistedRevision, attachments: sentAttachments, directories: Set(mentionedRevisions.keys))
            }
        } catch { record(error) }
        // Removing a chip or disposing a surface cannot delete bytes still
        // referenced by a command waiting for its admission receipt.
        let retired = accepted ? retiredAttachmentIDs.subtracting(protectedAttachmentIDs) : retiredAttachmentIDs
        protectedAttachmentIDs = []; retiredAttachmentIDs = []
        await discard(Array(retired))
    }

    public func clear(_ clearSession: () async throws -> Void) async {
        guard !isDisposed, !clearing, !submitting else { return }
        let revision = editRevision, discarded = attachments, mentioned = directoryRevisions
        let importAtStart = activeImport
        let pasteAtStart = pastePreparation
        clearing = true; error = nil
        defer { clearing = false }
        do {
            try await clearSession()
            // A pre-clear import may publish chips while the clear receipt is
            // pending. Consume that whole operation, even if it already finished,
            // while preserving imports started after clear admission.
            pasteAtStart?.finish()
            importAtStart?.retired = true
            if let importAtStart { finishImport(importAtStart) }
            let consumed = discarded + (importAtStart?.attachments ?? [])
            guard !isDisposed else {
                // Import progress can advance persistence while clear awaits its
                // receipt. Match our last saved snapshot, retaining later edits;
                // a replacement owner's newer revision still wins the CAS.
                let consumedDirectories = Set(mentioned.keys.filter { mentioned[$0] == directoryRevisions[$0] })
                try consumePersisted(revision: savedRevision, attachments: consumed,
                    directories: consumedDirectories, clearText: editRevision == revision)
                return
            }
            let removed = clearSubmitted(revision: revision, attachments: consumed, directories: mentioned)
            await discard(removed)
        } catch { record(error) }
    }

    /// Call only when the draft owner is destroyed, not when a composer view is
    /// hidden. Lifetime cancellation closes chooser scopes; late imports never
    /// repopulate this draft. Remote discard is skipped after confirmed shutdown.
    public func dispose(discardRemoteAttachments: Bool = true) async {
        // A successful service shutdown has already revoked command admission.
        // Its unretained staging files belong to runtime-owned orphan collection;
        // never reopen transport from late imports or send receipts during teardown.
        if !discardRemoteAttachments { remoteDiscardEnabled = false }
        guard !isDisposed else { return }
        persist(semanticChange: false)
        isDisposed = true; pastePreparation?.finish(); lifetime.cancel()
        // A host switch or app exit retires the view, not the unsent draft.
        // Its staged IDs remain available to the next owner of this file.
        if persistence != nil {
            remoteDiscardEnabled = false
            protectedAttachmentIDs.removeAll(); retiredAttachmentIDs.removeAll()
            return
        }
        let unused = attachments.compactMap(\.attachment).map(\.id)
        attachments = []; directories = []; directoryRevisions = [:]; text = ""
        if !remoteDiscardEnabled {
            protectedAttachmentIDs.removeAll(); retiredAttachmentIDs.removeAll()
        }
        await discard(unused)
    }

    private func beginImport(count: Int?) -> AttachmentImport? {
        guard !isDisposed else { return nil }
        guard !staging else { error = "附件正在处理中，请稍候"; return nil }
        let remaining = Self.maximumAttachments - attachments.count
        guard remaining > 0, (count ?? 0) <= remaining else { error = "附件数量不能超过 20 个"; return nil }
        staging = true; error = nil
        let operation = AttachmentImport()
        activeImport = operation
        return operation
    }
    private func finishImport(_ operation: AttachmentImport) {
        guard activeImport === operation else { return }
        activeImport = nil
        staging = false
    }
    private func clearSubmitted(revision: UInt64, attachments sent: [NativeComposerAttachment], directories mentioned: [JSONText: UUID]) -> [JSONText] {
        if editRevision == revision { text = "" }
        // Match by identity, not value equality. A preview can decode while the
        // send awaits its admission receipt, and a pending import can turn ready
        // while a clear awaits its receipt; a structural comparison would miss
        // the attachment and leave an already-sent chip in the composer.
        let sentIDs = Set(sent.map(\.id))
        let removed = attachments.filter { sentIDs.contains($0.id) }
        attachments.removeAll { sentIDs.contains($0.id) }
        let removedDirectories = directories.filter { mentioned[$0.path] == directoryRevisions[$0.path] }.map(\.path)
        for path in removedDirectories { removeDirectory(path) }
        return removed.compactMap(\.attachment).map(\.id)
    }
    private func discard(_ ids: [JSONText], from operation: AttachmentImport? = nil) async {
        guard remoteDiscardEnabled else { return }
        let requested = Set(ids)
        retiredAttachmentIDs.formUnion(requested.intersection(protectedAttachmentIDs))
        let unprotected = requested.subtracting(protectedAttachmentIDs)
        guard !unprotected.isEmpty else { return }
        do { try await services.discardAttachments(Array(unprotected)) }
        catch {
            // Retired staging belongs to runtime orphan collection if cleanup
            // fails. Its response must not replace the successor draft's error.
            if operation?.retired != true { record(error) }
        }
    }
    private func record(_ cause: Error) {
        guard !isDisposed, !(cause is CancellationError) else { return }
        error = cause.localizedDescription
    }

    private func persist(semanticChange: Bool = true) {
        guard !restoring, !isDisposed, let persistence else { return }
        let revision = semanticChange ? UUID().uuidString : savedRevision ?? UUID().uuidString
        do { savedRevision = try persistence.save(text: text, directories: directories, attachments: attachments, revision: revision) }
        catch { savedRevision = nil; self.error = "草稿未能保存到设备：\(error.localizedDescription)" }
    }

    private func consumePersisted(revision: String?, attachments: [NativeComposerAttachment], directories: Set<JSONText>, clearText: Bool = true) throws {
        guard let persistence, let revision,
              let consumed = try persistence.consume(expectedRevision: revision,
                  attachmentIDs: Set(attachments.map(\.id)), directoryPaths: directories, clearText: clearText) else { return }
        for owner in Self.owners.compactMap(\.value) where !owner.isDisposed
            && owner.persistence?.identity == persistence.identity && owner.savedRevision == revision {
            owner.restoring = true
            owner.text = consumed.text; owner.directories = consumed.directories; owner.attachments = consumed.attachments
            owner.savedRevision = consumed.revision
            owner.directoryRevisions = Dictionary(uniqueKeysWithValues: consumed.directories.map { ($0.path, UUID()) })
            owner.restoring = false
        }
    }

    private func loadPreviews(_ drafts: [NativeComposerAttachment]) {
        guard let preview = services.previewAttachment else { return }
        for draft in drafts where draft.preview == nil {
            guard let file = draft.attachment, file.kind == .image else { continue }
            Task { [weak self] in
                guard let self, !self.isDisposed else { return }
                do {
                    if let bytes = try await preview(file, self.lifetime) {
                        let value = await NativeComposerPreviewGenerator.make(.init(data: bytes, name: file.name.string, mimeType: file.mimeType.string))
                        self.fillPreview(value, for: draft.id)
                    }
                } catch { /* A preview is optional; the host validates bytes on send. */ }
            }
        }
    }

    private func validateFiles(_ files: [NativeComposerFile], policy: RuntimeAttachmentPolicy?, excluding pending: Set<JSONText>) throws {
        let existing = attachments.filter { !pending.contains($0.id) }.compactMap(\.attachment)
        for file in files {
            if case .bytes(let data) = file.source, data.count > Self.maximumClipboardBytes {
                throw PluginContractError("无路径的粘贴内容不能超过 20 MB；请先保存文件后再通过回形针添加")
            }
        }
        if let policy {
            guard existing.count + files.count <= policy.messageCount else { throw PluginContractError("附件数量超过主机限制") }
            var bytes = existing.reduce(0) { $0 + $1.size }
            for file in files {
                guard file.size >= 0, file.size <= policy.maximumBytes(mimeType: file.mimeType),
                      bytes <= policy.messageBytes - file.size else { throw PluginContractError("附件大小超过主机限制") }
                bytes += file.size
            }
        }
    }
}
