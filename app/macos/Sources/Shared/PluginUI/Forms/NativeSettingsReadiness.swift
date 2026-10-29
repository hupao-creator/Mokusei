import SwiftUI
import Observation

/// Local model choices can be incomplete before a plugin emits a saved draft.
/// Each mounted editor owns a readiness lease, independent of layout preferences.
@MainActor @Observable public final class NativeSettingsReadiness {
    public let id = UUID()
    private var editors: [UUID: Bool] = [:]
    public var ready: Bool { !editors.isEmpty && editors.values.allSatisfy { $0 } }
    public init() {}
    fileprivate func update(_ owner: UUID, ready: Bool) { editors[owner] = ready }
    fileprivate func remove(_ owner: UUID) { editors[owner] = nil }
}

private struct NativeSettingsReadinessReporter: ViewModifier {
    let ready: Bool
    @Environment(\.nativeSettingsReadiness) private var registry
    @State private var owner = UUID()
    @State private var registered: NativeSettingsReadiness?
    private struct Status: Equatable { let registry: UUID?; let ready: Bool }
    func body(content: Content) -> some View {
        content
            .onChange(of: Status(registry: registry?.id, ready: ready), initial: true) { _, _ in
                if registered !== registry { registered?.remove(owner); registered = registry }
                registry?.update(owner, ready: ready)
            }
            .onDisappear { registered?.remove(owner); registered = nil }
    }
}

public extension View {
    func nativeSettingsEditorReady(_ ready: Bool) -> some View {
        modifier(NativeSettingsReadinessReporter(ready: ready))
    }
}

public extension EnvironmentValues {
    @Entry var nativeSettingsCompactPresentation = false
    @Entry var nativeSettingsReadiness: NativeSettingsReadiness?
}
