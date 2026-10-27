import MokuseiPluginUI
import Observation
import Darwin
import Foundation
import MokuseiCore
import MokuseiComposition
import MokuseiUI
import SwiftUI

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
        .defaultSize(width: NativeGeometry.initialWindow.width, height: NativeGeometry.initialWindow.height)
        .commands {
            NativeWorkspaceCommands()
            CommandGroup(replacing: .appTermination) {
                Button(session.model?.preferences.locale.text("退出", "Quit") ?? "Quit") { session.quit() }.keyboardShortcut("q")
            }
            CommandGroup(after: .toolbar) {
                Button("Reload") { session.reload() }.keyboardShortcut("r").disabled(session.busy)
                Button("Actual Size") { session.setZoom(0) }.keyboardShortcut("0")
                Button("Zoom In") { session.setZoom(session.zoom + 0.5) }.keyboardShortcut("+")
                Button("Zoom Out") { session.setZoom(session.zoom - 0.5) }.keyboardShortcut("-")
                Toggle("Collect Detailed Performance", isOn: Binding(get: { NativePerformance.mode == .detailed },
                    set: { session.setPerformance($0) }))
            }
        }
    }
}

@MainActor @Observable
private final class WorkspaceSession {
    var model: NativeWorkspaceModel?
    var presentation: NativeWorkspacePresentation?
    var error: String?
    var busy = false
    var zoom: Double = 0
    var generation = UUID()
    private let startup = NativeStartupPerformance()
    private var exitCleanup: NativeRuntimeExitCleanup?
    private var interactionServer: NativeInteractionServer?
    private var zoomURL: URL?
    private var performanceDirectory: URL?
    private var task: Task<Void, Never>?
    private var quitting = false
    private var quitDeadline: Task<Void, Never>?
    var scale: Double { min(5, max(0.25, pow(1.2, zoom))) }

    init() {
        do {
            let options = try LaunchOptions()
            let lease = try RuntimeProfileClientLease(dataDirectory: options.dataDirectory)
            lease.retainForProcess()
            let profile = lease.profile
            performanceDirectory = profile.dataDirectory.appendingPathComponent("diagnostics/performance", isDirectory: true)
            if let performanceDirectory { NativePerformance.configure(directory: performanceDirectory) }
            startup.attachToRecording()
            zoomURL = profile.dataDirectory.appendingPathComponent("native-window-zoom.json")
            if let zoomURL, let data = try? Data(contentsOf: zoomURL),
               let saved = try? JSONDecoder().decode(SavedZoom.self, from: data), saved.level.isFinite { zoom = saved.level }
            NativeTypography.registerFonts()
            let preferences = DesktopPreferences(directory: profile.dataDirectory)
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
    func start() {
        guard let model else { return }
        startup.shellReady(); model.start()
        FileHandle.standardOutput.write(Data("[native-launch] ready pid=\(ProcessInfo.processInfo.processIdentifier)\n".utf8))
    }
    func setZoom(_ value: Double) {
        guard value.isFinite else { return }; zoom = value
        if let zoomURL, let data = try? JSONEncoder().encode(SavedZoom(level: value)) { try? data.write(to: zoomURL, options: .atomic) }
    }
    func setPerformance(_ enabled: Bool) {
        guard let performanceDirectory else { return }
        NativePerformance.configure(directory: performanceDirectory, mode: enabled ? .detailed : .off)
    }
    func reload() {
        guard !busy, !quitting, let model else { return }
        busy = true
        task = Task {
            defer { if !quitting { busy = false; task = nil } }
            model.resetSettingsForReload()
            await presentation?.release()
            await model.voice.stopAll(); await model.harnessHost.releaseAll()
            model.voice.receive(.connection(model.connection)); model.settingsOpen = false
            presentation = NativeWorkspacePresentation(workspace: model); generation = UUID()
        }
    }
    func quit() {
        guard !quitting else { finishQuit(); return }
        quitting = true; busy = true
        exitCleanup?.captureEpoch()
        task?.cancel()
        // Network/voice cleanup can outlive cancellation. The deadline must
        // not join that work; the epoch-fenced exit helper finishes it instead.
        quitDeadline = Task {
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            exitCleanup?.record(RuntimeError("QUIT_TIMEOUT", "Application exited while runtime cleanup continued"))
            finishQuit()
        }
        task = Task {
            do {
                try await model?.stop()
                exitCleanup?.disarm()
            } catch { exitCleanup?.record(error) }
            finishQuit()
        }
    }
    private func finishQuit() {
        quitDeadline?.cancel()
        interactionServer?.stop()
        startup.cancel(); NativePerformance.finish()
        exit(EXIT_SUCCESS)
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
                } else { ContentUnavailableView("无法打开 Mokusei", systemImage: "exclamationmark.triangle", description: Text(session.error ?? "")) }
            }
            .frame(width: geometry.size.width / session.scale, height: geometry.size.height / session.scale)
            .environment(\.nativeWindowContentScale, CGFloat(session.scale))
            .scaleEffect(session.scale, anchor: .topLeading)
            .disabled(session.busy)
        }
        .modifier(NativeWorkspaceWindowSurface())
        .onAppear { session.start() }
        .onDisappear { session.quit() }
        .alert("Mokusei", isPresented: Binding(get: { session.error != nil && session.model != nil }, set: { if !$0 { session.error = nil } })) {
            Button("OK") { session.error = nil }
        } message: { Text(session.error ?? "") }
    }
}

private struct LaunchOptions {
    let dataDirectory: URL
    let launch: RuntimeLaunchConfiguration?
    let automationSocket: String?

    init() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        var options: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            if flag.hasPrefix("-psn_") { index += 1; continue }
            guard ["--data-dir", "--runtime", "--automation-socket"].contains(flag), index + 1 < arguments.count,
                  options[flag] == nil, arguments[index + 1].hasPrefix("/") else {
                throw NSError(domain: "MokuseiLaunch", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unknown launch argument: \(flag)"])
            }
            options[flag] = arguments[index + 1]
            index += 2
        }
        automationSocket = options["--automation-socket"]
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
