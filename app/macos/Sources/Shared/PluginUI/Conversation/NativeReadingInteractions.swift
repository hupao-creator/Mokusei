import AppKit
import Observation
import MokuseiCore
import SwiftUI

public struct NativeReadingControlError: Error, LocalizedError {
    public let code: String
    public let message: String
    public init(_ code: String, _ message: String) { self.code = code; self.message = message }
    public var errorDescription: String? { message }
}

/// A window visit owns controls. Retained pages and recycled rows cannot operate
/// a replacement visit, even when their thread and row identities are identical.
@MainActor @Observable
public final class NativeReadingInteractions {
    public private(set) var refresh = 0
    private struct Entry {
        let owner: UUID
        let visit: UUID
        let refresh: Int
        let descriptor: JSONValue
        let handle: String
        let perform: (String, JSONValue) throws -> Void
    }
    @ObservationIgnored private var entries: [String: Entry] = [:]
    public init() {}

    fileprivate func install(id: String, owner: UUID, visit: UUID, refresh: Int,
                             descriptor: JSONValue, perform: @escaping (String, JSONValue) throws -> Void) {
        let old = entries[id]
        let unchanged = old?.owner == owner && old?.visit == visit && old?.refresh == refresh && old?.descriptor == descriptor
        entries[id] = Entry(owner: owner, visit: visit, refresh: refresh, descriptor: descriptor,
            handle: unchanged ? old!.handle : UUID().uuidString, perform: perform)
    }
    fileprivate func remove(id: String, owner: UUID) {
        if entries[id]?.owner == owner { entries[id] = nil }
    }
    public func snapshot(visit: UUID) -> [JSONValue] {
        entries.keys.sorted().compactMap { id in
            guard let entry = entries[id], entry.visit == visit else { return nil }
            var value = entry.descriptor.objectValue ?? [:]
            value["id"] = .text(id); value["handle"] = .text(entry.handle)
            value["pending"] = .bool(entry.refresh != refresh)
            return .object(value)
        }
    }
    public func perform(id: String, handle: String, operation: String, value: JSONValue, visit: UUID) throws {
        guard let entry = entries[id], entry.visit == visit else {
            throw NativeReadingControlError("unavailable", "Reading control is not mounted in the current document")
        }
        guard entry.handle == handle, entry.refresh == refresh else {
            throw NativeReadingControlError("stale_control", "Observe the updated reading control before operating it")
        }
        guard entry.descriptor["enabled"] == .bool(true) else { throw NativeReadingControlError("unavailable", "Reading control is disabled") }
        guard entry.descriptor["operations"]?.arrayValue?.contains(.text(operation)) == true else {
            throw NativeReadingControlError("invalid_request", "Unsupported reading control operation")
        }
        try entry.perform(operation, value)
        // The next command must observe SwiftUI's new callbacks and dependent
        // disclosures, including when an accepted action makes no state change.
        refresh += 1
    }
}

private struct ReadingRegistryKey: EnvironmentKey { static let defaultValue: NativeReadingInteractions? = nil }
private struct ReadingVisitKey: EnvironmentKey { static let defaultValue: UUID? = nil }
private struct ReadingScopeKey: EnvironmentKey { static let defaultValue = "" }
private struct ReadingRefreshKey: EnvironmentKey { static let defaultValue = 0 }
private struct ReadingActiveKey: EnvironmentKey { static let defaultValue = true }
public extension EnvironmentValues {
    var nativeReadingInteractions: NativeReadingInteractions? {
        get { self[ReadingRegistryKey.self] }
        set { self[ReadingRegistryKey.self] = newValue }
    }
    var nativeReadingInteractionVisit: UUID? {
        get { self[ReadingVisitKey.self] }
        set { self[ReadingVisitKey.self] = newValue }
    }
    var nativeReadingInteractionScope: String {
        get { self[ReadingScopeKey.self] }
        set { self[ReadingScopeKey.self] = newValue }
    }
    var nativeReadingInteractionRefresh: Int {
        get { self[ReadingRefreshKey.self] }
        set { self[ReadingRefreshKey.self] = newValue }
    }
    var nativeReadingInteractionActive: Bool {
        get { self[ReadingActiveKey.self] }
        set { self[ReadingActiveKey.self] = newValue }
    }
}

/// Encoding code units preserves opaque plugin identities, including non-scalar
/// JSON strings. Dots inside a plugin ID cannot collide with scope separators.
func nativeReadingInteractionKey(_ id: JSONText) -> String {
    Data(id.codeUnits.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8(truncatingIfNeeded: $0 >> 8)] }).base64EncodedString()
}

private struct NativeReadingScope: ViewModifier {
    let component: String
    @Environment(\.nativeReadingInteractionScope) private var scope
    func body(content: Content) -> some View {
        content.environment(\.nativeReadingInteractionScope, scope.isEmpty ? component : scope + "." + component)
    }
}
private struct NativeReadingActive: ViewModifier {
    let active: Bool
    @Environment(\.nativeReadingInteractionActive) private var inherited
    func body(content: Content) -> some View { content.environment(\.nativeReadingInteractionActive, inherited && active) }
}

public struct NativeReadingControlRegistration: NSViewRepresentable {
    public let id: String
    public let descriptor: JSONValue
    public let perform: (String, JSONValue) throws -> Void
    @Environment(\.nativeReadingInteractions) private var registry
    @Environment(\.nativeReadingInteractionVisit) private var visit
    @Environment(\.nativeReadingInteractionScope) private var scope
    @Environment(\.nativeReadingInteractionRefresh) private var refresh
    @Environment(\.nativeReadingInteractionActive) private var active
    @Environment(\.isEnabled) private var enabled
    public init(id: String, descriptor: JSONValue, perform: @escaping (String, JSONValue) throws -> Void = { _, _ in }) {
        self.id = id; self.descriptor = descriptor; self.perform = perform
    }
    public func makeNSView(context: Context) -> Registration { Registration() }
    public func updateNSView(_ view: Registration, context: Context) {
        var data = descriptor.objectValue ?? [:]
        data["enabled"] = .bool(enabled && data["enabled"] != .bool(false))
        data["scope"] = .text(scope)
        let key = scope.isEmpty ? id : scope + "." + id
        view.update = { [weak view] in
            guard let view else { return }
            guard view.window != nil, active, let registry, let visit else { view.remove(); return }
            if view.registry !== registry || view.id != key { view.remove() }
            view.registry = registry; view.id = key
            registry.install(id: key, owner: view.owner, visit: visit, refresh: refresh, descriptor: .object(data), perform: perform)
        }
        view.update?()
    }
    public static func dismantleNSView(_ view: Registration, coordinator: ()) { view.remove(); view.update = nil }
    @MainActor public final class Registration: NSView {
        fileprivate let owner = UUID()
        fileprivate weak var registry: NativeReadingInteractions?
        fileprivate var id: String?
        fileprivate var update: (() -> Void)?
        fileprivate func remove() { if let id { registry?.remove(id: id, owner: owner) }; registry = nil; id = nil }
        public override func hitTest(_ point: NSPoint) -> NSView? { nil }
        public override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { remove() } else { update?() }
        }
    }
}

public extension View {
    func nativeReadingScope(_ component: String) -> some View { modifier(NativeReadingScope(component: component)) }
    func nativeReadingActive(_ active: Bool) -> some View { modifier(NativeReadingActive(active: active)) }
    func nativeReadingAction(_ id: String, role: String, label: String, value: JSONValue = .null,
                             enabled: Bool = true, action: @escaping () -> Void) -> some View {
        background(NativeReadingControlRegistration(id: id, descriptor: .object([
            "kind": .text("button"), "role": .text(role), "label": .text(label), "value": value,
            "enabled": .bool(enabled), "operations": .array([.text("activate")])
        ])) { _, input in
            guard input == .null else { throw NativeReadingControlError("invalid_request", "Reading button expects null value") }
            action()
        })
    }
    func nativeReadingObservation(_ id: String, role: String, value: JSONValue) -> some View {
        background(NativeReadingControlRegistration(id: id, descriptor: .object([
            "kind": .text("state"), "role": .text(role), "value": value, "operations": .array([])
        ])))
    }
}
