import CoreGraphics
import Foundation
import MokuseiPluginUI

/// One central "is this card inside the canvas viewport" decision.
///
/// A card used to read its own camera-transformed geometry: every camera update
/// re-ran a geometry callback per card, and each callback fed a viewport
/// intersection back into the card's environment, so a pan invalidated layout
/// once per card. Registrations here carry the card's *world-space* rect — the
/// frame measured before the camera transform — and this type decides for all of
/// them, writing only the handles whose answer actually changed.
///
/// The judgment region stays the whole canvas, which is what the replaced
/// per-card probe used. `NativeOverviewCameraGeometry.isVisible` deliberately
/// is not reused: it frames content inside the toolbar/Dock-inset region and is
/// the overflow-attention criterion, not the animation gate.
@MainActor
final class NativeOverviewCardVisibility {
    private struct Entry {
        var rect: CGRect
        var handle: ThreadCardAnimationVisibility
        var canvasVisible: Bool
        var published: Bool?
    }

    private weak var camera: NativeOverviewCamera?
    private var entries: [UUID: Entry] = [:]
    /// Rect reported before its card registered. A geometry callback can arrive
    /// ahead of `onAppear`; dropping it would leave the handle unpublished.
    private var pendingRects: [UUID: CGRect] = [:]
    private var viewport = CGSize.zero
    private var canvasVisible = true
    private var generation = UUID()
    private var lastTransform = NativeOverviewTransform.identity
    /// Distance a pure translation may travel before any rect can cross an edge.
    private var nearestEdge = (x: Double.infinity, y: Double.infinity)
    private var sampler: Timer?

    func activate(camera: NativeOverviewCamera, viewport: CGSize, canvasVisible: Bool) {
        self.camera = camera
        self.viewport = viewport
        self.canvasVisible = canvasVisible
        self.generation = UUID()
        entries.removeAll()
        pendingRects.removeAll()
        lastTransform = camera.liveTransform
        nearestEdge = (.infinity, .infinity)
    }

    func deactivate() {
        stopSampling()
        entries.removeAll()
        camera = nil
        generation = UUID()
    }

    func register(token: UUID, handle: ThreadCardAnimationVisibility) {
        let rect = pendingRects.removeValue(forKey: token) ?? .null
        entries[token] = Entry(rect: rect, handle: handle, canvasVisible: canvasVisible, published: nil)
        evaluate(camera?.liveTransform ?? lastTransform, force: true)
    }

    func unregister(token: UUID) {
        entries.removeValue(forKey: token)
        pendingRects.removeValue(forKey: token)
        nearestEdge = (.infinity, .infinity)
    }

    func updateRect(token: UUID, rect: CGRect) {
        guard var entry = entries[token] else { pendingRects[token] = rect; return }
        guard entry.rect != rect else { return }
        entry.rect = rect
        // Only a real geometry change can move an edge; re-derive the thresholds.
        entry.published = nil
        entries[token] = entry
        nearestEdge = (.infinity, .infinity)
        evaluate(camera?.liveTransform ?? lastTransform, force: true)
    }

    func setCanvasVisible(_ value: Bool) {
        guard canvasVisible != value else { return }
        canvasVisible = value
        for token in entries.keys { entries[token]?.canvasVisible = value; entries[token]?.published = nil }
        evaluate(camera?.liveTransform ?? lastTransform, force: true)
    }

    func setViewport(_ size: CGSize) {
        guard viewport != size else { return }
        viewport = size
        nearestEdge = (.infinity, .infinity)
        evaluate(camera?.liveTransform ?? lastTransform, force: true)
    }

    /// Called for every camera intent and for each sampled animation frame.
    func presentationChanged(_ transform: NativeOverviewTransform) {
        evaluate(transform, force: false)
        if camera?.isAnimating == true { startSampling() }
    }

    private func startSampling() {
        guard sampler == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        sampler = timer
    }

    private func stopSampling() {
        sampler?.invalidate()
        sampler = nil
    }

    /// Intermediate camera frames are not published as intents, so a running
    /// automatic motion is sampled; sampling stops with the motion.
    private func sample() {
        guard let camera else { stopSampling(); return }
        guard camera.isAnimating else { stopSampling(); return }
        evaluate(camera.liveTransform, force: false)
    }

    private func evaluate(_ transform: NativeOverviewTransform, force: Bool) {
        guard transform.scale > 0 else { return }
        let translation = abs(transform.x - lastTransform.x) < nearestEdge.x
            && abs(transform.y - lastTransform.y) < nearestEdge.y
        if !force, translation, transform.scale == lastTransform.scale {
            lastTransform = transform
            return
        }
        var nearestX = Double.infinity
        var nearestY = Double.infinity
        let scale = transform.scale
        for (token, entry) in entries {
            guard !entry.rect.isNull else { continue }
            let visible = canvasVisible && intersects(entry.rect, transform: transform, scale: scale)
            if entry.published != visible {
                entry.handle.isVisible = visible
                entries[token]?.published = visible
            }
            // A rect is visible in x while tx is inside (-maxX·s, width - minX·s).
            let lowX = -entry.rect.maxX * scale
            let highX = viewport.width - entry.rect.minX * scale
            let lowY = -entry.rect.maxY * scale
            let highY = viewport.height - entry.rect.minY * scale
            nearestX = min(nearestX, abs(transform.x - lowX), abs(transform.x - highX))
            nearestY = min(nearestY, abs(transform.y - lowY), abs(transform.y - highY))
        }
        lastTransform = transform
        nearestEdge = (nearestX, nearestY)
    }

    private func intersects(_ rect: CGRect, transform: NativeOverviewTransform, scale: Double) -> Bool {
        let minX = rect.minX * scale + transform.x
        let maxX = rect.maxX * scale + transform.x
        let minY = rect.minY * scale + transform.y
        let maxY = rect.maxY * scale + transform.y
        return maxX > 0 && minX < viewport.width && maxY > 0 && minY < viewport.height
    }
}
