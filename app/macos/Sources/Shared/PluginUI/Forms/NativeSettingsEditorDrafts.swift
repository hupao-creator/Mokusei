import Observation
import SwiftUI

/// A Settings visit retains incomplete plugin input across tab/Harness unmounts.
/// These values never cross the persistence boundary until the plugin emits a
/// complete, typed configuration through its ordinary change callback.
@MainActor @Observable public final class NativeSettingsEditorDrafts {
    private struct Entry {
        let value: Any
        let blocksCommit: Bool
    }
    private var scopes: [String: [String: Entry]] = [:]
    public private(set) var generation = UUID()
    public var incompleteScopes: [String] {
        scopes.keys.sorted().filter { scopes[$0]?.values.contains { $0.blocksCommit } == true }
    }
    public init() {}
    public func reset() { scopes.removeAll(); generation = UUID() }
    fileprivate func value<Value>(_ scope: String, _ key: String, fallback: Value) -> Value {
        scopes[scope]?[key]?.value as? Value ?? fallback
    }
    fileprivate func update<Value>(_ scope: String, _ key: String, value: Value, blocksCommit: Bool) {
        scopes[scope, default: [:]][key] = Entry(value: value, blocksCommit: blocksCommit)
    }
}

/// Outside a Settings role editor this behaves like ordinary view-local State.
@MainActor @propertyWrapper public struct NativeSettingsEditorState<Value>: DynamicProperty {
    @State private var local: Value
    @Environment(\.nativeSettingsEditorDrafts) private var drafts
    @Environment(\.nativeSettingsInteractionScope) private var scope
    private let key: String
    private let blocksCommit: (Value) -> Bool

    public init(wrappedValue: Value, _ key: String, blocksCommit: @escaping (Value) -> Bool = { _ in false }) {
        _local = State(initialValue: wrappedValue)
        self.key = key; self.blocksCommit = blocksCommit
    }
    public var wrappedValue: Value {
        get { drafts?.value(scope, key, fallback: local) ?? local }
        nonmutating set {
            if let drafts { drafts.update(scope, key, value: newValue, blocksCommit: blocksCommit(newValue)) }
            else { local = newValue }
        }
    }
}

public extension EnvironmentValues {
    @Entry var nativeSettingsEditorDrafts: NativeSettingsEditorDrafts?
}
