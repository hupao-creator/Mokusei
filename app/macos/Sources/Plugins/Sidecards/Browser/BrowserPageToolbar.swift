import MokuseiPluginUI
import SwiftUI

/// Navigation chrome shared by Agent Sidecards and read-only Report link cards.
@MainActor
struct BrowserPageToolbar<AnnotationControl: View>: View {
    let session: BrowserWebSession?
    let requestedURL: URL?
    let active: Bool
    let translate: (String) -> String
    let onOpen: (URL) -> Void
    let onClose: (() -> Void)?
    @ViewBuilder var annotationControl: AnnotationControl
    @State private var addressDraft = ""
    @State private var addressError = ""
    @FocusState private var addressFocused: Bool
    private let palette = BrowserChromePalette()
    private var address: String { session?.pendingURL?.absoluteString ?? (session?.url.isEmpty == false ? session!.url : requestedURL?.absoluteString ?? "") }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 2) {
                    tool("ArrowLeft", "后退", disabled: session?.canGoBack != true) { session?.back() }
                    tool("ArrowRight", "前进", disabled: session?.canGoForward != true) { session?.forward() }
                    Rectangle().fill(palette.line).frame(width: 1, height: 16).padding(.horizontal, 3)
                    tool("RotateCw", "刷新", disabled: session?.terminated == true) { session?.reload() }
                }
                .padding(3).frame(height: 36).background(palette.background, in: Capsule())
                .overlay(Capsule().stroke(palette.line, lineWidth: 1))
                ZStack(alignment: .leading) {
                    TextField("", text: $addressDraft)
                        .textFieldStyle(.plain).font(NativeTypography.mono(size: 12))
                        .foregroundStyle(addressFocused ? palette.ink : Color.clear)
                        .focused($addressFocused).padding(.horizontal, 15)
                        .onSubmit { submitAddress() }
                        .nativeOnExitCommand { addressFocused = false; addressError = "" }
                        .onChange(of: addressFocused) { _, focused in
                            if !focused { addressDraft = address; addressError = "" }
                        }
                        .accessibilityLabel(translate("网址"))
                    if !addressFocused {
                        addressDisplay.padding(.horizontal, 15).allowsHitTesting(false)
                    }
                    if session?.loading == true {
                        BrowserProgressRing(color: palette.accent,
                            active: active).allowsHitTesting(false)
                    }
                }
                .frame(height: 36).background(palette.background, in: Capsule())
                .overlay(Capsule().stroke(palette.line, lineWidth: 1))
                .help(address)
                annotationControl
                if let onClose {
                    Button(action: onClose) { NativeIcon(name: "X", size: 16).frame(width: 36, height: 36) }
                        .buttonStyle(BrowserToolStyle(palette: palette)).background(palette.background, in: Circle())
                        .allowsWindowActivationEvents()
                        .overlay(Circle().stroke(palette.line, lineWidth: 1))
                        .help(translate("收起网页")).accessibilityLabel(translate("收起网页"))
                        .accessibilityIdentifier("browser-sidecard-close")
                }
            }
            .padding(10)
            if !addressError.isEmpty {
                Text(translate(addressError)).font(NativeTypography.inter(size: 12))
                    .foregroundStyle(NativeAppKitPalette.thread.danger.swiftUI)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 4)
            }
        }
        .onAppear { addressDraft = address }
        .onChange(of: address) { _, value in if !addressFocused { addressDraft = value } }
        .onChange(of: active) { _, value in if !value { addressFocused = false; addressError = "" } }
    }

    private var addressDisplay: some View {
        let parsed = URLComponents(string: address)
        let local = parsed?.scheme?.lowercased() == "file"
        let host = (parsed?.host ?? address).replacingOccurrences(of: "^www\\.", with: "", options: [.regularExpression, .caseInsensitive]) + (parsed?.port.map { ":\($0)" } ?? "")
        let path = parsed?.percentEncodedPath ?? ""
        let query = parsed?.percentEncodedQuery.map { "?" + $0 } ?? ""
        let hash = parsed?.percentEncodedFragment.map { "#" + $0 } ?? ""
        let suffix = path == "/" && query.isEmpty && hash.isEmpty ? "" : path + query + hash
        return HStack(spacing: 0) {
            Text(local ? "file://" : host).foregroundStyle(palette.strongInk).font(NativeTypography.mono(size: 12, weight: 500)).layoutPriority(1)
            Text(suffix).foregroundStyle(palette.muted).font(NativeTypography.mono(size: 12))
        }.lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).clipped()
    }

    private func submitAddress() {
        guard let target = BrowserURL.address(addressDraft) else { addressError = "请输入有效的 HTTP(S) 网址或本机 HTML 文件路径"; return }
        onOpen(target); addressError = ""; addressFocused = false
    }
    private func tool(_ icon: String, _ label: String, disabled: Bool = false, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { NativeIcon(name: icon, size: 16).frame(width: 28, height: 28) }
            .buttonStyle(BrowserToolStyle(palette: palette, active: active)).disabled(disabled)
            .accessibilityLabel(translate(label)).help(translate(label))
    }
}

struct BrowserToolStyle: ButtonStyle {
    let palette: BrowserChromePalette
    var active = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(palette.muted)
            .contentShape(Circle())
            .background(palette.ink.opacity(active ? 0.12 : configuration.isPressed ? 0.07 : 0), in: Circle())
            .overlay(Circle().stroke(palette.ink.opacity(active ? 0.24 : 0), lineWidth: 1)).opacity(enabled ? 1 : 0.3)
    }
}
struct BrowserRetryStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.padding(.horizontal, 12).padding(.vertical, 6)
            .background(NativeAppKitPalette.thread.surfaceStrong.swiftUI, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(NativeAppKitPalette.thread.line.swiftUI))
    }
}
/// Native chrome follows the system appearance; page rendering never drives
/// host colors, screenshots, or a second animation loop.
struct BrowserChromePalette {
    let background = NativeAppKitPalette.thread.ink.swiftUI.opacity(0.04)
    let ink = NativeAppKitPalette.thread.ink.swiftUI
    let strongInk = NativeAppKitPalette.thread.ink.swiftUI
    let muted = NativeAppKitPalette.thread.muted.swiftUI
    let line = NativeAppKitPalette.thread.lineSoft.swiftUI
    let accent = NativeAppKitPalette.thread.accent.swiftUI
}
