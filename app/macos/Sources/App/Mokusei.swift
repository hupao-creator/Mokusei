import AppKit
import MokuseiPluginUI
import Observation
import Darwin
import Foundation
import MokuseiCore
import MokuseiComposition
import MokuseiUI
import SwiftUI

#if !MOKUSEI_WORKSPACE_LIFECYCLE_REPLAY
@main @MainActor
struct Mokusei {
    static func main() {
        let arguments = CommandLine.arguments
        if arguments.count == 4, arguments[1] == "--finish-runtime", arguments[2].hasPrefix("/") {
            Task.detached {
                await NativeRuntimeExitCleanup.finish(directory: URL(fileURLWithPath: arguments[2]), epoch: arguments[3])
                exit(EXIT_SUCCESS)
            }
            dispatchMain()
        }
        WorkspaceApp.main()
    }
}
#endif

@MainActor
private struct WorkspaceApp: App {
    @State private var session = WorkspaceSession()
    var body: some Scene {
        Window("Mokusei", id: "workspace") {
            WorkspaceWindow(session: session)
                .frame(minWidth: NativeGeometry.minimumWindow.width, minHeight: NativeGeometry.minimumWindow.height)
        }
        .nativeWorkspaceWindowStyle()
        .defaultLaunchBehavior(.presented)
        .defaultSize(width: session.benchmarkOverview ? 1280 : NativeGeometry.initialWindow.width,
                     height: session.benchmarkOverview ? 820 : NativeGeometry.initialWindow.height)
        .restorationBehavior(session.benchmarkOverview ? .disabled : .automatic)
        .defaultWindowPlacement { _, _ in
            session.benchmarkOverview ? WindowPlacement(CGPoint(x: 50, y: 60), size: CGSize(width: 1280, height: 820)) : WindowPlacement()
        }
        .commands {
            NativeWorkspaceCommands()
            CommandGroup(replacing: .appTermination) {
                Button(session.model?.preferences.locale.text("退出", "Quit") ?? "Quit") { session.quit() }.keyboardShortcut("q")
            }
            CommandGroup(after: .toolbar) {
                Button("Reload") { session.performWebCommand("mokuseiReloadFocusedWebContent:") { session.reload() } }.keyboardShortcut("r").disabled(session.busy)
                Button("Actual Size") { session.performWebCommand("mokuseiResetFocusedWebContentZoom:") { session.setZoom(0) } }.keyboardShortcut("0")
                Button("Zoom In") { session.performWebCommand("mokuseiZoomInFocusedWebContent:") { session.setZoom(session.zoom + 0.5) } }.keyboardShortcut("+")
                Button("Zoom Out") { session.performWebCommand("mokuseiZoomOutFocusedWebContent:") { session.setZoom(session.zoom - 0.5) } }.keyboardShortcut("-")
                Toggle("Collect Detailed Performance", isOn: Binding(get: { NativePerformance.mode == .detailed },
                    set: { session.setPerformance($0) }))
            }
        }
    }
}

@MainActor @Observable
final class WorkspaceSession {
    private(set) var benchmarkOverview = false
    private(set) var benchmarkEmojiGlass = false
    var model: NativeWorkspaceModel?
    var presentation: NativeWorkspacePresentation?
    var error: String?
    var quitSettingsBlocked = false
    var busy = false
    var zoom: Double = 0
    var generation = UUID()
    private let startup = NativeStartupPerformance()
    private var exitCleanup: NativeRuntimeExitCleanup?
    private var interactionServer: NativeInteractionServer?
    private var zoomURL: URL?
    private var performanceDirectory: URL?
    private var task: Task<Void, Never>?
    private(set) var reloadTask: Task<Void, Never>?
    private var operationID: UUID?
    private var quitting = false
    private var finishingQuit = false
    private var quitSavingSettings = false
    private var quitDeadline: Task<Void, Never>?
    private static let zoomRange = (log(0.25) / log(1.2))...(log(5) / log(1.2))
    var scale: Double { pow(1.2, zoom) }

    init() {
        do {
            let options = try LaunchOptions()
            benchmarkOverview = options.benchmarkOverview
            benchmarkEmojiGlass = options.benchmarkEmojiBadge == "liquid-glass"
            let lease = try RuntimeProfileClientLease(dataDirectory: options.dataDirectory)
            lease.retainForProcess()
            let profile = lease.profile
            NativeLayoutDiagnostics.start(directory: profile.dataDirectory.appendingPathComponent("diagnostics/layout", isDirectory: true),
                explicitDataDirectory: options.explicitDataDirectory)
            performanceDirectory = profile.dataDirectory.appendingPathComponent("diagnostics/performance", isDirectory: true)
            if let performanceDirectory { NativePerformance.configure(directory: performanceDirectory) }
            startup.attachToRecording()
            zoomURL = profile.dataDirectory.appendingPathComponent("native-window-zoom.json")
            if let zoomURL, let data = try? Data(contentsOf: zoomURL),
               let saved = try? JSONDecoder().decode(SavedZoom.self, from: data), saved.level.isFinite { setZoom(saved.level) }
            NativeTypography.registerFonts()
            let preferences = DesktopPreferences(directory: profile.dataDirectory)
            // Explicit scenario setup belongs to the application. External runners
            // never synthesize preference files or bypass the production renderer.
            if options.benchmarkOverview {
                try preferences.setOnboardingCompleted(true)
                let receipt: [String: Any] = ["version": 1, "scenario": "overview",
                    "pid": ProcessInfo.processInfo.processIdentifier, "agentEmojiBadge": options.benchmarkEmojiBadge,
                    "reduceTransparency": NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
                    "reduceMotion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                    "increaseContrast": NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast]
                try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
                    .write(to: profile.dataDirectory.appendingPathComponent("benchmark-scenario.json"), options: .atomic)
            }
            let client = RuntimeClient(profile: profile, launch: options.launch)
            let composition = try NativePlugins.make()
            let model = NativeWorkspaceModel(client: client, preferences: preferences, plugins: composition, startupPerformance: startup)
            if let path = options.automationSocket {
                interactionServer = try NativeInteractionServer(path: path) { [weak self] in
                    guard let self, !self.busy else { return nil }
                    return self.presentation
                }
            }
            self.model = model; presentation = NativeWorkspacePresentation(workspace: model)
            if let executable = Bundle.main.executableURL { exitCleanup = NativeRuntimeExitCleanup(profile: profile, executable: executable) }
        } catch { startup.fail(); self.error = error.localizedDescription }
    }
    #if MOKUSEI_WORKSPACE_LIFECYCLE_REPLAY
    init(model: NativeWorkspaceModel) {
        self.model = model
        presentation = NativeWorkspacePresentation(workspace: model)
    }
    #endif
    func start() {
        guard let model else { return }
        startup.shellReady(); model.start()
        FileHandle.standardOutput.write(Data("[native-launch] ready pid=\(ProcessInfo.processInfo.processIdentifier)\n".utf8))
    }
    func setZoom(_ value: Double) {
        guard value.isFinite else { return }
        zoom = min(Self.zoomRange.upperBound, max(Self.zoomRange.lowerBound, value))
        if let zoomURL, let data = try? JSONEncoder().encode(SavedZoom(level: zoom)) { try? data.write(to: zoomURL, options: .atomic) }
    }
    func performWebCommand(_ selector: String, fallback: () -> Void) {
        if !NSApp.sendAction(NSSelectorFromString(selector), to: nil, from: nil) { fallback() }
    }
    func setPerformance(_ enabled: Bool) {
        guard let performanceDirectory else { return }
        NativePerformance.configure(directory: performanceDirectory, mode: enabled ? .detailed : .off)
    }
    func reload() {
        guard !busy, !quitting, let model else { return }
        model.resetSettingsForReload()
        let retiring = presentation
        replacePresentation(for: model) {
            await retiring?.release()
            await model.voice.stopAll()
            await model.harnessHost.releaseAll()
        }
    }
    private func replacePresentation(for model: NativeWorkspaceModel, after cleanup: @escaping @MainActor () async -> Void) {
        let operationID = UUID()
        self.operationID = operationID
        busy = true
        let pending = Task {
            defer {
                if self.operationID == operationID {
                    self.operationID = nil; reloadTask = nil; task = nil; busy = false
                }
            }
            // Cancellation revokes publication, not the scoped resource drain.
            // A rejected Quit joins this same retirement before restoring a UI owner.
            await cleanup()
            guard !Task.isCancelled, self.operationID == operationID, !quitting else { return }
            model.voice.receive(.connection(model.connection)); model.settingsOpen = false
            presentation = NativeWorkspacePresentation(workspace: model); generation = UUID()
        }
        reloadTask = pending
        task = pending
    }
    func quit(discardSettings: Bool = false) {
        guard !quitting else {
            NativeDiagnosticExit.forceExit { exitCleanup?.prepareForExit() }
        }
        quitting = true; busy = true
        let operationID = UUID()
        self.operationID = operationID
        quitSavingSettings = !discardSettings
        exitCleanup?.captureEpoch()
        task?.cancel()
        // Network/voice cleanup can outlive cancellation. The deadline must
        // not join that work; the epoch-fenced exit helper finishes it instead.
        quitDeadline = Task {
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard !Task.isCancelled, self.operationID == operationID, quitting else { return }
            if quitSavingSettings {
                rejectQuitForSettings(RuntimeError("SETTINGS_UNSAVED", "Saving settings timed out."))
                return
            }
            exitCleanup?.record(RuntimeError("QUIT_TIMEOUT", "Application exited while runtime cleanup continued"))
            finishQuit()
        }
        task = Task {
            if !discardSettings {
                do { try await model?.settingsModel.draft.flushForQuit() }
                catch {
                    guard !Task.isCancelled, self.operationID == operationID, quitting else { return }
                    rejectQuitForSettings(error)
                    return
                }
            }
            guard !Task.isCancelled, self.operationID == operationID, quitting else { return }
            quitSavingSettings = false
            do {
                try await model?.stop()
                exitCleanup?.disarm()
            } catch { exitCleanup?.record(error) }
            finishQuit()
        }
    }
    private func rejectQuitForSettings(_ error: Error) {
        quitDeadline?.cancel(); quitDeadline = nil
        task?.cancel(); task = nil
        operationID = nil
        quitting = false; quitSavingSettings = false; busy = false
        quitSettingsBlocked = true
        self.error = model?.preferences.locale.text(
            "设置尚未保存。可以继续编辑，或不保存并退出。\n\(error.localizedDescription)",
            "Settings have not been saved. Keep editing, or quit without saving.\n\(error.localizedDescription)") ?? error.localizedDescription
        if let reloadTask, let model {
            // Keep the failed Settings draft; restarting Reload would discard it.
            replacePresentation(for: model) { await reloadTask.value }
        }
    }
    private func finishQuit() {
        // A late runtime-cleanup completion must not cut short a drain already
        // requested by the runtime deadline. Only an explicit second Quit forces.
        guard !finishingQuit else { return }
        finishingQuit = true
        quitDeadline?.cancel()
        // Arm a separate background deadline before either diagnostics path.
        // A second Quit bypasses drains, but still admits the Runtime helper.
        let exitGate = NativeDiagnosticExit { NativeDiagnosticExit.terminateProcess(timedOut: $0) }
        exitCleanup?.prepareForExit()
        interactionServer?.stop()
        startup.cancel()
        NativeLayoutDiagnostics.finish { exitGate.completedDrain() }
        DispatchQueue.global(qos: .utility).async {
            NativePerformance.finish()
            exitGate.completedDrain()
        }
    }
    private struct SavedZoom: Codable { let level: Double }
}

private struct WorkspaceWindow: View {
    let session: WorkspaceSession
    var body: some View {
        GeometryReader { geometry in
            Group {
                if let model = session.model, let presentation = session.presentation {
                    NativeWorkspaceView(model: model, presentation: presentation).id(session.generation)
                        .environment(\.agentThreadEmojiUsesLiquidGlass, session.benchmarkEmojiGlass)
                } else { ContentUnavailableView("无法打开 Mokusei", systemImage: "exclamationmark.triangle", description: Text(session.error ?? "")) }
            }
            .frame(width: geometry.size.width / session.scale, height: geometry.size.height / session.scale)
            .environment(\.nativeWindowContentScale, CGFloat(session.scale))
            .scaleEffect(session.scale, anchor: .topLeading)
            .disabled(session.busy)
        }
        .modifier(NativeWorkspaceWindowSurface())
        .nativeLayoutLog("workspace.window")
        .onAppear { session.start() }
        .onDisappear { session.quit() }
        .alert("Mokusei", isPresented: Binding(get: { session.error != nil && session.model != nil }, set: { if !$0 { session.error = nil } })) {
            if session.quitSettingsBlocked {
                Button(session.model?.preferences.locale.text("继续编辑", "Keep Editing") ?? "Keep Editing", role: .cancel) {
                    session.error = nil; session.quitSettingsBlocked = false
                }
                Button(session.model?.preferences.locale.text("不保存并退出", "Quit Without Saving") ?? "Quit Without Saving", role: .destructive) {
                    session.error = nil; session.quitSettingsBlocked = false; session.quit(discardSettings: true)
                }
            } else { Button("OK") { session.error = nil } }
        } message: { Text(session.error ?? "") }
    }
}

private struct LaunchOptions {
    let dataDirectory: URL
    let launch: RuntimeLaunchConfiguration?
    let automationSocket: String?
    let explicitDataDirectory: Bool
    let benchmarkOverview: Bool
    let benchmarkEmojiBadge: String

    init() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        var options: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            if flag.hasPrefix("-psn_") { index += 1; continue }
            let allowedValues: [String: [String]] = ["--benchmark-scenario": ["overview"],
                "--benchmark-agent-emoji-badge": ["flat", "liquid-glass"]]
            guard (allowedValues[flag] != nil || ["--data-dir", "--runtime", "--automation-socket"].contains(flag)),
                  index + 1 < arguments.count, options[flag] == nil,
                  allowedValues[flag].map({ $0.contains(arguments[index + 1]) }) ?? arguments[index + 1].hasPrefix("/") else {
                throw NSError(domain: "MokuseiLaunch", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unknown launch argument: \(flag)"])
            }
            options[flag] = arguments[index + 1]
            index += 2
        }
        automationSocket = options["--automation-socket"]
        explicitDataDirectory = options["--data-dir"] != nil
        benchmarkOverview = options["--benchmark-scenario"] == "overview"
        benchmarkEmojiBadge = options["--benchmark-agent-emoji-badge"] ?? "flat"
        if options["--benchmark-agent-emoji-badge"] != nil, !benchmarkOverview {
            throw NSError(domain: "MokuseiLaunch", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "Badge experiments require --benchmark-scenario overview."])
        }
        if benchmarkOverview, !explicitDataDirectory || automationSocket == nil {
            throw NSError(domain: "MokuseiLaunch", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "Benchmark scenarios require explicit --data-dir and --automation-socket."])
        }
        if automationSocket != nil, options["--data-dir"] == nil {
            throw NSError(domain: "MokuseiLaunch", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Automation requires an explicit --data-dir."])
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dataDirectoryName = Bundle.main.object(forInfoDictionaryKey: "MokuseiDataDirectoryName") as? String
            ?? "Mokusei"
        dataDirectory = options["--data-dir"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent("Library/Application Support/\(dataDirectoryName)", isDirectory: true)
        let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent()
        let runtime = options["--runtime"].map { URL(fileURLWithPath: $0) }
            ?? executableDirectory?.appendingPathComponent("mokusei-runtime")
        if let runtime, FileManager.default.isExecutableFile(atPath: runtime.path) {
            launch = RuntimeLaunchConfiguration(executable: runtime, workingDirectory: home)
        } else {
            if options["--runtime"] != nil || Bundle.main.bundleURL.pathExtension == "app" {
                throw NSError(domain: "MokuseiLaunch", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "The native application requires its Go runtime executable."])
            }
            // A development executable may explicitly connect to an existing service.
            // It never silently falls back to a machine-specific runtime or production profile.
            launch = nil
        }
    }
}
