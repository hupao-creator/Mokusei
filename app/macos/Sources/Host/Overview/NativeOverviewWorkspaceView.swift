import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import SwiftUI

@MainActor
public struct NativeOverviewWorkspaceCallbacks {
    public let openThread: (JSONText, HarnessReadingTarget?) -> Void
    public let openApplication: (ApplicationThreadRef, HarnessReadingTarget?) -> Void
    public let onSettings: () -> Void
    /// Settings bounds in the logical client viewport, with a top-left origin.
    public let onSettingsWithOrigin: ((CGRect) -> Void)?
    public let onSettingsFrameChange: ((CGRect?) -> Void)?
    public let onFollowUp: ((JSONText, JSONText) -> Void)?
    public let onRestart: (() -> Void)?
    public init(openThread: @escaping (JSONText, HarnessReadingTarget?) -> Void,
                openApplication: @escaping (ApplicationThreadRef, HarnessReadingTarget?) -> Void,
                onSettings: @escaping () -> Void, onFollowUp: ((JSONText, JSONText) -> Void)? = nil,
                onRestart: (() -> Void)? = nil,
                onSettingsWithOrigin: ((CGRect) -> Void)? = nil,
                onSettingsFrameChange: ((CGRect?) -> Void)? = nil) {
        self.openThread = openThread; self.openApplication = openApplication
        self.onSettings = onSettings; self.onFollowUp = onFollowUp; self.onRestart = onRestart
        self.onSettingsWithOrigin = onSettingsWithOrigin; self.onSettingsFrameChange = onSettingsFrameChange
    }
}

/// A stable reference for the current callbacks. The view is reconstructed with
/// fresh closures by its owner, but already-mounted cards retain this store, so
/// actions always invoke the latest receiver.
@MainActor private final class NativeOverviewWorkspaceCallbackStore {
    var current: NativeOverviewWorkspaceCallbacks
    init(_ callbacks: NativeOverviewWorkspaceCallbacks) { current = callbacks }
}

/// Full overview composition; all semantic content is rendered by the owning native
/// plugin snapshot. The surrounding navigation/Moku scene remains owned by the shell.
@MainActor
public struct NativeOverviewWorkspaceView: View {
    public let model: NativeOverviewWorkspaceModel
    public let callbacks: NativeOverviewWorkspaceCallbacks
    public var interactionPaused: Bool
    public var clickExclusions: NativeClickExclusions
    public var landing: Bool
    @Environment(\.nativeCanvasInputRegions) private var sharedInputRegions
    @State private var localInputRegions = NativeCanvasInputRegions()
    @State private var callbackStore: NativeOverviewWorkspaceCallbackStore
    private var inputRegions: NativeCanvasInputRegions { sharedInputRegions ?? localInputRegions }
    private var locale: DesktopLocale { model.workspace.preferences.locale }
    public init(model: NativeOverviewWorkspaceModel, callbacks: NativeOverviewWorkspaceCallbacks,
                interactionPaused: Bool = false, clickExclusions: NativeClickExclusions = .init(), landing: Bool = false) {
        self.model = model; self.callbacks = callbacks; self.interactionPaused = interactionPaused
        self.clickExclusions = clickExclusions
        self.landing = landing
        _callbackStore = State(initialValue: NativeOverviewWorkspaceCallbackStore(callbacks))
    }
    public var body: some View {
        callbackStore.current = callbacks
        return GeometryReader { geometry in
            let viewport = Self.viewport(in: geometry.size, hasFilters: !model.filters.isEmpty,
                                         hasDock: model.workspace.catalog.moku != nil)
            ZStack {
                NativeOverviewCanvas(items: model.items, sceneKey: model.sceneKey, state: model.canvasState,
                    selectionID: selectionID,
                    toolbarBottom: viewport.toolbarBottom, bottomReservedHeight: viewport.bottomReservedHeight,
                    visible: model.facts.overviewVisible && model.facts.documentVisible && !landing,
                    cloudAnimationsEnabled: !model.facts.settingsOpen && !landing,
                    glassWorld: model.workspace.preferences.glassWorld,
                    interactionPaused: interactionPaused, resetEpoch: model.recoveryEpoch,
                    revisions: model.revisions, onRevisionsConsumed: { model.consumeRevisions(through: $0) },
                    onRetainedPresentationIDsChanged: { model.retainPresentations($0) },
                    cardContentIdentity: ObjectIdentifier(model),
                    inputRegions: inputRegions) { item in
                        NativeOverviewWorkspaceCard(item: item, model: model, callbacks: callbackStore)
                            .environment(\.locale, Locale(identifier: model.workspace.preferences.locale.rawValue))
                    }
                    .opacity(landing ? 0 : 1)
                    .allowsHitTesting(!landing)
                    .accessibilityHidden(landing)
                if !landing && model.items.isEmpty && model.error == nil {
                    NativeOverviewEmptyState(title: emptyTitle, detail: emptyDetail)
                }
                if let error = model.error ?? model.canvasState.layoutError {
                    VStack {
                        HStack(spacing: 8) {
                            Text(locale.text("布局暂未更新，请重试。", "The layout could not be updated. Please retry."))
                                .help(error)
                            Button(locale.text("重试", "Retry")) {
                                model.refresh()
                                model.canvasState.retryLayout()
                            }.buttonStyle(.plain).foregroundStyle(NativePalette.overview.accent.swiftUI)
                        }.font(NativeTypography.inter(size: 12)).padding(10)
                            .background(NativePalette.overview.surface.swiftUI, in: RoundedRectangle(cornerRadius: 8))
                            .padding(.top, 72)
                        Spacer()
                    }
                    .accessibilityLabel(error)
                }
                if model.canvasState.overflowAttentionCount > 0 {
                    VStack {
                        Spacer()
                        NativeOverviewAttentionIndicator(text: locale.text("\(model.canvasState.overflowAttentionCount) 待介入", "\(model.canvasState.overflowAttentionCount) need attention"))
                            .padding(.bottom, 20)
                    }
                }
            }
            .overlay {
                NativeOverviewRefreshDecoration(operation: model.featuredOperation,
                    visible: model.facts.overviewVisible && model.facts.documentVisible && !landing).allowsHitTesting(false)
            }
            .overlay(alignment: .top) {
                NativeOverviewChrome(filters: landing ? [] : model.visibleFilters, selectedTag: model.selectedTag,
                    selectedScope: model.selectedScope, selectedKind: model.tagSelection?.kind,
                    cameraManual: model.canvasState.camera.manual,
                    focusFilterRequestKey: model.focusFilterRequestKey, strings: chromeStrings,
                    isSearching: model.isSearching, searchQuery: model.searchQuery,
                    searchFocusRequest: model.searchFocusRequest, onSearchChange: model.updateSearch,
                    onSearchExit: model.endSearch,
                    onTagChange: model.selectTag,
                    onReturnToAuto: { model.canvasState.camera.returnToAuto() }, onSettings: callbacks.onSettings,
                    onRestart: callbacks.onRestart, onFocusFilterRequestConsumed: model.consumeFilterFocus,
                    onSettingsWithOrigin: callbacks.onSettingsWithOrigin,
                    onSettingsFrameChange: callbacks.onSettingsFrameChange,
                    clickExclusions: clickExclusions, interactions: model.chromeInteractions)
            }
        }
        .environment(\.nativeCanvasInputRegions, inputRegions)
        .environment(\.locale, Locale(identifier: locale.rawValue))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(locale.text("会话俯瞰", "Conversation overview"))
    }
    static func viewport(in size: CGSize, hasFilters: Bool, hasDock: Bool) -> NativeOverviewViewport {
        // Reserve the persistent seat, not transient composer/note growth:
        // opening an overlay must not repack the scene underneath the user.
        let dock = NativeMokuCapsuleLayout.idleSurface(in: CGRect(origin: .zero, size: size))
        return .init(width: size.width, height: size.height,
                     toolbarBottom: size.width <= 620 && hasFilters
                        ? OverviewTagMetrics.narrowToolbarClearance : OverviewTagMetrics.wideToolbarClearance,
                     bottomReservedHeight: hasDock ? size.height - dock.minY : 0)
    }

    private var emptyDetail: String {
        if model.isSearching {
            return locale.text("试试其他关键词、清空搜索，或切换标签范围。",
                               "Try another keyword, clear the search, or change the tag scope.")
        }
        return locale.text("切换标签筛选以查看其他 Thread。", "Switch tag filters to see other threads.")
    }
    private var emptyTitle: String {
        if model.isSearching && !NativeOverviewSearch(model.searchQuery).terms.isEmpty {
            return locale.text("没有匹配的会话", "No matching conversations")
        }
        if !model.selectedTag.isEmpty { return locale.text("没有 \(model.selectedFilter?.tag ?? model.selectedTag) 会话", "No \(model.selectedFilter?.tag ?? model.selectedTag) conversations") }
        return locale.text("还没有会话", "No conversations yet")
    }
    private var selectionID: String? {
        if model.isSearching && !NativeOverviewSearch(model.searchQuery).terms.isEmpty { return nil }
        if let filter = model.selectedFilter { return filter.id }
        if model.selectedTag.isEmpty { return "__all__" }
        return "\(model.tagSelection?.kind == .directory ? "directory" : "semantic"):\(model.selectedScope):\(NativeOverviewSelection.key(model.selectedTag))"
    }
    private var chromeStrings: NativeOverviewChromeStrings {
        var strings = NativeOverviewChromeStrings()
        if locale == .english {
            strings.all = "All"; strings.returnToAuto = "Return to automatic view"
            strings.settings = "Settings"; strings.restart = "Restart development app"; strings.actions = "Overview actions"
            strings.search = "Search conversations"; strings.searchIn = "Search in"; strings.closeSearch = "Close search (Esc)"
            strings.closeFilter = "Close child tag menu"
            strings.filter = "Filter by tag"; strings.directoryPrefix = "Working directory: "; strings.aliasPrefix = "; aliases: "
        }
        return strings
    }
}

@MainActor
private struct NativeOverviewWorkspaceCard: View {
    let item: NativeOverviewItem
    let model: NativeOverviewWorkspaceModel
    let callbacks: NativeOverviewWorkspaceCallbackStore
    @State private var lifetime = PluginLifetime()
    @State private var error: String?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.locale) private var locale

    var body: some View {
        #if OVERVIEW_PERF_DIAGNOSTICS
        let _: Void = OverviewPerformanceDiagnostics.workspaceCardBody()
        #endif
        return Group {
            switch model.snapshot(for: item) {
            case .harness(let snapshot):
                #if OVERVIEW_PERF_DIAGNOSTICS
                let _: Void = OverviewPerformanceDiagnostics.workspaceCard(itemID: item.id,
                    title: snapshot.input.thread.title.string, presentationID: item.presentationID,
                    completed: item.completed, locale: locale.identifier)
                #endif
                let thread = snapshot.input.thread
                snapshot.card(actions: actions(thread), openThread: { open(thread.id) })
                    .environment(\.openGitWorktree, { id in
                        guard model.canvasState.allowsActivation(cardID: item.id),
                              let current = model.workspace.catalog.thread(thread.id),
                              model.applicationFactories.gitStatus(current)?.id == id else { return }
                        callbacks.current.openApplication(.init(threadID: id, typeID: "git.worktree"), nil)
                    })
                    .environment(\.threadCardLogo, { @MainActor in
                        (try? model.workspace.harnessHost.registry.require(thread.harnessID))?.logo(size: 12) ?? AnyView(EmptyView())
                    })
                    .contentShape(RoundedRectangle(cornerRadius: 22))
                    .onTapGesture { open(thread.id) }
                    .focusable()
                    .focusEffectDisabled()
                    .onKeyPress(.return) { open(thread.id); return .handled }
                    .accessibilityAction(named: Text(model.workspace.preferences.locale.text("打开会话", "Open conversation"))) { open(thread.id) }
            case .application(let plugin, let snapshot):
                applicationCard(plugin: plugin, snapshot: snapshot)
            case nil:
                // Removed entities retain an inert geometric slot until the queued
                // exit/reflow commits. They never acquire fresh execution authority.
                Color.clear.allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .environment(\.locale, locale)
        .overlay {
            NativeOverviewWorkspaceCardOperation(itemID: item.id, model: model)
        }
        .overlay(alignment: .bottomTrailing) {
            if let rank = model.searchRank(for: item.id) {
                Text(model.workspace.preferences.locale.text("相关度 #\(rank + 1)", "Match #\(rank + 1)"))
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    .padding(12).allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let error { Text(error).font(NativeTypography.inter(size: 10)).foregroundStyle(NativePalette.overview.danger.swiftUI).padding(12) }
        }
        .onAppear { if lifetime.isCancelled { lifetime = PluginLifetime() } }
        .onDisappear { lifetime.cancel() }
    }
    private func open(_ id: JSONText) {
        guard model.canvasState.allowsActivation(cardID: item.id) else { return }
        callbacks.current.openThread(id, nil)
        Task { await model.recordUserAction(kind: "open-thread", thread: .init(threadID: id, typeID: JSONText("agent"))) }
    }
    private func actions(_ thread: HarnessThread) -> HarnessThreadActions {
        let actions = model.workspace.harnessHost.actions(for: thread)
        return .init(interrupt: actions.interrupt, respond: { request in
            model.canvasState.beginInteraction(cardID: item.id)
            defer { model.canvasState.endInteraction(cardID: item.id) }
            try await actions.respond(request)
        }, invokeHarnessExtension: actions.invokeHarnessExtension, forkThread: actions.forkThread,
        openExternal: actions.openExternal, openFollowUp: { draft in
            guard model.canvasState.allowsActivation(cardID: item.id),
                  let current = model.workspace.catalog.thread(thread.id), current.archived != true else { return }
            if let onFollowUp = callbacks.current.onFollowUp { onFollowUp(thread.id, draft) }
            else { actions.openFollowUp(draft) }
        })
    }
    private func applicationCard(plugin: AnyApplicationThreadPlugin, snapshot: ApplicationOverviewSnapshot) -> AnyView {
        do {
            let provided = try model.applicationFactories.rendererContext(plugin, snapshot.entry, lifetime)
            let context = ApplicationRendererContext(theme: provided.theme, locale: provided.locale, lifetime: provided.lifetime,
                domain: provided.domain, capabilities: provided.capabilities, openThread: { reference, target in
                    guard model.canvasState.allowsActivation(cardID: item.id) else { return }
                    provided.openThread(reference, target)
                }, openExecution: { reference in
                    guard model.canvasState.allowsActivation(cardID: item.id) else { return }
                    provided.openExecution(reference)
                })
            return try snapshot.card(context: context, openThread: {
                guard plugin.hasDetail, model.canvasState.allowsActivation(cardID: item.id) else { return }
                callbacks.current.openApplication(snapshot.entry.ref, nil)
                Task { await model.recordUserAction(kind: "open-thread", thread: snapshot.entry.ref) }
            })
        } catch {
            return AnyView(VStack(alignment: .leading, spacing: 8) {
                Text(snapshot.entry.title.string).font(NativeTypography.inter(size: 15, weight: 620))
                Text(error.localizedDescription).font(NativeTypography.inter(size: 11)).foregroundStyle(NativePalette.overview.danger.swiftUI)
            }.padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
        }
    }
}

/// Keep operation/visibility observation out of the card's focusable subtree.
private struct NativeOverviewWorkspaceCardOperation: View {
    let itemID: String
    let model: NativeOverviewWorkspaceModel
    var body: some View {
        if let operation = model.operation(for: itemID) {
            NativeOverviewOperationDecoration(operation: operation,
                visible: model.facts.overviewVisible && model.facts.documentVisible).allowsHitTesting(false)
        }
    }
}
