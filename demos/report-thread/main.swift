import AppKit
import Observation
import ScreenCaptureKit
import SwiftUI
import MokuseiCore
import MokuseiHarnessClaude
import MokuseiHarnessCodex
import MokuseiPluginUI
import MokuseiUI

enum ReportRoute: Equatable {
    case card, report, execution(ExecutionFixture)
    var isOpen: Bool { self != .card }
    var selection: ExecutionFixture? { if case .execution(let item) = self { item } else { nil } }
}

@MainActor @Observable final class DemoState {
    let report = ReportFixture.groupedSample
    let scene = NativeMokuSceneState()
    let draft = NativeComposerDraft(services: .init(stageFiles: { _, _ in [] }, discardAttachments: { _ in }))
    var route: ReportRoute = .card
    var dark = false
    var reduceMotion = false
    var frames: [String: CGRect] = [:]
    func navigate(_ next: ReportRoute) {
        withAnimation(reduceMotion ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: 0.42)) { route = next }
    }
    func back() { navigate(route.selection == nil ? .card : .report) }
}

private struct ReportDemo: View {
    @Bindable var state: DemoState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        NativeMokuScene(state: state.scene) {
            ZStack {
                backdrop
                if state.route.isOpen {
                    reader.padding(.horizontal, 48).padding(.top, 84).padding(.bottom, 100)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                } else {
                    CardComparison(report: state.report) { state.navigate(.report) }
                        .offset(y: -12)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .overlay(alignment: .top) { controls.padding(.top, 23).padding(.horizontal, 48) }
        } thread: { EmptyView() } dock: {
            NativeMokuDock(state: state.scene, draft: state.draft, cwd: "/demo/Mokusei", mode: .idle,
                loadMentionDirectories: { [] }, onSend: { _ in }, onCancel: {})
                .allowsHitTesting(false).accessibilityHidden(true)
        } settings: { EmptyView() }
        .coordinateSpace(name: "demo")
        .environment(\.locale, Locale(identifier: "zh-Hans"))
        .preferredColorScheme(state.dark ? .dark : .light)
        .modifier(NativeWorkspaceWindowSurface())
        .onChange(of: reduceMotion, initial: true) { _, value in state.reduceMotion = value }
        .nativeReadingEscape(perform: state.route.isOpen ? { state.back() } : nil)
        .onExitCommand { state.back() }
    }

    private var backdrop: some View {
        LinearGradient(colors: state.dark
            ? [Color(red: 0.16, green: 0.19, blue: 0.24), Color(red: 0.25, green: 0.22, blue: 0.30), Color(red: 0.15, green: 0.25, blue: 0.30)]
            : [Color(red: 0.92, green: 0.89, blue: 0.87), Color(red: 0.80, green: 0.86, blue: 0.94), Color(red: 0.88, green: 0.78, blue: 0.82)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay(alignment: .topTrailing) {
                Ellipse().fill(Color.cyan.opacity(state.dark ? 0.1 : 0.2))
                    .frame(width: 650, height: 430).blur(radius: 120).offset(x: 130, y: -130)
            }
            .ignoresSafeArea().accessibilityHidden(true)
    }

    private var controls: some View {
        HStack {
            Text("REPORT THREAD").font(NativeTypography.inter(size: 10, weight: 650))
                .tracking(1.8).foregroundStyle(NativePalette.overview.muted.swiftUI).padding(.leading, 90)
            Spacer()
            HStack(spacing: 4) {
                modeButton("卡片", route: .card, key: "1")
                modeButton("展开", route: .report, key: "2")
                modeButton("Execution", route: .execution(state.report.executions[0]), key: "3")
            }.padding(4).background(.regularMaterial, in: Capsule())
            Button { state.dark.toggle() } label: {
                Image(systemName: state.dark ? "sun.max" : "moon").frame(width: 32, height: 32)
            }.buttonStyle(.plain).background(.regularMaterial, in: Circle()).padding(.leading, 8)
                .help("切换浅色 / 深色").accessibilityLabel("切换主题")
        }
    }

    private func modeButton(_ label: String, route: ReportRoute, key: KeyEquivalent) -> some View {
        let selected = route.selection != nil ? state.route.selection != nil : state.route == route
        return Button { state.navigate(route) } label: {
            Text(label).font(NativeTypography.inter(size: 11, weight: selected ? 650 : 450))
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(selected ? NativePalette.thread.canvas.swiftUI : .clear, in: Capsule())
        }.buttonStyle(.plain).keyboardShortcut(key, modifiers: .command)
            .foregroundStyle(NativePalette.thread.ink.swiftUI)
    }

    private var reader: some View {
        GeometryReader { geometry in
            let usableWidth = geometry.size.width - 16
            let sideWidth = usableWidth * (state.route.selection == nil ? 0.2 : 0.5)
            HStack(spacing: 16) {
                ReportDocument()
                    .clipShape(RoundedRectangle(cornerRadius: 14)).padding(8)
                    .background(NativePalette.thread.canvas.swiftUI, in: RoundedRectangle(cornerRadius: 22))
                    .nativeReadingPanelClose(label: "关闭报告 · Esc", overlaysContent: true) { state.navigate(.card) }
                    .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(NativePalette.thread.line.swiftUI, lineWidth: 1) }
                    .frame(width: usableWidth - sideWidth, height: geometry.size.height)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("demo")) } action: { state.frames["report"] = $0 }
                sidecard
                    .frame(width: sideWidth, height: geometry.size.height)
                    .background(NativePalette.thread.canvas.swiftUI, in: RoundedRectangle(cornerRadius: 22))
                    .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(NativePalette.thread.line.swiftUI, lineWidth: 1) }
                    .clipShape(RoundedRectangle(cornerRadius: 22))
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("demo")) } action: { state.frames["sidecard"] = $0 }
            }
        }
    }

    private var sidecard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                if state.route.selection != nil {
                    Button { state.navigate(.report) } label: {
                        Label("关联执行", systemImage: "chevron.left")
                    }.buttonStyle(.plain).accessibilityLabel("返回关联执行列表")
                } else {
                    Text("关联执行").fontWeight(.semibold)
                    Text("\(state.report.executions.count)").foregroundStyle(NativePalette.thread.faint.swiftUI)
                }
                Spacer()
                Text(state.route.selection == nil ? "2 : 8" : "5 : 5")
                    .font(NativeTypography.mono(size: 9)).foregroundStyle(NativePalette.thread.faint.swiftUI)
                    .accessibilityLabel(state.route.selection == nil ? "侧卡与报告比例二比八" : "侧卡与报告比例五比五")
            }
            .font(NativeTypography.inter(size: 12)).foregroundStyle(NativePalette.thread.muted.swiftUI)
            .frame(height: 52).padding(.horizontal, 20)
            Divider().overlay(NativePalette.thread.lineSoft.swiftUI)
            if let execution = state.route.selection {
                ExecutionReader(execution: execution).id(execution.id)
                    .transition(.opacity)
            } else {
                NativeScrollView {
                    VStack(spacing: 6) {
                        ForEach(state.report.executions) { execution in
                            ExecutionRow(execution: execution) { state.navigate(.execution(execution)) }
                        }
                    }.padding(10)
                }
                .transition(.opacity)
                Spacer(minLength: 0)
                Text("查看生成报告时关联的执行")
                    .font(NativeTypography.inter(size: 10)).foregroundStyle(NativePalette.thread.faint.swiftUI)
                    .padding(20)
            }
        }
    }
}

private struct CardComparison: View {
    let report: ReportFixture
    let open: () -> Void
    private let presentation = try! composeThreadCard(.standard(identity: .init(), extensions: []),
        layoutContext: .init(availableCols: 1))
    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Agent Thread").font(NativeTypography.inter(size: 11, weight: 550))
                    .foregroundStyle(NativePalette.overview.muted.swiftUI).padding(.leading, 18)
                HarnessThreadCard(identity: .init(title: "梳理 Agent 工具调用路径",
                    harness: .init(brandKey: "codex", label: "Codex", logoSource: CodexLogo.source),
                    model: "GPT-6", effort: "High", excerpt: "对照两个后台 Agent 的工具调用记录，梳理调用频次、成功情况与统计边界。"),
                    presentation: presentation, emoji: "🔎", harnessLogo: AnyView(CodexLogo(size: 12)))
                    .modifier(ComparisonCardSurface())
                    .accessibilityLabel("Agent Thread 样式对照")
            }
            VStack(alignment: .leading, spacing: 14) {
                Text("Report Thread").font(NativeTypography.inter(size: 11, weight: 550))
                    .foregroundStyle(NativePalette.overview.muted.swiftUI).padding(.leading, 18)
                ReportCard(report: report, open: open).modifier(ComparisonCardSurface())
            }
        }
        // This AppKit fixture has no SwiftUI Scene to publish its active phase.
        // Both production excerpts must receive the same visible-scene input.
        .environment(\.scenePhase, .active)
    }
}

/// The proposal and production reference use the Overview's same 1×1 shell.
private struct ComparisonCardSurface: ViewModifier {
    func body(content: Content) -> some View {
        content.frame(width: NativeGeometry.overviewCard.width, height: NativeGeometry.overviewCard.height)
            .background(NativePalette.overview.surface.swiftUI, in: RoundedRectangle(cornerRadius: NativeGeometry.overviewCardRadius))
            .overlay {
                RoundedRectangle(cornerRadius: NativeGeometry.overviewCardRadius)
                    .stroke(NativePalette.overview.lineSoft.swiftUI, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: NativeGeometry.overviewCardRadius))
    }
}

private struct ReportCard: View {
    let report: ReportFixture
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 0) {
                Text(report.title).font(NativeTypography.inter(size: 15, weight: 620))
                    .lineLimit(1, reservesSpace: true).truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.trailing, 52).help(report.title)
                HStack(spacing: 5) {
                    ForEach(report.harnesses, id: \.self) { harness in
                        HStack(spacing: 3) {
                            FixtureHarnessLogo(harness: harness, size: 12)
                            let count = report.executions.filter { $0.harness == harness }.count
                            if count > 1 { Text("×\(count)").monospacedDigit() }
                        }.font(NativeTypography.inter(size: 11)).foregroundStyle(NativePalette.overview.faint.swiftUI)
                            .help(harness.rawValue).accessibilityLabel(harness.rawValue)
                    }
                    Text("13 小时前").font(NativeTypography.inter(size: 11))
                        .foregroundStyle(NativePalette.overview.faint.swiftUI)
                }.padding(.top, 5).padding(.trailing, 52)
                ThreadCardExcerpt(content: report.shortDescription)
                    .lineLimit(5).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10)
            }.padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .overlay(alignment: .topTrailing) {
                    ThreadCardProviderStatus(label: report.title, brandKey: "", emoji: report.emoji)
                        .padding(.top, 12).padding(.trailing, 17)
                }
                .contentShape(RoundedRectangle(cornerRadius: 22))
        }
        .buttonStyle(.plain).foregroundStyle(NativePalette.overview.ink.swiftUI)
        .environment(\.threadCardUsesFlatMaterials, true)
        .accessibilityLabel("打开报告：\(report.title)")
        .accessibilityValue(report.shortDescription + " · " + report.harnesses.map(\.rawValue).joined(separator: "、"))
    }
}

private struct ExecutionRow: View {
    let execution: ExecutionFixture
    let open: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 7) {
                    Text(execution.emoji).font(.system(size: 17))
                    Text(execution.role).font(NativeTypography.inter(size: 10, weight: 600))
                        .foregroundStyle(NativePalette.thread.muted.swiftUI)
                    Spacer(minLength: 0)
                    NativeIcon(name: "ChevronRight", size: 11).foregroundStyle(NativePalette.thread.faint.swiftUI)
                }
                Text(execution.title).font(NativeTypography.inter(size: 13, weight: 550))
                    .lineLimit(3).lineSpacing(3).frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 4) {
                    FixtureHarnessLogo(harness: execution.harness, size: 11)
                        .help(execution.harness.rawValue).accessibilityLabel(execution.harness.rawValue)
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(NativePalette.thread.success.swiftUI)
                    Text("已完成")
                    Spacer(minLength: 0)
                    Text(execution.usage).monospacedDigit()
                }.font(NativeTypography.inter(size: 9)).foregroundStyle(NativePalette.thread.faint.swiftUI)
            }.padding(12).background(hovering ? NativePalette.thread.surface.swiftUI : .clear, in: RoundedRectangle(cornerRadius: 12))
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).foregroundStyle(NativePalette.thread.ink.swiftUI).onHover { hovering = $0 }
            .accessibilityLabel("查看执行：\(execution.title)")
    }
}

struct ExecutionReader: View {
    let execution: ExecutionFixture
    var body: some View {
        NativeScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(execution.emoji).font(.system(size: 30))
                    Text(execution.title).font(NativeTypography.inter(size: 23, weight: 650)).lineSpacing(4)
                    HStack(spacing: 7) {
                        FixtureHarnessLogo(harness: execution.harness, size: 12)
                        Text(execution.role); Text("·"); Text("已完成"); Spacer(); Text(execution.usage + " tokens")
                    }.font(NativeTypography.inter(size: 10)).foregroundStyle(NativePalette.thread.muted.swiftUI)
                    Text(execution.time).font(NativeTypography.inter(size: 10)).foregroundStyle(NativePalette.thread.faint.swiftUI)
                }.padding(.bottom, 8)
                ThreadMessage(id: JSONText(execution.id + "-user"), author: .user, content: execution.prompt)
                ThreadMessage(id: JSONText(execution.id + "-answer"), author: .assistant, content: execution.answer)
                Text("本次执行已完成").font(NativeTypography.inter(size: 10))
                    .foregroundStyle(NativePalette.thread.faint.swiftUI).padding(.top, 8)
            }.padding(30).frame(maxWidth: 720, alignment: .leading).frame(maxWidth: .infinity)
        }.foregroundStyle(NativePalette.thread.ink.swiftUI)
    }
}

private struct FixtureHarnessLogo: View {
    let harness: FixtureHarness
    let size: CGFloat
    var body: some View {
        switch harness {
        case .codex: CodexLogo(size: size)
        case .claude: ClaudeLogo(size: size)
        }
    }
}

@MainActor private final class Delegate: NSObject, NSApplicationDelegate {
    let state = DemoState()
    var window: NSWindow!
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: .init(x: 80, y: 80, width: 1320, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Report Thread · Native Demo"
        window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.minSize = .init(width: 1060, height: 680)
        window.isReleasedWhenClosed = false
        if CommandLine.arguments.contains("--production") {
            window.contentView = NSHostingView(rootView: ProductionReportPreview())
        } else { window.contentView = NSHostingView(rootView: ReportDemo(state: state)) }
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate()
        let menu = NSMenu()
        let appItem = NSMenuItem(); menu.addItem(appItem)
        let submenu = NSMenu(); appItem.submenu = submenu
        submenu.addItem(withTitle: "退出 Report Demo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        NSApp.mainMenu = menu
        if CommandLine.arguments.contains("--capture") {
            Task {
                do { try await capture() }
                catch { print("Capture failed: \(error)"); NSApp.terminate(nil) }
            }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    private func capture() async throws {
        let output = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("evidence")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var geometries: [String: [String: [String: Double]]] = [:]
        let states: [(String, ReportRoute)] = [("01-card", .card), ("02-report-list", .report),
            ("03-execution", .execution(state.report.executions[0])), ("04-second-execution", .execution(state.report.executions[1])),
            ("05-return-to-list", .report)]
        for (name, route) in states {
            state.navigate(route)
            try await Task.sleep(for: .seconds(1.5))
            try await shot(name, output: output)
            if route.isOpen {
                geometries[name] = state.frames.mapValues { ["x": $0.minX, "y": $0.minY, "width": $0.width, "height": $0.height] }
            }
        }
        state.dark = true
        try await Task.sleep(for: .seconds(1))
        try await shot("06-dark-list", output: output)
        state.navigate(.execution(state.report.executions[0]))
        try await Task.sleep(for: .seconds(1))
        try await shot("07-dark-execution", output: output)
        state.dark = false; window.setContentSize(.init(width: 1060, height: 700))
        state.navigate(.report)
        try await Task.sleep(for: .seconds(1))
        try await shot("08-narrow-list", output: output)
        geometries["08-narrow-list"] = state.frames.mapValues { ["x": $0.minX, "y": $0.minY, "width": $0.width, "height": $0.height] }
        try JSONSerialization.data(withJSONObject: geometries, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("geometry.json"))
        NSApp.terminate(nil)
    }
    private func shot(_ name: String, output: URL) async throws {
        let content = try await SCShareableContent.currentProcess
        guard let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width * 2); config.height = Int(window.frame.height * 2)
        config.ignoreShadowsSingleWindow = true; config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: config)
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: output.appendingPathComponent(name + ".png"))
    }
}

@main private struct App {
    @MainActor static func main() throws {
        try prepareIsolatedNativeReplay()
        NativeTypography.registerFonts()
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = Delegate(); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
