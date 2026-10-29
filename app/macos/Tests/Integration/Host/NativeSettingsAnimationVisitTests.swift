import SwiftUI
import Testing
@testable import MokuseiUI

@MainActor struct NativeSettingsAnimationVisitTests {
    @Test func independentVisitsSurviveTabChangesAndResetOnClose() {
        var visits = NativeSettingsAnimationVisits()
        let tag = Binding(get: { visits.tag }, set: { visits.tag = $0 })
        let report = Binding(get: { visits.report }, set: { visits.report = $0 })

        // Inactive presentation and Tag's initial layout delay do not consume a visit.
        #expect(!NativeCapabilityPlayback.shouldPlay(active: false, reduceMotion: false, started: tag))
        #expect(NativeCapabilityPlayback.shouldPlay(active: true, reduceMotion: false, started: tag))
        #expect(NativeCapabilityPlayback.shouldPlay(active: true, reduceMotion: false, started: tag))
        NativeCapabilityPlayback.begin(tag)
        #expect(!NativeCapabilityPlayback.shouldPlay(active: true, reduceMotion: false, started: tag))

        #expect(NativeCapabilityPlayback.shouldPlay(active: true, reduceMotion: false, started: report))
        NativeCapabilityPlayback.begin(report)
        // Interruption or tab replacement cannot admit a second playback.
        #expect(!NativeCapabilityPlayback.shouldPlay(active: false, reduceMotion: false, started: report))
        #expect(!NativeCapabilityPlayback.shouldPlay(active: true, reduceMotion: false, started: report))
        #expect(!NativeCapabilityPlayback.shouldPlay(active: true, reduceMotion: false, started: tag))

        visits.reset()
        #expect(NativeCapabilityPlayback.shouldPlay(active: true, reduceMotion: false, started: tag))
        #expect(NativeCapabilityPlayback.shouldPlay(active: true, reduceMotion: false, started: report))
    }

    @Test func reduceMotionConsumesOnlyTheSelectedVisit() {
        var visits = NativeSettingsAnimationVisits()
        let tag = Binding(get: { visits.tag }, set: { visits.tag = $0 })
        let report = Binding(get: { visits.report }, set: { visits.report = $0 })
        #expect(!NativeCapabilityPlayback.shouldPlay(active: false, reduceMotion: true, started: tag))
        #expect(!NativeCapabilityPlayback.shouldPlay(active: true, reduceMotion: false, started: tag))
        #expect(NativeCapabilityPlayback.shouldPlay(active: true, reduceMotion: false, started: report))
        visits.reset()
        #expect(NativeCapabilityPlayback.shouldPlay(active: true, reduceMotion: false, started: tag))
    }
}
