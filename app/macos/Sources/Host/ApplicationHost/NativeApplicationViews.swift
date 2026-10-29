import Foundation
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import SwiftUI

@MainActor
public struct NativeApplicationDetailEnvironment {
    public let suppressed: Bool
    public let contentTopInset: Double
    public let onBack: () -> Void
    public let onSettings: () -> Void
    public let onNativeNavigationChange: (Bool) -> Void
    public let onNavigationChange: (ThreadDetailBackAction?) -> Void
    public init(suppressed: Bool, contentTopInset: Double = 74, onBack: @escaping () -> Void, onSettings: @escaping () -> Void,
                onNativeNavigationChange: @escaping (Bool) -> Void,
                onNavigationChange: @escaping (ThreadDetailBackAction?) -> Void) {
        self.suppressed = suppressed; self.contentTopInset = contentTopInset; self.onBack = onBack; self.onSettings = onSettings
        self.onNativeNavigationChange = onNativeNavigationChange; self.onNavigationChange = onNavigationChange
    }
}

extension NativeApplicationHost {
    public func detail(thread: ApplicationThreadRef, readingTarget: HarnessReadingTarget? = nil,
                       environment: NativeApplicationDetailEnvironment) -> AnyView {
        if thread.typeID == "git.worktree" {
            return AnyView(NativeGitReadingPage(host: self, id: thread.threadID, environment: environment))
        }
        return AnyView(NativeApplicationThreadDetail(host: self, thread: thread, readingTarget: readingTarget, environment: environment))
    }
    public func settingsSections(model: NativeSettingsModel) -> [NativeApplicationSettingsSection] {
        workspace.plugins.applications.modules.flatMap { module in
            module.settings.map { definition in
                NativeApplicationSettingsSection(id: definition.id.string, owner: definition.ownerPluginID.string,
                    label: definition.label.string, englishLabel: applicationSettingsEnglishLabel(definition.label), content: { [weak self, weak model] saved, draft in
                        guard let self, let model else { return AnyView(EmptyView()) }
                        return AnyView(NativeApplicationSettingsSurface(host: self, model: model, definition: definition,
                            saved: saved, draft: draft))
                    })
            }
        }
    }
}

@MainActor
private final class NativeApplicationViewLease {
    let identity: ApplicationThreadRef
    let lifetime = PluginLifetime()
    init(_ identity: ApplicationThreadRef) { self.identity = identity }
}

@MainActor
private struct NativeApplicationThreadDetail: View {
    let host: NativeApplicationHost
    let thread: ApplicationThreadRef
    let readingTarget: HarnessReadingTarget?
    let environment: NativeApplicationDetailEnvironment
    @State private var lease: NativeApplicationViewLease?
    // Publishing a fresh UUID on every render feeds back into the shell.
    @State private var navigation: ThreadDetailBackAction
    @Environment(\.colorScheme) private var colorScheme

    init(host: NativeApplicationHost, thread: ApplicationThreadRef, readingTarget: HarnessReadingTarget?,
         environment: NativeApplicationDetailEnvironment) {
        self.host = host; self.thread = thread; self.readingTarget = readingTarget; self.environment = environment
        _navigation = State(initialValue: ThreadDetailBackAction(
            label: host.workspace.preferences.locale.text("返回俯瞰", "Back to overview"), onBack: environment.onBack))
    }

    var body: some View {
        let label = host.workspace.preferences.locale.text("返回俯瞰", "Back to overview")
        ThreadDetailFrame(navigation: navigation,
            onNavigationChange: environment.onNavigationChange) {
            if let lease, lease.identity == thread, !lease.lifetime.isCancelled {
                content(lifetime: lease.lifetime)
            } else {
                NativeHarnessStatusView(message: "正在读取…", english: "Loading…")
            }
        }
        .task(id: thread) {
            lease?.lifetime.cancel()
            lease = NativeApplicationViewLease(thread)
        }
        .onChange(of: [thread.threadID, thread.typeID, JSONText(label)]) { _, _ in
            navigation = ThreadDetailBackAction(label: label, onBack: environment.onBack)
        }
        .onDisappear {
            lease?.lifetime.cancel(); lease = nil
            environment.onNativeNavigationChange(false)
        }
    }
    @ViewBuilder private func content(lifetime: PluginLifetime) -> some View {
        let result = Result { () throws -> (AnyView, Bool) in
            let entry = try host.entry(thread)
            let plugin = try host.workspace.plugins.applications.requireThread(entry.ref.typeID)
            let context = try host.rendererContext(plugin: plugin, entry: entry, lifetime: lifetime,
                detail: environment, theme: colorScheme == .dark ? .dark : .light)
            return (try plugin.detail(props: .init(entry: entry, readingTarget: readingTarget, context: context)), host.isEnabled(plugin.ownerPluginID))
        }
        switch result {
        case .success(let (view, enabled)): view.disabled(!enabled)
        case .failure(let error):
            NativeHarnessStatusView(message: "此应用的内容暂时不可用。", english: "This application's content is unavailable.", detail: error.localizedDescription)
        }
    }
}

@MainActor
private struct NativeApplicationSettingsSurface: View {
    let host: NativeApplicationHost
    let model: NativeSettingsModel
    let definition: AnyApplicationSettingsPlugin
    let saved: JSONValue
    @Binding var draft: JSONValue
    @State private var lifetime: PluginLifetime?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let lifetime, !lifetime.isCancelled {
                content(lifetime: lifetime)
            } else { NativeHarnessStatusView(message: "正在读取…", english: "Loading…")
                    .nativeSettingsEditorReady(false) }
        }
        .task(id: definition.id) {
            lifetime?.cancel(); lifetime = PluginLifetime()
        }
        .onDisappear { lifetime?.cancel(); lifetime = nil }
    }
    @ViewBuilder private func content(lifetime: PluginLifetime) -> some View {
        let result = Result { () throws -> AnyView in
            let background = ApplicationBackgroundConfigurationUI { value, change in
                NativeApplicationBackgroundEditor(workspace: host.workspace, settingsModel: model,
                    settingID: definition.id, value: value, change: change)
            }
            let capabilities = try ApplicationCapabilityAccess(scope: .init(pluginID: definition.ownerPluginID),
                requires: definition.requires, registrations: [.init(ApplicationCapabilities.backgroundConfigurationUI, value: background)])
            let props = ApplicationSettingsProps(value: draft, change: { value in
                guard !lifetime.isCancelled else { return }; draft = value
            }, theme: colorScheme == .dark ? .dark : .light, locale: host.locale, capabilities: capabilities)
            return try definition.settings(props: props, onError: { host.workspace.report($0) })
        }
        switch result {
        case .success(let view): view
        case .failure(let error): SettingsNotice(error.localizedDescription, error: true)
                .nativeSettingsEditorReady(false)
        }
    }
}

private func applicationSettingsEnglishLabel(_ label: JSONText) -> String {
    // Existing host translation key; this is copy localization, not dispatch by plugin ID.
    let labels: [JSONText: String] = ["标签管理": "Tag management"]
    return labels[label] ?? label.string
}
