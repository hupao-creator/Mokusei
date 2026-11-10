import MokuseiPluginUI
import SwiftUI

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
