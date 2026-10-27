import AppKit
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import SwiftUI

struct NativeGitDetail: View {
    let props: NativeGitDetailProps
    @State private var model: NativeGitDetailModel?
    private var locale: JSONText { props.context.locale }
    private func text(_ chinese: String, _ english: String) -> String { locale.string.hasPrefix("en") ? english : chinese }
    private var identity: NativeGitDetailIdentity { .init(props) }

    var body: some View {
        GeometryReader { geometry in
            let narrow = geometry.size.width <= 760
            if let model, model.identity == identity {
                VStack(spacing: 0) {
                    header(model, narrow: narrow)
                    tabs(model, narrow: narrow)
                    HStack(spacing: 0) {
                        sidebar(model).frame(width: narrow ? 160 : min(260, max(180, geometry.size.width * 0.27)))
                        Rectangle().fill(NativeAppKitPalette.thread.lineSoft.swiftUI).frame(width: 1)
                        content(model).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }.frame(maxHeight: .infinity)
                }
                .background(NativeAppKitPalette.thread.canvas.swiftUI).foregroundStyle(NativeAppKitPalette.thread.ink.swiftUI)
                .background(NativeGitWindowVisibility { model.setVisible($0) }.frame(width: 0, height: 0))
            } else { message(text("正在读取改动…", "Loading changes…")) }
        }
        .task(id: identity) {
            model?.close()
            let next = NativeGitDetailModel(props: props); model = next; next.start()
        }
        .onChange(of: props.entry.view) { _, _ in model?.update(props) }
        .onDisappear { model?.close(); model = nil }
    }

    private func header(_ model: NativeGitDetailModel, narrow: Bool) -> some View {
        HStack(spacing: narrow ? 12 : 20) {
            HStack(spacing: 8) {
                NativeIcon(name: "FileDiff", size: 20).foregroundStyle(NativeAppKitPalette.pair(0xd85b3b, 0xef9176).swiftUI)
                Menu {
                    ForEach(model.repositories) { repository in
                        Button {
                            props.context.openThread(.init(threadID: repository.id, typeID: "git.worktree"), nil)
                        } label: {
                            Text("\(repository.root.string) · \(repository.branch?.string ?? "HEAD")")
                        }
                    }
                } label: {
                    Text(props.entry.title.string).font(NativeTypography.inter(size: 18, weight: 550)).lineLimit(1)
                }.nativeBorderlessMenu().fixedSize(horizontal: false, vertical: true)
                    .help(props.entry.view.snapshot.root.string)
                    .accessibilityLabel(text("选择仓库或工作树", "Choose repository or worktree"))
                    .accessibilityIdentifier("git.repositories")
                if !narrow {
                    HStack(spacing: 8) {
                        NativeIcon(name: "GitBranch", size: 13)
                        Text(props.entry.view.snapshot.branch?.string ?? props.entry.view.snapshot.head.map { String($0.string.prefix(8)) } ?? "HEAD").lineLimit(1)
                    }.font(NativeTypography.inter(size: 12)).foregroundStyle(NativeAppKitPalette.thread.muted.swiftUI).padding(.leading, 8)
                }
            }
            Spacer(minLength: 0)
            if let stale = staleMessage(model) {
                Text(stale).font(NativeTypography.inter(size: 11)).foregroundStyle(NativeAppKitPalette.thread.warning.swiftUI)
                    .lineLimit(1).truncationMode(.tail).help(stale).accessibilityLabel(stale)
                    .frame(maxWidth: 420, alignment: .trailing)
            }
            Button { model.refresh() } label: {
                Image(systemName: "arrow.clockwise")
            }.buttonStyle(.borderless).disabled(model.isRefreshing)
                .help(text("刷新", "Refresh")).accessibilityLabel(text("刷新 Git 状态", "Refresh Git status"))
                .accessibilityIdentifier("git.refresh")
        }.padding(.horizontal, narrow ? 16 : 28)
            .padding(.top, max(narrow ? 18 : 24, props.context.contentTopInset)).padding(.bottom, narrow ? 10 : 16)
    }
    private func tabs(_ model: NativeGitDetailModel, narrow: Bool) -> some View {
        HStack(spacing: narrow ? 16 : 20) {
            ForEach(NativeGitDiffScope.allCases, id: \.self) { scope in
                Button { model.select(scope: scope) } label: {
                    HStack(spacing: 7) {
                        Text(label(scope)).font(NativeTypography.inter(size: 12))
                        Text(model.files.map { String($0.filter { $0.scope == scope }.count) } ?? "—")
                            .font(NativeTypography.inter(size: 10)).monospacedDigit()
                    }.padding(.vertical, 10)
                        .foregroundStyle(model.scope == scope ? NativeAppKitPalette.thread.ink.swiftUI : NativeAppKitPalette.thread.muted.swiftUI)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(model.scope == scope ? NativeAppKitPalette.thread.ink.swiftUI : .clear).frame(height: 2)
                        }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityAddTraits(model.scope == scope ? [.isSelected] : [])
                    .accessibilityIdentifier("git.scope.\(scope.rawValue)")
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, narrow ? 16 : 28)
            .overlay(alignment: .bottom) { Rectangle().fill(NativeAppKitPalette.thread.lineSoft.swiftUI).frame(height: 1) }
            .accessibilityElement(children: .contain).accessibilityLabel(text("改动分类", "Change categories"))
    }
    private func sidebar(_ model: NativeGitDetailModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(props.entry.view.snapshot.root.string).font(NativeTypography.inter(size: 10)).foregroundStyle(NativeAppKitPalette.thread.muted.swiftUI)
                .lineLimit(1).help(props.entry.view.snapshot.root.string).padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 12)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.visibleFiles) { file in
                        NativeGitFileButton(file: file, selected: model.selectedPath == file.path) { model.select(path: file.path) }
                    }
                }
            }.id(model.scope)
        }.frame(maxHeight: .infinity, alignment: .topLeading)
            .accessibilityElement(children: .contain).accessibilityLabel(text("改动文件", "Changed files"))
    }
    @ViewBuilder private func content(_ model: NativeGitDetailModel) -> some View {
        let loaded = model.loadedDiff
        let retained = loaded?.document != nil || loaded?.notice != nil
        let failure = model.files == nil ? model.filesError : retained ? nil : loaded?.error
        if let failure {
            VStack(spacing: 12) {
                message(failure == "parse" ? parseError : failure)
                Button(text("重试", "Retry")) { model.refresh() }.padding(.bottom, 24)
            }
        }
        else if model.files == nil { message(text("正在读取改动…", "Loading changes…")) }
        else if model.selectedPath == nil { message(text("此分类没有改动。", "No changes in this category.")) }
        else if let loaded {
            if let notice = loaded.notice { message(noticeText(notice), path: model.selectedPath) }
            else if let document = loaded.document {
                NativeGitDiffView(document: document, theme: props.context.theme, locale: locale).id(loaded.selection)
            } else { message(text("正在读取文件差异…", "Loading file diff…")) }
        } else { message(text("正在读取文件差异…", "Loading file diff…")) }
    }
    private func message(_ value: String, path: JSONText? = nil) -> some View {
        VStack(spacing: 6) {
            if let path { Text(path.string).font(NativeTypography.inter(size: 12, weight: 500)).foregroundStyle(NativeAppKitPalette.thread.ink.swiftUI) }
            Text(value).font(NativeTypography.inter(size: 13)).foregroundStyle(NativeAppKitPalette.thread.muted.swiftUI).textSelection(.enabled)
        }.multilineTextAlignment(.center).padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .contain)
    }
    private func label(_ scope: NativeGitDiffScope) -> String {
        switch scope {
        case .unstaged: text("未暂存", "Unstaged")
        case .staged: text("已暂存", "Staged")
        case .untracked: text("未跟踪", "Untracked")
        case .conflicts: text("冲突", "Conflicts")
        }
    }
    private var parseError: String { text("无法解析差异，稍后自动重试。", "Could not parse the diff. It will retry automatically.") }
    private func staleMessage(_ model: NativeGitDetailModel) -> String? {
        var errors: [String] = []
        if model.files != nil, let error = model.filesError { errors.append("\(text("文件列表", "File list")): \(error)") }
        if let loaded = model.loadedDiff, loaded.document != nil || loaded.notice != nil, let error = loaded.error {
            errors.append("\(text("文件差异", "File diff")): \(error == "parse" ? parseError : error)")
        }
        guard !errors.isEmpty else { return nil }
        return "\(text("刷新失败，内容可能已过期；将自动重试。", "Refresh failed; content may be outdated. Retrying automatically.")) \(errors.joined(separator: " · "))"
    }
    private func noticeText(_ notice: NativeGitDiffNotice) -> String {
        switch notice {
        case .binary: text("二进制文件，无法展示文本差异。", "This binary file has no text diff.")
        case .empty: text("没有可显示的文本差异；文件可能为空、仅修改了属性，或已发生变化。", "No text diff. The file may be empty, have metadata-only changes, or have changed since the last refresh.")
        case .tooLarge: text("此差异超过显示上限（2 MiB、12,000 行或单行 32,768 字符），请在编辑器中查看。", "This diff exceeds the display limit (2 MiB, 12,000 lines or 32,768 characters per line). Open it in your editor.")
        case .conflict: text("此文件存在合并冲突，请在编辑器中解决，此视图会自动更新。", "This file has merge conflicts. Resolve them in your editor; this view updates automatically.")
        case .submodule: text("子模块内有改动，但没有可显示的提交差异。", "The submodule has working changes but no commit diff to display.")
        }
    }
}

private struct NativeGitFileButton: View {
    let file: NativeGitChangedFile
    let selected: Bool
    let select: () -> Void
    @State private var hovered = false
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        Button(action: select) {
            HStack(spacing: 8) {
                Text(file.status.string).font(NativeTypography.inter(size: 10, weight: 600)).frame(width: 14)
                    .foregroundStyle(statusColor)
                Text(file.path.string).font(NativeTypography.inter(size: 11)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.horizontal, 16).frame(height: 34).contentShape(Rectangle())
                .background(selected || hovered ? highlight : .clear)
        }.buttonStyle(.plain).onHover { hovered = $0 }
            .accessibilityLabel(file.path.string).accessibilityIdentifier("git.file.\(file.scope.rawValue).\(file.path.string)")
            .help(file.oldPath.map { "\($0.string) → \(file.path.string)" } ?? file.path.string)
            .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
    private var statusColor: Color {
        switch file.status {
        case "A": NativeAppKitPalette.pair(0x238341, 0x6ec487).swiftUI
        case "D": NativeAppKitPalette.pair(0xb44338, 0xe18d82).swiftUI
        default: NativeAppKitPalette.thread.muted.swiftUI
        }
    }
    private var highlight: Color {
        NativeAppKitPalette.color(colorScheme == .dark ? 0xffffff : 0xeae8e3,
                            alpha: colorScheme == .dark ? 11 / 255.0 : 128 / 255.0).swiftUI
    }
}

private struct NativeGitWindowVisibility: NSViewRepresentable {
    let change: (Bool) -> Void
    func makeNSView(context: Context) -> VisibilityView { let view = VisibilityView(); view.change = change; return view }
    func updateNSView(_ view: VisibilityView, context: Context) { view.change = change; view.publish() }
    static func dismantleNSView(_ view: VisibilityView, coordinator: ()) { view.stop(); view.change = nil }
    @MainActor final class VisibilityView: NSView {
        var change: ((Bool) -> Void)?
        private var tokens: [NSObjectProtocol] = []
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); stop()
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
                tokens.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.publish() }
                })
            }
            for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
                tokens.append(NotificationCenter.default.addObserver(forName: name, object: NSApp, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.publish() }
                })
            }
            publish()
        }
        func publish() { change?(window.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) && !NSApp.isHidden } ?? false) }
        func stop() { for token in tokens { NotificationCenter.default.removeObserver(token) }; tokens.removeAll() }
    }
}
