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

// The action row changes only when the remaining message can still be read.
// Widths come from the mounted controls; the initial estimates prevent overlap
// until SwiftUI reports their intrinsic sizes.
@MainActor struct NativeMokuNoteActionLayout {
    let width: CGFloat
    let historyWidth: CGFloat
    let controlWidth: CGFloat
    let hasMessage: Bool
    let isDispatch: Bool

    private var trailing: CGFloat { controlWidth > 0 ? 7 : 18 }
    private var fullActions: CGFloat { historyWidth + (controlWidth > 0 ? 4 + controlWidth : 0) + trailing }
    // Preserve the message seat when a Stop or voice control retires.
    private var sharedActions: CGFloat {
        hasMessage ? historyWidth + 4 + max(34, controlWidth) + 7 : fullActions
    }
    var compact: Bool { fullActions > width }
    var stacked: Bool { controlWidth > 0 && 28 + 4 + controlWidth + trailing > width }
    var band: CGFloat {
        if stacked { return 80 }
        let requiredLeading = hasMessage ? NativeMokuTalkTypography.leading + (isDispatch ? 240 : 200) : 64
        return width < requiredLeading + max(48, sharedActions + 8) ? 40 : 0
    }
    var messageTrailing: CGFloat { band > 0 ? 48 : max(48, sharedActions + 8) }
    var edgeInset: CGFloat { stacked && width < controlWidth + trailing ? 0 : trailing }
}

struct NativeMokuNoteActionStack<Content: View>: View {
    let stacked: Bool
    let trailing: CGFloat
    let height: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .trailing, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 4))
        layout { content }
            .padding(.trailing, trailing)
            .frame(height: height)
    }
}

/// One glass capsule. Production composer, transcript and interaction ownership stay in the scene.
/// Moku history shares its draft; Agent detail supplies its own Thread draft.
public struct NativeMokuDock: View {
    public let state: NativeMokuSceneState
    public let draft: NativeComposerDraft
    public let cwd: JSONText
    public var threadID: JSONText?
    public var threadTitle: String?
    public var threadHarness: AnyHarnessPlugin?
    public var onThreadClose: (() -> Void)?
    public var sidecardComposer: SidecardComposerRequest?
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.nativeExecutionDockPlacement) private var executionPlacement
    @State private var hovered = false
    @State private var hoverTask: Task<Void, Never>?
    @FocusState private var stopFocused: Bool
    @AccessibilityFocusState private var stopAccessibilityFocused: Bool
    @State private var capsuleHeight: CGFloat = 58
    @State private var completionHeight: CGFloat = 0
    @State private var submissionDraft: NativeComposerDraft?
    @State private var focusReady = false
    @State private var focusRequest = 0
    @State private var directoryMentions = NativeMokuDirectoryMentions()
    @State private var editorBottomInset: CGFloat = 29
    @State private var noteContentHeight: CGFloat = 0
    @State private var noteMounted = false
    @State private var noteExpanded = false
    @State private var noteInkVisible = false
    @State private var noteSettled = false
    @State private var messageInkVisible = true
    @State private var noteTransitionGeneration = 0
    @State private var settingsPreferredHeight: CGFloat = 900
    @State private var historyActionWidth: CGFloat = 110
    @State private var voiceActionWidth: CGFloat = 34
    @State private var voiceControlsFrame = CGRect.zero
    @State private var stopControlsFrame = CGRect.zero
    @State private var voiceComposerRestoration = NativeMokuVoiceComposerRestoration()
    @State private var talkScrollbarStyle = NSScroller.preferredScrollerStyle
    @State private var dispatchDetail: NativeMokuTalkMessage?
    @State private var character = NativeMokuCharacterMotion()
    @State private var reasoningRequested = false
    @State private var reasoningSeatReserved = false
    @State private var reasoningReady = false
    @State private var reasoningTransition = 0
    @State private var retainedReasoningGlyphs: [MokuReasoningGlyph] = []

    public init(state: NativeMokuSceneState, draft: NativeComposerDraft, cwd: JSONText,
                landing: Bool = false, threadID: JSONText? = nil, threadTitle: String? = nil,
                threadHarness: AnyHarnessPlugin? = nil, onThreadClose: (() -> Void)? = nil,
                sidecardComposer: SidecardComposerRequest? = nil,
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
        self.threadID = threadID
        self.threadTitle = threadTitle
        self.threadHarness = threadHarness; self.onThreadClose = onThreadClose
        self.sidecardComposer = sidecardComposer
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
    private var submitting: Bool { submissionDraft === draft || draft.submitting }
    private var inputPresent: Bool {
        !state.settingsOpen && !state.notePanelOpen && (state.inputOpen || state.inputLeaving) && !voiceModeActive && interaction == nil
            && (state.inputOpen || displayedMessage == nil)
    }
    /// Settings retires the composer the moment it opens, but the face should
    /// leave from the composer seat it occupied. Holding that seat until the
    /// shell starts growing keeps the eyes from twitching down to the idle row
    /// before they travel to the panel.
    private var composerSeatHeld: Bool {
        state.settingsOpen && !state.settingsExpanded && !state.notePanelOpen
            && (state.inputOpen || state.inputLeaving) && !voiceModeActive && interaction == nil
    }
    private var composerMounted: Bool {
        state.dockRouteVisible && !state.notePanelOpen && (state.inputOpen || state.inputLeaving || (voiceModeActive && voiceComposerRestoration.shouldRestore)) && interaction == nil
    }
    private var incomingTalk: NativeMokuTalkMessage? {
        if let presentation { return presentation.talkMessage }
        guard let talk, !talk.isEmpty else { return nil }
        return NativeMokuTalkMessage(id: JSONText(talk), text: talk)
    }
    private var visibleTalk: NativeMokuTalkMessage? {
        guard threadTitle == nil, !state.inputOpen, interaction == nil, !state.dockCovered, state.dockRouteVisible,
              state.windowVisible, !disabled, !submitting, !draft.submitting else { return nil }
        return state.talkPresentation.message
    }
    private var visibleVoiceTranscript: NativeMokuTalkMessage? {
        guard voiceModeActive, interaction == nil, !state.dockCovered, state.dockRouteVisible,
              state.windowVisible, !disabled else { return nil }
        return voiceTranscript
    }
    private var navigationDisabled: Bool { disabled && !offlineDraftEditing }
    private var landingInputAvailable: Bool {
        landing && state.overviewVisible && !state.dockCovered && !state.notePanelOpen
            && !voiceModeActive && interaction == nil && !navigationDisabled
    }
    private var rowControlAvailable: Bool {
        state.inputInteractionReady && state.dockRouteVisible && state.windowVisible && !state.dockCovered && !navigationDisabled
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
    private var expanded: Bool { state.settingsExpanded || noteExpanded || rowExpanded }
    private var capsuleFraction: CGFloat { expanded ? 1 : 0 }
    private var surfaceAnimation: Animation? {
        reduceMotion ? nil : state.readingPanelVisible
            ? NativeReadingPageTiming.openingAnimation : .smooth(duration: 0.42, extraBounce: 0)
    }
    /// Centre of the resident face seat in shell-local points. The composer row
    /// carries the face with the editor; a retired composer keeps it on the row
    /// the shell's own layout reserves.
    private static func faceSeatCenter(shell: CGSize, rowHeight: CGFloat, historyBand: CGFloat,
                                       capsuleWidth: CGFloat, composerFraction: CGFloat,
                                       editorBottomInset: CGFloat, followsEditor: Bool) -> CGPoint {
        let idle = NativeMokuCapsuleLayout.idleSize
        let leading = (min(idle.width, capsuleWidth) - NativeMokuFaceLayout.seat.width) / 2 * (1 - composerFraction)
            + 15 * composerFraction
        let bottom = followsEditor
            ? idle.height / 2 - 12.5 + (editorBottomInset - idle.height / 2) * composerFraction
            : historyBand
        let centerY = followsEditor
            ? shell.height - bottom - NativeMokuFaceLayout.seat.height / 2
            : shell.height - bottom - (rowHeight - historyBand) / 2
        return CGPoint(x: leading + NativeMokuFaceLayout.seat.width / 2, y: centerY)
    }

    /// Moku's face keeps its layout seat for its whole lifetime. While Settings
    /// owns the shell the same view is shifted into the page's header slot, and
    /// the shift returns to zero as the shell contracts. The panel is dark like
    /// the capsule, so the face keeps its existing ink there.
    private func face(_ input: NativeMokuCharacterInput) -> some View {
        NativeMokuCharacterSurface(controller: character, input: input, seat: .face)
            // The panel corner shows the eyes at their ordinary size, so the
            // landing scale retires inside the same transaction.
            .scaleEffect(landing && expanded && !state.settingsExpanded ? NativeMokuCapsuleLayout.landingScale : 1)
            .frame(width: NativeMokuFaceLayout.canvas.width, height: NativeMokuFaceLayout.canvas.height)
            .frame(width: NativeMokuFaceLayout.seat.width, height: NativeMokuFaceLayout.seat.height)
            .allowsHitTesting(false).accessibilityHidden(true)
    }

    @ViewBuilder private func rowMessage(_ message: NativeMokuTalkMessage, width: CGFloat) -> some View {
        if let dispatch = message.dispatch {
            NativeMokuDispatchContent(dispatch: dispatch, harness: dispatchHarness(dispatch)) {
                dispatchDetail = message
            }
            .frame(width: max(1, width - NativeMokuTalkTypography.leading - 48), height: 28)
        } else {
            NativeMokuTalkContent(message: message, scrollbarStyle: talkScrollbarStyle)
                .accessibilityIdentifier(visibleVoiceTranscript == nil ? "moku-talk-content" : "moku-voice-transcript")
                .frame(width: max(1, width - NativeMokuTalkTypography.leading - 48),
                       height: max(0, surfaceHeight(width: width) - NativeMokuTalkTypography.verticalPadding * 2))
                .padding(.vertical, NativeMokuTalkTypography.verticalPadding)
                // Text snapshots change discretely. Interpolating the
                // native document/clip heights produces fractional
                // overflow and flashes the overlay scroller at wraps.
                // Keep the glass animation outside this transaction.
                .transaction { $0.animation = nil }
                // Resolve shell/row travel before the native viewport's discrete
                // layout. Otherwise its leaves adopt the final scene coordinates
                // while the glass is still moving. Talk keeps this viewport and
                // its scroll state while Note temporarily owns the reading seat.
                .geometryGroup()
                .transition(.opacity.animation(reduceMotion ? nil : .easeInOut(duration: 0.22)))
        }
    }
    /// Force-touch voice remains on Moku's original control row, rather than
    /// treating selectable note prose as a voice activation target.
    private var voiceActivationFrame: CGRect {
        let surface = state.capsuleFrame
        let height = noteExpanded
            ? min(surface.height, NativeMokuCapsuleLayout.idleSize.height)
            : surface.height
        return CGRect(x: surface.minX, y: surface.maxY - noteHistoryBand(width: surface.width) - height, width: surface.width, height: height)
    }
    private var stopControlPresent: Bool {
        running && !inputPresent && !voiceModeActive && !state.settingsOpen
    }
    private var voiceActionPresent: Bool { voiceControlVisible && (!inputPresent || voiceModeActive) }
    private func noteActions(width: CGFloat) -> NativeMokuNoteActionLayout {
        NativeMokuNoteActionLayout(width: width, historyWidth: historyActionWidth,
            controlWidth: stopControlPresent ? 30 : (voiceActionPresent ? voiceActionWidth : 0),
            hasMessage: !noteExpanded && displayedMessage != nil, isDispatch: !noteExpanded && displayedMessage?.dispatch != nil)
    }
    private func noteHistoryBand(width: CGFloat) -> CGFloat {
        noteExpanded ? noteActions(width: width).band : 0
    }
    private var stopVisible: Bool { hovered || stopFocused || stopAccessibilityFocused }
    // Talk keeps its ordinary control inset while covered, preserving wrapping
    // and scroll position without reserving a second message row inside Note.
    private func surfaceHeight(width: CGFloat) -> CGFloat {
        guard let message = displayedMessage else {
            return max(landing ? 76 : 58, capsuleHeight) + (completionVisible ? completionHeight : 0)
        }
        if message.dispatch != nil { return landing ? 76 : 58 }
        // Live ASR is unbounded like dictation, not length-capped like Talk, so it
        // keeps growing past the notification viewport before it scrolls.
        let maximumHeight = visibleVoiceTranscript == nil
            ? NativeMokuTalkTypography.maximumHeight : NativeMokuTalkTypography.transcriptMaximumHeight
        return max(landing ? 76 : 58, NativeMokuTalkTypography.capsuleHeight(message.text, width: width,
            trailingInset: 48, maximumHeight: maximumHeight, scrollbarStyle: talkScrollbarStyle))
    }
    private var residentPresenting: Bool {
        threadTitle == nil && !state.dockCovered && state.dockRouteVisible && state.windowVisible && !state.inputOpen &&
        !submitting && !draft.submitting && interaction == nil && displayedMessage == nil
    }
    private var completionVisible: Bool { inputPresent && !retaining && directoryMentions.isOpen }
    private var mentionsEnabled: Bool {
        sidecardComposer == nil && state.dockRouteVisible && state.inputOpen && !disabled && !state.dockCovered && state.windowVisible && interaction == nil
    }
    private var reminder: NativeMokuDockReply? {
        guard let reply, !state.readReplies.contains(JSONText(reply.readKey)),
              (presentation?.sessionIdle ?? !running), mode == .idle,
              !state.inputOpen, interaction == nil, !state.dockCovered else { return nil }
        return reply
    }
    private var runningFeedback: Bool {
        !state.settingsOpen && running && (mode == .running || incomingReasoning != nil)
            && !expanded && !state.notePanelOpen && !noteMounted && !inputPresent && interaction == nil && !voiceModeActive
            && !disabled && (presentation?.workspace.runtimeAvailable ?? true)
    }
    private var incomingReasoning: MokuReasoningContent? {
        guard threadTitle == nil, running else { return nil }
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
            // Keep the reading baseline; only the horizontal seat belongs to
            // the target execution column. Stacked layouts share its full width.
            let executionFrame = state.readingPanelVisible && threadID != nil && !state.settingsOpen
                && executionPlacement?.threadID == threadID
                ? executionPlacement?.frame : nil
            let column = executionFrame.map {
                CGRect(x: $0.minX, y: viewport.minY, width: $0.width, height: viewport.height).intersection(viewport)
            }
            let dockViewport = column.flatMap { $0.isNull || $0.isEmpty ? nil : $0 } ?? viewport
            let baseFrame = NativeMokuCapsuleLayout.frame(in: dockViewport, landing: landing,
                reading: state.readingPanelVisible && !state.settingsOpen)
            let messageWidth = displayedMessage?.dispatch != nil ? min(400, baseFrame.width) : baseFrame.width
            let frame = baseFrame.insetBy(dx: !noteExpanded && displayedMessage?.dispatch != nil ? max(0, (baseFrame.width - 400) / 2) : 0, dy: 0)
            let settingsSize = CGSize(width: min(780, max(0, viewport.width - 48)), height: min(settingsPreferredHeight, max(0, viewport.height - 48)))
            let width = state.settingsExpanded ? settingsSize.width : noteExpanded ? min(560, baseFrame.width) : frame.width
            let rowHeight = state.settingsExpanded || noteExpanded ? NativeMokuCapsuleLayout.idleSize.height + noteHistoryBand(width: width)
                : (rowExpanded ? surfaceHeight(width: width) : NativeMokuCapsuleLayout.idleSize.height) + noteHistoryBand(width: width)
            let noteAvailableHeight = max(0, frame.height - rowHeight)
            let noteHeight = noteExpanded
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
            let destination = NativeMokuHorizontalDestination(offset: placement.surface.midX - geometry.size.width / 2,
                frame: executionFrame, revision: executionPlacement?.travelRevision ?? 0, viewport: geometry.size,
                dragging: executionPlacement?.dragging == true, reduced: reduceMotion,
                composer: state.composerGeneration, reading: state.readingPanelVisible)
            ZStack(alignment: .topLeading) {
                capsule(width: width, room: max(58, frame.height - 18),
                        surface: surface, messageWidth: messageWidth, rowHeight: rowHeight, noteHeight: noteHeight,
                        noteAvailableHeight: noteAvailableHeight, decorationPadding: placement.decorationPadding, settingsSize: settingsSize)
                    .nativeCanvasNavigationRegion()
                    .geometryGroup()
                    // Seat the native editor on the bottom edge. Animating a
                    // centre position as well as the shell height applies the
                    // destination row layout before its translation has moved,
                    // making retiring AppKit text jump vertically for a frame.
                    .scaleEffect(placement.scale, anchor: .bottom)
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottom)
                    .offset(y: placement.surface.maxY - geometry.size.height)
                    .animation(reduceMotion || executionPlacement?.dragging == true ? nil
                        : NativeSidecardTiming.foldAnimation, value: executionFrame)
                    .animation(surfaceAnimation, value: placement)
                    // Inner shell animations must not inherit the discrete
                    // horizontal offset owned by the native compositor.
                    .geometryGroup()
                    .offset(x: destination.offset)
                    .animation(nil, value: destination.offset)
                    // Direct resize settles the native trip and shell together.
                    .transaction(value: geometry.size) {
                        $0.animation = nil; $0.disablesAnimations = true
                    }
                if let interaction, !state.settingsOpen {
                    interaction.padding(18)
                        .frame(width: panel.width, height: panel.height, alignment: .topLeading)
                        .nativeLayoutLog("moku.interaction.panel")
                        .nativeCanvasNavigationRegion()
                        .background { NativeMokuCapsuleGlass(interactive: false) }
                        .environment(\.colorScheme, .dark)
                        .position(x: panel.midX, y: panel.midY)
                }
            }
            .coordinateSpace(name: "native-moku-dock")
            .background {
                NativeMokuHorizontalTravelCommand(destination: destination,
                    hitRects: [placement.surface.insetBy(dx: -5, dy: -5)]
                        + (interaction != nil && !state.settingsOpen ? [panel] : []),
                    onSettled: { arrived in
                        guard state.composerGeneration == arrived.composer else { return }
                        executionPlacement?.completeTravel(revision: arrived.revision)
                    })
                    .allowsHitTesting(false)
            }
            .nativeLayoutLog("moku.dock.viewport")
            .onPreferenceChange(NativeSettingsPreferredHeightKey.self) { height in
                settingsPreferredHeight = max(900, ceil(height))
            }
            .onChange(of: HitLayout(surface: placement.surface, panel: panel, interaction: interaction != nil && !state.settingsOpen, noteButton: noteButtonRect), initial: true) { _, layout in
                guard state.dockRouteVisible else {
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
                state.setDockInteractionVisible(state.dockRouteVisible && visible, question: interactionIsQuestion)
                if visible && state.dockRouteVisible && !state.settingsOpen { state.setInputOpen(false) }
                else if !visible, threadTitle != nil, !state.dockCovered { state.setInputOpen(true) }
            }
            .onChange(of: interactionIsQuestion) { _, value in
                state.setDockInteractionVisible(state.dockRouteVisible && interaction != nil, question: value)
            }
        }
        .overlay {
            ZStack {
                NativeMokuOutsideClickMonitor(
                    exclusions: state.outsideClickExclusions,
                    beginClick: { state.beginOutsideClick() },
                    isActive: { (state.inputOpen || (!navigationDisabled && (state.notePanelOpen || foregroundTalkID != nil))) && state.dockRouteVisible && !state.dockCovered },
                    usesExclusions: foregroundTalkID == nil || state.notePanelOpen,
                    preservesOwnedInteractions: state.inputOpen,
                    preservedClick: { state.preserveInputForOwnedClick() },
                    outsideWindowClick: !state.notePanelOpen && foregroundTalkID != nil ? {
                        state.dismissTalk()
                    } : nil,
                    isInside: { point in
                        NativeMokuOutsideClick.isInside(point: point, dockRects: state.dockHitRects)
                            || state.dockMentionHitRect?.contains(point) == true
                    },
                    click: { _ in
                        if state.notePanelOpen { state.setNotePanelOpen(false) }
                        else if state.inputPinnedOpen, directoryMentions.dismiss() {
                            state.preserveInputForOwnedClick()
                        }
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
                        return NativeMokuSwipeTarget.contains(point, row: row,
                            eyesOnly: (voiceModeActive && displayedMessage != nil) || displayedMessage?.dispatch != nil,
                            excluding: (voiceActionPresent ? [voiceControlsFrame] : [])
                                + (stopControlPresent ? [stopControlsFrame] : []))
                    },
                    openNote: { state.openNotePanelFromUser() })
            }
            .allowsHitTesting(false)
        }
        .nativeReadingEscape(perform: !state.inputPinnedOpen && state.inputOpen && state.dockContentVisible && interaction == nil ? {
            escapeInput()
        } : nil)
        .onChange(of: landing, initial: true) { _, active in
            guard state.updateLanding(active) else { return }
            if active {
                if landingInputAvailable && !running && incomingTalk == nil { state.setInputOpen(true) }
            } else if threadTitle == nil {
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
        .onChange(of: ObjectIdentifier(draft)) { _, _ in
            focusReady = false
            directoryMentions = NativeMokuDirectoryMentions()
            voiceComposerRestoration = NativeMokuVoiceComposerRestoration()
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
        .onReceive(NotificationCenter.default.publisher(for: NSScroller.preferredScrollerStyleDidChangeNotification)) { _ in
            talkScrollbarStyle = NSScroller.preferredScrollerStyle
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
        .onChange(of: TalkPresentation(id: foregroundTalkID, noteCovering: state.notePanelOpen || noteMounted), initial: true) { _, value in
            // Covering a Talk with Note is a reversible reading visit. Calling
            // setPresented(false) here would consume the notification. Existing
            // deadlines keep running; newly received Talk waits for actual return.
            if !value.noteCovering { state.setTalkPresented(value.id != nil) }
        }
        .onChange(of: NoteDestination(open: state.notePanelOpen,
            immediate: reduceMotion || scenePhase != .active || !state.windowVisible || !state.dockRouteVisible
                || state.dockCovered || state.inputOpen || interaction != nil), initial: true) { _, destination in
            transitionNote(to: destination)
        }
        .onDisappear { noteTransitionGeneration &+= 1 }
        .task(id: state.talkPresentation.deadline) {
            guard let deadline = state.talkPresentation.deadline, let id = state.talkPresentation.message?.id else { return }
            // SwiftUI cancels on replacement, dismissal and unmount. The scene
            // also fences the captured identity in case cancellation races delivery.
            do { try await ContinuousClock().sleep(until: deadline) } catch { return }
            guard !Task.isCancelled else { return }
            state.expireTalk(id: id, deadline: deadline)
        }
        .onChange(of: state.dockRouteVisible) { _, visible in
            guard !visible else { return }
            focusReady = false
            state.dockHitRects = []
            state.dockMentionHitRect = nil
            hoverTask?.cancel(); hoverTask = nil
        }
        .task(id: "\(state.composerGeneration):\(state.inputInteractionReady && state.dockRouteVisible && state.inputOpen && !state.dockCovered):\(reduceMotion)") {
            guard state.inputInteractionReady, state.dockRouteVisible, state.inputOpen, !state.dockCovered else { focusReady = false; return }
            let generation = state.composerGeneration
            if !reduceMotion {
                do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            }
            guard !Task.isCancelled, state.composerGeneration == generation, state.ownsComposer(draft),
                  state.inputInteractionReady, state.dockRouteVisible, state.inputOpen, !state.dockCovered else { return }
            focusReady = true; focusRequest += 1
        }
        .onChange(of: draft.text) { _, _ in if state.dockRouteVisible && state.inputOpen { state.retainDraft(draft) } }
        .onChange(of: draft.attachments) { _, _ in if state.dockRouteVisible && state.inputOpen { state.retainDraft(draft) } }
        .onChange(of: sidecardComposer?.ready) { _, ready in
            if ready == true { focusRequest += 1 }
        }
        .onChange(of: submitting) { _, busy in
            if !busy, sidecardComposer?.ready == true { focusRequest += 1 }
        }
        .onChange(of: draft.directories) { _, _ in if state.dockRouteVisible && state.inputOpen { state.retainDraft(draft) } }
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
        .task(id: "\(state.composerGeneration):\(mentionsEnabled)") { await directoryMentions.load(enabled: mentionsEnabled, using: loadMentionDirectories) }
        // Keep the override local: a preferredColorScheme would also recolor
        // the containing workspace window and its other application surfaces.
        .environment(\.colorScheme, .dark)
    }

    private struct HitLayout: Equatable {
        var surface, panel: CGRect
        var interaction: Bool
        var noteButton: CGRect?
    }
    private struct TalkPresentation: Equatable {
        let id: JSONText?
        let noteCovering: Bool
    }
    private struct NoteDestination: Equatable {
        let open: Bool
        let immediate: Bool
    }

    private func transitionNote(to destination: NoteDestination) {
        if noteMounted == destination.open, noteExpanded == destination.open,
           noteInkVisible == destination.open, noteSettled == destination.open,
           messageInkVisible == !destination.open { return }
        noteTransitionGeneration &+= 1
        let generation = noteTransitionGeneration
        noteSettled = false
        if destination.immediate {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                noteMounted = destination.open
                noteExpanded = destination.open
                noteInkVisible = destination.open
                noteSettled = destination.open
                messageInkVisible = !destination.open
            }
            return
        }
        if destination.open { noteMounted = true }
        // Retire the current reading surface before moving any geometry. The
        // native text views stay mounted, but neither surface crosses the other.
        withAnimation(.easeOut(duration: 0.10), completionCriteria: .removed) {
            messageInkVisible = false
            noteInkVisible = false
        } completion: {
            guard noteTransitionGeneration == generation else { return }
            // The spring's long removal tail is not reading time. Hand off at
            // its authored arrival, rather than leaving a visibly settled shell empty.
            withAnimation(surfaceAnimation, completionCriteria: .logicallyComplete) {
                noteExpanded = destination.open
            } completion: {
                guard noteTransitionGeneration == generation else { return }
                withAnimation(.easeIn(duration: 0.12), completionCriteria: .removed) {
                    noteInkVisible = destination.open
                    messageInkVisible = !destination.open
                } completion: {
                    guard noteTransitionGeneration == generation else { return }
                    noteSettled = destination.open
                    if !destination.open { noteMounted = false }
                }
            }
        }
    }
    private func capsule(width: CGFloat, room: CGFloat, surface: CGRect, messageWidth: CGFloat, rowHeight: CGFloat,
                         noteHeight: CGFloat, noteAvailableHeight: CGFloat, decorationPadding: CGFloat, settingsSize: CGSize) -> some View {
        let actionLayout = noteActions(width: surface.width)
        let historyBand = noteHistoryBand(width: surface.width)
        let idleWidth = min(NativeMokuCapsuleLayout.idleSize.width, width)
        let idleHeight = NativeMokuCapsuleLayout.idleSize.height
        let composerVisible = inputPresent && state.inputOpen
        let followsEditor = (inputPresent && displayedMessage == nil) || composerSeatHeld
        // Settings always settles the composer expansion at 1 and retires the
        // row above the face, so the seat it lands on is known without reading
        // any animated geometry back. The face keeps its layout seat and is
        // shifted by the difference, which returns to zero as the shell
        // contracts and leaves the face exactly on Moku's row.
        let settledFace = Self.faceSeatCenter(shell: surface.size, rowHeight: rowHeight,
                                              historyBand: historyBand, capsuleWidth: width,
                                              composerFraction: 1, editorBottomInset: editorBottomInset,
                                              followsEditor: false)
        let faceShift = state.settingsExpanded
            ? CGSize(width: NativeSettingsHeaderLayout.faceCenter.x - settledFace.x,
                     height: NativeSettingsHeaderLayout.faceCenter.y - settledFace.y)
            : .zero
        let faceCenter = Self.faceSeatCenter(shell: surface.size, rowHeight: rowHeight,
            historyBand: historyBand, capsuleWidth: width, composerFraction: capsuleFraction,
            editorBottomInset: editorBottomInset, followsEditor: followsEditor)
        let characterInput = NativeMokuCharacterInput(expression: eyeExpression, focus: expanded ? 1 : 0,
            running: runningFeedback, reasoning: reasoningEligible ? incomingReasoning : nil,
            presentsReasoning: reasoningEligible && reasoningReady, executionKey: presentation?.executionKey,
            capsuleSize: CGSize(width: surface.width, height: rowHeight - historyBand), cornerRadius: NativeMokuCapsuleLayout.cornerRadius,
            // Settings covers the Dock but keeps the face on screen in the page's
            // header, so its blink and expression keep their clock.
            motion: scenePhase == .active && state.windowVisible && (!state.dockCovered || state.settingsOpen),
            reduceMotion: reduceMotion, dark: true)
        return Color.clear
        .frame(width: surface.width, height: surface.height)
        .nativeLayoutLog("moku.capsule")
        .overlay(alignment: .bottomLeading) {
            if composerMounted {
                composer(room: room, compact: width < 260)
                .nativeLayoutLog("moku.composer")
                    // Reflow native text once at the destination width. Resolve
                    // the shell's movement outside that discrete layout so its
                    // editor cannot jump to the final scene-space position.
                    .frame(width: width).fixedSize(horizontal: false, vertical: true)
                    .transaction(value: width) { $0.animation = nil }
                    .geometryGroup()
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { capsuleHeight = max(58, $0) }
                    // Let the eyes clear the text seat on expansion; fade prose
                    // quickly before they cross it again during collapse. Scope
                    // this curve to ink so it cannot retime native row placement.
                    .animation(reduceMotion ? nil : (composerVisible
                        ? (state.readingPanelVisible ? NativeReadingPageTiming.openingAnimation : .easeIn(duration: 0.42))
                        : .easeOut(duration: 0.12))) { content in
                        content.opacity(composerVisible ? 1 : 0)
                    }
                    .allowsHitTesting(composerVisible && state.inputInteractionReady)
                    .disabled(state.settingsOpen || !state.inputInteractionReady)
                    .accessibilityHidden(!composerVisible)
            }
        }
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
                        .frame(width: !state.notePanelOpen && !noteMounted && displayedMessage == nil ? surface.width : 46, height: rowHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // Leave selectable message prose and the later control overlays
                // their own hit targets; only the eyes open input beside a message.
                .padding(.leading, !state.notePanelOpen && !noteMounted && displayedMessage == nil ? 0 : max(0, faceCenter.x - 23))
                .accessibilityLabel(localize("打开 Moku 输入框", "Open Moku input"))
                .accessibilityIdentifier("moku-open-input")
            }
        }
        .overlay(alignment: .top) {
            if noteMounted {
                ZStack {
                    NativeMokuNoteContent(note: note, width: width, height: noteHeight, availableHeight: noteAvailableHeight,
                                          routeEligible: state.notePanelOpen && noteSettled && !state.settingsOpen && state.overviewVisible
                                              && !state.dockCovered && !navigationDisabled,
                                          openExternal: openExternal, openExecution: openExecution, workspace: presentation?.workspace,
                                          onContentHeightChange: { noteContentHeight = $0 },
                                          claimOpenArm: { state.claimNoteOpenArm() },
                                          onExposure: { state.recordNoteExposure($0) },
                                          onClose: { state.setNotePanelOpen(false) })
                        // Keep native Markdown layout discrete without cancelling
                        // the surrounding ink transition with this transaction.
                        .transaction { $0.animation = nil }
                }
                .compositingGroup()
                .opacity(noteInkVisible && !state.settingsOpen ? 1 : 0)
                .allowsHitTesting(state.notePanelOpen && noteSettled && !state.settingsOpen)
                .accessibilityHidden(!state.notePanelOpen || !noteSettled || state.settingsOpen)
                .transition(.identity)
            }
        }
        .overlay(alignment: .top) {
            if state.settingsOpen {
                settingsContent
                    .frame(width: settingsSize.width, height: settingsSize.height)
                    .nativeLayoutLog("moku.settings.seat")
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
                Color.clear.frame(width: NativeMokuFaceLayout.seat.width, height: NativeMokuFaceLayout.seat.height)
                if let message = displayedMessage {
                    rowMessage(message, width: messageWidth)
                        .opacity(messageInkVisible && !state.settingsOpen ? 1 : 0)
                        .allowsHitTesting(messageInkVisible && !state.notePanelOpen && !noteMounted && !state.settingsOpen)
                        .accessibilityHidden(!messageInkVisible || state.notePanelOpen || noteMounted || state.settingsOpen)
                }
            }
            .frame(height: followsEditor ? nil : rowHeight - historyBand)
            .padding(.leading, (idleWidth - NativeMokuFaceLayout.seat.width) / 2 * (1 - capsuleFraction) + 15 * capsuleFraction)
            .padding(.bottom, followsEditor
                ? idleHeight / 2 - NativeMokuFaceLayout.seat.height / 2
                    + (editorBottomInset - idleHeight / 2) * capsuleFraction : historyBand)
            .frame(maxWidth: .infinity, alignment: .leading)
            .allowsHitTesting(!state.settingsOpen)
        }
        .overlay(alignment: .topLeading) {
            // One numeric seat travels with the same transaction as the shell.
            // Switching between an intrinsic-height row and a fixed-height row
            // cannot interpolate, and a delayed expansion fraction starts the
            // eyes a layout pass after the glass has already changed size.
            NativeMokuDockIdentity(harness: threadHarness, showsHarness: threadTitle != nil && !state.settingsOpen) {
                face(characterInput)
            }
                .position(x: faceCenter.x + faceShift.width, y: faceCenter.y + faceShift.height)
        }
        .overlay(alignment: .bottomTrailing) {
            NativeMokuNoteActionStack(stacked: noteExpanded && actionLayout.stacked,
                trailing: noteExpanded ? actionLayout.edgeInset : (stopControlPresent ? 7 : 3),
                height: historyBand > 0 ? historyBand : rowHeight) {
                if noteExpanded {
                    NativeMokuNoteHistoryButton(compact: actionLayout.compact) { state.setMokuOpen(true) }
                        .fixedSize()
                        .background {
                            NativeMokuNoteHistoryButton {}.fixedSize().hidden()
                                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { historyActionWidth = $0 }
                                .accessibilityHidden(true).allowsHitTesting(false)
                        }
                        .opacity(noteInkVisible && !state.settingsOpen ? 1 : 0)
                        .allowsHitTesting(state.notePanelOpen && noteSettled && !state.settingsOpen)
                        .accessibilityHidden(!state.notePanelOpen || !noteSettled || state.settingsOpen)
                }
                if stopControlPresent {
                    Button(action: onCancel) {
                        // Keep the Button in accessibility while hiding its ink.
                        RoundedRectangle(cornerRadius: 1).fill(.foreground).frame(width: 10, height: 10)
                            .frame(width: 30, height: 30).contentShape(Circle())
                            .opacity(stopVisible ? 1 : 0)
                            .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: stopVisible)
                    }.buttonStyle(.plain).disabled(disabled)
                        .focused($stopFocused)
                        .accessibilityFocused($stopAccessibilityFocused)
                        .allowsHitTesting(stopVisible)
                        .help(threadTitle == nil ? localize("停止 Moku", "Stop Moku") : localize("停止此 Thread", "Stop this thread"))
                        .accessibilityLabel(threadTitle == nil ? localize("停止 Moku", "Stop Moku") : localize("停止此 Thread", "Stop this thread"))
                        .accessibilityIdentifier("moku-stop")
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("native-moku-dock")) } action: { stopControlsFrame = $0 }
                } else if voiceControlVisible && (!inputPresent || voiceModeActive) {
                    voiceControls.fixedSize(horizontal: true, vertical: true)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("native-moku-dock")) } action: { voiceControlsFrame = $0; voiceActionWidth = $0.width }
                        .transition(.opacity)
                }
            }
        }
        .animation(surfaceAnimation, value: voiceControlVisible && (!inputPresent || voiceModeActive))
        .background {
            ZStack {
                NativeMokuCapsuleGlass(regular: noteExpanded).opacity(state.settingsExpanded ? 0 : 1)
                if state.settingsOpen {
                    NativeSettingsPanelGlass().opacity(state.settingsExpanded ? 1 : 0)
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
        .animation(surfaceAnimation, value: surface)
        .nativeCanvasNavigationRegion()
        // In detail, only Dock focus may use this close route. A window-sized
        // fallback would race the reader's nested history/Sidecard cancellation.
        .nativeReadingEscape(perform: state.inputPinnedOpen && state.inputOpen && state.dockContentVisible && interaction == nil ? {
            escapeInput()
        } : nil)
        .accessibilityElement(children: .contain).accessibilityLabel(state.settingsOpen ? localize("设置", "Settings") : "Moku")
        .accessibilityHint(state.settingsOpen ? "" : localize("点击打开输入框，鼠标悬停时在触控板上向上滑动打开笔记", "Click to type; while hovering, swipe up on the trackpad for notes"))
        .accessibilityValue(state.noteUnread(note) ? localize("笔记有尚未完整浏览的更新", "Note update not yet fully browsed") : "")
        .accessibilityIdentifier("moku-capsule")
    }
    private func restoreVoiceComposer() {
        // A voice lifecycle change can arrive while Settings owns the capsule.
        // Defer the restoration receipt as well as the UI change until release.
        guard !state.settingsOpen, state.dockRouteVisible,
              let open = voiceComposerRestoration.update(active: voiceModeActive, inputOpen: state.inputOpen) else { return }
        if !open { state.retainDraft(draft) }
        state.setInputOpen(open && interaction == nil)
    }

    private func dispatchHarness(_ dispatch: NativeMokuDispatch) -> AnyHarnessPlugin? {
        try? presentation?.workspace.plugins.harnesses.require(dispatch.harnessID)
    }
    private func escapeInput() {
        guard state.ownsComposer(draft) else { return }
        if state.inputPinnedOpen {
            // Editor key handling arrives after IME/completion, but AppKit can
            // still address an anchor while a native transient owns Escape.
            guard let window = NSApp.currentEvent?.window ?? NSApp.keyWindow,
                  window.attachedSheet == nil, NSApp.modalWindow == nil,
                  !(window.childWindows ?? []).contains(where: { $0.isVisible }) else { return }
            if directoryMentions.dismiss() { return }
            if let sidecardComposer { sidecardComposer.cancel() }
            else { onThreadClose?() }
        }
        else { _ = state.dismissInputForEscape() }
    }
    private func composer(room: CGFloat, compact: Bool) -> some View {
        NativeMokuComposerInput(draft: draft, cwd: cwd, disabled: disabled || (submitting && sidecardComposer == nil),
            busy: submitting && sidecardComposer != nil,
            threadTitle: threadTitle, sidecardComposer: sidecardComposer,
            readOnly: state.inputLeaving, focusEnabled: state.inputInteractionReady && state.dockRouteVisible && state.inputOpen && !state.dockCovered && focusReady && (sidecardComposer?.ready ?? true),
            focusRequestKey: focusRequest, maxHeight: min(landing ? 156 : 126, room), landing: landing, compact: compact,
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
                guard state.ownsComposer(draft) else { return }
                if state.inputOpen, !editor.composing { state.retainSelection(editor.selection) }
                directoryMentions.update(editor)
            },
            onKeyDown: { state.ownsComposer(draft) && directoryMentions.handle($0, draft: draft) },
            onEditorSeatChange: {
                // The retiring editor remains mounted inside a shrinking capsule.
                // Its new anchor would redirect the eyes mid-collapse; keep the
                // last open seat until live editing resumes.
                if state.ownsComposer(draft), state.inputOpen { editorBottomInset = $0 }
            },
            onEscape: escapeInput, onSend: send)
            .id(ObjectIdentifier(draft))
    }

    private func send() {
        guard state.ownsComposer(draft), !state.settingsOpen, !submitting, !disabled, state.inputOpen, draft.canSubmit else { return }
        guard sidecardComposer?.ready ?? true else { return }
        state.retainDraft(draft, seal: !state.inputPinnedOpen)
        if threadTitle == nil { state.dismissTalk() }
        let sendingDraft = draft, send = onSend, generation = state.composerGeneration
        submissionDraft = sendingDraft
        state.setInputOpen(false)
        Task {
            // Capture both the draft and route before yielding. A late receipt
            // consumes only this draft and cannot reopen a replacement visit.
            await sendingDraft.submit(send)
            if submissionDraft === sendingDraft { submissionDraft = nil }
            if state.composerGeneration == generation, sendingDraft.error != nil, !state.mokuOpen {
                state.setInputOpen(true)
            }
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
