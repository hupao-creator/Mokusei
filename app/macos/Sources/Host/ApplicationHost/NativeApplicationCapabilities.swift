import Foundation
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import SwiftUI

struct NativeApplicationConversation {
    let thread: HarnessThread?
}

extension NativeApplicationHost {
    func conversation(_ entry: ApplicationThreadCatalogEntry<JSONValue>) throws -> NativeApplicationConversation? {
        guard let presentation = entry.presentations.first(where: { $0.id == "mokusei.conversation" }) else { return nil }
        guard presentation.apiVersion == 1, presentation.schemaVersion == 1 else {
            throw PluginContractError("Incompatible public conversation presentation")
        }
        guard case .object(let fields) = presentation.value, let raw = fields["thread"] else {
            throw PluginContractError("Malformed public conversation presentation")
        }
        if raw == .null { return NativeApplicationConversation(thread: nil) }
        guard case .object(var thread) = raw else { throw PluginContractError("Application conversation thread must be an object") }
        // Public application lifecycle travels with the public session envelope;
        // authority still comes from its application source, never Agent catalog.
        thread["archived"] = .bool(entry.archived)
        let parsed = try HarnessThread(json: .object(thread))
        guard parsed.id == entry.ref.threadID else { throw PluginContractError("Application conversation identity does not match its owner") }
        return NativeApplicationConversation(thread: parsed)
    }

    func conversationSource(ref: ApplicationThreadRef, owner: JSONText, lifetime: PluginLifetime) -> NativeHarnessConversationSource {
        NativeHarnessConversationSource(read: { [weak self] in
            guard let self, !lifetime.isCancelled,
                  let current = try? entry(ref),
                  (try? workspace.plugins.applications.requireThread(ref.typeID).ownerPluginID) == owner else { return nil }
            return try? conversation(current)?.thread
        }, canExecute: { [weak self] in
            guard let self, !lifetime.isCancelled, let current = try? entry(ref),
                  let conversation = try? conversation(current), let thread = conversation.thread else { return false }
            let key = JSONText(codeUnits: JSONText("harness:").codeUnits + thread.harnessID.codeUnits)
            let harness = workspace.catalog.plugins.first { $0["key"] == .string(key) }
            return canExecute(owner, entry: current) && harness?["enabled"] != .bool(false)
                && (harness?["unavailableReason"] == nil || harness?["unavailableReason"] == .null)
        })
    }

    func projectionCapabilities(plugin: AnyApplicationThreadPlugin,
                                entry: ApplicationThreadCatalogEntry<JSONValue>) throws -> ApplicationCapabilityAccess<ApplicationProjectionPhase> {
        guard !isReleased else { throw CancellationError() }
        var registrations: [ApplicationCapabilityRegistration<ApplicationProjectionPhase>] = []
        if let thread = try conversation(entry)?.thread {
            registrations.append(.init(ApplicationCapabilities.conversationProjection,
                value: ApplicationConversationProjection { [weak self] columns in
                    guard let self else { throw CancellationError() }
                    let snapshot = try workspace.harnessHost.overview(input: .init(thread: thread), availableColumns: columns)
                    return HarnessOverviewProjection(envelope: snapshot.envelope, view: ApplicationConversationCard(snapshot: snapshot))
                }))
        }
        return try ApplicationCapabilityAccess(scope: .init(pluginID: plugin.ownerPluginID, thread: entry.ref),
            requires: plugin.requires, registrations: registrations)
    }

    func rendererContext(plugin: AnyApplicationThreadPlugin, entry: ApplicationThreadCatalogEntry<JSONValue>,
                         lifetime: PluginLifetime, detail: NativeApplicationDetailEnvironment? = nil,
                         theme: PluginTheme? = nil) throws -> ApplicationRendererContext {
        guard !isReleased else { throw CancellationError() }
        let ref = entry.ref, owner = plugin.ownerPluginID
        try lifetime.checkCancellation()
        var registrations: [ApplicationCapabilityRegistration<ApplicationRendererPhase>] = [
            .init(ApplicationCapabilities.threadUserActions, value: ApplicationThreadUserActions(
                setArchived: { [weak self] archived, _, callLifetime in
                    guard let self else { throw CancellationError() }
                    try await archive(ref, archived: archived, owner: owner, viewLifetime: lifetime, callLifetime: callLifetime)
                }, initializeConversation: { [weak self] _, callLifetime in
                    guard let self else { throw CancellationError() }
                    try await initialize(ref, owner: owner, viewLifetime: lifetime, callLifetime: callLifetime)
                })),
            .init(ApplicationCapabilities.executionReferencesUI, value: ApplicationExecutionReferencesUI(
                read: { [weak self] references in
                    guard let self else { throw CancellationError() }; try lifetime.checkCancellation()
                    return try executionReferences(references)
                }, subscribe: { [weak self] listener in self?.subscribeReferences(listener, lifetime: lifetime) ?? {} },
                logo: { [weak self] id, size in
                    guard let self, !isReleased else { throw CancellationError() }
                    try lifetime.checkCancellation()
                    return try workspace.plugins.harnesses.require(id).logo(size: size)
                }))
        ]
        if try conversation(entry) != nil {
            let source = conversationSource(ref: ref, owner: owner, lifetime: lifetime)
            registrations.append(.init(ApplicationCapabilities.conversationUI, value: ApplicationConversationUI(
                workspace: { [weak self] target in
                    NativeApplicationConversationWorkspace(host: self, ref: ref, owner: owner, readingTarget: target, lifetime: lifetime)
                }, card: { [weak self] projection, openThread in
                    NativeApplicationConversationCard(host: self, snapshot: projection.snapshot, source: source,
                                                      lifetime: lifetime, openThread: openThread)
                })))
        }
        if let detail {
            registrations.append(.init(ApplicationCapabilities.isolatedHTML, value: ApplicationIsolatedHTML { [weak self] source, onFailure in
                NativeApplicationHTMLCapabilityView(host: self, source: source, ref: ref, owner: owner,
                    lifetime: lifetime, theme: theme ?? self?.theme ?? .light, detail: detail, onFailure: onFailure)
            }))
        }
        let capabilities = try ApplicationCapabilityAccess(scope: .init(pluginID: owner, thread: ref),
            requires: plugin.requires, registrations: registrations)
        return ApplicationRendererContext(theme: theme ?? self.theme, locale: locale, lifetime: lifetime,
            contentTopInset: detail?.contentTopInset ?? 0,
            domain: try domain(pluginID: owner, viewLifetime: lifetime), capabilities: capabilities,
            openThread: { [weak self] ref, target in
                guard let self, !lifetime.isCancelled else { return }; navigation.openThread(ref, target)
            }, openExecution: { [weak self] reference in
                guard let self, !lifetime.isCancelled else { return }; navigation.openExecution(reference)
            })
    }


    func htmlDocument(source: ApplicationHTMLSource, ref: ApplicationThreadRef, owner: JSONText,
                      lifetime: PluginLifetime) async throws -> ApplicationHTMLDocument {
        try lifetime.checkCancellation()
        guard source.pluginID == owner,
              try workspace.plugins.applications.requireThread(ref.typeID).ownerPluginID == owner,
              try module(owner).manifest.contributes.queries.contains(source.queryID) else {
            throw PluginContractError("HTML document query is not owned by this application")
        }
        _ = try entry(ref)
        let value = try await invokeQuery(args: [.object([
            "pluginId": .string(owner), "operationId": .string(source.queryID), "input": source.input
        ])]) {
            try lifetime.checkCancellation()
            _ = try self.entry(ref)
        }
        try lifetime.checkCancellation()
        _ = try entry(ref)
        guard case .string(let html) = value["html"], case .string(let revision) = value["contentRevision"],
              revision == source.contentRevision else { throw PluginContractError("HTML document content revision changed") }
        return ApplicationHTMLDocument(html: html, contentRevision: revision)
    }
}

@MainActor
private struct NativeApplicationConversationWorkspace: View {
    weak var host: NativeApplicationHost?
    let ref: ApplicationThreadRef
    let owner: JSONText
    let readingTarget: HarnessReadingTarget?
    let lifetime: PluginLifetime
    @State private var failure: String?
    @State private var initializing = false

    var body: some View {
        Group {
            if let host {
                content(host)
            } else { NativeHarnessStatusView(message: "会话已关闭。", english: "Conversation closed.") }
        }
    }
    @ViewBuilder private func content(_ host: NativeApplicationHost) -> some View {
        let result = Result { try host.conversation(host.entry(ref)) }
        switch result {
        case .failure(let error): NativeHarnessStatusView(message: "读取会话失败。", english: "Unable to read conversation.", detail: error.localizedDescription)
        case .success(let conversation):
            if let thread = conversation?.thread {
                NativeHarnessThreadView(host: host.workspace.harnessHost, input: .init(thread: thread, readingTarget: readingTarget),
                    source: host.conversationSource(ref: ref, owner: owner, lifetime: lifetime),
                    routes: NativeHarnessThreadRoutes(openFollowUp: { host.navigation.followUp(thread.id, $0) }))
                    .disabled(!host.isHarnessAvailable(thread.harnessID))
            } else if conversation != nil {
                VStack(alignment: .leading, spacing: 8) {
                    Button(host.workspace.preferences.locale.text("打开会话", "Open conversation")) {
                        Task {
                            initializing = true; failure = nil
                            defer { initializing = false }
                            do { try await host.initialize(ref, owner: owner, viewLifetime: lifetime, callLifetime: lifetime) }
                            catch { if !lifetime.isCancelled { failure = error.localizedDescription } }
                        }
                    }.buttonStyle(.plain).disabled(initializing || !host.isEnabled(owner))
                    if let failure { Text(failure).textSelection(.enabled).foregroundStyle(.red) }
                }
            } else { NativeHarnessStatusView(message: "此类型不支持会话。", english: "This thread type does not support conversations.") }
        }
    }
}

@MainActor
private struct NativeApplicationConversationCard: View {
    weak var host: NativeApplicationHost?
    let snapshot: HarnessOverviewSnapshot
    let source: NativeHarnessConversationSource
    let lifetime: PluginLifetime
    let openThread: () -> Void
    var body: some View {
        if let host, !lifetime.isCancelled {
            snapshot.card(actions: host.workspace.harnessHost.actions(for: snapshot.input.thread, source: source,
                routes: .init(openFollowUp: { host.navigation.followUp(snapshot.input.thread.id, $0) })), openThread: openThread)
        }
    }
}

@MainActor
private struct NativeApplicationHTMLCapabilityView: View {
    weak var host: NativeApplicationHost?
    let source: ApplicationHTMLSource
    let ref: ApplicationThreadRef
    let owner: JSONText
    let lifetime: PluginLifetime
    let theme: PluginTheme
    let detail: NativeApplicationDetailEnvironment
    let onFailure: (ApplicationHTMLFailure) -> Void
    var body: some View {
        if let host {
            NativeApplicationHTMLSurface(source: source, thread: ref, theme: theme, suppressed: detail.suppressed,
                locale: host.locale,
                zoomPreferencesURL: host.workspace.client.storageDirectory.appendingPathComponent("native-html-zoom.json"),
                readDocument: { try await host.htmlDocument(source: $0, ref: ref, owner: owner, lifetime: lifetime) },
                openExternal: { url in try await host.navigation.openExternal(url) }, onBack: detail.onBack, onSettings: detail.onSettings,
                onNativeNavigationChange: detail.onNativeNavigationChange, onFailure: onFailure)
                .environment(\.nativeHTMLPreloader, host.htmlPreloader)
        }
    }
}
