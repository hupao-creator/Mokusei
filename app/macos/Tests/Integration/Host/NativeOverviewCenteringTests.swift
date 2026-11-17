import AppKit
import Foundation
import SwiftUI
import Testing
import MokuseiPluginAPI
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
@testable import MokuseiUI

@MainActor
@Suite(.serializedNative, .requiresDisplay, .serialized)
struct NativeOverviewCenteringTests {
    @Test(arguments: [CGSize(width: 500, height: 600), CGSize(width: 620, height: 600),
                      CGSize(width: 621, height: 600), CGSize(width: 860, height: 600),
                      CGSize(width: 1180, height: 780), CGSize(width: 2560, height: 1440)])
    func renderedCollectionCentersAndKeepsControlsClear(size: CGSize) async throws {
        for count in [1, 3, 6, 16] {
            var items = (0..<count).map { NativeOverviewItem(id: "center-\($0)") }
            if count == 6 {
                items[0].columns = 2
                items[0].rows = 2
            }
            let fixture = OverviewReplayFixture(items: items, size: size)
            let window = SwiftUIReplay.window(OverviewReplayCanvas(fixture: fixture), width: size.width, height: size.height)
            defer { window.close() }
            try await OverviewReplay.settle(fixture, in: window)
            try OverviewReplay.verifyFitAll(fixture, in: window)
            try OverviewReplay.verifyControlsClear(fixture, in: window)
        }
    }


    @Test func maximumCardFootprintFitsTheMinimumWindow() async throws {
        let fixture = OverviewReplayFixture(
            items: [.init(id: "wide-agent", columns: HarnessOverviewCapacity.maximumColumns, rows: 2)],
            size: .init(width: 860, height: 600))
        let window = SwiftUIReplay.window(OverviewReplayCanvas(fixture: fixture), width: 860, height: 600)
        defer { window.close() }
        try await OverviewReplay.settle(fixture, in: window)
        try OverviewReplay.verifyFitAll(fixture, in: window)
        try OverviewReplay.verifyControlsClear(fixture, in: window)
    }

    @Test func mixedFootprintsKeepEveryCardVisibleAndCentered() async throws {
        let fixture = OverviewReplayFixture(size: .init(width: 1292, height: 858))
        var items = (0..<6).map { NativeOverviewItem(id: "mixed-\($0)") }
        items[0].columns = 2
        items[0].rows = 2
        fixture.install(items)
        let window = SwiftUIReplay.window(OverviewReplayCanvas(fixture: fixture), width: 1400, height: 950)
        defer { window.close() }
        try await OverviewReplay.settle(fixture, in: window)
        try OverviewReplay.verifyFitAll(fixture, in: window)
        try OverviewReplay.verifyControlsClear(fixture, in: window)
        // Every latest card occupies one rendered frame; no stale or duplicate
        // slot remains after the automatic fit.
        #expect(fixture.frames.count == items.count)
        #expect(Set(fixture.frames.keys) == Set(items.map(\.id)))
    }

    @Test func resizingReframesActualCardsWithoutReplacingThem() async throws {
        _ = NSApplication.shared
        let style: NSWindow.StyleMask = [.titled, .resizable]
        let initialScreen = try #require(NSScreen.main)
        let available = NSWindow.contentRect(forFrameRect: initialScreen.visibleFrame, styleMask: style).size
        let normal = CGSize(width: min(1180, floor(available.width)),
                            height: min(780, floor(available.height) - 1))
        try #require(normal.width >= 860 && normal.height >= 600)
        let fixture = OverviewReplayFixture(items: (0..<16).map { .init(id: "resize-\($0)") }, size: normal)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: normal),
                              styleMask: style, backing: .buffered, defer: false, screen: initialScreen)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: OverviewReplayCanvas(fixture: fixture))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await OverviewReplay.settle(fixture, in: window)
        let appearances = fixture.appearances
        let screen = try #require(window.screen)
        let frameInset = window.frame.height - window.contentRect(forFrameRect: window.frame).height
        let tallHeight = min(1000, floor(screen.visibleFrame.height - frameInset) - 1)
        for size in [CGSize(width: 860, height: 600), CGSize(width: 860, height: tallHeight), normal] {
            fixture.size = size
            window.setContentSize(size)
            try await SwiftUIReplay.wait { fixture.viewport == size }
            try await OverviewReplay.settle(fixture, in: window)
            try OverviewReplay.verifyFitAll(fixture, in: window)
            #expect(fixture.appearances == appearances)
        }
    }

    @Test func explicitReturnRestoresRenderedComposition() async throws {
        let fixture = OverviewReplayFixture(items: (0..<16).map { .init(id: "return-\($0)") })
        let window = SwiftUIReplay.window(OverviewReplayCanvas(fixture: fixture))
        defer { window.close() }
        try await OverviewReplay.settle(fixture, in: window)
        for suspension in ["none", "interaction", "hidden"] {
            fixture.state.camera.setManualTransform(.init(scale: 1.2, x: -500, y: 350))
            if suspension == "interaction" {
                fixture.state.beginInteraction(cardID: "return-0")
            } else if suspension == "hidden" {
                fixture.visible = false
                fixture.state.camera.setVisible(false)
            }
            fixture.state.camera.returnToAuto()
            fixture.state.endInteraction(cardID: "return-0")
            fixture.visible = true
            fixture.state.camera.setVisible(true)
            try await OverviewReplay.settle(fixture, in: window)
            #expect(!fixture.state.camera.manual)
            try OverviewReplay.verifyFitAll(fixture, in: window)
        }
    }

    @Test func manualCompositionSurvivesBackgroundGeometryChanges() async throws {
        let fixture = OverviewReplayFixture(items: (0..<6).map { .init(id: "manual-\($0)") })
        let window = SwiftUIReplay.window(OverviewReplayCanvas(fixture: fixture))
        defer { window.close() }
        try await OverviewReplay.settle(fixture, in: window)
        let manual = NativeOverviewTransform(scale: 1, x: -260, y: 120)
        fixture.state.camera.setManualTransform(manual)
        var items = fixture.items
        items[0].columns = 2
        items[0].rows = 2
        fixture.install(items)
        try await OverviewReplay.settle(fixture, in: window)
        #expect(fixture.state.camera.manual)
        #expect(fixture.state.camera.liveTransform == manual)
        fixture.state.camera.returnToAuto()
        try await OverviewReplay.settle(fixture, in: window)
        try OverviewReplay.verifyFitAll(fixture, in: window)
    }
}
