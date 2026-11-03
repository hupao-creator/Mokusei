import CryptoKit
import Observation
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import SwiftUI

/// The window owns routes and drafts; plugins own the contents of their pages.
@MainActor @Observable
public final class NativeWorkspacePresentation {
    public let workspace: NativeWorkspaceModel
    public let settingsNavigation = NativeSettingsNavigation()
    public let canvas = NativeOverviewCanvasState()
    public let messageMotion = NativeReadingPageMotion()
    public let themeTransition = NativeThemeTransitionController()
    public let readingNavigation = NativeReadingNavigationState()
    public let readingInteractions = NativeReadingInteractions()
    public let draft: NativeComposerDraft
    public private(set) var dockDraft: NativeComposerDraft
    public private(set) var dockThreadID: JSONText?
    @ObservationIgnored private var threadDrafts: [JSONText: NativeComposerDraft] = [:]
    public private(set) var selected: ApplicationThreadRef?
    public fileprivate(set) var mountedReadingThread: ApplicationThreadRef?
    public private(set) var performanceOperation: UInt64?
    @ObservationIgnored private var performanceVisit: NativePerformanceSpan?
    public private(set) var readingTarget: HarnessReadingTarget?
    public private(set) var readingPanelSource: CGRect?
    private var readingPanelSourceCardID: String?
    public var usesReadingPanel: Bool {
        guard let type = selected?.typeID else { return false }
        return type == "agent" || type == "report.document" || type == "git.worktree"
    }
    public var navigation: ThreadDetailBackAction?
    // History overlays a retained route; its nested Back must not replace the
    // underlying reader's navigation or remount that reader on return.
    public var mokuNavigation: ThreadDetailBackAction?
    @ObservationIgnored var navigationRouteID = UUID()
    public var nativeApplicationNavigation = false
    public private(set) var followUpVisible = false
    public private(set) var threadVoice: SidecardVoiceCapability?
    @ObservationIgnored private var applicationReturn: (thread: ApplicationThreadRef, target: HarnessReadingTarget?)?
    @ObservationIgnored private var voiceOwner: JSONText?
    @ObservationIgnored public lazy var scene = makeScene()
    @ObservationIgnored lazy var onboarding = NativeOnboardingState(workspace: workspace)
    @ObservationIgnored public lazy var applicationHost = NativeApplicationHost(workspace: workspace,
        navigationCallbacks: NativeApplicationNavigationCallbacks(
            openThread: { [weak self] thread, target in self?.open(thread, target: target) },
            openExecution: { [weak self] in self?.openExecution($0) },
            followUp: { [weak self] id, draft in self?.openFollowUp(id, draft: draft) },
            openExternal: { [weak self] url in
                guard let self else { throw CancellationError() }
                try await self.workspace.services.openExternal(JSONText(url.absoluteString))
            }))
    @ObservationIgnored public lazy var overview = NativeOverviewWorkspaceModel(workspace: workspace,
        applications: applicationHost.overviewFactories, canvasState: canvas)
    @ObservationIgnored public lazy var moku = NativeMokuWorkspacePresentation(workspace: workspace, overview: overview)
    private var focused = false
    private var documentVisible = true
    @ObservationIgnored private var started = false
    public var interactionReady: Bool { started && !workspace.stopping }
    @ObservationIgnored private var restored = false
    @ObservationIgnored private var snapshotAuthority: UUID?
    @ObservationIgnored private var releaseTask: Task<Void, Never>?

    public init(workspace: NativeWorkspaceModel) {
        self.workspace = workspace
        draft = NativeComposerDraft(services: workspace.services.composer(),
            persistence: NativeComposerDraftPersistence(storageDirectory: workspace.client.storageDirectory, scope: "moku"))
        dockDraft = draft
        // Reload retains the current catalog. Restore the route before the
        // first hosting-view layout so it cannot briefly build an overview
        // underneath a conversation that was already selected.
        restoreSavedSelection()
    }

    private func makeScene() -> NativeMokuSceneState {
        let state = NativeMokuSceneState(overviewState: canvas,
            replyReadFileURL: workspace.client.storageDirectory.appendingPathComponent("native-moku-reply-read.json"))
        state.submitNoteExposure = { [weak self] noteID, revision in
            guard let self else { throw CancellationError() }
            return try await NativeMokuNoteExposureSender.submit(workspace: self.workspace,
                                                                  id: noteID, revision: revision)
        }
        // Route is restored before the first layout. Do not wait for start()
        // or a saved thread briefly mounts the Overview capsule.
        state.readingPanelVisible = usesReadingPanel
        state.overviewVisible = selected == nil
        configureDockInput(in: state)
        state.onMokuOpenChange = { [weak self] open in
            NativeReadingPageMotion.cancelAll()
            if !open { self?.mokuNavigation = nil }
            self?.publishPresence()
        }
        state.onSettingsOpenChange = { [weak self] value in
            self?.workspace.settingsOpen = value
            self?.publishPresence()
        }
        state.onFlightActiveChange = { [weak self] value in self?.workspace.settingsModel.mokuInFlight = value }
        return state
    }

    public func start() {
        guard !started else { return }
        started = true
        _ = overview; _ = moku; _ = scene
        onboarding.admitIfNeeded()
        applicationHost.git.start { [weak self] in self?.overview.refreshCardExtensions() }
        workspace.voice.configureMoku(owner: workspace.catalog.moku?.id,
            available: workspace.connection == .connected && !workspace.stopping)
        workspace.voice.receive(.connection(workspace.connection))
        workspace.onCatalogChange = { [weak self] event in
            guard let self else { return }
            self.overview.receive(event)
            self.moku.receive(event)
            if case .snapshot(_, let authority) = event, self.snapshotAuthority != authority {
                self.snapshotAuthority = authority
                // Hydration gets a new snapshot authority even on a same-profile
                // reconnect. Preserve completed evidence only for the exact
                // incarnation/version still present in the new catalog.
                self.scene.reconcileNoteExposure(self.moku.note)
                self.scene.retryNoteExposure()
                // Rehydration interrupts rendering, not an accepted Close.
                self.scene.settle(); NativeReadingPageMotion.cancelAll(finishingClose: true)
            }
            self.reconcileSelection()
            self.onboarding.admitIfNeeded()
            self.publishPresence()
        }
        workspace.onOverviewFilter = { [weak self] request in self?.overview.receiveFilter(request) }
        workspace.onFollowUp = { [weak self] id, draft in self?.openFollowUp(id, draft: draft) }
        workspace.onStopped = { [weak self] in await self?.release(runtimeStopped: true) }
        workspace.onConnectionChange = { [weak self] status in
            guard let self else { return }
            self.overview.receive(.connection(status)); self.moku.receive(.connection(status))
            if status != .connected {
                self.scene.suspendNoteExposureSubmission()
                self.scene.settle(); NativeReadingPageMotion.cancelAll(finishingClose: true)
            }
            else { self.scene.retryNoteExposure() }
            self.configureThreadVoice(); self.publishPresence()
        }
        if let state = workspace.state, let authority = workspace.snapshotAuthority {
            snapshotAuthority = authority
            overview.receive(.snapshot(state, authority: authority)); moku.refresh(); reconcileSelection()
        }
        publishPresence()
    }

    public func setScenePhase(_ phase: ScenePhase) {
        focused = phase == .active; documentVisible = phase != .background
        scene.setWindowVisible(documentVisible)
        publishPresence()
    }

    private func restoreSavedSelection() {
        // Connection/hydration events can precede the first catalog. Preserve
        // the one-time saved selection until there is authoritative state.
        guard workspace.state != nil else { return }
        if !restored {
            restored = true
            if let id = workspace.preferences.selectedThreadID {
                let key = JSONText(id)
                if let thread = workspace.catalog.thread(key), thread.moku != true {
                    guard !thread.isHiddenFromUser else { persistSelection(nil); return }
                    selected = ApplicationThreadRef(threadID: key, typeID: "agent")
                    readingPanelSourceCardID = key.string
                    beginPerformanceVisit(ApplicationThreadRef(threadID: key, typeID: "agent"))
                }
            }
        }
    }

    func reconcileSelection() {
        guard workspace.state != nil else { return }
        restoreSavedSelection()
        if let previous = applicationReturn {
            let thread = workspace.catalog.thread(previous.thread.threadID)
            if thread == nil || thread?.isHiddenFromUser == true { applicationReturn = nil }
        }
        if let selected {
            let visible = selected.typeID == "agent" ? workspace.catalog.thread(selected.threadID).map { !$0.isHiddenFromUser || readingTarget?.position == .result } ?? false
                : selected.typeID == "git.worktree" ? applicationHost.git.repository(selected.threadID) != nil
                : (try? applicationHost.entry(selected)) != nil
            if !visible {
                if selected.typeID == "agent" { NativeReadingPageMotion.cancelAll(); finishBack() }
                else { closeApplication() }
            }
        }
        configureThreadVoice()
    }

    public func open(_ ref: ApplicationThreadRef, target: HarnessReadingTarget? = nil, sourceCardID: String? = nil) {
        guard !onboarding.blocksWorkspace, !scene.settingsOpen else { return }
        if ref.typeID == "agent" {
            guard let thread = workspace.catalog.thread(ref.threadID) else { return }
            if thread.moku == true { scene.setMokuOpen(true, readingTarget: target); return }
            guard !thread.isHiddenFromUser || target?.position == .result else { return }
        } else if !applicationHost.canOpen(ref.typeID) { return }
        if selected != ref || performanceVisit?.recordingID != NativePerformance.recordingID {
            beginPerformanceVisit(ref)
        } else if ref.typeID == "agent" {
            NativePerformance.event(.threadNavigate, context: performanceOperation)
        }
        NativeReadingPageMotion.cancelAll(); scene.settle(); scene.setInputOpen(false)
        if scene.mokuOpen { scene.setMokuOpen(false); scene.settle() }
        if selected != ref {
            if ref.typeID != "agent", let selected, selected.typeID == "agent" {
                applicationReturn = (selected, readingTarget)
            } else if ref.typeID == "agent" { applicationReturn = nil }
            if let previous = selected, previous.typeID == "agent" { workspace.voice.releaseThread(previous.threadID) }
            followUpVisible = false; resetNavigation(); nativeApplicationNavigation = false
        }
        if selected != ref {
            readingPanelSourceCardID = selected == nil ? sourceCardID ?? (ref.typeID == "git.worktree" ? nil : ref.threadID.string) : nil
            readingPanelSource = readingPanelSourceCardID.flatMap { canvas.displayedFrame(for: $0) }
        }
        selected = ref; readingTarget = target
        if ref.typeID == "agent" { persistSelection(ref.threadID) }
        configureThreadVoice(); publishPresence()
        if ref.typeID == "agent" { scene.setInputOpen(true) }
        Task { await overview.recordUserAction(kind: "open-thread", thread: ref) }
    }

    public func openExecution(_ reference: ApplicationExecutionRef) {
        let current = reference.thread.typeID == "agent"
            ? workspace.catalog.thread(reference.thread.threadID)?.observation.latestExecution?.executionID : nil
        open(reference.thread, target: HarnessReadingTarget(executionID: reference.executionID,
            requestID: JSONText(UUID().uuidString), mode: current == reference.executionID ? .current : .history))
    }

    public func openNoteExecution(_ reference: ApplicationExecutionRef) {
        // The public catalog excludes private background agents. Failed and
        // interrupted ordinary threads remain valid explicit reading targets.
        guard reference.thread.typeID == "agent",
              let thread = workspace.catalog.thread(reference.thread.threadID),
              thread.moku != true, !thread.mokuHistory else {
            workspace.report(PluginContractError(NativePluginLocalization.localize("链接指向的执行不可用。", locale: Locale(identifier: workspace.preferences.locale.rawValue))))
            return
        }
        open(reference.thread, target: HarnessReadingTarget(executionID: reference.executionID,
            requestID: JSONText(UUID().uuidString), mode: .history, position: .result))
    }

    public func openFollowUp(_ id: JSONText, draft: JSONText) {
        guard !onboarding.blocksWorkspace else { return }
        guard let thread = workspace.catalog.thread(id), !thread.isHiddenFromUser, thread.archived != true else { return }
        if selected?.threadID != id || selected?.typeID != "agent" {
            open(ApplicationThreadRef(threadID: id, typeID: "agent"))
        }
        if scene.mokuOpen { scene.setMokuOpen(false) }
        guard dockThreadID == id else { return }
        if !draft.codeUnits.isEmpty {
            // An explicit follow-up suggestion appends to this Thread's draft;
            // it cannot replace unsent text or attachments from the reader.
            dockDraft.text += (dockDraft.text.isEmpty ? "" : "\n\n") + draft.string
        }
        scene.setInputOpen(true)
    }

    public func showOverview(focusFilter: Bool = false) {
        guard !onboarding.blocksWorkspace else { return }
        if scene.settingsOpen {
            guard settingsNavigation.requestClose(model: workspace.settingsModel,
                onClose: { _ in scene.closeSettings() }) else { return }
            return
        }
        if focusFilter { overview.requestFilterFocus() }
        if scene.mokuOpen { scene.setMokuOpen(false) }
        // Reversal keeps the opening's source frozen. A settled return samples
        // its new destination only after the retained canvas has been prepared.
        if selected != nil, !scene.cameraActive, !scene.settingsOpen { messageMotion.close() }
        else { finishBack() }
    }

    fileprivate func prepareOverviewReturn() async {
        guard !Task.isCancelled else { return }
        let route = navigationRouteID, target = selected
        await canvas.prepareForPresentation()
        guard !Task.isCancelled, navigationRouteID == route, selected == target else { return }
        if overview.error == nil, canvas.layoutError == nil, usesReadingPanel, let id = readingPanelSourceCardID {
            readingPanelSource = canvas.displayedFrame(for: id)
        } else { readingPanelSource = nil }
    }

    public func finishBack() {
        performanceVisit?.end(); performanceVisit = nil; performanceOperation = nil
        let previous = selected
        selected = nil; readingTarget = nil; resetNavigation(); followUpVisible = false
        nativeApplicationNavigation = false
        if let previous, previous.typeID == "agent" { workspace.voice.releaseThread(previous.threadID) }
        threadVoice = nil
        applicationReturn = nil
        persistSelection(nil); publishPresence()
    }

    public func closeApplication() {
        guard selected?.typeID != "agent" else { return }
        if applicationReturn == nil, !scene.cameraActive, !scene.settingsOpen {
            messageMotion.close()
            return
        }
        NativeReadingPageMotion.cancelAll()
        selected = applicationReturn?.thread; readingTarget = applicationReturn?.target
        if let selected { beginPerformanceVisit(selected) }
        applicationReturn = nil; resetNavigation(); nativeApplicationNavigation = false
        followUpVisible = false
        configureThreadVoice(); publishPresence()
    }

    private func persistSelection(_ id: JSONText?) {
        do {
            if let id, JSONText(id.string) != id { throw PluginContractError("Thread identity cannot be stored as a native preference") }
            try workspace.preferences.selectThread(id?.string)
        } catch { workspace.report(error) }
    }

    private func beginPerformanceVisit(_ ref: ApplicationThreadRef) {
        performanceVisit?.end(.cancelled)
        performanceVisit = ref.typeID == "agent" ? NativePerformance.begin(.threadVisit) : nil
        performanceOperation = performanceVisit?.id
        if ref.typeID == "agent" { NativePerformance.event(.threadOpen, context: performanceOperation) }
    }

    private func resetNavigation() {
        navigation = nil
        mountedReadingThread = nil
        navigationRouteID = UUID()
    }

    public var canOpenSettings: Bool {
        workspace.hasInitialContent && !workspace.stopping
            && !onboarding.blocksWorkspace
            && selected == nil && scene.canOpenSettings && !messageMotion.active
    }
    public func openSettings() {
        guard canOpenSettings else { workspace.settingsOpen = scene.settingsOpen; return }
        if !scene.settingsOpen {
            settingsNavigation.visit = UUID()
            settingsNavigation.section = workspace.settingsModel.runtimeAvailable ? "moku" : "general"
        }
        NativeReadingPageMotion.cancelAll(); scene.openSettings()
    }

    public func setFollowUpVisible(_ value: Bool) { followUpVisible = value; publishPresence() }

    public func publishPresence() {
        guard started else { return }
        configureThreadVoice()
        // Keep Dock eligibility continuous while moving between its two routes.
        if selected == nil { scene.overviewVisible = true; scene.readingPanelVisible = false }
        else { scene.readingPanelVisible = usesReadingPanel; scene.overviewVisible = false }
        scene.disabled = workspace.stopping || workspace.catalog.moku == nil
            || (onboarding.blocksWorkspace && onboarding.step != .landing)
        configureDockInput(in: scene)
        overview.setPresentation(NativeOverviewPresentationFacts(
            overviewVisible: selected == nil && !scene.mokuOpen && !scene.cameraActive,
            mokuOpen: scene.mokuOpen, settingsOpen: scene.settingsOpen,
            selectedThread: scene.mokuOpen ? nil : selected,
            followUpThread: followUpVisible ? selected : nil,
            focused: focused, documentVisible: documentVisible,
            available: workspace.runtimeAvailable))
    }

    private func configureThreadVoice() {
        guard !scene.mokuOpen || scene.cameraActive,
              let selected, selected.typeID == "agent", let thread = workspace.catalog.thread(selected.threadID) else {
            if let voiceOwner { workspace.voice.releaseThread(voiceOwner); self.voiceOwner = nil }
            threadVoice = nil; return
        }
        if let voiceOwner, voiceOwner != thread.id { workspace.voice.releaseThread(voiceOwner) }
        voiceOwner = thread.id
        let value = JSONValue.array([.string(thread.harnessID), thread.settings,
            .string(thread.cwd), thread.worktree?["cwd"] ?? .null, .bool(thread.archived == true)])
        let bytes = (try? value.encodedData()) ?? Data()
        let identity = JSONText(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        threadVoice = workspace.voice.threadCapability(threadID: thread.id,
            enabled: workspace.canExecute(thread), identity: identity)
    }

    public func sendMoku(_ submission: NativeComposerSubmission) async throws {
        guard !onboarding.blocksWorkspace else { throw PluginContractError("Complete onboarding before sending a task.") }
        var request: [JSONText: JSONValue] = ["input": submission.input]
        if selected == nil, !scene.mokuOpen, !scene.cameraActive, !scene.settingsOpen,
           let filter = overview.filters.first(where: {
               $0.matches(overview.selectedTag, kind: overview.tagSelection?.kind, scope: overview.selectedScope)
           }), filter.isDirectory {
            request["directoryScopeId"] = .text(filter.scope)
        }
        workspace.dismissOperationError()
        await overview.recordUserAction(kind: "moku-input", text: JSONText(submission.text))
        _ = try await workspace.invoke("moku:submit", args: [workspace.voice.moku.fenceTypedInput(.object(request))])
    }

    public var dockThread: HarnessThread? { dockThreadID.flatMap(workspace.catalog.thread) }

    private func configureDockInput(in state: NativeMokuSceneState) {
        let thread = selected.flatMap { ref -> HarnessThread? in
            guard ref.typeID == "agent", !state.mokuOpen, !state.cameraActive,
                  let thread = workspace.catalog.thread(ref.threadID),
                  thread.moku != true, !thread.mokuHistory else { return nil }
            return thread
        }
        dockThreadID = thread?.id
        if let thread {
            if threadDrafts[thread.id] == nil {
                let scope = JSONText(codeUnits: Array("thread-detail:".utf16) + thread.id.codeUnits)
                threadDrafts[thread.id] = NativeComposerDraft(services: workspace.services.composer(),
                    persistence: NativeComposerDraftPersistence(storageDirectory: workspace.client.storageDirectory, scope: scope))
            }
            dockDraft = threadDrafts[thread.id]!
        } else { dockDraft = draft }
        state.setComposerContext(dockDraft, opensInput: thread != nil)
    }

    public func sendThread(_ submission: NativeComposerSubmission, to id: JSONText) async throws {
        guard !onboarding.blocksWorkspace,
              let thread = workspace.catalog.thread(id), thread.moku != true, !thread.mokuHistory,
              workspace.canExecute(thread) else {
            throw PluginContractError(workspace.preferences.locale.text(
                "此 Thread 当前无法接收输入，草稿已保留。", "This thread cannot accept input right now. Your draft has been kept."))
        }
        workspace.dismissOperationError()
        await overview.recordUserAction(kind: "thread-input",
            thread: ApplicationThreadRef(threadID: id, typeID: "agent"), text: JSONText(submission.text))
        _ = try await workspace.services.followUp(threadID: id, input: submission.input)
    }

    public func cancelMoku(observed thread: HarnessThread) {
        guard let target = thread.cancellationID else { return }
        perform {
            let result = try await self.workspace.invoke("moku:cancel", args: [.object([
                "threadId": .string(thread.id), "expectedCancellationId": .string(target)
            ])])
            if result["status"]?.stringValue == "stale" { throw PluginContractError("The observed Moku execution has ended or changed; refresh before stopping another execution") }
        }
    }

    /// The note command exists only where the Overview dock is mounted and
    /// reachable, so it never overlays a thread, settings or the Moku screen.
    public var canToggleMokuNote: Bool {
        started && scene.overviewVisible && !scene.disabled && !scene.dockCovered
            && !onboarding.blocksWorkspace
            && workspace.catalog.hasMoku
    }
    public func toggleMokuNote() {
        guard canToggleMokuNote else { return }
        scene.toggleNotePanelFromUser()
    }

    public func setAppearance(_ appearance: DesktopAppearance) throws {
        try themeTransition.perform(appearance: appearance) {
            try workspace.preferences.setAppearance(appearance)
            scene.settle(); NativeReadingPageMotion.cancelAll()
        }
    }
    public func perform(_ operation: @escaping () async throws -> Void) {
        workspace.dismissOperationError()
        Task { do { try await operation() } catch { workspace.report(error) } }
    }

    public func sidecardServices() -> NativeSidecardWorkspaceServices {
        NativeSidecardWorkspaceServices(send: { [weak self] thread, input in
            guard let self else { throw CancellationError() }
            let parts = input["parts"]?.arrayValue ?? []
            let text = parts.compactMap { $0["kind"] == .text("text") ? $0["text"]?.stringValue : nil }.joined(separator: "\n")
            await self.overview.recordUserAction(kind: "thread-input", thread: ApplicationThreadRef(threadID: thread, typeID: "agent"), text: JSONText(text))
            return try await self.workspace.services.followUp(threadID: thread, input: input)
        }, stageAttachments: { [weak self] urls in
            guard let self else { throw CancellationError() }
            return try await self.workspace.services.stage(urls.map(NativeComposerFile.init(url:))).map { SidecardStagedAttachment(id: $0.id) }
        }, discardAttachments: { [weak self] ids in
            guard let self else { throw CancellationError() }; try await self.workspace.services.discard(ids)
        }, openExternal: { [weak self] url in
            guard let self else { throw CancellationError() }; try await self.workspace.services.openExternal(url)
        }, voice: threadVoice, attachmentImport: SidecardAttachmentImport(stage: { [weak self] sources, lifetime in
            guard let self else { throw CancellationError() }
            let files = sources.map { source -> NativeComposerFile in
                switch source {
                case .file(let url): return NativeComposerFile(url: url)
                case .bytes(let bytes, let name, let mime): return NativeComposerFile(data: bytes, name: name, mimeType: mime)
                }
            }
            return try await self.workspace.services.composer().stageFiles(files, lifetime).map {
                SidecardImportedAttachment(id: $0.id, path: $0.path, name: $0.name, mimeType: $0.mimeType,
                    size: $0.size, kind: SidecardImportedAttachment.Kind(rawValue: $0.kind.rawValue)!)
            }
        }, policy: { [weak self] lifetime in
            guard let self else { throw CancellationError() }
            return try await self.workspace.services.composer().attachmentPolicy!(lifetime)
        }), compose: { [weak self] id, draft in self?.openFollowUp(id, draft: draft) })
    }

    public func release(runtimeStopped: Bool = false) async {
        performanceVisit?.end(.cancelled); performanceVisit = nil; performanceOperation = nil
        if let releaseTask { await releaseTask.value; return }
        guard started else { return }
        started = false
        scene.resetNoteExposureAuthority()
        workspace.onCatalogChange = nil; workspace.onConnectionChange = nil
        workspace.onOverviewFilter = nil; workspace.onFollowUp = nil; workspace.onStopped = nil
        themeTransition.cancel(); scene.settle(); moku.stop(); applicationHost.release()
        if let voiceOwner { workspace.voice.releaseThread(voiceOwner); self.voiceOwner = nil }
        let task = Task {
            await overview.stop(); await draft.dispose(discardRemoteAttachments: !runtimeStopped)
            for draft in threadDrafts.values { await draft.dispose(discardRemoteAttachments: !runtimeStopped) }
        }
        releaseTask = task
        await task.value
    }
}

@MainActor
public struct NativeWorkspaceView: View {
    public let model: NativeWorkspaceModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var presentation: NativeWorkspacePresentation
    @State private var canvasInputRegions = NativeCanvasInputRegions()
    public init(model: NativeWorkspaceModel, presentation: NativeWorkspacePresentation? = nil) {
        self.model = model; _presentation = State(initialValue: presentation ?? NativeWorkspacePresentation(workspace: model))
    }
    private var disabled: Bool { !model.runtimeAvailable }
    private var canStartMokuVoice: Bool {
        guard !presentation.onboarding.blocksWorkspace, !disabled, model.voice.moku.state.available else { return false }
        return model.voice.moku.state.phase == .closed || model.voice.moku.state.phase == .failed
    }
    private func startMokuVoice() {
        guard canStartMokuVoice else { return }
        Task { await model.voice.moku.start() }
    }
    private var applicationSuppressed: Bool {
        presentation.scene.settingsOpen || presentation.scene.cameraActive || presentation.scene.mokuOpen
            || presentation.scene.inputOpen || presentation.moku.interaction != nil
    }
    private var sidecardsSuppressed: Bool {
        presentation.scene.settingsOpen || presentation.scene.cameraActive || presentation.scene.mokuOpen
            || (presentation.scene.inputOpen && presentation.dockThreadID == nil)
            || presentation.moku.interaction != nil || presentation.messageMotion.active
    }

    public var body: some View {
        NativeThemeTransitionHost(controller: presentation.themeTransition) { workspaceSurface }
    }

    private var workspaceSurface: some View {
        NativeOperationNotice(error: presentation.scene.mokuOpen ? nil : model.localizedOperationError,
            suppressed: presentation.scene.settingsOpen,
            onScroll: { presentation.scene.setShellScrollOffset($0) },
            onDismiss: { model.dismissOperationError() }) {
            workspaceScene
        }
        .overlay(alignment: .top) {
            NativeRuntimeConnectionNotice(model: model).padding(.top, 12)
                .blur(radius: presentation.scene.settingsExpanded ? 12 : 0)
                .allowsHitTesting(!presentation.scene.settingsOpen)
                .accessibilityHidden(presentation.scene.settingsOpen)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            NativeMokuTimerBar(timer: model.timer, exclusions: presentation.scene.outsideClickExclusions)
        }
        .environment(\.locale, Locale(identifier: model.preferences.locale.rawValue))
        .environment(\.nativeOfflineDraftEditing, model.hasInitialContent && !model.runtimeAvailable && !model.stopping)
        .environment(\.nativeCanvasInputRegions, canvasInputRegions)
        .coordinateSpace(name: "workspace")
        .nativeLayoutLog("workspace.surface")
        .preferredColorScheme(model.preferences.appearance == .system ? nil : model.preferences.appearance == .dark ? .dark : .light)
        .onChange(of: scenePhase, initial: true) { _, phase in presentation.setScenePhase(phase) }
        .focusedSceneValue(\.workspacePresentation, presentation)
        .onAppear { presentation.start() }
        .onDisappear { Task { await presentation.release() } }
        .onChange(of: model.settingsOpen) { _, value in
            if value { presentation.openSettings() }
            else if presentation.scene.settingsOpen { presentation.scene.closeSettings() }
        }
        .onChange(of: presentation.overview.isSearching) { _, value in
            presentation.scene.setSearchActive(value)
        }
        .onChange(of: model.preferences.appearance) { _, value in
            presentation.scene.settle(); NativeReadingPageMotion.cancelAll(finishingClose: true)
        }
        .onChange(of: presentation.scene.cameraActive) { _, _ in presentation.publishPresence() }
        .onChange(of: model.stopping) { _, _ in presentation.publishPresence() }
        .onChange(of: presentation.onboarding.blocksWorkspace) { _, _ in presentation.publishPresence() }
        .onChange(of: presentation.onboarding.step) { _, _ in presentation.publishPresence() }
    }

    private var workspaceScene: some View {
        let historyVisit = presentation.scene.historyVisit
        return NativeMokuScene(state: presentation.scene) {
            NativeRuntimeSurface(model: model, showsConnectionNotice: false) {
                if presentation.onboarding.blocksWorkspace { Color.clear }
                else { outside }
            }
        } thread: {
            if (presentation.scene.mokuOpen || presentation.scene.cameraActive), let thread = model.catalog.moku {
                NativeMokuThreadView(harnessHost: model.harnessHost, thread: thread, draft: presentation.draft,
                    archiveThreads: model.catalog.threads.filter(\.mokuHistory),
                    readingTarget: presentation.scene.readingTarget,
                    running: presentation.moku.running, disabled: disabled,
                    activeVoiceControls: AnyView(NativeMokuVoiceControls(client: model.voice.moku, style: .dock, disabled: disabled)),
                    voiceBackground: AnyView(NativeMokuVoiceCloud(client: model.voice.moku,
                        visible: presentation.scene.windowVisible && presentation.scene.mokuOpen
                            && !presentation.scene.cameraActive && !presentation.scene.settingsOpen)),
                    voiceModeActive: [.preparing, .connecting, .listening, .stopping].contains(model.voice.moku.state.phase),
                    loadMentionDirectories: { try await model.services.knownDirectories() },
                    backLabel: presentation.selected == nil
                        ? model.preferences.locale.text("返回俯瞰", "Back to overview")
                        : model.preferences.locale.text("返回上一会话", "Back to previous conversation"),
                    focusEnabled: presentation.scene.mokuOpen && !presentation.scene.cameraActive && !presentation.scene.settingsOpen,
                    onNavigationChange: {
                        if presentation.scene.mokuOpen, presentation.scene.historyVisit == historyVisit { presentation.mokuNavigation = $0 }
                    }, error: model.localizedOperationError,
                    openExternal: { url in presentation.perform { try await model.services.openExternal(JSONText(url.absoluteString)) } },
                    onBack: { presentation.scene.closeHistory() },
                    onSend: { try await presentation.sendMoku($0) }, onCancel: { presentation.cancelMoku(observed: thread) },
                    canStartVoice: { canStartMokuVoice }, startVoice: startMokuVoice)
                    .environment(\.nativeReadingNavigation, nil)
            }
        } dock: {
            if presentation.onboarding.mountDock, let thread = model.catalog.moku {
                let detail = presentation.dockThread
                NativeMokuDock(state: presentation.scene, draft: presentation.dockDraft, cwd: detail?.cwd ?? JSONText(model.catalog.defaultCwd),
                    landing: detail == nil && presentation.moku.landing,
                    threadTitle: detail.map { $0.title.string.isEmpty ? model.preferences.locale.text("当前 Thread", "Current thread") : $0.title.string },
                    mode: detail.map { $0.observation.isExecutionActive ? .running : .idle } ?? presentation.moku.dockMode,
                    running: detail?.observation.isExecutionActive ?? presentation.moku.running,
                    talk: presentation.moku.talk, reply: detail == nil ? presentation.moku.reply : nil,
                    disabled: disabled || (detail.map { !model.canExecute($0) } ?? false),
                    interaction: presentation.moku.interaction, interactionIsQuestion: presentation.moku.interactionIsQuestion,
                    voiceControls: AnyView(NativeMokuVoiceControls(client: model.voice.moku, style: .dock, disabled: disabled)),
                    voiceBackground: AnyView(NativeMokuVoiceCloud(client: model.voice.moku,
                        visible: detail == nil && presentation.scene.dockContentVisible)),
                    voiceStatusVisible: detail == nil && ((model.voice.moku.state.phase != .closed && model.voice.moku.state.phase != .failed)
                        || !model.voice.moku.state.error.codeUnits.isEmpty),
                    voiceModeActive: detail == nil && [.preparing, .connecting, .listening, .stopping].contains(model.voice.moku.state.phase),
                    voiceTranscript: detail == nil ? model.voice.moku.inputTranscript.message.map { NativeMokuTalkMessage(id: $0.id, text: $0.text.string) } : nil,
                    presentation: presentation.moku,
                    note: presentation.moku.note,
                    openExternal: { url in presentation.perform { try await model.services.openExternal(JSONText(url.absoluteString)) } },
                    openExecution: presentation.openNoteExecution,
                    loadMentionDirectories: { try await model.services.knownDirectories() },
                    onSend: { submission in
                        if let detail { try await presentation.sendThread(submission, to: detail.id) }
                        else { try await presentation.sendMoku(submission) }
                    }, onCancel: {
                        if let detail { presentation.perform { try await model.harnessHost.actions(for: detail).interrupt() } }
                        else { presentation.cancelMoku(observed: thread) }
                    },
                    canStartVoice: { detail == nil && canStartMokuVoice }, startVoice: startMokuVoice)
                    .opacity(presentation.onboarding.dockVisible ? 1 : 0)
                    .allowsHitTesting(!presentation.onboarding.blocksWorkspace)
                    .accessibilityHidden(presentation.onboarding.blocksWorkspace)
            }
        } onCloseSettings: {
            presentation.settingsNavigation.requestClose(model: model.settingsModel) { _ in presentation.scene.closeSettings() }
        } prepareHistoryReturn: {
            if presentation.selected == nil { await presentation.prepareOverviewReturn() }
        } onHistoryParentPresentationChange: { active in
            if presentation.selected == nil { presentation.overview.setPresentationActive(active) }
        } settings: {
            if presentation.scene.settingsOpen { settings }
        }
        .overlay {
            if presentation.onboarding.blocksWorkspace, model.hasInitialContent {
                NativeOnboardingSurface(state: presentation.onboarding, scene: presentation.scene,
                    applicationSections: presentation.applicationHost.settingsSections(model: model.settingsModel))
            }
        }
        .overlay(alignment: .topLeading) {
            NativeWindowNavigationView(action: presentation.navigation, hidden: presentation.scene.mokuOpen || presentation.nativeApplicationNavigation || presentation.usesReadingPanel,
                suspended: presentation.scene.cameraActive || presentation.scene.settingsOpen,
                managesNativeButtons: !presentation.nativeApplicationNavigation || applicationSuppressed,
                reading: presentation.readingNavigation)
                .allowsHitTesting(!presentation.scene.settingsOpen && !presentation.onboarding.blocksWorkspace)
                .accessibilityHidden(presentation.scene.settingsOpen || presentation.onboarding.blocksWorkspace)
        }
    }

    @ViewBuilder private var outside: some View {
        // A disappearing page can publish nil after its replacement has mounted.
        // Fence navigation callbacks to the route visit that installed them.
        let routeID = presentation.navigationRouteID
        NativeReadingPageStack(open: presentation.selected != nil,
                identity: readingIdentity, motion: presentation.messageMotion,
                enabled: !presentation.scene.settingsOpen && !presentation.scene.mokuOpen && !presentation.scene.cameraActive,
                focusBlur: true, stationaryParent: true, emphasizedOpening: true,
                panel: presentation.usesReadingPanel, panelSource: presentation.readingPanelSource,
                onParentPresentationChange: { active in
                    guard presentation.navigationRouteID == routeID, active || presentation.selected != nil else { return }
                    presentation.overview.setPresentationActive(active)
                },
                prepareParent: { await presentation.prepareOverviewReturn() },
                onPanelOutsideClick: applicationSuppressed ? nil : {
                    guard presentation.navigationRouteID == routeID else { return }
                    if presentation.selected?.typeID == "agent" { presentation.showOverview() }
                    else { presentation.closeApplication() }
                },
                onClose: { presentation.finishBack() }) {
                NativeOverviewWorkspaceView(model: presentation.overview,
                    callbacks: NativeOverviewWorkspaceCallbacks(
                        openThread: { id, target in presentation.open(ApplicationThreadRef(threadID: id, typeID: "agent"), target: target) },
                        openApplication: { presentation.open($0, target: $1) },
                        onSettings: { presentation.openSettings() },
                        openGitWorktree: { presentation.open(.init(threadID: $0, typeID: "git.worktree"), sourceCardID: $1) }),
                    interactionPaused: presentation.scene.interactionPaused || presentation.messageMotion.active,
                    clickExclusions: presentation.scene.outsideClickExclusions, landing: presentation.moku.landing,
                    chromeVisible: presentation.selected == nil)
            } front: {
                if let selected = presentation.selected, selected.typeID != "agent" {
                    presentation.applicationHost.detail(thread: selected, readingTarget: presentation.readingTarget,
                        environment: NativeApplicationDetailEnvironment(suppressed: applicationSuppressed,
                            contentTopInset: presentation.usesReadingPanel ? 60 : 74,
                            onBack: { presentation.closeApplication() }, onSettings: { presentation.openSettings() },
                            onNativeNavigationChange: { if presentation.navigationRouteID == routeID { presentation.nativeApplicationNavigation = $0 } },
                            onNavigationChange: { if presentation.navigationRouteID == routeID { presentation.navigation = $0 } }))
                        .modifier(NativeApplicationReadingPanel(enabled: presentation.usesReadingPanel,
                            suppressed: applicationSuppressed,
                            identifier: selected.typeID == "report.document" ? "report-reading-panel" : "git-reading-panel",
                            onClose: { presentation.closeApplication() }))
                        .environment(\.nativeApplicationReadingPanel, presentation.usesReadingPanel)
                        .environment(\.nativeReadingNavigation, presentation.usesReadingPanel ? nil : presentation.readingNavigation)
                        .id(ApplicationSurfaceIdentity(thread: selected, recovery: model.recoveryRevision))
                        .onAppear { if presentation.navigationRouteID == routeID { presentation.mountedReadingThread = selected } }
                        .onDisappear { if presentation.navigationRouteID == routeID, presentation.mountedReadingThread == selected { presentation.mountedReadingThread = nil } }
                } else if let selected = presentation.selected, let thread = model.catalog.thread(selected.threadID) {
                    NativeAgentThreadWorkspace(harnessHost: model.harnessHost, thread: thread, registry: model.plugins.sidecards,
                        executionDisabled: !model.executionAvailable(thread), readingTarget: presentation.readingTarget,
                        sidecardsSuppressed: sidecardsSuppressed,
                        enabledSidecardIDs: enabledSidecards, services: presentation.sidecardServices(),
                        onBack: { presentation.showOverview() },
                        onFollowUpVisibilityChange: { presentation.setFollowUpVisible($0) },
                        backLabel: model.preferences.locale.text("返回俯瞰", "Back to overview"),
                        onNavigationChange: { if presentation.navigationRouteID == routeID { presentation.navigation = $0 } })
                        .environment(\.nativeReadingNavigation, nil)
                        .onAppear { if presentation.navigationRouteID == routeID { presentation.mountedReadingThread = selected } }
                        .onChange(of: selected) { _, ref in if presentation.navigationRouteID == routeID { presentation.mountedReadingThread = ref } }
                        .onDisappear { if presentation.navigationRouteID == routeID, presentation.mountedReadingThread == selected { presentation.mountedReadingThread = nil } }
                }
            }
            .environment(\.nativePerformanceOperation, presentation.performanceOperation)
            .environment(\.nativeReadingInteractions, presentation.readingInteractions)
            .environment(\.nativeReadingInteractionVisit, routeID)
            .environment(\.nativeReadingInteractionRefresh, presentation.readingInteractions.refresh)
            .nativeReadingActive(presentation.interactionPage == "thread" && !presentation.scene.cameraActive && !presentation.messageMotion.active)
    }

    private var readingIdentity: JSONText {
        guard let selected = presentation.selected else { return "overview" }
        // SwiftUI can retain a removed front under the Settings transition.
        // A new visit must mount/register navigation even when reopening the same thread.
        return JSONText(codeUnits: JSONText("\(presentation.navigationRouteID.uuidString):\(selected.typeID.codeUnits.count):").codeUnits
            + selected.typeID.codeUnits + selected.threadID.codeUnits)
    }

    private var enabledSidecards: Set<JSONText> {
        Set(model.plugins.sidecards.modules.compactMap { module in
            let key = JSONText(codeUnits: JSONText("sidecard:").codeUnits + module.descriptor.id.codeUnits)
            guard let plugin = model.catalog.plugins.first(where: { $0["key"] == .string(key) }),
                  plugin["enabled"] == .bool(true), (plugin["unavailableReason"]?.stringValue?.isEmpty ?? true) else { return nil }
            return module.descriptor.id
        })
    }

    private var settings: some View {
        NativeSettingsPage(model: model.settingsModel, navigation: presentation.settingsNavigation, preferences: model.preferences, harnesses: model.plugins.harnesses.modules,
            applicationSections: presentation.applicationHost.settingsSections(model: model.settingsModel),
            harnessSettings: { request in
                AnyView(NativeHarnessSettingsView(host: model.harnessHost,
                    configuration: NativeHarnessSettingsConfiguration(harnessID: request.harnessID,
                        cwd: JSONText(model.settingsModel.defaultCwd), source: request.savedValue,
                        scope: .global(applicationSettings: request.scopeID, executionOwner: request.executionSnapshot ? .moku : nil)),
                    section: request.section, executionSnapshot: request.executionSnapshot, settingsFormPage: true,
                    refreshSequence: request.refreshSequence, value: request.value))
            }, onSetAppearance: { try presentation.setAppearance($0) },
            onSetLocale: { try model.updateLocale($0) }, onClose: { _ in presentation.scene.closeSettings() },
            mokuController: presentation.scene.settingsCharacter,
            onCoordinatorFrame: { presentation.scene.setCoordinatorFrame($0, pending: $1) })
    }
}

private struct ApplicationSurfaceIdentity: Hashable {
    let thread: ApplicationThreadRef
    let recovery: Int
}

private struct WorkspacePresentationKey: FocusedValueKey {
    typealias Value = NativeWorkspacePresentation
}
public extension FocusedValues {
    var workspacePresentation: NativeWorkspacePresentation? {
        get { self[WorkspacePresentationKey.self] }
        set { self[WorkspacePresentationKey.self] = newValue }
    }
}

public struct NativeWorkspaceCommands: Commands {
    @FocusedValue(\.workspacePresentation) private var presentation
    private var locale: DesktopLocale { presentation?.workspace.preferences.locale ?? .chinese }
    public init() {}
    public var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button(locale.text("搜索会话", "Find Conversations")) { presentation?.overview.beginSearch() }
                .keyboardShortcut("f").disabled(presentation?.onboarding.blocksWorkspace == true || presentation?.selected != nil || presentation?.scene.settingsOpen == true || presentation?.scene.mokuOpen == true)
        }
        CommandGroup(after: .sidebar) {
            Button(locale.text("会话俯瞰", "Overview")) { presentation?.showOverview(focusFilter: true) }.keyboardShortcut("k")
                .disabled(presentation?.onboarding.blocksWorkspace == true)
            Button("Moku") { presentation?.scene.toggleMoku() }.keyboardShortcut("b")
                .disabled(presentation?.onboarding.blocksWorkspace == true || presentation?.scene.settingsOpen == true)
            Button(locale.text("输入", "Compose")) { presentation?.scene.toggleInput() }
                .keyboardShortcut("b", modifiers: [.command, .shift]).disabled(presentation?.onboarding.blocksWorkspace == true || presentation?.scene.dockRouteVisible != true || presentation?.scene.settingsOpen == true)
            Button(locale.text("Moku 笔记", "Moku Note")) { presentation?.toggleMokuNote() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(presentation?.canToggleMokuNote != true)
        }
        CommandGroup(replacing: .appSettings) {
            Button(locale.text("设置…", "Settings…")) { presentation?.openSettings() }.keyboardShortcut(",")
                .disabled(presentation?.canOpenSettings != true)
        }
    }
}
