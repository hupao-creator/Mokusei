import MokuseiCore
import SwiftUI

/// Browses authenticated host metadata. Paths are never opened by this device;
/// staging and directory references remain scoped to the current host.
public struct NativeComposerHostFilePicker: View {
    public enum Mode: String, Identifiable { case files, directory; public var id: String { rawValue } }
    private let draft: NativeComposerDraft
    private let mode: Mode
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var directory: RuntimeHostDirectory?
    @State private var reference: RuntimeHostFileReference?
    @State private var selected: [String: RuntimeHostFileEntry] = [:]
    @State private var loading = false
    @State private var error: String?
    @State private var request = UUID()
    @State private var previewing: String?
    @State private var previewError: String?
    @State private var previewTask: Task<Void, Never>?
    @State private var previewGeneration = UUID()

    public init(draft: NativeComposerDraft, mode: Mode) { self.draft = draft; self.mode = mode }
    public var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                if let directory {
                    HStack(spacing: 12) {
                        Button { navigate(directory.parent) } label: { NativeIcon(name: "ArrowUp", size: 16) }
                            .disabled(directory.parent == nil || loading).accessibilityLabel(localized("上一级", "Parent directory"))
                        Text(directory.reference.path).font(NativeTypography.mono(size: 11))
                            .lineLimit(2).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(16)
                    Divider()
                }
                if let error {
                    ContentUnavailableView {
                        Label(localized("无法读取主机目录", "Cannot read host directory"), systemImage: "folder.badge.questionmark")
                    } description: { Text(composerLocalized(error, locale: locale)) } actions: {
                        Button(localized("重试", "Retry")) { request = UUID() }
                        if let directory {
                            Button(localized("返回之前的目录", "Return to previous directory")) { navigate(directory.reference) }
                        }
                    }
                } else if let directory {
                    List(directory.entries) { entry in row(entry) }.nativeControlScrollbars()
                        .listStyle(.plain).disabled(loading)
                    if directory.entries.isEmpty { Text(localized("此目录为空", "This directory is empty")).foregroundStyle(.secondary).padding() }
                } else {
                    Spacer()
                }
                if loading { ProgressView().frame(maxWidth: .infinity).padding(12) }
                if directoryLimitReached {
                    Text(localized("目录引用不能超过 50 个；请先移除一个目录。", "You can reference up to 50 directories. Remove one before choosing another."))
                        .font(NativeTypography.inter(size: 12)).foregroundStyle(.secondary).padding(16)
                }
                if let previewError {
                    Text(composerLocalized(previewError, locale: locale)).font(NativeTypography.inter(size: 12))
                        .foregroundStyle(NativePlatformPalette.thread.danger.swiftUI).textSelection(.enabled).padding(16)
                }
                if mode == .files, !selected.isEmpty {
                    Text(localized("已选择 \(selected.count) 个文件", "\(selected.count) files selected"))
                        .font(NativeTypography.inter(size: 12)).padding(16)
                }
            }
            .background(NativePlatformPalette.thread.surfaceStrong.swiftUI)
            .navigationTitle(localized(mode == .files ? "主机文件" : "主机目录", mode == .files ? "Host files" : "Host directory"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(localized("取消", "Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(localized("选择", "Choose")) { choose() }
                        .disabled(loading || draft.isDisposed || directoryLimitReached || (mode == .files ? selected.isEmpty : directory == nil || error != nil))
                }
            }
        }
        .frame(minWidth: 300, idealWidth: 600, minHeight: 400, idealHeight: 650)
        .task(id: request) { await load() }
        .onDisappear {
            previewGeneration = UUID(); previewTask?.cancel(); previewTask = nil; previewing = nil
        }
    }
    private func row(_ entry: RuntimeHostFileEntry) -> some View {
        HStack(spacing: 8) {
            Button {
                if entry.isDirectory { navigate(entry.reference) }
                else if mode == .files {
                    if selected[entry.id] == nil { selected[entry.id] = entry } else { selected[entry.id] = nil }
                }
            } label: {
                HStack(spacing: 12) {
                    NativeIcon(name: entry.isDirectory ? "Folder" : "FileText", size: 18)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.name).lineLimit(2)
                        if !entry.isDirectory { Text(NativeComposerAttachmentChips.formatBytes(entry.size)).font(.caption).foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if entry.isDirectory { NativeIcon(name: "ChevronRight", size: 14) }
                    else if selected[entry.id] != nil { NativeIcon(name: "Check", size: 16) }
                }.font(NativeTypography.inter(size: 13)).padding(.vertical, 5).contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(mode == .directory && !entry.isDirectory)
            .accessibilityAddTraits(selected[entry.id] != nil ? .isSelected : [])
            if mode == .files && !entry.isDirectory && draft.canPreviewHostFiles {
                Button { preview(entry) } label: {
                    Group {
                        if previewing == entry.id { ProgressView().controlSize(.small) }
                        else { NativeIcon(name: "Eye", size: 16) }
                    }
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(previewing != nil || draft.isDisposed)
                .help(localized("预览、保存或分享", "Preview, save or share"))
                .accessibilityLabel(localized("预览 \(entry.name)", "Preview \(entry.name)"))
            }
        }
    }
    private func preview(_ entry: RuntimeHostFileEntry) {
        guard previewing == nil, !draft.isDisposed else { return }
        let generation = UUID(); previewGeneration = generation; previewing = entry.id; previewError = nil
        previewTask = Task {
            do { try await draft.openHostFile(entry.reference) }
            catch is CancellationError {} catch {
                if previewGeneration == generation && !Task.isCancelled { previewError = error.localizedDescription }
            }
            guard previewGeneration == generation else { return }
            previewing = nil; previewTask = nil
        }
    }
    private func navigate(_ reference: RuntimeHostFileReference?) {
        self.reference = reference; request = UUID(); previewError = nil
    }
    private func load() async {
        loading = true; error = nil
        let expected = request
        defer { if expected == request { loading = false } }
        do {
            let result = try await draft.hostDirectory(reference)
            try Task.checkCancellation()
            guard expected == request, !draft.isDisposed else { return }
            directory = result
        } catch is CancellationError {} catch {
            guard expected == request else { return }; self.error = error.localizedDescription
        }
    }
    private func choose() {
        guard !draft.isDisposed else { dismiss(); return }
        if mode == .directory, let directory {
            guard draft.insertDirectory(.init(name: JSONText(URL(fileURLWithPath: directory.reference.path).lastPathComponent),
                                        path: JSONText(directory.reference.path), hostID: directory.reference.hostID)) else { return }
        } else if mode == .files {
            let entries = selected.values.sorted { $0.id < $1.id }
            Task { await draft.chooseHostFiles(entries) }
        }
        dismiss()
    }
    private var directoryLimitReached: Bool {
        guard mode == .directory, draft.directories.count >= NativeComposerDraft.maximumDirectories else { return false }
        return !draft.directories.contains { $0.path.string == directory?.reference.path && $0.hostID == directory?.reference.hostID }
    }
    private func localized(_ chinese: String, _ english: String) -> String {
        locale.language.languageCode?.identifier == "zh" ? chinese : english
    }
}
