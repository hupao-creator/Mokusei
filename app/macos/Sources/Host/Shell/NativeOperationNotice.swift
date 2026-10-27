import SwiftUI

public struct NativeOperationNotice<Content: View>: View {
    private let error: String?
    private let suppressed: Bool
    private let onScroll: ((CGPoint) -> Void)?
    private let onDismiss: () -> Void
    private let content: Content
    @Environment(\.locale) private var locale
    public init(error: String?, suppressed: Bool = false, onScroll: ((CGPoint) -> Void)? = nil,
                onDismiss: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.error = error; self.suppressed = suppressed; self.onScroll = onScroll
        self.onDismiss = onDismiss; self.content = content()
    }
    public var body: some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            if let error, !error.isEmpty, !suppressed {
                HStack {
                    Text(error).textSelection(.enabled)
                    Spacer()
                    Button(locale.language.languageCode?.identifier == "zh" ? "关闭" : "Dismiss", action: onDismiss)
                }
                .font(.callout).padding(12).background(.regularMaterial)
                .accessibilityIdentifier("operation-notice")
            }
        }
        .onAppear { onScroll?(.zero) }
    }
}
