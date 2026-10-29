import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import SwiftUI

enum NativeSettingsRole: String {
    case moku, tag, report

    init?(section: String) {
        switch section {
        case "moku": self = .moku
        case "tag.settings": self = .tag
        case "report.settings": self = .report
        default: return nil
        }
    }

    var tabLabel: String { rawValue == "moku" ? "Moku" : rawValue.capitalized }
    func title(_ locale: DesktopLocale) -> String {
        switch self {
        case .moku: "Moku"
        case .tag: locale.text("找到想找的会话", "Find your conversations")
        case .report: locale.text("从文字到图示", "From text to pictures")
        }
    }
    var subtitle: String {
        switch self {
        case .moku: "One mind to orchestrate them all."
        case .tag: "A few tags to find them all."
        case .report: "Less to read. More to understand."
        }
    }
}

/// Owned by one Settings page visit, outside the tab's replaceable view identity.
struct NativeSettingsAnimationVisits {
    var tag = false
    var report = false

    mutating func reset() { tag = false; report = false }
}

/// A hidden window does not consume a visit; Reduce Motion consumes it without
/// animation. Once admitted, cancellation must not admit another playback.
enum NativeCapabilityPlayback {
    static func shouldPlay(active: Bool, reduceMotion: Bool, started: Binding<Bool>) -> Bool {
        if reduceMotion { started.wrappedValue = true }
        return active && !started.wrappedValue
    }

    static func begin(_ started: Binding<Bool>) { started.wrappedValue = true }
}

/// Onboarding owns step admission; Settings owns tab navigation. Both mount
/// this same live presentation around their plugin-owned configuration editors.
struct NativeRoleConfigurationPanel<Content: View>: View {
    let role: NativeSettingsRole
    let harnesses: [AnyHarnessPlugin]
    let locale: DesktopLocale
    var visitPlaybackStarted: Binding<Bool>? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Text(role.title(locale)).font(.system(size: 25, weight: .medium)).tracking(-0.5)
                .accessibilityAddTraits(.isHeader).padding(.bottom, 8)
            Text(role.subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: .infinity)
                .fixedSize(horizontal: false, vertical: true).padding(.bottom, 24)
            if role == .tag {
                NativeOnboardingTagAnimation(harnesses: harnesses, locale: locale, visitPlaybackStarted: visitPlaybackStarted).padding(.bottom, 24)
            } else if role == .report {
                NativeOnboardingReportAnimation(harnesses: harnesses, locale: locale, visitPlaybackStarted: visitPlaybackStarted).padding(.bottom, 24)
            }
            content
        }.environment(\.nativeSettingsCompactPresentation, true)
    }
}

struct NativeSettingsPanelGlass: View {
    @Environment(\.accessibilityReduceTransparency) private var opaque
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        if opaque {
            RoundedRectangle(cornerRadius: NativeMokuCapsuleLayout.cornerRadius)
                .fill(Color(white: scheme == .dark ? 0.12 : 0.97))
        } else {
            Color.clear.glassEffect(.regular, in: .rect(cornerRadius: NativeMokuCapsuleLayout.cornerRadius))
        }
    }
}
