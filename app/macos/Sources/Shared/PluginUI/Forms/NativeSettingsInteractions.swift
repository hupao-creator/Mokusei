import AppKit
import Observation
import MokuseiCore
import SwiftUI

public struct NativeSettingsInteractionContext: Equatable, Sendable {
    public let visit: UUID
    public let section: String
    public init(visit: UUID, section: String) { self.visit = visit; self.section = section }
}

public struct NativeSettingsControlError: Error, LocalizedError {
    public let code: String
    public let message: String
    public init(_ code: String, _ message: String) { self.code = code; self.message = message }
    public var errorDescription: String? { message }
}

/// Handles belong to mounted controls, never to paths inside a settings JSON document.
@MainActor @Observable
public final class NativeSettingsInteractions {
    public private(set) var refresh = 0
    private struct Entry {
        let owner: UUID
        let context: NativeSettingsInteractionContext
        let refresh: Int
        let descriptor: JSONValue
        let handle: String
        let perform: (String, JSONValue) throws -> Void
    }
    @ObservationIgnored private var entries: [String: Entry] = [:]
    public init() {}

    fileprivate func install(id: String, owner: UUID, context: NativeSettingsInteractionContext, refresh: Int,
                             descriptor: JSONValue, perform: @escaping (String, JSONValue) throws -> Void) {
        let previous = entries[id]
        let unchanged = previous?.owner == owner && previous?.context == context
            && previous?.refresh == refresh && previous?.descriptor == descriptor
        entries[id] = Entry(owner: owner, context: context, refresh: refresh, descriptor: descriptor,
            handle: unchanged ? previous!.handle : UUID().uuidString, perform: perform)
    }
    fileprivate func remove(id: String, owner: UUID) {
        if entries[id]?.owner == owner { entries[id] = nil }
    }
    public func snapshot(context: NativeSettingsInteractionContext) -> [JSONValue] {
        entries.keys.sorted().compactMap { id in
            guard let entry = entries[id], entry.context == context else { return nil }
            var value = entry.descriptor.objectValue ?? [:]
            value["id"] = .text(id); value["handle"] = .text(entry.handle)
            value["pending"] = .bool(entry.refresh != refresh)
            return .object(value)
        }
    }
    public func perform(id: String, handle: String, operation: String, value: JSONValue,
                        context: NativeSettingsInteractionContext) throws {
        guard let entry = entries[id], entry.context == context else {
            throw NativeSettingsControlError("unavailable", "Control is not mounted in the current Settings section")
        }
        guard entry.handle == handle, entry.refresh == refresh else {
            throw NativeSettingsControlError("stale_control", "Observe the updated control before operating it")
        }
        guard entry.descriptor["enabled"] == .bool(true) else { throw NativeSettingsControlError("unavailable", "Control is disabled") }
        guard entry.descriptor["operations"]?.arrayValue?.contains(.text(operation)) == true else {
            throw NativeSettingsControlError("invalid_request", "Unsupported control operation")
        }
        try entry.perform(operation, value)
        // Even a no-op choice must refresh captured bindings before the next
        // command. Dependent menus may change during the ensuing SwiftUI update.
        refresh += 1
    }
}

private struct InteractionRegistryKey: EnvironmentKey { static let defaultValue: NativeSettingsInteractions? = nil }
private struct InteractionContextKey: EnvironmentKey { static let defaultValue: NativeSettingsInteractionContext? = nil }
private struct InteractionScopeKey: EnvironmentKey { static let defaultValue = "" }
private struct InteractionFieldKey: EnvironmentKey { static let defaultValue: String? = nil }
private struct InteractionRefreshKey: EnvironmentKey { static let defaultValue = 0 }
public extension EnvironmentValues {
    var nativeSettingsInteractions: NativeSettingsInteractions? {
        get { self[InteractionRegistryKey.self] }
        set { self[InteractionRegistryKey.self] = newValue }
    }
    var nativeSettingsInteractionContext: NativeSettingsInteractionContext? {
        get { self[InteractionContextKey.self] }
        set { self[InteractionContextKey.self] = newValue }
    }
    var nativeSettingsInteractionScope: String {
        get { self[InteractionScopeKey.self] }
        set { self[InteractionScopeKey.self] = newValue }
    }
    var nativeSettingsControlID: String? {
        get { self[InteractionFieldKey.self] }
        set { self[InteractionFieldKey.self] = newValue }
    }
    var nativeSettingsInteractionRefresh: Int {
        get { self[InteractionRefreshKey.self] }
        set { self[InteractionRefreshKey.self] = newValue }
    }
}

/// Used by native editors as well as the zero-size registration adapter below.
@MainActor public final class NativeSettingsControlLease {
    private let owner = UUID()
    private weak var registry: NativeSettingsInteractions?
    private var id: String?
    public init() {}
    public func install(registry: NativeSettingsInteractions?, context: NativeSettingsInteractionContext?,
                        scope: String, field: String?, refresh: Int, descriptor: JSONValue,
                        perform: @escaping (String, JSONValue) throws -> Void) {
        guard let registry, let context, let field else { remove(); return }
        let next = (scope.isEmpty ? context.section : scope) + "." + field
        if self.registry !== registry || id != next { remove() }
        self.registry = registry; id = next
        registry.install(id: next, owner: owner, context: context, refresh: refresh, descriptor: descriptor, perform: perform)
    }
    public func remove() { if let id { registry?.remove(id: id, owner: owner) }; registry = nil; id = nil }
}

public struct NativeSettingsControlRegistration: NSViewRepresentable {
    public let descriptor: JSONValue
    public let perform: (String, JSONValue) throws -> Void
    @Environment(\.nativeSettingsInteractions) private var registry
    @Environment(\.nativeSettingsInteractionContext) private var interactionContext
    @Environment(\.nativeSettingsInteractionScope) private var scope
    @Environment(\.nativeSettingsControlID) private var field
    @Environment(\.nativeSettingsInteractionRefresh) private var refresh
    @Environment(\.isEnabled) private var enabled
    public init(descriptor: JSONValue, perform: @escaping (String, JSONValue) throws -> Void) {
        self.descriptor = descriptor; self.perform = perform
    }
    public func makeNSView(context: Context) -> Registration { Registration() }
    public func updateNSView(_ view: Registration, context: Context) {
        var data = descriptor.objectValue ?? [:]
        data["enabled"] = .bool(enabled && data["enabled"] != .bool(false))
        view.update = { [weak view] in
            guard let view, view.window != nil else { return }
            view.lease.install(registry: registry, context: interactionContext, scope: scope, field: field,
                               refresh: refresh, descriptor: .object(data), perform: perform)
        }
        view.update?()
    }
    public static func dismantleNSView(_ view: Registration, coordinator: ()) { view.lease.remove(); view.update = nil }
    @MainActor public final class Registration: NSView {
        let lease = NativeSettingsControlLease()
        var update: (() -> Void)?
        public override func hitTest(_ point: NSPoint) -> NSView? { nil }
        public override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { lease.remove() } else { update?() }
        }
    }
}

public extension View {
    func nativeSettingsControl(_ id: String) -> some View { environment(\.nativeSettingsControlID, id) }
    func nativeSettingsAction(_ id: String, label: String, selected: Bool? = nil,
                              action: @escaping () -> Void) -> some View {
        background(NativeSettingsControlRegistration(descriptor: .object([
            "kind": .text("button"), "label": .text(label), "operations": .array([.text("activate")]),
            "value": selected.map(JSONValue.bool) ?? .null
        ])) { _, value in
            guard value == .null else { throw NativeSettingsControlError("invalid_request", "Button expects null value") }
            action()
        }.nativeSettingsControl(id))
    }
}

/// NSTextInputClient drives the real editor, including composition and delegate
/// notifications. No draft/composing flags are assigned by the automation layer.
@MainActor public func nativeSettingsEdit(_ editor: NSTextView, operation: String, value: JSONValue) throws {
    guard let window = editor.window, editor.isEditable else { throw NativeSettingsControlError("unavailable", "Editor is not available") }
    if operation == "blur" {
        guard value == .null else { throw NativeSettingsControlError("invalid_request", "Blur expects null value") }
        if window.firstResponder === editor, !window.makeFirstResponder(nil) {
            throw NativeSettingsControlError("blocked", "Editor cannot end editing yet")
        }
        return
    }
    guard case .string(let text) = value, JSONText(text.string) == text, text.codeUnits.count <= 20_000 else {
        throw NativeSettingsControlError("invalid_request", "Text requires at most 20000 UTF-16 units")
    }
    guard window.makeFirstResponder(editor) else { throw NativeSettingsControlError("blocked", "Editor cannot receive focus yet") }
    let range = NSRange(location: 0, length: editor.string.utf16.count)
    if operation == "compose" { editor.setMarkedText(text.string, selectedRange: NSRange(location: text.codeUnits.count, length: 0), replacementRange: range) }
    else { editor.insertText(text.string, replacementRange: range) }
}

public struct NativeSettingsEditorInteraction: DynamicProperty {
    @Environment(\.nativeSettingsInteractions) private var registry
    @Environment(\.nativeSettingsInteractionContext) private var context
    @Environment(\.nativeSettingsInteractionScope) private var scope
    @Environment(\.nativeSettingsControlID) private var field
    @Environment(\.nativeSettingsInteractionRefresh) private var refresh
    @Environment(\.isEnabled) private var enabled
    public init() {}
    @MainActor public func install(_ lease: NativeSettingsControlLease, editor: NSTextView, label: String, value: String, invalid: Bool) {
        guard editor.window != nil else { lease.remove(); return }
        lease.install(registry: registry, context: context, scope: scope, field: field, refresh: refresh, descriptor: .object([
            "kind": .text("textarea"), "label": .text(label), "value": .text(value),
            "enabled": .bool(enabled), "invalid": .bool(invalid), "composing": .bool(editor.hasMarkedText()),
            "operations": .array(["set", "compose", "commit", "blur"].map(JSONValue.text))
        ])) { [weak editor] operation, value in
            guard let editor else { throw NativeSettingsControlError("unavailable", "Editor was removed") }
            try nativeSettingsEdit(editor, operation: operation, value: value)
        }
    }
}
