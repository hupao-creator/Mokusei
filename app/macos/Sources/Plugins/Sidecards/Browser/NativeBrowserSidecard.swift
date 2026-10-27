import Foundation
import Observation
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import SwiftUI
import WebKit

@MainActor
public struct NativeBrowserSidecard: SidecardPlugin {
    // Native WebKit belongs to the plugin; no remote desktop scope is required.
    public let descriptor = SidecardPluginDescriptor(id: "iab", displayName: "网页")
    public init() {}
    public var icon: some View { NativeIcon(name: "Globe2", size: 17, strokeWidth: 1.8) }
    public func makePresentation(context: SidecardContext, lifetime: PluginLifetime) -> BrowserSidecardPresentation {
        BrowserSidecardPresentation(context: context, lifetime: lifetime)
    }
    public func updatePresentation(_ presentation: BrowserSidecardPresentation, context: SidecardContext) {
        presentation.update(context)
    }
    public func sidecard(context: SidecardContext, presentation: BrowserSidecardPresentation) throws -> SidecardView<BrowserSidecardPane> {
        try SidecardView(available: presentation.requestedURL != nil, label: JSONText(context.translate("网页")),
                        preferredWidth: 2.0 / 3, focusContentOnOpen: false) {
            BrowserSidecardPane(presentation: presentation)
        }
    }
}

/// Data stores outlive the presentation, just as Electron's in-memory Thread
/// partitions do. Exact UTF-16 Thread identity isolate each store; none
/// writes cookies/local storage to a persistent profile or survives process exit.
@MainActor
enum BrowserRunSessions {
    private static var stores: [JSONText: WKWebsiteDataStore] = [:]
    private static let zoomMemories = NSMapTable<WKWebsiteDataStore, BrowserDocumentZoomMemory>.weakToStrongObjects()
    static func store(for thread: JSONText) -> WKWebsiteDataStore {
        let key = thread
        if let store = stores[key] { return store }
        let store = WKWebsiteDataStore.nonPersistent()
        stores[key] = store
        return store
    }
    static func documentZoomMemory(for store: WKWebsiteDataStore) -> BrowserDocumentZoomMemory {
        if let memory = zoomMemories.object(forKey: store) { return memory }
        let memory = BrowserDocumentZoomMemory()
        zoomMemories.setObject(memory, forKey: store)
        return memory
    }
}

/// Chromium's default zoom map is keyed by hostname inside its session
/// partition (including across schemes/ports), not by a full URL origin.
@MainActor
final class BrowserDocumentZoomMemory: NSObject {
    var levels: [String: Double] = [:]
}

@MainActor @Observable
public final class BrowserSidecardPresentation {
    let coordinateSpaceID = UUID()
    var context: SidecardContext
    var requestedURL: URL?
    var session: BrowserWebSession?
    var pending: [BrowserPendingAnnotation] = []
    var supplementalText = ""
    var sending = false
    var sendError = ""
    var detailsExpanded = false
    var selectedAnnotationID: UUID?
    var preview = false
    var annotationError = ""
    var released = false
    @ObservationIgnored private var submitted: [JSONText: BrowserSubmittedAnnotations] = [:]
    @ObservationIgnored private var sendTask: Task<Void, Never>?
    @ObservationIgnored private var contextGeneration = 0

    init(context: SidecardContext, lifetime: PluginLifetime) {
        self.context = context
        context.onIntent(lifetime: lifetime) { [weak self] intent in
            guard let self, case let .openURL(raw) = intent.kind,
                  let url = BrowserURL.absolute(raw.string) else { return false }
            self.open(url)
            _ = self.context.open()
            return true
        }
        lifetime.onCancel { [weak self] in self?.release() }
    }

    var annotationDisabled: Bool { pending.count >= 20 || context.executionDisabled || context.thread.archived == true }
    var canSend: Bool {
        !context.executionDisabled && !sending && (!supplementalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pending.isEmpty)
            && pending.allSatisfy { !$0.comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    var nativeHidden: Bool { released || context.suppressed || context.transitioning || !context.expanded || session?.error != nil }

    func update(_ next: SidecardContext) {
        if context.thread.id != next.thread.id {
            // A retained presentation must never deliver an old page callback or
            // screenshot into another host even when thread identifiers collide.
            contextGeneration += 1
            session?.release(); session = nil
            requestedURL = nil; pending = []; submitted = [:]
            supplementalText = ""; sendError = ""; annotationError = ""
            selectedAnnotationID = nil; preview = false; detailsExpanded = false; sending = false
        }
        context = next
        if !next.expanded {
            session?.cancelAnnotation()
            annotationError = ""
        }
        // Immediate native visibility is also applied before SwiftUI reconciliation.
        session?.setSuppressed(nativeHidden)
        if let execution = next.thread.observation.latestExecution,
           let delivery = submitted[execution.executionID] {
            switch execution.status {
            case .completed: submitted[execution.executionID] = nil
            case .failed, .interrupted:
                submitted[execution.executionID] = nil
                let ids = Set(pending.map(\.id))
                pending = delivery.batch.filter { !ids.contains($0.id) } + pending
                supplementalText = [delivery.text, supplementalText].filter { !$0.isEmpty }.joined(separator: " ")
                sendError = execution.status == .failed ? "执行失败，批注已恢复。可以重试，或仅发送文字。" : "执行已停止，批注已恢复。"
            case .running, .waitingForUser: break
            }
        }
    }

    func open(_ url: URL) {
        requestedURL = url
        annotationError = ""
        if session == nil || session?.terminated == true {
            session?.release()
            let next = BrowserWebSession(store: BrowserRunSessions.store(for: context.thread.id))
            next.backToOverview = { [weak self] in self?.context.backToOverview() }
            next.onAnnotation = { [weak self] annotation in
                guard let self, !self.released, self.pending.count < 20 else { return }
                self.pending.append(annotation)
            }
            session = next
        }
        session?.navigate(url)
        session?.setSuppressed(nativeHidden)
    }

    func retry() {
        guard let session else { if let requestedURL { open(requestedURL) }; return }
        if session.terminated { if let url = session.pendingURL ?? session.webView.url ?? requestedURL { open(url) } }
        else { session.retry() }
    }

    func annotate() {
        guard let session else { return }
        if session.annotating { session.cancelAnnotation() }
        else if !annotationDisabled { session.beginAnnotation() }
    }

    func remove(_ id: UUID) {
        guard !sending else { return }
        pending.removeAll { $0.id == id }
        if selectedAnnotationID == id { selectedAnnotationID = nil; preview = false }
        if pending.isEmpty { supplementalText = ""; sendError = ""; detailsExpanded = false }
    }

    func send(textOnly: Bool = false) {
        guard canSend, !released else { return }
        if context.thread.archived == true { sendError = "此 Thread 已归档，请取消归档后发送。"; return }
        if context.thread.observation.latestExecution?.status == .waitingForUser {
            sendError = "请先处理此 Thread 等待中的交互，再发送批注。"; return
        }
        let batch = pending, text = supplementalText
        let boundContext = context
        let owner = contextGeneration
        sending = true; sendError = ""
        sendTask = Task { [weak self] in
            var staged: [JSONText] = []
            var directory: URL?
            do {
                var attachments: [SidecardStagedAttachment] = []
                if !textOnly && !batch.isEmpty {
                    let prepared = try await BrowserAnnotationFiles.shared.write(batch.map(\.png))
                    directory = prepared.directory
                    try Task.checkCancellation()
                    guard let self, !self.released, self.contextGeneration == owner else { throw CancellationError() }
                    let files = prepared.files
                    attachments = try await boundContext.stageAttachments(files)
                    staged = attachments.map(\.id)
                    guard attachments.count == batch.count else { throw PluginContractError("批注截图数量不匹配") }
                }
                guard let self, !self.released, self.contextGeneration == owner else { throw CancellationError() }
                var parts: [JSONValue] = []
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { parts.append(.object(["kind": .text("text"), "text": .text(trimmed)])) }
                let annotations = try batch.enumerated().map { index, annotation in
                    let attachment = index < attachments.count ? attachments[index].id : nil
                    parts.append(.object(["kind": .text("text"), "text": .text(try annotation.modelContext(screenshotID: attachment)), "annotationId": .text(annotation.id.uuidString.lowercased())]))
                    if let attachment { parts.append(.object(["kind": .text("image"), "file": .object(["id": .string(attachment)])])) }
                    return annotation.json(screenshotID: attachment)
                }
                var input: [JSONText: JSONValue] = ["parts": .array(parts)]
                if !annotations.isEmpty { input["annotations"] = .array(annotations) }
                let receipt = try await boundContext.send(.object(input))
                guard !self.released, self.contextGeneration == owner else { throw CancellationError() }
                let execution = self.context.thread.observation.latestExecution
                let outcome = execution?.executionID == receipt.executionID ? execution?.status : nil
                if outcome == .failed { throw PluginContractError("执行失败，批注仍保留。详情见线程记录。") }
                if outcome == .interrupted { throw PluginContractError("执行已停止，批注仍保留。") }
                if outcome != .completed {
                    let previous = self.submitted[receipt.executionID]
                    self.submitted[receipt.executionID] = BrowserSubmittedAnnotations(batch: (previous?.batch ?? []) + batch,
                        text: [previous?.text ?? "", text].filter { !$0.isEmpty }.joined(separator: " "))
                }
                let ids = Set(batch.map(\.id))
                self.pending.removeAll { ids.contains($0.id) }
                if self.supplementalText == text { self.supplementalText = "" }
                self.preview = false; self.selectedAnnotationID = nil; self.detailsExpanded = false
            } catch {
                if let self, !self.released, self.contextGeneration == owner { self.sendError = error.localizedDescription }
            }
            // Runtime retention protects attachments referenced by accepted input.
            if !staged.isEmpty { try? await boundContext.discardAttachments(staged) }
            if let directory { await BrowserAnnotationFiles.shared.remove(directory) }
            if let self, self.contextGeneration == owner || self.released { self.sending = false }
        }
    }

    func release() {
        guard !released else { return }
        released = true
        contextGeneration += 1
        session?.release(); session = nil
        // An accepted command owns its runtime lifetime. Leave the send cleanup
        // task alive so staged files are discarded even when the view disappears.
        pending = []; submitted = [:]
    }
}

struct BrowserSubmittedAnnotations { let batch: [BrowserPendingAnnotation]; let text: String }

enum BrowserURL {
    static func isLoopback(_ url: URL) -> Bool {
        ClientWebNavigation.isLoopback(url)
    }
    static func absolute(_ raw: String) -> URL? {
        guard let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }
    static func address(_ raw: String) -> URL? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let absolute = absolute(value) { return absolute }
        guard !value.isEmpty, value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        let hostPort = value.range(of: #"^[\w.-]+:\d+(?:[/?#]|$)"#, options: .regularExpression) != nil
        if !hostPort && value.range(of: #"^[a-z][a-z\d+.-]*:"#, options: [.regularExpression, .caseInsensitive]) != nil { return nil }
        guard let parsed = absolute("https://" + value), var components = URLComponents(url: parsed, resolvingAgainstBaseURL: false) else { return nil }
        if isLoopback(parsed) { components.scheme = "http" }
        return components.url
    }
}
