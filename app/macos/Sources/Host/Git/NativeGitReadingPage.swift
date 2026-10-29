import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import SwiftUI

struct NativeGitDetailEntry {
    let ref: ApplicationThreadRef
    let title: JSONText
    let view: NativeGitView
}
struct NativeGitDetailProps {
    let entry: NativeGitDetailEntry
    let context: ApplicationRendererContext
}

@MainActor struct NativeGitReadingPage: View {
    let host: NativeApplicationHost
    let id: JSONText
    let environment: NativeApplicationDetailEnvironment
    @State private var lifetime: PluginLifetime?
    @State private var navigation: ThreadDetailBackAction
    @Environment(\.colorScheme) private var colorScheme

    init(host: NativeApplicationHost, id: JSONText, environment: NativeApplicationDetailEnvironment) {
        self.host = host; self.id = id; self.environment = environment
        _navigation = State(initialValue: ThreadDetailBackAction(
            label: host.workspace.preferences.locale.text("返回俯瞰", "Back to overview"), onBack: environment.onBack))
    }

    var body: some View {
        let label = host.workspace.preferences.locale.text("返回俯瞰", "Back to overview")
        ThreadDetailFrame(navigation: navigation,
                          onNavigationChange: environment.onNavigationChange) {
            if let lifetime, !lifetime.isCancelled {
                content(lifetime)
            } else { NativeHarnessStatusView.loading }
        }
        .task(id: id) { lifetime?.cancel(); lifetime = PluginLifetime() }
        .onChange(of: [id, JSONText(label)]) { _, _ in
            navigation = ThreadDetailBackAction(label: label, onBack: environment.onBack)
        }
        .onDisappear { lifetime?.cancel(); lifetime = nil; environment.onNativeNavigationChange(false) }
    }
    @ViewBuilder private func content(_ lifetime: PluginLifetime) -> some View {
        if let repository = host.git.repository(id) {
            let result = Result { () throws -> NativeGitDetailProps in
                let context = ApplicationRendererContext(theme: colorScheme == .dark ? .dark : .light,
                    locale: host.locale, lifetime: lifetime, contentTopInset: environment.contentTopInset,
                    domain: try host.domain(pluginID: "git", viewLifetime: lifetime),
                    capabilities: try .init(scope: .init(pluginID: "git"), requires: [], registrations: []),
                    openThread: host.navigation.openThread, openExecution: host.navigation.openExecution)
                return .init(entry: .init(ref: .init(threadID: id, typeID: "git.worktree"),
                    title: JSONText(repository.root.string.split(separator: "/").last.map(String.init) ?? repository.root.string),
                    view: repository.view), context: context)
            }
            switch result {
            case .success(let props): NativeGitDetail(props: props)
            case .failure(let error): NativeHarnessStatusView(message: "无法读取 Git。", english: "Git is unavailable.", detail: error.localizedDescription)
            }
        } else { NativeHarnessStatusView(message: "工作树已不可用。", english: "This worktree is no longer available.") }
    }
}
