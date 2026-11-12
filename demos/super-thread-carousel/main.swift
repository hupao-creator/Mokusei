import AppKit
import SwiftUI
import MokuseiPluginUI
@testable import MokuseiApplications

private struct CardShell<Content: View>: View {
    var providesCardSurface = false
    @ViewBuilder let content: Content
    var body: some View {
        content.frame(width: 360, height: 456)
            .background(providesCardSurface ? Color.clear : NativePalette.overview.surface.swiftUI)
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .overlay {
                if !providesCardSurface { RoundedRectangle(cornerRadius: 22).stroke(NativePalette.overview.lineSoft.swiftUI) }
            }
    }
}

private struct DemoView: View {
    @State private var model = DemoModel()
    let fixtures: [String: ReportFixture]
    @State private var dark = false
    @State private var active = true
    @State private var slow = false
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .firstTextBaseline) {
                Text("Super Thread").font(NativeTypography.inter(size: 25, weight: 620))
                Text("轮播集合 · 原生预览").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Toggle("深色", isOn: $dark).toggleStyle(.switch).controlSize(.small)
            }
            HStack(spacing: 10) {
                ForEach(DemoModel.tags, id: \.self) { tag in
                    Button(tag) { model.tag = tag }
                        .buttonStyle(.bordered).tint(model.tag == tag ? .accentColor : .secondary)
                        .accessibilityAddTraits(model.tag == tag ? .isSelected : [])
                }
                Spacer()
                Text("封面左右滑动 · 每 8 秒切换").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                Text("封面横向轮播 · 正文淡出 / 淡入").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Toggle("慢速 ×3", isOn: $slow).toggleStyle(.checkbox).font(.system(size: 11))
            }
            ScrollView {
                LazyVGrid(columns: [.init(.adaptive(minimum: 360, maximum: 360), spacing: 16)], alignment: .center, spacing: 22) {
                    if !model.projection.members.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            CardShell(providesCardSurface: true) {
                                NativeReportCollection(props: model.projection.members.map { fixtures[$0.id]!.props },
                                    active: active && model.reading == nil, slow: slow, onSelection: { _ in },
                                    openThread: { reference in
                                        if let report = model.reports.first(where: { $0.id == reference.threadID.string }) { model.open(report) }
                                    })
                                    .id("\(model.tag)-\(slow)")
                            }
                            Text("已查看 · \(model.projection.members.count) 篇").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(model.projection.individual) { report in
                        VStack(alignment: .leading, spacing: 10) {
                            CardShell { ProductionCard(fixture: fixtures[report.id]!, open: { model.open(report) }) }
                            Text(lastClosedLabel(report)).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }.padding(.vertical, 2)
            }
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("关闭后超过 5 分钟的报告按当前标签归组；已归组报告短读后仍保留资格。")
                    Text("至少 2 篇才成组；单次前台阅读超过 2 分钟才移出。切换轮播页不计为阅读。")
                        .foregroundStyle(.tertiary)
                }.font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                if model.offset > 0 { Text("+\(Int(model.offset / 60)) 分钟").font(.system(size: 11)).monospacedDigit() }
                Button("时间 +10 分钟") { model.advanceDemoTime() }
                Button("重置") { model.reset() }
            }.buttonStyle(.bordered).controlSize(.small)
        }.padding(30)
            .background(dark ? Color(white: 0.105) : Color(red: 0.95, green: 0.945, blue: 0.93))
            .preferredColorScheme(dark ? .dark : .light)
            .onReceive(clock) { date in model.tick(at: date) }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in active = true }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in active = false }
            .sheet(item: $model.reading) { report in
                VStack(alignment: .leading, spacing: 24) {
                    HStack {
                        Text(report.emoji).font(.system(size: 32))
                        Spacer()
                        Button("返回卡片") { model.reading = nil }.keyboardShortcut(.cancelAction)
                    }
                    Text(report.title).font(NativeTypography.inter(size: 26, weight: 620))
                    Text(report.summary).font(.system(size: 16)).lineSpacing(7)
                    Divider()
                    Text("这是轮播内容预览，不模拟真实阅读计时。生产中，已归组报告单次前台阅读超过 2 分钟才移出；关闭后重新计时 5 分钟。")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                    Text("此处为演示阅读页，未连接真实报告或 Agent。")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                    Spacer()
                }.padding(32).frame(width: 520, height: 360)
                    .preferredColorScheme(dark ? .dark : .light)
            }
    }
    private func lastClosedLabel(_ report: ReportSample) -> String {
        guard let opened = model.closedAt[report.id] else { return "尚未打开" }
        let minutes = max(0, Int(model.now.timeIntervalSince(opened) / 60))
        return minutes == 0 ? "刚刚关闭" : "\(minutes) 分钟前关闭"
    }
}

@MainActor private final class Delegate: NSObject, NSApplicationDelegate {
    let fixtures: [String: ReportFixture]
    var window: NSWindow?
    init(fixtures: [String: ReportFixture]) { self.fixtures = fixtures }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1192, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Super Thread · Production Carousel"
        window.minSize = .init(width: 840, height: 660)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: DemoView(fixtures: fixtures))
        self.window = window
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate()
        let menu = NSMenu(), item = NSMenuItem(), submenu = NSMenu()
        menu.addItem(item); item.submenu = submenu
        submenu.addItem(withTitle: "退出 Carousel Demo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        NSApp.mainMenu = menu
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main private struct App {
    @MainActor static func main() async throws {
        try prepareIsolatedNativeReplay()
        let now = Date()
        let fixtures = try Dictionary(uniqueKeysWithValues: ReportSample.samples.map { ($0.id, try ReportFixture($0, now: now)) })
        if CommandLine.arguments.contains("--headless") {
            try DemoModel.describe()
            try await exportProductionProjection(fixtures: fixtures)
            return
        }
        runGUI(fixtures: fixtures)
    }
    @MainActor private static func runGUI(fixtures: [String: ReportFixture]) {
        NativeTypography.registerFonts()
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = Delegate(fixtures: fixtures); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
