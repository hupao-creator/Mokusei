import SwiftUI

/// Shared launcher chrome; the owning workspace retains selection and focus.
public struct NativeSidecardToggle<Icon: View>: View {
    let expanded: Bool
    let label: String
    let action: () -> Void
    @ViewBuilder let icon: Icon
    @Environment(\.locale) private var locale

    public init(expanded: Bool, label: String, action: @escaping () -> Void,
                @ViewBuilder icon: () -> Icon) {
        self.expanded = expanded; self.label = label; self.action = action; self.icon = icon()
    }

    public var body: some View {
        Button(action: action) {
            icon.frame(width: 42, height: 42).contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(expanded ? .blue.opacity(0.18) : .clear).interactive(), in: .circle)
        .help(label).accessibilityLabel(label)
        .accessibilityValue(locale.language.languageCode?.identifier == "zh"
            ? (expanded ? "已展开" : "已收起") : (expanded ? "Expanded" : "Collapsed"))
    }
}

/// An application contributes controls to the host's real, hit-testable rail.
/// The position is in the application's coordinates, even with a linked Browser open.
public extension EnvironmentValues {
    @Entry var nativeReadingAuxiliaryLauncherPosition: CGPoint? = nil
    @Entry var nativeReadingAuxiliarySuppressed = false
}

public struct NativeReadingAuxiliaryToolbarKey: PreferenceKey {
    public static var defaultValue: AnyView? { nil }
    public static func reduce(value: inout AnyView?, nextValue: () -> AnyView?) {
        if let next = nextValue() { value = next }
    }
}
