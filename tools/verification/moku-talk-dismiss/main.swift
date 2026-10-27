import AppKit
import MokuseiCore
import MokuseiPluginUI
import Observation
import ScreenCaptureKit
import SwiftUI
@testable import MokuseiUI

private struct Failure: Error { let message: String }
@MainActor private func require(_ value: Bool, _ message: String) throws {
    if !value { throw Failure(message: message) }
}
@MainActor private func settle() async throws { try await Task.sleep(for: .milliseconds(600)) }
@MainActor private func wait(_ message: String, _ predicate: () -> Bool) async throws {
    for _ in 0..<300 {
        if predicate() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw Failure(message: message)
}
@MainActor private func find<T: NSView>(_ root: NSView, _ type: T.Type) -> T? {
    if let result = root as? T { return result }
    return root.subviews.lazy.compactMap { find($0, type) }.first
}
@MainActor private final class ClickTarget: NSView {
    var presses = 0
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { presses += 1 }
}
@MainActor @Observable private final class Fixture {
    let state = NativeMokuSceneState()
    let draft = NativeComposerDraft(services: .init(stageFiles: { _, _ in [] }, discardAttachments: { _ in }))
    let note = NativeMokuNote(id: "unread-fixture", text: "保留笔记功能", revision: 1, updatedAt: 1)
    var talk: String? = "“调试提示词”选项及专属代码已在隔离工作树移除，检查通过，补丁已生成；tag filter 调整仍在进行。"
    var mounted = true
}
private struct Scene: View {
    let fixture: Fixture
    var body: some View {
        ZStack {
            LinearGradient(colors: [.blue.opacity(0.35), .purple.opacity(0.3), .cyan.opacity(0.25)], startPoint: .bottomLeading, endPoint: .topTrailing)
            if fixture.mounted {
                NativeMokuDock(state: fixture.state, draft: fixture.draft, cwd: "/isolated/moku",
                    talk: fixture.talk, note: fixture.note, onSend: { _ in }, onCancel: {})
            }
        }.environment(\.locale, Locale(identifier: "zh-Hans"))
            .environment(\.colorScheme, .light)
    }
}
@MainActor private func click(_ window: NSWindow, _ point: CGPoint) async throws {
    let location = NSPoint(x: point.x, y: window.contentView!.bounds.height - point.y)
    func event(_ type: NSEvent.EventType) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
    }
    // Selectable native text tracks synchronously inside mouseDown. Queue the
    // release first so that tracking can complete without blocking this task.
    NSApp.postEvent(event(.leftMouseUp), atStart: false)
    NSApp.sendEvent(event(.leftMouseDown))
    try await Task.sleep(for: .milliseconds(100))
}
@MainActor private func replay() async throws {
    let evidence = URL(fileURLWithPath: CommandLine.arguments[1])
    try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
    let fixture = Fixture()
    fixture.state.setWindowVisible(true)
    let host = NSHostingView(rootView: Scene(fixture: fixture))
    let window = NSPanel(contentRect: NSRect(x: 150, y: 160, width: 900, height: 620),
        styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.title = "Moku Talk isolated dismissal replay"
    window.level = .floating
    window.appearance = NSAppearance(named: .aqua)
    window.contentView = host
    window.orderFrontRegardless()
    defer { window.close() }
    try await wait("Talk did not mount in NSPanel") { fixture.state.talkPresentation.presented && fixture.state.capsuleFrame.width > 500 }
    try await settle()
    func capture(_ name: String) async throws {
        let content = try await SCShareableContent.currentProcess
        guard let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            throw Failure(message: "Own WindowServer panel is unavailable")
        }
        let configuration = SCStreamConfiguration()
        configuration.width = Int(window.frame.width * 2); configuration.height = Int(window.frame.height * 2)
        configuration.ignoreShadowsSingleWindow = true; configuration.showsCursor = false
        configuration.capturesAudio = false; configuration.captureMicrophone = false
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: configuration)
        let bitmap = NSBitmapImageRep(cgImage: image)
        try bitmap.representation(using: .png, properties: [:])!.write(to: evidence.appendingPathComponent(name + ".png"))
    }
    try require(fixture.state.noteUnread(fixture.note), "Fixture must exercise unread note dot condition")
    try await capture("talk-unread-note-no-dot")
    let surface = fixture.state.capsuleFrame
    try await click(window, CGPoint(x: surface.midX, y: surface.midY))
    try require(fixture.state.talkPresentation.message != nil, "Inside click dismissed talk")
    // Native SwiftUI scroll view remains usable; scrolling never enters a mouse-down dismissal path.
    fixture.talk = (1...12).map { "可滚动消息第\($0)行" }.joined(separator: "\n")
    try await settle()
    guard let scroll = find(host, NSScrollView.self) else { throw Failure(message: "No production talk scroll view") }
    let before = scroll.contentView.bounds.origin
    // SwiftUI can restore either edge after replacing a short message. Try
    // both directions so a legitimate edge clamp is not a replay failure.
    for delta: Int32 in [120, -120] {
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0)!
        scroll.scrollWheel(with: NSEvent(cgEvent: event)!)
        try await Task.sleep(for: .milliseconds(200))
        if scroll.contentView.bounds.origin != before { break }
    }
    try require(fixture.state.talkPresentation.message != nil && scroll.contentView.bounds.origin != before,
                "Inside scroll dismissed talk or failed to scroll: before=\(before) after=\(scroll.contentView.bounds) document=\(String(describing: scroll.documentView?.frame))")
    try await capture("inside-scroll-retains-talk")
    // The target proves that dismissal leaves the original event on its normal path.
    let targetPoint = host.convert(NSPoint(x: 30, y: host.bounds.height - 40), from: nil)
    let target = ClickTarget(frame: NSRect(x: targetPoint.x - 20, y: targetPoint.y - 20, width: 60, height: 60))
    host.addSubview(target)
    try await click(window, CGPoint(x: 30, y: 40))
    try await settle()
    try require(fixture.state.talkPresentation.message == nil && target.presses == 1,
                "Outside click did not dismiss or swallowed the target click")
    try await capture("outside-dismissed")
    fixture.state.receiveTalk(NativeMokuTalkMessage(id: JSONText(fixture.talk!), text: fixture.talk!))
    try require(fixture.state.talkPresentation.message == nil, "Refresh resurrected dismissed talk")
    fixture.talk = "新消息仍会显示"
    try await wait("New delivery did not show") { fixture.state.talkPresentation.presented }
    try await settle()
    try await capture("new-message-visible")
    let other = NSWindow(contentRect: NSRect(x: 1100, y: 200, width: 160, height: 100),
        styleMask: [.titled], backing: .buffered, defer: false)
    other.isReleasedWhenClosed = false
    let otherTarget = ClickTarget(frame: NSRect(x: 0, y: 0, width: 160, height: 100))
    other.contentView = otherTarget; other.orderFrontRegardless()
    defer { other.close() }
    try await click(other, CGPoint(x: 50, y: 50))
    try await settle()
    try require(fixture.state.talkPresentation.message == nil,
                "Other-window click did not dismiss talk")
    try require(otherTarget.presses == 1, "Other-window target did not receive click: \(otherTarget.presses)")
    fixture.talk = "卸载前消息"
    try await wait("Delivery before unmount missing") { fixture.state.talkPresentation.presented }
    fixture.mounted = false
    try await settle()
    try require(find(host, NativeMokuOutsideClickMonitor.MonitorView.self) == nil, "Monitor survived unmount")
    fixture.state.receiveTalk(.init(id: "after-unmount", text: "Must remain pending"))
    try await click(other, CGPoint(x: 50, y: 50))
    try require(fixture.state.talkPresentation.message?.id == "after-unmount", "Detached monitor dismissed pending delivery")
    fixture.mounted = true; fixture.talk = "重新挂载新消息"
    try await wait("Remounted talk missing") { fixture.state.talkPresentation.presented }
    try await settle()
    try await click(window, CGPoint(x: 30, y: 40))
    try require(fixture.state.talkPresentation.message == nil, "Remounted monitor did not dismiss")
    // Presentation alone cannot invent authoritative exposure evidence.
    fixture.state.setNotePanelOpen(true)
    try await settle()
    try require(fixture.state.notePanelOpen && fixture.state.noteUnread(fixture.note), "Opening invented note exposure")
    try await capture("note-behavior-preserved")
    fixture.state.setNotePanelOpen(false)
    fixture.talk = "等待一分钟自动收起"
    try await wait("Timed delivery did not show") { fixture.state.talkPresentation.presented }
    let deadline = fixture.state.talkPresentation.deadline!
    // Re-render the production Dock without changing operation identity. The
    // timer must still fire at its original deadline, then survive remount.
    host.setFrameSize(NSSize(width: 860, height: 620))
    fixture.state.receiveTalk(.init(id: JSONText(fixture.talk!), text: fixture.talk!))
    try require(fixture.state.talkPresentation.deadline == deadline, "Refresh extended timeout")
    try await ContinuousClock().sleep(until: deadline.advanced(by: .milliseconds(100)))
    try await wait("Production deadline task did not dismiss talk") { fixture.state.talkPresentation.message == nil }
    try await settle()
    try await capture("timeout-dismissed")
    fixture.mounted = false
    try await settle()
    fixture.mounted = true
    try await settle()
    try require(fixture.state.talkPresentation.message == nil && fixture.state.talkPresentation.deadline == nil,
                "Expired talk resurrected on remount")
    try require(fixture.state.noteUnread(fixture.note), "Talk timeout invented note exposure")
    fixture.talk = "过期后新消息"
    try await wait("New message after timeout missing") { fixture.state.talkPresentation.presented }
    try require(fixture.state.talkPresentation.deadline! > deadline, "New message inherited expired deadline")
    // Render alignment cases through the production Dock after lifecycle checks;
    // replaying an earlier text identity would correctly leave it consumed.
    for (name, text) in [
        ("centered-chinese-single", "已安排恢复附件加号按钮，放在 Moku 眼睛右边，并验证附件选择功能。"),
        ("centered-english-single", "Ready to continue."),
        ("centered-english-multiline", "The first task is complete.\nThe next task is ready."),
        ("centered-chinese-multiline", "第一项任务已完成。\n正在检查第二项任务。\n保持现有布局。\n完成后会通知你。")
    ] {
        fixture.talk = text
        try await wait("Alignment fixture did not appear") { fixture.state.talkPresentation.message?.text == text }
        try await settle()
        try await capture(name)
    }
    let report: [String: Any] = ["ok": true,
        "checks": ["production Dock hosted in NSPanel with unread note and original screenshot text",
            "inside click retains; native scroll moves and retains", "outside click dismisses and reaches target",
            "refresh does not resurrect; new delivery shows", "other NSWindow click dismisses and reaches target",
            "unmount removes monitor; pending message survives; remount reinstalls", "note opening and Talk timeout preserve unknown exposure",
            "production task expires after 60 seconds; refresh retains deadline; remount cannot resurrect; next message gets fresh deadline"],
        "limits": "Isolated fixture state, native WindowServer screenshots. Cross-app global mouse delivery is not injected; no user runtime, provider or microphone used."]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: evidence.appendingPathComponent("report.json"))
    await fixture.draft.dispose()
}
@MainActor private final class Delegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            var failure: String?
            do { try await replay() } catch { failure = String(describing: error) }
            let result: [String: Any] = ["ok": failure == nil, "message": failure ?? "production Talk dismissal replay"]
            let path = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("result.json")
            try! JSONSerialization.data(withJSONObject: result).write(to: path)
            exit(failure == nil ? 0 : 1)
        }
    }
}
@main private enum Main {
    static func main() {
        do { try prepareIsolatedNativeReplay() }
        catch { print("FAIL replay isolation: \(error)"); exit(1) }
        let delegate = Delegate(), app = NSApplication.shared
        app.setActivationPolicy(.regular); app.delegate = delegate; app.run()
    }
}
