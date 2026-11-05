import MokuseiPluginUI
import SwiftUI

@MainActor
public struct BrowserSidecardPane: View {
    @Bindable var presentation: BrowserSidecardPresentation

    private var session: BrowserWebSession? { presentation.session }
    private let palette = BrowserChromePalette()
    public var body: some View {
        GeometryReader { geometry in
            let detailsHeight = presentation.detailsExpanded && !presentation.pending.isEmpty ? min(260, geometry.size.height * 0.36) : 0
            VStack(spacing: 0) {
                BrowserPageToolbar(session: session, requestedURL: presentation.requestedURL,
                    active: presentation.context.expanded && !presentation.released,
                    translate: presentation.context.translate, onOpen: presentation.open,
                    onClose: nil) {
                    Button { presentation.annotate() } label: {
                        NativeIcon(name: "MessageSquarePlus", size: 16).frame(width: 28, height: 28)
                    }
                    .buttonStyle(BrowserToolStyle(palette: palette, active: session?.annotating == true))
                    .disabled(presentation.annotationDisabled || session?.loading == true || session?.ready != true)
                    .help(presentation.context.translate("批注网页"))
                    .accessibilityLabel(presentation.context.translate("批注网页"))
                }
                if let notice = session?.notice { errorLabel(notice) }
                if let session, !session.captureError.isEmpty && !session.annotating { errorLabel(session.captureError) }
                ZStack(alignment: .bottom) {
                    if let session {
                        BrowserViewport(session: session, suppressed: presentation.nativeHidden, coveredBottom: detailsHeight)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .padding(.horizontal, 8)
                    }
                    if let error = session?.error {
                        VStack(spacing: 10) {
                            NativeIcon(name: "CircleAlert", size: 18)
                            Text(session?.localized(error) ?? presentation.context.translate(error)).foregroundStyle(NativeAppKitPalette.thread.danger.swiftUI).multilineTextAlignment(.center)
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
                if !presentation.pending.isEmpty || !presentation.supplementalText.isEmpty { annotationBar }
                else { Color.clear.frame(height: 8) }
            }
            .foregroundStyle(palette.ink)
        }
    }

    private func errorLabel(_ error: String) -> some View {
        Text(session?.localized(error) ?? presentation.context.translate(error)).font(NativeTypography.inter(size: 12)).foregroundStyle(NativeAppKitPalette.thread.danger.swiftUI)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 4)
    }

    private func localized(_ source: String, value: Int, placeholder: String = "count") -> String {
        presentation.context.translate(source).replacingOccurrences(of: "{\(placeholder)}", with: String(value))
    }

    private var annotationBar: some View {
        VStack(spacing: 0) {
            if !presentation.sendError.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(presentation.context.translate(presentation.sendError)).foregroundStyle(NativeAppKitPalette.thread.danger.swiftUI).frame(maxWidth: .infinity, alignment: .leading)
                    Button(presentation.context.translate("仅发送文字")) { presentation.send(textOnly: true) }.buttonStyle(.plain).underline().disabled(!presentation.canSend)
                }.font(NativeTypography.inter(size: 11)).padding(.horizontal, 12).padding(.top, 8)
            }
            HStack(spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) { presentation.detailsExpanded.toggle() }
                    presentation.selectedAnnotationID = nil; presentation.preview = false
                } label: {
                    HStack(spacing: 5) {
                        Text(localized("{count} 条批注", value: presentation.pending.count))
                        NativeIcon(name: "ChevronDown", size: 12).rotationEffect(.degrees(presentation.detailsExpanded ? 180 : 0))
                    }
                }.buttonStyle(.plain).foregroundStyle(NativeAppKitPalette.thread.muted.swiftUI)
                    .disabled(presentation.pending.isEmpty)
                    .accessibilityLabel(localized("查看 {count} 条待发送批注", value: presentation.pending.count))
                TextField(presentation.context.translate("补充说明…"), text: $presentation.supplementalText).textFieldStyle(.plain)
                    .disabled(presentation.sending).onSubmit { presentation.send() }.accessibilityLabel(presentation.context.translate("补充说明"))
                Button { presentation.send() } label: { NativeIcon(name: "ArrowUp", size: 15).frame(width: 28, height: 28) }
                    .buttonStyle(.plain).background(NativeAppKitPalette.thread.ink.swiftUI, in: Circle()).foregroundStyle(NativeAppKitPalette.thread.surfaceStrong.swiftUI)
                    .disabled(!presentation.canSend).opacity(presentation.canSend ? 1 : 0.35).accessibilityLabel(presentation.context.translate(presentation.sending ? "发送中" : "发送批注"))
            }
            .font(NativeTypography.inter(size: 12)).padding(.horizontal, 12).frame(height: 50)
        }
        .background(NativeAppKitPalette.pair(0xffffff, 0x000000).swiftUI)
        .shadow(color: .black.opacity(presentation.detailsExpanded ? 0 : 0.12), radius: 18, y: -3)
    }

    private var annotationDetails: some View {
        NativeScrollView {
            if let id = presentation.selectedAnnotationID, let index = presentation.pending.firstIndex(where: { $0.id == id }) {
                VStack(spacing: 4) {
                    HStack {
                        Button { presentation.selectedAnnotationID = nil; presentation.preview = false } label: {
                            HStack(spacing: 5) { NativeIcon(name: "ChevronLeft", size: 14); Text(localized("批注 {index}", value: index + 1, placeholder: "index")) }
                        }.accessibilityLabel(presentation.context.translate("返回批注列表"))
                        Spacer()
                        Button { presentation.preview.toggle() } label: { NativeIcon(name: "Image", size: 14).frame(width: 25, height: 25) }.accessibilityLabel(presentation.context.translate("预览批注截图"))
                        Button { presentation.remove(id) } label: { NativeIcon(name: "Trash2", size: 14).frame(width: 25, height: 25) }.disabled(presentation.sending).accessibilityLabel(presentation.context.translate("删除此批注"))
                    }
                    TextEditor(text: Binding(get: { presentation.pending.first(where: { $0.id == id })?.comment ?? "" }, set: { text in
                        if let i = presentation.pending.firstIndex(where: { $0.id == id }) { presentation.pending[i].comment = BrowserText.limit(text, utf16: 10_000) }
                    })).nativeControlScrollbars().font(NativeTypography.inter(size: 12)).scrollContentBackground(.hidden).frame(height: 64)
                        .disabled(presentation.sending).accessibilityLabel(localized("批注 {index} 评论", value: index + 1, placeholder: "index"))
                    if presentation.preview {
                        BrowserAnnotationPreview(data: presentation.pending[index].png, label: presentation.context.translate("批注原始截图")).id(id)
                    }
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(presentation.pending.enumerated()), id: \.element.id) { index, annotation in
                        HStack(spacing: 6) {
                            Button { presentation.selectedAnnotationID = annotation.id; presentation.preview = false } label: {
                                HStack(spacing: 9) {
                                    Text("\(index + 1)").font(NativeTypography.inter(size: 10)).foregroundStyle(NativeAppKitPalette.thread.faint.swiftUI).frame(width: 15)
                                    Text(annotation.comment.isEmpty ? presentation.context.translate("填写批注…") : annotation.comment).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                }.frame(minHeight: 33)
                            }.frame(maxWidth: .infinity)
                            Button { presentation.remove(annotation.id) } label: { NativeIcon(name: "Trash2", size: 14).frame(width: 28, height: 28) }
                                .disabled(presentation.sending).accessibilityLabel(localized("删除批注 {index}", value: index + 1, placeholder: "index"))
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

/// The mounted annotation owns one image, including a failed decode. Comment
/// edits and chrome updates cannot reconstruct the native image from unchanged PNG data.
private struct BrowserAnnotationPreview: View {
    let data: Data
    let label: String
    @State private var cache = BrowserPreviewImageCache()
    var body: some View {
        if let image = cache.image(data) {
            image.swiftUI.resizable().scaledToFit().frame(maxHeight: 150)
                .clipShape(RoundedRectangle(cornerRadius: 5)).accessibilityLabel(label)
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
