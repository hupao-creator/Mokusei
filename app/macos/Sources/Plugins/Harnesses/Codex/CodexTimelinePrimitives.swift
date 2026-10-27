import MokuseiPluginUI
import SwiftUI

/// The renderer's 1.5 px ring and 800 ms linear turn, drawn natively rather than
/// using the visually different system indeterminate progress control.
struct CodexStatusSpinner: View {
    var size: CGFloat = 12
    var lineWidth: CGFloat = 1.5
    var body: some View {
        TimelineView(.animation(minimumInterval: NativeFrameRate.interval)) { clock in
            let rotation = clock.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.8) / 0.8 * 360
            ZStack {
                Circle().stroke(NativePalette.pair(0xc5c4bd, 0x686b60).swiftUI, lineWidth: lineWidth)
                Circle().trim(from: 0, to: 0.25).stroke(NativePalette.thread.accent.swiftUI, lineWidth: lineWidth)
                    .rotationEffect(.degrees(rotation - 135))
            }.padding(lineWidth / 2)
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct CodexReviewDisclosure<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @State private var expanded = false
    @State private var hovered = false
    @Environment(\.locale) private var locale
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 7) {
                    NativeIcon(name: "GitPullRequest", size: 13)
                    Text("Review").font(NativeTypography.inter(size: 11, weight: 620)).foregroundStyle(NativePalette.thread.ink.swiftUI)
                    Spacer(minLength: 0)
                    NativeIcon(name: expanded ? "ChevronDown" : "ChevronRight", size: 13)
                }.font(NativeTypography.inter(size: 11))
                    .foregroundStyle((hovered ? NativePalette.thread.ink : NativePalette.thread.muted).swiftUI)
                    .padding(.vertical, 4).contentShape(Rectangle())
            }.buttonStyle(.plain).onHover { hovered = $0 }
                .accessibilityValue(NativePluginLocalization.localize(expanded ? "已展开" : "已收起", locale: locale))
            if expanded { content().padding(.top, 10) }
        }
    }
}
