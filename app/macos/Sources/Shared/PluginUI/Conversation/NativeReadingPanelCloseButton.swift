import SwiftUI

public extension EnvironmentValues {
    @Entry var nativeReadingPanelClosing = false
}

/// Panel chrome only: callers retain their own route or Sidecard close action.
public struct NativeReadingPanelCloseButton: View {
    private let label: String
    private let onClose: () -> Void
    private let overlaysContent: Bool
    @Environment(\.isEnabled) private var enabled
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @Environment(\.nativeReadingPanelClosing) private var closing
    @Environment(\.nativeThreadPreparing) private var preparing
    @State private var appeared = false

    public init(label: String, overlaysContent: Bool = false, onClose: @escaping () -> Void) {
        self.label = label; self.onClose = onClose; self.overlaysContent = overlaysContent
    }

    public var body: some View {
        Button(action: onClose) {
            NativeIcon(name: "X", size: 17)
                .frame(width: 32, height: 32)
                .contentShape(Circle())
        }
        .buttonStyle(ReadingPanelCloseStyle())
        .background {
            if overlaysContent {
                Circle().fill(NativePalette.thread.canvas.swiftUI).allowsHitTesting(false)
            }
        }
        .nativeLayoutLog("reading.close.target")
        // Clicking Close must not acquire editing focus and flash the keyboard ring.
        .focusable(interactions: .activate)
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
        .opacity(appeared && !closing && !preparing ? 1 : 0)
        .animation(reducedMotion ? nil : .easeOut(duration: 0.16), value: preparing)
        .animation(reducedMotion ? nil : .easeOut(duration: closing ? 0.08 : 0.16), value: closing)
        .onAppear { withAnimation(reducedMotion ? nil : .easeOut(duration: 0.16)) { appeared = true } }
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
    /// clear the fixed control vertically or horizontally, even after scrolling
    /// or resizing. For overlay placement, keep the control legible over authored
    /// content with an opaque canvas backing; the host still owns edge clipping.
    func nativeReadingPanelClose(label: String, identifier: String = "reading-panel-close",
                                overlaysContent: Bool = false, onClose: @escaping () -> Void) -> some View {
        overlay(alignment: .topLeading) {
            NativeReadingPanelCloseButton(label: label, overlaysContent: overlaysContent, onClose: onClose)
                .accessibilityIdentifier(identifier).padding(14)
        }
    }
}

/// An embedded reader offers Back to its owning workspace without replacing
/// the workspace's Close route. Identity changes retire the previous action.
public struct NativeReadingAuxiliaryBackAction: Equatable, Sendable {
    public let id: String
    public let perform: @MainActor @Sendable () -> Void
    public init(id: String, perform: @escaping @MainActor @Sendable () -> Void) { self.id = id; self.perform = perform }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}
public struct NativeReadingAuxiliaryBackKey: PreferenceKey {
    public static let defaultValue: NativeReadingAuxiliaryBackAction? = nil
    public static func reduce(value: inout NativeReadingAuxiliaryBackAction?, nextValue: () -> NativeReadingAuxiliaryBackAction?) {
        value = nextValue() ?? value
    }
}
