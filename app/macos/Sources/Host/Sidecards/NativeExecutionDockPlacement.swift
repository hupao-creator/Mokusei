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
    @ObservationIgnored private weak var scene: NativeExecutionDockRegion.RegionView?
    @ObservationIgnored private weak var execution: NativeExecutionDockRegion.RegionView?
    @ObservationIgnored private var publicationPending = false

    func attach(_ view: NativeExecutionDockRegion.RegionView) {
        if view.isScene { scene = view } else { execution = view }
        schedulePublication()
    }

    func detach(_ view: NativeExecutionDockRegion.RegionView) {
        if scene === view { scene = nil }
        if execution === view { execution = nil }
        schedulePublication()
    }

    func schedulePublication() {
        guard !publicationPending else { return }
        publicationPending = true
        // AppKit must finish placing both hosting trees before conversion, and
        // observable writes must not occur inside SwiftUI's layout/update pass.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            publicationPending = false
            let next: CGRect?
            if let scene, let execution, execution.active, execution.window != nil,
               scene.window === execution.window {
                next = scene.convert(execution.bounds, from: execution)
            } else { next = nil }
            let nextDragging = execution?.dragging == true
            if dragging != nextDragging { dragging = nextDragging }
            let nextThread = next == nil ? nil : execution?.threadID
            if threadID != nextThread { threadID = nextThread }
            if frame != next { frame = next }
        }
    }
}

extension EnvironmentValues {
    @Entry var nativeExecutionDockPlacement: NativeExecutionDockPlacement? = nil
}

struct NativeExecutionDockRegion: NSViewRepresentable {
    let placement: NativeExecutionDockPlacement?
    var isScene = false
    var active = true
    var dragging = false
    var threadID: JSONText?

    func makeNSView(context: Context) -> RegionView { RegionView(isScene: isScene) }
    func updateNSView(_ view: RegionView, context: Context) {
        if view.placement !== placement { view.placement?.detach(view) }
        view.placement = placement; view.active = active; view.dragging = dragging; view.threadID = threadID
        placement?.attach(view)
    }
    static func dismantleNSView(_ view: RegionView, coordinator: ()) { view.placement?.detach(view) }

    @MainActor final class RegionView: NSView {
        let isScene: Bool
        weak var placement: NativeExecutionDockPlacement?
        var active = true
        var dragging = false
        var threadID: JSONText?
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
