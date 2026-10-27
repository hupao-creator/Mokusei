import Foundation
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI

@MainActor
public extension NativeWorkspacePresentation {
    var interactionPage: String {
        if scene.settingsOpen { return "settings" }
        if scene.mokuOpen { return "moku" }
        return selected == nil ? "overview" : "thread"
    }

    var interactionSettingsSections: [String] {
        NativeSettingsNavigation.sections(model: workspace.settingsModel,
            applications: applicationHost.settingsSections(model: workspace.settingsModel))
    }

    private var interactionFilters: [NativeOverviewFilter] {
        overview.visibleFilters.flatMap { [$0] + $0.children.filter { $0.count > 0 } }
    }

    private var interactionThreads: [ApplicationThreadRef] {
        overview.items.compactMap { item in
            switch overview.snapshot(for: item) {
            case .harness(let snapshot):
                return ApplicationThreadRef(threadID: snapshot.input.thread.id, typeID: "agent")
            case .application(let plugin, let snapshot): return plugin.hasDetail ? snapshot.entry.ref : nil
            case nil: return nil
            }
        }.sorted { ($0.typeID.string, $0.threadID.string) < ($1.typeID.string, $1.threadID.string) }
    }

    var interactionActions: [String] {
        guard interactionReady else { return [] }
        if scene.settingsOpen {
            var actions = ["settings.select", "settings.control"]
            if settingsNavigation.closeBlockReason(model: workspace.settingsModel) == nil {
                actions += ["settings.close", "navigation.back", "overview.show"]
            }
            return actions.sorted()
        }
        var actions = ["settings.open"]
        if interactionPage == "overview" {
            actions += ["filter.select"]
            actions += overview.isSearching ? ["search.update", "search.end"] : ["search.begin"]
            if !interactionThreads.isEmpty { actions += ["thread.open"] }
        } else {
            actions += ["overview.show"]
            if navigation != nil || scene.mokuOpen || (selected != nil && nativeApplicationNavigation) { actions += ["navigation.back"] }
        }
        actions += overviewInteractionActions
        actions += readingInteractionActions
        return actions.sorted()
    }

    /// A response acknowledges semantic state, not completed rendering or saving.
    /// Callers observe mounted/transitioning and their own route postcondition.
    func interactionSnapshot() -> JSONValue {
        let sections = interactionSettingsSections
        let section = sections.contains(settingsNavigation.section) ? settingsNavigation.section : "general"
        let draft = workspace.settingsModel.draft
        let pageMounted = scene.settingsOpen ? settingsNavigation.mounted
            : scene.mokuOpen ? navigation != nil
            : selected == nil || mountedReadingThread == selected
        let settings: JSONValue = .object([
                "controls": .array(scene.settingsOpen && settingsNavigation.mounted
                    ? settingsNavigation.interactions.snapshot(context: settingsNavigation.interactionContext(section: section)) : []),
                "revision": .integer(draft.revision), "catalogRevision": .integer(workspace.catalog.settingsRevision), "status": .text(String(describing: draft.status)),
                "error": draft.error.map(JSONValue.text) ?? .null,
                "composing": .bool(draft.composing), "conflicted": .bool(draft.conflicted),
                "invalidField": draft.firstInvalidField.map(JSONValue.text) ?? .null,
                "appearance": .text(workspace.preferences.appearance.rawValue), "locale": .text(workspace.preferences.locale.rawValue),
                "glassWorld": .bool(workspace.preferences.glassWorld)
            ])
        return .object([
            "page": .text(interactionPage), "mounted": .bool(interactionReady && pageMounted),
            "transitioning": .bool(messageMotion.active || scene.cameraActive || scene.flightActive || scene.settingsTransitioning),
            "runtimeAvailable": .bool(workspace.runtimeAvailable),
            "selectedThread": selected?.json ?? .null,
            "settingsSection": scene.settingsOpen ? .text(section) : .null,
            "settingsSections": .array(sections.map(JSONValue.text)),
            "settings": settings,
            "settingsCloseBlocked": settingsNavigation.closeBlockReason(model: workspace.settingsModel).map(JSONValue.text) ?? .null,
            "settingsSaving": .bool(workspace.settingsModel.draft.status == .saving || workspace.settingsModel.draft.status == .pending),
            "search": .object(["active": .bool(overview.isSearching), "query": .text(overview.searchQuery),
                "mode": .text(overview.searchMode), "indexing": .bool(overview.searchIndexing)]),
            "selectedFilterId": overview.selectedFilter.map { .text($0.id) } ?? .null,
            "filters": .array(interactionFilters.sorted { $0.id < $1.id }.map {
                .object(["id": .text($0.id), "label": .text($0.displayTag), "count": .integer($0.count)])
            }),
            "threads": .array(interactionThreads.map(\.json)),
            "overview": overviewInteractionSnapshot(),
            "reading": readingInteractionSnapshot(),
            "actions": .array(interactionActions.map(JSONValue.text)),
            "errors": .array([workspace.operationError, workspace.connectionError,
                workspace.settingsModel.draft.error, workspace.settingsModel.operationError, overview.error, canvas.layoutError].compactMap { $0.map(JSONValue.text) })
        ])
    }

    func performInteraction(_ action: NativeWorkspaceAction) throws {
        if scene.settingsOpen, ["settings.close", "navigation.back", "overview.show"].contains(action.name),
           let reason = settingsNavigation.closeBlockReason(model: workspace.settingsModel) {
            // Preserve the page's invalid-field focus behavior even on rejection.
            settingsNavigation.requestClose(model: workspace.settingsModel) { _ in }
            throw NativeInteractionError("blocked", reason)
        }
        guard interactionActions.contains(action.name) else {
            throw NativeInteractionError("unavailable", "\(action.name) is unavailable on the current page")
        }
        switch action {
        case .openSettings: openSettings()
        case .closeSettings: try closeSettingsForInteraction()
        case .selectSettingsSection(let section):
            guard interactionSettingsSections.contains(section) else {
                throw NativeInteractionError("not_found", "Settings section is unavailable")
            }
            settingsNavigation.section = section
        case .settingsControl(let id, let handle, let operation, let value):
            let section = interactionSettingsSections.contains(settingsNavigation.section) ? settingsNavigation.section : "general"
            do {
                try settingsNavigation.interactions.perform(id: id, handle: handle, operation: operation, value: value,
                    context: settingsNavigation.interactionContext(section: section))
            } catch let error as NativeSettingsControlError { throw NativeInteractionError(error.code, error.message) }
        case .readingControl(let id, let handle, let operation, let value):
            try performReadingControl(id: id, handle: handle, operation: operation, value: value)
        case .showOverview:
            if scene.settingsOpen { try closeSettingsForInteraction() }
            showOverview()
        case .back:
            if scene.settingsOpen { try closeSettingsForInteraction() }
            else if let navigation { navigation.onBack() }
            else if selected != nil, nativeApplicationNavigation { closeApplication() }
            else { scene.setMokuOpen(false) }
        case .openThread(let ref):
            guard interactionThreads.contains(ref) else {
                throw NativeInteractionError("not_found", "Thread is not in the current Overview")
            }
            open(ref)
        case .beginSearch: overview.beginSearch()
        case .updateSearch(let query): overview.updateSearch(query)
        case .endSearch: overview.endSearch()
        case .selectFilter(let id):
            let filter = id.flatMap { id in interactionFilters.first { $0.id == id } }
            guard id == nil || filter != nil else { throw NativeInteractionError("not_found", "Filter is unavailable") }
            overview.selectTag(filter)
        case .overviewPan, .overviewZoom, .overviewAuto, .overviewRetry,
             .overviewDirectoryOpen, .overviewDirectoryClose, .overviewDirectorySelect,
             .overviewScrollFilter,
             .toggleMokuInput, .toggleMokuHistory, .toggleMokuNote:
            try performOverviewInteraction(action)
        }
    }

    private func closeSettingsForInteraction() throws {
        guard settingsNavigation.requestClose(model: workspace.settingsModel, onClose: { scene.closeSettings(origin: $0) }) else {
            throw NativeInteractionError("blocked", "Settings cannot close yet")
        }
    }
}
