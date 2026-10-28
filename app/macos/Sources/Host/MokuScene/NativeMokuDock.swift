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
    public var loadMentionDirectories: (() async throws -> [NativeComposerDirectory])?
    @Environment(\.locale) private var locale
    @Environment(\.nativeOfflineDraftEditing) private var offlineDraftEditing
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    @State private var hoverTask: Task<Void, Never>?
    @State private var capsuleHeight: CGFloat = 58
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
    @State private var landingNoticePresented = false

    public init(state: NativeMokuSceneState, draft: NativeComposerDraft, cwd: JSONText,
                landing: Bool = false,
                mode: MokuCharacterMode = .idle, running: Bool = false, talk: String? = nil,
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
                loadMentionDirectories: (() async throws -> [NativeComposerDirectory])? = nil,
                onSend: @escaping (NativeComposerSubmission) async throws -> Void,
                onCancel: @escaping () -> Void,
                canStartVoice: @escaping () -> Bool = { false },
                startVoice: @escaping () -> Void = {}) {
        self.state = state; self.draft = draft; self.cwd = cwd; self.mode = mode; self.running = running
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
        self.note = note; self.openExternal = openExternal
        self.loadMentionDirectories = loadMentionDirectories
    }
    private var retaining: Bool { state.inputLeaving || state.capsuleSealed }
    private var inputPresent: Bool {
        !state.notePanelOpen && (state.inputOpen || state.inputLeaving) && !voiceModeActive && interaction == nil
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
    private var landingTalk: NativeMokuTalkMessage? {
        guard landing, inputPresent, !state.dockCovered, state.overviewVisible,
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
    private var swipeControlAvailable: Bool {
        state.overviewVisible && state.windowVisible && !state.dockCovered && !navigationDisabled
            && interaction == nil && !state.inputOpen && !state.inputLeaving
    }
    private var voiceControlVisible: Bool {
        voiceStatusVisible
    }
    private var displayedMessage: NativeMokuTalkMessage? { visibleVoiceTranscript ?? visibleTalk }
    // A notification covered by live ASR has never been presented to the user.
    private var foregroundTalkID: JSONText? {
        guard visibleVoiceTranscript == nil else { return nil }
        return visibleTalk?.id ?? (landingNoticePresented ? landingTalk?.id : nil)
    }
    private var rowExpanded: Bool { (!voiceModeActive && state.inputOpen) || displayedMessage != nil }
    private var expanded: Bool { state.notePanelOpen || rowExpanded }
    private var surfaceAnimation: Animation? { reduceMotion ? nil : .smooth(duration: 0.42, extraBounce: 0) }
    /// Force-touch voice remains on Moku's original control row, rather than
    /// treating selectable note prose as a voice activation target.
    private var voiceActivationFrame: CGRect {
        let surface = state.capsuleFrame
        let height = state.notePanelOpen
            ? min(surface.height, rowExpanded ? surfaceHeight(width: surface.width) : NativeMokuCapsuleLayout.idleSize.height)
            : surface.height
        return CGRect(x: surface.minX, y: surface.maxY - height, width: surface.width, height: height)
    }
    private var talkTrailing: CGFloat { voiceControlVisible ? 48 : NativeMokuTalkTypography.trailing }
    private func surfaceHeight(width: CGFloat) -> CGFloat {
        guard let message = displayedMessage else { return max(landing ? 76 : 58, capsuleHeight) }
        if message.dispatch != nil { return 58 }
        return NativeMokuTalkTypography.capsuleHeight(message.text, width: width, trailingInset: talkTrailing)
    }
    private var residentPresenting: Bool {
        !state.dockCovered && state.overviewVisible && state.windowVisible && !state.inputOpen &&
        !submitting && !draft.submitting && interaction == nil && displayedMessage == nil
    }
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
        running && mode == .running && !expanded && !inputPresent && interaction == nil && !voiceModeActive
    }
    private var eyeExpression: MokuExpression {
        if state.inputOpen { return .focus }
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
            let width = state.notePanelOpen ? min(480, frame.width) : frame.width
            let rowHeight = rowExpanded ? surfaceHeight(width: width) : NativeMokuCapsuleLayout.idleSize.height
            let noteAvailableHeight = max(0, frame.height - rowHeight)
            let noteHeight = state.notePanelOpen
                ? NativeMokuNoteLayout.fittedHeight(content: noteContentHeight, available: noteAvailableHeight) : 0
            let availableSurface = CGRect(x: frame.midX - width / 2, y: frame.minY,
                                          width: width, height: frame.height)
            let surface = NativeMokuCapsuleLayout.surface(in: availableSurface, expanded: expanded,
                height: rowHeight + noteHeight, centered: landing)
            let panel = NativeMokuCapsuleLayout.panel(in: viewport, above: surface,
                                                     question: interactionIsQuestion)
            let notice = landingNoticeFrame(in: viewport, above: surface)
            let noteButtonRect: CGRect? = nil
            ZStack(alignment: .topLeading) {
                capsule(width: width, room: max(58, frame.height - 18),
                        surface: surface, rowHeight: rowHeight, noteHeight: noteHeight)
                    .nativeCanvasNavigationRegion()
                    .position(x: surface.midX, y: surface.midY)
                    .animation(surfaceAnimation, value: surface)
                if let message = landingTalk, let notice {
                    landingNotice(message, frame: notice)
                        .position(x: notice.midX, y: notice.midY)
                        .animation(surfaceAnimation, value: notice)
                }
                if let interaction {
                    interaction.padding(18)
                        .frame(width: panel.width, height: panel.height, alignment: .topLeading)
                        .nativeCanvasNavigationRegion()
                        .background { NativeMokuCapsuleGlass(interactive: false) }
                        .environment(\.colorScheme, .dark)
                        .position(x: panel.midX, y: panel.midY)
                }
            }
            .coordinateSpace(name: "native-moku-dock")
            .onChange(of: HitLayout(surface: surface, panel: panel, interaction: interaction != nil, noteButton: noteButtonRect, notice: notice), initial: true) { _, layout in
                landingNoticePresented = state.overviewVisible && layout.notice != nil
                guard state.overviewVisible else {
                    state.dockHitRects = []
                    state.dockMentionHitRect = nil
                    return
                }
                state.capsuleFrame = layout.surface
                state.dockHitRects = [layout.surface.insetBy(dx: -5, dy: -5)]
                if layout.interaction { state.dockHitRects.append(layout.panel) }
                if let button = layout.noteButton { state.dockHitRects.append(button) }
                if let notice = layout.notice { state.dockHitRects.append(notice) }
            }
            .onChange(of: interaction != nil, initial: true) { _, visible in
                state.setDockInteractionVisible(state.overviewVisible && visible, question: interactionIsQuestion)
                if visible && state.overviewVisible { state.setInputOpen(false) }
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
                    outsideWindowClick: foregroundTalkID != nil && !state.notePanelOpen ? { state.dismissTalk() } : nil,
                    isInside: { point in
                        NativeMokuOutsideClick.isInside(point: point, dockRects: state.dockHitRects)
                    },
                    click: { _ in
                        if state.notePanelOpen { state.setNotePanelOpen(false) }
                        else if state.inputOpen && !landing { state.dismissInputForOutsideClick() }
                        else { state.dismissTalk() }
                    })
                if state.notePanelOpen {
                    NativeSettingsEscapeHandler { state.setNotePanelOpen(false) }
                        .frame(width: 0, height: 0)
                }
                NativeMokuSwipeMonitor(
                    isActive: { swipeControlAvailable },
                    isInside: { point in
                        let row = voiceActivationFrame
                        return NativeMokuSwipeTarget.contains(point, row: row, showingMessage: displayedMessage != nil,
                            excluding: voiceControlVisible ? [voiceControlsFrame] : [])
                    },
                    openNote: { state.openNotePanelFromUser() },
                    // Voice owns the composer seat; notes only change presentation.
                    openInput: { if !voiceModeActive { state.setInputOpen(true) } })
                NativeMokuForceTouchVoiceMonitor(
                    isActive: { state.overviewVisible && !state.dockCovered && state.windowVisible },
                    isInside: { voiceActivationFrame.insetBy(dx: -5, dy: -5).contains($0) },
                    canStart: canStartVoice, start: startVoice)
            }
            .allowsHitTesting(false)
        }
        .onChange(of: landingInputAvailable, initial: true) { _, available in
            if available { state.setInputOpen(true) }
        }
        .onChange(of: landing) { _, active in
            if !active {
                state.retainDraft(draft)
                state.setInputOpen(false)
            }
        }
        .onChange(of: state.inputOpen, initial: true) { _, open in
            if !open && landingInputAvailable { state.setInputOpen(true); return }
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
        .onChange(of: incomingTalk, initial: true) { _, message in state.receiveTalk(message) }
        .onChange(of: note, initial: true) { previous, value in
            if previous?.documentToken != value?.documentToken { noteContentHeight = 0 }
            state.reconcileNoteExposure(value)
        }
        .onChange(of: state.windowVisible) { _, visible in if visible { state.retryNoteExposure() } }
        .onChange(of: navigationDisabled) { _, value in if value { state.setNotePanelOpen(false) } }
        .onChange(of: voiceModeActive, initial: true) { _, active in
            guard let open = voiceComposerRestoration.update(active: active, inputOpen: state.inputOpen) else { return }
            guard state.overviewVisible else { return }
            if open {
                state.setInputOpen(true)
            } else {
                state.retainDraft(draft)
                state.setInputOpen(false)
            }
        }
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
            landingNoticePresented = false
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
    }
    private struct HitLayout: Equatable {
        var surface, panel: CGRect
        var interaction: Bool
        var noteButton: CGRect?
        var notice: CGRect?
    }
    private func landingNoticeFrame(in viewport: CGRect, above surface: CGRect) -> CGRect? {
        guard let message = landingTalk else { return nil }
        let width = min(560, surface.width)
        let available = max(0, surface.minY - viewport.minY - NativeWindowNavigationGeometry.safeAreaTop - 12)
        let minimum = message.dispatch != nil ? 28.0 : NativeMokuTalkTypography.lineHeight
        guard available >= minimum + 24 else { return nil }
        let content = message.dispatch != nil ? 28.0
            : min(NativeMokuTalkTypography.maximumHeight, NativeMokuTalkTypography.height(message.text, width: width - 32))
        let height = min(available, content + 24)
        return CGRect(x: surface.midX - width / 2, y: surface.minY - height - 12, width: width, height: height)
    }
    private func landingNotice(_ message: NativeMokuTalkMessage, frame: CGRect) -> some View {
        Group {
            if let dispatch = message.dispatch {
                NativeMokuDispatchContent(dispatch: dispatch, harness: dispatchHarness(dispatch)) { dispatchDetail = message }
            } else { NativeMokuTalkContent(message: message) }
        }
        .frame(width: max(1, frame.width - 32), height: max(0, frame.height - 24))
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background { NativeMokuCapsuleGlass(usesThemeTint: true).id(colorScheme) }
        .shadow(color: .black.opacity(0.1), radius: 10, y: 4)
        .nativeCanvasNavigationRegion()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("moku-landing-notice")
    }
    private func capsule(width: CGFloat, room: CGFloat, surface: CGRect, rowHeight: CGFloat, noteHeight: CGFloat) -> some View {
        let idleWidth = min(NativeMokuCapsuleLayout.idleSize.width, width)
        let idleHeight = NativeMokuCapsuleLayout.idleSize.height
        let followsEditor = inputPresent && displayedMessage == nil
        return ZStack(alignment: .bottomLeading) {
            if composerMounted {
                composer(room: room).frame(width: width).fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { capsuleHeight = max(58, $0) }
                    .opacity(inputPresent ? capsuleFraction : 0)
                    // Let the eyes clear the text seat on expansion; fade prose
                    // quickly before they cross it again during collapse.
                    .animation(reduceMotion ? nil : (inputPresent ? .easeIn(duration: 0.42) : .easeOut(duration: 0.12)), value: inputPresent ? capsuleFraction : 0)
                    .allowsHitTesting(inputPresent)
                    .accessibilityHidden(!inputPresent)
            }
        }
        .frame(width: surface.width, height: surface.height, alignment: .bottomLeading)
        .overlay(alignment: .top) {
            if state.notePanelOpen {
                NativeMokuNoteContent(note: note, width: width, availableHeight: noteHeight,
                                      routeEligible: state.notePanelOpen && state.overviewVisible
                                          && !state.dockCovered && !navigationDisabled,
                                      openExternal: openExternal,
                                      onContentHeightChange: { noteContentHeight = $0 },
                                      claimOpenArm: { state.claimNoteOpenArm() },
                                      onExposure: { state.recordNoteExposure($0) },
                                      onClose: { state.setNotePanelOpen(false) })
                    // The reading document lays out at its final width; only
                    // the enclosing glass bounds interpolate and clip it.
                    .transaction { $0.animation = nil }
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottomLeading) {
            // Bottom alignment keeps Moku on the input row while only the
            // glass above it changes height. The inset is measured inside
            // the input, so menu and shell animation cannot affect it.
            HStack(alignment: .center, spacing: 15) {
                Group {
                    if runningFeedback {
                        Color.clear
                    } else {
                        NativeMokuBlinkingEyes(expression: eyeExpression, focus: expanded ? 1 : 0)
                    }
                }
                    .animation(surfaceAnimation, value: expanded)
                    .animation(surfaceAnimation, value: eyeExpression)
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
            .frame(height: followsEditor ? nil : rowHeight)
            .padding(.leading, (idleWidth - 34) / 2 * (1 - capsuleFraction) + 15 * capsuleFraction)
            .padding(.bottom, followsEditor
                ? idleHeight / 2 - 12.5 + (editorBottomInset - idleHeight / 2) * capsuleFraction : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay(alignment: .bottomTrailing) {
            if running && !inputPresent && !voiceModeActive {
                Button(action: onCancel) {
                    RoundedRectangle(cornerRadius: 1).fill(.foreground).frame(width: 10, height: 10)
                        .frame(width: 30, height: 30).contentShape(Circle())
                }.buttonStyle(.plain).disabled(disabled)
                    .help(localize("停止 Moku", "Stop Moku"))
                    .accessibilityLabel(localize("停止 Moku", "Stop Moku"))
                    .accessibilityIdentifier("moku-stop")
                    .padding(.trailing, 7).frame(height: rowHeight)
            } else if voiceControlVisible && (!inputPresent || voiceModeActive) {
                voiceControls.fixedSize(horizontal: true, vertical: true)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("native-moku-dock")) } action: { voiceControlsFrame = $0 }
                    .padding(.trailing, 3).frame(height: rowHeight)
                    .transition(.opacity)
            }
        }
        .animation(surfaceAnimation, value: voiceControlVisible && (!inputPresent || voiceModeActive))
        .background {
            ZStack {
                NativeMokuCapsuleGlass(usesThemeTint: true).id(colorScheme)
                voiceBackground
            }
        }.clipShape(RoundedRectangle(cornerRadius: NativeMokuCapsuleLayout.cornerRadius))
        .overlay {
            // Orbit ink lives outside the glass; never include it in the capsule clip.
            if runningFeedback {
                NativeMokuRunningEyes(reduceMotion: reduceMotion, capsuleSize: surface.size,
                                      cornerRadius: NativeMokuCapsuleLayout.cornerRadius)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: NativeMokuCapsuleLayout.cornerRadius)).onHover(perform: updateHover)
        .shadow(color: .black.opacity(0.13), radius: hovered ? 17 : 13, y: 6)
        .nativeCanvasNavigationRegion()
        .accessibilityElement(children: .contain).accessibilityLabel("Moku")
        .accessibilityHint(landing ? localize("输入任务交给 Moku", "Type a task for Moku")
            : localize("鼠标悬停时在触控板上向上滑动打开笔记，向左滑动打开输入框", "While hovering, swipe up on the trackpad for notes, or left to type"))
        .accessibilityValue(state.noteUnread(note) ? localize("笔记有尚未完整浏览的更新", "Note update not yet fully browsed") : "")
        .accessibilityIdentifier("moku-capsule")
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
            activeVoiceControls: voiceControls, voiceModeActive: voiceModeActive, running: running, onCancel: onCancel,
            availableHeight: room,
            mentions: directoryMentions, onMentionFrame: { state.dockMentionHitRect = $0 },
            selectionRequest: directoryMentions.selectionRequest,
            onEditorStateChange: directoryMentions.update,
            onKeyDown: { directoryMentions.handle($0, draft: draft) },
            onEditorSeatChange: { editorBottomInset = $0 },
            onEscape: { if !landing { state.setInputOpen(false) } }, onSend: send)
    }

    private func send() {
        guard !submitting, !disabled, state.inputOpen, draft.canSubmit else { return }
        state.retainDraft(draft, seal: !landing)
        state.dismissTalk()
        submitting = true
        if !landing { state.setInputOpen(false) }
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
