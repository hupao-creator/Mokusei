import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import SwiftUI

struct NativeMokuVoiceComposerRestoration {
    private(set) var active = false
    private(set) var shouldRestore = false

    mutating func update(active next: Bool, inputOpen: Bool) -> Bool? {
        guard active != next else { return nil }
        active = next
        if next {
            shouldRestore = inputOpen
            return inputOpen ? false : nil
        }
        let restore = shouldRestore
        shouldRestore = false
        return restore ? true : nil
    }
}

/// One glass capsule. Production composer, transcript and interaction ownership stay in the scene.
/// The draft object is the same one supplied to NativeMokuThreadView.
public struct NativeMokuDock: View {
    public let state: NativeMokuSceneState
    public let draft: NativeComposerDraft
    public let cwd: JSONText
    public var landing: Bool
    public var mode: MokuCharacterMode
    public var running: Bool
    public var reasoning: MokuReasoningContent?
    public var talk: String?
    public var reply: NativeMokuDockReply?
    public var disabled: Bool
    public var interaction: AnyView?
    public var interactionIsQuestion: Bool
    public var voiceControls: AnyView
    public var voiceBackground: AnyView
    public var voiceStatusVisible: Bool
    public var voiceModeActive: Bool
    public var voiceTranscript: NativeMokuTalkMessage?
    public var onSend: (NativeComposerSubmission) async throws -> Void
    public var onCancel: () -> Void
    public var canStartVoice: () -> Bool
    public var startVoice: () -> Void
    public var presentation: NativeMokuWorkspacePresentation?
    public var note: NativeMokuNote?
    public var openExternal: ((URL) -> Void)?
    public var openExecution: ((ApplicationExecutionRef) -> Void)?
    public var loadMentionDirectories: (() async throws -> [NativeComposerDirectory])?
    @Environment(\.nativeMokuSettingsContent) private var settingsContent
    @Environment(\.locale) private var locale
    @Environment(\.nativeOfflineDraftEditing) private var offlineDraftEditing
    @Environment(\.colorScheme) private var workspaceColorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var hovered = false
    @State private var hoverTask: Task<Void, Never>?
    @FocusState private var stopFocused: Bool
    @AccessibilityFocusState private var stopAccessibilityFocused: Bool
    @State private var capsuleHeight: CGFloat = 58
    @State private var completionHeight: CGFloat = 0
    @State private var capsuleFraction: CGFloat = 0
    @State private var submitting = false
    @State private var focusReady = false
    @State private var focusRequest = 0
    @State private var directoryMentions = NativeMokuDirectoryMentions()
    @State private var editorBottomInset: CGFloat = 29
    @State private var noteContentHeight: CGFloat = 0
    @State private var voiceControlsFrame = CGRect.zero
    @State private var voiceComposerRestoration = NativeMokuVoiceComposerRestoration()
    @State private var dispatchDetail: NativeMokuTalkMessage?
    @State private var character = NativeMokuCharacterMotion()
    @State private var reasoningRequested = false
    @State private var reasoningSeatReserved = false
    @State private var reasoningReady = false
    @State private var reasoningTransition = 0
    @State private var retainedReasoningGlyphs: [MokuReasoningGlyph] = []

    public init(state: NativeMokuSceneState, draft: NativeComposerDraft, cwd: JSONText,
                landing: Bool = false,
                mode: MokuCharacterMode = .idle, running: Bool = false, reasoning: MokuReasoningContent? = nil,
                talk: String? = nil,
                reply: NativeMokuDockReply? = nil, disabled: Bool = false,
                interaction: AnyView? = nil, interactionIsQuestion: Bool = false,
                voiceControls: AnyView = AnyView(EmptyView()),
                voiceBackground: AnyView = AnyView(EmptyView()),
                voiceStatusVisible: Bool = false,
                voiceModeActive: Bool = false,
                voiceTranscript: NativeMokuTalkMessage? = nil,
                presentation: NativeMokuWorkspacePresentation? = nil,
                note: NativeMokuNote? = nil,
                openExternal: ((URL) -> Void)? = nil,
                openExecution: ((ApplicationExecutionRef) -> Void)? = nil,
                loadMentionDirectories: (() async throws -> [NativeComposerDirectory])? = nil,
                onSend: @escaping (NativeComposerSubmission) async throws -> Void,
                onCancel: @escaping () -> Void,
                canStartVoice: @escaping () -> Bool = { false },
                startVoice: @escaping () -> Void = {}) {
        self.state = state; self.draft = draft; self.cwd = cwd; self.mode = mode; self.running = running
        self.reasoning = reasoning
        self.landing = landing
        self.talk = talk; self.reply = reply; self.disabled = disabled; self.interaction = interaction
        self.interactionIsQuestion = interactionIsQuestion; self.voiceControls = voiceControls
        self.voiceBackground = voiceBackground
        self.voiceStatusVisible = voiceStatusVisible
        self.voiceModeActive = voiceModeActive
        self.voiceTranscript = voiceTranscript
        self.onSend = onSend; self.onCancel = onCancel
        self.canStartVoice = canStartVoice; self.startVoice = startVoice
        self.presentation = presentation
        self.note = note; self.openExternal = openExternal; self.openExecution = openExecution
        self.loadMentionDirectories = loadMentionDirectories
    }
    private var retaining: Bool { state.inputLeaving || state.capsuleSealed }
    private var inputPresent: Bool {
        !state.settingsOpen && !state.notePanelOpen && (state.inputOpen || state.inputLeaving) && !voiceModeActive && interaction == nil
            && (state.inputOpen || displayedMessage == nil)
    }
    private var composerMounted: Bool {
        state.overviewVisible && !state.notePanelOpen && (state.inputOpen || state.inputLeaving || (voiceModeActive && voiceComposerRestoration.shouldRestore)) && interaction == nil
    }
    private var incomingTalk: NativeMokuTalkMessage? {
        if let presentation { return presentation.talkMessage }
        guard let talk, !talk.isEmpty else { return nil }
        return NativeMokuTalkMessage(id: JSONText(talk), text: talk)
    }
    private var visibleTalk: NativeMokuTalkMessage? {
        guard !state.inputOpen, interaction == nil, !state.dockCovered, state.overviewVisible,
              state.windowVisible, !disabled, !submitting, !draft.submitting else { return nil }
        return state.talkPresentation.message
    }
    private var visibleVoiceTranscript: NativeMokuTalkMessage? {
        guard voiceModeActive, interaction == nil, !state.dockCovered, state.overviewVisible,
              state.windowVisible, !disabled else { return nil }
        return voiceTranscript
    }
    private var navigationDisabled: Bool { disabled && !offlineDraftEditing }
    private var landingInputAvailable: Bool {
        landing && state.overviewVisible && !state.dockCovered && !state.notePanelOpen
            && !voiceModeActive && interaction == nil && !navigationDisabled
    }
    private var rowControlAvailable: Bool {
        state.overviewVisible && state.windowVisible && !state.dockCovered && !navigationDisabled
            && interaction == nil && !state.inputOpen && !state.inputLeaving
    }
    private var voiceControlVisible: Bool {
        !state.settingsOpen && voiceStatusVisible
    }
    private var displayedMessage: NativeMokuTalkMessage? { visibleVoiceTranscript ?? visibleTalk }
    // A notification covered by live ASR has never been presented to the user.
    private var foregroundTalkID: JSONText? {
        guard visibleVoiceTranscript == nil else { return nil }
        return visibleTalk?.id
    }
    private var rowExpanded: Bool { (!voiceModeActive && state.inputOpen) || displayedMessage != nil }
    private var expanded: Bool { state.settingsExpanded || state.notePanelOpen || rowExpanded }
    private var surfaceAnimation: Animation? { reduceMotion ? nil : .smooth(duration: 0.42, extraBounce: 0) }
    /// Force-touch voice remains on Moku's original control row, rather than
    /// treating selectable note prose as a voice activation target.
    private var voiceActivationFrame: CGRect {
        let surface = state.capsuleFrame
        let height = state.notePanelOpen
            ? min(surface.height, rowExpanded ? surfaceHeight(width: surface.width) : NativeMokuCapsuleLayout.idleSize.height)
            : surface.height
        return CGRect(x: surface.minX, y: surface.maxY - noteHistoryBand(width: surface.width) - height, width: surface.width, height: height)
    }
    private var stopControlPresent: Bool {
        running && !inputPresent && !voiceModeActive && !state.settingsOpen
    }
    // Keep the control seat for the entire message, including after Stop retires.
    // Changing it mid-message shifts centered text and can change line breaks.
    private var talkTrailing: CGFloat { 48 }
    // With prose or media controls, give History its own bottom band rather
    // than narrowing selectable text or covering controls in small viewports.
    private func noteHistoryBand(width: CGFloat) -> CGFloat {
        state.notePanelOpen && (width < 200 || displayedMessage != nil || voiceControlVisible || stopControlPresent) ? 40 : 0
    }
    private var stopVisible: Bool { hovered || stopFocused || stopAccessibilityFocused }
    private func surfaceHeight(width: CGFloat) -> CGFloat {
        guard let message = displayedMessage else {
            return max(landing ? 76 : 58, capsuleHeight) + (completionVisible ? completionHeight : 0)
        }
        if message.dispatch != nil { return landing ? 76 : 58 }
        return max(landing ? 76 : 58, NativeMokuTalkTypography.capsuleHeight(message.text, width: width, trailingInset: talkTrailing))
    }
    private var residentPresenting: Bool {
        !state.dockCovered && state.overviewVisible && state.windowVisible && !state.inputOpen &&
        !submitting && !draft.submitting && interaction == nil && displayedMessage == nil
    }
    private var completionVisible: Bool { inputPresent && !retaining && directoryMentions.isOpen }
    private var mentionsEnabled: Bool {
        state.overviewVisible && state.inputOpen && !disabled && !state.dockCovered && state.windowVisible && interaction == nil
    }
    private var reminder: NativeMokuDockReply? {
        guard let reply, !state.readReplies.contains(JSONText(reply.readKey)),
              (presentation?.sessionIdle ?? !running), mode == .idle,
              !state.inputOpen, interaction == nil, !state.dockCovered else { return nil }
        return reply
    }
    private var runningFeedback: Bool {
        !state.settingsOpen && running && (mode == .running || incomingReasoning != nil)
            && !expanded && !inputPresent && interaction == nil && !voiceModeActive
            && !disabled && (presentation?.workspace.runtimeAvailable ?? true)
    }
    private var incomingReasoning: MokuReasoningContent? {
        guard running else { return nil }
        if let presentation { return presentation.reasoning }
        return reasoning
    }
    private var reasoningEligible: Bool {
        // Temporarily use the existing three-dot running expression for Moku's
        // live reasoning. Keep the source projection and Arc implementation so
        // this presentation choice does not change runtime or thread history.
        false
    }
    private var reasoningGlyphs: [MokuReasoningGlyph] {
        let incoming = incomingReasoning.map { $0.text.map { MokuReasoningGlyph(value: String($0), position: 0.5, opacity: 1) } }
            ?? retainedReasoningGlyphs
        // A FIFO may still paint an earlier, wider glyph after it leaves the
        // latest tail; keep that envelope until its actual retirement ends.
        return incoming + character.paintedReasoningGlyphs
    }
    private var eyeExpression: MokuExpression {
        if state.settingsOpen || state.inputOpen { return .focus }
        if interaction != nil { return .curious }
        if submitting || draft.submitting || running { return .deliberating }
        if reminder != nil { return .happy }
        return .idle
    }
    public var body: some View {
        GeometryReader { geometry in
            let viewport = state.dockViewport(in: geometry.size)
            let baseFrame = NativeMokuCapsuleLayout.frame(in: viewport, landing: landing)
            let frame = baseFrame.insetBy(dx: displayedMessage?.dispatch != nil ? max(0, (baseFrame.width - 400) / 2) : 0, dy: 0)
            let settingsSize = CGSize(width: min(780, max(0, viewport.width - 48)), height: min(680, max(0, viewport.height - 112)))
            let width = state.settingsExpanded ? settingsSize.width : state.notePanelOpen ? min(560, baseFrame.width) : frame.width
            let rowHeight = state.settingsExpanded ? NativeMokuCapsuleLayout.idleSize.height
                : (rowExpanded ? surfaceHeight(width: width) : NativeMokuCapsuleLayout.idleSize.height) + noteHistoryBand(width: width)
            let noteAvailableHeight = max(0, frame.height - rowHeight)
            let noteHeight = state.notePanelOpen
                ? NativeMokuNoteLayout.fittedHeight(content: noteContentHeight, available: noteAvailableHeight) : 0
            let availableSurface = CGRect(x: frame.midX - width / 2,
                y: state.settingsExpanded ? viewport.minY : frame.minY,
                width: width, height: state.settingsExpanded ? viewport.height : frame.height)
            let surface = NativeMokuCapsuleLayout.surface(in: availableSurface, expanded: expanded,
                height: state.settingsExpanded ? settingsSize.height : rowHeight + noteHeight, centered: landing || state.settingsExpanded)
            let arcSize = NativeMokuCapsuleLayout.idleSurface(in: viewport).size
            let arcBody = CGRect(x: surface.midX - arcSize.width / 2,
                                 y: surface.maxY - rowHeight / 2 - arcSize.height / 2,
                                 width: arcSize.width, height: arcSize.height)
            // Scale the resident as one group so the eyes, orbit and thinking
            // ink retain the ordinary capsule's proportions and shared clock.
            let residentScale = landing && !expanded && frame.width > 0 && frame.height > 0
                ? min(NativeMokuCapsuleLayout.landingScale, frame.width / max(1, surface.width), frame.height / max(1, surface.height)) : 1
            let placement = reasoningSeatReserved
                ? NativeMokuReasoningPlacement.fit(surface: surface, arcBody: arcBody, viewport: viewport,
                    glyphs: reasoningGlyphs, preferredScale: residentScale)
                : NativeMokuReasoningPlacement(surface: surface.insetBy(dx: surface.width * (1 - residentScale) / 2,
                    dy: surface.height * (1 - residentScale) / 2), scale: residentScale)
            let panel = NativeMokuCapsuleLayout.panel(in: viewport, above: placement.surface,
                                                     question: interactionIsQuestion)
            let noteButtonRect: CGRect? = nil
            ZStack(alignment: .topLeading) {
                capsule(width: width, room: max(58, frame.height - 18),
                        surface: surface, rowHeight: rowHeight, noteHeight: noteHeight,
                        noteAvailableHeight: noteAvailableHeight, decorationPadding: placement.decorationPadding, settingsSize: settingsSize)
                    .nativeCanvasNavigationRegion()
                    .scaleEffect(placement.scale)
                    .position(x: placement.surface.midX, y: placement.surface.midY)
                    .animation(surfaceAnimation, value: placement)
                if let interaction, !state.settingsOpen {
                    interaction.padding(18)
                        .frame(width: panel.width, height: panel.height, alignment: .topLeading)
                        .nativeCanvasNavigationRegion()
                        .background { NativeMokuCapsuleGlass(interactive: false) }
                        .environment(\.colorScheme, .dark)
                        .position(x: panel.midX, y: panel.midY)
                }
            }
            .coordinateSpace(name: "native-moku-dock")
            .onChange(of: HitLayout(surface: placement.surface, panel: panel, interaction: interaction != nil && !state.settingsOpen, noteButton: noteButtonRect), initial: true) { _, layout in
                guard state.overviewVisible else {
                    state.dockHitRects = []
                    state.dockMentionHitRect = nil
                    return
                }
                state.capsuleFrame = layout.surface
                state.dockHitRects = [layout.surface.insetBy(dx: -5, dy: -5)]
                if layout.interaction { state.dockHitRects.append(layout.panel) }
                if let button = layout.noteButton { state.dockHitRects.append(button) }
            }
            .onChange(of: interaction != nil, initial: true) { _, visible in
                state.setDockInteractionVisible(state.overviewVisible && visible, question: interactionIsQuestion)
                if visible && state.overviewVisible && !state.settingsOpen { state.setInputOpen(false) }
            }
            .onChange(of: interactionIsQuestion) { _, value in
                state.setDockInteractionVisible(state.overviewVisible && interaction != nil, question: value)
            }
        }
        .overlay {
            ZStack {
                NativeMokuOutsideClickMonitor(
                    exclusions: state.outsideClickExclusions,
                    beginClick: { state.overviewState.clearAutoFocusSuppression() },
                    isActive: { (state.inputOpen || state.notePanelOpen || foregroundTalkID != nil) && state.overviewVisible && !state.dockCovered && !navigationDisabled },
                    usesExclusions: foregroundTalkID == nil || state.notePanelOpen,
                    preservesOwnedInteractions: landing && state.inputOpen,
                    outsideWindowClick: !state.notePanelOpen && (foregroundTalkID != nil || (landing && state.inputOpen)) ? {
                        if state.inputOpen { state.dismissInputForOutsideClick() }
                        else { state.dismissTalk() }
                    } : nil,
                    isInside: { point in
                        NativeMokuOutsideClick.isInside(point: point, dockRects: state.dockHitRects)
                    },
                    click: { _ in
                        if state.notePanelOpen { state.setNotePanelOpen(false) }
                        else if state.inputOpen { state.dismissInputForOutsideClick() }
                        else { state.dismissTalk() }
                    })
                if state.notePanelOpen && !state.settingsOpen {
                    NativeSettingsEscapeHandler { state.setNotePanelOpen(false) }
                        .frame(width: 0, height: 0)
                }
                NativeMokuSwipeMonitor(
                    isActive: { rowControlAvailable },
                    isInside: { point in
                        let row = voiceActivationFrame
                        return NativeMokuSwipeTarget.contains(point, row: row, showingMessage: displayedMessage != nil,
                            excluding: voiceControlVisible ? [voiceControlsFrame] : [])
                    },
                    openNote: { state.openNotePanelFromUser() })
            }
            .allowsHitTesting(false)
        }
        .onChange(of: landing, initial: true) { _, active in
            guard state.updateLanding(active) else { return }
            if active {
                if landingInputAvailable && !running && incomingTalk == nil { state.setInputOpen(true) }
            } else {
                state.retainDraft(draft)
                state.setInputOpen(false)
            }
        }
        .onChange(of: state.inputOpen, initial: true) { _, open in
            focusReady = false
            if open {
                if voiceModeActive {
                    if !voiceComposerRestoration.active {
                        _ = voiceComposerRestoration.update(active: true, inputOpen: true)
                    }
                    state.retainDraft(draft)
                    state.setInputOpen(false)
                } else {
                    state.retainDraft(draft)
                }
            }
        }
        .onChange(of: state.settingsOpen) { _, open in
            if open { state.retainDraft(draft) }
            else {
                restoreVoiceComposer()
                if interaction != nil {
                    state.setDockInteractionVisible(true, question: interactionIsQuestion)
                    state.setInputOpen(false)
                }
            }
        }
        .onChange(of: incomingTalk, initial: true) { _, message in state.receiveTalk(message) }
        .onAppear {
            character.onReasoningRetired = {
                guard !reasoningRequested else { return }
                withAnimation(surfaceAnimation) { reasoningSeatReserved = false }
                retainedReasoningGlyphs = []
            }
        }
        .onChange(of: incomingReasoning, initial: true) { _, content in
            if let content {
                retainedReasoningGlyphs = content.text.map { .init(value: String($0), position: 0.5, opacity: 1) }
            }
        }
        .onChange(of: reasoningEligible, initial: true) { _, eligible in
            reasoningRequested = eligible
            reasoningTransition += 1
            let request = reasoningTransition
            if eligible {
                if reasoningSeatReserved && reasoningReady { return }
                if reasoningSeatReserved { reasoningReady = true; return }
                // Establish the space before revealing external ink. Fast reversals
                // redirect the existing SwiftUI geometry rather than snapping home.
                withAnimation(surfaceAnimation, completionCriteria: .removed) {
                    reasoningSeatReserved = true
                } completion: {
                    guard request == reasoningTransition && reasoningRequested else { return }
                    reasoningReady = true
                }
            } else {
                let hadInk = reasoningReady
                reasoningReady = false
                if !hadInk || reduceMotion {
                    withAnimation(surfaceAnimation) { reasoningSeatReserved = false }
                }
            }
        }
        .onChange(of: note, initial: true) { previous, value in
            if previous?.documentToken != value?.documentToken { noteContentHeight = 0 }
            state.reconcileNoteExposure(value)
        }
        .onChange(of: state.windowVisible) { _, visible in if visible { state.retryNoteExposure() } }
        .onChange(of: navigationDisabled) { _, value in if value { state.setNotePanelOpen(false) } }
        .onChange(of: voiceModeActive, initial: true) { _, _ in restoreVoiceComposer() }
        .onChange(of: foregroundTalkID, initial: true) { _, id in state.setTalkPresented(id != nil) }
        .task(id: state.talkPresentation.deadline) {
            guard let deadline = state.talkPresentation.deadline, let id = state.talkPresentation.message?.id else { return }
            // SwiftUI cancels on replacement, dismissal and unmount. The scene
            // also fences the captured identity in case cancellation races delivery.
            do { try await ContinuousClock().sleep(until: deadline) } catch { return }
            guard !Task.isCancelled else { return }
            state.expireTalk(id: id, deadline: deadline)
        }
        .onChange(of: expanded, initial: true) { _, expanded in
            withAnimation(surfaceAnimation) { capsuleFraction = expanded ? 1 : 0 }
        }
        .onChange(of: state.overviewVisible) { _, visible in
            guard !visible else { return }
            focusReady = false
            state.dockHitRects = []
            state.dockMentionHitRect = nil
            hoverTask?.cancel(); hoverTask = nil
        }
        .task(id: state.overviewVisible && state.inputOpen && !state.dockCovered) {
            guard state.overviewVisible, state.inputOpen, !state.dockCovered else { focusReady = false; return }
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            guard !Task.isCancelled, state.overviewVisible, state.inputOpen else { return }
            focusReady = true; focusRequest += 1
        }
        .onChange(of: draft.text) { _, _ in if state.overviewVisible && state.inputOpen { state.retainDraft(draft) } }
        .onChange(of: draft.attachments) { _, _ in if state.overviewVisible && state.inputOpen { state.retainDraft(draft) } }
        .onChange(of: draft.directories) { _, _ in if state.overviewVisible && state.inputOpen { state.retainDraft(draft) } }
        .onChange(of: reply?.readKey, initial: true) { _, key in
            state.liveReplyKey = key
            if state.mokuOpen, !state.cameraActive, state.windowVisible, let key { state.markReplyRead(key) }
        }
        .onChange(of: residentPresenting, initial: true) { _, active in
            presentation?.setPresenting(active); acknowledgePresentation()
        }
        .onChange(of: presentation?.displayToken, initial: true) { _, _ in acknowledgePresentation() }
        .onDisappear {
            character.onReasoningRetired = nil
            reasoningRequested = false; reasoningReady = false; reasoningSeatReserved = false
            reasoningTransition += 1; retainedReasoningGlyphs = []
            state.setTalkPresented(false)
            state.setNotePanelOpen(false)
            state.dockHitRects = []
            state.dockMentionHitRect = nil
            if state.dockInteractionVisible { state.setDockInteractionVisible(false, question: false) }
            presentation?.setPresenting(false)
            hoverTask?.cancel(); hoverTask = nil
            focusReady = false
        }
        .sheet(item: $dispatchDetail) { selected in
            NativeMokuDispatchSheet(selected: selected, presentation: presentation)
        }
        .task(id: mentionsEnabled) { await directoryMentions.load(enabled: mentionsEnabled, using: loadMentionDirectories) }
        // Keep the override local: a preferredColorScheme would also recolor
        // the containing workspace window and its other application surfaces.
        .environment(\.colorScheme, .dark)
    }
    private struct HitLayout: Equatable {
        var surface, panel: CGRect
        var interaction: Bool
        var noteButton: CGRect?
    }
    private func capsule(width: CGFloat, room: CGFloat, surface: CGRect, rowHeight: CGFloat,
                         noteHeight: CGFloat, noteAvailableHeight: CGFloat, decorationPadding: CGFloat, settingsSize: CGSize) -> some View {
        let historyBand = noteHistoryBand(width: surface.width)
        let idleWidth = min(NativeMokuCapsuleLayout.idleSize.width, width)
        let idleHeight = NativeMokuCapsuleLayout.idleSize.height
        let followsEditor = inputPresent && displayedMessage == nil
        let characterInput = NativeMokuCharacterInput(expression: eyeExpression, focus: expanded ? 1 : 0,
            running: runningFeedback, reasoning: reasoningEligible ? incomingReasoning : nil,
            presentsReasoning: reasoningEligible && reasoningReady, executionKey: presentation?.executionKey,
            capsuleSize: CGSize(width: surface.width, height: rowHeight - historyBand), cornerRadius: NativeMokuCapsuleLayout.cornerRadius,
            motion: scenePhase == .active && state.windowVisible && !state.dockCovered,
            reduceMotion: reduceMotion, dark: true)
        return ZStack(alignment: .bottomLeading) {
            if composerMounted {
                composer(room: room).frame(width: width).fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { capsuleHeight = max(58, $0) }
                    .opacity(inputPresent ? capsuleFraction : 0)
                    // Let the eyes clear the text seat on expansion; fade prose
                    // quickly before they cross it again during collapse.
                    .animation(reduceMotion ? nil : (inputPresent ? .easeIn(duration: 0.42) : .easeOut(duration: 0.12)), value: inputPresent ? capsuleFraction : 0)
                    .allowsHitTesting(inputPresent)
                    .disabled(state.settingsOpen)
                    .accessibilityHidden(!inputPresent)
            }
        }
        .frame(width: surface.width, height: surface.height, alignment: .bottomLeading)
        .onChange(of: completionVisible) { _, visible in
            if !visible { state.dockMentionHitRect = nil }
        }
        .overlay(alignment: .top) {
            if completionVisible {
                NativeMokuComposerCompletion(mentions: directoryMentions, draft: draft,
                    maxHeight: max(0, room - capsuleHeight - 12),
                    onFrame: { state.dockMentionHitRect = completionVisible ? $0 : nil })
                    .disabled((disabled && !offlineDraftEditing) || draft.clearing || draft.isDisposed)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { completionHeight = $0 }
                    // Resolve the menu's target height once. The shell animates;
                    // the editor and its persistent face share the bottom edge.
                    .transaction { $0.animation = nil }
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if rowControlAvailable && !voiceModeActive && !inputPresent {
                Button { state.setInputOpen(true) } label: {
                    Color.clear
                        .frame(width: displayedMessage == nil ? surface.width : 46, height: rowHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // Leave selectable message prose and the later control overlays
                // their own hit targets; only the eyes open input beside a message.
                .padding(.leading, displayedMessage == nil ? 0 : 9)
                .accessibilityLabel(localize("打开 Moku 输入框", "Open Moku input"))
                .accessibilityIdentifier("moku-open-input")
            }
        }
        .overlay(alignment: .top) {
            if state.notePanelOpen {
                ZStack {
                    NativeMokuNoteContent(note: note, width: width, height: noteHeight, availableHeight: noteAvailableHeight,
                                          routeEligible: state.notePanelOpen && !state.settingsOpen && state.overviewVisible
                                              && !state.dockCovered && !navigationDisabled,
                                          openExternal: openExternal, openExecution: openExecution,
                                          onContentHeightChange: { noteContentHeight = $0 },
                                          claimOpenArm: { state.claimNoteOpenArm() },
                                          onExposure: { state.recordNoteExposure($0) },
                                          onClose: { state.setNotePanelOpen(false) })
                        // Keep native Markdown layout discrete without cancelling
                        // the surrounding ink transition with this transaction.
                        .transaction { $0.animation = nil }
                }
                .compositingGroup()
                .opacity(state.settingsOpen ? 0 : 1)
                .allowsHitTesting(!state.settingsOpen)
                .accessibilityHidden(state.settingsOpen)
                // Retire ink before the shrinking shell carries the header
                // through the eyes. The shell keeps its ordinary 420ms morph.
                .transition(.asymmetric(
                    insertion: .opacity.animation(surfaceAnimation),
                    removal: .opacity.animation(reduceMotion ? nil : .easeOut(duration: 0.12))))
            }
        }
        .overlay(alignment: .top) {
            if state.settingsOpen {
                settingsContent
                    .environment(\.colorScheme, workspaceColorScheme)
                    .frame(width: settingsSize.width, height: settingsSize.height)
                    // Settle the page layout during the capsule morph without
                    // suppressing animations initiated later by its children.
                    .transaction(value: state.settingsExpanded) { $0.animation = nil }
                    .compositingGroup()
                    .opacity(state.settingsExpanded ? 1 : 0)
                    .animation(reduceMotion ? nil : .easeOut(duration: state.settingsClosing ? 0.12 : 0.22), value: state.settingsExpanded)
                    .disabled(state.settingsClosing)
                    .allowsHitTesting(!state.settingsClosing)
                    .accessibilityHidden(state.settingsClosing)
            }
        }
        .overlay(alignment: .bottomLeading) {
            // Bottom alignment keeps Moku on the input row while only the
            // glass above it changes height. The inset is measured inside
            // the input, so menu and shell animation cannot affect it.
            HStack(alignment: .center, spacing: 15) {
                NativeMokuCharacterSurface(controller: character, input: characterInput, seat: .face)
                    .scaleEffect(landing && expanded ? NativeMokuCapsuleLayout.landingScale : 1)
                    .frame(width: 58, height: 49)
                    .frame(width: 34, height: 25)
                    .allowsHitTesting(false).accessibilityHidden(true)
                if let message = displayedMessage {
                    if let dispatch = message.dispatch {
                        NativeMokuDispatchContent(dispatch: dispatch, harness: dispatchHarness(dispatch)) {
                            dispatchDetail = message
                        }
                        .frame(width: max(1, width - NativeMokuTalkTypography.leading - talkTrailing), height: 28)
                    } else {
                        NativeMokuTalkContent(message: message)
                            .accessibilityIdentifier(visibleVoiceTranscript == nil ? "moku-talk-content" : "moku-voice-transcript")
                            .frame(width: max(1, width - NativeMokuTalkTypography.leading - talkTrailing),
                                   height: max(0, surfaceHeight(width: width) - NativeMokuTalkTypography.verticalPadding * 2))
                            .padding(.vertical, NativeMokuTalkTypography.verticalPadding)
                            // Text snapshots change discretely. Interpolating the
                            // native document/clip heights produces fractional
                            // overflow and flashes the overlay scroller at wraps.
                            // Keep the glass animation outside this transaction.
                            .transaction { $0.animation = nil }
                            .transition(.opacity.animation(.easeInOut(duration: 0.22)))
                    }
                }
            }
            .frame(height: followsEditor ? nil : rowHeight - historyBand)
            .padding(.leading, (idleWidth - 34) / 2 * (1 - capsuleFraction) + 15 * capsuleFraction)
            .padding(.bottom, followsEditor
                ? idleHeight / 2 - 12.5 + (editorBottomInset - idleHeight / 2) * capsuleFraction : historyBand)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(state.settingsOpen ? 0 : 1)
            .allowsHitTesting(!state.settingsOpen).accessibilityHidden(state.settingsOpen)
        }
        .overlay(alignment: .bottomTrailing) {
            if stopControlPresent {
                Button(action: onCancel) {
                    // Hide only the drawn square, not the Button: a fully
                    // transparent button is pruned from the accessibility tree.
                    RoundedRectangle(cornerRadius: 1).fill(.foreground).frame(width: 10, height: 10)
                        .frame(width: 30, height: 30).contentShape(Circle())
                        .opacity(stopVisible ? 1 : 0)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: stopVisible)
                }.buttonStyle(.plain).disabled(disabled)
                    .focused($stopFocused)
                    .accessibilityFocused($stopAccessibilityFocused)
                    .allowsHitTesting(stopVisible)
                    .help(localize("停止 Moku", "Stop Moku"))
                    .accessibilityLabel(localize("停止 Moku", "Stop Moku"))
                    .accessibilityIdentifier("moku-stop")
                    .padding(.trailing, 7).frame(height: rowHeight - historyBand)
                    .padding(.bottom, historyBand)
            } else if voiceControlVisible && (!inputPresent || voiceModeActive) {
                voiceControls.fixedSize(horizontal: true, vertical: true)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("native-moku-dock")) } action: { voiceControlsFrame = $0 }
                    .padding(.trailing, 3).frame(height: rowHeight - historyBand)
                    .padding(.bottom, historyBand)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if state.notePanelOpen {
                NativeMokuNoteHistoryButton { state.setMokuOpen(true) }
                    .padding(.trailing, 18)
                    .frame(height: 40)
                    .opacity(state.settingsOpen ? 0 : 1)
                    .allowsHitTesting(!state.settingsOpen)
                    .accessibilityHidden(state.settingsOpen)
            }
        }
        .animation(surfaceAnimation, value: voiceControlVisible && (!inputPresent || voiceModeActive))
        .background {
            ZStack {
                NativeMokuCapsuleGlass().opacity(state.settingsExpanded ? 0 : 1)
                if state.settingsOpen {
                    NativeSettingsPanelGlass().opacity(state.settingsExpanded ? 1 : 0)
                        .environment(\.colorScheme, workspaceColorScheme)
                }
                voiceBackground.opacity(state.settingsOpen ? 0 : 1)
            }
        }.clipShape(RoundedRectangle(cornerRadius: NativeMokuCapsuleLayout.cornerRadius))
        .overlay(alignment: .bottom) {
            // Orbit ink lives outside the glass; never include it in the capsule clip.
            NativeMokuCharacterSurface(controller: character, input: characterInput, seat: .decorations)
                .frame(width: surface.width + decorationPadding * 2, height: rowHeight + decorationPadding * 2)
                .offset(y: decorationPadding)
                .allowsHitTesting(false)
        }
        .contentShape(RoundedRectangle(cornerRadius: NativeMokuCapsuleLayout.cornerRadius)).onHover(perform: updateHover)
        .shadow(color: .black.opacity(0.13), radius: hovered ? 17 : 13, y: 6)
        .nativeCanvasNavigationRegion()
        .accessibilityElement(children: .contain).accessibilityLabel(state.settingsOpen ? localize("设置", "Settings") : "Moku")
        .accessibilityHint(state.settingsOpen ? "" : localize("点击打开输入框，鼠标悬停时在触控板上向上滑动打开笔记", "Click to type; while hovering, swipe up on the trackpad for notes"))
        .accessibilityValue(state.noteUnread(note) ? localize("笔记有尚未完整浏览的更新", "Note update not yet fully browsed") : "")
        .accessibilityIdentifier("moku-capsule")
    }
    private func restoreVoiceComposer() {
        // A voice lifecycle change can arrive while Settings owns the capsule.
        // Defer the restoration receipt as well as the UI change until release.
        guard !state.settingsOpen, state.overviewVisible,
              let open = voiceComposerRestoration.update(active: voiceModeActive, inputOpen: state.inputOpen) else { return }
        if !open { state.retainDraft(draft) }
        state.setInputOpen(open && interaction == nil)
    }

    private func dispatchHarness(_ dispatch: NativeMokuDispatch) -> AnyHarnessPlugin? {
        try? presentation?.workspace.plugins.harnesses.require(dispatch.harnessID)
    }
    private func composer(room: CGFloat) -> some View {
        NativeMokuComposerInput(draft: draft, cwd: cwd, disabled: disabled || submitting,
            readOnly: state.inputLeaving, focusEnabled: state.overviewVisible && state.inputOpen && !state.dockCovered && focusReady,
            focusRequestKey: focusRequest, maxHeight: min(landing ? 156 : 126, room), landing: landing,
            retainedText: retaining ? state.retainedText : nil,
            retainedAttachments: retaining ? state.retainedAttachments : nil,
            retainedDirectories: retaining ? state.retainedDirectories : nil,
            canStartVoice: { state.windowVisible && !state.dockCovered && !navigationDisabled && canStartVoice() }, startVoice: startVoice,
            activeVoiceControls: voiceControls, voiceModeActive: voiceModeActive, running: running, onCancel: onCancel,
            availableHeight: room,
            mentions: directoryMentions, includesCompletion: false, onMentionFrame: { state.dockMentionHitRect = $0 },
            selectionRequest: directoryMentions.selectionRequest,
            initialSelection: state.retainedSelection,
            onEditorStateChange: { editor in
                if state.inputOpen, !editor.composing { state.retainSelection(editor.selection) }
                directoryMentions.update(editor)
            },
            onKeyDown: { directoryMentions.handle($0, draft: draft) },
            onEditorSeatChange: {
                // The retiring editor remains mounted inside a shrinking capsule.
                // Its new anchor would redirect the eyes mid-collapse; keep the
                // last open seat until live editing resumes.
                if state.inputOpen { editorBottomInset = $0 }
            },
            onEscape: { state.setInputOpen(false) }, onSend: send)
    }

    private func send() {
        guard !state.settingsOpen, !submitting, !disabled, state.inputOpen, draft.canSubmit else { return }
        state.retainDraft(draft, seal: true)
        state.dismissTalk()
        submitting = true
        state.setInputOpen(false)
        Task {
            await draft.submit(onSend)
            submitting = false
            if draft.error != nil, !state.mokuOpen { state.setInputOpen(true) }
        }
    }
    private func acknowledgePresentation() {
        guard residentPresenting, let presentation else { return }
        let token = presentation.displayToken
        Task { @MainActor in
            await Task.yield()
            guard residentPresenting, token == presentation.displayToken else { return }
            presentation.presented(token)
        }
    }
    private func updateHover(_ active: Bool) {
        hoverTask?.cancel(); hoverTask = nil
        if active { hovered = true }
        else {
            hoverTask = Task { @MainActor in
                do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
                hovered = false
            }
        }
    }
    private func localize(_ zh: String, _ en: String) -> String { locale.language.languageCode?.identifier == "zh" ? zh : en }
}
