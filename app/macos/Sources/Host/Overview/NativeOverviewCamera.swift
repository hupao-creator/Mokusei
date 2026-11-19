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

    public static let zero = Self(left: 0, top: 0, width: 0, height: 0)
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
    /// Total seconds. A zero duration is a direct commit.
    public var duration: TimeInterval
    public var delay: TimeInterval
    /// Monotonic start time in seconds since boot.
    public var startedAt: TimeInterval
}

public enum NativeOverviewCameraGeometry {
    /// Explicit product zoom ceiling. Automatic FitAll respects it; the same
    /// ceiling bounds manual zoom so both paths share one declared limit.
    public static let scaleCap = NativeOverviewGeometryPolicy.standard.scaleCap ?? 1.0
    /// Cards keep at least their logical size in both manual and automatic views.
    public static let scaleFloor = 1.0
    public static let wheelZoomIntensity = 0.0015
    public static let motionDuration: TimeInterval = 0.36
    public static let motionFrameCount = 48
    /// Single product breakpoint for the compact tag bar and framing margin.
    public static let compactViewportWidth: Double = 620

    public static func contentRegion(_ viewport: NativeOverviewViewport) -> NativeOverviewContentRect {
        let top = min(max(0, viewport.toolbarBottom), viewport.height)
        let bottom = max(top, viewport.height - max(0, viewport.bottomReservedHeight))
        return .init(left: 0, top: top, width: max(0, viewport.width), height: bottom - top)
    }

    /// The persistent controls own their actual space. The remaining inset is
    /// a product margin around the collection, never a hidden fit floor.
    public static func framingRegion(_ viewport: NativeOverviewViewport) -> NativeOverviewContentRect {
        let margin = viewport.width <= compactViewportWidth ? 32.0 : 64.0
        let left = min(margin, viewport.width / 2)
        let content = contentRegion(viewport)
        let verticalMargin = min(content.height / 2, max(0, margin - viewport.bottomReservedHeight / 2))
        let top = content.top + verticalMargin
        return .init(left: left, top: top, width: max(0, viewport.width - 2 * left),
                     height: max(0, content.height - 2 * verticalMargin))
    }

    /// The Dock can place the usable center above the window center. Lower the
    /// automatic target by that difference while retaining the full packing area.
    static func automaticFramingRegion(_ viewport: NativeOverviewViewport) -> NativeOverviewContentRect {
        var region = framingRegion(viewport)
        region.top = max(region.top, (viewport.height - region.height) / 2)
        return region
    }

    /// Center the world rect, fitting only as far as the card scale floor allows.
    /// Nil means the caller has no finite, positive geometry to frame.
    public static func centeredTransform(content: NativeOverviewContentRect,
                                         usable: NativeOverviewContentRect,
                                         scaleCap: Double?) -> NativeOverviewTransform? {
        guard content.width > 0, content.height > 0,
              content.left.isFinite, content.top.isFinite,
              content.width.isFinite, content.height.isFinite,
              usable.left.isFinite, usable.top.isFinite,
              usable.width > 0, usable.height > 0,
              usable.width.isFinite, usable.height.isFinite else { return nil }
        let fit = min(usable.width / content.width, usable.height / content.height)
        guard fit.isFinite, fit > 0 else { return nil }
        let scale = max(scaleFloor, min(scaleCap ?? fit, fit))
        guard scale.isFinite, scale > 0 else { return nil }
        return .init(scale: scale,
                     x: usable.left + (usable.width - content.width * scale) / 2 - content.left * scale,
                     y: usable.top + (usable.height - content.height * scale) / 2 - content.top * scale)
    }

    public static func fit(_ content: NativeOverviewContentRect, viewport: NativeOverviewViewport,
                           scaleCap: Double? = NativeOverviewGeometryPolicy.standard.scaleCap) -> NativeOverviewTransform? {
        var usable = automaticFramingRegion(viewport)
        // At maximum workspace zoom the header and Dock can exhaust the packing
        // height. Frame the cards on the visible canvas so navigation can start.
        if usable.height == 0 {
            usable.top = 0
            usable.height = viewport.height
        }
        return centeredTransform(content: content, usable: usable, scaleCap: scaleCap)
    }

    public static func zoom(_ transform: NativeOverviewTransform, cursor: CGPoint, nextScale: Double,
                            minimumScale: Double = scaleFloor,
                            maximumScale: Double = scaleCap) -> NativeOverviewTransform {
        let maximum = maximumScale.isFinite ? max(scaleFloor, maximumScale) : scaleCap
        let minimum = minimumScale.isFinite ? min(maximum, max(scaleFloor, minimumScale)) : scaleFloor
        let scale = nextScale.isFinite ? min(maximum, max(minimum, nextScale)) : minimum
        guard scale != transform.scale else { return transform }
        guard transform.scale.isFinite, transform.scale > 0,
              transform.x.isFinite, transform.y.isFinite else {
            return .init(scale: scale, x: transform.x, y: transform.y)
        }
        let ratio = scale / transform.scale
        return .init(scale: scale, x: cursor.x - (cursor.x - transform.x) * ratio,
                     y: cursor.y - (cursor.y - transform.y) * ratio)
    }

    public static func pan(_ transform: NativeOverviewTransform, deltaX: Double, deltaY: Double) -> NativeOverviewTransform {
        .init(scale: transform.scale, x: transform.x + deltaX, y: transform.y + deltaY)
    }

    public static func isVisible(_ rect: NativeOverviewContentRect, transform: NativeOverviewTransform,
                                 viewport: NativeOverviewViewport) -> Bool {
        guard transform.scale.isFinite, transform.scale > 0,
              transform.x.isFinite, transform.y.isFinite else { return false }
        let left = transform.x + rect.left * transform.scale
        let top = transform.y + rect.top * transform.scale
        let region = framingRegion(viewport)
        return left + rect.width * transform.scale > region.left && top + rect.height * transform.scale > region.top
            && left < region.left + region.width && top < region.top + region.height
    }

    public static func approximatelyEqual(_ lhs: NativeOverviewTransform, _ rhs: NativeOverviewTransform) -> Bool {
        abs(lhs.x - rhs.x) < 0.001 && abs(lhs.y - rhs.y) < 0.001 && abs(lhs.scale - rhs.scale) < 0.000001
    }

    /// Sample quintic easing once, then play linear keyframe segments in the compositor.
    public static func move(from: NativeOverviewTransform, to: NativeOverviewTransform,
                            duration: TimeInterval = motionDuration, delay: TimeInterval = 0) -> [NativeOverviewCameraFrame] {
        var frames = [NativeOverviewCameraFrame(at: 0, transform: from)]
        for index in 0...motionFrameCount {
            let time = Double(index) / Double(motionFrameCount)
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

/// Single-writer camera with latest-wins automatic framing. Automatic targets
/// come from the same geometry snapshot as the layout; manual transforms are
/// user-owned and never replaced by background work.
@MainActor @Observable
public final class NativeOverviewCamera {
    public private(set) var manual = false
    public private(set) var isInitialized = false
    /// Committed target transform. Geometry and gestures use `liveTransform`
    /// while a track is playing.
    public private(set) var transform = NativeOverviewTransform.identity
    public private(set) var isAnimating = false
    @ObservationIgnored public private(set) var animationFrames: [NativeOverviewCameraFrame] = []
    @ObservationIgnored public var onSubmission: ((NativeOverviewCameraSubmission) -> Void)?
    @ObservationIgnored public var onFrameSubmission: ((NativeOverviewTransform, NativeOverviewTransform, TimeInterval, TimeInterval) -> Void)?
    @ObservationIgnored public var onChange: (() -> Void)?

    @ObservationIgnored private var geometry: Geometry?
    @ObservationIgnored private var visible = true
    @ObservationIgnored private var interactionPaused = false
    @ObservationIgnored private var pendingAutoFit = false
    @ObservationIgnored private var animationTask: Task<Void, Never>?
    @ObservationIgnored private var animationGeneration = 0
    @ObservationIgnored private var track: Track?

    private struct Geometry: Equatable {
        var content: NativeOverviewContentRect
        var viewport: NativeOverviewViewport
        var automatic: NativeOverviewTransform?
    }

    private struct Track {
        var frames: [NativeOverviewCameraFrame]
        var started: TimeInterval
    }

    public init() {}

    public var live: NativeOverviewCameraState? {
        guard isInitialized else { return nil }
        let displayed = track.map { NativeOverviewCameraGeometry.sample($0.frames, at: uptime - $0.started) } ?? transform
        // Motion samples own geometry, never camera ownership. A paused return
        // must retain the user's latest request for automatic framing.
        return .init(transform: displayed, manual: manual)
    }

    public var liveTransform: NativeOverviewTransform { isAnimating ? (live?.transform ?? transform) : transform }
    public var animationStartTime: TimeInterval? { track?.started }
    public var viewport: NativeOverviewViewport? { geometry?.viewport }
    public var minimumScale: Double { NativeOverviewCameraGeometry.scaleFloor }
    public var maximumScale: Double { NativeOverviewCameraGeometry.scaleCap }
    public var hasScheduledMotion: Bool { animationTask != nil }
    public var hasPendingAutomaticFit: Bool { pendingAutoFit }
    /// Explicit-return provenance for diagnostics; automatic framing is pending.
    public var returning: Bool { pendingAutoFit && !manual }
    public var automaticFitTarget: NativeOverviewTransform? { isInitialized ? geometry?.automatic : nil }
    public var automaticFitBlockReason: String? {
        guard pendingAutoFit else { return nil }
        if manual { return "manual" }
        if !visible { return "hidden" }
        if interactionPaused { return "interaction" }
        if geometry?.automatic == nil { return "unavailable" }
        return nil
    }

    /// Apply the geometry that belongs to one layout snapshot. A nonmanual
    /// camera retargets from the current displayed transform; a manual camera
    /// keeps its explicit transform.
    public func applyGeometry(content: NativeOverviewContentRect, viewport: NativeOverviewViewport,
                              automatic: NativeOverviewTransform?) {
        geometry = .init(content: content, viewport: viewport, automatic: automatic)
        guard isInitialized else {
            guard !manual, content.width > 0, content.height > 0, let automatic else { return }
            pendingAutoFit = false
            commit(.init(transform: automatic, manual: false))
            return
        }
        guard !manual else {
            pendingAutoFit = false
            return
        }
        guard content.width > 0, content.height > 0 else {
            pendingAutoFit = false
            stopMotion(commitSample: false)
            commit(nil)
            return
        }
        pendingAutoFit = true
        updateAuto()
    }

    public func cutTo(content: NativeOverviewContentRect, viewport: NativeOverviewViewport) {
        stopMotion(commitSample: false)
        let automatic = NativeOverviewCameraGeometry.fit(content, viewport: viewport)
        geometry = .init(content: content, viewport: viewport, automatic: automatic)
        pendingAutoFit = false
        guard content.width > 0, content.height > 0, let automatic else {
            commit(nil)
            return
        }
        commit(.init(transform: automatic, manual: false))
    }

    /// Cross-scene restores keep the 0.36s retarget animation for a saved
    /// automatic bookmark. The ordinary same-scene geometry path does not call
    /// this method and writes the current snapshot directly.
    public func restore(view: NativeOverviewCameraState, content: NativeOverviewContentRect,
                        viewport: NativeOverviewViewport) {
        stopMotion(commitSample: false)
        geometry = .init(content: content, viewport: viewport,
                         automatic: NativeOverviewCameraGeometry.fit(content, viewport: viewport))
        guard content.width > 0, content.height > 0 else { commit(nil); return }
        if view.manual {
            pendingAutoFit = false
            commit(.init(transform: constrained(view.transform), manual: true))
        } else {
            // Normalize the bookmark before it becomes an animation source.
            commit(.init(transform: constrained(view.transform), manual: false))
            pendingAutoFit = true
            updateAuto()
        }
    }

    public func setVisible(_ value: Bool) {
        guard visible != value else { return }
        visible = value
        if value {
            updateAuto()
        } else {
            stopMotion(commitSample: true)
            publish()
        }
    }

    public func setManualTransform(_ value: NativeOverviewTransform, anchor: CGPoint? = nil) {
        guard isInitialized else { return }
        stopMotion(commitSample: false)
        pendingAutoFit = false
        commit(.init(transform: constrained(value, anchor: anchor), manual: true))
    }

    public func zoom(deltaY: Double, cursor: CGPoint) {
        guard let live else { return }
        setManualTransform(NativeOverviewCameraGeometry.zoom(live.transform, cursor: cursor,
            nextScale: live.transform.scale * exp(-deltaY * NativeOverviewCameraGeometry.wheelZoomIntensity)),
            anchor: cursor)
    }

    public func pan(deltaX: Double, deltaY: Double) {
        guard let live else { return }
        let next = NativeOverviewCameraGeometry.pan(live.transform, deltaX: deltaX, deltaY: deltaY)
        guard next.x.isFinite, next.y.isFinite else { return }
        setManualTransform(next)
    }

    public func returnToAuto() {
        guard let geometry, isInitialized else { return }
        // Stop the old track at its displayed sample before choosing the new
        // automatic target. Otherwise an in-flight track could later commit an
        // obsolete destination after the target already matched this sample.
        stopMotion(commitSample: true)
        manual = false
        pendingAutoFit = true
        guard geometry.content.width > 0, geometry.content.height > 0 else {
            pendingAutoFit = false
            commit(nil)
            return
        }
        updateAuto()
        publish()
    }

    public func setInteractionPaused(_ paused: Bool) {
        guard interactionPaused != paused else { return }
        interactionPaused = paused
        if paused {
            stopMotion(commitSample: true)
            publish()
        } else {
            updateAuto()
        }
    }

    public func dispose() {
        stopMotion(commitSample: false)
        geometry = nil
        pendingAutoFit = false
        interactionPaused = false
        commit(nil)
    }

    private var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private var hasObservers: Bool {
        onChange != nil || onSubmission != nil || onFrameSubmission != nil
    }

    private func updateAuto() {
        guard let geometry, isInitialized, !manual else { return }
        guard geometry.content.width > 0, geometry.content.height > 0 else {
            pendingAutoFit = false
            stopMotion(commitSample: false)
            commit(nil)
            return
        }
        guard visible, !interactionPaused else { return }
        guard let target = geometry.automatic else {
            pendingAutoFit = true
            return
        }
        if NativeOverviewCameraGeometry.approximatelyEqual(transform, target) {
            // A new snapshot that resolves to the same target must not restart
            // its own in-flight motion.
            if isAnimating { pendingAutoFit = true; return }
            pendingAutoFit = false
            return
        }
        pendingAutoFit = true
        startAnimation(to: target)
    }

    private func startAnimation(to target: NativeOverviewTransform) {
        let from = liveTransform
        stopMotion(commitSample: false)
        let generation = animationGeneration
        if !hasObservers {
            finishAnimation(target: target, generation: generation)
            return
        }
        let started = uptime
        let frames = NativeOverviewCameraGeometry.move(from: from, to: target)
        track = Track(frames: frames, started: started)
        isAnimating = true
        transform = target
        animationFrames = frames
        onSubmission?(.init(from: from, to: target, frames: frames,
                            duration: NativeOverviewCameraGeometry.motionDuration, delay: 0, startedAt: started))
        onFrameSubmission?(from, target, NativeOverviewCameraGeometry.motionDuration, 0)
        publish()
        animationTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(NativeOverviewCameraGeometry.motionDuration))
            } catch {
                return
            }
            guard let self, !Task.isCancelled, self.animationGeneration == generation else { return }
            self.finishAnimation(target: target, generation: generation)
        }
    }

    private func finishAnimation(target: NativeOverviewTransform, generation: Int) {
        guard animationGeneration == generation else { return }
        animationTask?.cancel()
        animationTask = nil
        track = nil
        isAnimating = false
        animationFrames = []
        if !manual, pendingAutoFit, geometry?.automatic == target {
            pendingAutoFit = false
        }
        commit(.init(transform: target, manual: manual))
    }

    /// Stop the current track. Sampling is synchronous, so callers can start a
    /// newer target from the actual displayed state in the same interval.
    private func stopMotion(commitSample: Bool) {
        animationGeneration += 1
        animationTask?.cancel()
        animationTask = nil
        let sample = live
        track = nil
        isAnimating = false
        animationFrames = []
        if commitSample, let sample {
            transform = sample.transform
        }
    }

    private func constrained(_ value: NativeOverviewTransform, anchor: CGPoint? = nil) -> NativeOverviewTransform {
        let region = geometry.map { NativeOverviewCameraGeometry.framingRegion($0.viewport) }
        let pivot = anchor ?? CGPoint(x: region.map { $0.left + $0.width / 2 } ?? 0,
                                      y: region.map { $0.top + $0.height / 2 } ?? 0)
        return NativeOverviewCameraGeometry.zoom(value, cursor: pivot, nextScale: value.scale,
                                                  minimumScale: minimumScale, maximumScale: maximumScale)
    }

    private func commit(_ next: NativeOverviewCameraState?) {
        let previousTransform = liveTransform
        transform = next?.transform ?? .identity
        manual = next?.manual ?? false
        isInitialized = next != nil
        animationFrames = []
        onSubmission?(.init(from: previousTransform, to: transform,
                            frames: [.init(at: 0, transform: transform)], duration: 0, delay: 0, startedAt: uptime))
        onFrameSubmission?(previousTransform, transform, 0, 0)
        publish()
    }

    private func publish() {
        onChange?()
    }
}
