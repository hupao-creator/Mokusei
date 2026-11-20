import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import SwiftUI

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
    // Preserve the message seat when a Stop control retires.
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

/// The editor uses its final layout throughout the morph. Reveal it in the
/// last part of the shell's own travel, once the identity has cleared the row.
private struct ComposerInk: ViewModifier, @preconcurrency Animatable {
    var expansion: CGFloat
    let autofocusGeneration: UUID?
    let requestFocus: (UUID) -> Void

    var animatableData: CGFloat {
        get { expansion }
        set { expansion = newValue }
    }
    func body(content: Content) -> some View {
        let opacity = min(1, max(0, (expansion - 0.9) / 0.1))
        content.opacity(opacity)
            .onChange(of: opacity >= 0.1 ? autofocusGeneration : nil, initial: true) { _, generation in
                if let generation { requestFocus(generation) }
            }
    }
}

/// One glass capsule. Production composer, transcript and interaction ownership stay in the scene.
/// Moku history shares its draft; Agent detail supplies its own Thread draft.
public struct NativeMokuDock: View {
    public let state: NativeMokuSceneState
    public let draft: NativeComposerDraft
    public let cwd: JSONText
    public var threadID: JSONText?
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
    public var onSend: (NativeComposerSubmission) async throws -> Void
    public var onSendConsumed: (NativeComposerSubmission) async -> Void
    public var awaitingContinuation: Bool
    public var onCancel: () -> Void
    public var presentation: NativeMokuWorkspacePresentation?
    public var note: NativeMokuNote?
    public var openExternal: ((URL) -> Void)?
    public var openExecution: ((ApplicationExecutionRef) -> Void)?
    public var loadMentionDirectories: (() async throws -> [NativeComposerDirectory])?
    @Environment(\.nativeMokuSettingsContent) private var settingsContent
    @Environment(\.colorScheme) private var workspaceColorScheme
    @Environment(\.locale) private var locale
    @Environment(\.nativeOfflineDraftEditing) private var offlineDraftEditing
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.nativeExecutionDockPlacement) private var executionPlacement
    @State private var hovered = false
    @State private var hoverTask: Task<Void, Never>?
    @FocusState private var stopFocused: Bool
    @AccessibilityFocusState private var stopAccessibilityFocused: Bool
    @State private var capsuleHeight: CGFloat = 58
    @State private var completionHeight: CGFloat = 0
    @State private var focusGeneration: UUID?
    @State private var explicitFocusGeneration: UUID?
    @State private var focusRequest = 0
    @State private var directoryMentions = NativeMokuDirectoryMentions()
    @State private var editorBottomInset: CGFloat = 29
    // Keep the note's real scroll view at its reading dimensions while the
    // same Dock lends its visible shell to the linked Thread's composer.
    @State private var linkedNoteLayout: (width: CGFloat, height: CGFloat, available: CGFloat)?
    @State private var noteContentHeight: CGFloat = 0
    @State private var noteMounted = false
    @State private var noteExpanded = false
    @State private var noteInkVisible = false
    @State private var noteSettled = false
    @State private var messageInkVisible = true
    @State private var noteTransitionGeneration = 0
    @State private var settingsPreferredHeight: CGFloat = 900
    @State private var settingsHeaderScroll: CGFloat = 0
    @State private var historyActionWidth: CGFloat = 110
    @State private var stopControlsFrame = CGRect.zero
    @State private var composerStopInset = CGPoint(x: 61, y: 29)
    @State private var talkScrollbarStyle = NSScroller.preferredScrollerStyle
    @State private var character = NativeMokuCharacterMotion()
    @State private var reasoningRequested = false
    @State private var reasoningSeatReserved = false
    @State private var reasoningReady = false
    @State private var reasoningTransition = 0
    @State private var retainedReasoningGlyphs: [MokuReasoningGlyph] = []

    public init(state: NativeMokuSceneState, draft: NativeComposerDraft, cwd: JSONText,
                landing: Bool = false, threadID: JSONText? = nil,
                threadHarness: AnyHarnessPlugin? = nil, onThreadClose: (() -> Void)? = nil,
                sidecardComposer: SidecardComposerRequest? = nil,
                awaitingContinuation: Bool = false,
                mode: MokuCharacterMode = .idle, running: Bool = false, reasoning: MokuReasoningContent? = nil,
                talk: String? = nil,
                reply: NativeMokuDockReply? = nil, disabled: Bool = false,
                interaction: AnyView? = nil, interactionIsQuestion: Bool = false,
                presentation: NativeMokuWorkspacePresentation? = nil,
                note: NativeMokuNote? = nil,
                openExternal: ((URL) -> Void)? = nil,
                openExecution: ((ApplicationExecutionRef) -> Void)? = nil,
                loadMentionDirectories: (() async throws -> [NativeComposerDirectory])? = nil,
                onSend: @escaping (NativeComposerSubmission) async throws -> Void,
                onSendConsumed: @escaping (NativeComposerSubmission) async -> Void = { _ in },
                onCancel: @escaping () -> Void) {
        self.state = state; self.draft = draft; self.cwd = cwd; self.mode = mode; self.running = running
        self.awaitingContinuation = awaitingContinuation
        self.reasoning = reasoning
        self.landing = landing
        self.threadID = threadID
        self.threadHarness = threadHarness; self.onThreadClose = onThreadClose
        self.sidecardComposer = sidecardComposer
        self.talk = talk; self.reply = reply; self.disabled = disabled; self.interaction = interaction
        self.interactionIsQuestion = interactionIsQuestion
        self.onSend = onSend; self.onSendConsumed = onSendConsumed; self.onCancel = onCancel
        self.presentation = presentation
        self.note = note; self.openExternal = openExternal; self.openExecution = openExecution
        self.loadMentionDirectories = loadMentionDirectories
    }
    private var retaining: Bool { state.inputLeaving || state.capsuleSealed }
    private var retiringInputSeat: Bool {
        state.inputLeaving && !(reduceMotion && ordinaryOverviewDock)
    }
    private var inputPresent: Bool {
        !state.settingsOpen && !state.notePanelOpen && (state.inputOpen || retiringInputSeat) && interaction == nil
            && (state.inputOpen || displayedMessage == nil)
    }
    /// Settings retires the composer the moment it opens, but the face should
    /// leave from the composer seat it occupied. Holding that seat until the
    /// shell starts growing keeps the eyes from twitching down to the idle row
    /// before they travel to the panel.
    private var composerSeatHeld: Bool {
        state.settingsOpen && !state.settingsExpanded && !state.notePanelOpen
            && (state.inputOpen || state.inputLeaving) && interaction == nil
    }
    private var composerMounted: Bool {
        state.dockRouteVisible && !state.notePanelOpen && (state.inputOpen || state.inputLeaving) && interaction == nil
    }
    private var incomingTalk: NativeMokuTalkMessage? {
        if let presentation { return presentation.talkMessage }
        guard let talk, !talk.isEmpty else { return nil }
        return NativeMokuTalkMessage(id: JSONText(talk), text: talk)
    }
    private var visibleTalk: NativeMokuTalkMessage? {
        guard threadID == nil, !state.inputOpen, interaction == nil, !state.dockCovered, state.dockRouteVisible,
              state.windowVisible, !disabled, !draft.submitting else { return nil }
        return state.talkPresentation.message
    }

    private var navigationDisabled: Bool { disabled && !offlineDraftEditing }
    private var landingInputAvailable: Bool {
        landing && state.overviewVisible && !state.dockCovered && !state.notePanelOpen
            && interaction == nil && !navigationDisabled
    }
    private var rowControlAvailable: Bool {
        state.inputInteractionReady && state.dockRouteVisible && state.windowVisible && !state.dockCovered && !navigationDisabled
            && interaction == nil && !state.inputOpen && !retiringInputSeat
    }

    private var displayedMessage: NativeMokuTalkMessage? { visibleTalk }
    private var foregroundTalkID: JSONText? {
        return visibleTalk?.id
    }
    private var continuationPresenting: Bool {
        threadID != nil && sidecardComposer == nil && (awaitingContinuation || executionPlacement?.continuing == true)
    }
    // The outgoing draft stays open until route release. Its shell starts
    // folding when the reading panel withdraws input, alongside its ink.
    private var rowExpanded: Bool {
        (state.inputOpen && state.inputInteractionReady) || continuationPresenting || displayedMessage != nil
    }
    private var expanded: Bool { state.settingsExpanded || noteExpanded || rowExpanded }
    private var capsuleFraction: CGFloat { expanded ? 1 : 0 }
    // The native replay supplies a sampling clock only for admitted reading input.
    var readingInputAnimation: Animation?
    private var settlingNoteDock: Bool {
        linkedNoteLayout != nil && (state.notePanelOpen || !state.inputInteractionReady)
    }
    private var directNoteReading: Bool { reduceMotion && state.noteReadingOrigin != nil }
    private var surfaceAnimation: Animation? {
        if directNoteReading || settlingNoteDock { return nil }
        guard state.readingPanelVisible else { return .smooth(duration: 0.42, extraBounce: 0) }
        if state.inputOpen && !rowExpanded { return .easeOut(duration: NativeReadingPageTiming.duration) }
        if let readingInputAnimation, state.inputOpen, state.inputInteractionReady { return readingInputAnimation }
        return NativeReadingPageTiming.openingAnimation
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
    /// the shift returns to zero as the shell contracts.
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
            NativeMokuDispatchContent(dispatch: dispatch, harness: dispatchHarness(dispatch))
                .frame(width: max(1, width - NativeMokuTalkTypography.leading - 48), height: 32)
        } else {
            // The legacy scroller occupies the trailing gutter; extend its
            // viewport so the remaining text clip stays centered in the shell.
            NativeMokuTalkContent(message: message, scrollbarStyle: talkScrollbarStyle)
                .accessibilityIdentifier("moku-talk-content")
                .frame(width: max(1, width - NativeMokuTalkTypography.centeredInset * 2
                    + NativeMokuTalkTypography.scrollbarGutter(for: talkScrollbarStyle)),
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
                .transition(.opacity.animation(.easeInOut(duration: 0.22)))
        }
    }
    /// Note swipes belong to the original control row, outside selectable prose.
    private var controlRowFrame: CGRect {
        let surface = state.capsuleFrame
        let height = noteExpanded
            ? min(surface.height, NativeMokuCapsuleLayout.idleSize.height)
            : surface.height
        return CGRect(x: surface.minX, y: surface.maxY - noteHistoryBand(width: surface.width) - height, width: surface.width, height: height)
    }
    private var ordinaryOverviewDock: Bool {
        state.overviewVisible && !state.readingPanelVisible && !landing && threadID == nil && sidecardComposer == nil
            && !state.dockCovered && !state.settingsOpen && !state.notePanelOpen && !noteMounted
            && state.noteReadingOrigin == nil && interaction == nil && displayedMessage == nil
    }
    private var stopControlPresent: Bool {
        running && (ordinaryOverviewDock || !inputPresent) && !state.settingsOpen
    }
    private func noteActions(width: CGFloat) -> NativeMokuNoteActionLayout {
        NativeMokuNoteActionLayout(width: width, historyWidth: historyActionWidth,
            controlWidth: stopControlPresent ? 30 : 0,
            hasMessage: !noteExpanded && displayedMessage != nil, isDispatch: !noteExpanded && displayedMessage?.dispatch != nil)
    }
    private func noteHistoryBand(width: CGFloat) -> CGFloat {
        noteExpanded ? noteActions(width: width).band : 0
    }
    private var stopVisible: Bool {
        (ordinaryOverviewDock && composerVisible) || hovered || stopFocused || stopAccessibilityFocused
    }
    // Talk keeps its ordinary control inset while covered, preserving wrapping
    // and scroll position without reserving a second message row inside Note.
    private func surfaceHeight(width: CGFloat) -> CGFloat {
        guard let message = displayedMessage else {
            return max(landing ? 76 : 58, capsuleHeight) + (completionVisible ? completionHeight : 0)
        }
        if message.dispatch != nil { return landing ? 76 : 58 }
        let maximumHeight = NativeMokuTalkTypography.maximumHeight
        return max(landing ? 76 : 58, NativeMokuTalkTypography.capsuleHeight(message.text, width: width,
            leadingInset: NativeMokuTalkTypography.centeredInset,
            trailingInset: NativeMokuTalkTypography.centeredInset - NativeMokuTalkTypography.scrollbarGutter(for: talkScrollbarStyle),
            maximumHeight: maximumHeight, scrollbarStyle: talkScrollbarStyle))
    }
    private var residentPresenting: Bool {
        threadID == nil && !state.dockCovered && state.dockRouteVisible && state.windowVisible && !state.inputOpen &&
        !draft.submitting && interaction == nil && displayedMessage == nil
    }
    // The workspace retains the selected Agent while its reader returns to
    // Overview. Input is already closed to interaction during that motion.
    private var composerVisible: Bool { inputPresent && state.inputOpen && state.inputInteractionReady }
    private var composerCanFocus: Bool {
        state.inputInteractionReady && state.dockRouteVisible && state.inputOpen && !state.dockCovered
    }
    private var autofocusGeneration: UUID? {
        guard inputPresent, composerCanFocus,
              state.composerAutofocus || explicitFocusGeneration == state.composerGeneration else { return nil }
        return state.composerGeneration
    }
    private var agentMentions: NativeMokuDirectoryMentions? {
        guard threadID != nil, sidecardComposer == nil, loadMentionDirectories != nil else { return nil }
        return directoryMentions
    }
    private var completionVisible: Bool { composerVisible && !retaining && agentMentions?.isOpen == true }
    private var mentionsEnabled: Bool {
        agentMentions != nil && state.dockRouteVisible && state.inputOpen && !disabled && !state.dockCovered && state.windowVisible && interaction == nil
    }
    private var reminder: NativeMokuDockReply? {
        guard let reply, !state.readReplies.contains(JSONText(reply.readKey)),
              (presentation?.sessionIdle ?? !running), mode == .idle,
              !state.inputOpen, interaction == nil, !state.dockCovered else { return nil }
        return reply
    }
    private var inputSuppressesRunningFeedback: Bool {
        // Agent detail owns its persistent editor during travel and the Harness
        // flip, before inputOpen can become true. That wait is not a closed input.
        state.inputOpen || state.inputPinnedOpen
    }
    private var runningFeedback: Bool {
        guard !inputSuppressesRunningFeedback, !state.settingsOpen, !state.notePanelOpen, !noteMounted, interaction == nil,
              presentation?.workspace.runtimeAvailable ?? true else { return false }
        if threadID != nil, sidecardComposer == nil {
            // Submission is pending feedback only. It grants neither success,
            // Stop authority nor permission to consume the captured draft.
            // Closing input admits feedback immediately, even while the
            // retiring editor remains mounted. Open input owns its own controls.
            return (draft.submitting && draft.error == nil) || continuationPresenting || (!disabled && running && draft.error == nil)
        }
        return running && (mode == .running || incomingReasoning != nil)
            && !expanded && !state.notePanelOpen && !noteMounted && !inputPresent && interaction == nil
            && !disabled && (presentation?.workspace.runtimeAvailable ?? true)
    }
    private var incomingReasoning: MokuReasoningContent? {
        guard threadID == nil, running else { return nil }
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
        if draft.submitting || running { return .deliberating }
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
            let restingFrame = NativeMokuCapsuleLayout.frame(in: dockViewport, landing: landing)
            let readingOffset = baseFrame.maxY - restingFrame.maxY
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
                verticalOffset: readingOffset,
                frame: executionFrame, revision: executionPlacement?.travelRevision ?? 0, viewport: geometry.size,
                dragging: executionPlacement?.dragging == true, inactive: scenePhase != .active || directNoteReading || settlingNoteDock,
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
                    .offset(y: placement.surface.maxY - geometry.size.height - readingOffset)
                    // A column change must drive shell width on the same curve
                    // as native travel, before it can reach the narrower seat.
                    .animation(directNoteReading || executionPlacement?.dragging == true ? nil
                        : NativeSidecardTiming.foldAnimation, value: executionFrame)
                    .animation(surfaceAnimation, value: placement)
                    // Keep the small reading-seat descent out of SwiftUI layout
                    // animation too: reader preparation must not stall its frames.
                    .geometryGroup()
                    .offset(y: destination.verticalOffset)
                    .animation(nil, value: destination.verticalOffset)
                    // The panel owns this handoff. In particular, a shrinking
                    // composer must not leave an additive width animation on
                    // the restored Note when Reduce Motion cuts to its frame.
                    .transaction(value: state.noteReadingOrigin?.phase == .reading) {
                        $0.animation = nil; $0.disablesAnimations = true
                    }
                    .transaction(value: state.inputOpen) {
                        if reduceMotion && ordinaryOverviewDock {
                            $0.animation = nil; $0.disablesAnimations = true
                        }
                    }
                    .transaction {
                        if directNoteReading || (reduceMotion && settlingNoteDock) {
                            $0.animation = nil; $0.disablesAnimations = true
                        }
                    }
                    // Direct resize settles the native trip and shell together.
                    .transaction(value: geometry.size) {
                        $0.animation = nil; $0.disablesAnimations = true
                    }
                if let interaction, !state.settingsOpen {
                    interaction.padding(18)
                        .frame(width: panel.width, height: panel.height, alignment: .topLeading)
                        .nativeCanvasNavigationRegion()
                        .background { NativeMokuCapsuleGlass(interactive: false) }
                        .environment(\.colorScheme, .dark)
                        .position(x: panel.midX - destination.offset, y: panel.midY)
                }
            }
            .coordinateSpace(name: "native-moku-dock")
            .overlay(alignment: .topLeading) {
                // Local event monitors need an attached origin, not a hit area.
                interactionMonitors(horizontalOffset: destination.offset).frame(width: 0, height: 0)
            }
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
            .onPreferenceChange(NativeSettingsPreferredHeightKey.self) { height in
                settingsPreferredHeight = max(900, ceil(height))
            }
            .onPreferenceChange(NativeSettingsHeaderScrollKey.self) { offset in
                settingsHeaderScroll = offset
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
                else if !visible, threadID != nil, !state.dockCovered { state.setInputOpen(true) }
            }
            .onChange(of: interactionIsQuestion) { _, value in
                state.setDockInteractionVisible(state.dockRouteVisible && interaction != nil, question: value)
            }
        }
        .nativeReadingEscape(perform: !state.inputPinnedOpen && state.inputOpen && state.dockContentVisible && interaction == nil ? {
            escapeInput()
        } : nil)
        .onChange(of: landing, initial: true) { _, active in
            guard state.updateLanding(active) else { return }
            if active {
                if landingInputAvailable && !running && incomingTalk == nil { state.setInputOpen(true) }
            } else if threadID == nil {
                state.retainDraft(draft)
                state.setInputOpen(false)
            }
        }
        .onChange(of: state.inputOpen, initial: true) { _, open in
            if open { state.retainDraft(draft) }
        }
        .onChange(of: ObjectIdentifier(draft)) { _, _ in
            directoryMentions = NativeMokuDirectoryMentions()
        }
        .onChange(of: state.settingsOpen) { _, open in
            if open { state.retainDraft(draft) }
            else {
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
            state.dockCharacter = character
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
                if !hadInk {
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
        .onChange(of: TalkPresentation(id: foregroundTalkID, noteCovering: state.notePanelOpen || noteMounted), initial: true) { _, value in
            // Covering a Talk with Note is a reversible reading visit. Calling
            // setPresented(false) here would consume the notification. Existing
            // deadlines keep running; newly received Talk waits for actual return.
            if !value.noteCovering { state.setTalkPresented(value.id != nil) }
        }
        .onChange(of: NoteDestination(open: state.notePanelOpen, readingLink: state.noteReadingOrigin != nil,
            dismissingLink: state.noteReadingOrigin?.phase == .dismissing ? state.noteReadingOrigin?.id : nil,
            immediate: scenePhase != .active || !state.windowVisible || !state.dockRouteVisible
                || state.dockCovered || state.inputOpen || interaction != nil
                || directNoteReading), initial: true) { previous, destination in
            transitionNote(to: destination, returningFromLink: previous.readingLink && destination.open)
            if !destination.readingLink { linkedNoteLayout = nil }
        }
        .onDisappear {
            noteTransitionGeneration &+= 1
            state.cancelPendingNoteReading()
        }
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
            state.dockHitRects = []
            state.dockMentionHitRect = nil
            hoverTask?.cancel(); hoverTask = nil
        }
        .onChange(of: composerCanFocus) { _, available in
            if !available { focusGeneration = nil }
        }
        .onChange(of: state.composerFocusRequest) { _, _ in
            guard state.inputOpen, state.dockRouteVisible, !state.dockCovered else { return }
            explicitFocusGeneration = state.composerGeneration
            focusGeneration = state.composerGeneration
            focusRequest += 1
        }
        .onChange(of: draft.text) { _, _ in if state.dockRouteVisible && state.inputOpen { state.retainDraft(draft) } }
        .onChange(of: draft.attachments) { _, _ in if state.dockRouteVisible && state.inputOpen { state.retainDraft(draft) } }
        .onChange(of: sidecardComposer?.ready) { _, ready in
            if ready == true { focusRequest += 1 }
        }
        .onChange(of: draft.submitting) { _, busy in
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
            if state.dockCharacter === character { state.dockCharacter = nil }
            character.cancelOnboardingBlink()
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
            focusGeneration = nil
        }
        .task(id: "\(state.composerGeneration):\(mentionsEnabled)") {
            await directoryMentions.load(enabled: mentionsEnabled, using: loadMentionDirectories)
        }
        // Keep the override local: a preferredColorScheme would also recolor
        // the containing workspace window and its other application surfaces.
        .environment(\.colorScheme, .dark)
    }

    private func interactionMonitors(horizontalOffset: CGFloat) -> some View {
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
                    NativeMokuOutsideClick.isInside(point: CGPoint(x: point.x + horizontalOffset, y: point.y),
                        dockRects: state.dockHitRects)
                        || state.dockMentionHitRect?.contains(point) == true
                },
                click: { _ in
                    if state.notePanelOpen { state.setNotePanelOpen(false) }
                    else if state.inputPinnedOpen, agentMentions?.dismiss() == true {
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
                    let row = controlRowFrame.offsetBy(dx: -horizontalOffset, dy: 0)
                    return NativeMokuSwipeTarget.contains(point, row: row,
                        eyesOnly: displayedMessage?.dispatch != nil,
                        excluding: (stopControlPresent ? [stopControlsFrame] : []))
                },
                openNote: { state.openNotePanelFromUser() })
        }
        .allowsHitTesting(false)
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
        let readingLink: Bool
        let dismissingLink: UUID?
        let immediate: Bool
    }

    private func transitionNote(to destination: NoteDestination, returningFromLink: Bool) {
        let keepMounted = destination.open || destination.readingLink
        if noteMounted == keepMounted, noteExpanded == destination.open,
           noteInkVisible == destination.open, noteSettled == destination.open,
           messageInkVisible == !destination.open { return }
        noteTransitionGeneration &+= 1
        let generation = noteTransitionGeneration
        noteSettled = false
        if destination.immediate || (destination.readingLink && destination.dismissingLink == nil) || returningFromLink {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                noteMounted = keepMounted
                noteExpanded = destination.open
                noteInkVisible = destination.open
                noteSettled = destination.open
                messageInkVisible = !destination.open
            }
            state.finishLinkedNoteDismissal(destination.dismissingLink)
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
                    noteMounted = keepMounted
                    state.finishLinkedNoteDismissal(destination.dismissingLink)
                }
            }
        }
    }
    private func capsule(width: CGFloat, room: CGFloat, surface: CGRect, messageWidth: CGFloat, rowHeight: CGFloat,
                         noteHeight: CGFloat, noteAvailableHeight: CGFloat, decorationPadding: CGFloat, settingsSize: CGSize) -> some View {
        let actionLayout = noteActions(width: surface.width)
        let historyBand = noteHistoryBand(width: surface.width)
        let composerStop = ordinaryOverviewDock && composerVisible
        let actionTrailing = noteExpanded ? actionLayout.edgeInset : (stopControlPresent ? 7 : 3)
        let actionHeight = historyBand > 0 ? historyBand : rowHeight
        let retiringOverviewInk = ordinaryOverviewDock && inputPresent && state.inputLeaving && state.inputInteractionReady
        let followsEditor = (inputPresent && displayedMessage == nil) || composerSeatHeld || continuationPresenting
        // Settings always settles the composer expansion at 1 and retires the
        // row above the face, so the seat it lands on is known without reading
        // any animated geometry back. The face keeps its layout seat and is
        // shifted by the difference, which returns to zero as the shell
        // contracts and leaves the face exactly on Moku's row.
        let settledFace = Self.faceSeatCenter(shell: surface.size, rowHeight: rowHeight,
                                              historyBand: historyBand, capsuleWidth: width,
                                              composerFraction: 1, editorBottomInset: editorBottomInset,
                                              followsEditor: false)
        // At extreme zoom the header scrolls inside the shell.
        let faceShift = state.settingsExpanded
            ? CGSize(width: NativeSettingsHeaderLayout.faceCenter.x - settledFace.x,
                     height: NativeSettingsHeaderLayout.faceCenter.y - settledFace.y - settingsHeaderScroll)
            : .zero
        let faceCenter = Self.faceSeatCenter(shell: surface.size, rowHeight: rowHeight,
            historyBand: historyBand, capsuleWidth: width, composerFraction: capsuleFraction,
            editorBottomInset: editorBottomInset, followsEditor: followsEditor)
        let characterInput = NativeMokuCharacterInput(expression: eyeExpression, focus: expanded ? 1 : 0,
            running: runningFeedback, reasoning: reasoningEligible ? incomingReasoning : nil,
            presentsReasoning: reasoningEligible && reasoningReady, executionKey: threadID?.string ?? presentation?.executionKey,
            capsuleSize: CGSize(width: surface.width, height: rowHeight - historyBand), cornerRadius: NativeMokuCapsuleLayout.cornerRadius,
            // Settings covers the Dock but keeps the face on screen in the page's
            // header, so its blink and expression keep their clock.
            motion: scenePhase == .active && state.windowVisible && (!state.dockCovered || state.settingsOpen),
            reduceMotion: reduceMotion, dark: !state.settingsExpanded || workspaceColorScheme == .dark, immediateOrbit: threadID != nil)
        return Color.clear
        .frame(width: surface.width, height: surface.height)
        .overlay(alignment: .bottom) {
            ZStack {
                if composerMounted {
                    composer(room: room, compact: width < 260)
                        // Reflow native text once at the destination width. Resolve
                        // the shell's movement outside that discrete layout so its
                        // editor cannot jump to the final scene-space position.
                        .frame(width: width).fixedSize(horizontal: false, vertical: true)
                        .transaction(value: width) { $0.animation = nil }
                        .geometryGroup()
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { capsuleHeight = max(58, $0) }
                        .animation(nil) { $0.opacity(composerVisible || retiringOverviewInk ? 1 : 0) }
                        .allowsHitTesting(composerVisible)
                        .disabled(state.settingsOpen || !state.inputInteractionReady)
                        .accessibilityHidden(!composerVisible)
                        // A route can replace the draft or unmount the entire row
                        // before it receives the hidden state. An implicit removal
                        // fade would keep the outgoing text in the shrinking shell.
                        .id(ObjectIdentifier(draft))
                        .transition(.identity)
                }
            }
            // Keep the overlay's footprint through the empty-to-mounted change.
            // An intrinsic size starting at zero also animates the text origin.
            .frame(width: width, height: capsuleHeight, alignment: .bottom)
            .geometryGroup()
            .modifier(ComposerInk(expansion: capsuleFraction, autofocusGeneration: autofocusGeneration) { generation in
                guard autofocusGeneration == generation, state.ownsComposer(draft),
                      focusGeneration != generation else { return }
                focusGeneration = generation
                focusRequest += 1
            })
        }
        .onChange(of: completionVisible) { _, visible in
            if !visible { state.dockMentionHitRect = nil }
        }
        .overlay(alignment: .top) {
            if completionVisible, let agentMentions {
                NativeMokuComposerCompletion(mentions: agentMentions, draft: draft,
                    maxHeight: max(0, room - capsuleHeight - 12),
                    onFrame: { state.dockMentionHitRect = completionVisible ? $0 : nil })
                    .disabled((disabled && !offlineDraftEditing) || draft.clearing || draft.isDisposed)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { completionHeight = $0 }
                    // Resolve the menu's target height once. The shell animates;
                    // the editor and its persistent face share the bottom edge.
                    .transaction { $0.animation = nil }
                    .transition(.asymmetric(insertion: .opacity, removal: .identity))
            }
        }
        .overlay(alignment: .bottomLeading) {
            if rowControlAvailable && !inputPresent {
                Button { state.setInputOpen(true) } label: {
                    Color.clear
                        .frame(width: !state.notePanelOpen && !noteMounted && displayedMessage == nil ? surface.width : 46, height: rowHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // Leave selectable message prose and the later control overlays
                // their own hit targets; only the eyes open input beside a message.
                .padding(.leading, !state.notePanelOpen && !noteMounted && displayedMessage == nil ? 0 : max(0, faceCenter.x - 23))
                .accessibilityLabel(localize("打开 Chief 输入框", "Open Chief input"))
                .accessibilityIdentifier("moku-open-input")
            }
        }
        .overlay(alignment: .top) {
            if noteMounted {
                let held = linkedNoteLayout
                ZStack {
                    NativeMokuNoteContent(note: note, width: held?.width ?? width, height: held?.height ?? noteHeight,
                                          availableHeight: held?.available ?? noteAvailableHeight,
                                          routeEligible: state.notePanelOpen && noteSettled && !state.settingsOpen && state.overviewVisible
                                              && !state.dockCovered && !navigationDisabled,
                                          openExternal: openExternal, openExecution: { reference in
                                              guard noteSettled, state.notePanelOpen, !state.dockCovered else { return }
                                              openExecution?(reference)
                                              if state.noteReadingOrigin != nil {
                                                  linkedNoteLayout = (width, noteHeight, noteAvailableHeight)
                                              }
                                          }, workspace: presentation?.workspace,
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
                    .environment(\.colorScheme, workspaceColorScheme)
                    .frame(width: settingsSize.width, height: settingsSize.height)
                    // Settle the page layout during the capsule morph without
                    // suppressing animations initiated later by its children.
                    .transaction(value: state.settingsExpanded) { $0.animation = nil }
                    .compositingGroup()
                    .opacity(state.settingsExpanded ? 1 : 0)
                    .animation(.easeOut(duration: state.settingsClosing ? 0.12 : 0.22), value: state.settingsExpanded)
                    // Resolve placement with the shell's animation, outside both
                    // the faster ink fade and the page's discrete layout. Without
                    // this boundary the page jumps to the collapsed Dock's origin.
                    .geometryGroup()
                    .disabled(state.settingsClosing)
                    .allowsHitTesting(!state.settingsClosing)
                    .accessibilityHidden(state.settingsClosing)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let message = displayedMessage {
                rowMessage(message, width: messageWidth)
                    .opacity(messageInkVisible && !state.settingsOpen ? 1 : 0)
                    .allowsHitTesting(messageInkVisible && !state.notePanelOpen && !noteMounted && !state.settingsOpen)
                    .accessibilityHidden(!messageInkVisible || state.notePanelOpen || noteMounted || state.settingsOpen)
                    .frame(height: rowHeight - historyBand)
                    .padding(.leading, message.dispatch == nil ? NativeMokuTalkTypography.centeredInset : NativeMokuTalkTypography.leading)
                    .padding(.bottom, historyBand)
            }
        }
        .overlay(alignment: .topLeading) {
            // One numeric seat travels with the same transaction as the shell.
            // Switching between an intrinsic-height row and a fixed-height row
            // cannot interpolate, and a delayed expansion fraction starts the
            // eyes a layout pass after the glass has already changed size.
            let generation = state.composerGeneration
            NativeMokuDockIdentity(harness: threadHarness,
                showsHarness: threadID != nil && !state.settingsOpen,
                entranceReady: state.inputAdmissionReady,
                generation: generation, motion: state.windowVisible && !directNoteReading,
                onSettled: { state.completeInputIdentity(generation: generation) }) {
                face(characterInput)
            }
                .position(x: faceCenter.x + faceShift.width, y: faceCenter.y + faceShift.height)
        }
        .overlay(alignment: .bottomTrailing) {
            NativeMokuNoteActionStack(stacked: noteExpanded && actionLayout.stacked,
                trailing: composerStop ? composerStopInset.x - 16 : actionTrailing,
                height: composerStop ? 2 * composerStopInset.y : actionHeight) {
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
                            // The hover fade owns only ink. The moving button's
                            // position and hit seat follow the shell's transaction.
                            .animation(ordinaryOverviewDock && reduceMotion ? nil : .easeInOut(duration: 0.12)) {
                                $0.opacity(stopVisible ? 1 : 0)
                            }
                            .geometryGroup()
                            .frame(width: composerStop ? 32 : 30, height: composerStop ? 32 : 30)
                            .contentShape(Circle())
                    }.buttonStyle(.plain)
                        .disabled(disabled || (ordinaryOverviewDock && inputPresent &&
                            (!composerVisible || draft.submitting || draft.clearing || draft.isDisposed)))
                        .accessibilityHidden(ordinaryOverviewDock && inputPresent && !composerVisible)
                        .focused($stopFocused)
                        .accessibilityFocused($stopAccessibilityFocused)
                        .allowsHitTesting(stopVisible && (!inputPresent || composerVisible))
                        .help(threadID == nil ? localize("停止 Chief", "Stop Chief") : localize("停止此 Thread", "Stop this thread"))
                        .accessibilityLabel(threadID == nil ? localize("停止 Chief", "Stop Chief") : localize("停止此 Thread", "Stop this thread"))
                        .accessibilityIdentifier("moku-stop")
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("native-moku-dock")) } action: { stopControlsFrame = $0 }
                }
            }
        }
        .background {
            ZStack {
                NativeMokuCapsuleGlass(regular: noteExpanded).opacity(state.settingsExpanded ? 0 : 1)
                if state.settingsOpen {
                    NativeSettingsPanelBackground()
                        .environment(\.colorScheme, workspaceColorScheme)
                        .opacity(state.settingsExpanded ? 1 : 0)
                }
            }
        }.clipShape(RoundedRectangle(cornerRadius: NativeMokuCapsuleLayout.cornerRadius))
        .overlay(alignment: .bottom) {
            // Orbit ink lives outside the glass; never include it in the capsule clip.
            NativeMokuCharacterSurface(controller: character, input: characterInput, seat: .decorations)
                .frame(width: surface.width + decorationPadding * 2, height: rowHeight + decorationPadding * 2)
                .offset(y: decorationPadding)
                // Also hide the character's retiring ink as soon as detail owns
                // input, including entry from running Moku and rapid replacement.
                .opacity(inputSuppressesRunningFeedback ? 0 : 1)
                .animation(nil, value: inputSuppressesRunningFeedback)
                .allowsHitTesting(false)
        }
        .contentShape(RoundedRectangle(cornerRadius: NativeMokuCapsuleLayout.cornerRadius)).onHover(perform: updateHover)
        .shadow(color: .black.opacity(0.13), radius: hovered ? 17 : 13, y: 6)
        .nativeCanvasNavigationRegion()
        // In detail, only Dock focus may use this close route. A window-sized
        // fallback would race the reader's nested history/Sidecard cancellation.
        .nativeReadingEscape(perform: state.inputPinnedOpen && state.inputOpen && state.dockContentVisible && interaction == nil ? {
            escapeInput()
        } : nil)
        .accessibilityElement(children: .contain).accessibilityLabel(state.settingsOpen ? localize("设置", "Settings") : "Chief")
        .accessibilityHint(state.settingsOpen || !state.inputInteractionReady ? "" : localize("点击打开输入框，鼠标悬停时在触控板上向上滑动打开笔记", "Click to type; while hovering, swipe up on the trackpad for notes"))
        .accessibilityValue(state.noteUnread(note) ? localize("笔记有尚未完整浏览的更新", "Note update not yet fully browsed") : "")
        .accessibilityIdentifier("moku-capsule")
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
                  !(window.childWindows ?? []).contains(where: { $0.isVisible && $0.canBecomeKey }) else { return }
            if agentMentions?.dismiss() == true { return }
            if let sidecardComposer { sidecardComposer.cancel() }
            else { onThreadClose?() }
        }
        else { _ = state.dismissInputForEscape() }
    }
    private func composer(room: CGFloat, compact: Bool) -> some View {
        let mentions = agentMentions
        // The ink reveal owns only automatic acquisition. An admitted
        // editor must accept clicks/Tab without a delayed update blurring it.
        return NativeMokuComposerInput(draft: draft, cwd: cwd, disabled: disabled,
            submissionPending: draft.submitting,
            targetsThread: threadID != nil, sidecardComposer: sidecardComposer,
            readOnly: state.inputLeaving, focusEnabled: composerCanFocus && (sidecardComposer?.ready ?? true),
            automaticFocus: false,
            focusRequestKey: focusGeneration == state.composerGeneration ? focusRequest : 0,
            suppressInitialFocus: !state.composerAutofocus,
            maxHeight: min(landing ? 156 : 126, room), landing: landing, compact: compact,
            retainedText: retaining ? state.retainedText : nil,
            retainedAttachments: retaining ? state.retainedAttachments : nil,
            retainedDirectories: retaining ? state.retainedDirectories : nil,
            running: running, onCancel: onCancel,
            onReservedStopSeatChange: ordinaryOverviewDock ? { inset in composerStopInset = inset } : nil,
            selectionRequest: mentions?.selectionRequest,
            initialSelection: state.selectionForReopening(text: retaining ? state.retainedText : draft.text),
            onEditorStateChange: { editor in
                guard state.ownsComposer(draft) else { return }
                if state.inputOpen, editor.focused, !editor.composing,
                   editor.text.utf16.elementsEqual(draft.text.utf16) {
                    state.retainSelection(editor.selection, text: editor.text)
                }
                mentions?.update(editor)
            },
            onKeyDown: mentions.map { completion in
                { state.ownsComposer(draft) && completion.handle($0, draft: draft) }
            },
            onEditorSeatChange: {
                // The retiring editor remains mounted inside a shrinking capsule.
                // Its new anchor would redirect the eyes mid-collapse; keep the
                // last open seat until live editing resumes.
                if state.ownsComposer(draft), state.inputOpen { editorBottomInset = $0 }
            },
            onEscape: escapeInput, onSend: send)
    }

    private func send() {
        guard state.ownsComposer(draft), !state.settingsOpen, !disabled, state.inputOpen, draft.canSubmit else { return }
        guard sidecardComposer?.ready ?? true else { return }
        state.retainDraft(draft, seal: !state.inputPinnedOpen)
        // The retiring capsule is a sealed projection, independent of the live
        // draft. Clear it too so collapse never keeps the submitted ink visible.
        state.retainedText = ""; state.retainedAttachments = []; state.retainedDirectories = []
        if threadID == nil { state.dismissTalk() }
        let sendingDraft = draft, send = onSend, consumed = onSendConsumed, generation = state.composerGeneration
        state.setInputOpen(false)
        // Capture and project the submitted input in this event, before another
        // keystroke can change the payload. The receipt can arrive on a later visit.
        Task.immediate {
            await sendingDraft.submit(send, optimisticallyClear: true, didConsume: consumed)
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
