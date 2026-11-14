import AppKit
import Observation
import SwiftUI
import MokuseiCore

/// A transient render slot. No native message semantics or persisted state live here.
public struct ThreadTimelineRow: Identifiable {
    public let id: JSONText
    public let createdAt: Double
    public let node: AnyView
    public init(id: JSONText, createdAt: Double, node: AnyView) {
        self.id = id; self.createdAt = createdAt; self.node = node
    }
}

struct ThreadAnchorPreference: PreferenceKey {
    static let defaultValue: [JSONText: CGFloat] = [:]
    static func reduce(value: inout [JSONText: CGFloat], nextValue: () -> [JSONText: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}
struct ThreadFocusPreference: PreferenceKey {
    static let defaultValue: [UUID] = []
    static func reduce(value: inout [UUID], nextValue: () -> [UUID]) { value.append(contentsOf: nextValue()) }
}
private struct ThreadTimelineFocus: ViewModifier {
    @State private var id = UUID()
    func body(content: Content) -> some View {
        content.id(id).preference(key: ThreadFocusPreference.self, value: [id])
    }
}
public extension View {
    /// Opaque plugin identities are registered only while their corresponding content is mounted.
    func threadReadingAnchor(_ id: JSONText) -> some View {
        // A background contributes alongside descendant anchors instead of
        // replacing them. Measure in document coordinates so late row loading
        // does not depend on ScrollViewReader registering nested opaque views.
        self.id(id).background {
            GeometryReader { geometry in
                Color.clear.preference(key: ThreadAnchorPreference.self,
                    value: [id: geometry.frame(in: .named("thread-timeline-content")).minY])
            }
        }
    }
    func threadTimelineFocus() -> some View { modifier(ThreadTimelineFocus()) }
}

public struct ThreadTimelineReadingTarget: Hashable, Sendable {
    public let requestId: JSONText
    public let anchorId: JSONText
    public let follow: Bool
    public init(requestId: JSONText, anchorId: JSONText, follow: Bool = false) {
        self.requestId = requestId; self.anchorId = anchorId; self.follow = follow
    }
}

private struct TimelineGeometry: Equatable {
    let contentOffset: CGFloat
    let insetTop: CGFloat
    let height: CGFloat
    let viewport: CGFloat
    // ScrollPosition uses a zero-based content coordinate; ScrollGeometry's
    // raw offset starts at -contentInsets.top. Keep retention and relative
    // scroll commands in the same coordinate space as their write target.
    var top: CGFloat { contentOffset + insetTop }
    var distance: CGFloat { max(0, height - top - viewport) }
}

@MainActor @Observable private final class TimelineViewport {
    var geometry = TimelineGeometry(contentOffset: 0, insetTop: 0, height: 0, viewport: 0)
}

/// Exact offsets belong to the control observation, not to the document's view
/// construction. Keep fresh control handles without rebuilding every message
/// whenever the native viewport moves.
private struct TimelineInteractionRegistration: View {
    let viewport: TimelineViewport
    let label: String
    let enabled: Bool
    let following: Bool
    let locatedRequest: JSONText?
    let showLatest: Bool
    let rowCount: Int
    let firstIndex: Int
    let visibleRowIds: [JSONText]
    let showOlderRows: Bool
    let perform: (String, JSONValue) throws -> Void

    var body: some View {
        let geometry = viewport.geometry
        NativeReadingControlRegistration(id: "timeline", descriptor: .object([
            "kind": .text("scroll"), "role": .text("timeline"), "label": .text(label),
            "enabled": .bool(enabled), "operations": .array([.text("scrollTo"), .text("scrollBy")]),
            "value": .object([
                "top": .number(Double(geometry.top)), "height": .number(Double(geometry.height)),
                "contentOffset": .number(Double(geometry.contentOffset)), "insetTop": .number(Double(geometry.insetTop)),
                "viewport": .number(Double(geometry.viewport)), "following": .bool(following),
                "locatedRequestId": locatedRequest.map(JSONValue.string) ?? .null, "showLatest": .bool(showLatest),
                "rowCount": .integer(rowCount), "firstIndex": .integer(firstIndex), "visibleCount": .integer(visibleRowIds.count),
                "visibleRowIds": .array(visibleRowIds.map(JSONValue.string)), "showOlderRows": .bool(showOlderRows)
            ])
        ]), perform: perform)
    }
}
private enum TimelineEdge: Hashable { case top, bottom }

private enum TimelineConstructionProfile {
    static let enabled = ProcessInfo.processInfo.environment["MOKUSEI_TIMELINE_PROFILE"] == "1"
    // Count construction separately from geometry delivery; neither is a
    // rendered frame. Keep observation and scroll state entirely unchanged.
    static func record(_ phase: Int, context: @autoclosure () -> UInt64?) {
        guard enabled, NativePerformance.mode == .detailed else { return }
        NativePerformance.event(.display, context: context(), values: ["timelinePhase": Double(phase)])
    }
}

/// Diagnostics attach only to the timeline; shared styling belongs to NativeScrollView.
private struct TimelineDiagnosticsAttachment: NSViewRepresentable {
    var active: Bool
    var operation: UInt64?
    func makeNSView(context: Context) -> TimelineDiagnosticsAttachmentView {
        TimelineDiagnosticsAttachmentView()
    }
    func updateNSView(_ view: TimelineDiagnosticsAttachmentView, context: Context) {
        view.active = active
        view.operation = operation
        view.configure()
    }
    static func dismantleNSView(_ view: TimelineDiagnosticsAttachmentView, coordinator: ()) { view.diagnostics.detach() }
}

@MainActor private final class TimelineDiagnosticsAttachmentView: NSView {
    let diagnostics = TimelineScrollDiagnostics()
    var active = true
    var operation: UInt64?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); configure() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); configure() }

    func configure() {
        let scroll = window == nil ? nil : enclosingScrollView
        diagnostics.attach(to: scroll, enabled: active, context: operation)
    }
}


/// Bounded history window with explicit following. Documents start at their heading unless the caller opens at the live bottom.
public struct HarnessMessageTimeline: View {
    public let timelineKey: JSONText
    /// Primary document identity within a retained timeline, independent of its live follow key.
    public var documentKey: JSONText?
    public let rows: [ThreadTimelineRow]
    public var toolbar: AnyView?
    public var emptyState: AnyView?
    /// Historical name: an explicit inset now applies to both document edges.
    public var contentTopInset: CGFloat?
    public var suspended: Bool
    public var followOutput: Bool
    public var allowsJumpToLatest: Bool
    public var opensAtBottom: Bool
    public var followKey: JSONText?
    public var followPaused: Bool
    public var onJumpToLatest: (() -> Void)?
    public var showOlderRows: Bool
    public var pinnedRowId: JSONText?
    public var readingTarget: ThreadTimelineReadingTarget?
    public var readingVisitId: JSONText?
    public var locatedRequestId: JSONText?
    public var onLocated: ((JSONText) -> Void)?
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.nativeReadingNavigation) private var readingNavigation
    @Environment(\.nativePerformanceOperation) private var performanceOperation
    @State private var previousReadingNavigation: NativeReadingNavigationState?
    @State private var readingSource = UUID()
    @State private var visibleCount = 120
    @State private var tailLength = 0
    @State private var following = false
    @State private var showLatest = false
    @State private var userPositioned = false
    @State private var userScrolling = false
    @State private var latestTransition: UUID?
    @State private var viewport = TimelineViewport()
    @State private var anchors: [JSONText: CGFloat] = [:]
    @State private var focusAnchors: [UUID] = []
    @State private var locatedRequest: JSONText?
    @State private var clampedRequest: JSONText?
    @State private var position = ScrollPosition(y: 0)
    @State private var prependSnapshot: TimelineGeometry?
    @State private var suspendedSnapshot: (top: CGFloat, following: Bool)?
    @FocusState private var focused: Bool

    public init(timelineKey: JSONText, documentKey: JSONText? = nil, rows: [ThreadTimelineRow], toolbar: AnyView? = nil,
                emptyState: AnyView? = nil, contentTopInset: CGFloat? = nil,
                suspended: Bool = false, followOutput: Bool = false, allowsJumpToLatest: Bool = true, opensAtBottom: Bool = false,
                followKey: JSONText? = nil, followPaused: Bool = false, onJumpToLatest: (() -> Void)? = nil,
                showOlderRows: Bool = true, pinnedRowId: JSONText? = nil,
                readingTarget: ThreadTimelineReadingTarget? = nil, readingVisitId: JSONText? = nil, locatedRequestId: JSONText? = nil,
                onLocated: ((JSONText) -> Void)? = nil) {
        self.timelineKey = timelineKey; self.documentKey = documentKey
        self.rows = rows; self.toolbar = toolbar; self.emptyState = emptyState
        self.contentTopInset = contentTopInset
        self.suspended = suspended; self.followOutput = followOutput; self.opensAtBottom = opensAtBottom; self.followKey = followKey
        self.allowsJumpToLatest = allowsJumpToLatest
        self.followPaused = followPaused; self.onJumpToLatest = onJumpToLatest
        self.showOlderRows = showOlderRows; self.pinnedRowId = pinnedRowId; self.readingTarget = readingTarget
        self.readingVisitId = readingVisitId; self.locatedRequestId = locatedRequestId; self.onLocated = onLocated
        _tailLength = State(initialValue: rows.count)
    }
    private var orderedRows: [ThreadTimelineRow] {
        rows.enumerated().sorted { a, b in
            a.element.createdAt == b.element.createdAt ? a.offset < b.offset : a.element.createdAt < b.element.createdAt
        }.map(\.element)
    }
    private var firstIndex: Int { max(0, rows.count - visibleCount - max(0, rows.count - tailLength)) }
    private var visibleRows: [ThreadTimelineRow] {
        let ordered = orderedRows
        let tail = Array(ordered.dropFirst(firstIndex))
        guard let pinnedRowId, let index = ordered.firstIndex(where: { $0.id == pinnedRowId }), index < firstIndex else { return tail }
        return [ordered[index]] + tail
    }
    private var geometry: TimelineGeometry { viewport.geometry }
    public var body: some View {
        let _ = TimelineConstructionProfile.record(1, context: performanceOperation)
        let visible = visibleRows
        ScrollViewReader { proxy in
            let _ = TimelineConstructionProfile.record(2, context: performanceOperation)
            GeometryReader { bounds in
                let _ = TimelineConstructionProfile.record(3, context: performanceOperation)
                NativeScrollView(.vertical) {
                    let _ = TimelineConstructionProfile.record(4, context: performanceOperation)
                    VStack(alignment: .leading, spacing: 0) {
                        Color.clear.frame(height: 0).id(TimelineEdge.top)
                        if showOlderRows && firstIndex > 0 {
                            Button(localize("显示更早的 {count} 条消息").replacingOccurrences(of: "{count}", with: String(min(100, firstIndex))), action: loadEarlier)
                            .nativeReadingAction("loadEarlier", role: "loadEarlier", label: localize("显示更早的消息"),
                                value: .integer(firstIndex), action: loadEarlier)
                            .buttonStyle(.plain).font(NativeTypography.inter(size: 11))
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(NativeAppKitPalette.thread.surface.swiftUI, in: RoundedRectangle(cornerRadius: 5))
                            .frame(maxWidth: .infinity).padding(.bottom, 24)
                        }
                        toolbar
                        if rows.isEmpty { emptyState }
                        // The bounded outer window is retained as a VStack: lazy rows carry their
                        // own scoped reads, and anchor registration must also work below the fold.
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(visible) { row in
                                row.node.threadReadingAnchor(row.id)
                                    .nativeReadingScope("row." + nativeReadingInteractionKey(row.id))
                            }
                        }.accessibilityElement(children: .contain)
                            .accessibilityLabel(localize("已加载消息"))
                        Color.clear.frame(height: 0).id(TimelineEdge.bottom)
                    }
                    .frame(maxWidth: NativeGeometry.readingWidth, alignment: .leading)
                    .nativeLayoutLog("timeline.reading.column")
                    .padding(.horizontal, bounds.size.width <= 540 ? 18 : 32)
                    .padding(.vertical, readingVerticalInset(bounds.size.width)).frame(maxWidth: .infinity)
                    .coordinateSpace(name: "thread-timeline-content")
                    .nativeLayoutLog("timeline.document")
                    .environment(\.nativeReadingPageCapacity, readingPageCapacity(bounds.size))
                    .background(TimelineDiagnosticsAttachment(active: !suspended, operation: performanceOperation).allowsHitTesting(false))
                }
                .scrollIndicators(.automatic)
                .scrollPosition($position)
                .focusable().focusEffectDisabled().focused($focused)
                .accessibilityLabel(localize("消息时间线"))
                .onScrollPhaseChange { _, phase in
                    userScrolling = phase == .interacting || phase == .decelerating
                    if phase == .tracking || userScrolling {
                        if latestTransition != nil { following = false }
                        userPositioned = true; clampedRequest = nil; latestTransition = nil
                    }
                    if userScrolling && !suspended && geometry.distance > 1 { following = false }
                }
                .onScrollGeometryChange(for: TimelineGeometry.self) {
                    TimelineGeometry(contentOffset: $0.contentOffset.y, insetTop: $0.contentInsets.top,
                        height: $0.contentSize.height, viewport: $0.containerSize.height)
                } action: { old, new in
                    TimelineConstructionProfile.record(5, context: performanceOperation)
                    viewport.geometry = new
                    reportReading()
                    guard !suspended else { return }
                    if let previous = prependSnapshot, new.height != previous.height {
                        prependSnapshot = nil
                        position.scrollTo(y: previous.top + new.height - previous.height)
                        return
                    }
                    if userScrolling {
                        if new.top < old.top { following = false }
                        else if new.distance <= 1 { following = !followPaused }
                    }
                    showLatest = new.distance >= 64
                    if (new.height != old.height || new.viewport != old.viewport) && following && !followPaused && followOutput && prependSnapshot == nil && latestTransition == nil {
                        position.scrollTo(edge: .bottom)
                    }
                    locate()
                }
                .onPreferenceChange(ThreadAnchorPreference.self) { value in
                    anchors = value
                    locate()
                }
                .onPreferenceChange(ThreadFocusPreference.self) { focusAnchors = $0 }
                .onChange(of: readingTarget) { _, _ in locate() }
                .onChange(of: readingVisitId ?? readingTarget?.requestId) { _, _ in
                    // A visit exists before its message/row anchor is projected.
                    // Anchor readiness alone must never undo a user's scroll.
                    userPositioned = false
                    if readingVisitId != nil || readingTarget != nil { latestTransition = nil }
                    locate()
                }
                .onChange(of: timelineKey, initial: true) { _, _ in
                    visibleCount = 120; tailLength = rows.count; userPositioned = false; latestTransition = nil
                    if readingTarget?.requestId != locatedRequestId || locatedRequestId == nil {
                        following = opensAtBottom && !followPaused; locatedRequest = nil; clampedRequest = nil
                        if following { position.scrollTo(edge: .bottom) }
                        else { position.scrollTo(y: 0) }
                        locate()
                    }
                }
                .onChange(of: followKey) { old, new in
                    if new != nil && new != old && !followPaused && !suspended && readingTarget == nil && readingVisitId == nil {
                        if opensAtBottom { openBottom() }
                        else { follow(proxy) }
                    }
                }
                .onChange(of: documentKey) { old, new in
                    guard old != nil, new != old, !suspended, !opensAtBottom,
                          readingTarget == nil, readingVisitId == nil else { return }
                    // The live execution can move to a Sidecard after its index
                    // arrives. Its bottom-follow state does not belong to the
                    // completed document left in main. Settlement alone keeps
                    // the same document key and must not reset the reader.
                    following = false; latestTransition = nil
                    if !userPositioned { position.scrollTo(y: 0) }
                }
                .onChange(of: opensAtBottom) { _, new in
                    if new && latestTransition == nil { openBottom() }
                }
                .onChange(of: followPaused) { old, new in
                    if new { following = false; latestTransition = nil }
                    else if old && !suspended && latestTransition == nil {
                        // A requested message may still be resolving its anchor.
                        // Generic follow must not take that visit's position.
                        if readingTarget != nil || readingVisitId != nil { locate() }
                        else if opensAtBottom {
                            userPositioned = false
                            openBottom()
                        } else { follow(proxy) }
                    }
                }
                .onChange(of: suspended) { _, new in
                    reportReading()
                    if new {
                        latestTransition = nil
                        suspendedSnapshot = (geometry.top, following)
                        following = false
                    } else {
                        if opensAtBottom && readingTarget == nil {
                            // Returning from a different execution is a new visit;
                            // growth while hidden must not restore an obsolete offset.
                            userPositioned = false
                            openBottom()
                            suspendedSnapshot = nil
                        } else if let previous = suspendedSnapshot {
                            position.scrollTo(y: previous.top)
                            following = previous.following && geometry.height - previous.top - geometry.viewport <= 1
                            showLatest = geometry.height - previous.top - geometry.viewport >= 64
                            suspendedSnapshot = nil
                        }
                        locate()
                    }
                }
                .onChange(of: readingNavigation.map(ObjectIdentifier.init), initial: true) { _, _ in
                    previousReadingNavigation?.remove(source: readingSource)
                    previousReadingNavigation = readingNavigation
                    reportReading()
                }
                .onChange(of: reduceMotion) { _, reduced in
                    guard reduced, latestTransition != nil else { return }
                    latestTransition = nil
                    if following && !followPaused && !suspended { alignToLatest() }
                }
                .onDisappear {
                    latestTransition = nil
                    previousReadingNavigation?.remove(source: readingSource)
                }
                .background { interactionRegistration(visible: visible) }
                .overlay(alignment: .bottom) {
                    if allowsJumpToLatest && followOutput && showLatest && !suspended {
                        Button { jumpToLatest() } label: {
                            NativeIcon(name: "ArrowDown", size: 13)
                                .frame(width: 42, height: 42).contentShape(Circle())
                        }.buttonStyle(.plain)
                            .glassEffect(.regular.interactive(), in: .circle)
                            .padding(.bottom, 16)
                            .accessibilityLabel(localize("回到最新"))
                            .help(localize("回到最新"))
                            .nativeReadingAction("jumpLatest", role: "jumpLatest", label: localize("回到最新")) { jumpToLatest() }
                    }
                }
            }
        }
    }
    private func interactionRegistration(visible: [ThreadTimelineRow]) -> some View {
        TimelineInteractionRegistration(viewport: viewport, label: localize("消息时间线"), enabled: !suspended,
            following: following, locatedRequest: locatedRequest, showLatest: showLatest,
            rowCount: rows.count, firstIndex: firstIndex, visibleRowIds: visible.map(\.id), showOlderRows: showOlderRows) { operation, value in
            guard let amount = value.numberValue, amount.isFinite, abs(amount) <= 10_000_000 else {
                throw NativeReadingControlError("invalid_request", "Scroll offset must be a finite number within 10000000 points")
            }
            let offset = operation == "scrollBy" ? Double(geometry.top) + amount : amount
            userPositioned = true; following = false; clampedRequest = nil; latestTransition = nil
            position.scrollTo(y: min(max(0, geometry.height - geometry.viewport), max(0, CGFloat(offset))))
        }
    }
    private func openBottom() {
        guard opensAtBottom, followOutput, !followPaused, !suspended, !userPositioned, readingTarget == nil else { return }
        following = true; showLatest = false
        position.scrollTo(edge: .bottom)
    }
    private func loadEarlier() {
        userPositioned = true; following = false; latestTransition = nil
        prependSnapshot = geometry
        visibleCount += 100 + max(0, rows.count - tailLength)
        tailLength = rows.count
    }
    private func jumpToLatest() {
        onJumpToLatest?(); following = true; showLatest = false; clampedRequest = nil; userPositioned = true
        let transition = UUID()
        latestTransition = transition
        // With no running application event loop (previews and isolated native
        // replays) an animated scroll cannot complete. The hosted graphical
        // suite declares itself an isolated AppKit replay so its content checks
        // settle immediately; the production app keeps the 350ms transition.
        let isolatedReplay = ProcessInfo.processInfo.environment["MOKUSEI_ISOLATED_APPKIT_REPLAY"] == "1"
        withAnimation(reduceMotion || isolatedReplay || NSApp?.isRunning != true ? nil : .easeInOut(duration: 0.35),
                      completionCriteria: .removed) {
            // An edge target follows content growth inside SwiftUI itself.
            // Animate to this snapshot instead, then admit ordinary following.
            position.scrollTo(y: max(0, geometry.height - geometry.viewport))
        } completion: {
            guard latestTransition == transition else { return }
            latestTransition = nil
            // Resolve any content growth that arrived during the transition.
            if following && !followPaused && !suspended { alignToLatest() }
        }
    }
    private func alignToLatest() {
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) { position.scrollTo(edge: .bottom) }
    }
    private func localize(_ value: String) -> String { NativePluginLocalization.localize(value, locale: locale) }

    /// One page is the content height actually visible under the timeline's
    /// symmetric document insets. A taller page would not be visible as a
    /// whole when it flushes; resizing must update padding and capacity together.
    private func readingPageCapacity(_ size: CGSize) -> CGFloat {
        max(0, size.height - 2 * readingVerticalInset(size.width))
    }

    private func readingVerticalInset(_ width: CGFloat) -> CGFloat {
        contentTopInset ?? (readingNavigation != nil ? 94 : width >= 1024 ? 24 : width <= 540 ? 28 : 44)
    }
    private func reportReading() {
        readingNavigation?.update(source: readingSource, scrollTop: geometry.top, active: !suspended)
    }
    private func locate() {
        // A fresh request resets userPositioned. Late anchors for that same
        // request must respect manual scrolling, including non-following visits.
        guard !suspended, let target = readingTarget, !userPositioned,
              (locatedRequest != target.requestId && locatedRequestId != target.requestId) || clampedRequest == target.requestId,
              geometry.height > 0, geometry.viewport > 0, let top = anchors[target.anchorId] else { return }
        following = target.follow && followOutput && !followPaused
        if following { clampedRequest = nil; position.scrollTo(edge: .bottom) }
        else {
            // Rich Markdown can still be empty when its row first mounts. Keep
            // a clamped location pending as the document grows, until it can
            // reach the anchor or the user takes over scrolling.
            clampedRequest = top > max(0, geometry.height - geometry.viewport) + 1 ? target.requestId : nil
            position.scrollTo(y: top)
        }
        if locatedRequest != target.requestId {
            locatedRequest = target.requestId
            onLocated?(target.requestId)
        }
        focused = true
    }
    private func follow(_ proxy: ScrollViewProxy) {
        guard followOutput else { return }
        if let attention = focusAnchors.first {
            following = false; proxy.scrollTo(attention, anchor: .top)
        } else {
            following = true; position.scrollTo(edge: .bottom)
        }
    }
}
