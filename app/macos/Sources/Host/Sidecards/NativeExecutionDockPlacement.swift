import AppKit
import MokuseiCore
import Observation
import SwiftUI

/// Reading panels host a separate SwiftUI tree, so preferences cannot reach the
/// resident Dock. Passive native markers convert destination geometry across
/// that hosting boundary, including workspace scaling and shell scrolling.
@MainActor @Observable
final class NativeExecutionDockPlacement {
    private(set) var frame: CGRect?
    private(set) var threadID: JSONText?
    private(set) var dragging = false
    private(set) var travelRevision = 0
    private(set) var continuing = false
    @ObservationIgnored private var route: UUID?
    @ObservationIgnored private var destinationReady = false
    @ObservationIgnored private var travelSettled = true
    @ObservationIgnored private weak var scene: NativeExecutionDockRegion.RegionView?
    @ObservationIgnored private weak var execution: NativeExecutionDockRegion.RegionView?
    @ObservationIgnored private var publicationPending = false

    func beginRoute(_ route: UUID, retaining frame: CGRect? = nil, threadID: JSONText? = nil,
                    continuing: Bool = false) {
        self.route = route
        self.frame = frame; self.threadID = threadID
        self.continuing = continuing
        destinationReady = false
        execution = nil; dragging = false
        travelRevision += 1; travelSettled = false
    }

    func attach(_ view: NativeExecutionDockRegion.RegionView) {
        guard view.isScene || view.route == route else { return }
        if view.isScene { scene = view }
        else {
            if execution !== view || !view.ready { destinationReady = false; travelSettled = false }
            execution = view
        }
        schedulePublication()
    }

    func detach(_ view: NativeExecutionDockRegion.RegionView) {
        if scene === view { scene = nil }
        if execution === view { execution = nil; destinationReady = false; travelSettled = false }
        schedulePublication()
    }

    func completeTravel(revision: Int) {
        guard revision == travelRevision else { return }
        guard execution?.ready == true else { return }
        travelSettled = true
        // A native layout publication may already be replacing this target.
        // Let that publication decide whether the new column needs travel.
        if !publicationPending, frame != nil || execution?.active == false {
            continuing = false
            execution?.onSettled()
        }
    }

    func schedulePublication() {
        guard !publicationPending else { return }
        publicationPending = true
        // AppKit must finish placing both hosting trees before conversion, and
        // observable writes must not occur inside SwiftUI's layout/update pass.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            publicationPending = false
            // Missing/unprepared markers belong to the gap between reading
            // hosts, not a destination at the workspace centre. Old retained
            // Report hosts cannot reclaim a newer route's placement.
            guard let execution, execution.route == route, execution.ready else { return }
            let next: CGRect?
            if execution.active {
                guard let scene, execution.window != nil, scene.window === execution.window else { return }
                next = scene.convert(execution.destination ?? execution.bounds, from: execution)
            } else { next = nil }
            let nextDragging = execution.dragging
            if dragging != nextDragging { dragging = nextDragging }
            let nextThread = next == nil ? nil : execution.threadID
            if !destinationReady || frame != next || threadID != nextThread {
                travelRevision += 1
                travelSettled = false
            }
            destinationReady = true
            if threadID != nextThread { threadID = nextThread }
            if frame != next { frame = next }
            if travelSettled, next != nil || !execution.active {
                continuing = false
                execution.onSettled()
            }
        }
    }
}

extension EnvironmentValues {
    @Entry var nativeExecutionDockPlacement: NativeExecutionDockPlacement? = nil
    @Entry var nativeExecutionDockRoute: UUID? = nil
}

struct NativeExecutionDockRegion: NSViewRepresentable {
    let placement: NativeExecutionDockPlacement?
    var isScene = false
    var active = true
    var ready = true
    var dragging = false
    var threadID: JSONText?
    var onSettled: () -> Void = {}
    var destination: CGRect?
    @Environment(\.nativeExecutionDockRoute) private var route

    func destinationFrame(_ frame: CGRect?) -> some View {
        var region = self
        // Keep the native marker at the workspace origin. A SwiftUI offset can
        // move via an ancestor transform without a native frame notification;
        // publishing the local destination explicitly also covers equal widths.
        region.destination = frame
        return region.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func makeNSView(context: Context) -> RegionView { RegionView(isScene: isScene) }
    func updateNSView(_ view: RegionView, context: Context) {
        if view.placement !== placement { view.placement?.detach(view) }
        view.placement = placement; view.active = active; view.dragging = dragging; view.threadID = threadID
        view.route = route; view.ready = ready
        view.destination = destination
        view.onSettled = onSettled
        placement?.attach(view)
    }
    static func dismantleNSView(_ view: RegionView, coordinator: ()) { view.placement?.detach(view) }

    @MainActor final class RegionView: NSView {
        let isScene: Bool
        weak var placement: NativeExecutionDockPlacement?
        var active = true
        var ready = true
        var route: UUID?
        var dragging = false
        var threadID: JSONText?
        var destination: CGRect?
        var onSettled: () -> Void = {}
        init(isScene: Bool) { self.isScene = isScene; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func layout() { super.layout(); placement?.schedulePublication() }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); placement?.schedulePublication() }
        override func setFrameOrigin(_ point: NSPoint) { super.setFrameOrigin(point); placement?.schedulePublication() }
        override func setFrameSize(_ size: NSSize) { super.setFrameSize(size); placement?.schedulePublication() }
    }
}
