import Foundation
import CoreGraphics
import Observation
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI

/// Navigation lifetime shared by the overview, dock, thread and settings seats.
/// SwiftUI owns presentation and animation; the model owns navigation intent.
@MainActor @Observable public final class NativeMokuSceneState {
    public let overviewState: NativeOverviewCanvasState
    public let settingsCharacter = MokuCharacterController()
    /// Controls outside the Dock that an outside click must treat as inside,
    /// such as the Overview's Return to Automatic View button.
    let outsideClickExclusions = NativeClickExclusions()
    /// One registry spans the canvas and its overlaid Moku surfaces. A drag
    /// over the capsule must retain control ownership on touch and pointer.
    let canvasInputRegions = NativeCanvasInputRegions()
    public private(set) var mokuOpen = false
    public private(set) var cameraActive = false
    public private(set) var inputOpen = false
    public private(set) var inputLeaving = false
    public private(set) var talkPresentation = NativeMokuTalkState()
    public private(set) var settingsOpen = false
    public private(set) var settingsClosing = false
    public private(set) var settingsTransitioning = false
    private(set) var settingsTransitionRequest = 0
    @ObservationIgnored var settingsSettle: (() -> Void)?
    public private(set) var flightActive = false
    public private(set) var searchActive = false
    public private(set) var readingTarget: HarnessReadingTarget?
    public private(set) var readReplies: Set<JSONText> = []
    public private(set) var notePanelOpen = false
    public private(set) var noteOpenGeneration = 0
    public var overviewVisible = true {
        didSet {
            guard overviewVisible != oldValue, !overviewVisible else { return }
            talkPresentation.setPresented(false)
            closeNotePanel()
            setInputOpen(false)
            dockHitRects = []
            dockMentionHitRect = nil
            if dockInteractionVisible { setDockInteractionVisible(false, question: false) }
        }
    }
    public var disabled = false
    private(set) var dockVisibleViewport: CGRect?
    public var onMokuOpenChange: ((Bool) -> Void)?
    public var onSettingsOpenChange: ((Bool) -> Void)?
    public var onFlightActiveChange: ((Bool) -> Void)?
    @ObservationIgnored var command: ((Command) -> Void)?
    @ObservationIgnored var hostOwner: UUID?
    @ObservationIgnored var capsuleTask: Task<Void, Never>?
    @ObservationIgnored var retainedText = ""
    @ObservationIgnored var retainedAttachments: [NativeComposerAttachment] = []
    @ObservationIgnored var retainedDirectories: [NativeComposerDirectory] = []
    /// Caret/selection of the last open Dock editor. It outlives the editor
    /// view so reopening restores the reader's place instead of resetting it.
    @ObservationIgnored var retainedSelection: NSRange?
    @ObservationIgnored var capsuleSealed = false
    @ObservationIgnored var coordinatorFrame: CGRect?
    @ObservationIgnored var settingsOrigin = CGRect.zero
    /// The normal-flow operation notice can scroll the shell without resizing
    /// its viewport. Fixed descendants compensate imperatively, without a new
    /// SwiftUI update while the enclosing clip view is publishing its bounds.
    @ObservationIgnored public private(set) var shellScrollOffset = CGPoint.zero
    @ObservationIgnored var liveReplyKey: String?
    public private(set) var windowVisible = false
    @ObservationIgnored var dockHitRects: [CGRect] = []
    @ObservationIgnored var dockMentionHitRect: CGRect?
    @ObservationIgnored var capsuleFrame = CGRect.zero
    private(set) var dockInteractionVisible = false
    private(set) var dockInteractionIsQuestion = false
    @ObservationIgnored private var replyReadOrder: [JSONText]
    @ObservationIgnored private let replyReadFileURL: URL?
    @ObservationIgnored public var submitNoteExposure: ((JSONText, Int) async throws -> String)?
    @ObservationIgnored private var pendingNoteExposure: (id: JSONText, revision: Int)?
    @ObservationIgnored private var noteExposureTask: Task<Void, Never>?
    @ObservationIgnored private var noteExposureAuthority = UUID()
    @ObservationIgnored private var claimedNoteOpenGeneration = 0

    enum Command { case camera(Bool, Bool), settings(Bool), coordinator(CGRect?, Bool), position, visibility, shellScroll, settle }
    public init(overviewState: NativeOverviewCanvasState = .init(), replyReadFileURL: URL? = nil) {
        self.overviewState = overviewState
        self.replyReadFileURL = replyReadFileURL
        let stored = replyReadFileURL.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONValue.parse(data: $0) }?.arrayValue ?? []
        replyReadOrder = Array(stored.compactMap { value -> JSONText? in
            guard case let .string(text) = value else { return nil }
            return text
        }.suffix(256))
        readReplies = Set(replyReadOrder)
    }
    public var dockCovered: Bool { mokuOpen || cameraActive || settingsOpen || flightActive || searchActive }
    /// Voice-cloud admission only. Idle analysis stays off a normal thread, and
    /// explicit input or an intervention can still admit the cloud. The capsule
    /// view is mounted only while Overview is the current route.
    public var dockContentVisible: Bool {
        windowVisible && !dockCovered && (overviewVisible || inputOpen || dockInteractionVisible)
    }
    public var interactionPaused: Bool { cameraActive || settingsOpen || flightActive || inputOpen }

    public func setMokuOpen(_ open: Bool, readingTarget: HarnessReadingTarget? = nil) {
        guard !disabled || !open else { return }
        if open { talkPresentation.setPresented(false); closeNotePanel() }
        self.readingTarget = readingTarget
        setInputOpen(false)
        // Publish mounting admission before the route. Host callbacks may
        // synchronously derive workspaceMounted from these two values.
        cameraActive = false
        mokuOpen = open
        command?(.camera(open, overviewVisible && !settingsOpen))
        onMokuOpenChange?(open)
    }
    public func toggleMoku() { setMokuOpen(!mokuOpen) }
    public func setSearchActive(_ active: Bool) {
        guard searchActive != active else { return }
        searchActive = active
        if active { talkPresentation.setPresented(false); closeNotePanel() }
        command?(.visibility)
    }
    public func toggleInput() {
        // Compose belongs to the Overview capsule. Off that route the shortcut
        // must not reopen a hidden field or leave it first responder.
        guard overviewVisible else { return }
        if mokuOpen || cameraActive { setMokuOpen(false); setInputOpen(true) }
        else { setInputOpen(!inputOpen) }
    }
    public func setInputOpen(_ open: Bool) {
        guard !disabled || !open else { return }
        guard open != inputOpen else { return }
        capsuleTask?.cancel(); capsuleTask = nil
        overviewState.clearAutoFocusSuppression()
        if open {
            talkPresentation.setPresented(false)
            closeNotePanel()
            inputLeaving = false; capsuleSealed = false; inputOpen = true
        }
        else if inputOpen {
            inputOpen = false; inputLeaving = true
            capsuleTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(420))
                guard !Task.isCancelled, let self else { return }
                self.inputLeaving = false
            }
        }
        command?(.position)
    }

    /// A click outside the composer leaves input-box mode. The click is marked
    /// before mouse-up so the Overview background cannot also run its automatic
    /// framing transition for the same press.
    @discardableResult
    public func dismissInputForOutsideClick() -> Bool {
        guard inputOpen, overviewVisible, !dockCovered, !disabled else { return false }
        setInputOpen(false)
        overviewState.suppressAutoFocusForThisClick()
        return true
    }
    public func receiveTalk(_ message: NativeMokuTalkMessage?) { talkPresentation.receive(message) }
    func setTalkPresented(_ visible: Bool) { talkPresentation.setPresented(visible) }
    func expireTalk(id: JSONText, deadline: ContinuousClock.Instant) { talkPresentation.expire(id: id, deadline: deadline) }
    public func dismissTalk() { talkPresentation.dismiss() }

    /// The note panel belongs to the Overview dock only. Composer and
    /// permission/question panels take priority; opening either closes it.
    public func toggleNotePanel() { setNotePanelOpen(!notePanelOpen) }
    /// Only the existing user entry points may start a fresh reading session.
    public func openNotePanelFromUser() {
        setNotePanelOpen(true)
        if notePanelOpen { noteOpenGeneration &+= 1 }
    }
    public func toggleNotePanelFromUser() {
        if notePanelOpen { setNotePanelOpen(false) }
        else { openNotePanelFromUser() }
    }
    public func claimNoteOpenArm() -> Bool {
        guard notePanelOpen, noteOpenGeneration > claimedNoteOpenGeneration else { return false }
        claimedNoteOpenGeneration = noteOpenGeneration
        return true
    }
    public func setNotePanelOpen(_ open: Bool) {
        guard open != notePanelOpen else { return }
        guard !open || (overviewVisible && !disabled && !dockCovered && !dockInteractionVisible) else { return }
        if open { setInputOpen(false) }
        notePanelOpen = open
        command?(.position)
    }
    private func closeNotePanel() {
        guard notePanelOpen else { return }
        notePanelOpen = false
        command?(.position)
    }
    public func noteUnread(_ note: NativeMokuNote?) -> Bool {
        note?.hasUnexposedUpdate == true
    }

    public func reconcileNoteExposure(_ note: NativeMokuNote?) {
        guard let pending = pendingNoteExposure else { return }
        guard let note, note.id == pending.id, note.revision == pending.revision,
              note.hasUnexposedUpdate else {
            pendingNoteExposure = nil
            noteExposureAuthority = UUID()
            noteExposureTask?.cancel(); noteExposureTask = nil
            return
        }
    }

    public func resetNoteExposureAuthority() {
        pendingNoteExposure = nil
        suspendNoteExposureSubmission()
    }

    public func suspendNoteExposureSubmission() {
        noteExposureAuthority = UUID()
        noteExposureTask?.cancel(); noteExposureTask = nil
    }

    public func recordNoteExposure(_ note: NativeMokuNote) {
        guard note.hasUnexposedUpdate else { return }
        pendingNoteExposure = (note.id, note.revision)
        retryNoteExposure()
    }

    public func retryNoteExposure() {
        guard noteExposureTask == nil, let pending = pendingNoteExposure,
              let submitNoteExposure else { return }
        let authority = noteExposureAuthority
        noteExposureTask = Task { [weak self] in
            let status = try? await submitNoteExposure(pending.id, pending.revision)
            guard let self, self.noteExposureAuthority == authority,
                  self.pendingNoteExposure?.id == pending.id,
                  self.pendingNoteExposure?.revision == pending.revision else { return }
            self.noteExposureTask = nil
            if status == "stale" { self.pendingNoteExposure = nil }
            // Accepted/duplicate only become visible after the authoritative
            // catalog arrives; failures wait for the next UI activity.
        }
    }
    public func retainDraft(_ draft: NativeComposerDraft, seal: Bool = false) {
        guard !capsuleSealed else { return }
        retainedText = draft.text; retainedAttachments = draft.attachments; retainedDirectories = draft.directories
        capsuleSealed = seal
    }
    func retainSelection(_ selection: NSRange) {
        guard selection.location != NSNotFound else { return }
        retainedSelection = selection
    }
    public func openSettings(origin: CGRect = .zero) {
        guard !settingsOpen || settingsClosing else { return }
        talkPresentation.setPresented(false)
        closeNotePanel()
        if !settingsOpen { settle() }
        settingsOrigin = origin; settingsClosing = false; settingsOpen = true
        settingsTransitioning = settingsSettle != nil
        settingsTransitionRequest += 1
        onSettingsOpenChange?(true)
        command?(.settings(true))
    }
    public func closeSettings(origin: CGRect = .zero) {
        guard settingsOpen, !settingsClosing else { return }
        if !origin.isEmpty { settingsOrigin = origin }
        settingsClosing = true
        settingsTransitioning = settingsSettle != nil
        settingsTransitionRequest += 1
        if settingsSettle == nil { finishSettingsTransition() }
    }
    public func setCoordinatorFrame(_ rect: CGRect?, pending: Bool) {
        coordinatorFrame = rect
        command?(.coordinator(rect, pending))
    }
    public func setShellScrollOffset(_ offset: CGPoint) {
        guard offset.x.isFinite, offset.y.isFinite, shellScrollOffset != offset else { return }
        shellScrollOffset = offset
        command?(.shellScroll)
    }
    public func settle() { settingsSettle?(); command?(.settle) }
    func setDockInteractionVisible(_ value: Bool, question: Bool) {
        if value { talkPresentation.setPresented(false); closeNotePanel() }
        dockInteractionVisible = value; dockInteractionIsQuestion = question; command?(.position)
    }
    public func markReplyRead(_ key: String) {
        markReplyRead(JSONText(key))
    }
    public func markReplyRead(_ key: JSONText) {
        guard !readReplies.contains(key) else { return }
        replyReadOrder = Array((replyReadOrder + [key]).suffix(256))
        readReplies = Set(replyReadOrder)
        guard let replyReadFileURL else { return }
        // Each native data directory has the same isolation as an Electron
        // profile's localStorage. A storage failure never interrupts reading.
        do {
            try FileManager.default.createDirectory(at: replyReadFileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONValue.array(replyReadOrder.map(JSONValue.string)).encodedData().write(to: replyReadFileURL, options: .atomic)
        } catch {}
    }
    func setCameraActive(_ active: Bool) {
        if active { talkPresentation.setPresented(false); closeNotePanel() }
        cameraActive = active
        if !active, mokuOpen, windowVisible, let key = liveReplyKey { markReplyRead(key) }
    }
    func setFlightActive(_ active: Bool) {
        if active { talkPresentation.setPresented(false); closeNotePanel() }
        flightActive = active; onFlightActiveChange?(active)
    }
    func finishSettingsTransition() {
        settingsTransitioning = false
        guard settingsClosing else { return }
        settingsClosing = false; settingsOpen = false
        onSettingsOpenChange?(false)
    }
    func setWindowVisible(_ value: Bool) {
        if !value { talkPresentation.setPresented(false); closeNotePanel() }
        windowVisible = value
        if value, mokuOpen, !cameraActive, let key = liveReplyKey { markReplyRead(key) }
    }
    func dockViewport(in size: CGSize) -> CGRect {
        dockVisibleViewport ?? CGRect(origin: .zero, size: size)
    }
    func setDockViewport(_ viewport: CGRect) {
        if dockVisibleViewport != viewport { dockVisibleViewport = viewport }
    }
}

/// Small, immutable display input. Execution and transcript interpretation stays
/// at their public boundary; the scene does not inspect a Harness sessionState.
public struct NativeMokuDockReply: Equatable, Sendable {
    public let id: String
    public let readKey: String
    public let excerpt: String
    public let executionID: JSONText
    public let target: JSONValue?
    public init(id: String, readKey: String, excerpt: String, executionID: JSONText, target: JSONValue? = nil) {
        self.id = id; self.readKey = readKey; self.excerpt = excerpt; self.executionID = executionID; self.target = target
    }
}
