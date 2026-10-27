import AppKit
import MokuseiHarnessCodex
import MokuseiPluginUI
import SwiftUI

// Visual thesis: the approved glass lens on real production plan rows.
// Content: a complete thread card plus compact, tall and constrained apertures.
// Interaction: fixture changes, progress transitions and appearance/localization.
private enum Fixture: String, CaseIterable {
    case standard = "三步", long = "长计划", single = "单步"
    case pending = "全待执行", completed = "全完成", empty = "空计划"
}

private let titles = [
    "建立临时源码引用图，人工核对入口与删除证据",
    "删除确认无用的代码并复核 diff",
    "运行类型检查、lint、构建及现有测试，汇总证据"
]
private let extendedTitles = [
    "检查源码入口、插件注册和动态引用",
    "建立临时源码引用图，人工核对入口与删除证据",
    "逐项核对 Swift 入口、资源加载与运行时调用，记录可追溯且足够详细的删除依据",
    "删除确认无用的代码并复核 diff",
    "运行 TypeScript 类型检查和 lint",
    "构建原生 macOS 应用并核对界面表现",
    "检查深色模式与较窄卡片中的文本换行",
    "复核可访问性与状态切换",
    "汇总验证证据与尚未运行的检查"
]

private struct GlassTimelineDemo: View {
    let onAppearance: (Bool) -> Void
    @State private var fixture = Fixture.standard
    @State private var current = 0
    @State private var dark = false
    @State private var english = false

    private var labels: [String] {
        switch fixture {
        case .empty: []
        case .single: Array(titles.prefix(1))
        case .long: extendedTitles
        default: titles
        }
    }
    private var steps: [ThreadCardPlanStep] {
        labels.enumerated().map { index, title in
            let status: ThreadCardPlanStatus
            switch fixture {
            case .pending: status = .pending
            case .completed: status = .completed
            default: status = index < current ? .completed : index == current ? .inProgress : .pending
            }
            return .init(step: title, status: status)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("清透时间线").font(.system(size: 21, weight: .medium))
                Text("生产组件预览").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Toggle("深色", isOn: $dark).toggleStyle(.switch).controlSize(.small)
            }.padding(.horizontal, 26).padding(.top, 16).padding(.bottom, 12)
            HStack(spacing: 14) {
                Picker("计划", selection: $fixture) {
                    ForEach(Fixture.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 350)
                Button(current >= labels.count ? "重新开始" : "下一步") {
                    current = current >= labels.count ? 0 : current + 1
                }
                .disabled(fixture == .empty || fixture == .pending || fixture == .completed)
                .accessibilityIdentifier("glass-timeline-next")
                Spacer(minLength: 0)
                Toggle("English", isOn: $english).toggleStyle(.checkbox)
            }.font(.system(size: 11)).padding(.horizontal, 26).padding(.bottom, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    threadCard
                        .frame(height: 200)
                        .background(DemoGlass())
                        .background(wallpaper)
                        .clipShape(RoundedRectangle(cornerRadius: NativeGeometry.overviewCardRadius))
                    HStack(alignment: .top, spacing: 20) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("常规 · 360 × 200").font(.system(size: 11)).foregroundStyle(.secondary)
                            aperture(.compact, height: 200)
                            Text("受限高度 · 保留当前步骤").font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 8)
                            aperture(.compact, height: 94)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text("高卡片 · 360 × 416").font(.system(size: 11)).foregroundStyle(.secondary)
                            aperture(.tall, height: 416)
                        }
                        Spacer(minLength: 0)
                    }
                }.padding(.horizontal, 26).padding(.bottom, 16)
            }
        }
        .background(NativePalette.overview.canvas.swiftUI)
        .environment(\.colorScheme, dark ? .dark : .light)
        .environment(\.locale, Locale(identifier: english ? "en" : "zh-Hans"))
        .environment(\.threadCardCloudAnimationsEnabled, false)
        .onChange(of: dark) { _, value in onAppearance(value) }
        .onChange(of: fixture) { _, _ in current = 0 }
    }

    private func aperture(_ variant: ThreadCardVariantId, height: CGFloat) -> some View {
        CardPlanLadder(steps: steps, variant: variant)
            .padding(.horizontal, 18).padding(.vertical, 16)
            .frame(width: 360, height: height)
            .background(NativeCloudLoading(palette: CodexLogo.threadCardCloudPalette, isAnimating: false))
            .background(DemoGlass()).background(wallpaper)
            .clipShape(RoundedRectangle(cornerRadius: NativeGeometry.overviewCardRadius))
    }

    private var threadCard: some View {
        let cell = ThreadCardSize(cols: 1, rows: 1)
        let size = ThreadCardSize(cols: 2, rows: 1)
        let projection = ThreadCardProjection.standard(identity: .init(usage: .init(parts: [
            .init(suffix: "tokens", id: "tokens", value: "54.3K", numericValue: 54_300)
        ])), extensions: [.todo(steps: steps)])
        let placement = ThreadCardExtensionPlacement(kind: .todo, component: .todo, variant: .compact,
            col: 1, row: 0, allowedSizes: [cell], preferredSize: cell, selectedSize: cell)
        let identity = ThreadCardSizeSelection(component: .identity, allowedSizes: [cell], preferredSize: cell, selectedSize: cell)
        let presentation = ThreadCardPresentation(projection: projection,
            composition: .standard(size: size, identity: identity, placements: [placement], key: "plan-preview"),
            size: size, key: "plan-preview")
        return HarnessThreadCard(identity: .init(title: "清理并验证 Mokusei 无用代码",
            harness: .init(brandKey: "codex", label: "Codex", logoSource: ""), model: "gpt-6.1-sol", effort: "高",
            runtime: .init(startedAt: 1_792_310_000_000, endedAt: 1_792_310_091_000),
            steer: "Swift 只读复核已完成：高置信候选 app/macos/Sources/OpenA…",
            excerpt: "Clarifying export reference counting"), presentation: presentation,
            status: .init(kind: .running, label: "运行中"), emoji: "🧹", harnessLogo: AnyView(CodexLogo(size: 12)))
            .environment(\.threadCardProviderColor, NativePalette.pair(0x3941ff, 0x8f94ff).swiftUI)
            .environment(\.threadCardCloudPalette, CodexLogo.threadCardCloudPalette)
    }

    private var wallpaper: some View {
        LinearGradient(colors: dark
            ? [Color(red: 0.26, green: 0.19, blue: 0.31), Color(red: 0.4, green: 0.24, blue: 0.19)]
            : [Color(red: 0.9, green: 0.63, blue: 0.7), Color(red: 1, green: 0.7, blue: 0.45)],
            startPoint: .bottomLeading, endPoint: .topTrailing)
    }
}

private struct DemoGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView(frame: .zero)
        view.style = .regular
        view.cornerRadius = NativeGeometry.overviewCardRadius
        view.setAccessibilityElement(false)
        return view
    }
    func updateNSView(_ view: NSGlassEffectView, context: Context) {}
}

private final class DemoDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
private let delegate = DemoDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
NativeTypography.registerFonts()
let menu = NSMenu()
let item = NSMenuItem()
menu.addItem(item)
let applicationMenu = NSMenu()
applicationMenu.addItem(withTitle: "退出时间线预览", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
item.submenu = applicationMenu
app.mainMenu = menu
let size = NSSize(width: 1000, height: 820)
let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
    styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
window.title = "清透时间线 · Production Preview"
window.minSize = NSSize(width: 980, height: 670)
window.isReleasedWhenClosed = false
window.isOpaque = false
window.backgroundColor = .clear
window.appearance = NSAppearance(named: .aqua)
let host = NativeContentHost(frame: NSRect(origin: .zero, size: size))
host.setContent(NSHostingView(rootView: GlassTimelineDemo(onAppearance: { dark in
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
})))
window.contentView = host
window.center()
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
app.run()
