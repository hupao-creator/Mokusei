import AppKit
import SwiftUI

/// The complete inline row copy, including its label and custom description
/// hint. The tooltip is anchored to the copy's lower-left edge, not the icon.
/// Raise the containing row's zIndex while `onVisibilityChange` reports true so
/// the overlay stays above following rows without changing their layout.
public struct NativeSettingsDescriptionHint: View {
    public let label: String
    public let description: String
    private let onVisibilityChange: ((Bool) -> Void)?
    private let onActivateLabel: (() -> Void)?
    @Environment(\.locale) private var locale
    @Environment(\.nativeSettingsLocalAgentDetail) private var localAgentDetail
    @Environment(\.nativeSettingsFormPage) private var settingsFormPage
    @FocusState private var hintFocused: Bool
    @State private var keyboardFocused = false
    @State private var iconHovered = false
    @State private var tooltipHovered = false
    @State private var presented = false
    @State private var retained = false
    @State private var touchPresented = false
    @State private var fadeCompletion: Task<Void, Never>?

    public init(label: String, description: String, onVisibilityChange: ((Bool) -> Void)? = nil,
                onActivateLabel: (() -> Void)? = nil) {
        self.label = label; self.description = description; self.onVisibilityChange = onVisibilityChange
        self.onActivateLabel = onActivateLabel
    }

    public var body: some View {
        if settingsFormPage {
            HStack(spacing: 6) {
                copyText(label, size: localAgentDetail ? 11 : 14, weight: localAgentDetail ? 400 : 500,
                         lineHeight: localAgentDetail ? 16.5 : 21)
                    .contentShape(Rectangle()).onTapGesture { onActivateLabel?() }
                Button { presented.toggle() } label: { Image(systemName: "questionmark.circle") }
                    .buttonStyle(.borderless)
                    .help(description)
                    .accessibilityLabel(NativePluginLocalization.localize("说明", locale: locale) + ": " + label)
                    .accessibilityHint(description)
                    .popover(isPresented: $presented) {
                        Text(description).font(.callout).textSelection(.enabled)
                            .padding().frame(idealWidth: 280, maxWidth: 320)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                Spacer(minLength: 0)
            }
            .onChange(of: presented) { _, visible in onVisibilityChange?(visible) }
            .onDisappear { presented = false; onVisibilityChange?(false) }
        } else {
            customBody
        }
    }

    private var customBody: some View {
        HStack(alignment: .center, spacing: 6) {
            copyText(label, size: localAgentDetail ? 11 : settingsFormPage ? 14 : 13, weight: localAgentDetail ? 400 : 500,
                     lineHeight: localAgentDetail ? 16.5 : settingsFormPage ? 21 : 19.5)
                .foregroundStyle((localAgentDetail ? NativePlatformPalette.settings.muted : NativePlatformPalette.settings.text).swiftUI)
                .contentShape(Rectangle())
                .onTapGesture { onActivateLabel?() }
            hintButton
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topLeading) {
            GeometryReader { geometry in
                tooltip
                    .frame(width: min(320, max(0, geometry.size.width)), alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .offset(y: geometry.size.height + 7)
                    .opacity(presented ? 1 : 0)
                    .allowsHitTesting(retained)
                    .accessibilityHidden(!retained)
                    .animation(.easeOut(duration: 0.12), value: presented)
                    .onHover { hovering in
                        tooltipHovered = hovering
                        updatePresentation()
                    }
            }
        }
        .onChange(of: hintFocused) { _, focused in
            keyboardFocused = focused && !Self.isPointerEvent
            updatePresentation()
        }
        .onDisappear {
            fadeCompletion?.cancel()
            fadeCompletion = nil
            presented = false; retained = false
            touchPresented = false
            onVisibilityChange?(false)
        }
    }

    private var hintButton: some View {
        Button {
            // Pointer activation already reveals the hover hint. Keyboard and
            // assistive activation reveal the same description.
            keyboardFocused = !Self.isPointerEvent
            if keyboardFocused { hintFocused = true }
            updatePresentation()
        } label: {
            Text("?")
                .font(NativeTypography.settings(size: 9, weight: 600))
                .foregroundStyle(NativePlatformPalette.settings.muted.swiftUI)
                .frame(width: 14, height: 14)
                .overlay(Circle().strokeBorder(NativePlatformPalette.settings.line.swiftUI, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .focused($hintFocused)
        .overlay {
            if keyboardFocused {
                // The 14-point circle plus a 3-point offset and 2-point outline.
                Circle().strokeBorder(NativePlatformPalette.settings.accent.swiftUI, lineWidth: 2)
                    .frame(width: 24, height: 24).allowsHitTesting(false)
            }
        }
        .offset(y: -1)
        .onHover { hovering in
            iconHovered = hovering
            updatePresentation()
        }
        .accessibilityLabel(NativePluginLocalization.localize("说明", locale: locale))
        .accessibilityValue(label)
        .accessibilityHint(description)
    }

    private var tooltip: some View {
        copyText(description, size: 12, weight: 400, lineHeight: 18.6)
            .foregroundStyle(NativePlatformPalette.settings.muted.swiftUI)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8).padding(.horizontal, 10)
            .background(NativePlatformPalette.settings.hintSurface.swiftUI, in: RoundedRectangle(cornerRadius: 8))
            .background { NativeSettingsHintShadows() }
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(NativePlatformPalette.settings.hintBorder.swiftUI, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(description)
    }

    private func copyText(_ text: String, size: CGFloat, weight: CGFloat, lineHeight: CGFloat) -> some View {
        let font = NativeTypography.settingsPlatformFont(size: size, weight: weight)
        let leading = max(0, lineHeight - nativeSettingsLineHeight(size: size, weight: weight))
        return Text(text).font(Font(font))
            .lineSpacing(leading)
            .padding(.vertical, leading / 2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func updatePresentation() {
        let visible = iconHovered || tooltipHovered || keyboardFocused || touchPresented
        guard visible != presented else { return }
        fadeCompletion?.cancel()
        fadeCompletion = nil
        presented = visible
        if visible {
            retained = true
            onVisibilityChange?(true)
        } else {
            // CSS opacity fades immediately while visibility remains visible
            // until that same 120ms transition ends. Keep its hit region and
            // stacking level during the fade so the pointer can cross the gap.
            fadeCompletion = Task { @MainActor in
                do { try await Task.sleep(for: .milliseconds(120)) }
                catch { return }
                guard !presented else { return }
                retained = false
                onVisibilityChange?(false)
                fadeCompletion = nil
            }
        }
    }

    private static var isPointerEvent: Bool { NativePlatformInput.isPointerEvent }
}

/// CSS shadow blur is twice its Gaussian standard deviation; SwiftUI's filter
/// radius is the deviation itself. Each shadow uses the same original shape,
/// rather than casting another shadow from the previous shadow's pixels.
private struct NativeSettingsHintShadows: View {
    private let inset: CGFloat = 56

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, _ in
                // CSS lists the topmost shadow first, so paint in reverse order.
                for shadow in [(offset: CGFloat(2), sigma: CGFloat(3), alpha: 15.0 / 255),
                               (offset: CGFloat(8), sigma: CGFloat(11), alpha: 31.0 / 255)] {
                    let rect = CGRect(x: inset, y: inset + shadow.offset,
                                      width: geometry.size.width, height: geometry.size.height)
                    context.drawLayer { layer in
                        layer.addFilter(.blur(radius: shadow.sigma))
                        layer.fill(Path(roundedRect: rect, cornerRadius: 8),
                                   with: .color(NativePlatformPalette.color(0x26384e, alpha: shadow.alpha).swiftUI))
                    }
                }
            }
            .frame(width: geometry.size.width + inset * 2, height: geometry.size.height + inset * 2)
            .offset(x: -inset, y: -inset)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
