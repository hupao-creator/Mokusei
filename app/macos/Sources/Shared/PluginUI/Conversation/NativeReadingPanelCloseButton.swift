import SwiftUI

/// Panel chrome only: callers retain their own route or Sidecard close action.
public struct NativeReadingPanelCloseButton: View {
    private let label: String
    private let onClose: () -> Void
    @Environment(\.isEnabled) private var enabled
    @FocusState private var focused: Bool

    public init(label: String, onClose: @escaping () -> Void) {
        self.label = label; self.onClose = onClose
    }

    public var body: some View {
        Button(action: onClose) {
            NativeIcon(name: "X", size: 17)
                .frame(width: 32, height: 32)
                .contentShape(Circle())
        }
        .buttonStyle(ReadingPanelCloseStyle())
        .nativeLayoutLog("reading.close.target")
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.space, .return], phases: .down) { _ in
            guard focused && enabled else { return .ignored }
            onClose()
            return .handled
        }
        .overlay {
            Circle().stroke(NativePalette.thread.accent.swiftUI, lineWidth: focused ? 2 : 0)
                .padding(-3).allowsHitTesting(false)
        }
        .help(label).accessibilityLabel(label)
    }
}

private struct ReadingPanelCloseStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ReadingPanelCloseBody(configuration: configuration)
    }
}

private struct ReadingPanelCloseBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hovering = false

    var body: some View {
        configuration.label
            .foregroundStyle(hovering && enabled ? NativePalette.thread.ink.swiftUI : NativePalette.thread.muted.swiftUI)
            .background(NativePalette.thread.ink.swiftUI.opacity(
                enabled && configuration.isPressed ? 0.12 : enabled && hovering ? 0.08 : 0.04), in: Circle())
            .overlay {
                Circle().stroke(NativePalette.thread.muted.swiftUI.opacity(contrast == .increased ? 0.6 : 0), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .opacity(enabled ? 1 : 0.4)
            .onHover { hovering = $0 }
    }
}

public extension View {
    /// Use with `nativeReadingPanelViewport()` so content and native scrollers
    /// stay below the fixed control, including after scrolling or resizing.
    func nativeReadingPanelClose(label: String, identifier: String = "reading-panel-close",
                                onClose: @escaping () -> Void) -> some View {
        overlay(alignment: .topLeading) {
            NativeReadingPanelCloseButton(label: label, onClose: onClose)
                .accessibilityIdentifier(identifier).padding(14)
        }
    }
}
