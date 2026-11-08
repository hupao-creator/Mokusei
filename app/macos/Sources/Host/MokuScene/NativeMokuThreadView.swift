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
    public let draft: NativeComposerDraft
    public let readingTarget: HarnessReadingTarget?
    public let running: Bool
    public let disabled: Bool
    public let loadMentionDirectories: (() async throws -> [NativeComposerDirectory])?
    public let backLabel: String?
    public let focusEnabled: Bool
    public let onNavigationChange: ((ThreadDetailBackAction?) -> Void)?
    public let error: String?
    public let openExternal: ((URL) -> Void)?
    public let onBack: () -> Void
    public let onSend: (NativeComposerSubmission) async throws -> Void
    public let onSendConsumed: (NativeComposerSubmission) async -> Void
    public let onCancel: () -> Void
    @Environment(\.locale) private var locale
    @State private var navigation: ThreadDetailBackAction
    @State private var nestedNavigation: ThreadDetailBackAction?
    @State private var focusRequest = 0

    // Former voice arguments are accepted for source compatibility only; this
    // reader neither retains nor mounts those controls or callbacks.
    public init(harnessHost: NativeHarnessHost, thread: HarnessThread, draft: NativeComposerDraft,
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
                onSendConsumed: @escaping (NativeComposerSubmission) async -> Void = { _ in },
                onCancel: @escaping () -> Void,
                canStartVoice: @escaping () -> Bool = { false },
                startVoice: @escaping () -> Void = {}) {
        self.harnessHost = harnessHost; self.thread = thread; self.draft = draft; self.readingTarget = readingTarget
        self.running = running; self.disabled = disabled
        self.error = error; self.loadMentionDirectories = loadMentionDirectories
        self.openExternal = openExternal; self.backLabel = backLabel; self.focusEnabled = focusEnabled
        self.onNavigationChange = onNavigationChange; self.onBack = onBack; self.onSend = onSend
        self.onSendConsumed = onSendConsumed; self.onCancel = onCancel
        _navigation = State(initialValue: ThreadDetailBackAction(label: backLabel ?? "返回俯瞰", onBack: onBack))
    }
    public var body: some View {
        let label = backLabel ?? (locale.language.languageCode?.identifier == "zh" ? "返回俯瞰" : "Back to overview")
        ThreadDetailFrame(navigation: navigation, onNavigationChange: { action in
            nestedNavigation = action
            onNavigationChange?(action)
        }) {
            VStack(spacing: 12) {
                VStack(spacing: 0) {
                    NativeHarnessThreadView(host: harnessHost, input: HarnessThreadInput(thread: thread, readingTarget: readingTarget),
                        routes: NativeHarnessThreadRoutes(interrupt: { onCancel() }, openFollowUp: { initialDraft in
                            draft.text = initialDraft.string
                            focusRequest &+= 1
                        }, openExternal: externalRoute))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if let message = displayError, !message.isEmpty, draft.error == nil {
                        Text(message).font(NativeTypography.inter(size: 10)).foregroundStyle(NativePalette.thread.danger.swiftUI)
                            .textSelection(.enabled).padding(.horizontal, 24).padding(.bottom, 12)
                    }
                }
                .modifier(NativeApplicationReadingPanel(enabled: true, suppressed: !focusEnabled,
                    escapeEnabled: nestedNavigation.map { $0.id == navigation.id } ?? true,
                    identifier: "moku-reading-panel", onClose: onBack))
                // Keep the draft outside the reading surface, aligned with its
                // center rather than the shared panel's trailing toolbar seat.
                NativeMokuHistoryComposer(draft: draft, cwd: thread.cwd, disabled: disabled,
                    running: running || thread.observation.isExecutionActive,
                    focusEnabled: focusEnabled, focusRequestKey: focusRequest,
                    suppressInitialFocus: readingTarget?.message != nil,
                    loadMentionDirectories: loadMentionDirectories, onSend: onSend,
                    onSendConsumed: onSendConsumed, onCancel: onCancel)
                    .frame(maxWidth: 560)
                    .padding(.horizontal, 24).padding(.trailing, 76)
            }
        }
        .task(id: [thread.id, JSONText(label)]) { navigation = ThreadDetailBackAction(label: label, onBack: onBack) }
    }
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
