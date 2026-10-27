import AppKit
import SwiftUI

struct TagCloudDemo: View {
    var onAppearance: (Bool) -> Void
    @State private var dark = false
    @State private var selected: NativeOverviewFilter?

    private let filters: [NativeOverviewFilter] = [
        .init(tag: "Mokusei", count: 12, isDirectory: true),
        .init(tag: "界面设计", count: 4),
        .init(tag: "性能优化", count: 3),
        .init(tag: "代码调研", count: 6),
        .init(tag: "语音交互", count: 2),
        .init(tag: "一个较长的工作目录名称", count: 24, isDirectory: true)
    ]

    private func chrome(_ items: [NativeOverviewFilter]) -> some View {
        var strings = NativeOverviewChromeStrings()
        strings.settings = "切换深浅外观"
        return NativeOverviewChrome(filters: items, selectedTag: selected?.tag ?? "",
            selectedKind: selected.map { $0.isDirectory ? .directory : .semantic },
            strings: strings,
            onTagChange: { selected = $0 }, onSettings: { dark.toggle() })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Tag filter").font(.system(size: 20, weight: .medium))
                    Text("原生组件预览")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 16)
                Toggle("深色", isOn: $dark).toggleStyle(.switch)
            }
            .padding(.horizontal, 28).padding(.top, 28).padding(.bottom, 30)

            Text("常规宽度").font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary).padding(.horizontal, 28)
            chrome(Array(filters.prefix(4)))

            Text("窄窗口 · 可横向滚动").font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary).padding(.horizontal, 28)
            chrome(filters).frame(width: 540).padding(.leading, 14)

            Spacer(minLength: 16)
            HStack {
                Text(selected?.tag ?? "全部")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("tag-cloud-demo-status")
                Spacer()
                Text("点击标签可检查选中效果").foregroundStyle(.tertiary)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 28).padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(dark ? Color(red: 0.11, green: 0.12, blue: 0.14)
                        : Color(red: 0.94, green: 0.94, blue: 0.95))
        .environment(\.colorScheme, dark ? .dark : .light)
        .onChange(of: dark) { _, value in onAppearance(value) }
    }
}

final class DemoDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = DemoDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
let menu = NSMenu()
let applicationItem = NSMenuItem()
menu.addItem(applicationItem)
let applicationMenu = NSMenu()
applicationMenu.addItem(withTitle: "退出光云预览", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
applicationItem.submenu = applicationMenu
app.mainMenu = menu

let size = NSSize(width: 1060, height: 480)
let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
    styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
window.title = "Tag Filter Demo"
window.minSize = NSSize(width: 600, height: 480)
window.isReleasedWhenClosed = false
window.isOpaque = false
window.backgroundColor = .clear
window.appearance = NSAppearance(named: .aqua)
let host = NativeContentHost(frame: NSRect(origin: .zero, size: size))
host.setContent(NSHostingView(rootView: TagCloudDemo(onAppearance: { dark in
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
})))
window.contentView = host
window.center()
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
app.run()
