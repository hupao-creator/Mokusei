import AppKit
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
@testable import MokuseiUI

@MainActor @Suite(.serializedNative, .serialized)
struct NativeForceTouchVoiceTriggerTests {
    @Test func stageOneIsAnOrdinaryClickAndDoesNotStart() {
        var trigger = NativeForceTouchVoiceTrigger()
        #expect(trigger.handle(stage: 1, canStart: true) == .idle)
        #expect(!trigger.firedForCurrentPress)
    }

    @Test func stageTwoStartsVoiceOncePerPress() {
        var trigger = NativeForceTouchVoiceTrigger()
        #expect(trigger.handle(stage: 2, canStart: true) == .started)
        #expect(trigger.firedForCurrentPress)
        #expect(trigger.handle(stage: 2, canStart: true) == .duplicate)
        #expect(trigger.handle(stage: 2, canStart: true) == .duplicate)
    }

    @Test func stageZeroReleasesTheOneShotForTheNextPress() {
        var trigger = NativeForceTouchVoiceTrigger()
        #expect(trigger.handle(stage: 2, canStart: true) == .started)
        #expect(trigger.handle(stage: 0, canStart: true) == .idle)
        #expect(trigger.handle(stage: 2, canStart: true) == .started)
    }

    @Test func stageTwoWhileACallIsAlreadyActiveOrVoiceIsUnavailableDoesNotStart() {
        var trigger = NativeForceTouchVoiceTrigger()
        #expect(trigger.handle(stage: 2, canStart: false) == .unavailable)
        #expect(!trigger.firedForCurrentPress)
        #expect(trigger.handle(stage: 1, canStart: false) == .idle)
    }

    @Test func monitorStartsOnlyForStageTwoInsideAnActiveRegion() {
        let view = NativeMokuForceTouchVoiceMonitor.MonitorView()
        view.frame = CGRect(x: 0, y: 0, width: 120, height: 58)
        var starts = 0
        var active = true
        var canStart = true
        var inside = true
        view.update(isActive: { active }, isInside: { _ in inside },
                    canStart: { canStart }, start: { starts += 1 })

        #expect(view.receive(stage: 1, at: CGPoint(x: 60, y: 29)) == .idle)
        #expect(starts == 0)
        #expect(view.receive(stage: 2, at: CGPoint(x: 60, y: 29)) == .started)
        #expect(starts == 1)
        #expect(view.receive(stage: 2, at: CGPoint(x: 60, y: 29)) == .duplicate)
        #expect(starts == 1)
        #expect(view.receive(stage: 0, at: CGPoint(x: 60, y: 29)) == .idle)
        #expect(view.receive(stage: 2, at: CGPoint(x: 60, y: 29)) == .started)
        #expect(starts == 2)

        canStart = false
        #expect(view.receive(stage: 0, at: CGPoint(x: 60, y: 29)) == .idle)
        #expect(view.receive(stage: 2, at: CGPoint(x: 60, y: 29)) == .unavailable)
        #expect(starts == 2)

        canStart = true
        active = false
        #expect(view.receive(stage: 2, at: CGPoint(x: 60, y: 29)) == .idle)
        #expect(starts == 2)

        active = true
        inside = false
        #expect(view.receive(stage: 2, at: CGPoint(x: 60, y: 29)) == .idle)
        #expect(starts == 2)
        inside = true
        #expect(view.receive(stage: 2, at: CGPoint(x: 200, y: 29)) == .idle)
        #expect(starts == 2)
    }

    @Test func forceTouchUsesTheTwoStageDeepClickBoundary() {
        #expect(NativeForceTouchVoiceTrigger.forceStage == 2)
        // NSEvent.h: primaryClick has one stage (1 -> 0); primaryDeepClick has
        // two (1 -> 2 -> 1 -> 0). Only the latter can expose a Force Click.
        let configuration = NSPressureConfiguration(pressureBehavior: .primaryDeepClick)
        #expect(configuration.pressureBehavior == .primaryDeepClick)
    }

    @Test(.requiresDisplay) func monitorConfiguresItsAppKitHostForDeepClickWithoutTakingHitTesting() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 120))
        window.contentView = host
        let view = NativeMokuForceTouchVoiceMonitor.MonitorView(frame: NSRect(x: 0, y: 0, width: 120, height: 58))
        host.addSubview(view)
        defer { view.stop(); window.close() }

        #expect(host.pressureConfiguration?.pressureBehavior == .primaryDeepClick)
        #expect(view.pressureConfiguration?.pressureBehavior == .primaryDeepClick)
        // The local monitor lives beside the view tree, not inside hit testing.
        #expect(view.hitTest(NSPoint(x: 10, y: 10)) == nil)
    }
}
