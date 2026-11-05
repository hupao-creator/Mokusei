import MokuseiPluginUI
import SwiftUI
import WebKit

/// A document-owned browser without Thread execution or annotation capabilities.
@MainActor
public struct NativeBrowserDocumentCard: View {
    public let requestID: UUID
    public let url: URL
    public let suppressed: Bool
    public let onClose: () -> Void
    @Environment(\.locale) private var locale
    @State private var session: BrowserWebSession?

    public init(url: URL, requestID: UUID, suppressed: Bool, onClose: @escaping () -> Void) {
        self.url = url; self.requestID = requestID; self.suppressed = suppressed
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            BrowserPageToolbar(session: session, requestedURL: url, active: !suppressed,
                translate: translate, onOpen: { session?.navigate($0) }, onClose: onClose) { EmptyView() }
            if let notice = session?.notice { message(notice) }
            ZStack {
                if let session {
                    BrowserViewport(session: session, suppressed: suppressed || session.error != nil, coveredBottom: 0)
                        .clipShape(RoundedRectangle(cornerRadius: 12)).padding(.horizontal, 8)
                    if let error = session.error {
                        VStack(spacing: 10) {
                            message(error)
                            Button(translate("重试")) { retry() }.buttonStyle(BrowserRetryStyle())
                        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Color.clear.frame(height: 8)
        }
        .task(id: requestID) {
            guard !Task.isCancelled else { return }
            if session == nil { makeSession() }
            session?.backToOverview = onClose
            session?.navigate(url)
        }
        .onChange(of: suppressed) { _, value in
            session?.backToOverview = onClose
            session?.setSuppressed(value)
        }
        .onChange(of: locale) { _, value in
            session?.translate = { NativePluginLocalization.localize($0, locale: value) }
        }
        .onDisappear { session?.release(); session = nil }
        .nativeOnExitCommand { if !suppressed { onClose() } }
    }

    private func makeSession() {
        // Report visits own an ephemeral partition; no Agent identity or draft
        // is fabricated, and retiring the reading route releases page dialogs.
        let next = BrowserWebSession(store: .nonPersistent())
        let locale = locale
        next.translate = { NativePluginLocalization.localize($0, locale: locale) }
        // This session's unhandled DOM Escape folds the card. The Report's
        // ordinary Close/Overview routes remain owned by its containing panel.
        next.backToOverview = onClose
        next.setSuppressed(suppressed)
        session = next
    }

    private func retry() {
        guard let session else { return }
        if session.terminated {
            let target = session.pendingURL ?? session.webView.url ?? url
            session.release(); makeSession(); self.session?.navigate(target)
        } else { session.retry() }
    }

    private func translate(_ text: String) -> String { NativePluginLocalization.localize(text, locale: locale) }
    private func message(_ text: String) -> some View {
        Text(session?.localized(text) ?? translate(text)).font(NativeTypography.inter(size: 12))
            .foregroundStyle(NativeAppKitPalette.thread.danger.swiftUI)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 4)
    }
}
