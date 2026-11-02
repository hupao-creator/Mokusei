import Foundation
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import SwiftUI

/// Core owns the Moku frame and draft. The selected Harness owns its manifest,
/// visible rows, message identity and private-state interpretation.
public struct NativeMokuThreadView: View {
    public let harnessHost: NativeHarnessHost
    public let thread: HarnessThread
    public let archiveThreads: [HarnessThread]
    public let draft: NativeComposerDraft
    public let readingTarget: HarnessReadingTarget?
    public let running: Bool
    public let disabled: Bool
    public let activeVoiceControls: AnyView
    public let voiceModeActive: Bool
    public let voiceBackground: AnyView
    public let canStartVoice: () -> Bool
    public let startVoice: () -> Void
    public let loadMentionDirectories: (() async throws -> [NativeComposerDirectory])?
    public let backLabel: String?
    public let focusEnabled: Bool
    public let onNavigationChange: ((ThreadDetailBackAction?) -> Void)?
    public let error: String?
    public let openExternal: ((URL) -> Void)?
    public let onBack: () -> Void
    public let onSend: (NativeComposerSubmission) async throws -> Void
    public let onCancel: () -> Void
    @Environment(\.locale) private var locale
    @State private var navigation: ThreadDetailBackAction
    @State private var focusRequest = 0
    @State private var archiveID: JSONText?

    public init(harnessHost: NativeHarnessHost, thread: HarnessThread, draft: NativeComposerDraft,
                archiveThreads: [HarnessThread] = [],
                readingTarget: HarnessReadingTarget? = nil,
                running: Bool = false, disabled: Bool = false,
                activeVoiceControls: AnyView = AnyView(EmptyView()),
                voiceBackground: AnyView = AnyView(EmptyView()),
                voiceModeActive: Bool = false,
                loadMentionDirectories: (() async throws -> [NativeComposerDirectory])? = nil,
                backLabel: String? = nil, focusEnabled: Bool = true,
                onNavigationChange: ((ThreadDetailBackAction?) -> Void)? = nil,
                error: String? = nil, openExternal: ((URL) -> Void)? = nil,
                onBack: @escaping () -> Void,
                onSend: @escaping (NativeComposerSubmission) async throws -> Void,
                onCancel: @escaping () -> Void,
                canStartVoice: @escaping () -> Bool = { false },
                startVoice: @escaping () -> Void = {}) {
        self.harnessHost = harnessHost; self.thread = thread; self.draft = draft; self.readingTarget = readingTarget
        self.archiveThreads = archiveThreads
        self.running = running; self.disabled = disabled
        self.activeVoiceControls = activeVoiceControls; self.error = error
        self.voiceModeActive = voiceModeActive
        self.voiceBackground = voiceBackground; self.loadMentionDirectories = loadMentionDirectories
        self.canStartVoice = canStartVoice; self.startVoice = startVoice
        self.openExternal = openExternal; self.backLabel = backLabel; self.focusEnabled = focusEnabled
        self.onNavigationChange = onNavigationChange; self.onBack = onBack; self.onSend = onSend; self.onCancel = onCancel
        _navigation = State(initialValue: ThreadDetailBackAction(label: backLabel ?? "返回俯瞰", onBack: onBack))
    }
    public var body: some View {
        let label = backLabel ?? (locale.language.languageCode?.identifier == "zh" ? "返回俯瞰" : "Back to overview")
        ThreadDetailFrame(navigation: navigation, onNavigationChange: onNavigationChange) {
            VStack(spacing: 0) {
                if !archiveThreads.isEmpty {
                    HStack {
                        Menu {
                            Button(localize("当前对话", "Current conversation")) { archiveID = nil }
                            Divider()
                            ForEach(archiveThreads, id: \.id) { previous in
                                Button("\(previous.title.string) · \(Date(timeIntervalSince1970: previous.updatedAt / 1000).formatted(date: .abbreviated, time: .shortened))") { archiveID = previous.id }
                            }
                        } label: {
                            Text(archiveID == nil ? localize("当前对话", "Current conversation") : localize("先前对话（只读）", "Previous conversation (read-only)"))
                        }.accessibilityIdentifier("moku-history-sessions")
                        Spacer()
                    }.padding(.horizontal, 24).padding(.top, 12)
                }
                if let archive = archiveThreads.first(where: { $0.id == archiveID }) {
                    NativeHarnessThreadView(host: harnessHost, input: HarnessThreadInput(thread: archive),
                        routes: NativeHarnessThreadRoutes(openExternal: externalRoute))
                        .id(archive.id).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    NativeHarnessThreadView(host: harnessHost, input: HarnessThreadInput(thread: thread, readingTarget: readingTarget),
                        routes: NativeHarnessThreadRoutes(interrupt: { onCancel() }, openFollowUp: { initialDraft in
                            draft.text = initialDraft.string
                            focusRequest &+= 1
                        }, openExternal: externalRoute))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    NativeMokuHistoryComposer(draft: draft, cwd: thread.cwd, disabled: disabled,
                        running: running || thread.observation.isExecutionActive,
                        focusEnabled: focusEnabled, focusRequestKey: focusRequest,
                        suppressInitialFocus: readingTarget?.message != nil,
                        activeVoiceControls: activeVoiceControls, voiceBackground: voiceBackground, voiceModeActive: voiceModeActive,
                        loadMentionDirectories: loadMentionDirectories, onSend: onSend, onCancel: onCancel,
                        canStartVoice: canStartVoice, startVoice: startVoice)
                        .frame(maxWidth: 560)
                        .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 28)
                }
                if let message = displayError, !message.isEmpty, draft.error == nil {
                    Text(message).font(NativeTypography.inter(size: 10)).foregroundStyle(NativePalette.thread.danger.swiftUI)
                        .textSelection(.enabled).padding(.horizontal, 24).padding(.bottom, 12)
                }
            }.background(NativePalette.thread.canvas.swiftUI)
        }
        .task(id: [thread.id, JSONText(label)]) { navigation = ThreadDetailBackAction(label: label, onBack: onBack) }
        .environment(\.colorScheme, .dark)
    }
    private func localize(_ zh: String, _ en: String) -> String { locale.language.languageCode?.identifier == "zh" ? zh : en }
    private var externalRoute: ((JSONText) async throws -> Void)? {
        openExternal.map { open in
            { (url: JSONText) async throws -> Void in
                guard let value = URL(string: url.string) else { throw PluginContractError("Invalid external URL") }
                open(value)
            }
        }
    }
    private var displayError: String? {
        if let error, !error.isEmpty { return error }
        guard let execution = thread.observation.latestExecution, execution.status == .failed else { return nil }
        return execution.error?.string ?? execution.summary?.string
            ?? (locale.language.languageCode?.identifier == "zh" ? "操作失败" : "Operation failed")
    }
}
