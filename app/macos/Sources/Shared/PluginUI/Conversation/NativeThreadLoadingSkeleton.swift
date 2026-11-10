import SwiftUI

/// Pending-content material shared by the body skeleton and the Author header.
/// Both must read as one loading state; a solid foreground would make the
/// Author placeholder look like settled content.
struct NativeSkeletonLine: View {
    let width: CGFloat
    let height: CGFloat
    var opacity: Double

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(NativePalette.thread.ink.swiftUI.opacity(opacity))
            .frame(width: width, height: height)
    }
}

/// Shared loading skeleton used by scoped row loading and initial admission.
public struct NativeThreadLoadingSkeleton: View {
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @Environment(\.locale) private var locale
    @State private var pulse = false
    private let widths: [CGFloat] = [0.32, 0.96, 0.88, 0.65, 0.4, 0.92, 0.78]
    public init() {}
    public var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 15) {
                ForEach(widths.indices, id: \.self) { index in
                    NativeSkeletonLine(width: geometry.size.width * widths[index],
                                       height: index == 0 ? 15 : 10,
                                       opacity: index == 0 || index == 4 ? 0.12 : 0.07)
                        .padding(.top, index == 1 || index == 4 ? 12 : 0)
                }
            }.opacity(reducedMotion ? 1 : pulse ? 0.55 : 1)
        }
        .frame(height: 240)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(locale.language.languageCode?.identifier == "zh" ? "正在载入正文" : "Loading content")
        .onAppear {
            guard !reducedMotion else { return }
            withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}
