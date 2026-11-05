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
                    return .init(reference: ref, title: JSONText(item.title), missing: false, running: false,
                        harness: .init(id: codex ? "codex" : "claude", displayName: JSONText(item.harness.rawValue), logoSource: codex ? CodexLogo.source : ClaudeLogo.source), preview: try! .init(startedAt: 0, finishedAt: 138_000, running: false, excerpt: JSONText(item.answer)))
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
            "emoji": .text(sample.emoji), "shortDescription": .text(sample.shortDescription), "previewText": .text(sample.shortDescription),
            "contentRevision": .text("preview"), "relatedExecutions": .array(refs.map { .object(["thread": $0.thread.json, "executionId": .string($0.executionID)]) })
        ]))
        return .init(entry: .init(ref: reference, revision: 1, createdAt: 0, updatedAt: Date().addingTimeInterval(-46800).timeIntervalSince1970 * 1000,
            title: JSONText(sample.title), archived: false, tags: .init(tags: [], semanticTags: [], directoryTags: [], tagEmojis: [:]), presentations: [], view: view),
            context: .init(theme: .light, locale: "zh-CN", lifetime: PluginLifetime(), domain: .init(pluginID: "report", invoke: { _, _, _, _, _ in throw PluginContractError("Fixture only") }),
                capabilities: capabilities, openThread: { _, _ in }, openExecution: { _ in }))
    }
}

struct ProductionReportPreview: View {
    @State private var fixture = ProductionReportFixture()
    @State private var slow = false
    @State private var recording = ProductionReportRecording()
    var body: some View {
        NativeReadingPageStack(open: fixture.open, identity: "report-preview", motion: fixture.motion,
            stationaryParent: true, emphasizedOpening: true, panel: true,
            panelSource: CGRect(x: 180, y: 160, width: 360, height: 200),
            panelFrontIdentity: "workspace-route-slide", reportPanelMotion: true,
            duration: slow ? 2.1 : 0.42,
            prepareParent: { await Task.yield() }, onClose: { fixture.open = false }) {
            ZStack(alignment: .topLeading) {
                Color(white: 0.14)
                NativeReportCard(props: fixture.props, projection: .init(previewText: fixture.props.entry.view.shortDescription, relatedThreadCount: 2), openThread: { fixture.open = true })
                    .frame(width: 360, height: 200)
                    .background(NativePalette.overview.surface.swiftUI, in: RoundedRectangle(cornerRadius: 22))
                    .overlay(RoundedRectangle(cornerRadius: 22).stroke(NativePalette.overview.lineSoft.swiftUI))
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
    @Environment(\.nativeReadingEntranceReady) private var ready
    private let route = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    var body: some View {
        NativeExecutionRouteSlide(route: route, requestedRoute: nil, ready: ready, enabled: true) {
            NativeReportDetail(props: fixture.props)
                .modifier(NativeApplicationReadingPanel(enabled: true, identifier: "report-reading-panel", onClose: { fixture.motion.close() }))
                .environment(\.nativeApplicationReadingPanel, true)
        }
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
            guard let window = NSApp.keyWindow else { return }
            let available = try await SCShareableContent.currentProcess
            guard let target = available.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { return }
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
