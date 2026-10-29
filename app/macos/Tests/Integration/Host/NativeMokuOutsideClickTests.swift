import AppKit
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import SwiftUI
import Testing
#if SWIFT_PACKAGE
import MokuseiTestSupport
#endif
@testable import MokuseiUI

@MainActor private final class OutsideClickFixture {
    let scene = NativeMokuSceneState()
    let draft = NativeComposerDraft(services: .init(stageFiles: { _, _ in [] }, discardAttachments: { _ in }))
    var pauseCanvas = true
    var landing = false
    var note: NativeMokuNote?
}

private struct OutsideClickReplay: View {
    let fixture: OutsideClickFixture
    var body: some View {
        NativeMokuScene(state: fixture.scene) {
            NativeOverviewCanvas(items: [.init(id: "thread")], sceneKey: "outside-click",
                state: fixture.scene.overviewState,
                interactionPaused: fixture.pauseCanvas ? fixture.scene.interactionPaused : false) { _ in
                Color.clear
            }
        } thread: {
            EmptyView()
        } dock: {
            NativeMokuDock(state: fixture.scene, draft: fixture.draft, cwd: "/tmp", landing: fixture.landing, note: fixture.note,
                onSend: { _ in }, onCancel: {})
        } settings: {
            EmptyView()
        }
    }
}

@MainActor
@Suite(.serializedNative, .serialized)
struct NativeMokuOutsideClickTests {
    private func click(_ window: NSWindow, at point: CGPoint, hold: Duration = .milliseconds(80)) async throws {
        let height = try #require(window.contentView).bounds.height
        let location = CGPoint(x: point.x, y: height - point.y)
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
        }
        NSApp.sendEvent(try event(.leftMouseDown))
        try await Task.sleep(for: hold)
        NSApp.sendEvent(try event(.leftMouseUp))
    }

    @Test(.requiresDisplay, arguments: [false, true])
    func outsideClickRespectsDockModeAndInsideClickKeepsInput(landing: Bool) async throws {
        let fixture = OutsideClickFixture()
        fixture.landing = landing
        let scene = fixture.scene
        let window = SwiftUIReplay.window(OutsideClickReplay(fixture: fixture), width: 900, height: 600)
        defer { window.close(); scene.overviewState.camera.dispose() }
        try await SwiftUIReplay.wait { scene.windowVisible && scene.overviewState.camera.isInitialized
            && !scene.overviewState.isLayingOut && !scene.overviewState.camera.isAnimating }
        scene.overviewState.camera.setManualTransform(.init(scale: 1, x: 120, y: 90))
        #expect(scene.overviewState.camera.manual)
        scene.setInputOpen(true)
        try await SwiftUIReplay.wait { scene.inputOpen && !scene.capsuleFrame.isEmpty }
        #expect(scene.overviewState.camera.manual)

        let outside = CGPoint(x: 20, y: scene.capsuleFrame.minY - 30)
        try await click(window, at: outside)
        try await Task.sleep(for: .milliseconds(150))
        #expect(scene.inputOpen == landing)
        #expect(scene.overviewState.camera.manual)

        scene.setInputOpen(true)
        try await SwiftUIReplay.wait { scene.inputOpen && !scene.capsuleFrame.isEmpty }
        let inside = CGPoint(x: scene.capsuleFrame.midX, y: scene.capsuleFrame.midY)
        try await click(window, at: inside)
        try await Task.sleep(for: .milliseconds(150))
        #expect(scene.inputOpen)
    }

    @Test(.requiresDisplay) func landingOutsideWindowClickRetainsDraftAndPassesThrough() async throws {
        let fixture = OutsideClickFixture()
        fixture.landing = true
        fixture.draft.text = "保留窗口外点击前的草稿"
        let scene = fixture.scene
        let window = SwiftUIReplay.window(OutsideClickReplay(fixture: fixture), width: 900, height: 600)
        let other = NSWindow(contentRect: CGRect(x: 950, y: 100, width: 180, height: 120),
                             styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        let target = OutsideClickTarget(frame: CGRect(x: 0, y: 0, width: 180, height: 120))
        other.contentView = target
        defer { other.close(); window.close(); scene.overviewState.camera.dispose() }
        try await SwiftUIReplay.wait { scene.windowVisible && scene.inputOpen && !scene.capsuleFrame.isEmpty }
        // Merely moving focus (as menus and panels do) must not retire the draft.
        other.makeKeyAndOrderFront(nil)
        #expect(scene.inputOpen)
        window.addChildWindow(other, ordered: .above)
        try await click(other, at: CGPoint(x: 50, y: 50))
        #expect(scene.inputOpen && target.presses == 1)
        window.removeChildWindow(other)

        // Drive the same native notifications as text/attachment menus. Nested
        // tracking must retain ownership until the last menu has closed.
        let menu = NSMenu(), submenu = NSMenu()
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: submenu)
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: submenu)
        try await click(other, at: CGPoint(x: 50, y: 50))
        #expect(scene.inputOpen && target.presses == 2)
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)

        other.orderOut(nil)
        window.beginSheet(other, completionHandler: { _ in })
        try await SwiftUIReplay.wait { window.attachedSheet === other }
        try await click(other, at: CGPoint(x: 50, y: 50))
        #expect(scene.inputOpen && target.presses == 3)
        window.endSheet(other)
        try await SwiftUIReplay.wait { window.attachedSheet == nil }
        other.makeKeyAndOrderFront(nil)
        try await click(other, at: CGPoint(x: 50, y: 50))
        #expect(scene.inputOpen)
        #expect(target.presses == 4)
        #expect(fixture.draft.text == "保留窗口外点击前的草稿")
        scene.toggleInput()
        #expect(!scene.inputOpen)
        scene.toggleInput()
        try await SwiftUIReplay.wait { scene.inputOpen }
        #expect(fixture.draft.text == "保留窗口外点击前的草稿")
        scene.openSettings()
        try await SwiftUIReplay.wait { scene.dockCovered }
        try await click(other, at: CGPoint(x: 50, y: 50))
        #expect(scene.inputOpen)
        scene.closeSettings(); scene.settle()
        try await SwiftUIReplay.wait { !scene.dockCovered && scene.inputOpen && !scene.capsuleFrame.isEmpty }
        try await click(other, at: CGPoint(x: 50, y: 50))
        #expect(scene.inputOpen)
        #expect(fixture.draft.text == "保留窗口外点击前的草稿")
    }

    /// The note grows the bottom-anchored Moku surface. Blank space above
    /// that fitted surface still dismisses it; the Moku row stays inside.
    @Test(.requiresDisplay) func shortNotePublishesOnlyItsVisibleBoundsForDismissal() async throws {
        let fixture = OutsideClickFixture()
        fixture.note = NativeMokuNote(id: "note-incarnation", text: "Short note", revision: 1, updatedAt: 1)
        let scene = fixture.scene
        let window = SwiftUIReplay.window(OutsideClickReplay(fixture: fixture), width: 900, height: 600)
        defer { window.close(); scene.overviewState.camera.dispose() }
        try await SwiftUIReplay.wait { scene.windowVisible && scene.overviewState.camera.isInitialized
            && !scene.overviewState.isLayingOut && !scene.overviewState.camera.isAnimating }
        let closed = scene.capsuleFrame
        scene.setNotePanelOpen(true)
        try await SwiftUIReplay.wait { scene.notePanelOpen && scene.capsuleFrame.height > closed.height }
        try await Task.sleep(for: .milliseconds(600))

        let panel = scene.capsuleFrame
        #expect(abs(panel.maxY - closed.maxY) < 1)
        #expect(scene.dockHitRects.count == 1)
        #expect(NativeMokuOutsideClick.isInside(point: CGPoint(x: closed.midX, y: closed.midY), dockRects: scene.dockHitRects))
        // A short note fits far below the full space between the window top and
        // the capsule (the available area spans from y = 24 in this window).
        #expect(panel.height < 300)
        let blankAboveVisiblePanel = CGPoint(x: panel.midX, y: 40)
        #expect(!NativeMokuOutsideClick.isInside(point: blankAboveVisiblePanel, dockRects: scene.dockHitRects))
        try await click(window, at: CGPoint(x: panel.minX + 30, y: panel.minY + 60))
        #expect(scene.notePanelOpen)
        try await click(window, at: blankAboveVisiblePanel)
        try await SwiftUIReplay.wait { !scene.notePanelOpen }
    }

    @Test(.requiresDisplay) func outsideClickSuppressesAutoFramingForTheSamePress() async throws {
        let fixture = OutsideClickFixture()
        // Keep the background tappable before and after the press so the test
        // proves the precedence interlock rather than the existing canvas pause.
        fixture.pauseCanvas = false
        let scene = fixture.scene
        let window = SwiftUIReplay.window(OutsideClickReplay(fixture: fixture), width: 900, height: 600)
        defer { window.close(); scene.overviewState.camera.dispose() }
        try await SwiftUIReplay.wait { scene.windowVisible && scene.overviewState.camera.isInitialized
            && !scene.overviewState.isLayingOut && !scene.overviewState.camera.isAnimating }
        let manual = NativeOverviewTransform(scale: 1, x: 120, y: 90)
        scene.overviewState.camera.setManualTransform(manual)
        #expect(scene.overviewState.camera.manual)
        scene.setInputOpen(true)
        try await SwiftUIReplay.wait { scene.inputOpen && !scene.capsuleFrame.isEmpty }
        #expect(scene.overviewState.camera.manual)

        let outside = CGPoint(x: 20, y: scene.capsuleFrame.minY - 30)
        try await click(window, at: outside)
        try await SwiftUIReplay.wait { !scene.inputOpen }
        // The canvas background is reachable for this press; automatic framing
        // must still be skipped because the same press dismissed the composer.
        #expect(scene.overviewState.camera.manual)
        #expect(scene.overviewState.camera.transform == manual)
    }

    @Test func dismissalMarksOnlyTheDismissingClickForAutoFraming() {
        let scene = NativeMokuSceneState()
        scene.setWindowVisible(true)
        let camera = scene.overviewState.camera
        camera.cutTo(content: .init(left: 0, top: 0, width: 736, height: 400),
                     viewport: .init(width: 900, height: 600, toolbarBottom: 58))
        let manual = NativeOverviewTransform(scale: 1, x: 120, y: 90)
        camera.setManualTransform(manual)
        scene.setInputOpen(true)

        #expect(scene.dismissInputForOutsideClick())
        #expect(!scene.inputOpen)
        #expect(!scene.overviewState.allowsBackgroundAutoFocus())
        #expect(scene.overviewState.allowsBackgroundAutoFocus())
        #expect(camera.manual && camera.transform == manual)
        #expect(!scene.dismissInputForOutsideClick())
    }

    @Test func composerCapsuleIsInsideWhileBackgroundIsOutside() {
        let capsule = CGRect(x: 100, y: 500, width: 200, height: 60)
        #expect(NativeMokuOutsideClick.isInside(point: CGPoint(x: 150, y: 520), dockRects: [capsule]))
        #expect(!NativeMokuOutsideClick.isInside(point: CGPoint(x: 150, y: 300), dockRects: [capsule]))
        // A missing published frame must never dismiss the composed draft.
        #expect(NativeMokuOutsideClick.isInside(point: CGPoint(x: 150, y: 300), dockRects: []))
    }

    @Test(.requiresDisplay) func excludedControlCountsAsInside() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = root
        let exclusions = NativeClickExclusions()
        let control = NSView(frame: CGRect(x: 120, y: 200, width: 40, height: 40))
        root.addSubview(control)
        exclusions.add(control)
        #expect(control.window === window)
        #expect(exclusions.contains(CGPoint(x: 140, y: 220), in: window))
        #expect(!exclusions.contains(CGPoint(x: 20, y: 20), in: window))
    }

    @Test(.requiresDisplay) func returnToAutoControlRegistersItsExclusionWhileManual() async throws {
        let exclusions = NativeClickExclusions()
        let window = SwiftUIReplay.window(
            NativeOverviewChrome(filters: [], cameraManual: true, onTagChange: { _ in },
                onReturnToAuto: {}, clickExclusions: exclusions),
            width: 900, height: 200)
        defer { window.close() }
        try await SwiftUIReplay.wait { exclusions.registeredCount > 0 }
        let button = try #require(exclusions.windowFrames(in: window).first)
        #expect(button.width > 35 && button.height > 35)
        #expect(button.minX > 700)
        #expect(exclusions.contains(CGPoint(x: button.midX, y: button.midY), in: window))
        #expect(!exclusions.contains(CGPoint(x: 400, y: 100), in: window))
    }
}

@MainActor private final class OutsideClickTarget: NSView {
    var presses = 0
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { presses += 1 }
}
