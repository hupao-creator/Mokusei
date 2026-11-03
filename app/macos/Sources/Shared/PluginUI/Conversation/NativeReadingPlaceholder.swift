import SwiftUI

/// Presentation only: the owner still decides whether content is loading.
public struct NativeReadingPlaceholder: View {
    public enum Placement { case surface, inline }

    private let placement: Placement
    @Environment(\.locale) private var locale
    @State private var visible = false

    public init(placement: Placement = .surface) {
        self.placement = placement
    }

    public var body: some View {
        Text(locale.language.languageCode?.identifier == "zh" ? "正在读取…" : "Loading…")
            .font(NativeTypography.inter(size: 13))
            .foregroundStyle(NativePalette.thread.muted.swiftUI)
            .multilineTextAlignment(placement == .surface ? .center : .leading)
            .padding(.vertical, 16)
            .padding(.horizontal, placement == .surface ? 18 : 0)
            .frame(maxWidth: .infinity, maxHeight: placement == .surface ? .infinity : nil,
                   alignment: placement == .surface ? .center : .leading)
            .nativeLayoutLog("reading.placeholder")
            // Reserve the same geometry during the grace period. Inline loading
            // must never claim viewport height or change the reader's scroll extent.
            .opacity(visible ? 1 : 0)
            .accessibilityHidden(!visible)
            .allowsHitTesting(false)
            .task {
                visible = false
                do { try await Task.sleep(for: .milliseconds(180)) }
                catch { return }
                guard !Task.isCancelled else { return }
                visible = true
            }
            .onDisappear { visible = false }
    }
}
