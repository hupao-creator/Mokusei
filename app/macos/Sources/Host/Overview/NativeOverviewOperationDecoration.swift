import MokuseiPluginUI
import SwiftUI

struct NativeOverviewOperationDecoration: View {
    let operation: NativeOverviewMokuOperation?
    let visible: Bool
    @State private var pulse = false
    var body: some View {
        Group {
            if visible, let operation {
                RoundedRectangle(cornerRadius: 22)
                    .trim(from: 0.46, to: 0.51)
                    .stroke(color(operation.phase).opacity(opacity(operation.phase)), lineWidth: 1)
                    .task(id: operation) {
                        var reset = Transaction(); reset.disablesAnimations = true
                        withTransaction(reset) { pulse = false }
                        await Task.yield()
                        guard !Task.isCancelled, operation.phase != .failed else { return }
                        withAnimation(operation.phase == .running ? .easeInOut(duration: 0.9).repeatForever() : .easeOut(duration: 0.6)) { pulse = true }
                    }
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
    private func opacity(_ phase: NativeOverviewMokuOperation.Phase) -> Double {
        switch phase {
        case .running: pulse ? 0.5 : 0.2
        case .completed: pulse ? 0 : 0.6
        case .failed: 0.34
        }
    }
    private func color(_ phase: NativeOverviewMokuOperation.Phase) -> Color {
        switch phase {
        case .running: NativePalette.overview.accent.swiftUI
        case .completed: NativePalette.overview.success.swiftUI
        case .failed: NativePalette.overview.danger.swiftUI
        }
    }
}

struct NativeOverviewRefreshDecoration: View {
    let operation: NativeOverviewMokuOperation?
    let visible: Bool
    @Environment(\.locale) private var locale
    var body: some View {
        if visible, operation?.kind == .list, operation?.phase == .running {
            ProgressView().controlSize(.small).padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .accessibilityLabel(locale.language.languageCode?.identifier == "zh" ? "正在刷新" : "Refreshing")
        }
    }
}
