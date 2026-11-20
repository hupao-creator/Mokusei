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

    var tabLabel: String {
        switch self {
        case .moku: "Chief"
        case .tag: "Tag"
        case .report: "Super Thread"
        }
    }
    func title(_ locale: DesktopLocale) -> String {
        switch self {
        case .moku: "Chief"
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

/// A hidden window does not consume a visit. Once admitted, cancellation must
/// not admit another playback.
enum NativeCapabilityPlayback {
    static func shouldPlay(active: Bool, started: Binding<Bool>) -> Bool {
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
    let showsHeading: Bool
    var illustrationWidth: CGFloat? = nil
    var visitPlaybackStarted: Binding<Bool>? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            if showsHeading {
                Text(role.title(locale)).font(.system(size: 25, weight: .medium)).tracking(-0.5)
                    .multilineTextAlignment(.center).frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader).padding(.bottom, 8)
                Text(role.subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true).padding(.bottom, 24)
            }
            if role != .moku {
                if let illustrationWidth, !harnesses.isEmpty {
                    NativeSettingsIllustrationPanel(width: illustrationWidth) {
                        animation
                    }
                    .padding(.bottom, 24)
                } else {
                    animation.padding(.bottom, 24)
                }
            }
            content
                .frame(maxWidth: illustrationWidth != nil && role != .moku ? NativeSettingsContentLayout.formWidth : nil,
                       alignment: .leading)
        }.environment(\.nativeSettingsCompactPresentation, true)
    }

    @ViewBuilder private var animation: some View {
        if role == .tag {
            NativeOnboardingTagAnimation(harnesses: harnesses, locale: locale, visitPlaybackStarted: visitPlaybackStarted)
        } else {
            NativeOnboardingReportAnimation(harnesses: harnesses, visitPlaybackStarted: visitPlaybackStarted)
        }
    }
}

struct NativeSettingsIllustrationPanel<Content: View>: View {
    let width: CGFloat
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let paddingScale = min(1, width / 320)
        let horizontalInset = 16 * paddingScale
        let canvasHeight: CGFloat = 250
        let innerWidth = max(0, width - 2 * horizontalInset)
        // Preserve the positions and legibility of the seats, tokens and figures at high zoom.
        let canvasWidth = max(500, innerWidth)
        let scale = innerWidth / canvasWidth
        content.frame(width: canvasWidth, height: canvasHeight)
            .scaleEffect(scale)
            .frame(width: innerWidth, height: canvasHeight * scale)
            .padding(.vertical, 14 * paddingScale)
            .frame(width: width)
            .background {
                let shape = RoundedRectangle(cornerRadius: NativeMokuCapsuleLayout.cornerRadius * paddingScale)
                Color.clear.nativeRegularCardGlass(
                    in: shape,
                    opaque: NativePalette.settings.hintSurface.swiftUI)
                    .overlay {
                        if reduceTransparency {
                            shape.strokeBorder(NativePalette.settings.inputBorder.swiftUI)
                        }
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}

/// Settings owns an opaque reading surface even when transparency is available.
struct NativeSettingsPanelBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: NativeMokuCapsuleLayout.cornerRadius)
            .fill(Color(nsColor: .windowBackgroundColor))
    }
}
