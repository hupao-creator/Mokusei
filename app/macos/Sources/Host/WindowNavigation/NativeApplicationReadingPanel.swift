import MokuseiSidecardBrowser
import MokuseiPluginUI
import SwiftUI

extension EnvironmentValues {
    @Entry var nativeApplicationReadingPanel = false
    @Entry var nativeApplicationOpenLinkCard: ((URL) -> Void)?
    @Entry var nativeApplicationCloseLinkCard: (() -> Bool)?
}

struct NativeApplicationReadingPanel: ViewModifier {
    let enabled: Bool
    var suppressed = false
    var escapeEnabled = true
    let identifier: String
    let onClose: () -> Void
    @Environment(\.locale) private var locale

    private var layoutRole: StaticString {
        switch identifier {
        case "moku-reading-panel": "moku.history.panel"
        case "report-reading-panel": "report.reading.panel"
        case "git-reading-panel": "git.reading.panel"
        default: "application.reading.panel"
        }
    }

    func body(content: Content) -> some View {
        if enabled {
            if identifier == "report-reading-panel" {
                NativeReportLinkWorkspace(suppressed: suppressed, onClose: onClose) {
                    panel(content)
                }
            } else {
                panel(content).padding(.trailing, 76)
            }
        } else { content }
    }

    private func panel(_ content: Content) -> some View {
        viewport(content)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(NativePalette.thread.canvas.swiftUI)
            .background(NativeReadingPanelFrame(identifier: identifier))
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(NativePalette.thread.line.swiftUI.opacity(0.6)))
            .nativeReadingPanelClose(label: locale.language.languageCode?.identifier == "zh" ? "关闭面板" : "Close panel",
                overlaysContent: identifier == "report-reading-panel", onClose: onClose)
            .accessibilityIdentifier(identifier)
            .nativeLayoutLog(layoutRole)
            .nativeReadingEscape(perform: suppressed || !escapeEnabled || identifier == "report-reading-panel" ? nil : onClose)
    }

    @ViewBuilder private func viewport(_ content: Content) -> some View {
        if identifier == "report-reading-panel" {
            // Clip before padding so the 8pt border follows the outer 22pt curve.
            content.clipShape(RoundedRectangle(cornerRadius: 14))
                .nativeReadingPanelViewport(topInset: 8, balancedVerticalInsets: true)
        } else {
            content.nativeReadingPanelViewport()
        }
    }
}

private struct NativeReportLinkWorkspace<Content: View>: View {
    let suppressed: Bool
    let onClose: () -> Void
    @ViewBuilder var content: Content
    @State private var requestID = UUID()
    @State private var url: URL?
    @State private var expanded = false
    @State private var retainedWidth: CGFloat?
    @State private var dragging = false
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let size = CGSize(width: max(1, geometry.size.width - 76), height: geometry.size.height)
            let layout = NativeSidecardWorkspaceGeometry(size: size, open: expanded,
                preferredWidth: 2.0 / 3, retainedWidth: retainedWidth)
            ZStack(alignment: .topLeading) {
                content
                    .environment(\.nativeApplicationOpenLinkCard, { target in url = target; requestID = UUID(); expanded = true })
                    .environment(\.nativeApplicationCloseLinkCard, {
                        guard expanded else { return false }
                        expanded = false; return true
                    })
                    .frame(width: layout.mainWidth, height: layout.mainHeight)
                if url != nil {
                    if expanded && !layout.stacked {
                        NativeSidecardDivider(width: layout.cardWidth, maximumWidth: layout.maximumCardWidth,
                            onWidthChange: { retainedWidth = $0 }, onDraggingChange: { dragging = $0 })
                            .frame(width: 6, height: size.height)
                            .offset(x: layout.mainWidth + 5)
                    }
                    if let url {
                        NativeBrowserDocumentCard(url: url, requestID: requestID, suppressed: suppressed || !expanded,
                            onClose: { expanded = false })
                            .environment(\.nativeReadingNavigation, nil)
                            .frame(width: layout.surfaceWidth, height: layout.surfaceHeight)
                            .background(NativePalette.thread.canvas.swiftUI)
                            .background(NativeReadingPanelFrame(identifier: "report-link-card"))
                            .clipShape(RoundedRectangle(cornerRadius: 21))
                            .overlay(RoundedRectangle(cornerRadius: 21).stroke(NativePalette.thread.line.swiftUI.opacity(0.6)))
                            .offset(x: layout.surfaceX, y: layout.surfaceY)
                            .opacity(expanded ? 1 : 0)
                            .allowsHitTesting(expanded && !suppressed)
                            .disabled(!expanded || suppressed)
                            .accessibilityHidden(!expanded || suppressed)
                            .accessibilityIdentifier("report-link-card")
                    }
                    Button { expanded.toggle() } label: {
                        NativeIcon(name: "Globe2", size: 17, strokeWidth: 1.8)
                            .frame(width: 42, height: 42).contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.tint(expanded ? .blue.opacity(0.18) : .clear).interactive(), in: .circle)
                    .position(x: size.width + 38, y: size.height / 2)
                    .disabled(suppressed)
                    .accessibilityValue(locale.language.languageCode?.identifier == "zh"
                        ? (expanded ? "已展开" : "已收起") : (expanded ? "Expanded" : "Collapsed"))
                    .help(locale.language.languageCode?.identifier == "zh" ? "网页" : "Browser")
                    .accessibilityLabel(locale.language.languageCode?.identifier == "zh" ? "网页" : "Browser")
                }
            }
            .animation(dragging || reduceMotion ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: 0.38), value: expanded)
            .animation(dragging || reduceMotion ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: 0.38), value: layout.stacked)
        }
        .nativeReadingEscape(perform: suppressed ? nil : {
            if expanded { expanded = false }
            else { onClose() }
        })
    }
}
