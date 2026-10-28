import AppKit
import Observation
import ScreenCaptureKit
import SwiftUI
import MokuseiCore
import MokuseiHarnessCodex
import MokuseiPluginAPI
@testable import MokuseiPluginUI
@testable import MokuseiUI

private struct Controls: View {
    @Bindable var fixture: LandingFixture
    let resize: (CGSize) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Moku Landing").font(.system(size: 22, weight: .semibold))
            Text("原生交互预览").font(.subheadline).foregroundStyle(.secondary)
            Divider()
            Text(fixture.status).font(.system(size: 13)).frame(minHeight: 34, alignment: .leading)
            Picker("发送结果", selection: $fixture.outcome) {
                ForEach(LandingFixture.Outcome.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Button("重置为空工作区", action: fixture.reset)
            Button("演示首次成功派发") { fixture.simulate(.success) }.disabled(fixture.draft.submitting)
            Button("演示创建前失败") { fixture.simulate(.failure) }.disabled(fixture.draft.submitting)
            Button("归档全部会话", action: fixture.archive)
            Button("筛选无结果", action: fixture.filterToEmpty)
            Button("添加示例附件与目录") { Task { await fixture.addContext() } }
            Divider()
            Toggle("对照原来的空页面", isOn: $fixture.original)
            Toggle("深色外观", isOn: $fixture.dark)
            HStack {
                Button("宽窗口") { resize(.init(width: 1100, height: 720)) }
                Button("窄窗口") { resize(.init(width: 480, height: 620)) }
            }
            Text("主窗口可直接输入，Return 发送；输入 @ 选择目录。派发结果为模拟数据。").font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .buttonStyle(.bordered)
        .padding(22).frame(width: 290)
    }
}

private struct Failure: Error, CustomStringConvertible { let description: String }
@MainActor private func require(_ value: Bool, _ message: String) throws {
    if !value { throw Failure(description: message) }
}
@MainActor private func wait(_ message: String, until predicate: () -> Bool) async throws {
    for _ in 0..<300 {
        for window in NSApp.windows {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        if predicate() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw Failure(description: message)
}
@MainActor private func editor(in view: NSView) -> NSTextView? {
    if let view = view as? NSTextView, view.isEditable { return view }
    return view.subviews.lazy.compactMap { editor(in: $0) }.first
}
@MainActor private func accessible(_ id: String, in root: NSView) -> Bool {
    var visited = Set<ObjectIdentifier>()
    func find(_ object: NSObject) -> Bool {
        guard visited.insert(ObjectIdentifier(object)).inserted else { return false }
        let identifier = NSSelectorFromString("accessibilityIdentifier")
        if object.responds(to: identifier), object.perform(identifier)?.takeUnretainedValue() as? String == id { return true }
        let children = NSSelectorFromString("accessibilityChildren")
        if object.responds(to: children), let values = object.perform(children)?.takeUnretainedValue() as? [NSObject], values.contains(where: find) { return true }
        let legacy = NSSelectorFromString("accessibilityAttributeValue:")
        if object.responds(to: legacy), let values = object.perform(legacy, with: "AXChildren")?.takeUnretainedValue() as? [NSObject], values.contains(where: find) { return true }
        return (object as? NSView)?.subviews.contains(where: find) ?? false
    }
    _ = root.window?.accessibilityChildren()
    return find(root.window ?? root)
}

@MainActor private final class Delegate {
    let fixture = LandingFixture()
    var window: NSWindow!
    var controls: NSWindow!
    private var caretContrast: [String: Any] = [:]
    func mount() async {
        guard window == nil else { return }
        do {
            try await wait("SwiftUI window did not mount") {
                NSApp.windows.contains { $0.identifier?.rawValue == "landing-demo" }
            }
        } catch { finish(ok: false, message: String(describing: error)); return }
        window = NSApp.windows.first { $0.identifier?.rawValue == "landing-demo" }!
        window.setContentSize(.init(width: 1100, height: 720))
        window.minSize = .init(width: 360, height: 360)
        window.center(); window.makeKeyAndOrderFront(nil)
        fixture.openControls = { [weak self] in self?.showControls() }
        controls = NSWindow(contentRect: .init(x: 100, y: 100, width: 290, height: 590),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        controls.title = "演示控制"; controls.isReleasedWhenClosed = false
        controls.contentView = NSHostingView(rootView: Controls(fixture: fixture, resize: { [weak self] size in
            self?.window.setContentSize(size); self?.window.center(); self?.window.makeKeyAndOrderFront(nil)
        }))
        NSApp.activate(ignoringOtherApps: true)
        if CommandLine.arguments.contains("--verify") {
            do {
                try await verify()
                finish(ok: true, message: "PASS: native landing, dispatch, draft, archive, filter, narrow-window and attachment checks")
            } catch { finish(ok: false, message: String(describing: error)) }
        }
    }
    func showControls() {
        controls.setFrameTopLeftPoint(.init(x: max(20, window.frame.maxX - 100), y: window.frame.maxY - 50))
        controls.makeKeyAndOrderFront(nil)
    }

    private var output: URL { URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("evidence") }
    private func pressReturn() {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        window.sendEvent(event)
    }
    @discardableResult private func capture(_ name: String) async throws -> CGImage {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        // Limit enumeration and pixels to this demo's own window. A broad
        // desktop enumeration would require unrelated screen-recording access.
        for _ in 0..<4 {
            let content = try await SCShareableContent.currentProcess
            guard let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
                throw Failure(description: "Own demo window unavailable for capture")
            }
            let filter = SCContentFilter(desktopIndependentWindow: target)
            let config = SCStreamConfiguration()
            config.width = Int(window.contentView!.bounds.width * window.backingScaleFactor)
            config.height = Int(window.contentView!.bounds.height * window.backingScaleFactor)
            config.showsCursor = false; config.ignoreShadowsSingleWindow = true
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            let probe = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            probe.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 32))
            let pixels = probe.data!.assumingMemoryBound(to: UInt8.self)
            // WindowServer can briefly return a Stage Manager/minimizing
            // thumbnail. A geometrically valid model does not certify those pixels.
            if (0..<1024).filter({ pixels[$0 * 4 + 3] > 16 }).count < 1000 {
                window.deminiaturize(nil); window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                try await Task.sleep(for: .milliseconds(250))
                continue
            }
            guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                throw Failure(description: "Unable to encode native window capture")
            }
            try data.write(to: output.appendingPathComponent(name + ".png"))
            return image
        }
        throw Failure(description: "WindowServer did not provide a complete demo window for \(name)")
    }
    private func captureCaret(_ name: String, input: NSTextView, caret: CALayer, dim: Bool = false) async throws {
        input.updateInsertionPointStateAndRestartTimer(true)
        try await wait("Caret did not reach the requested phase for the contrast capture") {
            let opacity = caret.sublayers?.first { $0.name == "composer-insertion-core" }?.presentation()?.opacity ?? 0
            return dim ? opacity > 0 && opacity < 0.805 : opacity > 0.995
        }
        // WindowServer capture is asynchronous; hold the sampled phase so its
        // pixels cannot drift into the other half of the breathing cycle.
        let pausedTime = caret.convertTime(CACurrentMediaTime(), from: nil)
        caret.speed = 0
        caret.timeOffset = pausedTime
        defer {
            caret.speed = 1
            caret.timeOffset = 0
            caret.beginTime = 0
            caret.beginTime = caret.convertTime(CACurrentMediaTime(), from: nil) - pausedTime
        }
        let image = try await capture(name)
        try require(window.isKeyWindow && window.firstResponder === input && caret.superlayer != nil,
                    "Caret capture lost the native editor's focus")
        let root = window.contentView!
        var rect = input.convert(caret.frame, to: root)
        if !root.isFlipped { rect.origin.y = root.bounds.height - rect.maxY }
        let scale = CGFloat(image.width) / root.bounds.width
        let bitmap = NSBitmapImageRep(cgImage: image)
        let foreground = bitmap.colorAt(x: Int(rect.midX * scale), y: Int(rect.midY * scale))!.usingColorSpace(.sRGB)!
        // Sample above the line: a point to the right can hit placeholder ink.
        let background = bitmap.colorAt(x: Int((rect.midX + 14) * scale), y: Int((rect.minY - 12) * scale))!.usingColorSpace(.sRGB)!
        func luminance(_ color: NSColor) -> Double {
            func linear(_ value: CGFloat) -> Double {
                let value = Double(value)
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent) + 0.0722 * linear(color.blueComponent)
        }
        let a = luminance(foreground), b = luminance(background)
        let contrast = (max(a, b) + 0.05) / (min(a, b) + 0.05)
        caretContrast[(fixture.dark ? "dark" : "light") + (dim ? "-dim" : "")] = ["ratio": contrast, "widthPoints": Double(caret.bounds.width)]
        try JSONSerialization.data(withJSONObject: caretContrast, options: .prettyPrinted)
            .write(to: output.appendingPathComponent("caret-contrast.json"))
        try require(abs(caret.bounds.width - 2.6) < 0.01 && contrast >= (dim ? 3 : 4.5), "Rendered caret is too thin or faint: width=\(caret.bounds.width), contrast=\(contrast)")
        rect = rect.insetBy(dx: -18, dy: -14)
        let pixels = CGRect(x: rect.minX * scale, y: rect.minY * scale,
                            width: rect.width * scale, height: rect.height * scale).integral
        guard let crop = image.cropping(to: pixels),
              let data = NSBitmapImageRep(cgImage: crop).representation(using: .png, properties: [:]) else {
            throw Failure(description: "Unable to capture the rendered caret")
        }
        try data.write(to: output.appendingPathComponent(name + "-closeup.png"))
    }
    private func verify() async throws {
        window.level = .floating
        // Request this fixture's complete SwiftUI accessibility tree. This is
        // local app state and does not change system accessibility permission.
        let enableAX = NSSelectorFromString("accessibilitySetValue:forAttribute:")
        if NSApp.responds(to: enableAX) { _ = NSApp.perform(enableAX, with: true, with: "AXEnhancedUserInterface") }
        try await wait("Landing did not open its native editor") {
            self.fixture.scene.inputOpen && editor(in: self.window.contentView!) != nil
                && abs(self.fixture.scene.capsuleFrame.width - 680) < 1
        }
        try await Task.sleep(for: .milliseconds(600))
        let center = fixture.scene.capsuleFrame
        try require(abs(center.midY - window.contentView!.bounds.height / 2) < 1 && center.height == 76,
                    "Landing is not a centered 680 × 76 surface")
        try require(!accessible("moku-send", in: window.contentView!), "Empty composer still exposes Send")
        try await capture("01-landing")
        let input = editor(in: window.contentView!)!
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(input)
        input.updateInsertionPointStateAndRestartTimer(true)
        do {
            try await wait("Animated native insertion point did not mount") {
                input.layer?.sublayers?.contains { $0.name == "composer-insertion-point" } == true
            }
        } catch {
            throw Failure(description: "\(error); key=\(window.isKeyWindow), active=\(NSApp.isActive), focused=\(window.firstResponder === input), drawing=\(input.shouldDrawInsertionPoint), marked=\(input.hasMarkedText())")
        }
        let caret = input.layer!.sublayers!.first { $0.name == "composer-insertion-point" }!
        let core = caret.sublayers!.first { $0.name == "composer-insertion-core" }!
        var opacitySamples: [Float] = []
        for _ in 0..<26 {
            try await Task.sleep(for: .milliseconds(100))
            try require(caret.superlayer != nil && !caret.isHidden,
                        "Native blinking interrupted the breathing caret; key=\(window.isKeyWindow), active=\(NSApp.isActive), focused=\(window.firstResponder === input), frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown")")
            opacitySamples.append(core.presentation()?.opacity ?? core.opacity)
        }
        try require(opacitySamples.min()! < 0.82 && opacitySamples.max()! > 0.98 && opacitySamples.min()! >= 0.79,
                    "Caret did not breathe continuously between dim and bright phases")
        try require(caret.bounds.height > input.font!.pointSize && caret.bounds.height < input.font!.pointSize * 1.1 && abs(caret.bounds.width - 2.6) < 0.01,
                    "Caret did not use the approved short, slightly thicker geometry")
        try JSONSerialization.data(withJSONObject: opacitySamples.map(Double.init), options: .prettyPrinted)
            .write(to: output.appendingPathComponent("caret-breathing.json"))
        let before = caret.position
        input.insertText("优化 landing page", replacementRange: NSRange(location: 0, length: 0))
        try await wait("Native editing did not update the production draft") { self.fixture.draft.text == "优化 landing page" }
        try await wait("Typing did not animate the insertion point") { caret.animation(forKey: "typing") != nil }
        try await Task.sleep(for: .milliseconds(25))
        let during = caret.presentation()?.position ?? caret.position
        let target = caret.position
        try require(during.x > before.x && during.x < target.x, "Caret did not occupy an intermediate typing position")
        try await capture("01b-caret-moving")
        try await Task.sleep(for: .milliseconds(180))
        let settled = caret.presentation()?.position ?? caret.position
        try require(abs(settled.x - target.x) < 0.5, "Caret did not settle at the native insertion point")
        try await captureCaret("01c-breathing-caret", input: input, caret: caret)
        try await captureCaret("01d-dim-caret", input: input, caret: caret, dim: true)
        try require(accessible("moku-send", in: window.contentView!), "Nonempty composer does not expose Send")
        try JSONSerialization.data(withJSONObject: ["before": NSStringFromPoint(before), "during": NSStringFromPoint(during),
            "target": NSStringFromPoint(target), "settled": NSStringFromPoint(settled)], options: .prettyPrinted)
            .write(to: output.appendingPathComponent("caret-motion.json"))
        input.setMarkedText("ni", selectedRange: .init(location: 2, length: 0),
                            replacementRange: .init(location: NSNotFound, length: 0))
        try await wait("IME composition did not retire the animated caret") { input.hasMarkedText() && caret.superlayer == nil }
        input.insertText("你", replacementRange: .init(location: NSNotFound, length: 0))
        try await wait("IME commit lost the text or composition state") {
            !input.hasMarkedText() && self.fixture.draft.text == "优化 landing page你"
        }
        input.setSelectedRange(.init(location: 0, length: input.string.utf16.count))
        try await wait("Selecting text left a visible animated insertion point") { caret.superlayer == nil || caret.isHidden }
        window.makeFirstResponder(nil)
        try require(caret.superlayer == nil, "Losing focus retained an animated caret")
        window.makeFirstResponder(input)
        input.insertText("  ", replacementRange: .init(location: 0, length: input.string.utf16.count))
        try await wait("Clearing to whitespace left the Send button mounted") {
            self.fixture.draft.text == "  " && !accessible("moku-send", in: self.window.contentView!)
        }
        input.insertText("优化 landing page", replacementRange: .init(location: 0, length: input.string.utf16.count))
        try await wait("Restoring input did not restore Send") { accessible("moku-send", in: self.window.contentView!) }
        // SwiftUI's system accessibility environment is read-only. Exercise the
        // production layer's reduced-motion input without changing OS settings.
        let reduced = NativeComposerCaret()
        reduced.reduceMotion = true
        let origin = CGRect(x: 20, y: 10, width: 1, height: 20)
        reduced.show(at: origin, color: .textColor, in: input)
        reduced.show(at: origin.offsetBy(dx: 30, dy: 0), color: .textColor, in: input)
        try require(reduced.layer.animation(forKey: "typing") == nil && reduced.layer.frame.midX == 50.5,
                    "Reduce Motion did not position the production caret immediately")
        try require(reduced.layer.sublayers!.allSatisfy { $0.animation(forKey: "breathing") == nil },
                    "Reduce Motion retained breathing animations")
        reduced.remove()
        fixture.outcome = .failure
        pressReturn()
        try await wait("Return did not begin the production send path") { self.fixture.running }
        try require(fixture.landing && fixture.scene.inputOpen, "Pending dispatch left the center")
        try await wait("Failed send did not preserve its draft") {
            self.fixture.draft.error != nil && !self.fixture.draft.submitting
        }
        try require(fixture.landing && fixture.scene.inputOpen && fixture.draft.text == "优化 landing page", "Failed send lost centered editing")
        try await Task.sleep(for: .milliseconds(500))
        try await capture("02-failed")
        fixture.outcome = .success
        window.makeFirstResponder(input)
        pressReturn()
        try await wait("Successful dispatch did not publish the first thread") { self.fixture.hasThread }
        try await wait("Successful dispatch did not collapse the Dock") { !self.fixture.scene.inputOpen && self.fixture.scene.capsuleFrame.width == 168 }
        try await Task.sleep(for: .milliseconds(800))
        let bottom = NativeMokuCapsuleLayout.idleSurface(in: window.contentView!.bounds)
        try require(fixture.scene.capsuleFrame == bottom, "Successful dispatch missed the original Dock position")
        try await capture("03-dispatched")
        fixture.filterToEmpty()
        try await Task.sleep(for: .milliseconds(600))
        try require(!fixture.landing && fixture.scene.capsuleFrame == bottom, "Filtered empty result moved the Dock")
        try await capture("04-filter-empty")
        fixture.archive()
        try await wait("Archiving all threads did not restore center") { self.fixture.scene.inputOpen && self.fixture.scene.capsuleFrame.width == 680 }
        try await Task.sleep(for: .milliseconds(600))
        try await capture("05-archived")
        await fixture.addContext()
        try await Task.sleep(for: .milliseconds(600))
        try require(fixture.draft.directories.count == 1 && fixture.draft.attachments.count == 1, "Context chips missing")
        try require(accessible("moku-send", in: window.contentView!), "Attachment-only draft does not expose Send")
        try await capture("06-context")
        window.setContentSize(.init(width: 480, height: 620))
        try await Task.sleep(for: .milliseconds(700))
        let narrow = fixture.scene.capsuleFrame
        try require(narrow.width == 432 && narrow.minX >= 24 && narrow.maxX <= 456, "Narrow composer escaped its safe margins")
        try await capture("07-narrow")
        fixture.dark = true
        try await Task.sleep(for: .milliseconds(700))
        let darkInput = editor(in: window.contentView!)!
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(darkInput)
        darkInput.insertText("Moku", replacementRange: .init(location: 0, length: darkInput.string.utf16.count))
        darkInput.updateInsertionPointStateAndRestartTimer(true)
        try await wait("Dark composer did not mount its caret") {
            darkInput.layer?.sublayers?.contains { $0.name == "composer-insertion-point" } == true
        }
        try await Task.sleep(for: .milliseconds(180))
        let darkCaret = darkInput.layer!.sublayers!.first { $0.name == "composer-insertion-point" }!
        try await captureCaret("08-narrow-dark", input: darkInput, caret: darkCaret)
        darkInput.insertText("", replacementRange: .init(location: 0, length: darkInput.string.utf16.count))
        try await wait("Empty dark editor did not settle") { self.fixture.draft.text.isEmpty }
        try await Task.sleep(for: .milliseconds(180))
        try await captureCaret("08b-empty-dark", input: darkInput, caret: darkCaret)
        fixture.reset(); fixture.dark = false
        window.setContentSize(.init(width: 1100, height: 720))
        fixture.original = true
        try await Task.sleep(for: .milliseconds(700))
        try await capture("09-original")
        let measurements: [String: Any] = ["center": NSStringFromRect(center), "bottom": NSStringFromRect(bottom), "narrow": NSStringFromRect(narrow)]
        try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("measurements.json"))
    }
    private func finish(ok: Bool, message: String) {
        let root = Bundle.main.bundleURL.deletingLastPathComponent()
        try? JSONSerialization.data(withJSONObject: ["ok": ok, "message": message], options: .prettyPrinted)
            .write(to: root.appendingPathComponent("result.json"))
        print(message)
        exit(ok ? 0 : 1)
    }
}

@main @MainActor private struct Demo: App {
    @State private var delegate = Delegate()
    init() {
        do { try prepareIsolatedNativeReplay() }
        catch { print(error); exit(1) }
    }
    var body: some Scene {
        Window("Moku Landing Demo", id: "landing-demo") {
            LandingSurface(fixture: delegate.fixture).task { await delegate.mount() }
        }
        .nativeWorkspaceWindowStyle().defaultLaunchBehavior(.presented).defaultSize(width: 1100, height: 720)
        .commands {
            CommandMenu("演示") {
                Button("演示控制…") { delegate.showControls() }.keyboardShortcut("d")
                Button("重置为空工作区") { delegate.fixture.reset() }.keyboardShortcut("1")
                Button("演示首次成功派发") { delegate.fixture.simulate(.success) }.keyboardShortcut("2")
                Button("演示创建前失败") { delegate.fixture.simulate(.failure) }.keyboardShortcut("3")
                Button("归档全部会话") { delegate.fixture.archive() }.keyboardShortcut("4")
            }
        }
    }
}
