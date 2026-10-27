import Foundation
import MokuseiCore
import MokuseiPluginAPI
import SwiftUI

/// Callbacks belong to the visible glass controls, not to an alternate menu model.
/// Each registration owns its lifetime so a retiring view cannot remove its successor.
@MainActor
public final class NativeOverviewChromeInteractions {
    private struct Entry {
        let owner: UUID
        let filter: NativeOverviewFilter
        let enabled: Bool
        let open: () -> Void
        let close: () -> Void
        let select: (String) -> Void
    }
    private var entries: [UUID: [String: Entry]] = [:]
    private var menus: [UUID: [String: UUID]] = [:]
    private var scrolls: [UUID: (owner: UUID, ids: [String], enabled: Bool, action: (String) -> Void)] = [:]
    private var chromeOwner: UUID?
    public private(set) var openScope: String?

    func install(id: String, owner: UUID, root: UUID, filter: NativeOverviewFilter, enabled: Bool,
                 open: @escaping () -> Void, close: @escaping () -> Void, select: @escaping (String) -> Void) {
        entries[root, default: [:]][id] = Entry(owner: owner, filter: filter, enabled: enabled, open: open, close: close, select: select)
    }
    func remove(id: String, owner: UUID, root: UUID) {
        if entries[root]?[id]?.owner == owner { entries[root]?.removeValue(forKey: id) }
    }
    func installChrome(owner: UUID, openScope: String?) { chromeOwner = owner; self.openScope = openScope }
    func removeChrome(owner: UUID) {
        entries.removeValue(forKey: owner); menus.removeValue(forKey: owner); scrolls.removeValue(forKey: owner)
        if chromeOwner == owner { chromeOwner = nil; openScope = nil }
    }
    func setOpenScope(_ value: String?, owner: UUID) { if chromeOwner == owner { openScope = value } }
    func installScroll(owner: UUID, root: UUID, ids: [String], enabled: Bool, action: @escaping (String) -> Void) {
        scrolls[root] = (owner, ids, enabled, action)
    }
    func removeScroll(owner: UUID, root: UUID) { if scrolls[root]?.owner == owner { scrolls.removeValue(forKey: root) } }
    var canScroll: Bool { chromeOwner.flatMap { scrolls[$0] }?.enabled == true }
    func scrollTo(_ id: String) throws {
        guard let root = chromeOwner, let scroll = scrolls[root], scroll.enabled else { throw NativeInteractionError("unavailable", "Filter bar is not mounted and enabled") }
        guard scroll.ids.contains(id) else { throw NativeInteractionError("not_found", "Top-level filter is unavailable") }
        scroll.action(id)
    }
    func mountMenu(id: String, owner: UUID, root: UUID) { menus[root, default: [:]][id] = owner }
    func unmountMenu(id: String, owner: UUID, root: UUID) {
        if menus[root]?[id] == owner { menus[root]?.removeValue(forKey: id) }
    }

    public var mountedDirectoryIDs: [String] {
        guard let root = chromeOwner else { return [] }
        return (entries[root] ?? [:]).filter { $0.value.enabled }.keys.sorted()
    }
    public var mountedMenuIDs: [String] {
        guard let root = chromeOwner else { return [] }
        return Array((menus[root] ?? [:]).keys).sorted()
    }
    func perform(directory id: String, operation: String, child: String? = nil) throws {
        guard let root = chromeOwner, let entry = entries[root]?[id], entry.enabled else {
            throw NativeInteractionError("unavailable", "Directory control is not mounted and enabled")
        }
        switch operation {
        case "open": entry.open()
        case "close":
            guard openScope == entry.filter.scope else { throw NativeInteractionError("unavailable", "Directory menu is closed") }
            entry.close()
        case "select":
            guard openScope == entry.filter.scope, menus[root]?[id] != nil else {
                throw NativeInteractionError("unavailable", "Directory menu has not mounted")
            }
            guard let child, entry.filter.children.contains(where: { $0.id == child && $0.count > 0 }) else {
                throw NativeInteractionError("not_found", "Child filter is unavailable in this directory")
            }
            entry.select(child)
        default: throw NativeInteractionError("invalid_request", "Unknown directory operation")
        }
    }
}

struct NativeOverviewFilterScrollRegistration: ViewModifier {
    let registry: NativeOverviewChromeInteractions?
    let root: UUID
    let ids: [String]
    let enabled: Bool
    let scroll: (String) -> Void
    @State private var owner = UUID()
    func body(content: Content) -> some View {
        content.onAppear(perform: install)
            .onChange(of: ids) { _, _ in install() }
            .onChange(of: enabled) { _, _ in install() }
            .onDisappear { registry?.removeScroll(owner: owner, root: root) }
    }
    private func install() { registry?.installScroll(owner: owner, root: root, ids: ids, enabled: enabled, action: scroll) }
}

struct NativeOverviewDirectoryRegistration: ViewModifier {
    let registry: NativeOverviewChromeInteractions?
    let root: UUID
    let filter: NativeOverviewFilter
    let enabled: Bool
    let open: () -> Void
    let close: () -> Void
    let select: (String) -> Void
    @State private var owner = UUID()
    func body(content: Content) -> some View {
        content.onAppear(perform: install)
            .onChange(of: filter) { _, _ in install() }
            .onChange(of: enabled) { _, _ in install() }
            .onDisappear { registry?.remove(id: filter.id, owner: owner, root: root) }
    }
    private func install() {
        registry?.install(id: filter.id, owner: owner, root: root, filter: filter, enabled: enabled,
                          open: open, close: close, select: select)
    }
}

struct NativeOverviewMenuRegistration: ViewModifier {
    let registry: NativeOverviewChromeInteractions?
    let root: UUID
    let id: String
    @State private var owner = UUID()
    func body(content: Content) -> some View {
        content.onAppear { registry?.mountMenu(id: id, owner: owner, root: root) }
            .onDisappear { registry?.unmountMenu(id: id, owner: owner, root: root) }
    }
}

@MainActor
extension NativeWorkspacePresentation {
    var overviewInteractionActions: [String] {
        var result: [String] = []
        if interactionPage == "overview" {
            if !scene.interactionPaused, canvas.camera.isInitialized, !canvas.isLayingOut {
                result += ["overview.pan", "overview.zoom"]
            }
            // The toolbar remains usable while the composer pauses canvas input;
            // the production camera defers fitting until that pause ends.
            if canvas.camera.isInitialized { result.append("overview.auto") }
            if overview.error != nil || canvas.layoutError != nil { result.append("overview.retry") }
            if !overview.isSearching, !overview.chromeInteractions.mountedDirectoryIDs.isEmpty {
                result += ["overview.directory.open", "overview.directory.close", "overview.directory.select"]
            }
            if !overview.isSearching, overview.chromeInteractions.canScroll { result.append("overview.filters.scroll") }
            if !scene.disabled, !scene.dockCovered { result.append("moku.input.toggle") }
            if canToggleMokuNote { result.append("moku.note.toggle") }
        }
        if !scene.disabled, interactionPage == "overview" || interactionPage == "moku" {
            result.append("moku.history.toggle")
        }
        return result
    }

    func overviewInteractionSnapshot() -> JSONValue {
        func filter(_ item: NativeOverviewFilter) -> JSONValue {
            .object(["id": .text(item.id), "label": .text(item.displayTag), "tag": .text(item.tag),
                "kind": .text(item.isDirectory ? "directory" : "semantic"), "scope": .text(item.scope),
                "count": .integer(item.count), "aliases": .array(item.aliases.map(JSONValue.text)),
                "children": .array(item.children.filter { $0.count > 0 }.map(filter))])
        }
        let camera = canvas.camera
        let transform = camera.liveTransform
        let viewport: JSONValue = camera.viewport.map {
            .object(["width": .number($0.width), "height": .number($0.height), "toolbarBottom": .number($0.toolbarBottom)])
        } ?? .null
        let automaticFitTarget: JSONValue = camera.automaticFitTarget.map {
            .object(["scale": .number($0.scale), "x": .number($0.x), "y": .number($0.y)])
        } ?? .null
        let cameraState: JSONValue = .object([
            "initialized": .bool(camera.isInitialized), "manual": .bool(camera.manual),
            "animating": .bool(camera.isAnimating), "returning": .bool(camera.returning),
            "scale": .number(transform.scale), "x": .number(transform.x), "y": .number(transform.y),
            "minimumScale": .number(camera.minimumScale), "maximumScale": .number(camera.maximumScale),
            "viewport": viewport, "carouselTarget": camera.carouselTargetID.map(JSONValue.text) ?? .null,
            "motionPending": .bool(camera.hasScheduledMotion), "automaticFitPending": .bool(camera.hasPendingAutomaticFit),
            "automaticFitBlocked": camera.automaticFitBlockReason.map(JSONValue.text) ?? .null,
            "interactionPauseReasons": .array(canvas.interactionPauseReasons.map(JSONValue.text)),
            "automaticFitTarget": automaticFitTarget
        ])
        let placements: [JSONValue] = canvas.presentedPlacements.map {
            .object(["id": .text($0.id), "column": .integer($0.column), "row": .integer($0.row),
                     "columns": .integer($0.columns), "rows": .integer($0.rows)])
        }
        let cards: [JSONValue] = overview.items.map { item in
            var value: [JSONText: JSONValue] = ["id": .text(item.id), "columns": .integer(item.columns),
                "rows": .integer(item.rows), "activatable": .bool(canvas.allowsActivation(cardID: item.id))]
            switch overview.snapshot(for: item) {
            case .harness(let snapshot):
                let thread = snapshot.input.thread
                value["ref"] = ApplicationThreadRef(threadID: thread.id, typeID: "agent").json
                value["title"] = .string(thread.title)
                value["cwd"] = .string(thread.cwd)
                value["scope"] = .string(thread.directoryScope)
                value["directoryLabel"] = .string(thread.directoryTag)
                value["tags"] = .array(thread.tags.map(JSONValue.string))
            case .application(_, let snapshot):
                value["ref"] = snapshot.entry.ref.json
                value["title"] = .string(snapshot.entry.title)
            case nil: break
            }
            return .object(value)
        }
        return .object([
            "sceneKey": .text(overview.sceneKey), "layingOut": .bool(canvas.isLayingOut),
            "stage": canvas.motionStages.activeOwner.map(JSONValue.text) ?? .null,
            "filters": .array(overview.visibleFilters.map(filter)), "cards": .array(cards),
            "mountedCardIds": .array(canvas.mountedCardIDs.sorted().map(JSONValue.text)),
            "placements": .array(placements), "camera": cameraState,
            "menu": .object([
                "openScope": overview.chromeInteractions.openScope.map(JSONValue.text) ?? .null,
                "mountedDirectoryIds": .array(overview.chromeInteractions.mountedDirectoryIDs.map(JSONValue.text)),
                "mountedMenuIds": .array(overview.chromeInteractions.mountedMenuIDs.map(JSONValue.text))
            ]),
            "dock": .object(["inputOpen": .bool(scene.inputOpen), "inputLeaving": .bool(scene.inputLeaving),
                "historyOpen": .bool(scene.mokuOpen), "noteOpen": .bool(scene.notePanelOpen), "covered": .bool(scene.dockCovered)])
        ])
    }

    func performOverviewInteraction(_ action: NativeWorkspaceAction) throws {
        switch action {
        case .overviewPan(let x, let y): canvas.camera.pan(deltaX: x, deltaY: y)
        case .overviewZoom(let delta, let x, let y):
            guard let viewport = canvas.camera.viewport, (0...1).contains(x), (0...1).contains(y) else {
                throw NativeInteractionError("invalid_request", "Zoom anchor must be within the normalized viewport")
            }
            canvas.camera.zoom(deltaY: delta, cursor: CGPoint(x: viewport.width * x, y: viewport.height * y))
        case .overviewAuto: canvas.camera.returnToAuto()
        case .overviewRetry: overview.refresh(); canvas.retryLayout()
        case .overviewDirectoryOpen(let id): try overview.chromeInteractions.perform(directory: id, operation: "open")
        case .overviewDirectoryClose(let id): try overview.chromeInteractions.perform(directory: id, operation: "close")
        case .overviewDirectorySelect(let id, let filter): try overview.chromeInteractions.perform(directory: id, operation: "select", child: filter)
        case .overviewScrollFilter(let id): try overview.chromeInteractions.scrollTo(id)
        case .toggleMokuInput: scene.toggleInput()
        case .toggleMokuHistory: scene.toggleMoku()
        case .toggleMokuNote: toggleMokuNote()
        default: throw NativeInteractionError("invalid_request", "Not an Overview action")
        }
    }
}
