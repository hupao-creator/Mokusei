import Foundation
import Observation
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import SwiftUI

struct NativeSidecardWorkspaceConfiguration: Equatable {
    var input: HarnessThreadInput
    var executionDisabled: Bool
    var suppressed: Bool
    var enabledIDs: Set<JSONText>?
    var followUpRequest: NativeSidecardFollowUpRequest?
    var locale: Locale
}

@MainActor
struct NativeSidecardWorkspaceCard: Identifiable {
    let id: JSONText
    let icon: AnyView
    let view: SidecardView<AnyView>
}

@MainActor
struct NativeSidecardWorkspaceSnapshot {
    let input: HarnessThreadInput
    let cards: [NativeSidecardWorkspaceCard]
    let selected: JSONText?
    let lastSelected: JSONText?
    let selectionRevision: Int
    let transitioning: Bool
    let dragging: Bool
    let widths: [JSONText: CGFloat]
    let requestError: String?
    let executionDisabled: Bool
    let suppressed: Bool

    var available: [NativeSidecardWorkspaceCard] { cards.filter { $0.view.available } }
    // Folding never gives the main view ownership of a sidecard's execution.
    var excludedExecutionIDs: [JSONText] { cards.compactMap { $0.view.excludeExecutionID } }
}

/// Updates happen outside View.body. Plugins may open/close during reconciliation;
/// those requests are settled before one snapshot publishes input and metadata.
@MainActor @Observable
final class NativeSidecardWorkspaceModel {
    private(set) var snapshot: NativeSidecardWorkspaceSnapshot?
    @ObservationIgnored let harnessHost: NativeHarnessHost
    @ObservationIgnored private let registry: SidecardPluginRegistry
    @ObservationIgnored private var services: NativeSidecardWorkspaceServices
    @ObservationIgnored private var configuration: NativeSidecardWorkspaceConfiguration
    @ObservationIgnored private var onBack: () -> Void
    @ObservationIgnored private var onVisibilityChange: (Bool) -> Void
    @ObservationIgnored private var sessions: [JSONText: SidecardSession] = [:]
    @ObservationIgnored private var failures: [JSONText: String] = [:]
    @ObservationIgnored private var handlers: [JSONText: [(UUID, (SidecardIntent) -> Bool)]] = [:]
    @ObservationIgnored private var selected: JSONText?
    @ObservationIgnored private var lastSelected: JSONText?
    @ObservationIgnored private var selectionRevision = 0
    @ObservationIgnored private var conversationIndex: ThreadConversationIndex?
    @ObservationIgnored private var widths: [JSONText: CGFloat] = [:]
    @ObservationIgnored private var dragging = false
    @ObservationIgnored private var transitioning = false
    @ObservationIgnored private var requestError: String?
    @ObservationIgnored private var requestSequence = 0.0
    @ObservationIgnored private var handledFollowUp: Int?
    @ObservationIgnored private var lastVisibility = false
    @ObservationIgnored private var isReleased = false
    @ObservationIgnored private var reconciling = false
    @ObservationIgnored private var needsReconciliation = false
    @ObservationIgnored private var dispatchDepth = 0
    @ObservationIgnored private var observationGeneration = 0
    @ObservationIgnored private var transitionTask: Task<Void, Never>?

    init(harnessHost: NativeHarnessHost, registry: SidecardPluginRegistry,
         configuration: NativeSidecardWorkspaceConfiguration, services: NativeSidecardWorkspaceServices,
         onBack: @escaping () -> Void, onVisibilityChange: @escaping (Bool) -> Void) {
        self.harnessHost = harnessHost; self.registry = registry; self.configuration = configuration
        self.services = services; self.onBack = onBack; self.onVisibilityChange = onVisibilityChange
    }

    var routes: NativeHarnessThreadRoutes {
        NativeHarnessThreadRoutes(openFollowUp: { [weak self] in self?.compose($0) },
            openExternal: { [weak self] url in
                guard let self else { throw CancellationError() }
                try await openExternal(url)
            })
    }

    func update(configuration: NativeSidecardWorkspaceConfiguration, services: NativeSidecardWorkspaceServices,
                onBack: @escaping () -> Void, onVisibilityChange: @escaping (Bool) -> Void) {
        guard !isReleased else { return }
        self.configuration = configuration; self.services = services
        self.onBack = onBack; self.onVisibilityChange = onVisibilityChange
        reconcile()
        if let request = configuration.followUpRequest, request.requestKey != handledFollowUp {
            handledFollowUp = request.requestKey
            compose(request.initialDraft)
        }
    }

    func receiveIndex(_ index: ThreadConversationIndex) {
        // Harnesses may publish this from render. Defer all observable writes.
        Task { @MainActor [weak self] in
            guard let self, !isReleased, conversationIndex != index else { return }
            conversationIndex = index
            reconcile()
        }
    }

    func activate(_ id: JSONText) {
        dispatchDepth += 1
        _ = choose(selected == id ? nil : id)
        if selected == id { _ = dispatch(.activate, target: id) }
        dispatchDepth -= 1
        reconcile()
    }

    func close(_ id: JSONText) { if selected == id { _ = choose(nil) } }

    func resize(_ width: CGFloat, maximum: CGFloat) {
        guard let id = selected ?? lastSelected, width.isFinite else { return }
        widths[id] = min(max(320, maximum), max(320, width))
        reconcile()
    }

    func setDragging(_ value: Bool) {
        guard dragging != value else { return }
        dragging = value; reconcile()
    }

    func release() {
        guard !isReleased else { return }
        isReleased = true; observationGeneration += 1
        transitionTask?.cancel(); transitionTask = nil
        for session in sessions.values { session.release() }
        sessions.removeAll(); handlers.removeAll()
        if lastVisibility { onVisibilityChange(false) }
    }

    private var modules: [AnySidecardPlugin] {
        registry.modules.filter { configuration.enabledIDs?.contains($0.descriptor.id) ?? true }
    }

    @discardableResult
    private func choose(_ id: JSONText?) -> Int {
        guard !isReleased else { return selectionRevision }
        selectionRevision += 1
        if selected != id {
            selected = id
            if let id { lastSelected = id }
            transitionTask?.cancel()
            transitioning = true
            transitionTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .milliseconds(380)) } catch { return }
                guard let self, !isReleased else { return }
                transitioning = false; reconcile()
            }
        }
        needsReconciliation = true
        if !reconciling && dispatchDepth == 0 { reconcile() }
        return selectionRevision
    }

    private func compose(_ draft: JSONText?) {
        guard !isReleased, configuration.input.thread.archived != true else { return }
        let accepted = dispatch(.compose(initialDraft: draft))
        requestError = accepted ? nil : translate("没有已启用的 Sidecard 可以输入消息。")
        reconcile()
    }

    private func openExternal(_ url: JSONText) async throws {
        guard !isReleased else { throw CancellationError() }
        if !dispatch(.openURL(url)) { try await services.openExternal(url) }
    }

    @discardableResult
    private func dispatch(_ kind: SidecardIntent.Kind, target: JSONText? = nil) -> Bool {
        guard !isReleased, let intent = try? SidecardIntent(kind) else { return false }
        let notification: Bool
        switch kind {
        case .sendStarted, .sendAccepted, .sendFailed: notification = true
        case .activate, .compose, .openURL: notification = false
        }
        dispatchDepth += 1
        defer {
            dispatchDepth -= 1
            if dispatchDepth == 0 { reconcile() }
        }
        var accepted = false
        for module in modules where target == nil || target == module.descriptor.id {
            for (id, handler) in handlers[module.descriptor.id] ?? [] {
                guard handlers[module.descriptor.id]?.contains(where: { $0.0 == id }) == true else { continue }
                if handler(intent) {
                    accepted = true
                    if !notification { return true }
                }
            }
        }
        return accepted
    }

    private func send(_ input: JSONValue) async throws -> SidecardSendReceipt {
        guard !isReleased, !configuration.executionDisabled, configuration.input.thread.archived != true else {
            throw PluginContractError("This thread currently cannot accept input")
        }
        requestSequence += 1
        let requestID = requestSequence
        let threadID = configuration.input.thread.id
        _ = dispatch(.sendStarted(requestID: requestID))
        do {
            let receipt = try await services.send(threadID, input)
            // Never infer the new execution from a possibly lagging observation.
            // An accepted receipt still belongs to the submitted draft after
            // its view retires. Only presentation events need a live workspace.
            if !isReleased { _ = dispatch(.sendAccepted(requestID: requestID, receipt: receipt)) }
            return receipt
        } catch {
            _ = dispatch(.sendFailed(requestID: requestID))
            throw error
        }
    }

    private func context(for module: AnySidecardPlugin) -> SidecardContext {
        let id = module.descriptor.id
        let input = configuration.input
        let disabled = configuration.executionDisabled
        let stageAttachments = services.stageAttachments
        let discardAttachments = services.discardAttachments
        return SidecardContext(thread: input.thread, conversationIndex: conversationIndex,
            actions: harnessHost.actions(for: input.thread, routes: routes), readingTarget: input.readingTarget,
            executionDisabled: disabled, expanded: selected == id, transitioning: transitioning,
            suppressed: configuration.suppressed || dragging || transitioning || selected != id,
            conversation: { [weak self] executionID, target in
                guard let self else { return AnyView(EmptyView()) }
                return AnyView(NativeHarnessThreadView(host: harnessHost,
                    input: HarnessThreadInput(thread: input.thread, readingTarget: target),
                    presentation: .execution(executionID), routes: routes)
                    .disabled(disabled))
            }, voice: services.voice,
            open: { [weak self] in self?.choose(id) ?? 0 },
            close: { [weak self] in self?.close(id) },
            selectionRevision: { [weak self] in self?.selectionRevision ?? 0 },
            onIntent: { [weak self] handler in
                guard let self, !isReleased else { return {} }
                let token = UUID()
                handlers[id, default: []].append((token, handler))
                return { [weak self] in self?.handlers[id]?.removeAll { $0.0 == token } }
            }, send: { [weak self] input in
                guard let self else { throw CancellationError() }
                return try await send(input)
            }, stageAttachments: { [weak self] files in
                guard self?.isReleased == false else { throw CancellationError() }
                let staged = try await stageAttachments(files)
                guard self?.isReleased == false else {
                    if !staged.isEmpty {
                        do { try await discardAttachments(staged.map(\.id)) }
                        catch { NSLog("Sidecard attachment cleanup failed after workspace release: %@", error.localizedDescription) }
                    }
                    throw CancellationError()
                }
                return staged
            }, discardAttachments: discardAttachments,
            backToOverview: { [weak self] in self?.onBack() },
            translate: { [weak self] in self?.translate($0) ?? $0 },
            draftStorageDirectory: harnessHost.client.storageDirectory, attachmentImport: services.attachmentImport)
    }

    private func retry(_ id: JSONText) {
        sessions.removeValue(forKey: id)?.release()
        failures[id] = nil
        reconcile()
    }

    private func translate(_ source: String) -> String {
        let chinese = configuration.locale.language.languageCode?.identifier == "zh"
        guard !chinese else { return source }
        return ["没有已启用的 Sidecard 可以输入消息。": "No enabled Sidecard can compose messages.",
                "重试": "Retry", "收起卡片": "Collapse card", "输入与执行": "Input and execution",
                "输入与执行卡片": "Input and execution card", "需要回应": "Response needed",
                "输入消息": "Message", "错误": "Error", "停止当前轮": "Stop current turn",
                "补充到当前轮": "Add to current turn", "发送消息": "Send message",
                "此 Thread 已归档": "This thread is archived", "等待回应…": "Waiting for a response…",
                "补充…": "Add more…", "输入消息…": "Type a message…"][source]
            ?? NativePluginLocalization.localize(source, locale: configuration.locale)
    }

    private func reconcile() {
        guard !isReleased else { return }
        guard !reconciling, dispatchDepth == 0 else { needsReconciliation = true; return }
        reconciling = true
        defer { reconciling = false }
        let activeModules = modules
        let activeIDs = Set(activeModules.map { $0.descriptor.id })
        for id in Array(sessions.keys) where !activeIDs.contains(id) {
            sessions.removeValue(forKey: id)?.release()
            failures[id] = nil; handlers[id] = nil
        }
        if let selected, !activeIDs.contains(selected) { _ = choose(nil) }
        var cards: [NativeSidecardWorkspaceCard] = []
        var passes = 0
        repeat {
            needsReconciliation = false; passes += 1; observationGeneration += 1
            let generation = observationGeneration
            // Update presentation owners before observing metadata; old observers
            // are invalidated by generation and cannot recursively schedule work.
            for module in activeModules {
                let id = module.descriptor.id
                guard failures[id] == nil else { continue }
                do {
                    if let session = sessions[id] { try session.update(context: context(for: module)) }
                    else { sessions[id] = try module.makeSession(context: context(for: module)) }
                } catch { failures[id] = error.localizedDescription }
            }
            cards = withObservationTracking {
                activeModules.map { module in
                    let id = module.descriptor.id
                    if failures[id] == nil, let session = sessions[id] {
                        do { return NativeSidecardWorkspaceCard(id: id, icon: module.icon, view: try session.view()) }
                        catch { failures[id] = error.localizedDescription }
                    }
                    return NativeSidecardWorkspaceCard(id: id, icon: module.icon, view: failureView(module))
                }
            } onChange: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, !isReleased, observationGeneration == generation else { return }
                    reconcile()
                }
            }
        } while needsReconciliation && passes < 16
        snapshot = NativeSidecardWorkspaceSnapshot(input: configuration.input, cards: cards,
            selected: selected, lastSelected: lastSelected, selectionRevision: selectionRevision,
            transitioning: transitioning, dragging: dragging, widths: widths, requestError: requestError,
            executionDisabled: configuration.executionDisabled, suppressed: configuration.suppressed)
        let visible = cards.contains { $0.id == selected && $0.view.acceptsInput == true }
        if lastVisibility != visible { lastVisibility = visible; onVisibilityChange(visible) }
    }

    private func failureView(_ module: AnySidecardPlugin) -> SidecardView<AnyView> {
        let id = module.descriptor.id
        // The fallback has a known finite width and cannot fail validation.
        return try! SidecardView(available: true, label: module.descriptor.displayName,
            indicator: .attention, preferredWidth: 1 / 3) {
                AnyView(VStack(alignment: .leading, spacing: 12) {
                    Text("\(module.descriptor.displayName.string): \(failures[id] ?? "Sidecard unavailable")")
                        .foregroundStyle(NativePalette.thread.danger.swiftUI).textSelection(.enabled)
                    Button(translate("重试")) { [weak self] in self?.retry(id) }
                    Button(translate("收起卡片")) { [weak self] in self?.close(id) }
                    Spacer(minLength: 0)
                }.font(.system(size: 12)).padding(12))
            }
    }
}
