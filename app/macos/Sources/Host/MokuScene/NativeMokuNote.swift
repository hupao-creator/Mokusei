import AppKit
import Foundation
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import SwiftUI

/// Public projection of Moku's one persistent milestone note. The transcript is
/// not consulted: the note is published on the Thread record so it outlives
/// audit previews and execution changes.
public struct NativeMokuNote: Equatable, Sendable {
    /// The note incarnation survives host replacement but not history reset.
    public let id: JSONText
    public let text: String
    public let revision: Int
    public let updatedAt: Double
    public let lastExposureRevision: Int?

    public init(id: JSONText, text: String, revision: Int, updatedAt: Double,
                lastExposureRevision: Int? = nil) {
        self.id = id; self.text = text; self.revision = revision; self.updatedAt = updatedAt
        self.lastExposureRevision = lastExposureRevision
    }

    /// An empty note is the explicit clear; the panel shows its empty state.
    public static func current(in thread: HarnessThread?) -> Self? {
        guard let thread, thread.moku == true, let note = thread.note, !note.isEmpty else { return nil }
        return Self(id: note.id, text: note.text.string, revision: note.revision,
                    updatedAt: note.updatedAt, lastExposureRevision: note.lastExposure?.revision)
    }

    public var date: Date { Date(timeIntervalSince1970: updatedAt / 1000) }
    public var documentToken: String { "\(id.string):\(revision)" }
    public var hasUnexposedUpdate: Bool { !text.isEmpty && lastExposureRevision != revision }
}

@MainActor enum NativeMokuNoteExposureSender {
    static func submit(workspace: NativeWorkspaceModel, id: JSONText, revision: Int) async throws -> String {
        let result = try await workspace.invoke("moku:record-note-exposure", args: [.object([
            "noteId": .string(id), "revision": .integer(revision),
            "signal": .text("complete-viewport-coverage-v1")
        ])])
        guard let status = result["status"]?.stringValue,
              ["accepted", "duplicate", "stale"].contains(status) else {
            throw RuntimeError("INVALID_RESPONSE", "Runtime returned an invalid note exposure result")
        }
        return status
    }
}

/// The note consumes only the space above Moku's existing bottom row. Its
/// natural reading height is capped by the Dock's visible viewport.
enum NativeMokuNoteLayout {
    static func fittedHeight(content: CGFloat, available: CGFloat) -> CGFloat {
        min(max(0, available), max(0, content > 0 ? content : 160))
    }
}


/// Read-only content inside Moku's expanding glass. This view deliberately
/// owns no material, shadow or outer shape; the capsule supplies all three.
struct NativeMokuNoteContent: View {
    let note: NativeMokuNote?
    let width: CGFloat
    let height: CGFloat
    let availableHeight: CGFloat
    var routeEligible = true
    let openExternal: ((URL) -> Void)?
    var openExecution: ((ApplicationExecutionRef) -> Void)? = nil
    var onContentHeightChange: ((CGFloat) -> Void)?
    var claimOpenArm: () -> Bool = { false }
    var onExposure: ((NativeMokuNote) -> Void)?
    var onClose: () -> Void = {}
    @Environment(\.locale) private var locale
    @State private var contentHeight: CGFloat = 0
    @State private var exposure = NativeMokuNoteExposureTracker()
    private let headerHeight: CGFloat = 54
    private var shortViewport: Bool { availableHeight < headerHeight + 44 }

    private func localize(_ zh: String, _ en: String) -> String {
        locale.language.languageCode?.identifier == "zh" ? zh : en
    }

    var body: some View {
        Group {
            if shortViewport {
                // At large app zoom, fixed chrome can leave less than a line.
                // Let the header scroll with the body in this short viewport.
                // Use the Dock's capacity, not the initially empty document's
                // fitted height: changing branches would retire its read session.
                NativeScrollView {
                    VStack(alignment: .leading, spacing: 12) { header; noteBody }
                }.scrollIndicators(.automatic).scrollBounceBehavior(.basedOnSize)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    header.padding(.bottom, 12)
                    NativeScrollView { noteBody }
                        .scrollIndicators(.automatic).scrollBounceBehavior(.basedOnSize)
                        .frame(height: max(0, height - headerHeight))
                }
            }
        }
        // Reading content stays above the retained row and the history action.
        .frame(width: width, height: height, alignment: .top)
        .clipped()
        .onChange(of: contentHeight, initial: true) { _, height in
            if height > 0 { onContentHeightChange?(height + headerHeight) }
        }
        .onAppear {
            exposure.onComplete = onExposure
            exposure.configure(note)
            if claimOpenArm() { exposure.arm() }
        }
        .onChange(of: note) { _, next in exposure.configure(next) }
        .onDisappear { exposure.endSession() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("moku-note-panel")
    }
    private var header: some View {
        HStack(spacing: 12) {
            Text(localize("Moku 笔记", "Moku Note"))
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 0)
            if let note {
                Text(note.date, format: .dateTime.month().day().hour().minute())
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityIdentifier("moku-note-updated")
            }
            Button(action: onClose) {
                NativeIcon(name: "X", size: 12, strokeWidth: 1.7)
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(localize("收起 Moku 笔记", "Close Moku note"))
            .accessibilityIdentifier("moku-note-close")
        }
        .frame(height: 24)
        .padding(.horizontal, 18).padding(.top, 18)
    }
    private var noteBody: some View {
        Group {
            if let note {
                NativeMarkdownView(text: note.text, fontSize: 13, openExternal: openExternal,
                    openExecution: openExecution, documentToken: note.documentToken,
                    onDocumentApplied: { exposure.applied($0) })
                    .id(note.documentToken)
                    .background(NativeMokuNoteExposureProbe(tracker: exposure, note: note,
                        routeEligible: routeEligible))
                    .accessibilityIdentifier("moku-note-content")
            } else {
                Text(localize("Moku 还没有写笔记。", "Moku has not written a note yet."))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("moku-note-empty")
            }
        }
        .padding(.horizontal, 18).padding(.bottom, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
    }
}

/// One mounted note owns one coverage set. No two windows can combine partial
/// ranges, and a new document identity or layout discards incomplete evidence.
@MainActor final class NativeMokuNoteExposureTracker {
    var onComplete: ((NativeMokuNote) -> Void)?
    private(set) var note: NativeMokuNote?
    private var appliedToken: String?
    private var eligible = false
    private var armed = false
    private var completed = false
    private var wasQualified = false
    private var bodySize = CGSize.zero
    private var viewportSize = CGSize.zero
    private var candidate: ClosedRange<CGFloat>?
    private var coverage: [ClosedRange<CGFloat>] = []
    private var deadline: Task<Void, Never>?
    private var generation = 0

    func configure(_ next: NativeMokuNote?) {
        let changed = note?.documentToken != next?.documentToken
        note = next
        if changed {
            appliedToken = nil; eligible = false; completed = false
            endSession()
            bodySize = .zero; viewportSize = .zero; generation &+= 1
        }
        if next?.hasUnexposedUpdate == false { completed = true; cancelDeadline() }
    }

    func applied(_ result: NativeMarkdownAppliedDocument?) {
        guard let note, result?.token == note.documentToken else {
            appliedToken = nil; eligible = false; cancelDeadline(); return
        }
        let changed = appliedToken != result?.token || eligible != result?.coverageEligible
        appliedToken = result?.token; eligible = result?.coverageEligible == true
        if changed { resetCoverage() }
    }

    func arm() { armed = true }
    func armFromBodyEvent() {
        guard let note, appliedToken == note.documentToken, eligible else { return }
        armed = true
    }

    func update(body: CGSize, viewport: CGRect?, qualified: Bool) {
        let nextViewportSize = viewport?.size ?? .zero
        if abs(body.width - bodySize.width) > 0.5 || abs(body.height - bodySize.height) > 0.5
            || abs(nextViewportSize.width - viewportSize.width) > 0.5
            || abs(nextViewportSize.height - viewportSize.height) > 0.5 {
            bodySize = body; viewportSize = nextViewportSize; resetCoverage()
        }
        if wasQualified && !qualified { endSession() }
        wasQualified = qualified
        guard let note, note.hasUnexposedUpdate, !completed, armed,
              appliedToken == note.documentToken, eligible, qualified,
              body.width > 0, body.height > 0,
              let viewport, viewport.width > 0, viewport.height > 0,
              body.width <= viewport.width + 1 else { cancelDeadline(); return }
        let lower = max(0, viewport.minY), upper = min(body.height, viewport.maxY)
        guard lower < upper, viewport.minX <= 1, viewport.maxX >= body.width - 1 else {
            cancelDeadline(); return
        }
        let range = lower...upper
        if let current = candidate, abs(current.lowerBound - lower) < 0.1,
           abs(current.upperBound - upper) < 0.1 { return }
        cancelDeadline()
        candidate = range
        let captured = generation
        deadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, self.generation == captured,
                  self.candidate == range, self.armed, self.wasQualified,
                  self.appliedToken == self.note?.documentToken else { return }
            self.deadline = nil; self.candidate = nil
            self.coverage.append(range)
            self.coverage.sort { $0.lowerBound < $1.lowerBound }
            var merged: [ClosedRange<CGFloat>] = []
            for interval in self.coverage {
                if let last = merged.last, interval.lowerBound <= last.upperBound + 1 {
                    merged[merged.count - 1] = last.lowerBound...max(last.upperBound, interval.upperBound)
                } else { merged.append(interval) }
            }
            // Retain the union, not every visit: repeated scrolling over the
            // same text must not grow the scene's evidence indefinitely.
            self.coverage = merged
            if merged.count == 1, let full = merged.first,
               full.lowerBound <= 1, full.upperBound >= self.bodySize.height - 1,
               let note = self.note {
                self.completed = true
                self.onComplete?(note)
            }
        }
    }

    func endSession() { armed = false; wasQualified = false; resetCoverage() }
    private func resetCoverage() { cancelDeadline(); coverage = []; generation &+= 1 }
    private func cancelDeadline() { deadline?.cancel(); deadline = nil; candidate = nil }
}

/// This inert view observes the real AppKit body and clip geometry without
/// intercepting pointer, selection, Markdown links, composer, or voice focus.
private struct NativeMokuNoteExposureProbe: NSViewRepresentable {
    let tracker: NativeMokuNoteExposureTracker
    let note: NativeMokuNote
    let routeEligible: Bool

    func makeNSView(context: Context) -> ExposureView {
        let view = ExposureView()
        view.tracker = tracker
        view.routeEligible = routeEligible
        return view
    }
    func updateNSView(_ view: ExposureView, context: Context) {
        view.tracker = tracker
        view.routeEligible = routeEligible
        view.refresh()
    }
    static func dismantleNSView(_ view: ExposureView, coordinator: ()) { view.stop(retireSession: true) }

    @MainActor final class ExposureView: NSView {
        weak var tracker: NativeMokuNoteExposureTracker?
        var routeEligible = true
        private var observers: [NSObjectProtocol] = []
        private var monitor: Any?
        private weak var clip: NSClipView?
        override var isFlipped: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { stop(retireSession: true) }
            else { install(); refresh() }
        }
        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            if superview == nil { stop(retireSession: true) }
            else { install(); refresh() }
        }
        override func layout() { super.layout(); refresh() }

        private func install() {
            stop()
            guard let window, let scroll = enclosingScrollView else { return }
            let clip = scroll.contentView
            self.clip = clip
            clip.postsBoundsChangedNotifications = true
            postsFrameChangedNotifications = true
            let center = NotificationCenter.default
            for (name, object) in [
                (NSView.boundsDidChangeNotification, clip as AnyObject),
                (NSView.frameDidChangeNotification, self as AnyObject),
                (NSWindow.didBecomeKeyNotification, window as AnyObject),
                (NSWindow.didResignKeyNotification, window as AnyObject),
                (NSWindow.didChangeOcclusionStateNotification, window as AnyObject),
                (NSWindow.didMiniaturizeNotification, window as AnyObject),
                (NSWindow.didDeminiaturizeNotification, window as AnyObject),
                (NSApplication.didBecomeActiveNotification, NSApp as AnyObject),
                (NSApplication.didResignActiveNotification, NSApp as AnyObject)
            ] {
                observers.append(center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                })
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event) }
                return event
            }
        }

        func stop(retireSession: Bool = false) {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers = []
            if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
            clip = nil
            if retireSession { tracker?.endSession() }
        }

        private func handle(_ event: NSEvent) {
            guard let window, event.window === window, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
            if event.type == .scrollWheel, !event.momentumPhase.isEmpty { return }
            tracker?.armFromBodyEvent()
            refresh()
        }

        func refresh() {
            guard let window, let clip else { return }
            let contentFits = clip.documentView.map { document in
                document.bounds.width <= clip.bounds.width + 1 && !horizontalOverflow(in: document)
            } ?? false
            let qualified = routeEligible && contentFits && NSApp.isActive && window.isKeyWindow
                && window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
            let viewport = convert(clip.bounds, from: clip)
            tracker?.update(body: bounds.size, viewport: viewport, qualified: qualified)
        }

        private func horizontalOverflow(in view: NSView) -> Bool {
            if let text = view as? NSTextView, let layout = text.layoutManager,
               let container = text.textContainer,
               layout.usedRect(for: container).maxX > text.bounds.width + 1 { return true }
            return view.subviews.contains(where: horizontalOverflow)
        }
    }
}

/// The Dock owns this action so note scrolling cannot move its bottom seat.
struct NativeMokuNoteHistoryButton: View {
    var compact = false
    var onOpen: () -> Void
    @Environment(\.locale) private var locale

    private func localize(_ zh: String, _ en: String) -> String {
        locale.language.languageCode?.identifier == "zh" ? zh : en
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 6) {
                NativeIcon(name: "History", size: 13)
                if !compact {
                    Text(localize("Moku 历史", "Moku history"))
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 6)
            .frame(minWidth: 28, minHeight: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(localize("查看 Moku 历史详情", "View Moku conversation history"))
        .accessibilityLabel(localize("查看 Moku 历史详情", "View Moku conversation history"))
        .accessibilityIdentifier("moku-note-history")
    }
}
