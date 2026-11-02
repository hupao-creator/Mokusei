import MokuseiPluginUI
import SwiftUI

extension EnvironmentValues {
    @Entry var nativeApplicationReadingPanel = false
}

struct NativeReadingPanelCloseButton: View {
    let label: String
    let onClose: () -> Void

    var body: some View {
        Button(action: onClose) {
            NativeIcon(name: "X", size: 17).frame(width: 32, height: 32)
                .background(.quaternary.opacity(0.5), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain).padding(14)
        .help(label).accessibilityLabel(label)
    }
}

struct NativeApplicationReadingPanel: ViewModifier {
    let enabled: Bool
    let identifier: String
    let onClose: () -> Void
    @Environment(\.locale) private var locale

    func body(content: Content) -> some View {
        if enabled {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(NativePalette.thread.canvas.swiftUI)
                .background(NativeReadingPanelFrame(identifier: identifier))
                .clipShape(RoundedRectangle(cornerRadius: 22))
                .overlay(RoundedRectangle(cornerRadius: 22).stroke(NativePalette.thread.line.swiftUI.opacity(0.6)))
                .overlay(alignment: .topTrailing) {
                    NativeReadingPanelCloseButton(label: locale.language.languageCode?.identifier == "zh" ? "关闭面板" : "Close panel",
                        onClose: onClose)
                }
                .accessibilityIdentifier(identifier)
                // Match the Agent panel's layout seat for its external toolbar.
                .padding(.trailing, 76)
        } else { content }
    }
}
