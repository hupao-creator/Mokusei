import SwiftUI
import AppKit
import ScreenCaptureKit
import Observation
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import MokuseiHarnessCodex
import MokuseiHarnessClaude
@testable import MokuseiApplications
@testable import MokuseiUI

@MainActor @Observable private final class ProductionReportFixture {
    let showsCover: Bool
    init(showsCover: Bool) { self.showsCover = showsCover }
    var open = false
    let motion = NativeReadingPageMotion()
    let sample = ReportFixture.groupedSample
    @ObservationIgnored lazy var props: ApplicationThreadProps<NativeReportView> = makeProps()
    private func makeProps() -> ApplicationThreadProps<NativeReportView> {
        let reference = ApplicationThreadRef(threadID: "report-preview", typeID: "report.document")
        let refs = sample.executions.map { ApplicationExecutionRef(thread: .init(threadID: JSONText($0.id), typeID: "agent"), executionID: JSONText($0.id)) }
        let capabilities = try! ApplicationCapabilityAccess<ApplicationRendererPhase>(scope: .init(pluginID: "report", thread: reference), requires: [
            ApplicationCapabilities.executionReferencesUI.requirement,
            ApplicationCapabilities.threadUserActions.requirement,
            ApplicationCapabilities.isolatedHTML.requirement
        ], registrations: [
            .init(ApplicationCapabilities.threadUserActions, value: ApplicationThreadUserActions(setArchived: { _, _, _ in }, initializeConversation: { _, _ in })),
            .init(ApplicationCapabilities.executionReferencesUI, value: ApplicationExecutionReferencesUI(read: { [sample] requested in
                requested.compactMap { ref in
                    guard let item = sample.executions.first(where: { $0.id == ref.executionID.string }) else { return nil }
                    let codex = item.harness == .codex
                    return .init(reference: ref, title: JSONText(item.title), emoji: item.emoji, missing: false, running: false,
                        harness: .init(id: codex ? "codex" : "claude", displayName: JSONText(item.harness.rawValue)), preview: try! .init(startedAt: 0, finishedAt: 138_000, running: false, excerpt: JSONText(item.answer)))
                }
            }, subscribe: { _ in {} }, logo: { id, size in
                id == "codex" ? AnyView(CodexLogo(size: size)) : AnyView(ClaudeLogo(size: size))
            }, execution: { [sample] ref in
                guard let item = sample.executions.first(where: { $0.id == ref.executionID.string }) else { throw PluginContractError("Missing fixture execution") }
                return AnyView(ExecutionReader(execution: item))
            })),
            .init(ApplicationCapabilities.isolatedHTML, value: ApplicationIsolatedHTML { [weak self] source, failure in
                NativeApplicationHTMLSurface(source: source, thread: reference, theme: .light, suppressed: false,
                    readDocument: { source in ApplicationHTMLDocument(html: JSONText(ReportDocument.html), contentRevision: source.contentRevision) },
                    openExternal: { _ in }, onBack: { self?.motion.close() }, onSettings: {}, onNativeNavigationChange: { _ in }, onFailure: failure)
            })
        ])
        let view = try! NativeReportView(json: .object([
            "coverRevision": .text(showsCover ? "cover-preview" : ""),
            "emoji": .text(sample.emoji), "shortDescription": .text(sample.shortDescription), "previewText": .text(sample.shortDescription),
            "contentRevision": .text("preview"), "relatedExecutions": .array(refs.map { .object(["thread": $0.thread.json, "executionId": .string($0.executionID)]) })
        ]))
        return .init(entry: .init(ref: reference, revision: 1, createdAt: 0, updatedAt: Date().addingTimeInterval(-46800).timeIntervalSince1970 * 1000,
            title: JSONText(sample.title), archived: false, tags: .init(tags: [], semanticTags: [], directoryTags: [], tagEmojis: [:]), presentations: [], view: view),
            context: .init(theme: .light, locale: "zh-CN", lifetime: PluginLifetime(), domain: .init(pluginID: "report", invoke: { [sample] _, operation, _, _, _ in
                    if operation == "report.cover" {
                        return .object(["html": .text(ReportCoverDocument.html), "contentRevision": .text("cover-preview")])
                    }
                    guard operation == "report.relations" else { throw PluginContractError("Fixture only") }
                    return .object(["reportId": .text("report-preview"), "revision": .number(1), "items": .array(sample.executions.map { item in
                        let facts: JSONValue = .object(["executionId": .text(item.id), "status": .text("completed"),
                            "startedAt": .number(0), "finishedAt": .number(138_000)])
                        return .object([
                            "reference": .object(["thread": .object(["typeId": .text("agent"), "threadId": .text(item.id)]), "executionId": .text(item.id)]),
                            "thread": .object(["title": .text(item.title), "archived": .bool(false),
                                "currentExecution": facts, "backgroundRunning": .bool(false)]),
                            "execution": facts, "unavailable": .text(""), "bindingCount": .number(1)
                        ])
                    })])
                }),
                capabilities: capabilities, openThread: { _, _ in }, openExecution: { _ in }))
    }
}

struct ProductionReportPreview: View {
    var showsCover = false
    private var cardWidth: CGFloat { NativeOverviewLayout.columnWidth }
    private var rowHeight: CGFloat { showsCover ? NativeOverviewLayout.rowHeight : 200 }
    private var cardHeight: CGFloat { showsCover ? rowHeight * 2 + NativeOverviewLayout.gap : rowHeight }
    @State private var fixture: ProductionReportFixture
    init(showsCover: Bool = false) {
        self.showsCover = showsCover
        _fixture = State(initialValue: ProductionReportFixture(showsCover: showsCover))
    }
    @State private var slow = false
    @State private var recording = ProductionReportRecording()
    var body: some View {
        NativeReadingPageStack(open: fixture.open, identity: "report-preview", motion: fixture.motion,
            stationaryParent: true, emphasizedOpening: true, panel: true,
            panelSource: CGRect(x: 180, y: 160, width: cardWidth, height: cardHeight),
            panelFrontIdentity: "workspace-route-slide", reportPanelMotion: true,
            duration: slow ? 2.1 : 0.42,
            prepareParent: { await Task.yield() }, onClose: { fixture.open = false }) {
            ZStack(alignment: .topLeading) {
                Color(white: 0.14)
                NativeReportCard(props: fixture.props,
                    projection: .init(previewText: fixture.props.entry.view.shortDescription, relatedThreadCount: fixture.sample.executions.count),
                    openThread: { fixture.open = true })
                .frame(width: cardWidth, height: cardHeight)
                .background(NativePalette.overview.surface.swiftUI)
                .clipShape(RoundedRectangle(cornerRadius: 22))
                .overlay(RoundedRectangle(cornerRadius: 22).stroke(NativePalette.overview.lineSoft.swiftUI))
                .contentShape(RoundedRectangle(cornerRadius: 22))
                .offset(x: 180, y: 160)
            }
        } front: {
            ProductionReportRoute(fixture: fixture)
        }
        .overlay(alignment: .bottomTrailing) {
            HStack {
                Text(recording.status).font(.caption).foregroundStyle(.secondary)
                Button(recording.active ? "停止录制" : "录制本窗口") {
                    Task { await recording.toggle() }
                }.disabled(recording.busy)
                Toggle("慢速 ×5", isOn: $slow).toggleStyle(.checkbox)
            }.padding(24)
        }
        .environment(\.scenePhase, .active).environment(\.locale, Locale(identifier: "zh-Hans"))
        .preferredColorScheme(.dark).modifier(NativeWorkspaceWindowSurface())
    }
}

private struct ProductionReportRoute: View {
    let fixture: ProductionReportFixture
    var body: some View {
        NativeReportDetail(props: fixture.props)
            .modifier(NativeApplicationReadingPanel(enabled: true, identifier: "report-reading-panel", onClose: { fixture.motion.close() }))
            .environment(\.nativeApplicationReadingPanel, true)
    }
}

/// Manual evidence capture of this isolated production-component window only.
/// It does not drive controls, invoke tests or record any other application.
@MainActor @Observable private final class ProductionReportRecording: NSObject, SCRecordingOutputDelegate {
    var active = false
    var busy = false
    var status = ""
    @ObservationIgnored private var stream: SCStream?
    @ObservationIgnored private var output: SCRecordingOutput?
    @ObservationIgnored private var destination: URL?
    func toggle() async {
        busy = true
        defer { busy = false }
        do {
            if let stream {
                try await stream.stopCapture()
                self.stream = nil
                active = false
                return
            }
            // Accessibility clicks can reach this isolated preview without making
            // it key. Keep recording scoped to its visible application window.
            guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else {
                status = "没有可录制的预览窗口"; return
            }
            let available = try await SCShareableContent.currentProcess
            guard let target = available.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
                status = "预览窗口尚未可供录制"; return
            }
            let directory = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("evidence")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent("return-\(Int(Date().timeIntervalSince1970)).mp4")
            self.destination = destination
            let config = SCStreamConfiguration()
            config.width = Int(window.frame.width * 2); config.height = Int(window.frame.height * 2)
            config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            config.queueDepth = 6; config.ignoreShadowsSingleWindow = true
            config.showsCursor = false; config.capturesAudio = false; config.captureMicrophone = false
            let record = SCRecordingOutputConfiguration()
            record.outputURL = destination; record.videoCodecType = .h264; record.outputFileType = .mp4
            let output = SCRecordingOutput(configuration: record, delegate: self)
            self.output = output
            let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: target), configuration: config, delegate: nil)
            try stream.addRecordingOutput(output)
            self.stream = stream
            try await stream.startCapture()
            active = true
            status = "录制中"
        } catch { status = String(describing: error); stream = nil; active = false }
    }
    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in status = destination?.lastPathComponent ?? "已保存"; output = nil }
    }
    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        let message = String(describing: error)
        Task { @MainActor in status = message; active = false }
    }
}

private enum ReportCoverDocument {
    static let html = """
    <!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
    <style>
    *{box-sizing:border-box}html,body{margin:0;width:100%;height:100%;overflow:hidden}
    body{background:#dddcd3;color:#282e2c;font-family:-apple-system,BlinkMacSystemFont,sans-serif}
    article{height:100%;padding:22px;position:relative;background:linear-gradient(125deg,#efeee7,#d1d6ca)}
    small{font-size:9px;letter-spacing:2px}h1{font-size:24px;line-height:1.25;font-weight:600;letter-spacing:-.6px;margin:21px 0 12px;position:relative;z-index:1}
    footer{font-size:10px;color:#596358;position:absolute;bottom:21px;left:22px}
    .bars{position:absolute;right:22px;bottom:25px;height:113px;display:flex;gap:8px;align-items:end;opacity:.32}
    .bars i{display:block;width:17px;background:#657b62;border-radius:3px 3px 0 0}
    .bars i:nth-child(1){height:28%}.bars i:nth-child(2){height:48%}.bars i:nth-child(3){height:39%}.bars i:nth-child(4){height:74%}.bars i:nth-child(5){height:100%}
    </style></head><body><article><small>MOKUSEI / REPORT</small>
    <h1>Report 与 Tag<br>工具留存分析</h1><div class="bars" aria-hidden="true"><i></i><i></i><i></i><i></i><i></i></div>
    <footer>调用频次 · 成功情况 · 统计边界</footer></article></body></html>
    """
}
