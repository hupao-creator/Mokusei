import Foundation
import Observation
import ChiefCore
import ChiefPluginAPI

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
    public var text = "" {
        didSet {
            editRevision &+= 1
            guard !restoring else { return }
            textEditID = UUID()
            persist()
            synchronizeEditors()
        }
    }
    public private(set) var directories: [NativeComposerDirectory] = [] { didSet { persist(semanticChange: directories != oldValue) } }
    public private(set) var attachments: [NativeComposerAttachment] = [] {
        didSet {
            updateAttachmentOwner()
            persist(semanticChange: attachments != oldValue)
        }
    }
    private typealias Contents = NativeComposerDraftPersistence.Contents
    private typealias Pending = NativeComposerDraftPersistence.Pending
    private var pending: Pending?
    public private(set) var cleanupReceipt: String?
    private var composingEditor: UUID?
    private var compositionRecovery: (prefix: String, markedDraft: String)?
    @ObservationIgnored let editors = NSHashTable<NativeComposerEditor.Coordinator>.weakObjects()

    private func synchronizeEditors() {
        for editor in editors.allObjects { editor.applyDraft(self) }
    }

    public func setComposing(_ active: Bool, editor: UUID) {
        if active { composingEditor = editor }
        else if composingEditor == editor {
            composingEditor = nil
            if let recovery = compositionRecovery {
                compositionRecovery = nil
                let merged = Contents.recoveredText(submitted: recovery.prefix, next: recovery.markedDraft)
                if text.utf16.elementsEqual(merged.utf16) { synchronizeEditors() }
                else { text = merged }
            }
        }
    }

    public var inputText: String {
        get { compositionRecovery?.markedDraft ?? text }
        set {
            if let recovery = compositionRecovery {
                compositionRecovery = (recovery.prefix, newValue)
                text = Contents.recoveredText(submitted: recovery.prefix, next: newValue)
            } else { text = newValue }
        }
    }
    public var inputAttachments: [NativeComposerAttachment] { attachments }
    public var inputDirectories: [NativeComposerDirectory] { directories }

    public var hasInterruptedSend: Bool { pending != nil && !submitting }
    public var interruptedInput: NativeComposerSubmission? {
        guard hasInterruptedSend, let pending else { return nil }
        let original = pending.original
        return NativeComposerSubmission(text: original.text, directories: original.directories,
            attachments: original.attachments.compactMap(\.attachment), commandID: pending.id)
    }

    public var importing: Bool { staging || pastePreparation != nil }
    private var staging = false
    private var pastePreparation: NativeComposerPastePreparation?
    public private(set) var submitting = false
    public private(set) var clearing = false
    public var error: String? { saveError ?? operationError }
    private var operationError: String?
    private var saveError: String?
    public private(set) var isDisposed = false
    @ObservationIgnored private var editRevision: UInt64 = 0
    @ObservationIgnored private var activeImport: AttachmentImport?
    @ObservationIgnored private let lifetime = PluginLifetime()
    @ObservationIgnored private let services: NativeComposerServices
    @ObservationIgnored private let persistence: NativeComposerDraftPersistence?
    @ObservationIgnored private var attachmentOwner: RuntimeAttachmentOwner?
    @ObservationIgnored private var restoring = false
    private var saveFailed: Bool { saveError != nil }
    @ObservationIgnored private var textEditID = UUID()
    @ObservationIgnored private var savedRevision: String?
    @ObservationIgnored private var protectedAttachmentIDs: Set<JSONText> = []
    @ObservationIgnored private var retiredAttachmentIDs: Set<JSONText> = []
    @ObservationIgnored private var remoteDiscardEnabled = true
    @ObservationIgnored private var directoryRevisions: [JSONText: UUID] = [:]

    public init(services: NativeComposerServices, persistence: NativeComposerDraftPersistence? = nil) {
        self.services = services; self.persistence = persistence
        restoring = true
        do {
            let retained = try persistence?.loadRetainingAttachments()
            if let retained { attachmentOwner = retained.owner }
            else { attachmentOwner = try services.retainAttachments?([]) }
            if let saved = retained?.snapshot {
                textEditID = saved.contents.textEditID
                text = saved.text; directories = saved.directories; attachments = saved.attachments
                savedRevision = saved.revision; pending = saved.pending; cleanupReceipt = saved.cleanupReceipt
                directoryRevisions = Dictionary(uniqueKeysWithValues: directories.map { ($0.path, UUID()) })
            }
        } catch let failure as RuntimeError where failure.code == "DRAFT_STORAGE_INVALID" {
            // Leave the saved record alone and keep the editor available.
        } catch { self.operationError = error.localizedDescription }
        restoring = false
        Self.owners.removeAll { $0.value == nil }
        Self.owners.append(WeakDraft(self))
        loadPreviews(attachments)
    }
    public var canSubmit: Bool {
        !isDisposed && !importing && !submitting && !clearing && pending == nil && cleanupReceipt == nil && composingEditor == nil
            && !editors.allObjects.contains { $0.active == true && $0.editor?.hasMarkedText() == true }
            && NativeComposerSubmissionPolicy.canSubmit(text: text, attachments: attachments, directories: directories)
    }
    public func clearError() { operationError = nil }

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
        guard entries.allSatisfy({ !$0.isDirectory }) else { operationError = "请选择文件"; return }
        await importFiles(entries.map { .init(hostFile: $0.reference, name: $0.name, size: $0.size, mimeType: $0.mimeType) })
    }

    @discardableResult
    func chooseHostDirectory(_ reference: RuntimeHostFileReference) -> Bool {
        insertDirectory(.init(name: JSONText(URL(fileURLWithPath: reference.path).lastPathComponent),
                              path: JSONText(reference.path), hostID: reference.hostID))
    }

    @discardableResult
    public func insertDirectory(_ directory: NativeComposerDirectory) -> Bool {
        guard !isDisposed, !directory.path.codeUnits.isEmpty else { return false }
        if let index = directories.firstIndex(where: { $0.path == directory.path }) {
            // A host picker selection for the same path gives a saved catalog
            // reference the explicit host identity used for submission.
            if directories[index].hostID == nil, directory.hostID != nil {
                directories[index] = directory
                directoryRevisions[directory.path] = UUID()
            }
            return true
        }
        let used = Set(directories.map(\.path)).union(pending?.original.directories.map(\.path) ?? [])
        guard used.contains(directory.path) || used.count < Self.maximumDirectories else { return false }
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
            let selected = try await services.chooseFiles(cwd, Self.maximumAttachments - reservedAttachmentCount, lifetime)
            guard !selected.isEmpty, !isDisposed, !operation.retired else { return }
            await importFiles(selected, operation: operation)
        } catch { if !operation.retired { record(error) } }
    }

    public func importFiles(_ files: [NativeComposerFile]) async {
        // TIFF can fail admission just as the old synchronous pasteboard
        // decoder did. Count only admitted files; invalid TIFF must not turn a
        // mixed text paste into an attachment error or consume an attachment slot.
        let knownCount = files.filter { !$0.clipboardTIFF }.count
        guard !files.isEmpty, let operation = beginImport(count: knownCount) else { return }
        defer { finishImport(operation) }
        await importFiles(files, operation: operation)
    }

    private func importFiles(_ files: [NativeComposerFile], operation: AttachmentImport) async {
        var pending: [NativeComposerAttachment] = []
        do {
            // A pending chip is persisted immediately. Prepare TIFF before
            // publishing any chips so even an interrupted import stays within
            // the same attachment bound used when restoring the draft.
            try validateFiles(files, policy: nil)
            let policy = try await services.attachmentPolicy?(lifetime)
            guard !isDisposed, !operation.retired else { return }
            try validateFiles(files.filter { !$0.clipboardTIFF }, policy: policy)
            let results = try await NativeRasterPreparation.shared.prepare(files)
            try Task.checkCancellation(); try lifetime.checkCancellation()
            guard !isDisposed, !operation.retired else { return }
            let prepared = results.compactMap { $0 }
            guard !prepared.isEmpty else { return }
            guard reservedAttachmentCount + prepared.count <= Self.maximumAttachments else {
                throw PluginContractError("附件数量不能超过 20 个")
            }
            try validateFiles(prepared, policy: policy)
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
            // A selected file may change size before the transfer snapshots it.
            if let policy, !fitsAttachmentBudget(staged.map(\.size), limit: policy.messageBytes) {
                await discard(staged.map(\.id), from: operation)
                throw PluginContractError("附件大小超过主机限制")
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

    /// Admission consumes only the captured revision and identities. Moku can
    /// optimistically clear the editor while retaining the durable send payload.
    public func submit(_ send: (NativeComposerSubmission) async throws -> Void,
                       optimisticallyClear: Bool = false,
                       didConsume: ((NativeComposerSubmission) async -> Void)? = nil) async {
        guard canSubmit else { return }
        let revision = editRevision, persistedRevision = savedRevision
        let sentAttachments = attachments.filter { $0.attachment != nil }
        let sentDirectories = directories
        let mentionedRevisions = directoryRevisions
        let submission = NativeComposerSubmission(text: text, directories: sentDirectories,
                                                   attachments: sentAttachments.compactMap(\.attachment))
        let submissionOwner: RuntimeAttachmentOwner?
        do {
            submissionOwner = try attachmentOwner?.capture(submission.attachments.map(\.id))
                ?? services.retainAttachments?(submission.attachments.map(\.id))
        } catch { record(error); return }
        defer { try? submissionOwner?.release() }
        submitting = true; operationError = nil
        protectedAttachmentIDs = Set(submission.attachments.map(\.id))
        defer { submitting = false }
        var accepted = false
        var consumed = false
        let handoff = Pending(id: submission.commandID, original: Contents(textValue: JSONText(submission.text),
            textEditID: textEditID, directories: sentDirectories, attachments: sentAttachments),
            receiptID: services.receipts == nil ? nil : submission.commandID)
        let lease: RuntimeDraftSubmissionLease?
        do {
            lease = optimisticallyClear ? try persistence?.acquireSubmissionLease() : nil
            if optimisticallyClear {
                let next = Contents(textValue: "", textEditID: UUID(), directories: [],
                                    attachments: attachments.filter { $0.attachment == nil })
                let revision = try persistence?.save(next, pending: handoff,
                    expectedRevision: savedRevision, revision: UUID().uuidString)
                install(next, pending: handoff, revision: revision)
            }
        } catch {
            protectedAttachmentIDs = []
            record(error)
            return
        }
        defer { withExtendedLifetime(lease) {} }
        do {
            try await send(submission)
            accepted = true
            if optimisticallyClear {
                try finish(handoff, restore: false, cleanup: handoff.receiptID)
                if let id = handoff.receiptID { try await completeCleanup(id) }
            } else if !isDisposed {
                _ = clearSubmitted(revision: revision, attachments: sentAttachments, directories: mentionedRevisions)
            } else {
                try consumePersisted(revision: persistedRevision, attachments: sentAttachments, directories: Set(mentionedRevisions.keys))
                try consumeAcceptedAttachments(sentAttachments)
            }
            consumed = !saveFailed || optimisticallyClear
        } catch let sendError {
            record(sendError)
            let uncertain = (sendError as? RuntimeError)?.kind == .uncertain && persistence != nil
            if !accepted, optimisticallyClear, uncertain, let id = (sendError as? RuntimeError)?.receiptID {
                do { try bindReceipt(id, to: handoff) } catch { record(error) }
            } else if !accepted, optimisticallyClear {
                let failure = sendError as? RuntimeError
                let cleanup = services.receipts != nil && failure?.kind == .commandRejected ? failure?.receiptID : nil
                do {
                    try finish(handoff, restore: true, cleanup: cleanup)
                    if let cleanup { try await completeCleanup(cleanup) }
                } catch { record(error) }
            }
        }
        // Retained command receipts outlive transport success. Release them
        // only after this revision has been consumed without a storage error.
        if consumed { await didConsume?(submission) }
        // Removing a chip or disposing a surface cannot delete bytes still
        // referenced by a command waiting for its admission receipt.
        let retired = accepted ? retiredAttachmentIDs.subtracting(protectedAttachmentIDs) : retiredAttachmentIDs
        // Thread admission retains its own reference. Release staging only after
        // the consumed draft is durable; a failed save must keep its lease.
        let consumedIDs = consumed ? Set(submission.attachments.map(\.id)) : []
        protectedAttachmentIDs = []; retiredAttachmentIDs = []
        // End the temporary send owner before Discard asks the repository to
        // collect. An uncertain outcome is retained by the command journal.
        try? submissionOwner?.release()
        await discard(Array(retired.union(consumedIDs)))
    }

    public func clear(_ clearSession: () async throws -> Void) async {
        guard !isDisposed, !clearing, !submitting, pending == nil else { return }
        let revision = editRevision, discarded = attachments, mentioned = directoryRevisions
        let importAtStart = activeImport
        let pasteAtStart = pastePreparation
        clearing = true; operationError = nil
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
        if persistence != nil, saveFailed { attachmentOwner?.preserveUntilProcessExit() }
        else { try? attachmentOwner?.release() }
        attachmentOwner = nil
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

    private var contents: Contents {
        Contents(textValue: JSONText(text), textEditID: textEditID, directories: directories, attachments: attachments)
    }

    private func install(_ next: Contents, pending: Pending?, revision: String?, restoredPrefix: String? = nil) {
        if composingEditor != nil {
            // Chip edits carry the same body across document revisions. Only
            // independently edited text belongs alongside the native IME buffer.
            if next.textEditID != textEditID { compositionRecovery = (next.text, inputText) }
            else if let restoredPrefix { compositionRecovery = (restoredPrefix, inputText) }
            else if let original = self.pending?.original, pending == nil,
                    !text.utf16.elementsEqual(next.text.utf16) {
                // Another process settled the same body before we refreshed.
                compositionRecovery = (original.text, inputText)
            }
        }
        restoring = true
        textEditID = next.textEditID
        self.pending = pending
        text = next.text
        directories = next.directories
        directoryRevisions = Dictionary(uniqueKeysWithValues: directories.map { ($0.path, UUID()) })
        attachments = next.attachments
        savedRevision = revision
        saveError = nil
        restoring = false
        synchronizeEditors()
    }

    public var hasTrackedReceipt: Bool { pending?.receiptID != nil && !requiresForkReview }
    public var requiresForkReview: Bool { pending?.reviewFork == true }

    private func bindReceipt(_ id: String?, to handoff: Pending, reviewFork: Bool = false) throws {
        try persistence?.bindReceipt(id, to: handoff.id, reviewFork: reviewFork)
        for owner in Self.owners.compactMap(\.value) where owner.pending?.id == handoff.id {
            owner.pending?.receiptID = id
            owner.pending?.reviewFork = reviewFork
        }
    }

    /// This action can only inspect the captured receipt, never submit editor text.
    public func checkPendingReceipt() async {
        guard !submitting, !isDisposed, let persistence, let actions = services.receipts else { return }
        submitting = true
        defer { submitting = false }
        do {
            let lease = try persistence.acquireSubmissionLease()
            defer { withExtendedLifetime(lease) {} }
            guard let saved = try persistence.load() else { throw PluginContractError("The saved draft is unavailable.") }
            cleanupReceipt = saved.cleanupReceipt
            if let id = cleanupReceipt {
                if saveFailed { pending = saved.pending }
                else if savedRevision != saved.revision { install(saved.contents, pending: saved.pending, revision: saved.revision) }
                try await completeCleanup(id)
            } else if let handoff = saved.pending, handoff.id == pending?.id,
                      let id = handoff.receiptID, !handoff.reviewFork {
                switch try await actions.check(id) {
                case .absent:
                    try bindReceipt(nil, to: handoff)
                case .unfinishedFork(let terminal):
                    try bindReceipt(terminal, to: handoff, reviewFork: true)
                case .rejected(let terminal):
                    try finish(handoff, restore: true, cleanup: terminal)
                    try await completeCleanup(terminal)
                case .accepted(let terminal):
                    try finish(handoff, restore: false, cleanup: terminal)
                    try await completeCleanup(terminal)
                    await discard(handoff.original.attachments.compactMap(\.attachment).map(\.id))
                }
            } else if saveFailed { pending = saved.pending }
            else { install(saved.contents, pending: saved.pending, revision: saved.revision) }
            operationError = nil
        } catch { record(error) }
    }

    // finish writes this marker atomically with the successor. Either side of
    // journal acknowledgement can be interrupted and retried after reopening.
    private func completeCleanup(_ id: String) async throws {
        guard let actions = services.receipts else { throw PluginContractError("Receipt cleanup is unavailable.") }
        try await actions.consume(id)
        try persistence?.completeCleanup(id)
        for owner in Self.owners.compactMap(\.value) where owner.cleanupReceipt == id {
            owner.cleanupReceipt = nil
        }
    }

    /// An admission receipt can arrive after a replacement editor has edited
    /// the successor. Resolve by send ID, retaining that editor's live imports.
    private func finish(_ handoff: Pending, restore: Bool, cleanup: String? = nil) throws {
        let owners = Self.owners.compactMap(\.value).filter { !$0.isDisposed && $0.pending?.id == handoff.id }
        // A failed edit write still belongs to its editor. Keep the handoff
        // recoverable if the latest in-memory successor cannot be made durable.
        var divergent = Set<ObjectIdentifier>()
        for owner in owners where owner.saveFailed {
            if try persistence?.load()?.revision != owner.savedRevision {
                // Keep the losing editor's unsaved buffer and file owner. Its
                // stale revision cannot publish over the durable successor.
                divergent.insert(ObjectIdentifier(owner))
                continue
            }
            owner.savedRevision = try persistence?.save(owner.contents, pending: handoff,
                expectedRevision: owner.savedRevision, revision: UUID().uuidString)
            owner.saveError = nil
        }
        let saved = try persistence?.finish(handoff.id, restore: restore, cleanupReceipt: cleanup)
        for owner in owners {
            owner.cleanupReceipt = cleanup
            if divergent.contains(ObjectIdentifier(owner)) {
                owner.pending = nil
                continue
            }
            let next: Contents
            if let saved, owner.savedRevision != saved.previousRevision { next = saved.snapshot.contents }
            else { next = restore ? owner.contents.restoring(handoff.original) : owner.contents }
            owner.install(next, pending: nil, revision: saved?.snapshot.revision,
                          restoredPrefix: restore ? handoff.original.text : nil)
        }
    }

    /// Reopening only offers a local review. Neither choice invokes a command.
    public func reviewInterruptedSend(restore: Bool) async {
        guard !isDisposed, !submitting, let pending, pending.receiptID == nil || pending.reviewFork, let persistence else { return }
        submitting = true
        defer { submitting = false }
        do {
            let lease = try persistence.acquireSubmissionLease()
            defer { withExtendedLifetime(lease) {} }
            let latest = try persistence.load()
            if let tracked = latest?.pending, tracked.id == pending.id, tracked.receiptID != nil, !tracked.reviewFork {
                self.pending = tracked
                return
            }
            if let saved = latest, saved.pending?.id != pending.id {
                // A different process may already have received the receipt.
                // Refresh this view without resolving its successor's send.
                guard !saveFailed else { throw PluginContractError("Reopen the saved draft after copying your unsaved edits.") }
                cleanupReceipt = saved.cleanupReceipt
                install(saved.contents, pending: saved.pending, revision: saved.revision)
            } else {
                let cleanup = latest?.pending?.receiptID
                try finish(pending, restore: restore, cleanup: cleanup)
                if let cleanup { try await completeCleanup(cleanup) }
            }
            operationError = nil
        } catch { record(error) }
    }

    private var reservedAttachmentCount: Int { attachments.count + (pending?.original.attachments.count ?? 0) }

    private func beginImport(count: Int?) -> AttachmentImport? {
        guard !isDisposed else { return nil }
        guard !staging else { operationError = "附件正在处理中，请稍候"; return nil }
        let remaining = Self.maximumAttachments - reservedAttachmentCount
        guard remaining > 0, (count ?? 0) <= remaining else { operationError = "附件数量不能超过 20 个"; return nil }
        staging = true; operationError = nil
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
        if editRevision == revision {
            compositionRecovery = nil
            text = ""
        }
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
        operationError = cause.localizedDescription
    }

    private func persist(semanticChange: Bool = true) {
        guard !restoring, !isDisposed, let persistence else { return }
        let revision = semanticChange ? UUID().uuidString : savedRevision ?? UUID().uuidString
        do {
            savedRevision = try persistence.save(contents, pending: pending, expectedRevision: savedRevision, revision: revision)
            saveError = nil
        } catch { saveError = "草稿未能保存到设备：\(error.localizedDescription)" }
    }

    private func updateAttachmentOwner() {
        guard !isDisposed else { return }
        do { try attachmentOwner?.replace(attachments.compactMap(\.attachment).map(\.id)) }
        catch { self.operationError = "草稿附件归属未能保存：\(error.localizedDescription)" }
    }

    private func consumePersisted(revision: String?, attachments: [NativeComposerAttachment], directories: Set<JSONText>, clearText: Bool = true) throws {
        guard let persistence, let revision,
              let consumed = try persistence.consume(expectedRevision: revision,
                  attachmentIDs: Set(attachments.map(\.id)), directoryPaths: directories, clearText: clearText) else { return }
        for owner in Self.owners.compactMap(\.value) where !owner.isDisposed
            && owner.persistence?.identity == persistence.identity && owner.savedRevision == revision {
            owner.install(consumed.contents, pending: nil, revision: consumed.revision)
        }
    }

    private func consumeAcceptedAttachments(_ sent: [NativeComposerAttachment]) throws {
        let identities = Dictionary(uniqueKeysWithValues: sent.compactMap { draft in
            draft.attachment.map { (draft.id, $0.id) }
        })
        guard let persistence,
              let consumed = try persistence.consumeAcceptedAttachments(identities) else { return }
        for owner in Self.owners.compactMap(\.value) where !owner.isDisposed
            && owner.persistence?.identity == persistence.identity {
            // Patch live chips instead of restoring a snapshot, preserving new
            // text, previews and imports that are still awaiting their stage result.
            owner.restoring = true
            owner.attachments.removeAll { draft in
                guard let file = draft.attachment else { return false }
                return identities[draft.id] == file.id
            }
            if owner.savedRevision == consumed.previousRevision { owner.savedRevision = consumed.revision }
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

    private func validateFiles(_ files: [NativeComposerFile], policy: RuntimeAttachmentPolicy?) throws {
        for file in files {
            if case .bytes(let data) = file.source, data.count > Self.maximumClipboardBytes {
                throw PluginContractError("无路径的粘贴内容不能超过 20 MB；请先保存文件后再添加")
            }
        }
        if let policy {
            guard attachments.compactMap(\.attachment).count + files.count <= policy.messageCount else {
                throw PluginContractError("附件数量超过主机限制")
            }
            guard files.allSatisfy({ $0.size >= 0 && $0.size <= policy.maximumBytes(mimeType: $0.mimeType) }),
                  fitsAttachmentBudget(files.map(\.size), limit: policy.messageBytes) else {
                throw PluginContractError("附件大小超过主机限制")
            }
        }
    }

    private func fitsAttachmentBudget(_ addedSizes: [Int], limit: Int) -> Bool {
        var remaining = limit
        for size in attachments.compactMap({ $0.attachment?.size }) + addedSizes {
            guard size <= remaining else { return false }
            remaining -= size
        }
        return true
    }
}
