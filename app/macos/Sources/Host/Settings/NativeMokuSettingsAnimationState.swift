import AppKit
import Foundation
import Observation
import SwiftUI

/// The source's independent handoff, quiet-window feedback and idle clocks.
/// A target change saves immediately; only its visual acknowledgment is delayed.
@MainActor @Observable final class NativeMokuSettingsAnimationState {
    struct Handoff {
        let identity = UUID()
        let hostID: String
        let previousID: String?
        let direction: CGFloat
        let startedAt: Double
        let eyeMotion: MokuEyeMotion
    }
    struct FeedbackRequest: Equatable {
        let sequence: Int
        let targetID: String
        let enabled: Bool
        let gazeX: CGFloat
    }
    struct Feedback {
        let identity = UUID()
        let request: FeedbackRequest
        let startedAt: Double
        let eyeMotion: MokuEyeMotion
    }
    struct DispatchMove {
        let from: CGPoint
        let to: CGPoint
        let startedAt: Double
        let moving: Bool
    }

    private(set) var driverID: String?
    private(set) var handoff: Handoff?
    private(set) var feedback: Feedback?
    private(set) var latestFeedback: FeedbackRequest?
    private(set) var idleStartedAt: Double?
    private(set) var dispatchMove: DispatchMove?
    private var armedFeedback: FeedbackRequest?
    private var settledSequence = 0
    private var sequence = 0
    private var hostID: String?
    private var inFlight = false
    private var visible = true
    private var hadDispatchTargets = false
    @ObservationIgnored private var handoffTask: Task<Void, Never>?
    @ObservationIgnored private var quietTask: Task<Void, Never>?
    @ObservationIgnored private var feedbackTask: Task<Void, Never>?

    static var now: Double { ProcessInfo.processInfo.systemUptime * 1000 }
    var pendingFeedback: Bool { latestFeedback.map { $0.sequence != settledSequence } ?? false }
    private var ready: Bool { hostID != nil && driverID == hostID && handoff == nil && !inFlight }

    func configure(hostID: String?, inFlight: Bool) {
        self.hostID = hostID; self.inFlight = inFlight
        if handoff?.hostID != hostID {
            handoffTask?.cancel(); handoffTask = nil; handoff = nil; driverID = hostID
        }
        if !ready { cancelFeedback() }
        startFeedbackIfReady(); updateIdle()
    }

    func beginHandoff(to next: String, direction: CGFloat) {
        handoffTask?.cancel()
        let now = Self.now
        let transfer = Handoff(hostID: next, previousID: driverID, direction: direction, startedAt: now,
                               eyeMotion: NativeMokuSettingsMotion.handoffEyeMotion(direction: direction, startedAtMilliseconds: now))
        handoff = transfer; hostID = next
        cancelFeedback(); updateIdle()
        handoffTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(1050)) } catch { return }
            guard let self, self.handoff?.identity == transfer.identity else { return }
            self.driverID = next; self.handoff = nil; self.handoffTask = nil
            self.startFeedbackIfReady(); self.updateIdle()
        }
    }

    func requestFeedback(targetID: String, enabled: Bool, gazeX: CGFloat) {
        sequence += 1
        let request = FeedbackRequest(sequence: sequence, targetID: targetID, enabled: enabled,
                                      gazeX: min(32, max(-32, gazeX)))
        latestFeedback = request; updateIdle()
        quietTask?.cancel()
        quietTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            guard let self, self.latestFeedback?.sequence == request.sequence else { return }
            self.armedFeedback = request; self.quietTask = nil
            self.startFeedbackIfReady()
        }
    }

    func configureDispatch(source: CGPoint?, hasTargets: Bool) {
        guard let source else { dispatchMove = nil; hadDispatchTargets = false; return }
        if dispatchMove?.to != source {
            let now = Self.now
            let previous = hadDispatchTargets ? dispatchPosition(at: now) ?? source : source
            dispatchMove = DispatchMove(from: previous, to: source, startedAt: now, moving: hadDispatchTargets)
        }
        hadDispatchTargets = hasTargets
    }

    func dispatchPosition(at now: Double) -> CGPoint? {
        dispatchMove.map { NativeMokuSettingsMotion.dispatchSource(from: $0.from, to: $0.to,
            elapsedMilliseconds: now - $0.startedAt, moving: $0.moving) }
    }

    func setVisible(_ visible: Bool) {
        guard visible != self.visible else { return }
        self.visible = visible; idleStartedAt = nil; updateIdle()
    }

    func stop() {
        handoffTask?.cancel(); quietTask?.cancel(); feedbackTask?.cancel()
        handoffTask = nil; quietTask = nil; feedbackTask = nil
        handoff = nil; feedback = nil; latestFeedback = nil; armedFeedback = nil
        driverID = nil; hostID = nil; idleStartedAt = nil; dispatchMove = nil
        hadDispatchTargets = false
    }

    private func startFeedbackIfReady() {
        guard ready, let request = armedFeedback, request.sequence == latestFeedback?.sequence,
              request.sequence != settledSequence else { return }
        guard feedback?.request.sequence != request.sequence else { return }
        cancelFeedback()
        let now = Self.now
        let clip = Feedback(request: request, startedAt: now,
                            eyeMotion: NativeMokuSettingsMotion.feedbackEyeMotion(enabled: request.enabled, gazeX: request.gazeX, startedAtMilliseconds: now))
        feedback = clip
        feedbackTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(NativeMokuSettingsMotion.feedbackDurationMilliseconds(enabled: request.enabled))) }
            catch { return }
            guard let self, self.feedback?.identity == clip.identity else { return }
            self.settledSequence = request.sequence; self.feedback = nil; self.feedbackTask = nil
            self.startFeedbackIfReady(); self.updateIdle()
        }
    }

    private func cancelFeedback() { feedbackTask?.cancel(); feedbackTask = nil; feedback = nil }
    private func updateIdle() {
        if ready && !pendingFeedback && visible {
            if idleStartedAt == nil { idleStartedAt = Self.now }
        } else { idleStartedAt = nil }
    }
}

struct NativeMokuSettingsTransform: ViewModifier {
    let pose: NativeMokuSettingsMotion.Transform
    var scale: CGFloat = 1.7
    var anchor = UnitPoint(x: 0.5, y: 0.8)
    func body(content: Content) -> some View {
        content.scaleEffect(x: pose.scaleX, y: pose.scaleY, anchor: anchor)
            .rotationEffect(.degrees(pose.rotationDegrees), anchor: anchor)
            .offset(x: pose.x * scale, y: pose.y * scale)
    }
}

struct NativeSettingsWindowVisibility: NSViewRepresentable {
    let changed: (Bool) -> Void
    func makeNSView(context: Context) -> Observer { Observer() }
    func updateNSView(_ view: Observer, context: Context) { view.changed = changed; view.report() }
    static func dismantleNSView(_ view: Observer, coordinator: ()) { view.dispose() }
    final class Observer: NSView {
        var changed: ((Bool) -> Void)?
        private var notification: NSObjectProtocol?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); dispose()
            if let window {
                notification = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                    object: window, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.report() } }
                report()
            }
        }
        func report() {
            guard let window else { return }
            let visible = window.occlusionState.contains(.visible)
            DispatchQueue.main.async { [weak self] in self?.changed?(visible) }
        }
        func dispose() {
            if let notification { NotificationCenter.default.removeObserver(notification); self.notification = nil }
        }
    }
}
