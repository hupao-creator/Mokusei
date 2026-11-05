import MokuseiSidecardBrowser
import MokuseiPluginAPI
import MokuseiPluginUI
import SwiftUI

extension EnvironmentValues {
    @Entry var nativeApplicationReadingPanel = false
    @Entry var nativeApplicationOpenLinkCard: ((URL) -> Void)?
    @Entry var nativeApplicationCloseLinkCard: (() -> Bool)?
    @Entry var nativeReportExecutionInputChanged: ((ApplicationExecutionRef?, Bool, (() -> Void)?) -> Void)?
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
        default: "application.reading.panel"
        }
    }

    func body(content: Content) -> some View {
        if enabled {
            if identifier == "report-reading-panel" {
                NativeReportLinkWorkspace(suppressed: suppressed, onClose: onClose) {
                    content
                        .nativeReadingPanelClose(label: locale.language.languageCode?.identifier == "zh" ? "关闭报告" : "Close report", overlaysContent: true, onClose: onClose)
                        .background(NativeReadingPanelFrame(identifier: identifier))
                        .accessibilityIdentifier(identifier)
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
    @State private var auxiliaryBack: NativeReadingAuxiliaryBackAction?
    @State private var requestID = UUID()
    @State private var url: URL?
    @State private var sidecards = NativeReportSidecardPresentation()
    @State private var retainedWidth: CGFloat?
    @State private var dragging = false
    @State private var executionInput: NativeReportExecutionInput?
    @Environment(\.nativeExecutionDockPlacement) private var executionPlacement
    @Environment(\.nativeReportExecutionInputChanged) private var inputChanged
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var expanded: Bool { sidecards.active == .browser }

    var body: some View {
        GeometryReader { geometry in
            let size = CGSize(width: max(1, geometry.size.width - 76), height: geometry.size.height)
            let layout = NativeSidecardWorkspaceGeometry(size: size, open: expanded,
                preferredWidth: 0.5, retainedWidth: retainedWidth)
            let browserLauncher = CGPoint(x: size.width + 38, y: size.height / 2 + 28)
            ZStack(alignment: .topLeading) {
                content
                    .environment(\.nativeReportSidecards, sidecards)
                    .environment(\.nativeApplicationOpenLinkCard, { target in
                        guard !suppressed else { return }
                        url = target; requestID = UUID(); sidecards.open(.browser)
                    })
                    .environment(\.nativeApplicationCloseLinkCard, {
                        if sidecards.active == .browser || sidecards.pending == .browser { sidecards.close(); return true }
                        if let auxiliaryBack { auxiliaryBack.perform(); return true }
                        if sidecards.active != nil || sidecards.pending != nil { sidecards.close(); return true }
                        return false
                    })
                    .environment(\.nativeReadingAuxiliarySuppressed, suppressed)
                    .environment(\.nativeReadingAuxiliaryLauncherPosition,
                        CGPoint(x: size.width + 38, y: size.height / 2 - (url == nil ? 0 : 28)))
                    .frame(width: layout.mainWidth, height: layout.mainHeight)
                // Keep the shell mounted before the first HTML link arrives,
                // so selection animates its existing launcher-sized aperture in
                // the same transaction as every other sidecard and main pane.
                ZStack(alignment: .topLeading) {
                    if let url {
                        let browserRequest = requestID
                        let selectionID = sidecards.selectionID
                        NativeBrowserDocumentCard(url: url, requestID: requestID, suppressed: suppressed || !expanded,
                            onClose: {
                                guard browserRequest == requestID, selectionID == sidecards.selectionID,
                                      sidecards.active == .browser else { return }
                                sidecards.close()
                            })
                    } else { Color.clear }
                }
                .environment(\.nativeReadingNavigation, nil)
                .clipShape(RoundedRectangle(cornerRadius: 21))
                .modifier(NativeSidecardFold(progress: expanded ? 1 : 0,
                    source: CGRect(x: browserLauncher.x - 21, y: browserLauncher.y - 21, width: 42, height: 42),
                    destination: CGRect(x: layout.surfaceX, y: layout.surfaceY,
                        width: layout.surfaceWidth, height: layout.surfaceHeight),
                    frameIdentifier: "report-link-card", fadesOnClose: true))
                .allowsHitTesting(expanded && !suppressed)
                .disabled(!expanded || suppressed)
                .accessibilityHidden(!expanded || suppressed)
                .accessibilityIdentifier("report-link-card")
                if url != nil {
                    if expanded && !layout.stacked {
                        NativeSidecardDivider(width: layout.cardWidth, maximumWidth: layout.maximumCardWidth,
                            onWidthChange: { retainedWidth = $0 }, onDraggingChange: { dragging = $0 })
                            .frame(width: 6, height: size.height)
                            .offset(x: layout.mainWidth + 5)
                    }
                    NativeSidecardToggle(expanded: expanded || sidecards.pending == .browser,
                        label: locale.language.languageCode?.identifier == "zh" ? "网页" : "Browser",
                        action: { sidecards.toggle(.browser) }) {
                        NativeIcon(name: "Globe2", size: 17, strokeWidth: 1.8)
                            .frame(width: 42, height: 42).contentShape(Circle())
                    }
                    .position(browserLauncher)
                    .disabled(suppressed)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .overlayPreferenceValue(NativeReadingAuxiliaryToolbarKey.self) { toolbar in
                toolbar
                    .position(x: size.width + 38, y: size.height / 2 - (url == nil ? 0 : 28))
                    .disabled(suppressed)
            }
            .animation(dragging || reduceMotion ? nil : NativeSidecardTiming.foldAnimation, value: expanded)
            .animation(dragging || reduceMotion ? nil : NativeSidecardTiming.foldAnimation, value: layout.stacked)
        }
        .background(alignment: .topLeading) {
            NativeExecutionDockRegion(placement: executionPlacement,
                active: executionInput != nil && !suppressed,
                threadID: executionInput?.reference.thread.threadID,
                onSettled: { inputChanged?(executionInput?.reference, true, returnFromExecution) })
                .destinationFrame(executionInput?.frame)
                .allowsHitTesting(false)
        }
        .onPreferenceChange(NativeReportExecutionInputKey.self) { next in
            executionInput = next
            inputChanged?(next?.reference, false, returnFromExecution)
        }
        .onPreferenceChange(NativeReadingAuxiliaryBackKey.self) { auxiliaryBack = $0 }
        .onChange(of: suppressed) { _, hidden in
            if hidden { sidecards.updateLayout(ready: false, suppressed: true) }
        }
        .onDisappear { sidecards.cancel(); auxiliaryBack = nil; inputChanged?(nil, false, nil) }
        .nativeReadingEscape(perform: suppressed ? nil : {
            if sidecards.active == .browser || sidecards.pending == .browser { sidecards.close() }
            else if let auxiliaryBack { auxiliaryBack.perform() }
            else if sidecards.active != nil || sidecards.pending != nil { sidecards.close() }
            else { onClose() }
        })
    }

    private func returnFromExecution() {
        if let auxiliaryBack { auxiliaryBack.perform() }
        else { sidecards.close() }
    }
}
