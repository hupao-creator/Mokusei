import SwiftUI

public extension EnvironmentValues {
    /// Use the Agent reader's loading presentation in place of compact indicators.
    @Entry var nativeThreadUsesLoadingSkeleton = false
}

/// Presentation only: the owner still decides whether content is loading.
public struct NativeReadingPlaceholder: View {
    public enum Placement { case surface, inline }

    private let placement: Placement
    @Environment(\.nativeThreadUsesLoadingSkeleton) private var usesLoadingSkeleton
    @Environment(\.nativeThreadIdentityVisit) private var identityVisit
    @Environment(\.locale) private var locale
    @State private var visible = false

    public init(placement: Placement = .surface) {
        self.placement = placement
    }

    public var body: some View {
        Group {
            if usesLoadingSkeleton && placement == .surface && identityVisit != nil {
                NativeThreadOpeningContent(showsLoading: visible)
            } else if usesLoadingSkeleton {
                NativeThreadLoadingSkeleton().frame(maxWidth: NativeGeometry.readingWidth).padding(.horizontal, placement == .surface ? 32 : 0)
            } else {
                Text(locale.language.languageCode?.identifier == "zh" ? "正在读取…" : "Loading…")
            .font(NativeTypography.inter(size: 13))
            .foregroundStyle(NativePalette.thread.muted.swiftUI)
            .multilineTextAlignment(placement == .surface ? .center : .leading)
            .padding(.vertical, 16)
            .padding(.horizontal, placement == .surface ? 18 : 0)
            .frame(maxWidth: .infinity, maxHeight: placement == .surface ? .infinity : nil,
                   alignment: placement == .surface ? .center : .leading)
            }
        }
            .nativeThreadRailFallback()
            .transformPreference(NativeReadingContentStatusKey.self) { status in
                // A loaded sibling (for example a system error) cannot admit
                // auxiliary input while this document is still being acquired.
                // Readiness starts waiting before the visual grace period ends.
                status.pending = status.pending || usesLoadingSkeleton
            }
            .nativeLayoutLog("reading.placeholder")
            // Reserve the same geometry during the grace period. Inline loading
            // must never claim viewport height or change the reader's scroll extent.
            .opacity(visible || (usesLoadingSkeleton && placement == .surface && identityVisit != nil) ? 1 : 0)
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


/// Keep each Harness's compact spinner outside the main Agent reader.
public struct NativeThreadLoadingIndicator: View {
    @Environment(\.nativeThreadUsesLoadingSkeleton) private var usesLoadingSkeleton
    private let alignedLeading: Bool
    public init(alignedLeading: Bool = false) { self.alignedLeading = alignedLeading }
    public var body: some View {
        if usesLoadingSkeleton { NativeReadingPlaceholder(placement: .inline) }
        else {
            ProgressView().controlSize(.small)
                .frame(maxWidth: alignedLeading ? .infinity : nil, alignment: .leading)
                .padding(.vertical, 16)
        }
    }
}
