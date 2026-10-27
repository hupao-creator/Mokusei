import SwiftUI
import AppKit

/// The few input queries shared controls need, kept at the native boundary.
@MainActor public enum NativePlatformInput {
    public static var isComposingText: Bool {
        return (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() == true
    }

    public static var isPointerEvent: Bool {
        guard let event = NSApp.currentEvent else { return false }
        return [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                .otherMouseDown, .otherMouseUp].contains(event.type)
    }

    public static func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

}

public extension View {
    /// A menu uses the shared label without adding platform-specific button chrome.
    @ViewBuilder
    func nativeBorderlessMenu() -> some View {
        menuStyle(.borderlessButton)
    }

    /// Escape keeps the existing dismiss action with either native input system.
    @ViewBuilder
    func nativeOnExitCommand(perform action: (() -> Void)?) -> some View {
        onExitCommand(perform: action)
    }
}
