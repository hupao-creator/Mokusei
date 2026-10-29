import Foundation
import Observation

public struct NativeOverviewTransform: Codable, Equatable, Sendable {
    public var scale: Double
    public var x: Double
    public var y: Double

    public init(scale: Double = 1, x: Double = 0, y: Double = 0) {
        self.scale = scale
        self.x = x
        self.y = y
    }

    public static let identity = Self()
}

public struct NativeOverviewContentRect: Codable, Equatable, Sendable {
    public var left: Double
    public var top: Double
    public var width: Double
    public var height: Double

    public init(left: Double, top: Double, width: Double, height: Double) {
        self.left = left
        self.top = top
        self.width = width
        self.height = height
    }
}

public struct NativeOverviewViewport: Equatable, Sendable {
    public var width: Double
    public var height: Double
    public var toolbarBottom: Double
    public var bottomReservedHeight: Double

    public init(width: Double, height: Double, toolbarBottom: Double = 0, bottomReservedHeight: Double = 0) {
        self.width = width
        self.height = height
        self.toolbarBottom = toolbarBottom
        self.bottomReservedHeight = bottomReservedHeight
    }
}

public struct NativeOverviewCameraState: Equatable, Sendable {
    public var transform: NativeOverviewTransform
    public var manual: Bool

    public init(transform: NativeOverviewTransform, manual: Bool) {
        self.transform = transform
        self.manual = manual
    }
}

public struct NativeOverviewCarouselCard: Equatable, Sendable {
    public var id: String
    public var rect: NativeOverviewContentRect
    public var eligible: Bool

    public init(id: String, rect: NativeOverviewContentRect, eligible: Bool) {
        self.id = id
        self.rect = rect
        self.eligible = eligible
    }
}

/// One runtime bookmark belongs to the host; switching collections replaces it.
@MainActor
public final class NativeOverviewCameraMemory {
    public var current: (sceneKey: String, view: NativeOverviewCameraState)?

    public init(current: (sceneKey: String, view: NativeOverviewCameraState)? = nil) {
        self.current = current
    }
}

public struct NativeOverviewCameraFrame: Equatable, Sendable {
    /// Seconds from submission, including the optional initial hold.
    public var at: TimeInterval
    public var scale: Double
    public var x: Double
    public var y: Double

    public init(at: TimeInterval, transform: NativeOverviewTransform) {
        self.at = at
        scale = transform.scale
        x = transform.x
        y = transform.y
    }

    public var transform: NativeOverviewTransform { .init(scale: scale, x: x, y: y) }
}

/// A prepared camera track is sampled by the SwiftUI transform wrapper.
public struct NativeOverviewCameraSubmission: Sendable {
    public var from: NativeOverviewTransform
    public var to: NativeOverviewTransform
    public var frames: [NativeOverviewCameraFrame]
    /// Total seconds, including delay. A zero duration is a direct/cancelled write.
    public var duration: TimeInterval
    public var delay: TimeInterval
    /// Monotonic start time in seconds since boot.
    public var startedAt: TimeInterval
}

public enum NativeOverviewCameraGeometry {
    public static let scaleFloor = 0.85
    public static let scaleMaximum = 1.7
    public static let readableCellBudget = 16.0
    private static let standardCellArea = 376.0 * 216.0
    public static let wheelZoomIntensity = 0.0015

    public static func contentRegion(_ viewport: NativeOverviewViewport) -> NativeOverviewContentRect {
        let top = min(max(0, viewport.toolbarBottom), viewport.height)
        let bottom = max(top, viewport.height - max(0, viewport.bottomReservedHeight))
        return .init(left: 0, top: top, width: max(0, viewport.width), height: bottom - top)
    }

    public static func framingRegion(_ viewport: NativeOverviewViewport) -> NativeOverviewContentRect {
        let margin = viewport.width <= 620 ? 32.0 : 64.0
        let left = min(margin, viewport.width / 2)
        let content = contentRegion(viewport)
        // The persistent Dock consumes the existing vertical padding budget.
        // Center the remaining breathing room between controls instead of
        // reserving the Dock on top of two full margins and shrinking cards.
        let verticalMargin = min(content.height / 2, max(0, margin - viewport.bottomReservedHeight / 2))
        let top = content.top + verticalMargin
        return .init(left: left, top: top, width: max(0, viewport.width - 2 * left),
                     height: max(0, content.height - 2 * verticalMargin))
    }

    /// Limit the readable world area, rather than hiding a fixed number of cards.
    /// Partial cards at the viewport edges may extend beyond this cell budget.
    public static func minimumScale(in viewport: NativeOverviewViewport) -> Double {
        let region = framingRegion(viewport)
        let area = region.width * region.height
        guard area.isFinite, area > 0 else { return scaleFloor }
        return max(scaleFloor, sqrt(area / (readableCellBudget * standardCellArea)))
    }

    public static func maximumScale(minimumScale: Double = scaleFloor) -> Double {
        let minimum = minimumScale.isFinite ? max(scaleFloor, minimumScale) : scaleFloor
        return max(scaleMaximum, minimum * 2)
    }

    public static func clampScale(_ scale: Double, minimumScale: Double = scaleFloor) -> Double {
        let minimum = minimumScale.isFinite ? max(scaleFloor, minimumScale) : scaleFloor
        let maximum = maximumScale(minimumScale: minimum)
        guard scale.isFinite else { return maximum }
        return min(maximum, max(minimum, scale))
    }

    public static func wholeSceneFitScale(_ content: NativeOverviewContentRect, viewport: NativeOverviewViewport) -> Double {
        guard hasGeometry(content, viewport: viewport) else { return 1 }
        let region = framingRegion(viewport)
        return min(region.width / content.width, region.height / content.height)
    }

    public static func fitsAtReadingScale(_ content: NativeOverviewContentRect, viewport: NativeOverviewViewport) -> Bool {
        wholeSceneFitScale(content, viewport: viewport) + 1e-6 >= minimumScale(in: viewport)
    }

    /// Framing margins are preferred breathing room, not occlusion. Carousel
    /// admission asks whether a translation can show the whole collection
    /// between persistent controls at readable scale, independent of the camera.
    static func fitsInViewportAtReadingScale(_ content: NativeOverviewContentRect,
                                            viewport: NativeOverviewViewport) -> Bool {
        guard hasGeometry(content, viewport: viewport) else { return false }
        let scale = minimumScale(in: viewport)
        let region = contentRegion(viewport)
        return content.width * scale <= region.width + 1e-6
            && content.height * scale <= region.height + 1e-6
    }

    /// Collection fitting, retained filters and attention share the center of
    /// the region between persistent controls. Overflow stays symmetric.
    static func framingTransform(_ content: NativeOverviewContentRect,
                                 viewport: NativeOverviewViewport,
                                 scale: Double) -> NativeOverviewTransform {
        guard hasGeometry(content, viewport: viewport), scale.isFinite, scale > 0 else { return .identity }
        let region = framingRegion(viewport)
        let remainingHeight = region.height - content.height * scale
        return .init(scale: scale,
                     x: region.left + (region.width - content.width * scale) / 2 - content.left * scale,
                     y: region.top + remainingHeight / 2 - content.top * scale)
    }

    /// Keep the retained reading scale, clamped to the destination viewport's
    /// readable range, and move a repacked collection to the shared framing
    /// anchor. A tag filter can change the packed footprint; a frozen
    /// translation would leave the narrower result anchored to the old scene's
    /// edge instead of the usable viewport.
    ///
    /// Clamping matters when the viewport changes in the same frame as the
    /// filter: the retained scale can be outside the new readable range, and
    /// retained framing suppresses the refit that would otherwise correct it.
    public static func recenter(content: NativeOverviewContentRect,
                                viewport: NativeOverviewViewport,
                                scale: Double) -> NativeOverviewTransform? {
        guard hasGeometry(content, viewport: viewport), scale.isFinite, scale > 0 else { return nil }
        let clamped = clampScale(scale, minimumScale: minimumScale(in: viewport))
        return framingTransform(content, viewport: viewport, scale: clamped)
    }

    public static func fit(_ content: NativeOverviewContentRect, viewport: NativeOverviewViewport,
                           minimumScale: Double = scaleFloor) -> NativeOverviewTransform {
        guard hasGeometry(content, viewport: viewport) else { return .identity }
        let minimum = max(minimumScale, self.minimumScale(in: viewport))
        // Preferred margins can yield to readability; the controls' actual
        // region remains the hard capacity boundary used by the carousel.
        let naturalScale = min(wholeSceneFitScale(content, viewport: viewport), max(1, minimum))
        let scale = clampScale(naturalScale, minimumScale: minimum)
        return framingTransform(content, viewport: viewport, scale: scale)
    }

    /// Project the old translation onto the range that keeps the collection
    /// visible. This is the least screen movement at unchanged reading scale;
    /// capacity loss still uses the normal readable fit policy.
    public static func preservingReadingPosition(_ transform: NativeOverviewTransform,
                                                 content: NativeOverviewContentRect,
                                                 viewport: NativeOverviewViewport) -> NativeOverviewTransform {
        let region = framingRegion(viewport)
        let scale = transform.scale
        // A scale derived by division can overshoot the same edge by an ULP
        // when multiplied back. Do not turn that into a visible recenter.
        guard scale >= minimumScale(in: viewport),
              content.width * scale <= region.width + 1e-6, content.height * scale <= region.height + 1e-6 else {
            return fit(content, viewport: viewport)
        }
        return .init(scale: scale,
                     x: max(region.left - content.left * scale,
                            min(region.left + region.width - (content.left + content.width) * scale, transform.x)),
                     y: max(region.top - content.top * scale,
                            min(region.top + region.height - (content.top + content.height) * scale, transform.y)))
    }

    public static func zoom(_ transform: NativeOverviewTransform, cursor: CGPoint, nextScale: Double,
                            minimumScale: Double = scaleFloor) -> NativeOverviewTransform {
        let scale = clampScale(nextScale, minimumScale: minimumScale)
        guard scale != transform.scale else { return transform }
        guard transform.scale.isFinite, transform.scale > 0 else {
            return .init(scale: scale, x: transform.x, y: transform.y)
        }
        let ratio = scale / transform.scale
        return .init(scale: scale, x: cursor.x - (cursor.x - transform.x) * ratio,
                     y: cursor.y - (cursor.y - transform.y) * ratio)
    }

    public static func pan(_ transform: NativeOverviewTransform, deltaX: Double, deltaY: Double) -> NativeOverviewTransform {
        .init(scale: transform.scale, x: transform.x + deltaX, y: transform.y + deltaY)
    }

    /// Center a card at an existing reading scale without resizing it. The
    /// carousel steps with translation only; keeping the scale stable avoids a
    /// zoom pulse on every card. Cards near the content edge may therefore
    /// leave blank space beyond the scene: exact centering is the contract, so
    /// this deliberately does not clamp to the content bounds.
    public static func centeredTransform(for rect: NativeOverviewContentRect,
                                         viewport: NativeOverviewViewport,
                                         scale: Double) -> NativeOverviewTransform? {
        let region = framingRegion(viewport)
        guard region.width > 0, region.height > 0,
              hasGeometry(rect, viewport: viewport), scale.isFinite, scale > 0 else { return nil }
        return framingTransform(rect, viewport: viewport, scale: scale)
    }

    public static func isVisible(_ rect: NativeOverviewContentRect, transform: NativeOverviewTransform,
                                 viewport: NativeOverviewViewport) -> Bool {
        let left = transform.x + rect.left * transform.scale
        let top = transform.y + rect.top * transform.scale
        let region = framingRegion(viewport)
        return left + rect.width * transform.scale > region.left && top + rect.height * transform.scale > region.top
            && left < region.left + region.width && top < region.top + region.height
    }

    public static func needsRefit(_ content: NativeOverviewContentRect, viewport: NativeOverviewViewport,
                                  transform: NativeOverviewTransform, minimumScale: Double = scaleFloor) -> Bool {
        guard hasGeometry(content, viewport: viewport) else { return false }
        let ideal = fit(content, viewport: viewport, minimumScale: minimumScale)
        if abs(ideal.scale - transform.scale) < 1e-6 && abs(ideal.x - transform.x) < 1 && abs(ideal.y - transform.y) < 1 { return false }
        let region = framingRegion(viewport)
        let left = transform.x + content.left * transform.scale
        let top = transform.y + content.top * transform.scale
        if left < region.left - 1 || top < region.top - 1
            || left + content.width * transform.scale > region.left + region.width + 1
            || top + content.height * transform.scale > region.top + region.height + 1 { return true }
        return ideal.scale - transform.scale > 0.08 || abs(ideal.x - transform.x) > region.width * 0.1
            || abs(ideal.y - transform.y) > region.height * 0.1
    }

    public static func hasGeometry(_ content: NativeOverviewContentRect, viewport: NativeOverviewViewport) -> Bool {
        content.width > 0 && content.height > 0 && viewport.width > 0 && viewport.height > 0
    }

    public static func approximatelyEqual(_ lhs: NativeOverviewTransform, _ rhs: NativeOverviewTransform) -> Bool {
        abs(lhs.x - rhs.x) < 0.001 && abs(lhs.y - rhs.y) < 0.001 && abs(lhs.scale - rhs.scale) < 0.000001
    }

    /// Sample quintic easing once, then play linear keyframe segments in the compositor.
    public static func move(from: NativeOverviewTransform, to: NativeOverviewTransform,
                            duration: TimeInterval, delay: TimeInterval = 0) -> [NativeOverviewCameraFrame] {
        var frames = [NativeOverviewCameraFrame(at: 0, transform: from)]
        for index in 0...48 {
            let time = Double(index) / 48
            let progress = 1 - pow(1 - time, 5)
            frames.append(.init(at: delay + time * duration, transform: interpolate(from, to, progress: progress)))
        }
        return frames
    }

    public static func sample(_ frames: [NativeOverviewCameraFrame], at: TimeInterval) -> NativeOverviewTransform {
        guard !frames.isEmpty else { return .identity }
        var index = 0
        while index + 1 < frames.count && frames[index + 1].at <= at { index += 1 }
        let from = frames[index]
        guard index + 1 < frames.count else { return from.transform }
        let to = frames[index + 1]
        let progress = max(0, min(1, (at - from.at) / (to.at - from.at)))
        return interpolate(from.transform, to.transform, progress: progress)
    }

    private static func interpolate(_ from: NativeOverviewTransform, _ to: NativeOverviewTransform,
                                     progress: Double) -> NativeOverviewTransform {
        .init(scale: from.scale + (to.scale - from.scale) * progress,
              x: from.x + (to.x - from.x) * progress, y: from.y + (to.y - from.y) * progress)
    }
}

/// Single-writer camera with prepared motion and sampled cancellation.
@MainActor @Observable
public final class NativeOverviewCamera {
    public private(set) var manual = false
    public private(set) var returning = false
    public private(set) var carouselTargetID: String?
    public private(set) var carouselPaused = false
    public private(set) var isInitialized = false

    /// Target transform. Geometry and gestures must use `liveTransform` during motion.
    public private(set) var transform = NativeOverviewTransform.identity
    @ObservationIgnored public private(set) var animationFrames: [NativeOverviewCameraFrame] = []
    @ObservationIgnored public var onSubmission: ((NativeOverviewCameraSubmission) -> Void)?
    @ObservationIgnored public var onFrameSubmission: ((NativeOverviewTransform, NativeOverviewTransform, TimeInterval, TimeInterval) -> Void)?
    @ObservationIgnored public var onChange: (() -> Void)?
    @ObservationIgnored public var stageCoordinator: NativeOverviewStageCoordinator?

    @ObservationIgnored private var state: NativeOverviewCameraState?
    public private(set) var isAnimating = false
    @ObservationIgnored private var track: Track? { didSet { isAnimating = track != nil } }
    @ObservationIgnored private var animationTask: Task<Void, Never>?
    @ObservationIgnored private var animationOwner: Owner?
    public var reduceMotion = false
    @ObservationIgnored private var readingFit: NativeOverviewTransform?
    @ObservationIgnored private var refitTask: Task<Void, Never>?
    @ObservationIgnored private var carouselTask: Task<Void, Never>?
    @ObservationIgnored private var animationGeneration = 0
    @ObservationIgnored private var returnEpoch = 0
    @ObservationIgnored private var carouselEpoch = 0
    @ObservationIgnored private var visible = true
    @ObservationIgnored private var lastRefitAt = -Double.infinity
    @ObservationIgnored private var bounds: (content: NativeOverviewContentRect, viewport: NativeOverviewViewport)?
    @ObservationIgnored private var framingRevision = 0
    @ObservationIgnored private var framedRevision = 0
    @ObservationIgnored private var carouselCards: [NativeOverviewCarouselCard] = []
    @ObservationIgnored private var carouselActive = false
    @ObservationIgnored private var carouselIndex = 0
    @ObservationIgnored private var carouselDeadline: TimeInterval?
    @ObservationIgnored private var carouselMoving = false
    @ObservationIgnored private var interactionPaused = false
    @ObservationIgnored private var environmentDeferred = false
    @ObservationIgnored private var framingRetained = false
    @ObservationIgnored private var pendingAutoFit = false
    /// Time each attention card stays centered before the carousel advances.
    /// Internal so tests can exercise several steps without waiting full beats.
    @ObservationIgnored var carouselDwell: TimeInterval = 5

    private enum Owner: String {
        case returning = "restore-auto"
        case refit = "throttled-refit"
        case carousel
        case returnAuto = "return-auto"
    }
    private struct Track {
        var frames: [NativeOverviewCameraFrame]
        var started: TimeInterval
    }

    public init() {}

    public var live: NativeOverviewCameraState? {
        guard var state else { return nil }
        if let track { state.transform = NativeOverviewCameraGeometry.sample(track.frames, at: ProcessInfo.processInfo.systemUptime - track.started) }
        return state
    }

    public var animationStartTime: TimeInterval? { track?.started }

    public var liveTransform: NativeOverviewTransform { isAnimating ? (live?.transform ?? transform) : transform }

    public var minimumScale: Double {
        bounds.map { NativeOverviewCameraGeometry.minimumScale(in: $0.viewport) } ?? NativeOverviewCameraGeometry.scaleFloor
    }
    public var maximumScale: Double { NativeOverviewCameraGeometry.maximumScale(minimumScale: minimumScale) }
    public var viewport: NativeOverviewViewport? { bounds?.viewport }
    /// A track is created only after stage acquisition. Callers waiting for an
    /// applied camera intent must also observe queued work and deferred fitting.
    public var hasScheduledMotion: Bool { animationTask != nil || refitTask != nil || returning }
    public var hasPendingAutomaticFit: Bool { pendingAutoFit }
    public var automaticFitTarget: NativeOverviewTransform? { state == nil ? nil : fit() }
    public var automaticFitBlockReason: String? {
        guard pendingAutoFit else { return nil }
        if !visible { return "hidden" }
        if interactionPaused { return "interaction" }
        if environmentDeferred { return "layout" }
        if framingRetained { return "retained-framing" }
        if returning { return "restoring" }
        return nil
    }

    public func reconcileBounds(content: NativeOverviewContentRect, viewport: NativeOverviewViewport) {
        setBounds(content: content, viewport: viewport)
        guard NativeOverviewCameraGeometry.hasGeometry(content, viewport: viewport) else { dispose(); return }
        if state == nil { cutTo(content: content, viewport: viewport) }
        else { constrainManualState() }
    }

    public func cutTo(content: NativeOverviewContentRect, viewport: NativeOverviewViewport) {
        resetActivity()
        setBounds(content: content, viewport: viewport)
        framedRevision = framingRevision
        commit(NativeOverviewCameraGeometry.hasGeometry(content, viewport: viewport) ? .init(transform: fit(), manual: false) : nil)
    }

    /// Keep the sampled screen positions across a compact filter repack. The
    /// next layout/viewport change or explicit camera action resumes auto policy.
    ///
    /// Changed content or viewport bounds are recentered in the framing region
    /// at the retained scale, clamped to the destination viewport's readable
    /// range. A manual pan or zoom is explicit user framing and is never moved
    /// automatically.
    public func retainFraming(content: NativeOverviewContentRect, viewport: NativeOverviewViewport) {
        guard let view = live else { cutTo(content: content, viewport: viewport); return }
        let framingChanged = bounds.map { $0.content != content || $0.viewport != viewport } ?? true
        pendingAutoFit = false
        stopCarousel()
        cancelReturn()
        cancelMotion()
        clearRefit()
        setBounds(content: content, viewport: viewport)
        framingRetained = true
        var retained = view
        if framingChanged, !view.manual,
           let recentered = NativeOverviewCameraGeometry.recenter(content: content, viewport: viewport,
                                                                  scale: view.transform.scale) {
            retained = .init(transform: recentered, manual: false)
        }
        commit(retained)
    }

    public func restore(view: NativeOverviewCameraState, content: NativeOverviewContentRect, viewport: NativeOverviewViewport) {
        dispose()
        setBounds(content: content, viewport: viewport)
        guard NativeOverviewCameraGeometry.hasGeometry(content, viewport: viewport) else { return }
        returning = !view.manual
        commit(.init(transform: constrained(view.transform), manual: view.manual))
        if !view.manual { scheduleReturn() }
    }

    public func setVisible(_ value: Bool) {
        guard visible != value else { return }
        visible = value
        if !value {
            suspendCarousel(resetDwell: true)
            let wasReturning = returning
            cancelReturn()
            returning = wasReturning
            clearRefit()
            cancelMotion()
        } else if returning { scheduleReturn() }
        else if let bounds { requestRefit(content: bounds.content, viewport: bounds.viewport) }
        publish()
    }

    public func setManualTransform(_ value: NativeOverviewTransform, anchor: CGPoint? = nil) {
        framingRetained = false
        pendingAutoFit = false
        stopCarousel()
        cancelReturn()
        cancelMotion()
        clearRefit()
        guard state != nil else { return }
        commit(.init(transform: constrained(value, anchor: anchor), manual: true))
    }

    public func zoom(deltaY: Double, cursor: CGPoint) {
        guard let live else { return }
        setManualTransform(NativeOverviewCameraGeometry.zoom(live.transform, cursor: cursor,
            nextScale: live.transform.scale * exp(-deltaY * NativeOverviewCameraGeometry.wheelZoomIntensity),
            minimumScale: minimumScale), anchor: cursor)
    }

    public func pan(deltaX: Double, deltaY: Double) {
        guard let live else { return }
        let next = NativeOverviewCameraGeometry.pan(live.transform, deltaX: deltaX, deltaY: deltaY)
        guard next.x.isFinite, next.y.isFinite else { return }
        setManualTransform(next)
    }

    public func returnToAuto() {
        guard let bounds else { return }
        returnToAuto(content: bounds.content, viewport: bounds.viewport)
    }

    public func returnToAuto(content: NativeOverviewContentRect, viewport: NativeOverviewViewport) {
        readingFit = nil
        framingRetained = false
        stopCarousel()
        clearRefit()
        cancelReturn()
        cancelMotion()
        setBounds(content: content, viewport: viewport)
        guard var state else { return }
        state.manual = false
        pendingAutoFit = true
        commit(state)
        environmentDeferred = false
        updateAuto()
    }

    public func setCarouselCards(_ cards: [NativeOverviewCarouselCard]) {
        if let index = carouselCards.firstIndex(where: { $0.id == carouselTargetID }) { carouselIndex = index }
        carouselCards = cards
        updateAuto()
    }

    public func setInteractionPaused(_ paused: Bool) {
        guard interactionPaused != paused else { return }
        interactionPaused = paused
        suspendCarousel(resetDwell: true)
        if paused {
            cancelReturn()
            clearRefit()
            cancelMotion()
        }
        publish()
        if !paused { updateAuto() }
    }

    public func requestRefit(content: NativeOverviewContentRect, viewport: NativeOverviewViewport, layoutChanged: Bool = false,
                             preserveFraming: Bool = false, preserveReadingPosition: Bool = false) {
        setBounds(content: content, viewport: viewport)
        if layoutChanged {
            framingRetained = false
            // A following footprint revision must not turn an unfinished insert,
            // restore or automatic return into a retained intermediate position.
            // Consecutive reading-preserving revisions keep their intended target,
            // even when the preceding translation has not finished playing.
            let readingPosition = readingFit ?? (framedRevision == framingRevision ? live?.transform : nil)
            readingFit = preserveReadingPosition && live?.manual == false && !returning
                && !pendingAutoFit && !carouselActive ? readingPosition.map {
                NativeOverviewCameraGeometry.preservingReadingPosition($0, content: content, viewport: viewport)
            } : nil
        }
        if preserveFraming { framingRetained = true }
        if layoutChanged { framingRevision += 1 }
        // A retained filter view is an intentional settled target, so a later
        // local footprint edit may preserve its reading position too.
        if preserveFraming { framedRevision = framingRevision }
        environmentDeferred = false
        constrainManualState()
        updateAuto()
    }

    public func deferRefit() {
        environmentDeferred = true
        suspendCarousel(resetDwell: false)
        clearRefit()
        if animationOwner == .refit { cancelMotion() }
    }

    public func dispose() {
        resetActivity()
        carouselCards = []
        commit(nil)
    }

    private func resetActivity() {
        readingFit = nil
        framingRetained = false
        pendingAutoFit = false
        stopCarousel()
        interactionPaused = false
        environmentDeferred = false
        cancelReturn()
        cancelMotion()
        clearRefit()
    }

    private func setBounds(content: NativeOverviewContentRect, viewport: NativeOverviewViewport) {
        if let bounds, bounds.content != content || bounds.viewport != viewport { framingRetained = false }
        if let previous = bounds?.viewport, previous != viewport { framingRevision += 1; readingFit = nil }
        bounds = (content, viewport)
    }

    private func constrained(_ value: NativeOverviewTransform, anchor: CGPoint? = nil) -> NativeOverviewTransform {
        let region = bounds.map { NativeOverviewCameraGeometry.framingRegion($0.viewport) }
        let pivot = anchor ?? CGPoint(x: region.map { $0.left + $0.width / 2 } ?? 0,
                                      y: region.map { $0.top + $0.height / 2 } ?? 0)
        return NativeOverviewCameraGeometry.zoom(value, cursor: pivot, nextScale: value.scale,
                                                  minimumScale: minimumScale)
    }

    private func constrainManualState() {
        guard var current = live, current.manual else { return }
        let next = constrained(current.transform)
        guard next != current.transform else { return }
        current.transform = next
        commit(current)
    }

    private func fit() -> NativeOverviewTransform {
        guard let bounds else { return .identity }
        return readingFit ?? NativeOverviewCameraGeometry.fit(bounds.content, viewport: bounds.viewport)
    }

    private func scheduleReturn() {
        guard visible, returning else { return }
        let epoch = returnEpoch
        let due = ProcessInfo.processInfo.systemUptime + 0.6
        // Target preparation follows stage acquisition, after the mounting transaction
        // supplies its cards. Waiting for another owner consumes the absolute hold.
        animate(to: {
            // Entering attention keeps the scene's reading scale and only
            // translates, matching every later carousel step.
            if let first = self.carouselCards.first(where: \.eligible), let bounds = self.bounds,
               self.state != nil,
               !NativeOverviewCameraGeometry.fitsInViewportAtReadingScale(bounds.content, viewport: bounds.viewport) {
                let fitted = NativeOverviewCameraGeometry.fit(bounds.content, viewport: bounds.viewport)
                return NativeOverviewCameraGeometry.centeredTransform(
                    for: first.rect, viewport: bounds.viewport, scale: fitted.scale) ?? fitted
            }
            return self.fit()
        }, owner: .returning, due: due) { [weak self] completed in
            guard let self, self.returnEpoch == epoch else { return }
            self.returning = false
            self.publish()
            if completed, let bounds = self.bounds { self.requestRefit(content: bounds.content, viewport: bounds.viewport) }
        }
    }

    private func cancelReturn() {
        returnEpoch += 1
        returning = false
    }

    private func updateAuto() {
        guard let bounds, let live, !live.manual, !returning, visible, !interactionPaused, !environmentDeferred, !framingRetained else { return }
        if let owner = animationOwner, owner != .refit && owner != .carousel { return }
        if pendingAutoFit {
            // Explicit return restores the browsing origin even if a carousel
            // card is already visible at the manually displaced position.
            // Keep the request until completion so temporary pauses can retry it.
            animate(to: { self.fit() }, owner: .returnAuto) { [weak self] completed in
                guard let self, completed else { return }
                self.pendingAutoFit = false
                self.updateAuto()
            }
            return
        }
        if reconcileCarousel() { return }
        let framingChanged = framingRevision != framedRevision
        if readingFit != nil && NativeOverviewCameraGeometry.approximatelyEqual(live.transform, fit()) {
            clearRefit()
            framedRevision = framingRevision
            return
        }
        if (!framingChanged || NativeOverviewCameraGeometry.approximatelyEqual(live.transform, fit()))
            && !NativeOverviewCameraGeometry.needsRefit(bounds.content, viewport: bounds.viewport, transform: live.transform) {
            clearRefit()
            framedRevision = framingRevision
            if animationOwner == .refit { cancelMotion() }
            return
        }
        // Content/carousel facts can arrive faster than the refit delay. Keep
        // admitted work on its deadline instead of debouncing it indefinitely.
        // The queued move resolves the latest bounds after stage acquisition;
        // a playing move reconciles newer framing revisions on completion.
        guard refitTask == nil, animationOwner != .refit else { return }
        let delay = max(0.160, lastRefitAt + 0.600 - ProcessInfo.processInfo.systemUptime)
        let deadline = ProcessInfo.processInfo.systemUptime + delay
        refitTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, deadline - ProcessInfo.processInfo.systemUptime))) } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.refitTask = nil
            guard self.state != nil, !self.manual, !self.interactionPaused, self.visible, !self.environmentDeferred else { return }
            self.lastRefitAt = ProcessInfo.processInfo.systemUptime
            self.animate(to: { self.fit() }, owner: .refit)
        }
    }

    private func reconcileCarousel() -> Bool {
        guard let bounds, state != nil else { return false }
        let eligible = carouselCards.filter(\.eligible)
        let fitsWholeScene = NativeOverviewCameraGeometry.fitsInViewportAtReadingScale(bounds.content, viewport: bounds.viewport)
        if carouselActive && fitsWholeScene { stopCarousel() }
        if !carouselActive {
            guard !fitsWholeScene, !eligible.isEmpty else { return false }
            carouselActive = true
        }
        clearRefit()
        if animationOwner == .refit { cancelMotion() }
        var current = carouselCards.first { $0.id == carouselTargetID }
        let expired = carouselDeadline.map { ProcessInfo.processInfo.systemUptime >= $0 } ?? false
        if current == nil || (expired && (current?.eligible == false || eligible.count > 1)) {
            let index = current.flatMap { card in carouselCards.firstIndex { $0.id == card.id }.map { $0 + 1 } } ?? carouselIndex
            let pivot = min(index, carouselCards.count)
            let ordered = Array(carouselCards.dropFirst(pivot)) + Array(carouselCards.prefix(pivot))
            current = ordered.first(where: \.eligible)
            guard let current else { stopCarousel(); return false }
            suspendCarousel(resetDwell: true)
            carouselTargetID = current.id
            carouselIndex = carouselCards.firstIndex { $0.id == current.id } ?? 0
            publish()
        }
        guard let current else { return false }
        if carouselMoving { return true }
        // Steps translate the current reading scale; the card center goes to
        // the usable viewport center even when the card is wider or taller
        // than that region.
        let target = NativeOverviewCameraGeometry.centeredTransform(
            for: current.rect, viewport: bounds.viewport, scale: liveTransform.scale) ?? liveTransform
        if NativeOverviewCameraGeometry.approximatelyEqual(liveTransform, target) {
            framedRevision = framingRevision
            scheduleCarouselDwell()
            return true
        }
        suspendCarousel(resetDwell: false)
        carouselMoving = true
        let epoch = carouselEpoch
        let id = current.id
        animate(to: {
            guard let card = self.carouselCards.first(where: { $0.id == id }), let bounds = self.bounds else { return target }
            return NativeOverviewCameraGeometry.centeredTransform(
                for: card.rect, viewport: bounds.viewport, scale: self.liveTransform.scale) ?? target
        }, owner: .carousel) { [weak self] completed in
            guard let self, self.carouselEpoch == epoch else { return }
            self.carouselMoving = false
            if completed {
                self.scheduleCarouselDwell()
                self.updateAuto()
            }
        }
        return true
    }

    private func scheduleCarouselDwell() {
        guard carouselActive, !manual, !interactionPaused, visible, !environmentDeferred else { return }
        if carouselDeadline == nil { carouselDeadline = ProcessInfo.processInfo.systemUptime + carouselDwell }
        guard carouselTask == nil, let deadline = carouselDeadline, deadline > ProcessInfo.processInfo.systemUptime else { return }
        carouselTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(max(0.001, deadline - ProcessInfo.processInfo.systemUptime))) } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.carouselTask = nil
            self.updateAuto()
        }
    }

    private func suspendCarousel(resetDwell: Bool) {
        carouselEpoch += 1
        carouselMoving = false
        carouselTask?.cancel()
        carouselTask = nil
        if resetDwell { carouselDeadline = nil }
        if animationOwner == .carousel { cancelMotion() }
    }

    private func stopCarousel() {
        guard carouselActive || carouselMoving || carouselTask != nil || carouselTargetID != nil else { return }
        suspendCarousel(resetDwell: true)
        carouselActive = false
        carouselTargetID = nil
        carouselIndex = 0
        publish()
    }

    private func animate(to targetForBounds: @escaping @MainActor () -> NativeOverviewTransform,
                         owner: Owner, due: TimeInterval? = nil,
                         completion: ((Bool) -> Void)? = nil) {
        clearRefit()
        cancelMotion()
        guard state != nil, !manual, !interactionPaused, visible else { completion?(false); return }
        let generation = animationGeneration
        // Queued owners count too: deferRefit and interactions must cancel a camera
        // reservation before it is granted, not only an already-playing track.
        animationOwner = owner
        animationTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled, let self, self.animationGeneration == generation else { return }
            var stage: NativeOverviewStageLease?
            var completed = false
            var revision = self.framingRevision
            defer {
                let owned = self.animationGeneration == generation
                if owned {
                    if !completed, let sampled = self.live, self.track != nil {
                        self.track = nil
                        self.commit(sampled)
                    }
                    self.animationTask = nil
                    self.animationOwner = nil
                    if completed { self.framedRevision = revision }
                }
                // Release before callbacks can schedule a following move or layout.
                stage?.release()
                if owned { completion?(completed) }
                if self.animationGeneration == generation, completed,
                   self.framedRevision != self.framingRevision { self.updateAuto() }
            }
            do {
                if let coordinator = self.stageCoordinator {
                    stage = try await coordinator.acquire(owner: "camera:\(owner.rawValue)")
                }
                try Task.checkCancellation()
                guard self.animationGeneration == generation, self.state != nil,
                      !self.manual, !self.interactionPaused, self.visible else { return }
                let from = self.liveTransform
                let target = targetForBounds()
                revision = self.framingRevision
                if NativeOverviewCameraGeometry.approximatelyEqual(from, target), due == nil {
                    completed = true
                    return
                }
                if self.reduceMotion {
                    self.commit(.init(transform: target, manual: false))
                    completed = true
                    return
                }
                let started = ProcessInfo.processInfo.systemUptime
                let delay = max(0, (due ?? started) - started)
                let motionDuration = 0.360
                let duration = motionDuration + delay
                let frames = NativeOverviewCameraGeometry.move(from: from, to: target, duration: motionDuration, delay: delay)
                // An attached SwiftUI canvas observes camera changes directly;
                // submission callbacks are optional diagnostics.
                guard self.onChange != nil || self.onSubmission != nil || self.onFrameSubmission != nil else {
                    self.commit(.init(transform: target, manual: self.manual))
                    completed = true
                    return
                }
                self.track = Track(frames: frames, started: started)
                self.transform = target
                self.animationFrames = frames
                self.onSubmission?(.init(from: from, to: target, frames: frames, duration: duration, delay: delay, startedAt: started))
                self.onFrameSubmission?(from, target, motionDuration, delay)
                try await Task.sleep(for: .seconds(max(0, started + duration - ProcessInfo.processInfo.systemUptime)))
                try Task.checkCancellation()
                guard self.animationGeneration == generation else { return }
                self.track = nil
                self.commit(.init(transform: target, manual: self.manual))
                completed = true
            } catch {
                // Cancellation releases both an in-flight effect and a queued lease;
                // the generation guard keeps old completions out of the new owner.
            }
        }
    }

    private func cancelMotion() {
        animationGeneration += 1
        animationTask?.cancel()
        animationTask = nil
        animationOwner = nil
        guard let live, track != nil else { return }
        track = nil
        commit(live)
    }

    private func clearRefit() {
        refitTask?.cancel()
        refitTask = nil
    }

    private func commit(_ next: NativeOverviewCameraState?) {
        let previousTransform = liveTransform
        state = next
        transform = next?.transform ?? .identity
        manual = next?.manual ?? false
        isInitialized = next != nil
        animationFrames = []
        onSubmission?(.init(from: previousTransform, to: transform,
                            frames: [.init(at: 0, transform: transform)], duration: 0, delay: 0, startedAt: ProcessInfo.processInfo.systemUptime))
        onFrameSubmission?(previousTransform, transform, 0, 0)
        publish()
    }

    private func publish() {
        carouselPaused = carouselActive && interactionPaused
        onChange?()
    }
}
