import AppKit
import MokuseiCore
import MokuseiHarnessClaude
import MokuseiHarnessCodex
import MokuseiHarnessOpenCode
import MokuseiHarnessPi
import MokuseiPluginUI
import SwiftUI

// Visual thesis: the existing glass cards become apertures onto softly drifting
// harness-colored light, with unchanged type and spacing.
// Content: production tag reference, four real thread cards, local preview controls.
// Interaction: independent drifting clouds, 0.4s run-state fade, live appearance/intensity.
struct ThreadCloudDemo: View {
    let onAppearance: (Bool) -> Void
    @State private var dark = false
    @State private var mode = DemoStatus.running
    @State private var restarting = false
    private var running: Bool { mode == .running || mode == .background }
    @State private var wide = false
    @State private var frozen = false
    @State private var intensity = 1.0
    @State private var selectedTag: NativeOverviewFilter?
    @State private var startedAt = Date().timeIntervalSince1970 * 1_000 - 83_000
    @State private var endedAt: Double?

    private let filters: [NativeOverviewFilter] = [
        .init(tag: "Mokusei", count: 4, isDirectory: true),
        .init(tag: "界面设计", count: 2), .init(tag: "性能优化", count: 2)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            HStack {
                Text("TAG FILTER").tracking(1.2)
                Text("现有效果").foregroundStyle(.tertiary)
            }
            .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            .padding(.horizontal, 30).padding(.top, 14)
            NativeOverviewChrome(filters: filters, selectedTag: selectedTag?.tag ?? "",
                selectedKind: selectedTag.map { $0.isDirectory ? .directory : .semantic },
                strings: chromeStrings,
                onTagChange: { selectedTag = $0 }, onSettings: { dark.toggle() })
                .frame(height: 84).padding(.horizontal, 14)

            HStack(spacing: 16) {
                Picker("卡片状态", selection: $mode) {
                    ForEach(DemoStatus.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.frame(width: 190)
                Button("快速重启 · 150 ms") { restarting = true }.disabled(restarting)
                Toggle("宽卡片", isOn: $wide).toggleStyle(.checkbox)
            }.font(.system(size: 11)).padding(.horizontal, 30).padding(.bottom, 14)
            ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 20), count: wide ? 1 : 2), spacing: 24) {
                ForEach(DemoHarness.allCases) { harness in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 7) {
                            logo(harness, size: 16)
                            Text(harness.label).font(.system(size: 13, weight: .semibold))
                            Text(harness.colorDescription).font(.system(size: 11)).foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            Text(mode.rawValue)
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }.padding(.horizontal, 4)
                        card(harness)
                    }
                }
            }.padding(.horizontal, 30).padding(.bottom, 8)
            }
            Spacer(minLength: 16)
            controls
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(NativePalette.overview.canvas.swiftUI)
        .environment(\.colorScheme, dark ? .dark : .light)
        .environment(\.locale, Locale(identifier: "zh-Hans"))
        .onChange(of: dark) { _, value in onAppearance(value) }
        .onChange(of: mode) { _, value in
            if value == .running || value == .background { endedAt = nil }
            else { endedAt = Date().timeIntervalSince1970 * 1_000 }
        }
        .task(id: restarting) {
            guard restarting else { return }
            mode = .completed
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            mode = .running
            restarting = false
        }
    }

    private var chromeStrings: NativeOverviewChromeStrings {
        var strings = NativeOverviewChromeStrings()
        strings.settings = "切换深浅外观"
        return strings
    }

    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Thread 光云").font(.system(size: 22, weight: .medium))
                Text("Harness 主题色 · 原生卡片预览").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("深色", isOn: $dark).toggleStyle(.switch).controlSize(.small)
                .accessibilityIdentifier("thread-cloud-dark")
            Button(running ? "结束运行" : "重新运行") {
                if running { endedAt = Date().timeIntervalSince1970 * 1_000 }
                else { startedAt = Date().timeIntervalSince1970 * 1_000; endedAt = nil }
                mode = running ? .completed : .running
            }.controlSize(.large).accessibilityIdentifier("thread-cloud-running")
        }
        .padding(.horizontal, 30).padding(.top, 28)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Text("光云强度").font(.system(size: 12)).foregroundStyle(.secondary)
            Slider(value: $intensity, in: 0.4...1.6, step: 0.05).frame(width: 142)
                .accessibilityLabel("光云强度")
            Text("\(Int((intensity * 100).rounded()))%")
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary).frame(width: 36)
            Button("重置") { intensity = 1; frozen = false }.buttonStyle(.plain)
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Button(frozen ? "继续流动" : "暂停流动") { frozen.toggle() }
                .accessibilityIdentifier("thread-cloud-freeze")
            Text("本地预览").font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 30).padding(.bottom, 24).padding(.top, 12)
    }

    private func card(_ harness: DemoHarness) -> some View {
        HarnessThreadCard(identity: identity(harness), presentation: presentation(harness),
            status: mode.projection,
            emoji: emoji(harness), harnessLogo: AnyView(logo(harness, size: 12)))
            .environment(\.threadCardProviderColor, harness.accent)
            .environment(\.threadCardCloudPalette, harness.cloudPalette(intensity: intensity))
            .environment(\.threadCardCloudAnimationsEnabled, !frozen)
            .frame(height: 200)
            .background(DemoCardGlass())
            .clipShape(RoundedRectangle(cornerRadius: NativeGeometry.overviewCardRadius))
    }

    private func identity(_ harness: DemoHarness) -> ThreadCardIdentityView {
        let title: String
        let model: String
        let excerpt: String
        switch harness {
        case .codex:
            title = "优化 Thread 滚动性能"; model = "gpt-6.1"
            excerpt = "正在检查视图更新与布局开销，\n保留阅读位置，减少不必要的重绘。"
        case .claude:
            title = "打磨工作区的交互细节"; model = "Claude"
            excerpt = "正在梳理卡片状态和交互反馈，\n让等待、运行与完成都更容易辨认。"
        case .pi:
            title = "探索新的可视化方案"; model = "Pi Agent"
            excerpt = "正在比较不同的视觉方向，\n把有用的信息组织成清晰的层次。"
        case .opencode:
            title = "整理 Harness 运行流程"; model = "OpenCode"
            excerpt = "正在检查任务执行和状态同步，\n并复核后台工作结束后的展示。"
        }
        return .init(title: title, harness: .init(brandKey: harness.rawValue, label: harness.label, logoSource: ""),
                     model: model, effort: "High",
                     runtime: .init(startedAt: startedAt, endedAt: endedAt),
                     excerpt: running ? excerpt : "当前状态：\(mode.rawValue)。\n光云淡出，保留卡片的状态提示。")
    }

    private func presentation(_ harness: DemoHarness) -> ThreadCardPresentation {
        let usage: String
        let numeric: Double
        switch harness {
        case .codex: usage = "52.0K"; numeric = 52_000
        case .claude: usage = "28.4K"; numeric = 28_400
        case .pi: usage = "16.8K"; numeric = 16_800
        case .opencode: usage = "8.2K"; numeric = 8_200
        }
        let projection = ThreadCardProjection.standard(identity: .init(usage: .init(parts: [
            .init(suffix: "tokens", id: "tokens", value: usage, numericValue: numeric)
        ])), extensions: [])
        // A fixed one-cell fixture, using the same composition as a compact thread.
        let size = ThreadCardSize(cols: 1, rows: 1)
        return .init(projection: projection,
                     composition: .slots(size: size, identitySize: size, slots: [], key: "demo-identity"),
                     size: size, key: "demo-identity")
    }

    private func emoji(_ harness: DemoHarness) -> String {
        switch harness { case .codex: "⚡️"; case .claude: "✍️"; case .pi: "🌈"; case .opencode: "🛠️" }
    }

    @ViewBuilder private func logo(_ harness: DemoHarness, size: CGFloat) -> some View {
        switch harness {
        case .codex: CodexLogo(size: size)
        case .claude: ClaudeLogo(size: size)
        case .pi: PiLogo(size: size)
        case .opencode: OpenCodeLogo(size: size)
        }
    }
}

/// The production overview's glass material, kept beneath the preview light.
private struct DemoCardGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView(frame: .zero)
        view.style = .regular
        view.cornerRadius = NativeGeometry.overviewCardRadius
        view.setAccessibilityElement(false)
        return view
    }
    func updateNSView(_ view: NSGlassEffectView, context: Context) {}
}

private enum DemoStatus: String, CaseIterable {
    case running = "运行中", background = "后台运行中", waiting = "等你授权"
    case completed = "已完成", interrupted = "已中断", failed = "执行失败", idle = "等待开始"
    var projection: ThreadCardStatusProjection {
        switch self {
        case .running, .background: .init(kind: .running, label: rawValue)
        case .waiting: .init(kind: .attention, label: rawValue, icon: "ShieldCheck")
        case .completed: .init(kind: .completed, label: rawValue, terminal: .completed)
        case .interrupted: .init(kind: .interrupted, label: rawValue, terminal: .interrupted)
        case .failed: .init(kind: .failed, label: rawValue, terminal: .failed)
        case .idle: .init(kind: .idle, label: rawValue, icon: "CircleDashed")
        }
    }
}

final class DemoDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = DemoDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
NativeTypography.registerFonts()
let menu = NSMenu()
let applicationItem = NSMenuItem()
menu.addItem(applicationItem)
let applicationMenu = NSMenu()
applicationMenu.addItem(withTitle: "退出 Thread 光云预览", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
applicationItem.submenu = applicationMenu
app.mainMenu = menu

let size = NSSize(width: 820, height: 800)
let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
    styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
window.title = "Thread 光云 · Harness Preview"
window.minSize = NSSize(width: 800, height: 780)
window.isReleasedWhenClosed = false
window.isOpaque = false
window.backgroundColor = .clear
window.appearance = NSAppearance(named: .aqua)
let host = NativeContentHost(frame: NSRect(origin: .zero, size: size))
host.setContent(NSHostingView(rootView: ThreadCloudDemo(onAppearance: { dark in
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
})))
window.contentView = host
window.center()
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
app.run()
