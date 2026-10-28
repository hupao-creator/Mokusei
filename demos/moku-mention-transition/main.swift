import AppKit
import SwiftUI
import MokuseiCore
import MokuseiPluginAPI
@testable import MokuseiPluginUI
@testable import MokuseiUI

private let directories: [NativeComposerDirectory] = [
    .init(name: "Mokusei", path: "/demo/Mokusei"),
    .init(name: "Agent Learn", path: "/demo/Agent Learn"),
    .init(name: "AnyThing", path: "/demo/AnyThing"),
    .init(name: "Design", path: "/demo/Design"),
    .init(name: "Research", path: "/demo/Research"),
    .init(name: "Website", path: "/demo/Website"),
]

private struct Preview: View {
    @State private var draft = NativeComposerDraft(services: .init(stageFiles: { _, _ in [] }, discardAttachments: { _ in }))
    @State private var mentions = NativeMokuDirectoryMentions()
    @State private var scene = NativeMokuSceneState()
    @State private var original = true
    @State private var dark = true
    @State private var replaying = false
    @State private var replay: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: dark ? [Color(red: 0.17, green: 0.13, blue: 0.21), Color(red: 0.35, green: 0.22, blue: 0.22)]
                : [Color(red: 0.91, green: 0.89, blue: 0.85), Color(red: 0.80, green: 0.85, blue: 0.87)], startPoint: .topLeading, endPoint: .bottomTrailing)
            if original {
                NativeMokuScene(state: scene) { Color.clear } thread: { EmptyView() } dock: {
                    NativeMokuDock(state: scene, draft: draft, cwd: "/demo", landing: true,
                        loadMentionDirectories: { directories }, onSend: { _ in }, onCancel: {})
                } settings: { EmptyView() }
            } else {
                GeometryReader { proxy in
                    NativeMokuComposerInput(draft: draft, cwd: "/demo", landing: true,
                        availableHeight: min(380, proxy.size.height - 180), mentions: mentions, showsEyes: true,
                        selectionRequest: mentions.selectionRequest, onEditorStateChange: mentions.update,
                        onKeyDown: { mentions.handle($0, draft: draft) }, onSend: {})
                        .frame(width: min(680, proxy.size.width - 64))
                        .fixedSize(horizontal: false, vertical: true)
                        .background { NativeMokuCapsuleGlass().id(dark) }
                        .clipShape(RoundedRectangle(cornerRadius: NativeMokuCapsuleLayout.cornerRadius))
                        .shadow(color: .black.opacity(0.13), radius: 13, y: 6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        // A single layout owns the face, input row, glass and centered expansion.
                        // No asynchronously measured eye offset is fed back into a second animation.
                        .animation(reduceMotion ? nil : .smooth(duration: 0.42, extraBounce: 0), value: mentions.isOpen)
                        .coordinateSpace(name: "native-moku-dock")
                        .task { await mentions.load(enabled: true, using: { directories }) }
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Mention · 眼睛与输入行同步").font(.system(size: 22, weight: .semibold))
                        Text(original ? "正式 Dock · 统一胶囊过渡" : "提案 · 眼睛留在输入行，菜单和玻璃一起展开").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("正式 Dock", isOn: $original).toggleStyle(.switch)
                    Toggle("深色", isOn: $dark).toggleStyle(.switch)
                }
                HStack {
                    Button(replaying ? "停止回放" : "回放展开 / 收起") { toggleReplay() }.buttonStyle(.borderedProminent)
                    Text("也可以直接输入 @，用 ↑ ↓ 选择，Esc 收起。发送仅为预览。").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }.padding(28)
        }
        .preferredColorScheme(dark ? .dark : .light)
        .environment(\.locale, Locale(identifier: "zh-Hans"))
        .onChange(of: original) { _, _ in replay?.cancel(); replaying = false; draft.text = "" }
        .onDisappear { replay?.cancel() }
    }

    private func toggleReplay() {
        if replaying { replay?.cancel(); replaying = false; return }
        replaying = true
        replay = Task { @MainActor in
            defer { replaying = false }
            for text in ["", "@", "", "@", "@M", "@", ""] {
                guard !Task.isCancelled else { return }
                if let root = NSApp.keyWindow?.contentView, let editor = findEditor(root) {
                    NSApp.keyWindow?.makeFirstResponder(editor)
                    editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
                }
                do { try await Task.sleep(for: .milliseconds(text == "@M" ? 900 : 1300)) } catch { return }
            }
        }
    }
}

@MainActor private func findEditor(_ view: NSView) -> NSTextView? {
    if let text = view as? NSTextView, text.isEditable { return text }
    return view.subviews.lazy.compactMap { findEditor($0) }.first
}

@main @MainActor private struct Demo: App {
    init() {
        do { try prepareIsolatedNativeReplay() } catch { print(error); exit(1) }
    }
    var body: some Scene {
        Window("Moku Mention Transition Preview", id: "mention-preview") { Preview() }
            .defaultSize(width: 1000, height: 700)
    }
}
