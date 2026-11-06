// Production cards with synthetic content; no runtime or user data access.
import AppKit
import SwiftUI
import ScreenCaptureKit
import MokuseiPluginUI

private let screenshotText = "目前确认了两个关键点：数字表示整个 worktree 相对当前 HEAD 的未提交改动，并不等于这次执行的产出；原生 diff 面板已被移除，但后端仍保留文件列表和 diff 查询。\n\n冲突数、暂存/未暂存数、上游领先/落后数也已传到卡片层，接下来会检查这些数据的展示位置与更新方式，并补充验证。"
private let longText = (1...30).map { "第\($0)行 More content 👩🏽‍💻 稳定截断" }.joined(separator: "\n")

private struct Scenario {
    let name: String
    let width: CGFloat
    let height: CGFloat
    var text = longText
    var expanded = false
    var metadata = true
    var steer = false
    var extensions = false
    var rasterScale: CGFloat = 1
}

private struct Card: View {
    let scenario: Scenario
    var body: some View {
        let projection = ThreadCardProjection.standard(identity: .init(
            recentTools: scenario.expanded ? [
                .init(kind: .search, name: "Search", summary: "tool row remains visible", status: .completed),
                .init(kind: .command, name: "Build", summary: "second tool row", status: .running),
                .init(kind: .file, name: "Edit", summary: "third tool row", status: .completed),
            ] : nil,
            usage: scenario.metadata ? .init(parts: [.init(suffix: "tokens", id: "tokens", value: "49.9K", numericValue: 49900)]) : nil),
            extensions: scenario.extensions ? [.todo(steps: [.init(step: "Extension stays in its own cell", status: .inProgress)])] : [])
        let base = try! composeThreadCard(projection, layoutContext: .init(availableCols: 3))
        let size = ThreadCardSize(cols: 1, rows: 2)
        let presentation = scenario.expanded ? ThreadCardPresentation(projection: projection,
            composition: .slots(size: size, identitySize: size, slots: [], key: "expanded"), size: size, key: "expanded") : base
        HarnessThreadCard(identity: .init(title: "调研 Git 扩展并提出改进建议 very long title 👩🏽‍💻",
            model: scenario.metadata ? "gpt-6.1-sol" : nil, effort: scenario.metadata ? "Medium" : nil,
            runtime: scenario.metadata ? .init(startedAt: 0, endedAt: 61000) : nil,
            steer: scenario.steer ? "Extra steer metadata must retain one line" : nil,
            excerpt: scenario.text), presentation: presentation, emoji: "🔎")
            .environment(\.threadCardCloudAnimationsEnabled, false)
            .environment(\.scenePhase, .active)
            .environment(\.threadCardTextRasterScale, scenario.rasterScale)
            .frame(width: scenario.width, height: scenario.height)
            .background(Color(white: 0.13), in: RoundedRectangle(cornerRadius: 22))
            .padding(12)
            .background(Color(white: 0.25))
            .preferredColorScheme(.dark)
    }
}

@MainActor private func run() async throws {
    let directory = URL(fileURLWithPath: Bundle.main.object(forInfoDictionaryKey: "OutputDirectory") as! String)
    let window = NSWindow(contentRect: .init(x: 100, y: 100, width: 800, height: 650),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.level = .floating
    defer { window.close() }
    let scenarios: [Scenario] = [
        .init(name: "screenshot-220", width: 360, height: 220, text: screenshotText),
        .init(name: "screenshot-260", width: 360, height: 260, text: screenshotText),
        .init(name: "compact-180", width: 360, height: 180),
        .init(name: "normal-220", width: 360, height: 220),
        .init(name: "tall-340", width: 360, height: 340),
        .init(name: "short", width: 360, height: 260, text: "短回复 OK 👩🏽‍💻"),
        .init(name: "empty", width: 360, height: 220, text: ""),
        .init(name: "narrow", width: 240, height: 220, steer: true),
        .init(name: "minimal-metadata", width: 360, height: 260, metadata: false),
        .init(name: "expanded-tools", width: 360, height: 456, expanded: true, steer: true),
        .init(name: "extension", width: 736, height: 220, extensions: true),
        .init(name: "raster-2", width: 360, height: 260, rasterScale: 2),
    ]
    for scenario in scenarios {
        let host = NSHostingView(rootView: Card(scenario: scenario))
        window.contentView = host
        window.setContentSize(.init(width: scenario.width + 24, height: scenario.height + 24))
        window.makeKeyAndOrderFront(nil); NSApp.activate()
        try await Task.sleep(for: .milliseconds(400))
        host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let content = try await SCShareableContent.currentProcess
        guard let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            fatalError("Own window unavailable")
        }
        let config = SCStreamConfiguration()
        config.width = Int(host.bounds.width * window.backingScaleFactor)
        config.height = Int(host.bounds.height * window.backingScaleFactor)
        config.ignoreShadowsSingleWindow = true; config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: config)
        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
            .write(to: directory.appendingPathComponent(scenario.name + ".png"))
        print("CAPTURE \(scenario.name) \(scenario.width)x\(scenario.height)")
    }
}

@MainActor private final class Delegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do { try await run(); print("PASS card height captures"); exit(0) }
            catch { print("FAIL \(error)"); exit(1) }
        }
    }
}

@main private enum Main {
    static func main() {
        let delegate = Delegate(), app = NSApplication.shared
        app.setActivationPolicy(.accessory); app.delegate = delegate; app.run()
    }
}
