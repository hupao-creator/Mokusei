import AppKit
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
    static let defaultValue: Set<JSONText> = []
    static func reduce(value: inout Set<JSONText>, nextValue: () -> Set<JSONText>) { value.formUnion(nextValue()) }
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
        self.id(id).preference(key: ThreadAnchorPreference.self, value: [id])
    }
    func threadTimelineFocus() -> some View { modifier(ThreadTimelineFocus()) }
}

public struct ThreadTimelineReadingTarget: Hashable, Sendable {
    public let requestId: JSONText
    public let anchorId: JSONText
    public init(requestId: JSONText, anchorId: JSONText) { self.requestId = requestId; self.anchorId = anchorId }
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

/// SwiftUI follows the user's global scroller preference, which can turn the
/// reading timeline into a wide, persistent legacy scrollbar. Keep this one
/// reading surface narrow and transient without replacing native scrolling.
private struct TimelineScrollerConfiguration: NSViewRepresentable {
    var active: Bool
    var operation: UInt64?
    func makeNSView(context: Context) -> TimelineScrollerConfigurationView {
        TimelineScrollerConfigurationView()
    }
    func updateNSView(_ view: TimelineScrollerConfigurationView, context: Context) {
        view.active = active
        view.operation = operation
        view.configure()
    }
    static func dismantleNSView(_ view: TimelineScrollerConfigurationView, coordinator: ()) { view.diagnostics.detach() }
}

@MainActor private final class TimelineScrollerConfigurationView: NSView {
    let diagnostics = TimelineScrollDiagnostics()
    var active = true
    var operation: UInt64?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); configure() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); configure() }

    func configure() {
        let scroll = window == nil ? nil : enclosingScrollView
        diagnostics.attach(to: scroll, enabled: active, context: operation)
        guard let scroll else { return }
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.verticalScroller?.controlSize = .mini
        scroll.horizontalScroller?.controlSize = .mini
    }
}


/// Bounded history window with explicit following. Opening a document starts at its heading.
public struct HarnessMessageTimeline: View {
    public let timelineKey: JSONText
    public let rows: [ThreadTimelineRow]
    public var toolbar: AnyView?
    public var emptyState: AnyView?
    public var suspended: Bool
    public var followOutput: Bool
    public var followKey: JSONText?
    public var followPaused: Bool
    public var onJumpToLatest: (() -> Void)?
    public var showOlderRows: Bool
    public var pinnedRowId: JSONText?
    public var readingTarget: ThreadTimelineReadingTarget?
    public var locatedRequestId: JSONText?
    public var onLocated: ((JSONText) -> Void)?
    @Environment(\.locale) private var locale
    @Environment(\.nativeReadingNavigation) private var readingNavigation
    @Environment(\.nativePerformanceOperation) private var performanceOperation
    @State private var previousReadingNavigation: NativeReadingNavigationState?
    @State private var readingSource = UUID()
    @State private var visibleCount = 120
    @State private var tailLength = 0
    @State private var following = false
    @State private var showLatest = false
    @State private var userScrolling = false
    @State private var geometry = TimelineGeometry(contentOffset: 0, insetTop: 0, height: 0, viewport: 0)
    @State private var anchors: Set<JSONText> = []
    @State private var focusAnchors: [UUID] = []
    @State private var locatedRequest: JSONText?
    @State private var position = ScrollPosition(y: 0)
    @State private var prependSnapshot: TimelineGeometry?
    @State private var suspendedSnapshot: (top: CGFloat, following: Bool)?
    @FocusState private var focused: Bool

    public init(timelineKey: JSONText, rows: [ThreadTimelineRow], toolbar: AnyView? = nil,
                emptyState: AnyView? = nil, suspended: Bool = false, followOutput: Bool = false,
                followKey: JSONText? = nil, followPaused: Bool = false, onJumpToLatest: (() -> Void)? = nil,
                showOlderRows: Bool = true, pinnedRowId: JSONText? = nil,
                readingTarget: ThreadTimelineReadingTarget? = nil, locatedRequestId: JSONText? = nil,
                onLocated: ((JSONText) -> Void)? = nil) {
        self.timelineKey = timelineKey; self.rows = rows; self.toolbar = toolbar; self.emptyState = emptyState
        self.suspended = suspended; self.followOutput = followOutput; self.followKey = followKey
        self.followPaused = followPaused; self.onJumpToLatest = onJumpToLatest
        self.showOlderRows = showOlderRows; self.pinnedRowId = pinnedRowId; self.readingTarget = readingTarget
        self.locatedRequestId = locatedRequestId; self.onLocated = onLocated
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
    public var body: some View {
        let _ = TimelineConstructionProfile.record(1, context: performanceOperation)
        ScrollViewReader { proxy in
            let _ = TimelineConstructionProfile.record(2, context: performanceOperation)
            GeometryReader { bounds in
                let _ = TimelineConstructionProfile.record(3, context: performanceOperation)
                ScrollView(.vertical) {
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
                            ForEach(visibleRows) { row in
                                row.node.threadReadingAnchor(row.id)
                                    .nativeReadingScope("row." + nativeReadingInteractionKey(row.id))
                            }
                        }.accessibilityElement(children: .contain)
                            .accessibilityLabel(localize("已加载消息"))
                        Color.clear.frame(height: 1).id(TimelineEdge.bottom)
                    }
                    .frame(maxWidth: NativeGeometry.readingWidth, alignment: .leading)
                    .padding(.horizontal, bounds.size.width <= 540 ? 18 : 32)
                    .padding(.top, readingNavigation != nil ? 94 : bounds.size.width >= 1024 ? 24 : bounds.size.width <= 540 ? 28 : 44)
                    .padding(.bottom, 36).frame(maxWidth: .infinity)
                    .background(TimelineScrollerConfiguration(active: !suspended, operation: performanceOperation).allowsHitTesting(false))
                }
                .scrollIndicators(.automatic)
                .scrollPosition($position)
                .focusable().focusEffectDisabled().focused($focused)
                .accessibilityLabel(localize("消息时间线"))
                .onScrollPhaseChange { _, phase in
                    userScrolling = phase == .interacting || phase == .decelerating
                    if userScrolling && !suspended { following = !followPaused && geometry.distance < 64 }
                }
                .onScrollGeometryChange(for: TimelineGeometry.self) {
                    TimelineGeometry(contentOffset: $0.contentOffset.y, insetTop: $0.contentInsets.top,
                        height: $0.contentSize.height, viewport: $0.containerSize.height)
                } action: { old, new in
                    TimelineConstructionProfile.record(5, context: performanceOperation)
                    geometry = new
                    reportReading()
                    guard !suspended else { return }
                    if let previous = prependSnapshot, new.height != previous.height {
                        prependSnapshot = nil
                        position.scrollTo(y: previous.top + new.height - previous.height)
                        return
                    }
                    if userScrolling { following = !followPaused && new.distance < 64 }
                    showLatest = new.distance >= 64
                    if new.height != old.height && following && !followPaused && followOutput && prependSnapshot == nil {
                        proxy.scrollTo(TimelineEdge.bottom, anchor: .bottom)
                    }
                }
                .onPreferenceChange(ThreadAnchorPreference.self) { value in
                    anchors = value
                    locate(proxy)
                }
                .onPreferenceChange(ThreadFocusPreference.self) { focusAnchors = $0 }
                .onChange(of: readingTarget) { _, _ in locate(proxy) }
                .onChange(of: timelineKey, initial: true) { _, _ in
                    visibleCount = 120; tailLength = rows.count; following = false; locatedRequest = nil
                    proxy.scrollTo(TimelineEdge.top, anchor: .top)
                    locate(proxy)
                }
                .onChange(of: followKey) { old, new in
                    if new != nil && new != old && !followPaused && !suspended { follow(proxy) }
                }
                .onChange(of: followPaused) { old, new in
                    if new { following = false }
                    else if old && !suspended { follow(proxy) }
                }
                .onChange(of: suspended) { _, new in
                    reportReading()
                    if new {
                        suspendedSnapshot = (geometry.top, following)
                        following = false
                    } else {
                        if let previous = suspendedSnapshot {
                            position.scrollTo(y: previous.top)
                            following = previous.following && geometry.height - previous.top - geometry.viewport <= 1
                            showLatest = geometry.height - previous.top - geometry.viewport >= 64
                            suspendedSnapshot = nil
                        }
                        locate(proxy)
                    }
                }
                .onChange(of: readingNavigation.map(ObjectIdentifier.init), initial: true) { _, _ in
                    previousReadingNavigation?.remove(source: readingSource)
                    previousReadingNavigation = readingNavigation
                    reportReading()
                }
                .onDisappear { previousReadingNavigation?.remove(source: readingSource) }
                .background(interactionRegistration)
                .overlay(alignment: .bottom) {
                    if followOutput && showLatest && !suspended {
                        Button { jumpToLatest(proxy) } label: {
                            HStack(spacing: 5) { NativeIcon(name: "ChevronDown", size: 13); Text(localize("回到最新")) }
                                .font(NativeTypography.inter(size: 11)).padding(.vertical, 6).padding(.horizontal, 10)
                                .background(NativeAppKitPalette.thread.canvas.swiftUI, in: RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(NativeAppKitPalette.thread.line.swiftUI))
                                .shadow(color: .black.opacity(0.07), radius: 3, y: 2)
                        }.buttonStyle(.plain).padding(.bottom, 16)
                            .nativeReadingAction("jumpLatest", role: "jumpLatest", label: localize("回到最新")) { jumpToLatest(proxy) }
                    }
                }
            }
        }
    }
    private var interactionRegistration: some View {
        NativeReadingControlRegistration(id: "timeline", descriptor: .object([
            "kind": .text("scroll"), "role": .text("timeline"), "label": .text(localize("消息时间线")),
            "enabled": .bool(!suspended), "operations": .array([.text("scrollTo"), .text("scrollBy")]),
            "value": .object([
                "top": .number(Double(geometry.top)), "height": .number(Double(geometry.height)),
                "contentOffset": .number(Double(geometry.contentOffset)), "insetTop": .number(Double(geometry.insetTop)),
                "viewport": .number(Double(geometry.viewport)), "following": .bool(following), "showLatest": .bool(showLatest),
                "rowCount": .integer(rows.count), "firstIndex": .integer(firstIndex), "visibleCount": .integer(visibleRows.count),
                "visibleRowIds": .array(visibleRows.map { .string($0.id) }), "showOlderRows": .bool(showOlderRows)
            ])
        ])) { operation, value in
            guard let amount = value.numberValue, amount.isFinite, abs(amount) <= 10_000_000 else {
                throw NativeReadingControlError("invalid_request", "Scroll offset must be a finite number within 10000000 points")
            }
            let offset = operation == "scrollBy" ? Double(geometry.top) + amount : amount
            following = false
            position.scrollTo(y: min(max(0, geometry.height - geometry.viewport), max(0, CGFloat(offset))))
        }
    }
    private func loadEarlier() {
        prependSnapshot = geometry
        visibleCount += 100 + max(0, rows.count - tailLength)
        tailLength = rows.count
    }
    private func jumpToLatest(_ proxy: ScrollViewProxy) {
        onJumpToLatest?(); following = true; showLatest = false
        proxy.scrollTo(TimelineEdge.bottom, anchor: .bottom)
    }
    private func localize(_ value: String) -> String { NativePluginLocalization.localize(value, locale: locale) }
    private func reportReading() {
        readingNavigation?.update(source: readingSource, scrollTop: geometry.top, active: !suspended)
    }
    private func locate(_ proxy: ScrollViewProxy) {
        guard !suspended, let target = readingTarget, locatedRequest != target.requestId, locatedRequestId != target.requestId,
              anchors.contains(target.anchorId) else { return }
        following = false
        proxy.scrollTo(target.anchorId, anchor: .top)
        locatedRequest = target.requestId
        onLocated?(target.requestId)
        focused = true
    }
    private func follow(_ proxy: ScrollViewProxy) {
        guard followOutput else { return }
        if let attention = focusAnchors.first {
            following = false; proxy.scrollTo(attention, anchor: .top)
        } else {
            following = true; proxy.scrollTo(TimelineEdge.bottom, anchor: .bottom)
        }
    }
}
