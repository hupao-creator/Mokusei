import AppKit
import QuartzCore
import SwiftUI

public extension EnvironmentValues {
    /// The owning reading stack has completed primary travel. Nested readers
    /// inherit this gate until their own stack supplies its completion state.
    @Entry var nativeReadingEntranceReady = true
}

/// Commit the initial, folded layout before admitting secondary motion. A reader
/// can first mount after primary travel, so an already-selected plugin must not
/// make its first rendered frame the expanded destination.
public struct NativeReadingEntranceStage: NSViewRepresentable {
    public let enabled: Bool
    public let onReady: () -> Void
    public init(enabled: Bool, onReady: @escaping () -> Void) {
        self.enabled = enabled; self.onReady = onReady
    }
    public func makeNSView(context: Context) -> StageView { StageView() }
    public func updateNSView(_ view: StageView, context: Context) {
        view.configure(enabled: enabled, onReady: onReady)
    }
    public static func dismantleNSView(_ view: StageView, coordinator: ()) {
        view.configure(enabled: false, onReady: {})
    }

    public final class StageView: NSView {
        private var enabled = false
        private var reported = false
        private var generation = 0
        private var onReady: (() -> Void)?
        public override func hitTest(_ point: NSPoint) -> NSView? { nil }
        public override func isAccessibilityElement() -> Bool { false }

        fileprivate func configure(enabled: Bool, onReady: @escaping () -> Void) {
            self.onReady = onReady
            if self.enabled != enabled {
                self.enabled = enabled; generation += 1; reported = false
            }
            if enabled && !reported { needsLayout = true }
        }
        public override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            generation += 1; reported = false
            if window != nil { needsLayout = true }
        }
        public override func layout() {
            super.layout()
            guard enabled, !reported, window != nil else { return }
            reported = true
            let token = generation
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, enabled, window != nil, generation == token else { return }
                    onReady?()
                }
            }
            CATransaction.commit()
        }
    }
}
