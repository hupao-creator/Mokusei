import AppKit
import Combine
import SwiftUI
import MokuseiUI
import MokuseiPluginUI

/// Visual replay of the real production component, including its scroll bridge,
/// typography, selection and floating actions.
private struct ProductionTagMorphReplay: View {
    @State private var filters: [NativeOverviewFilter] = []
    @State private var selected: NativeOverviewFilter?
    @State private var dark = true
    @State private var cameraManual = false
    @State private var generation = 0
    @State private var focusRequest = 0
    @State private var playing = false
    @State private var replayIndex = 0

    private let catalog: [NativeOverviewFilter] = [
        .init(tag: "Mokusei", count: 12, isDirectory: true, selectionKey: "members:directory:1"),
        .init(tag: "界面设计", count: 4, aliases: ["Design"], selectionKey: "members:design:1"),
        .init(tag: "性能优化", count: 3, selectionKey: "members:performance:1"),
        .init(tag: "代码调研", count: 6, selectionKey: "members:research:1"),
        .init(tag: "语音交互", count: 2, selectionKey: "members:voice:1"),
        .init(tag: "一个较长的工作目录名称", count: 24, isDirectory: true, selectionKey: "members:long:1")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Overview · 生产 Tag Morph").font(.system(size: 23, weight: .semibold))
            Text("直接加载 MokuseiUI.NativeOverviewChrome · 两个独立原生滚动视口")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            HStack {
                Button("加载 2 项") { filters = Array(catalog.prefix(2)) }
                Button("增加") {
                    if let next = catalog.first(where: { item in !filters.contains { $0.tag == item.tag } }) { filters.append(next) }
                }.disabled(filters.count == catalog.count)
                Button("删除选中 / 末尾") {
                    if let selected, filters.contains(where: { $0.id == selected.id }) { filters.removeAll { $0.id == selected.id }; self.selected = nil }
                    else if !filters.isEmpty { filters.removeLast() }
                }.disabled(filters.isEmpty)
                Button("批量 2 ⇄ 6") { filters = Array(catalog.prefix(filters.count > 2 ? 2 : 6)) }
                Button("反转排序") { filters.reverse() }.disabled(filters.count < 2)
                Button("成员 / 计数变化") {
                    filters = filters.map { item in
                        var next = item; next.count += 100; next.selectionKey += ":new-member"; return next
                    }
                }.disabled(filters.isEmpty)
                Button("清空") { filters = []; selected = nil }
            }.controlSize(.large)
            HStack(spacing: 18) {
                Toggle("深色", isOn: $dark)
                Toggle("手动相机", isOn: $cameraManual)
            }.toggleStyle(.checkbox).font(.system(size: 12))
            HStack {
                Button("新场景（空）") { filters = []; selected = nil; generation += 1 }
                Button("键盘聚焦当前筛选") { focusRequest += 1 }
                Button("选择别名 Design") { selected = .init(tag: "Design", count: 4) }
                Button(playing ? "停止回放" : "自动增删回放") { playing.toggle() }
                Spacer()
                Text("\(filters.count) 项 · 选中：\(selected?.tag ?? "全部")").monospacedDigit()
            }.font(.system(size: 12))
            VStack(alignment: .leading, spacing: 0) {
                Text("常规宽度").font(.system(size: 11)).foregroundStyle(.secondary).padding(16)
                chrome.id("wide-\(generation)")
                Text("窄视口 540 pt · 全部固定，标签可滚动")
                    .font(.system(size: 11)).foregroundStyle(.secondary).padding(16)
                chrome.frame(width: 540).id("narrow-\(generation)")
            }
            .background {
                ZStack {
                    Color(white: dark ? 0.15 : 0.92)
                    Ellipse().fill(.purple.opacity(0.2)).blur(radius: 70).offset(x: -200)
                    Ellipse().fill(.blue.opacity(0.13)).blur(radius: 70).offset(x: 200)
                }.clipShape(RoundedRectangle(cornerRadius: 20))
            }
            Spacer()
            Text("先点击加载检查首次出现；再增删、反转、改变计数。全程使用正式筛选器，无会话数据或 runtime。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(28).frame(minWidth: 1080, minHeight: 580)
        .background(Color(white: dark ? 0.085 : 0.985))
        .environment(\.colorScheme, dark ? .dark : .light)
        .preferredColorScheme(dark ? .dark : .light)
        .overlay {
            if playing {
                ProductionReplayClock {
                    let counts = [2, 3, 6, 2, 0, 2]
                    filters = Array(catalog.prefix(counts[replayIndex % counts.count]))
                    replayIndex += 1
                }.frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .onDisappear { playing = false }
    }

    private var chrome: some View {
        NativeOverviewChrome(filters: filters, selectedTag: selected?.tag ?? "",
            selectedKind: selected.map { $0.isDirectory ? .directory : .semantic },
            cameraManual: cameraManual, focusFilterRequestKey: focusRequest,
            onTagChange: { selected = $0 }, onReturnToAuto: { cameraManual = false },
            onSettings: { dark.toggle() }, onFocusFilterRequestConsumed: { focusRequest = 0 })
    }
}

final class ProductionMorphDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NativeTypography.registerFonts()
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct ProductionTagMorphApp: App {
    @NSApplicationDelegateAdaptor(ProductionMorphDelegate.self) private var delegate
    var body: some Scene {
        Window("Overview · 生产 Tag Morph 验证", id: "production-tag-morph") { ProductionTagMorphReplay() }
            .defaultSize(width: 1120, height: 620)
    }
}

private struct ProductionReplayClock: View {
    var advance: () -> Void
    var body: some View {
        Color.clear.onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in advance() }
    }
}
