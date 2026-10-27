import MokuseiPluginUI
import SwiftUI

@MainActor
public struct BrowserSidecardPane: View {
    @Bindable var presentation: BrowserSidecardPresentation
    @State private var addressDraft = ""
    @State private var addressError = ""
    @FocusState private var addressFocused: Bool

    private var session: BrowserWebSession? { presentation.session }
    private let palette = BrowserChromePalette()
    private var address: String { session?.pendingURL?.absoluteString ?? (session?.url.isEmpty == false ? session!.url : presentation.requestedURL?.absoluteString ?? "") }
    public var body: some View {
        GeometryReader { geometry in
            let detailsHeight = presentation.detailsExpanded && !presentation.pending.isEmpty ? min(260, geometry.size.height * 0.36) : 0
            VStack(spacing: 0) {
                toolbar
                if !addressError.isEmpty { errorLabel(addressError) }
                if let session, !session.captureError.isEmpty && !session.annotating { errorLabel(session.captureError) }
                ZStack(alignment: .bottom) {
                    if let session {
                        GeometryReader { page in
                            let origin = page.frame(in: .named(presentation.coordinateSpaceID)).origin
                            BrowserViewport(session: session, suppressed: presentation.nativeHidden, coveredBottom: detailsHeight,
                                cardRect: CGRect(x: -origin.x, y: -origin.y, width: geometry.size.width, height: geometry.size.height))
                        }
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .padding(.horizontal, 8)
                    }
                    if let error = session?.error {
                        VStack(spacing: 10) {
                            NativeIcon(name: "CircleAlert", size: 18)
                            Text(presentation.context.translate(error)).foregroundStyle(NativeAppKitPalette.thread.danger.swiftUI).multilineTextAlignment(.center)
                            Button(presentation.context.translate("重试")) { presentation.retry() }
                                .buttonStyle(BrowserRetryStyle())
                        }
                        .font(NativeTypography.inter(size: 12)).padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    if detailsHeight > 0 {
                        annotationDetails.frame(height: detailsHeight).background(NativeAppKitPalette.pair(0xffffff, 0x000000).swiftUI)
                            .shadow(color: .black.opacity(0.13), radius: 18, y: -3)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if !presentation.pending.isEmpty { annotationBar }
                else { Color.clear.frame(height: 8) }
            }
            .foregroundStyle(palette.ink)
            .coordinateSpace(name: presentation.coordinateSpaceID)
        }
        .onAppear { addressDraft = address }
        .onChange(of: address) { _, value in if !addressFocused { addressDraft = value } }
        .onChange(of: presentation.context.expanded) { _, expanded in
            if !expanded { addressFocused = false; addressError = "" }
        }
    }

    private var toolbar: some View {
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
                    .accessibilityLabel(presentation.context.translate("网址"))
                if !addressFocused {
                    addressDisplay.padding(.horizontal, 15).allowsHitTesting(false)
                }
                if session?.loading == true {
                    BrowserProgressRing(color: palette.accent,
                        active: presentation.context.expanded && !presentation.released).allowsHitTesting(false)
                }
            }
            .frame(height: 36).background(palette.background, in: Capsule())
            .overlay(Capsule().stroke(palette.line, lineWidth: 1))
            .help(address)
            tool("MessageSquarePlus", "批注网页", disabled: presentation.annotationDisabled || session?.loading == true || session?.ready != true,
                 active: session?.annotating == true) { presentation.annotate() }
            Button { presentation.context.close() } label: { NativeIcon(name: "X", size: 16).frame(width: 36, height: 36) }
                .buttonStyle(BrowserToolStyle(palette: palette)).background(palette.background, in: Circle())
                .allowsWindowActivationEvents()
                .overlay(Circle().stroke(palette.line, lineWidth: 1))
                .help(presentation.context.translate("收起网页")).accessibilityLabel(presentation.context.translate("收起网页"))
                .accessibilityIdentifier("browser-sidecard-close")
        }
        .padding(10)
    }

    private var addressDisplay: some View {
        let parsed = URLComponents(string: address)
        let host = (parsed?.host ?? address).replacingOccurrences(of: "^www\\.", with: "", options: [.regularExpression, .caseInsensitive]) + (parsed?.port.map { ":\($0)" } ?? "")
        let path = parsed?.percentEncodedPath ?? ""
        let query = parsed?.percentEncodedQuery.map { "?" + $0 } ?? ""
        let hash = parsed?.percentEncodedFragment.map { "#" + $0 } ?? ""
        let suffix = path == "/" && query.isEmpty && hash.isEmpty ? "" : path + query + hash
        return HStack(spacing: 0) {
            Text(host).foregroundStyle(palette.strongInk).font(NativeTypography.mono(size: 12, weight: 500)).layoutPriority(1)
            Text(suffix).foregroundStyle(palette.muted).font(NativeTypography.mono(size: 12))
        }.lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).clipped()
    }

    private func submitAddress() {
        guard let target = BrowserURL.address(addressDraft) else { addressError = "请输入有效的 HTTP 或 HTTPS 网址"; return }
        presentation.open(target); addressError = ""; addressFocused = false
    }
    private func tool(_ icon: String, _ label: String, disabled: Bool = false, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { NativeIcon(name: icon, size: 16).frame(width: 28, height: 28) }
            .buttonStyle(BrowserToolStyle(palette: palette, active: active)).disabled(disabled)
            .accessibilityLabel(presentation.context.translate(label)).help(presentation.context.translate(label))
    }
    private func errorLabel(_ error: String) -> some View {
        Text(error).font(NativeTypography.inter(size: 12)).foregroundStyle(NativeAppKitPalette.thread.danger.swiftUI)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 4)
    }

    private var annotationBar: some View {
        VStack(spacing: 0) {
            if !presentation.sendError.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(presentation.sendError).foregroundStyle(NativeAppKitPalette.thread.danger.swiftUI).frame(maxWidth: .infinity, alignment: .leading)
                    Button("仅发送文字") { presentation.send(textOnly: true) }.buttonStyle(.plain).underline().disabled(!presentation.canSend)
                }.font(NativeTypography.inter(size: 11)).padding(.horizontal, 12).padding(.top, 8)
            }
            HStack(spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) { presentation.detailsExpanded.toggle() }
                    presentation.selectedAnnotationID = nil; presentation.preview = false
                } label: {
                    HStack(spacing: 5) {
                        Text("\(presentation.pending.count) 条批注")
                        NativeIcon(name: "ChevronDown", size: 12).rotationEffect(.degrees(presentation.detailsExpanded ? 180 : 0))
                    }
                }.buttonStyle(.plain).foregroundStyle(NativeAppKitPalette.thread.muted.swiftUI)
                    .accessibilityLabel("查看 \(presentation.pending.count) 条待发送批注")
                TextField("补充说明…", text: $presentation.supplementalText).textFieldStyle(.plain)
                    .disabled(presentation.sending).onSubmit { presentation.send() }.accessibilityLabel("补充说明")
                Button { presentation.send() } label: { NativeIcon(name: "ArrowUp", size: 15).frame(width: 28, height: 28) }
                    .buttonStyle(.plain).background(NativeAppKitPalette.thread.ink.swiftUI, in: Circle()).foregroundStyle(NativeAppKitPalette.thread.surfaceStrong.swiftUI)
                    .disabled(!presentation.canSend).opacity(presentation.canSend ? 1 : 0.35).accessibilityLabel(presentation.sending ? "发送中" : "发送批注")
            }
            .font(NativeTypography.inter(size: 12)).padding(.horizontal, 12).frame(height: 50)
        }
        .background(NativeAppKitPalette.pair(0xffffff, 0x000000).swiftUI)
        .shadow(color: .black.opacity(presentation.detailsExpanded ? 0 : 0.12), radius: 18, y: -3)
    }

    private var annotationDetails: some View {
        ScrollView {
            if let id = presentation.selectedAnnotationID, let index = presentation.pending.firstIndex(where: { $0.id == id }) {
                VStack(spacing: 4) {
                    HStack {
                        Button { presentation.selectedAnnotationID = nil; presentation.preview = false } label: {
                            HStack(spacing: 5) { NativeIcon(name: "ChevronLeft", size: 14); Text("批注 \(index + 1)") }
                        }.accessibilityLabel("返回批注列表")
                        Spacer()
                        Button { presentation.preview.toggle() } label: { NativeIcon(name: "Image", size: 14).frame(width: 25, height: 25) }.accessibilityLabel("预览批注截图")
                        Button { presentation.remove(id) } label: { NativeIcon(name: "Trash2", size: 14).frame(width: 25, height: 25) }.disabled(presentation.sending).accessibilityLabel("删除此批注")
                    }
                    TextEditor(text: Binding(get: { presentation.pending.first(where: { $0.id == id })?.comment ?? "" }, set: { text in
                        if let i = presentation.pending.firstIndex(where: { $0.id == id }) { presentation.pending[i].comment = BrowserText.limit(text, utf16: 10_000) }
                    })).font(NativeTypography.inter(size: 12)).scrollContentBackground(.hidden).frame(height: 64)
                        .disabled(presentation.sending).accessibilityLabel("批注 \(index + 1) 评论")
                    if presentation.preview {
                        BrowserAnnotationPreview(data: presentation.pending[index].png).id(id)
                    }
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(presentation.pending.enumerated()), id: \.element.id) { index, annotation in
                        HStack(spacing: 6) {
                            Button { presentation.selectedAnnotationID = annotation.id; presentation.preview = false } label: {
                                HStack(spacing: 9) {
                                    Text("\(index + 1)").font(NativeTypography.inter(size: 10)).foregroundStyle(NativeAppKitPalette.thread.faint.swiftUI).frame(width: 15)
                                    Text(annotation.comment.isEmpty ? "填写批注…" : annotation.comment).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                }.frame(minHeight: 33)
                            }.frame(maxWidth: .infinity)
                            Button { presentation.remove(annotation.id) } label: { NativeIcon(name: "Trash2", size: 14).frame(width: 28, height: 28) }
                                .disabled(presentation.sending).accessibilityLabel("删除批注 \(index + 1)")
                        }
                        if index + 1 < presentation.pending.count { Rectangle().fill(NativeAppKitPalette.thread.lineSoft.swiftUI).frame(height: 1) }
                    }
                }
            }
        }
        .buttonStyle(.plain).font(NativeTypography.inter(size: 12)).foregroundStyle(NativeAppKitPalette.thread.ink.swiftUI)
        .padding(.horizontal, 12).padding(.top, 8)
    }
}

private struct BrowserToolStyle: ButtonStyle {
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
private struct BrowserRetryStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.padding(.horizontal, 12).padding(.vertical, 6)
            .background(NativeAppKitPalette.thread.surfaceStrong.swiftUI, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(NativeAppKitPalette.thread.line.swiftUI))
    }
}
/// Native chrome follows the system appearance; page rendering never drives
/// host colors, screenshots, or a second animation loop.
private struct BrowserChromePalette {
    let background = NativeAppKitPalette.thread.ink.swiftUI.opacity(0.04)
    let ink = NativeAppKitPalette.thread.ink.swiftUI
    let strongInk = NativeAppKitPalette.thread.ink.swiftUI
    let muted = NativeAppKitPalette.thread.muted.swiftUI
    let line = NativeAppKitPalette.thread.lineSoft.swiftUI
    let accent = NativeAppKitPalette.thread.accent.swiftUI
}

/// The mounted annotation owns one image, including a failed decode. Comment
/// edits and chrome updates cannot reconstruct the native image from unchanged PNG data.
private struct BrowserAnnotationPreview: View {
    let data: Data
    @State private var cache = BrowserPreviewImageCache()
    var body: some View {
        if let image = cache.image(data) {
            image.swiftUI.resizable().scaledToFit().frame(maxHeight: 150)
                .clipShape(RoundedRectangle(cornerRadius: 5)).accessibilityLabel("批注原始截图")
        }
    }
}
@MainActor private final class BrowserPreviewImageCache {
    private var data: Data?
    private var value: NativePlatformImage?
    func image(_ data: Data) -> NativePlatformImage? {
        if self.data == data { return value }
        self.data = data; value = NativePlatformImage(data: data)
        return value
    }
}
