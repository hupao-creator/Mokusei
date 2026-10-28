import Foundation
import Observation
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI

/// One instance belongs to one thread/plugin session. Folding or suppressing its
/// view never releases composition state or the owning Harness's response forms.
@MainActor @Observable
public final class ConversationSidecardPresentation {
    private final class WeakOwner {
        weak var value: ConversationSidecardPresentation?
        init(_ value: ConversationSidecardPresentation) { self.value = value }
    }
    private static var owners: [WeakOwner] = []
    public private(set) var context: SidecardContext
    public let attachments: NativeComposerDraft
    public private(set) var draft = ""
    public private(set) var submitting = false
    public private(set) var stopping = false
    private var operationError: String?
    public var error: String? { operationError ?? attachments.error }
    public private(set) var focusRequest = 0

    private var executionState = ConversationExecutionState()
    @ObservationIgnored private let lifetime: PluginLifetime
    @ObservationIgnored private var draftRevision = 0
    @ObservationIgnored private var rawDraft: JSONText?
    @ObservationIgnored private var lastExecutionFocusRequest = 0
    @ObservationIgnored private let persistence: NativeComposerDraftPersistence?
    @ObservationIgnored private var persistedRevision: String?

    public init(context: SidecardContext, lifetime: PluginLifetime) {
        self.context = context
        self.lifetime = lifetime
        attachments = NativeComposerDraft(services: NativeComposerServices(stageFiles: { files, importLifetime in
            guard let capability = context.attachmentImport else { throw PluginContractError("附件导入不可用") }
            let sources = try files.map { file -> SidecardAttachmentSource in
                switch file.source {
                case .file(let url): return .file(url)
                case .bytes(let bytes): return .bytes(bytes, name: file.name, mimeType: file.mimeType)
                case .hostPath: throw PluginContractError("Sidecard attachments must be device-local files")
                }
            }
            return try await capability.stage(sources, importLifetime).map {
                NativeComposerStoredAttachment(id: $0.id, path: $0.path, name: $0.name, mimeType: $0.mimeType,
                    size: $0.size, kind: NativeComposerStoredAttachment.Kind(rawValue: $0.kind.rawValue)!)
            }
        }, attachmentPolicy: context.attachmentImport?.policy, discardAttachments: context.discardAttachments))
        lifetime.onCancel { [attachments] in Task { await attachments.dispose() } }
        persistence = context.draftStorageDirectory.map {
            NativeComposerDraftPersistence(storageDirectory: $0, scope: JSONText(codeUnits: Array("conversation:".utf16) + context.thread.id.codeUnits))
        }
        do {
            if let saved = try persistence?.loadText() {
                rawDraft = saved.textValue; draft = saved.textValue.string; persistedRevision = saved.revision
            }
        } catch { self.operationError = error.localizedDescription }
        Self.owners.removeAll { $0.value == nil }
        Self.owners.append(WeakOwner(self))
        context.onIntent(lifetime: lifetime) { [weak self] intent in self?.handle(intent) ?? false }
        update(context: context)
        if context.expanded && sidecardExecutionID == nil && !disabled { focusRequest += 1 }
    }

    public var activeExecutionID: JSONText? { executionState.activeExecutionID(thread: context.thread) }
    public var sidecardExecutionID: JSONText? {
        executionState.sidecardExecutionID(thread: context.thread, index: context.conversationIndex, readingTarget: context.readingTarget)
    }
    public var disabled: Bool { lifetime.isCancelled || context.thread.archived == true }
    public var waiting: Bool { context.thread.observation.latestExecution?.status == .waitingForUser }
    public var running: Bool { context.thread.pendingInput || context.thread.observation.latestExecution?.status == .running }
    private var trimmedDraft: JSONText { NativeComposerSubmissionPolicy.trimmedText(rawDraft ?? JSONText(draft)) }
    public var hasDraft: Bool { !trimmedDraft.codeUnits.isEmpty || !attachments.attachments.isEmpty }
    public var canSend: Bool {
        !disabled && !context.executionDisabled && !waiting && !submitting && !attachments.importing
            && NativeComposerSubmissionPolicy.canSubmit(text: draft, attachments: attachments.attachments)
    }

    public func update(context: SidecardContext) {
        guard !lifetime.isCancelled else { return }
        let shouldFocus = context.expanded && (!self.context.expanded
            || (disabled && !context.executionDisabled && context.thread.archived != true) || (sidecardExecutionID != nil
            && executionState.sidecardExecutionID(thread: context.thread, index: context.conversationIndex, readingTarget: context.readingTarget) == nil))
        self.context = context
        reconcileExecution()
        applyFocusRequest()
        if shouldFocus && sidecardExecutionID == nil && !disabled { focusRequest += 1 }
    }

    public func changeDraft(_ value: String) {
        guard !lifetime.isCancelled else { return }
        draftRevision += 1
        rawDraft = nil
        draft = value
        persistDraft()
    }

    public func importFiles(_ files: [NativeComposerFile]) async {
        guard !disabled, !submitting, context.attachmentImport != nil else { return }
        operationError = nil
        await attachments.importFiles(files)
    }

    @discardableResult
    private func handle(_ intent: SidecardIntent) -> Bool {
        guard !lifetime.isCancelled else { return false }
        switch intent.kind {
        case .activate:
            executionState.requestFocus()
        case .compose(let initialDraft):
            _ = context.open()
            executionState.requestFocus(initialDraft: initialDraft)
        case .sendStarted(let requestID):
            executionState.sendStarted(requestID: requestID, thread: context.thread, index: context.conversationIndex,
                                       selectionRevision: context.selectionRevision(), open: context.open)
        case .sendFailed(let requestID):
            executionState.sendFailed(requestID: requestID)
        case .sendAccepted(let requestID, let receipt):
            executionState.sendAccepted(requestID: requestID, executionID: receipt.executionID, thread: context.thread,
                                        selectionRevision: context.selectionRevision(), close: context.close)
            // Receipt-driven state changes have the same derived effects as a
            // snapshot: a matching reading target must open immediately.
            reconcileExecution()
        case .openURL:
            return false
        }
        applyFocusRequest()
        switch intent.kind {
        case .activate, .compose: return true
        case .sendStarted, .sendAccepted, .sendFailed, .openURL: return false
        }
    }

    private func reconcileExecution() {
        executionState.update(thread: context.thread, index: context.conversationIndex,
                              readingTarget: context.readingTarget, expanded: context.expanded,
                              selectionRevision: context.selectionRevision(), open: context.open, close: context.close)
    }

    private func applyFocusRequest() {
        guard lastExecutionFocusRequest != executionState.focusRequest else { return }
        lastExecutionFocusRequest = executionState.focusRequest
        if let initialDraft = executionState.initialDraft {
            changeDraft(initialDraft.string)
            // Native text storage receives a repaired display string; retain the
            // original UTF-16 input until a real edit crosses that boundary.
            rawDraft = initialDraft
            persistDraft()
        }
        focusRequest += 1
    }

    public func send() async {
        guard canSend, !lifetime.isCancelled else { return }
        submitting = true
        operationError = nil
        let sentRevision = draftRevision
        let savedRevision = persistedRevision
        let text = trimmedDraft
        let send = context.send
        attachments.text = draft
        defer { if !lifetime.isCancelled { submitting = false } }
        await attachments.submit { submission in
            // Preserve the lossless text draft while sharing attachment part encoding.
            var parts = submission.input["parts"]?.arrayValue?.filter { $0["kind"] != .text("text") } ?? []
            if !text.codeUnits.isEmpty { parts.insert(.object(["kind": .text("text"), "text": .string(text)]), at: 0) }
            _ = try await send(.object(["parts": .array(parts)]))
            if let persistence, let savedRevision {
                do {
                    if let consumed = try persistence.consumeText(expectedRevision: savedRevision) {
                        // A retired sender can finish after this thread is open
                        // again. Refresh only owners still holding that exact
                        // persisted revision; even an edit back to identical
                        // text belongs to a new draft and must survive.
                        Self.owners.removeAll { $0.value == nil }
                        for owner in Self.owners.compactMap(\.value) {
                            guard let other = owner.persistence, persistence.isSameDraft(as: other),
                                  owner.persistedRevision == savedRevision else { continue }
                            owner.draftRevision += 1
                            owner.draft = consumed.textValue.string; owner.rawDraft = consumed.textValue
                            owner.persistedRevision = consumed.revision
                        }
                    }
                } catch {
                    if !lifetime.isCancelled { self.operationError = "消息已接纳，但未能更新设备草稿：\(error.localizedDescription)" }
                }
            } else if !lifetime.isCancelled, draftRevision == sentRevision {
                draft = ""; rawDraft = nil; persistDraft()
            }
        }
    }

    public func stop() async {
        guard !context.executionDisabled, !stopping, !lifetime.isCancelled else { return }
        stopping = true
        operationError = nil
        defer { if !lifetime.isCancelled { stopping = false } }
        do { try await context.actions.interrupt() }
        catch { if !lifetime.isCancelled { self.operationError = error.localizedDescription } }
    }

    private func persistDraft() {
        do { persistedRevision = try persistence?.saveText(rawDraft ?? JSONText(draft)) }
        catch { persistedRevision = nil; self.operationError = "草稿未能保存到设备：\(error.localizedDescription)" }
    }
}
