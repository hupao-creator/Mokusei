import AppKit
import SwiftUI

/// Stage policy for the Force Touch voice entrance.
///
/// AppKit numbers pressure stages from the initial mouse-down:
/// - stage 0: no press / gesture ended
/// - stage 1: an ordinary click has reached the trackpad's pressure floor
/// - stage 2: the deep "Force Click" stage
///
/// `stage` is intentionally used instead of a raw pressure threshold. The
/// pressure value is normalized for the current device and the user's trackpad
/// setting, while stage 2 is the SDK's semantic Force Click boundary. A raw
/// threshold would therefore fire differently on different Macs.
struct NativeForceTouchVoiceTrigger: Equatable {
    enum Outcome: Equatable {
        case idle
        case started
        case duplicate
        case unavailable
    }

    /// macOS NSPressureBehavior.primaryDeepClick is the only primary behavior
    /// with two stages (Apple's NSEvent.h documents 1 -> 2 -> 1 -> 0). The
    /// prompt's `.primaryClick` behavior has one stage only (1 -> 0) and can
    /// never publish a stage 2, so it cannot implement a Force Touch entrance.
    static let forceStage = 2
    private(set) var firedForCurrentPress = false

    /// Returns `.started` at most once per physical press. A press remains
    /// deduplicated while the user holds at stage 2; stage 0 or mouse-up starts
    /// a new press. `canStart` folds in voice availability, the active call
    /// state and the disabled route.
    mutating func handle(stage: Int, canStart: Bool) -> Outcome {
        if stage <= 0 {
            firedForCurrentPress = false
            return .idle
        }
        guard stage >= Self.forceStage else { return .idle }
        guard !firedForCurrentPress else { return .duplicate }
        guard canStart else { return .unavailable }
        firedForCurrentPress = true
        return .started
    }

    /// The monitor calls this on mouse-up so a press that never delivered a
    /// final stage-0 event still cannot leak its one-shot into the next click.
    mutating func pressEnded() { firedForCurrentPress = false }
}

/// Observes Force Touch pressure without consuming mouse events. The view is a
/// zero-interaction member of the Moku hierarchy: `hitTest` returns nil, so
/// clicking, dragging, text editing, context menus and window drags keep their
/// normal AppKit/SwiftUI paths. `isInside` narrows the local monitor to the
/// Moku capsule or the history composer that owns this view.
struct NativeMokuForceTouchVoiceMonitor: NSViewRepresentable {
    var isActive: () -> Bool
    var isInside: (CGPoint) -> Bool
    var canStart: () -> Bool
    var start: () -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.update(isActive: isActive, isInside: isInside, canStart: canStart, start: start)
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.update(isActive: isActive, isInside: isInside, canStart: canStart, start: start)
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) { view.stop() }

    @MainActor final class MonitorView: NSView {
        private var monitor: Any?
        private var trigger = NativeForceTouchVoiceTrigger()
        private var suppressMouseUp = false
        private var configuration: NSPressureConfiguration?
        private var installedConfiguration = false
        private var isActive: () -> Bool = { false }
        private var isInside: (CGPoint) -> Bool = { _ in false }
        private var canStart: () -> Bool = { false }
        private var start: () -> Void = {}

        // Match the flipped SwiftUI scene so the published capsule rectangles
        // and the monitor's local point use the same coordinate system.
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func update(isActive: @escaping () -> Bool, isInside: @escaping (CGPoint) -> Bool,
                    canStart: @escaping () -> Bool, start: @escaping () -> Void) {
            self.isActive = isActive; self.isInside = isInside
            self.canStart = canStart; self.start = start
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            installPressureConfiguration()
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.pressure, .leftMouseDown, .leftMouseUp]) { [weak self] event in
                let swallow = MainActor.assumeIsolated {
                    guard let self else { return false }
                    return self.handle(event)
                }
                return swallow ? nil : event
            }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { stop() }
            super.viewWillMove(toWindow: newWindow)
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            if installedConfiguration, window?.contentView?.pressureConfiguration === configuration {
                window?.contentView?.pressureConfiguration = nil
            }
            installedConfiguration = false
            configuration = nil
            trigger.pressEnded()
            suppressMouseUp = false
        }

        private func installPressureConfiguration() {
            // PrimaryDeepClick is the two-stage Force Click behavior. Deep
            // click disables stage 2 as soon as a drag starts, so a press-and-
            // drag on the composer keeps its existing text selection behavior.
            let configuration = NSPressureConfiguration(pressureBehavior: .primaryDeepClick)
            self.configuration = configuration
            pressureConfiguration = configuration
            guard let content = window?.contentView else { return }
            // Leave an explicit configuration owned by another AppKit view
            // alone. A nil value uses the system's default deep-click behavior;
            // setting it here makes the Moku entrance independent of that
            // default and documents the behavior on the hosting view itself.
            guard content.pressureConfiguration == nil else { return }
            content.pressureConfiguration = configuration
            installedConfiguration = true
        }

        private func handle(_ event: NSEvent) -> Bool {
            guard event.window === window, !isHiddenOrHasHiddenAncestor else { return false }
            switch event.type {
            case .leftMouseDown:
                // A new press always begins a new one-shot window, even if the
                // previous mouse-up was delivered to another application.
                trigger.pressEnded()
                return false
            case .pressure:
                let point = convert(event.locationInWindow, from: nil)
                let outcome = receive(stage: Int(event.stage), at: point)
                if ProcessInfo.processInfo.environment["MOKUSEI_FORCE_TOUCH_LOG"] == "1" {
                    print("[moku-force-touch] stage=\(event.stage) point=\(point) outcome=\(outcome)")
                }
                // Once the deep stage belongs to Moku voice, also keep it away
                // from the text system's own Force Click lookup. Stage 1 and
                // out-of-region pressure events keep their normal path.
                return outcome != .idle
            case .leftMouseUp:
                let suppress = suppressMouseUp
                suppressMouseUp = false
                trigger.pressEnded()
                // A Force Touch already performed the voice action. Swallow
                // the release so a SwiftUI Button under the same press cannot
                // additionally submit, open its menu or run a double-click
                // action. Text-field focus happened on mouse-down and remains.
                return suppress
            default:
                return false
            }
        }

        /// Test seam for the stage policy and the monitor's wiring. Production
        /// calls it from the `.pressure` event monitor with `event.stage`.
        @discardableResult
        func receive(stage: Int, at point: CGPoint) -> NativeForceTouchVoiceTrigger.Outcome {
            guard isActive(), !isHiddenOrHasHiddenAncestor, bounds.contains(point), isInside(point) else {
                return .idle
            }
            let outcome = trigger.handle(stage: stage, canStart: canStart())
            if outcome == .started {
                suppressMouseUp = true
                start()
            }
            return outcome
        }
    }
}
