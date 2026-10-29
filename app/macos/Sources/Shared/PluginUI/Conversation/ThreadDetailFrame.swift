import SwiftUI

@MainActor
public struct ThreadDetailBackAction: Identifiable {
    public let id: UUID
    public let label: String
    public let onBack: () -> Void
    public init(label: String, onBack: @escaping () -> Void) {
        id = UUID(); self.label = label; self.onBack = onBack
    }
}

@MainActor
final class ThreadDetailNavigationScope: ObservableObject {
    @Published private(set) var action: ThreadDetailBackAction?
    var hostOwned = false
    func register(_ action: ThreadDetailBackAction) -> UUID {
        self.action = action
        return action.id
    }
    func unregister(_ token: UUID) {
        if action?.id == token { action = nil }
    }
}
private struct ThreadDetailNavigationKey: EnvironmentKey {
    static let defaultValue: ThreadDetailNavigationScope? = nil
}
private struct ThreadDetailRootNavigationKey: EnvironmentKey {
    static let defaultValue: ThreadDetailBackAction? = nil
}
extension EnvironmentValues {
    var threadDetailNavigation: ThreadDetailNavigationScope? {
        get { self[ThreadDetailNavigationKey.self] }
        set { self[ThreadDetailNavigationKey.self] = newValue }
    }
    var threadDetailRootNavigation: ThreadDetailBackAction? {
        get { self[ThreadDetailRootNavigationKey.self] }
        set { self[ThreadDetailRootNavigationKey.self] = newValue }
    }
}

/// Lets the host render one back control, while a history page temporarily owns its action.
public struct ThreadDetailFrame<Content: View>: View {
    private let navigation: ThreadDetailBackAction?
    private let onNavigationChange: ((ThreadDetailBackAction?) -> Void)?
    private let isolatedNavigation: Bool
    private let content: Content
    @StateObject private var scope = ThreadDetailNavigationScope()
    @Environment(\.threadDetailNavigation) private var inherited
    @Environment(\.threadDetailRootNavigation) private var inheritedRoot

    public init(navigation: ThreadDetailBackAction? = nil,
                onNavigationChange: ((ThreadDetailBackAction?) -> Void)? = nil,
                isolatedNavigation: Bool = false, @ViewBuilder content: () -> Content) {
        self.navigation = navigation; self.onNavigationChange = onNavigationChange
        self.isolatedNavigation = isolatedNavigation; self.content = content()
    }
    private var hostOwned: Bool { navigation != nil || onNavigationChange != nil }
    private var ownsNavigation: Bool { isolatedNavigation || inherited == nil || (hostOwned && inherited?.hostOwned == false) }
    private var action: ThreadDetailBackAction? { scope.action ?? navigation }
    public var body: some View {
        content
            .environment(\.threadDetailNavigation, ownsNavigation ? scope : inherited)
            .environment(\.threadDetailRootNavigation, ownsNavigation ? navigation : inheritedRoot)
            .overlay(alignment: .topLeading) {
                if ownsNavigation, onNavigationChange == nil, let action {
                    Button(action: action.onBack) { NativeIcon(name: "ArrowLeft", size: 17).frame(width: 32, height: 30) }
                        .buttonStyle(.plain).background(NativePalette.thread.surface.swiftUI, in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(NativePalette.thread.line.swiftUI))
                        .padding(16).help(action.label).accessibilityLabel(action.label)
                }
            }
            .onAppear { scope.hostOwned = hostOwned; publish() }
            .onChange(of: scope.action?.id) { _, _ in publish() }
            .onChange(of: navigation?.id) { _, _ in publish() }
            .onDisappear { if ownsNavigation { onNavigationChange?(nil) } }
    }
    private func publish() { if ownsNavigation { onNavigationChange?(action) } }
}
