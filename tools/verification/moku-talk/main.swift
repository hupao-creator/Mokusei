import AppKit
import Observation
import MokuseiCore
import MokuseiHarnessCodex
import MokuseiPluginAPI
import MokuseiPluginUI
@testable import MokuseiUI
import ScreenCaptureKit
import SwiftUI

private struct Failure: Error, CustomStringConvertible { let description: String }
@MainActor func require(_ value: Bool, _ message: String) throws {
    if !value { throw Failure(description: message) }
}
@MainActor func wait(_ label: String, _ predicate: () -> Bool) async throws {
    for _ in 0..<500 {
        if predicate() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw Failure(description: label)
}
@MainActor func find<T: NSView>(_ root: NSView, _ type: T.Type) -> T? {
    if let view = root as? T { return view }
    return root.subviews.lazy.compactMap { find($0, type) }.first
}
@MainActor private struct Harness: HarnessPlugin {
    let descriptor = HarnessPluginDescriptor(id: "mock", displayName: "Fixture",
        threadCapabilities: .init(instructions: false, threadContext: false, sendContext: false, toolModes: []))
    let logoSource = ""
    var threadSettingsCodec: PluginValueCodec<JSONValue> { .json }
    var harnessSettingsCodec: PluginValueCodec<JSONValue> { .json }
    var settingsPresentationCodec: PluginValueCodec<JSONValue> { .json }
    func logo(size: CGFloat) -> some View { CodexLogo(size: size) }
    func projectOverview(input: HarnessThreadInput, availableColumns: Int) throws -> HarnessOverviewProjection<String> {
        .init(footprint: .init(columns: 1, rows: 1), structureKey: "fixture", excerpt: "", view: "")
    }
    func threadView(input: HarnessThreadInput, actions: HarnessThreadActions, context: HarnessRenderContext) -> some View { EmptyView() }
    func overviewCard(input: HarnessThreadInput, projection: String, actions: HarnessThreadActions, openThread: @escaping () -> Void) -> some View { EmptyView() }
    func threadSettings(input: HarnessThreadInput, resource: HarnessSettingsResource<JSONValue>, update: @escaping (JSONValue) async throws -> Void) -> some View { EmptyView() }
    func harnessSettings(props: HarnessSettingsProps<JSONValue, JSONValue>) -> some View { EmptyView() }
}

@MainActor @Observable final class Fixture {
    let state = NativeMokuSceneState()
    let draft = NativeComposerDraft(services: .init(stageFiles: { _, _ in [] }, discardAttachments: { _ in }))
    let workspace: NativeWorkspaceModel
    let overview: NativeOverviewWorkspaceModel
    let presentation: NativeMokuWorkspacePresentation
    var scheme: ColorScheme = .light
    var interaction = false
    var voiceVisible = false
    var voiceActive = false
    private var revision = 0
    private var snapshot: JSONValue?
    private let authority = UUID()

    init(directory: URL) throws {
        workspace = NativeWorkspaceModel(client: RuntimeClient(profile: try RuntimeProfile(dataDirectory: directory, homeDirectory: directory)),
            preferences: DesktopPreferences(directory: directory),
            plugins: try .init(harnesses: [AnyHarnessPlugin(Harness())], sidecards: [], applications: []))
        overview = NativeOverviewWorkspaceModel(workspace: workspace,
            applications: .init(projectionCapabilities: { _, _ in throw CancellationError() }, rendererContext: { _, _, _ in throw CancellationError() }))
        presentation = NativeMokuWorkspacePresentation(workspace: workspace, overview: overview)
        // Deliberately do not start a RuntimeClient, voice media or a provider.
    }
    func install(_ thread: JSONValue) throws {
        revision += 1
        let hydrated: JSONValue = .object(["revision": .integer(revision), "settingsRevision": .integer(0),
            "defaultCwd": .text("/isolated/moku"), "settings": .object([:]), "threads": .array([thread]),
            "executions": .array([]), "applicationThreads": .array([])])
        let event: RuntimeClientEvent
        if let previous = snapshot, let old = previous["threads"]?.arrayValue?.first,
           (thread["revision"]?.intValue ?? 0) > (old["revision"]?.intValue ?? 0) {
            let mutation: JSONValue = .object(["type": .text("state-patched"),
                "baseRevision": .integer(revision - 1), "revision": .integer(revision),
                "threads": .object(["upserts": .array([thread]), "removedIds": .array([])])])
            let next = try RuntimeState.applying(mutation, to: previous)
            try workspace.catalog.install(next); snapshot = next
            event = .mutation(mutation, state: next, authority: authority)
        } else {
            try workspace.catalog.install(hydrated); snapshot = hydrated
            event = .snapshot(hydrated, authority: authority)
        }
        overview.receive(event); presentation.receive(event)
    }
}
private struct Dock: View {
    let fixture: Fixture
    var body: some View {
        NativeMokuDock(state: fixture.state, draft: fixture.draft, cwd: "/isolated/moku",
            mode: fixture.presentation.dockMode, running: fixture.presentation.running,
            talk: fixture.presentation.talk, interaction: fixture.interaction ? AnyView(Text("Permission fixture")) : nil,
            voiceControls: AnyView(Text("V").frame(width: 34, height: 34)),
            voiceBackground: AnyView(Group {
                if fixture.voiceActive && fixture.voiceVisible { DispatchVoiceCloud() }
            }),
            voiceStatusVisible: fixture.voiceVisible,
            voiceModeActive: fixture.voiceActive,
            presentation: fixture.presentation, onSend: { _ in }, onCancel: {})
    }
}
/// Fresh scalar fixture input drives the actual shared production cloud. Audio
/// capture is covered separately by the PCM replay; this owns no microphone.
private struct DispatchVoiceCloud: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.05)) { _ in
            NativeVoiceCloud(level: 0.035, capturedAt: ProcessInfo.processInfo.systemUptime, listening: true)
        }
    }
}
private struct Scene: View {
    let fixture: Fixture
    var body: some View {
        NativeMokuScene(state: fixture.state) { Color(nsColor: .windowBackgroundColor) } thread: {
            Text("History fixture")
        } dock: { Dock(fixture: fixture) } settings: { Text("Settings fixture") }
        .environment(\.colorScheme, fixture.scheme)
        .environment(\.locale, Locale(identifier: "zh-Hans"))
    }
}

// A reported full-size SCWindow can still be transformed by Stage Manager.
// Verify actual alpha coverage before using any pixels as rendering evidence.
private func coversFullWindow(_ image: CGImage) -> Bool {
    var rgba = [UInt8](repeating: 0, count: 32 * 32 * 4)
    return rgba.withUnsafeMutableBytes { buffer in
        let cg = CGContext(data: buffer.baseAddress, width: 32, height: 32, bitsPerComponent: 8,
            bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        cg.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 32))
        let bytes = buffer.bindMemory(to: UInt8.self)
        return stride(from: 3, to: bytes.count, by: 4).filter { bytes[$0] > 240 }.count >= 1000
    }
}
@MainActor private func replay() async throws {
    guard CommandLine.arguments.count >= 3 else { throw Failure(description: "Expected tool-records.json and evidence directory") }
    let fixtureURL = URL(fileURLWithPath: CommandLine.arguments[1])
    let evidence = URL(fileURLWithPath: CommandLine.arguments[2])
    try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
    let data = try JSONValue.parse(data: Data(contentsOf: fixtureURL))
    guard let records = data["records"]?.arrayValue, let texts = data["texts"]?.arrayValue?.compactMap(\.stringValue),
          records.count == 4, texts.count == 4 else { throw Failure(description: "Missing real Go tool records") }
    let fixture = try Fixture(directory: evidence.appendingPathComponent("isolated-profile"))
    let host = NSHostingView(rootView: Scene(fixture: fixture))
    let window = NSWindow(contentRect: CGRect(x: 150, y: 100, width: 900, height: 620),
        styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.level = .floating
    window.title = "Production Moku talk regression replay"
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .aqua)
    window.contentView = host
    window.orderFrontRegardless() // own fixture only; never activate/restart the live app
    defer { window.close() }
    try await wait("Scene did not mount") { fixture.state.windowVisible && fixture.state.capsuleFrame.width == 136 }
    var measurements: [[String: Any]] = []

    func capture(_ name: String) async throws {
        var target: SCWindow?
        for _ in 0..<30 {
            let content = try await SCShareableContent.currentProcess
            target = content.windows.first { $0.windowID == CGWindowID(window.windowNumber)
                && $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier
                && abs($0.frame.width - window.frame.width) < 1 && abs($0.frame.height - window.frame.height) < 1 }
            if target != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard let target else { throw Failure(description: "No full-size own window; refusing thumbnail evidence") }
        let configuration = SCStreamConfiguration()
        configuration.width = Int(window.frame.width * 2); configuration.height = Int(window.frame.height * 2)
        configuration.ignoreShadowsSingleWindow = true; configuration.showsCursor = false
        configuration.capturesAudio = false; configuration.captureMicrophone = false
        var captured: CGImage?
        let filter = SCContentFilter(desktopIndependentWindow: target)
        for _ in 0..<40 {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            if coversFullWindow(image) { captured = image; break }
            try await Task.sleep(for: .milliseconds(75))
        }
        guard let image = captured else { throw Failure(description: "Refusing transformed/thumbnail WindowServer evidence") }
        let bitmap = NSBitmapImageRep(cgImage: image)
        try bitmap.representation(using: .png, properties: [:])!.write(to: evidence.appendingPathComponent(name + ".png"))
    }
    func scroll() throws -> NativeMokuTalkScrollView {
        guard let view = find(host, NativeMokuTalkScrollView.self) else { throw Failure(description: "No production talk scroll view") }
        return view
    }
    func centered(_ name: String) throws {
        let view = try scroll()
        guard let eye = find(host, NativeMokuCapsuleEyeCanvas.self) else { throw Failure(description: "Blinking eyes were removed") }
        let eyeFrame = eye.convert(eye.bounds, to: nil), textFrame = view.convert(view.bounds, to: nil)
        let text = view.messageView
        try require(abs(eyeFrame.midY - textFrame.midY) < 1.5, "\(name): eyes are not centered with talk viewport")
        try require(view.contentSize.height <= NativeMokuTalkTypography.maximumHeight + 0.5, "More than four lines visible")
        try require(!text.isEditable && text.isSelectable && find(host, NSTextField.self) == nil, "Talk mounted an input field")
        let ink = text.layoutManager!.usedRect(for: text.textContainer!)
        let expectedInset = max(0, (view.contentSize.height - ceil(ink.height)) / 2)
        try require(text.alignment == .center && abs(text.textContainerInset.height - expectedInset) < 0.5
                    && abs(ink.midX - view.contentSize.width / 2) < 1, "Talk is not centered in its content viewport")
        try require(view.scrollerStyle == .overlay && view.autohidesScrollers && view.verticalScroller?.controlSize == .mini,
                    "Legacy or persistent scroller")
        measurements.append(["state": name, "capsule": NSStringFromRect(fixture.state.capsuleFrame),
            "viewportHeight": view.contentSize.height, "maximum": NativeMokuTalkTypography.maximumHeight,
            "eyeCenterY": eyeFrame.midY, "textCenterY": textFrame.midY,
            "scroller": "native overlay/mini/autohide", "text": text.string])
    }
    var previousScroll: NativeMokuTalkScrollView?
    for (index, record) in records.enumerated() {
        try fixture.install(record)
        try await wait("Tool record did not reach production text \(index)") { find(host, NativeMokuTalkScrollView.self)?.messageView.string == texts[index] }
        let currentScroll = try scroll()
        if let previousScroll { try require(previousScroll === currentScroll, "Replacement recreated the native scroll view") }
        previousScroll = currentScroll
        // Sample real native geometry throughout the height/replacement animation.
        for sample in 0..<25 {
            if let view = find(host, NativeMokuTalkScrollView.self), let eye = find(host, NativeMokuCapsuleEyeCanvas.self) {
                let textY = view.convert(view.bounds, to: nil).midY, eyeY = eye.convert(eye.bounds, to: nil).midY
                if abs(textY - eyeY) >= 2 {
                    try await capture("animation-misaligned-\(index)-\(sample)")
                    throw Failure(description: "Eye/text centers diverged: record=\(index) sample=\(sample) textY=\(textY) eyeY=\(eyeY) capsule=\(fixture.state.capsuleFrame)")
                }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        try centered("light-\(index)")
        try require(!fixture.state.inputOpen && fixture.state.dockHitRects.count == 1, "Separate bubble or input ownership remains")
        try await capture("light-\(index)")
    }
    let view = try scroll()
    view.contentView.scroll(to: CGPoint(x: 0, y: view.messageView.frame.height - view.contentSize.height))
    view.reflectScrolledClipView(view.contentView); view.flashScrollers()
    try await Task.sleep(for: .milliseconds(100))
    let last = (texts[3] as NSString).range(of: "这就是消息的结尾。")
    let glyphs = view.messageView.layoutManager!.glyphRange(forCharacterRange: last, actualCharacterRange: nil)
    let lastRect = view.messageView.layoutManager!.boundingRect(forGlyphRange: glyphs, in: view.messageView.textContainer!)
    try require(view.documentVisibleRect.intersects(lastRect), "Long text ending unreachable")
    try await capture("light-long-end-scrolling")
    try await Task.sleep(for: .seconds(2))
    try await capture("light-long-end-idle")

    fixture.scheme = .dark; window.appearance = NSAppearance(named: .darkAqua)
    try await Task.sleep(for: .milliseconds(300))
    try centered("dark-long")
    try await capture("dark-long-end")

    fixture.state.setInputOpen(true)
    try await wait("Production composer not focused") { (window.firstResponder as? NSTextView)?.isEditable == true }
    let editor = window.firstResponder as! NSTextView
    editor.insertText("preserved draft 草稿", replacementRange: NSRange(location: NSNotFound, length: 0))
    editor.setSelectedRange(NSRange(location: 2, length: 4))
    let selection = editor.selectedRange(), draft = fixture.draft.text
    try fixture.install(records[0]) // previously seen item must not resurrect
    try fixture.install(records[3])
    var fresh = records[1].objectValue!
    var transcript = fresh["transcript"]!.arrayValue!
    var item = transcript.last!.objectValue!; item["id"] = .text("new-during-input")
    transcript.append(.object(item)); fresh["transcript"] = .array(transcript)
    try fixture.install(.object(fresh))
    try await Task.sleep(for: .milliseconds(150))
    try require(window.firstResponder === editor && editor.selectedRange() == selection && fixture.draft.text == draft,
                "Incoming talk stole focus, selection or draft")
    try require(find(host, NativeMokuTalkScrollView.self) == nil, "Talk interrupted active input")
    try await capture("input-protected")
    fixture.state.setInputOpen(false)
    try await wait("Pending talk not shown after input") { find(host, NativeMokuTalkScrollView.self)?.messageView.string == texts[1] }
    try await Task.sleep(for: .milliseconds(500))
    try require(fixture.draft.text == draft, "Closing input discarded draft")
    try centered("after-input")
    try await capture("input-deferred-then-shown")
    fixture.state.dismissTalk(); fixture.presentation.refresh()
    try await Task.sleep(for: .milliseconds(500))
    try require(find(host, NativeMokuTalkScrollView.self) == nil && fixture.state.capsuleFrame.width == 136,
                "Dismissed talk reappeared on catalog refresh")

    // A new current execution cannot show an old execution's transcript.
    var successor = fresh
    var observation = successor["observation"]!.objectValue!
    var execution = observation["latestExecution"]!.objectValue!
    execution["executionId"] = .text("successor")
    observation["latestExecution"] = .object(execution); successor["observation"] = .object(observation)
    try fixture.install(.object(successor))
    try require(fixture.presentation.talkMessage == nil, "Talk leaked across execution scope")
    try await capture("dismissed-no-stale-replay")

    func newDelivery(_ id: String) throws {
        var record = records[2].objectValue!, items = record["transcript"]!.arrayValue!
        var item = items.last!.objectValue!; item["id"] = .text(id)
        items.append(.object(item)); record["transcript"] = .array(items)
        try fixture.install(.object(record))
    }
    fixture.interaction = true
    try newDelivery("permission-pending")
    try await Task.sleep(for: .milliseconds(150))
    try require(find(host, NativeMokuTalkScrollView.self) == nil, "Talk covered permission panel")
    fixture.interaction = false
    try await wait("Permission deferred talk lost") { find(host, NativeMokuTalkScrollView.self) != nil }
    fixture.state.setSearchActive(true)
    try await Task.sleep(for: .milliseconds(100))
    try newDelivery("search-pending")
    try require(!fixture.state.talkPresentation.presented, "Hidden talk marked as presented")
    fixture.state.setSearchActive(false)
    try await wait("Hidden pending message not restored") { fixture.state.talkPresentation.presented }
    fixture.voiceVisible = true
    try await Task.sleep(for: .milliseconds(500))
    try centered("voice-control-reserved")
    try require(abs(try scroll().contentSize.width - 448) < 1, "Talk overlaps existing voice controls")
    try await capture("voice-control-reserved")
    fixture.state.dismissTalk()
    try await Task.sleep(for: .milliseconds(500))
    guard let dispatchRecords = data["dispatchRecords"]?.arrayValue, dispatchRecords.count == 4 else {
        throw Failure(description: "Missing real create_thread lifecycle records")
    }
    try await replayDispatch(fixture: fixture, host: host, window: window, records: dispatchRecords, capture: capture)
    let report: [String: Any] = ["source": data["source"]?.stringValue ?? "unknown", "measurements": measurements,
        "checks": ["real Coordinator audit → snapshot and RuntimeState patch → Catalog → WorkspacePresentation → production Dock",
            "1/2/4/>4 lines; animation eye centers; light/dark; full ending; overlay scroller",
            "composer focus/selection/draft; deferred latest; dismissal refresh; execution isolation",
            "real create_thread pending/success/failure; 400×58 single row; voice/text; compact viewport; clickable input sheet",
            "production loudness cloud moves beneath the dispatch row without obscuring configuration or detail clicks"],
        "limits": "Mock Harness and isolated profile; no live provider/account, microphone or user runtime started"]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: evidence.appendingPathComponent("report.json"))
    await fixture.draft.dispose()
}

@MainActor private final class Delegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            var failure: String?
            do { try await replay() } catch { failure = String(describing: error) }
            let result: [String: Any] = ["ok": failure == nil, "message": failure ?? "production talk native replay"]
            let path = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("result.json")
            try! JSONSerialization.data(withJSONObject: result).write(to: path)
            print(failure.map { "FAIL: \($0)" } ?? "PASS production talk native replay")
            exit(failure == nil ? 0 : 1)
        }
    }
}
@main private enum Main {
    static func main() {
        let delegate = Delegate(), app = NSApplication.shared
        app.setActivationPolicy(.regular); app.delegate = delegate
        app.run()
    }
}
